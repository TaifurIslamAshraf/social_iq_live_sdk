import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/call_config.dart';
import '../services/livekit_service.dart';
import '../services/socket_service.dart';
import '../services/api_service.dart';

/// Controller for managing call state (audio, video, group).
///
/// Optimisation notes for low-resource VPS (1 CPU core / 4 GB RAM):
///  - Video calls use [StreamMode.videoCall]: 360p @ 15 fps, 500 kbps, no simulcast.
///  - Audio calls use [StreamMode.audioCall]: camera disabled, DTX active.
///  - Duration-timer `notifyListeners` is the only high-frequency rebuild trigger;
///    it is preserved as-is because the timer fires once per second (acceptable).
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
  Duration _callDuration = Duration.zero;
  Timer? _durationTimer;
  bool _isSpeakerOn = false;

  StreamSubscription? _callEndedSub;
  StreamSubscription? _callResponseSub;
  StreamSubscription? _extraSub;

  // Public getters
  LiveKitService get livekitService => _livekitService;
  CallState get callState => _callState;
  CallType? get callType => _callType;
  String? get roomName => _roomName;
  Duration get callDuration => _callDuration;
  bool get isMuted => !_livekitService.isMicEnabled;
  bool get isCameraOff => !_livekitService.isCameraEnabled;
  bool get isSpeakerOn => _isSpeakerOn;
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
        // Group calls: video at reduced quality, no simulcast.
        return StreamMode.videoCall;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Outgoing call
  // ─────────────────────────────────────────────────────────────────────────

  /// Start a 1:1 call (audio or video).
  Future<void> startCall({
    required String userToken,
    required String callerId,
    required String receiverId,
    required String roomName,
    required CallType callType,
    required String livekitUrl,
    required String socketUrl,
    String? receiverName,
    String? receiverAvatar,
  }) async {
    // Cancel any lingering subscriptions from a previous call.
    _callResponseSub?.cancel();
    _extraSub?.cancel();
    _callEndedSub?.cancel();

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
    _listenForCallEnded();

    try {
      final tokenData = await _apiService.getCallToken(
        callerId: callerId,
        receiverId: receiverId,
        room: roomName,
      );

      // Notify receiver.
      _socketService.sendCallOffer(
        callerId: callerId,
        receiverId: receiverId,
        roomName: roomName,
        callType: callType == CallType.video ? 'video' : 'audio',
        callerName: receiverName,
        callerAvatar: receiverAvatar,
      );

      // Stay in Calling… state; join LiveKit only when receiver accepts.
      _callResponseSub = _socketService.onCallAccepted.listen((_) async {
        if (_callState != CallState.connecting) return;
        _extraSub?.cancel();
        try {
          await _livekitService.connect(
            url: tokenData['livekitUrl'] ?? livekitUrl,
            token: tokenData['callerToken'],
            enableCamera: callType == CallType.video,
            enableMicrophone: true,
            mode: _modeFor(callType), // ← VPS-optimised mode
          );
          // Sync speaker state so the UI button reflects the actual routing
          // set inside livekit_service.connect() (audio=earpiece, video=speaker).
          _isSpeakerOn = callType != CallType.audio;
          _callState = CallState.connected;
          _startDurationTimer();
          _livekitService.addListener(_onLiveKitUpdate);
          notifyListeners();
        } catch (e) {
          _callState = CallState.ended;
          notifyListeners();
        }
      });

      // Receiver declined.
      _extraSub = _socketService.onCallRejected.listen((_) {
        if (_callState != CallState.connecting) return;
        _callResponseSub?.cancel();
        _callState = CallState.ended;
        notifyListeners();
      });
    } catch (e) {
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
        mode: _modeFor(callType), // ← VPS-optimised mode
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
        mode: StreamMode.videoCall, // group = videoCall mode (360p, no simulcast)
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

  /// End the call.
  Future<void> endCall() async {
    _callState = CallState.ended;
    _durationTimer?.cancel();
    _callEndedSub?.cancel();
    _callResponseSub?.cancel();
    _extraSub?.cancel();

    if (_callerId != null && _receiverId != null) {
      _socketService.endCallSignal(
          callerId: _callerId!, receiverId: _receiverId!);
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
      if (_callState != CallState.ended) {
        _callState = CallState.ended;
        _durationTimer?.cancel();
        _livekitService.removeListener(_onLiveKitUpdate);
        _livekitService.disconnect();
        _socketService.disconnect();
        notifyListeners();
      }
    });
  }

  void _startDurationTimer() {
    _callDuration = Duration.zero;
    _durationTimer?.cancel();
    // Fires once per second — acceptable rebuild frequency for the call timer.
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _callDuration += const Duration(seconds: 1);
      notifyListeners();
    });
  }

  void _onLiveKitUpdate() => notifyListeners();

  @override
  void dispose() {
    _durationTimer?.cancel();
    _callEndedSub?.cancel();
    _callResponseSub?.cancel();
    _extraSub?.cancel();
    _livekitService.removeListener(_onLiveKitUpdate);
    _livekitService.dispose();
    _socketService.dispose();
    super.dispose();
  }
}
