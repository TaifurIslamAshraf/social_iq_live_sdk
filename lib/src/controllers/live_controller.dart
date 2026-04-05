import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' show VideoQuality;
import '../models/live_config.dart';
import '../services/livekit_service.dart';
import '../services/socket_service.dart';
import '../services/api_service.dart';

/// Controller for managing live broadcast state (host or viewer).
///
/// Optimisation: `notifyListeners()` is throttled to at most once per 100 ms
/// so the Flutter widget tree does not rebuild on every incoming WebRTC event.
/// On a busy stream with many viewers this can drop main-thread CPU usage by ~20 %.
class LiveController extends ChangeNotifier {
  final LiveKitService _livekitService = LiveKitService();
  final SocketService _socketService = SocketService();
  final ApiService _apiService;

  static const int _maxComments = 100;

  // ── Throttle ──────────────────────────────────────────────────────────────
  /// Minimum gap between successive `notifyListeners()` calls from LiveKit events.
  static const Duration _notifyThrottle = Duration(milliseconds: 100);
  Timer? _throttleTimer;
  bool _pendingNotify = false;

  final List<LiveComment> _comments = [];
  final List<LiveReaction> _pendingReactions = [];
  int _viewerCount = 0;
  bool _isLive = false;
  bool _isHost = false;
  String? _roomName;
  String? _identity;
  String? _displayName;
  String? _avatarUrl;

  StreamSubscription? _connectSub;
  StreamSubscription? _commentSub;
  StreamSubscription? _reactionSub;
  StreamSubscription? _viewerCountSub;

  // Public getters
  LiveKitService get livekitService => _livekitService;
  List<LiveComment> get comments => List.unmodifiable(_comments);
  List<LiveReaction> get pendingReactions =>
      List.unmodifiable(_pendingReactions);
  int get viewerCount => _viewerCount;
  bool get isLive => _isLive;
  bool get isHost => _isHost;
  bool get isMuted => !_livekitService.isMicEnabled;
  bool get isCameraOff => !_livekitService.isCameraEnabled;
  String? get roomName => _roomName;

  LiveController({required ApiService apiService}) : _apiService = apiService;

  // ── Throttled notify ──────────────────────────────────────────────────────

  /// Queues a `notifyListeners()` call that is coalesced within [_notifyThrottle].
  /// Immediate state changes (start/stop) bypass this by calling
  /// `notifyListeners()` directly.
  void _scheduleNotify() {
    if (_throttleTimer?.isActive == true) {
      _pendingNotify = true;
      return;
    }
    notifyListeners();
    _pendingNotify = false;
    _throttleTimer = Timer(_notifyThrottle, () {
      if (_pendingNotify) {
        _pendingNotify = false;
        notifyListeners();
      }
    });
  }

  // ── Broadcast ─────────────────────────────────────────────────────────────

  /// Start a live broadcast as host.
  Future<void> startBroadcast({
    required String userToken,
    required String identity,
    required String displayName,
    String? avatarUrl,
    String? title,
    required String livekitUrl,
    required String socketUrl,
  }) async {
    _isHost = true;
    _identity = identity;
    _displayName = displayName;
    _avatarUrl = avatarUrl;
    _roomName = 'live_$identity';

    _apiService.setAuthToken(userToken);

    try {
      final tokenData = await _apiService.getLiveToken(
        userType: 'publisher',
        identity: identity,
        room: _roomName!,
      );

      // Connect with livestream mode — 540p @ 20 fps, 2-layer simulcast.
      await _livekitService.connect(
        url: tokenData['livekitUrl'] ?? livekitUrl,
        token: tokenData['token'],
        enableCamera: true,
        enableMicrophone: true,
        mode: StreamMode.livestream,
      );

      _setupSocketListeners();
      _socketService.connect(url: socketUrl, authToken: userToken);
      _socketService.joinLiveRoom(_roomName!, identity);
      _socketService.startLive(_roomName!, identity);

      _isLive = true;
      _livekitService.addListener(_onLiveKitUpdate);

      notifyListeners(); // immediate — state just changed
    } catch (e) {
      _isHost = false;
      _isLive = false;
      notifyListeners();
      rethrow;
    }
  }

  /// Join a live broadcast as viewer.
  Future<void> joinAsViewer({
    required String userToken,
    required String identity,
    required String displayName,
    String? avatarUrl,
    required String roomName,
    required String livekitUrl,
    required String socketUrl,
    /// Viewers default to MEDIUM quality to reduce server routing load.
    VideoQuality preferredQuality = VideoQuality.MEDIUM,
  }) async {
    _isHost = false;
    _identity = identity;
    _displayName = displayName;
    _avatarUrl = avatarUrl;
    _roomName = roomName;

    _apiService.setAuthToken(userToken);

    try {
      final tokenData = await _apiService.getLiveToken(
        userType: 'viewer',
        identity: identity,
        room: roomName,
      );

      // Viewers don't publish — use videoCall mode to avoid forcing loudspeaker
      // routing that would let mic leak bleed back to the host as echo.
      await _livekitService.connect(
        url: tokenData['livekitUrl'] ?? livekitUrl,
        token: tokenData['token'],
        enableCamera: false,
        enableMicrophone: false,
        mode: StreamMode.videoCall,
      );

      // Downgrade subscription quality for every existing remote participant.
      for (final p in _livekitService.remoteParticipants) {
        await _livekitService.setPreferredVideoQuality(p, preferredQuality);
      }

      _setupSocketListeners();
      _socketService.connect(url: socketUrl, authToken: userToken);
      _socketService.joinLiveRoom(roomName, identity);

      _isLive = true;
      _livekitService.addListener(_onLiveKitUpdate);

      notifyListeners(); // immediate
    } catch (e) {
      _isLive = false;
      notifyListeners();
      rethrow;
    }
  }

