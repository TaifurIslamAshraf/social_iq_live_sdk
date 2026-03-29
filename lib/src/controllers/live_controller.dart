import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/live_config.dart';
import '../services/livekit_service.dart';
import '../services/socket_service.dart';
import '../services/api_service.dart';

/// Controller for managing live broadcast state (host or viewer).
class LiveController extends ChangeNotifier {
  final LiveKitService _livekitService = LiveKitService();
  final SocketService _socketService = SocketService();
  final ApiService _apiService;

  static const int _maxComments = 100;

  final List<LiveComment> _comments = [];
  final List<LiveReaction> _pendingReactions = [];
  int _viewerCount = 0;
  bool _isLive = false;
  bool _isHost = false;
  String? _roomName;
  String? _identity;
  String? _displayName;
  String? _avatarUrl;

  StreamSubscription? _commentSub;
  StreamSubscription? _reactionSub;
  StreamSubscription? _viewerCountSub;

  // Public getters
  LiveKitService get livekitService => _livekitService;
  List<LiveComment> get comments => List.unmodifiable(_comments);
  List<LiveReaction> get pendingReactions => List.unmodifiable(_pendingReactions);
  int get viewerCount => _viewerCount;
  bool get isLive => _isLive;
  bool get isHost => _isHost;
  bool get isMuted => !_livekitService.isMicEnabled;
  bool get isCameraOff => !_livekitService.isCameraEnabled;
  String? get roomName => _roomName;

  LiveController({required ApiService apiService}) : _apiService = apiService;

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
      // Get live token from backend
      final tokenData = await _apiService.getLiveToken(
        userType: 'publisher',
        identity: identity,
        room: _roomName!,
      );

      // Connect to LiveKit
      await _livekitService.connect(
        url: tokenData['livekitUrl'] ?? livekitUrl,
        token: tokenData['token'],
        enableCamera: true,
        enableMicrophone: true,
      );

      // Connect to socket for comments/reactions
      _socketService.connect(url: socketUrl, authToken: userToken);
      _socketService.joinLiveRoom(_roomName!);
      _setupSocketListeners();

      _isLive = true;

      // Forward LiveKit changes
      _livekitService.addListener(_onLiveKitUpdate);

      notifyListeners();
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
  }) async {
    _isHost = false;
    _identity = identity;
    _displayName = displayName;
    _avatarUrl = avatarUrl;
    _roomName = roomName;

    _apiService.setAuthToken(userToken);

    try {
      // Get viewer token from backend
      final tokenData = await _apiService.getLiveToken(
        userType: 'viewer',
        identity: identity,
        room: roomName,
      );

      // Connect to LiveKit (viewer: no camera/mic)
      await _livekitService.connect(
        url: tokenData['livekitUrl'] ?? livekitUrl,
        token: tokenData['token'],
        enableCamera: false,
        enableMicrophone: false,
      );

      // Connect to socket
      _socketService.connect(url: socketUrl, authToken: userToken);
      _socketService.joinLiveRoom(roomName);
      _setupSocketListeners();

      _isLive = true;
      _livekitService.addListener(_onLiveKitUpdate);

      notifyListeners();
    } catch (e) {
      _isLive = false;
      notifyListeners();
      rethrow;
    }
  }

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
    // Fix 8: Cap comments to prevent memory leak
    if (_comments.length > _maxComments) {
      _comments.removeAt(0);
    }

    _socketService.sendComment(
      roomName: _roomName!,
      userId: _identity!,
      userName: _displayName ?? _identity!,
      userAvatar: _avatarUrl,
      message: message.trim(),
    );

    notifyListeners();
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

    notifyListeners();

    // Auto-remove reaction after animation completes
    Future.delayed(const Duration(seconds: 3), () {
      _pendingReactions.remove(reaction);
      if (!_isLive) return;
      notifyListeners();
    });
  }

  /// Remove a reaction (called after animation completes).
  void removeReaction(LiveReaction reaction) {
    _pendingReactions.remove(reaction);
    notifyListeners();
  }

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
      _socketService.leaveLiveRoom(_roomName!);

      // Fix 3: Use the correct endLive endpoint for broadcasts
      if (_isHost) {
        try {
          await _apiService.endLive(roomName: _roomName!);
        } catch (e) {
          debugPrint('Failed to end live room via API: $e');
        }
      }
    }

    _livekitService.removeListener(_onLiveKitUpdate);
    await _livekitService.disconnect();
    _socketService.disconnect();

    notifyListeners();
  }

  void _onLiveKitUpdate() {
    // Fix 7: Viewer count should not include host when counting viewers
    _viewerCount = _isHost
        ? _livekitService.remoteParticipants.length
        : _livekitService.participantCount;

    // Fix 11: Propagate host disconnection to viewers
    if (!_isHost && _isLive && _livekitService.remoteParticipants.isEmpty) {
      // Host may have left — mark stream as ended so UI can react
      _isLive = false;
    }

    notifyListeners();
  }

  void _setupSocketListeners() {
    _commentSub = _socketService.onComment.listen((data) {
      // Don't duplicate own comments
      if (data['userId'] == _identity) return;

      final comment = LiveComment(
        userId: data['userId'] ?? '',
        userName: data['userName'] ?? 'Unknown',
        userAvatar: data['userAvatar'],
        message: data['message'] ?? '',
        timestamp: DateTime.now(),
      );

      _comments.add(comment);
      // Fix 8: Cap comments to prevent memory leak
      if (_comments.length > _maxComments) {
        _comments.removeAt(0);
      }
      notifyListeners();
    });

    _reactionSub = _socketService.onReaction.listen((data) {
      if (data['userId'] == _identity) return;

      final reaction = LiveReaction(
        emoji: data['emoji'] ?? '❤️',
        userId: data['userId'] ?? '',
        timestamp: DateTime.now(),
      );

      _pendingReactions.add(reaction);
      notifyListeners();

      Future.delayed(const Duration(seconds: 3), () {
        _pendingReactions.remove(reaction);
        if (!_isLive) return;
        notifyListeners();
      });
    });

    _viewerCountSub = _socketService.onViewerCountUpdate.listen((count) {
      _viewerCount = count;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _commentSub?.cancel();
    _reactionSub?.cancel();
    _viewerCountSub?.cancel();
    _livekitService.removeListener(_onLiveKitUpdate);
    _livekitService.dispose();
    _socketService.dispose();
    super.dispose();
  }
}
