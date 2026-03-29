import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/call_config.dart';
import '../services/livekit_service.dart';
import '../services/socket_service.dart';
import '../services/api_service.dart';

/// Controller for managing call state (audio, video, group).
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
    final minutes = _callDuration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = _callDuration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = _callDuration.inHours;
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  CallController({required ApiService apiService}) : _apiService = apiService;

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
    _callState = CallState.connecting;
    _callType = callType;
    _roomName = roomName;
    _callerId = callerId;
    _receiverId = receiverId;
    _receiverName = receiverName;
    _receiverAvatar = receiverAvatar;
    notifyListeners();

    _apiService.setAuthToken(userToken);

    // Connect socket and register user so we can receive call events
    _socketService.connect(url: socketUrl, authToken: userToken);
    _socketService.registerUser(callerId);
    _listenForCallEnded();

    try {
      final tokenData = await _apiService.getCallToken(
        callerId: callerId,
        receiverId: receiverId,
        room: roomName,
      );

      // Signal the receiver before connecting LiveKit
      _socketService.sendCallOffer(
        callerId: callerId,
        receiverId: receiverId,
        roomName: roomName,
        callType: callType == CallType.video ? 'video' : 'audio',
        callerName: receiverName, // caller's own name
        callerAvatar: receiverAvatar,
      );

      await _livekitService.connect(
        url: tokenData['livekitUrl'] ?? livekitUrl,
        token: tokenData['callerToken'],
        enableCamera: callType == CallType.video,
        enableMicrophone: true,
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
    _socketService.acceptCall(callerId: callerId, receiverId: receiverId, roomName: roomName);
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

  /// End the call.
  Future<void> endCall() async {
    _callState = CallState.ended;
    _durationTimer?.cancel();
    _callEndedSub?.cancel();

    // Signal the other party that the call ended
    if (_callerId != null && _receiverId != null) {
      _socketService.endCallSignal(callerId: _callerId!, receiverId: _receiverId!);
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

  /// Toggle microphone.
  Future<void> toggleMute() async {
    await _livekitService.toggleMicrophone();
    notifyListeners();
  }

  /// Toggle camera.
  Future<void> toggleCamera() async {
    await _livekitService.toggleCamera();
    notifyListeners();
  }

  /// Switch camera (front/rear).
  Future<void> switchCamera() async {
    await _livekitService.switchCamera();
  }

  /// Toggle speaker.
  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    await _livekitService.setSpeakerOn(_isSpeakerOn);
    notifyListeners();
  }

  /// Explicitly set speaker state.
  Future<void> setSpeakerEnabled(bool enabled) async {
    _isSpeakerOn = enabled;
    await _livekitService.setSpeakerOn(enabled);
    notifyListeners();
  }

  void _startDurationTimer() {
    _callDuration = Duration.zero;
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _callDuration += const Duration(seconds: 1);
      notifyListeners();
    });
  }

  void _onLiveKitUpdate() {
    notifyListeners();
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _callEndedSub?.cancel();
    _livekitService.removeListener(_onLiveKitUpdate);
    _livekitService.dispose();
    _socketService.dispose();
    super.dispose();
  }
}