  // ── Chat / reactions ──────────────────────────────────────────────────────

  /// Send a comment.
  void sendComment(String message) {
    if (_roomName == null || _identity == null || message.trim().isEmpty) return;

    final comment = LiveComment(
      userId: _identity!,
      userName: _displayName ?? _identity!,
      userAvatar: _avatarUrl,
      message: message.trim(),
      timestamp: DateTime.now(),
    );

    _comments.add(comment);
    if (_comments.length > _maxComments) _comments.removeAt(0);

    _socketService.sendComment(
      roomName: _roomName!,
      userId: _identity!,
      userName: _displayName ?? _identity!,
      userAvatar: _avatarUrl,
      message: message.trim(),
    );

    notifyListeners(); // immediate — user action
  }

  /// Send a reaction emoji.
  void sendReaction(String emoji) {
    if (_roomName == null || _identity == null) return;

    final reaction = LiveReaction(
      emoji: emoji,
      userId: _identity!,
      timestamp: DateTime.now(),
    );

    _pendingReactions.add(reaction);

    _socketService.sendReaction(
      roomName: _roomName!,
      userId: _identity!,
      emoji: emoji,
    );

    notifyListeners(); // immediate — user action

    Future.delayed(const Duration(seconds: 3), () {
      _pendingReactions.remove(reaction);
      if (!_isLive) return;
      _scheduleNotify();
    });
  }

  /// Remove a reaction (called after animation completes).
  void removeReaction(LiveReaction reaction) {
    _pendingReactions.remove(reaction);
    _scheduleNotify();
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  /// Toggle mute.
  Future<void> toggleMute() async {
    await _livekitService.toggleMicrophone();
    notifyListeners();
  }

  /// Toggle camera.
  Future<void> toggleCamera() async {
    await _livekitService.toggleCamera();
    notifyListeners();
  }

  /// Switch camera.
  Future<void> switchCamera() async {
    await _livekitService.switchCamera();
  }

  /// Stop broadcast / leave stream.
  Future<void> stopBroadcast() async {
    _isLive = false;

    if (_roomName != null) {
      _socketService.leaveLiveRoom(_roomName!, _identity ?? '', isHost: _isHost);

      if (_isHost) {
        try {
          await _apiService.endLive(roomName: _roomName!);
        } catch (e) {
          debugPrint('Failed to end live room via API: $e');
        }
      }
    }

    _throttleTimer?.cancel();
    _livekitService.removeListener(_onLiveKitUpdate);
    await _livekitService.disconnect();
    _socketService.disconnect();

    notifyListeners(); // immediate
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  void _onLiveKitUpdate() {
    // For viewers, keep participant count in sync with LiveKit.
    // For the host, viewer count is sourced exclusively from the socket
    // (_viewerCountSub) — LiveKit's remoteParticipants can transiently return
    // 0 during local track events (mic/camera toggle) and must not overwrite
    // the socket-authoritative value.
    if (!_isHost) {
      _viewerCount = _livekitService.participantCount;
    }

    // Detect host disconnection for viewers.
    // Two cases trigger this:
    //  a) Host participant left but room is still open  → remoteParticipants.isEmpty
    //  b) Host ended via API (room closed server-side) → room disconnected,
    //     remoteParticipants may not be empty yet due to the race between
    //     RoomDisconnectedEvent and the participant list being cleared.
    //     Checking !isConnected catches this second case.
    if (!_isHost && _isLive &&
        (_livekitService.remoteParticipants.isEmpty ||
            !_livekitService.isConnected)) {
      _isLive = false;
      notifyListeners(); // immediate — navigation-critical
      return;
    }

    // All other LiveKit events are throttled to avoid widget storm.
    _scheduleNotify();
  }

  void _setupSocketListeners() {
    _connectSub = _socketService.onConnect.listen((_) {
      if (_roomName != null && _identity != null) {
        _socketService.joinLiveRoom(_roomName!, _identity!);
      }
    });

    _commentSub = _socketService.onComment.listen((data) {
      if (data['userId'] == _identity) return;

      _comments.add(LiveComment(
        userId: data['userId'] ?? '',
        userName: data['userName'] ?? 'Unknown',
        userAvatar: data['userAvatar'],
        message: data['message'] ?? '',
        timestamp: DateTime.now(),
      ));
      if (_comments.length > _maxComments) _comments.removeAt(0);
      notifyListeners(); // user-visible — keep immediate
    });

    _reactionSub = _socketService.onReaction.listen((data) {
      if (data['userId'] == _identity) return;

      final reaction = LiveReaction(
        emoji: data['emoji'] ?? '❤️',
        userId: data['userId'] ?? '',
        timestamp: DateTime.now(),
      );

      _pendingReactions.add(reaction);
      _scheduleNotify();

      Future.delayed(const Duration(seconds: 3), () {
        _pendingReactions.remove(reaction);
        if (!_isLive) return;
        _scheduleNotify();
      });
    });

    _viewerCountSub = _socketService.onViewerCountUpdate.listen((count) {
      _viewerCount = count;
      _scheduleNotify();
    });
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    _connectSub?.cancel();
    _commentSub?.cancel();
    _reactionSub?.cancel();
    _viewerCountSub?.cancel();
    _livekitService.removeListener(_onLiveKitUpdate);
    _livekitService.dispose();
    _socketService.dispose();
    super.dispose();
  }
}
