import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/call_config.dart';
import '../services/livekit_service.dart';
import '../services/socket_service.dart';
import '../services/api_service.dart';

/// How long the caller waits for the receiver to accept/reject before
/// the call is auto-ended as "no answer".
const Duration _kRingingTimeout = Duration(seconds: 45);

/// Controller for managing call state (audio, video, group).
///
/// Optimisation notes for low-resource VPS (1 CPU core / 4 GB RAM):
///  - Video calls use [StreamMode.videoCall]: 720p @ 30 fps, 1700 kbps, no simulcast.
///  - Audio calls use [StreamMode.audioCall]: camera disabled, DTX active.
///  - Call duration is derived from [_callStartedAt] to avoid timer drift on
///    long calls; `notifyListeners` still fires once per second for the UI.
class CallController extends ChangeNotifier {
  final LiveKitService _livekitService = LiveKitService();
  final SocketService _socketService = SocketService();
  final ApiService _apiService;

  CallState _callState = CallState.idle;
  CallType? _callType;
  String? _roomName;
  String? _receiverName;
  String? _receiverAvatar;
  String? _callerId;
  String? _receiverId;
  DateTime? _callStartedAt;
  Duration _callDuration = Duration.zero;
  Timer? _durationTimer;
  Timer? _ringingTimer;
  bool _isSpeakerOn = false;
  bool _endSignaled = false;

  StreamSubscription? _callEndedSub;
  StreamSubscription? _callResponseSub;
  StreamSubscription? _extraSub;
  StreamSubscription? _socketReconnectSub;

  // Public getters
  LiveKitService get livekitService => _livekitService;
  CallState get callState => _callState;
  CallType? get callType => _callType;
  String? get roomName => _roomName;
  Duration get callDuration => _callDuration;
  bool get isMuted => !_livekitService.isMicEnabled;
  bool get isCameraOff => !_livekitService.isCameraEnabled;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isReconnecting => _livekitService.isReconnecting;
  String? get receiverName => _receiverName;
  String? get receiverAvatar => _receiverAvatar;
  int get participantCount => _livekitService.participantCount;

  String get formattedDuration {
    final h = _callDuration.inHours;
    final m = _callDuration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _callDuration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  CallController({required ApiService apiService}) : _apiService = apiService;

  // ─────────────────────────────────────────────────────────────────────────
  // StreamMode helper
  // ─────────────────────────────────────────────────────────────────────────

  StreamMode _modeFor(CallType type) {
    switch (type) {
      case CallType.audio:
        return StreamMode.audioCall;
      case CallType.video:
        return StreamMode.videoCall;
      case CallType.group:
        // Group calls: 720p, no simulcast.
        return StreamMode.videoCall;
    }
  }

  bool _isBusy() =>
      _callState == CallState.connecting || _callState == CallState.connected;

  // ─────────────────────────────────────────────────────────────────────────
  // Outgoing call
  // ─────────────────────────────────────────────────────────────────────────

  /// Start a 1:1 call (audio or video).
  ///
  /// [callerName] / [callerAvatar] are sent to the receiver so the incoming
  /// call screen can display who is calling. [receiverName] / [receiverAvatar]
  /// are kept locally to render the caller's own "calling …" screen.
  Future<void> startCall({
    required String userToken,
    required String callerId,
    required String receiverId,
    required String roomName,
    required CallType callType,
    required String livekitUrl,
    required String socketUrl,
    String? callerName,
    String? callerAvatar,
    String? receiverName,
    String? receiverAvatar,
  }) async {
    if (_isBusy()) {
      debugPrint('[CallController] startCall ignored — already in a call');
      return;
    }

    // Cancel any lingering subscriptions from a previous call.
    _callResponseSub?.cancel();
    _extraSub?.cancel();
    _callEndedSub?.cancel();
    _ringingTimer?.cancel();

    _endSignaled = false;
    _callState = CallState.connecting;
    _callType = callType;
    _roomName = roomName;
    _callerId = callerId;
    _receiverId = receiverId;
    _receiverName = receiverName;
    _receiverAvatar = receiverAvatar;
    notifyListeners();

    _apiService.setAuthToken(userToken);

    _socketService.connect(url: socketUrl, authToken: userToken);
    _socketService.registerUser(callerId);
    _listenForSocketReconnect(callerId);
    _listenForCallEnded();

    try {
      final tokenData = await _apiService.getCallToken(
        callerId: callerId,
        receiverId: receiverId,
        room: roomName,
      );

      // Notify receiver. Send CALLER's identity, not the receiver's.
      _socketService.sendCallOffer(
        callerId: callerId,
        receiverId: receiverId,
        roomName: roomName,
        callType: callType == CallType.video ? 'video' : 'audio',
        callerName: callerName,
        callerAvatar: callerAvatar,
      );

      // No-answer timeout.
      _ringingTimer = Timer(_kRingingTimeout, () {
        if (_callState != CallState.connecting) return;
        debugPrint('[CallController] Ringing timeout, cancelling call');
        endCall();
      });

      // Connect to LiveKit eagerly while the receiver is still ringing.
      // By the time they accept, the caller is already in the room — the
      // "Calling…" → timer transition happens almost instantly.
      _isSpeakerOn = callType != CallType.audio;
      final connectFuture = _livekitService
          .connect(
            url: tokenData['livekitUrl'] ?? livekitUrl,
            token: tokenData['callerToken'],
            enableCamera: callType == CallType.video,
            enableMicrophone: true,
            mode: _modeFor(callType),
          )
          .catchError((dynamic e) {
        debugPrint('[CallController] Eager LiveKit connect error: $e');
        if (_callState == CallState.connecting) {
          _callState = CallState.ended;
          notifyListeners();
        }
      });

      // Receiver accepted — LiveKit connection is likely already done.
      _callResponseSub = _socketService.onCallAccepted.listen((_) async {
        if (_callState != CallState.connecting) return;
        _ringingTimer?.cancel();
        _extraSub?.cancel();
        await connectFuture; // no-op if already connected
        if (_callState == CallState.ended) return; // connect failed
        _callState = CallState.connected;
        _startDurationTimer();
        _livekitService.addListener(_onLiveKitUpdate);
        notifyListeners();
      });

      // Receiver declined — disconnect from LiveKit.
      _extraSub = _socketService.onCallRejected.listen((_) {
        if (_callState != CallState.connecting) return;
        _ringingTimer?.cancel();
        _callResponseSub?.cancel();
        _livekitService.disconnect();
        _callState = CallState.ended;
        notifyListeners();
      });
    } catch (e) {
      _ringingTimer?.cancel();
      _callState = CallState.ended;
      notifyListeners();
      rethrow;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Incoming call
  // ─────────────────────────────────────────────────────────────────────────

  /// Join a call as receiver (for incoming calls).
  Future<void> answerCall({
    required String userToken,
    required String receiverId,
    required String callerId,
    required String roomName,
    required CallType callType,
    required String livekitUrl,
    required String socketUrl,
    String? callerName,
    String? callerAvatar,
  }) async {
    if (_isBusy()) {
      debugPrint('[CallController] answerCall ignored — already in a call');
      return;
    }

    _endSignaled = false;
    _callState = CallState.connecting;
    _callType = callType;
    _roomName = roomName;
    _callerId = callerId;
    _receiverId = receiverId;
    _receiverName = callerName;
    _receiverAvatar = callerAvatar;
    notifyListeners();

    _apiService.setAuthToken(userToken);
    _socketService.connect(url: socketUrl, authToken: userToken);
    _socketService.registerUser(receiverId);
    _listenForSocketReconnect(receiverId);
    _listenForCallEnded();

    try {
      final tokenData = await _apiService.getCallToken(
        callerId: callerId,
        receiverId: receiverId,
        room: roomName,
      );

      await _livekitService.connect(
        url: tokenData['livekitUrl'] ?? livekitUrl,
        token: tokenData['receiverToken'],
        enableCamera: callType == CallType.video,
        enableMicrophone: true,
        mode: _modeFor(callType),
      );
      // Sync speaker state so the UI button reflects the actual routing.
      _isSpeakerOn = callType != CallType.audio;

      // Signal caller AFTER we are in the room so audio starts immediately.
      _socketService.acceptCall(
        callerId: callerId,
        receiverId: receiverId,
        roomName: roomName,
      );

      _callState = CallState.connected;
      _startDurationTimer();
      _livekitService.addListener(_onLiveKitUpdate);
      notifyListeners();
    } catch (e) {
      _callState = CallState.ended;
      notifyListeners();
      rethrow;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Group call
  // ─────────────────────────────────────────────────────────────────────────

  /// Join a group call.
  Future<void> joinGroupCall({
    required String userToken,
    required String identity,
    required String roomName,
    required String livekitUrl,
  }) async {
    if (_isBusy()) {
      debugPrint('[CallController] joinGroupCall ignored — already in a call');
      return;
    }

    _endSignaled = false;
    _callState = CallState.connecting;
    _callType = CallType.group;
    _roomName = roomName;
    notifyListeners();

    _apiService.setAuthToken(userToken);

    try {
      final tokenData = await _apiService.getGroupCallToken(
        identity: identity,
        room: roomName,
      );

      await _livekitService.connect(
        url: tokenData['livekitUrl'] ?? livekitUrl,
        token: tokenData['token'],
        enableCamera: true,
        enableMicrophone: true,
        mode: StreamMode.videoCall, // group = videoCall mode (720p, no simulcast)
      );
      // Group calls use speaker; sync UI state.
      _isSpeakerOn = true;

      _callState = CallState.connected;
      _startDurationTimer();
      _livekitService.addListener(_onLiveKitUpdate);
      notifyListeners();
    } catch (e) {
      _callState = CallState.ended;
      notifyListeners();
      rethrow;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // End call
  // ─────────────────────────────────────────────────────────────────────────

  /// End the call. Safe to call more than once — duplicate invocations are
  /// no-ops.
  Future<void> endCall() async {
    if (_callState == CallState.ended || _callState == CallState.idle) {
      return;
    }
    _callState = CallState.ended;
    _durationTimer?.cancel();
    _ringingTimer?.cancel();
    _callEndedSub?.cancel();
    _callResponseSub?.cancel();
    _extraSub?.cancel();
    _socketReconnectSub?.cancel();

    if (!_endSignaled &&
        _callerId != null &&
        _receiverId != null &&
        _socketService.isConnected) {
      _endSignaled = true;
      _socketService.endCallSignal(
        callerId: _callerId!,
        receiverId: _receiverId!,
      );
    }

    _livekitService.removeListener(_onLiveKitUpdate);
    await _livekitService.disconnect();
    _socketService.disconnect();

    if (_roomName != null) {
      try {
        await _apiService.endCall(roomName: _roomName!);
      } catch (e) {
        debugPrint('Failed to end room via API: $e');
      }
    }

    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Controls
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> toggleMute() async {
    await _livekitService.toggleMicrophone();
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    await _livekitService.toggleCamera();
    notifyListeners();
  }

  Future<void> switchCamera() async => _livekitService.switchCamera();

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    await _livekitService.setSpeakerOn(_isSpeakerOn);
    notifyListeners();
  }

  Future<void> setSpeakerEnabled(bool enabled) async {
    _isSpeakerOn = enabled;
    await _livekitService.setSpeakerOn(enabled);
    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal
  // ─────────────────────────────────────────────────────────────────────────

  void _listenForCallEnded() {
    _callEndedSub?.cancel();
    _callEndedSub = _socketService.onCallEnded.listen((_) {
      if (_callState == CallState.ended) return;
      // Remote ended — mark as such before doing anything so our own endCall()
      // signal path sees _callState=ended and skips re-emitting call_end.
      _endSignaled = true;
      _callState = CallState.ended;
      _durationTimer?.cancel();
      _ringingTimer?.cancel();
      _livekitService.removeListener(_onLiveKitUpdate);
      _livekitService.disconnect();
      _socketService.disconnect();
      notifyListeners();
    });
  }

  void _listenForSocketReconnect(String userId) {
    _socketReconnectSub?.cancel();
    // Re-register this user on every (re)connect so incoming-call routing
    // survives transient network drops mid-call.
    _socketReconnectSub = _socketService.onConnect.listen((_) {
      _socketService.registerUser(userId);
    });
  }

  void _startDurationTimer() {
    _callStartedAt = DateTime.now();
    _callDuration = Duration.zero;
    _durationTimer?.cancel();
    // Rebuild once per second; derive duration from the start timestamp so
    // the value never drifts relative to wall-clock time.
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final start = _callStartedAt;
      if (start == null) return;
      _callDuration = DateTime.now().difference(start);
      notifyListeners();
    });
  }

  void _onLiveKitUpdate() => notifyListeners();

  @override
  void dispose() {
    _durationTimer?.cancel();
    _ringingTimer?.cancel();
    _callEndedSub?.cancel();
    _callResponseSub?.cancel();
    _extraSub?.cancel();
    _socketReconnectSub?.cancel();
    _livekitService.removeListener(_onLiveKitUpdate);
    // Disconnecting here is sufficient — no need to also call dispose() on
    // the services (they'd just re-disconnect). Their own ChangeNotifier
    // disposal happens via garbage collection once we drop our references.
    _livekitService.dispose();
    _socketService.dispose();
    super.dispose();
  }
}
