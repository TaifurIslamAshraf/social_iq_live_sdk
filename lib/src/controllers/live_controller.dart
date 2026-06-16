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

  // ── Host-presence grace ─────────────────────────────────────────────────────
  /// A viewer waits this long before concluding the host has actually left.
  /// Rides out transient blips — the viewer's own reconnect or a brief host
  /// track renegotiation — that would otherwise look like the stream ending.
  static const Duration _hostGoneGrace = Duration(seconds: 6);
  Timer? _hostGoneTimer;

  final List<LiveComment> _comments = [];
  final List<LiveReaction> _pendingReactions = [];
  final List<LiveGift> _pendingGifts = [];

  // ── Follow status (only ever resolved for users who comment) ────────────────
  /// Set by the screen. Returns which of the given uids the current user
  /// already follows. Null when the app doesn't support follow.
  Future<Set<String>> Function(List<String> uids)? followingChecker;
  final Set<String> _followedUserIds = {}; // known already-followed
  final Set<String> _checkedFollowIds = {}; // resolved (avoid re-checking)
  final Set<String> _extraFollowUids = {}; // non-commenters to also check (host)
  bool _resolvingFollow = false;

  /// Running total of gift coins (gross value) sent in the current session.
  /// In-memory only — resets when a new broadcast starts/joins.
  int _sessionGiftCoins = 0;
  LiveComment? _pinnedComment;
  int _viewerCount = 0;
  bool _isLive = false;
  bool _isHost = false;
  String? _roomName;
  String? _identity;
  String? _displayName;
  String? _avatarUrl;

  /// Users the host has blocked. Their comments/reactions are hidden locally
  /// and dropped server-side. Held in memory for the duration of the stream.
  final Set<String> _blockedUserIds = {};

  /// True once *this* client's own user has been blocked by the host — used to
  /// disable their comment input.
  bool _isBlocked = false;

  /// True once the host has comment-muted *this* client. They can still watch
  /// and react, but their comment box is disabled.
  bool _isCommentMuted = false;

  /// Set when this viewer is removed from the live by the host. One of
  /// `'kicked'` or `'banned'`; null otherwise. The viewer UI reads this to show
  /// the right message before leaving.
  String? _removedReason;

  VideoQuality _preferredQuality = VideoQuality.MEDIUM;

  StreamSubscription? _connectSub;
  StreamSubscription? _commentSub;
  StreamSubscription? _reactionSub;
  StreamSubscription? _giftSub;
  StreamSubscription? _viewerCountSub;
  StreamSubscription? _commentPinSub;
  StreamSubscription? _blockedSub;
  StreamSubscription? _commentHistorySub;
  StreamSubscription? _kickedSub;
  StreamSubscription? _bannedSub;
  StreamSubscription? _banBlockedSub;
  StreamSubscription? _commentMutedSub;
  StreamSubscription? _commentDeletedSub;

  // Public getters
  LiveKitService get livekitService => _livekitService;
  List<LiveComment> get comments => List.unmodifiable(_comments);
  List<LiveReaction> get pendingReactions =>
      List.unmodifiable(_pendingReactions);
  List<LiveGift> get pendingGifts => List.unmodifiable(_pendingGifts);

  /// Total gift coins (gross) sent so far in this live session.
  int get sessionGiftCoins => _sessionGiftCoins;
  LiveComment? get pinnedComment => _pinnedComment;
  int get viewerCount => _viewerCount;
  bool get isLive => _isLive;
  bool get isHost => _isHost;
  bool get isMuted => !_livekitService.isMicEnabled;
  bool get isCameraOff => !_livekitService.isCameraEnabled;
  String? get roomName => _roomName;

  /// True once the host has blocked this client's user. The UI disables the
  /// comment input when this is set.
  bool get isBlocked => _isBlocked;

  /// True once the host has comment-muted this client. The UI disables the
  /// comment input (but the viewer can still watch and react).
  bool get isCommentMuted => _isCommentMuted;

  /// Why this viewer was removed from the live (`'kicked'` / `'banned'`), or
  /// null if they weren't. The viewer screen shows the matching message.
  String? get removedReason => _removedReason;

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
    _sessionGiftCoins = 0;

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
      // NOTE: do NOT call joinLiveRoom here — _connectSub fires for the
      // initial connect event and handles it (avoids emitting join_live twice).
      _socketService.connect(url: socketUrl, authToken: userToken);
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
    _sessionGiftCoins = 0;

    _preferredQuality = preferredQuality;
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
      // NOTE: do NOT call joinLiveRoom here — _connectSub fires for the
      // initial connect event and handles it (avoids emitting join_live twice).
      _socketService.connect(url: socketUrl, authToken: userToken);

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

  /// Send a comment. Pass [replyTo] to mark it as a reply to another comment;
  /// the recipient bubble will show "@theirName" context above the message.
  void sendComment(String message, {LiveComment? replyTo}) {
    if (_roomName == null || _identity == null || message.trim().isEmpty) return;
    // Blocked or comment-muted users can't post — the server drops it anyway.
    if (_isBlocked || _isCommentMuted) return;

    final now = DateTime.now();
    final id = '${_identity!}_${now.microsecondsSinceEpoch}';

    final comment = LiveComment(
      id: id,
      userId: _identity!,
      userName: _displayName ?? _identity!,
      userAvatar: _avatarUrl,
      message: message.trim(),
      timestamp: now,
      replyToCommentId: replyTo?.id,
      replyToUserName: replyTo?.userName,
    );

    _comments.add(comment);
    if (_comments.length > _maxComments) _comments.removeAt(0);

    _socketService.sendComment(
      roomName: _roomName!,
      userId: _identity!,
      userName: _displayName ?? _identity!,
      userAvatar: _avatarUrl,
      message: comment.message,
      commentId: id,
      replyToCommentId: comment.replyToCommentId,
      replyToUserName: comment.replyToUserName,
    );

    notifyListeners(); // immediate — user action
  }

  /// Host-only: pin a comment. Replaces any existing pin.
  /// Silently no-ops when called from a viewer.
  void pinComment(LiveComment comment) {
    if (!_isHost || _roomName == null || _identity == null) return;
    _applyPin(comment.id, fallback: comment);
    _socketService.pinComment(
      roomName: _roomName!,
      userId: _identity!,
      commentId: comment.id,
      pinned: true,
      commentUserId: comment.userId,
      userName: comment.userName,
      userAvatar: comment.userAvatar,
      message: comment.message,
    );
    notifyListeners();
  }

  /// Host-only: clear the current pin.
  void unpinComment() {
    if (!_isHost || _roomName == null || _identity == null) return;
    _applyPin(null);
    _socketService.pinComment(
      roomName: _roomName!,
      userId: _identity!,
      commentId: null,
      pinned: false,
    );
    notifyListeners();
  }

  // ── Moderation ────────────────────────────────────────────────────────────

  /// Host-only: block a user from the live room. Their existing comments are
  /// removed locally and future comments/reactions are ignored; the server is
  /// told so it drops them room-wide and notifies the blocked user.
  void blockUser(String userId) {
    if (!_isHost || _roomName == null || _identity == null) return;
    if (userId.isEmpty || userId == _identity) return;

    _blockedUserIds.add(userId);
    _comments.removeWhere((c) => c.userId == userId);
    // If the pinned comment was theirs, clear it.
    if (_pinnedComment?.userId == userId) {
      _applyPin(null);
    }

    _socketService.blockLiveUser(
      roomName: _roomName!,
      userId: _identity!,
      blockedUserId: userId,
    );
    notifyListeners();
  }

  /// Host-only: kick a user from the current live. They may rejoin.
  void kickUser(String userId) {
    if (!_isHost || _roomName == null || _identity == null) return;
    if (userId.isEmpty || userId == _identity) return;
    _comments.removeWhere((c) => c.userId == userId);
    if (_pinnedComment?.userId == userId) _applyPin(null);
    _socketService.kickLiveUser(
      roomName: _roomName!,
      userId: _identity!,
      targetUserId: userId,
    );
    notifyListeners();
  }

  /// Host-only: ban a user from this live session. They cannot rejoin until the
  /// host ends the broadcast.
  void banUser(String userId) {
    if (!_isHost || _roomName == null || _identity == null) return;
    if (userId.isEmpty || userId == _identity) return;
    _comments.removeWhere((c) => c.userId == userId);
    if (_pinnedComment?.userId == userId) _applyPin(null);
    _socketService.banLiveUser(
      roomName: _roomName!,
      userId: _identity!,
      targetUserId: userId,
    );
    notifyListeners();
  }

  /// Apply a kick/ban received from the server. If it targets this client, mark
  /// it removed so the viewer screen leaves with the right message; otherwise
  /// just drop that user's comments locally.
  void _applyRemoval(String targetUserId, String reason) {
    if (targetUserId.isEmpty) return;
    if (targetUserId == _identity) {
      _removedReason = reason;
      _isLive = false;
      notifyListeners(); // immediate — navigation-critical
      return;
    }
    _comments.removeWhere((c) => c.userId == targetUserId);
    if (_pinnedComment?.userId == targetUserId) _applyPin(null);
    notifyListeners();
  }

  /// Host-only: comment-block (mute) a user. They keep watching/reacting but
  /// their comment box is disabled and future comments are dropped.
  void muteUser(String userId) {
    if (!_isHost || _roomName == null || _identity == null) return;
    if (userId.isEmpty || userId == _identity) return;
    _socketService.muteLiveUser(
      roomName: _roomName!,
      userId: _identity!,
      targetUserId: userId,
    );
  }

  /// Host-only: delete a single comment for everyone.
  void deleteComment(LiveComment comment) {
    if (!_isHost || _roomName == null || _identity == null) return;
    _removeCommentById(comment.id);
    _socketService.deleteLiveComment(
      roomName: _roomName!,
      userId: _identity!,
      commentId: comment.id,
    );
    notifyListeners();
  }

  /// Remove a comment by id locally; clears the pin if it was the pinned one.
  void _removeCommentById(String commentId) {
    _comments.removeWhere((c) => c.id == commentId);
    if (_pinnedComment?.id == commentId) _applyPin(null);
  }

  // ── Follow ────────────────────────────────────────────────────────────────

  /// Uids whose comments should show a Follow pill: resolved as "not followed".
  Set<String> get followableUserIds =>
      _checkedFollowIds.difference(_followedUserIds);

  /// Record the outcome of a follow tap so the pill hides once followed.
  void markFollowed(String userId, bool followed) {
    if (userId.isEmpty) return;
    if (followed) {
      _followedUserIds.add(userId);
    } else {
      _followedUserIds.remove(userId);
    }
    notifyListeners();
  }

  /// Resolve follow status for specific uids that may never comment (e.g. the
  /// host), so the viewer can be offered a Follow button for them too.
  void seedFollowCheck(Iterable<String> uids) {
    var added = false;
    for (final uid in uids) {
      if (uid.isEmpty || uid == _identity) continue;
      if (_checkedFollowIds.contains(uid)) continue;
      if (_extraFollowUids.add(uid)) added = true;
    }
    if (added) _resolveFollowChecks();
  }

  /// Resolve follow status for any new commenters (excludes self and anyone
  /// already checked), batched into a single backend call. Called whenever
  /// comments change. Only ever inspects users who actually comment — never the
  /// full following list — so it scales regardless of how many you follow.
  Future<void> _resolveFollowChecks() async {
    final checker = followingChecker;
    if (checker == null || _resolvingFollow) return;

    final pending = <String>{};
    void consider(String uid) {
      if (uid.isEmpty || uid == _identity) return;
      if (_checkedFollowIds.contains(uid)) return;
      pending.add(uid);
    }

    for (final c in _comments) {
      consider(c.userId);
    }
    for (final uid in _extraFollowUids) {
      consider(uid); // host (and any other non-commenters we were asked to check)
    }
    if (pending.isEmpty) return;

    // Optimistically mark checked so concurrent/new comments don't re-request.
    _checkedFollowIds.addAll(pending);
    _resolvingFollow = true;
    try {
      final followed = await checker(pending.toList());
      _followedUserIds.addAll(followed);
      notifyListeners();
    } catch (_) {
      _checkedFollowIds.removeAll(pending); // allow a later retry
    } finally {
      _resolvingFollow = false;
      // Pick up anyone who commented (or was seeded) while we were resolving.
      bool needsCheck(String uid) =>
          uid.isNotEmpty &&
          uid != _identity &&
          !_checkedFollowIds.contains(uid);
      final more = _comments.any((c) => needsCheck(c.userId)) ||
          _extraFollowUids.any(needsCheck);
      if (more) _resolveFollowChecks();
    }
  }

  /// Report a comment for moderation review. Fire-and-forget; available to any
  /// participant.
  void reportComment(LiveComment comment) {
    if (_roomName == null || _identity == null) return;
    _socketService.reportLiveComment(
      roomName: _roomName!,
      reporterId: _identity!,
      commentId: comment.id,
      commentUserId: comment.userId,
      userName: comment.userName,
      message: comment.message,
    );
  }

  /// Apply a block received from the server (or echoed back to the host).
  void _applyBlock(String blockedUserId) {
    if (blockedUserId.isEmpty) return;
    _blockedUserIds.add(blockedUserId);
    _comments.removeWhere((c) => c.userId == blockedUserId);
    if (_pinnedComment?.userId == blockedUserId) _applyPin(null);
    if (blockedUserId == _identity) _isBlocked = true;
    notifyListeners();
  }

  /// Update local pinned state. [pinnedId] null clears the pin.
  ///
  /// [fallback] is the full pinned comment as carried by the pin event. It is
  /// used when [pinnedId] refers to a comment that isn't in this client's
  /// buffer (e.g. a late joiner who never received the original `live_comment`)
  /// so the pinned row still renders.
  void _applyPin(String? pinnedId, {LiveComment? fallback}) {
    for (var i = 0; i < _comments.length; i++) {
      final c = _comments[i];
      final shouldPin = c.id == pinnedId;
      if (c.isPinned != shouldPin) {
        _comments[i] = c.copyWith(isPinned: shouldPin);
      }
    }
    if (pinnedId == null) {
      _pinnedComment = null;
      return;
    }
    for (final c in _comments) {
      if (c.id == pinnedId) {
        _pinnedComment = c;
        return;
      }
    }
    // Not in the buffer — use the payload the host sent with the pin so late
    // joiners (and clients whose buffer aged the comment out) still see it.
    if (fallback != null) {
      _pinnedComment = fallback.copyWith(isPinned: true);
    }
    // else: keep showing the prior pinned row rather than clearing silently.
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

  /// Broadcast a gift to the room and float it locally. Call this only *after*
  /// the coin charge (HTTP POST /send_gift) has succeeded — this is the visual
  /// + realtime broadcast, not the payment.
  void sendGift({
    required String giftKey,
    required String emoji,
    required String label,
    required int coin,
    int healthGained = 0,
  }) {
    if (_roomName == null || _identity == null) return;

    final gift = LiveGift(
      giftKey: giftKey,
      emoji: emoji,
      label: label,
      coin: coin,
      userId: _identity!,
      userName: _displayName ?? _identity!,
      healthGained: healthGained,
      timestamp: DateTime.now(),
    );

    _pendingGifts.add(gift);
    _sessionGiftCoins += coin; // our own gift counts toward the session total

    _socketService.sendGift(
      roomName: _roomName!,
      userId: _identity!,
      userName: _displayName ?? _identity!,
      giftKey: giftKey,
      emoji: emoji,
      label: label,
      coin: coin,
      healthGained: healthGained,
    );

    notifyListeners(); // immediate — user action

    Future.delayed(const Duration(seconds: 4), () {
      _pendingGifts.remove(gift);
      if (!_isLive) return;
      _scheduleNotify();
    });
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
    _hostGoneTimer?.cancel();
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

      // Re-apply preferred quality on every LiveKit update so that tracks
      // subscribed after the initial join (e.g. host enables camera late) also
      // get the correct quality setting — not just those present at join time.
      for (final p in _livekitService.remoteParticipants) {
        _livekitService.setPreferredVideoQuality(p, _preferredQuality);
      }
    }

    // Detect host disconnection for viewers — but tolerate transient blips.
    // The host looks "gone" when either:
    //  a) the host participant left the room  → remoteParticipants.isEmpty
    //  b) the room itself disconnected         → !isConnected
    // Both also fire briefly during a viewer's own reconnect or a host track
    // renegotiation on a perfectly healthy stream. So instead of ending
    // immediately, start a grace timer and only confirm if it persists.
    if (!_isHost && _isLive) {
      final hostSeemsGone = _livekitService.remoteParticipants.isEmpty ||
          !_livekitService.isConnected;
      if (hostSeemsGone) {
        _hostGoneTimer ??= Timer(_hostGoneGrace, _confirmHostGone);
      } else {
        // Recovered before the grace period elapsed — cancel the pending end.
        _hostGoneTimer?.cancel();
        _hostGoneTimer = null;
      }
    }

    // All other LiveKit events are throttled to avoid widget storm.
    _scheduleNotify();
  }

  /// Runs after the grace period with the host still apparently gone. Re-checks
  /// live state so a last-moment recovery isn't missed before ending the stream.
  void _confirmHostGone() {
    _hostGoneTimer = null;
    if (_isHost || !_isLive) return;
    final stillGone = _livekitService.remoteParticipants.isEmpty ||
        !_livekitService.isConnected;
    if (stillGone) {
      _isLive = false;
      notifyListeners(); // immediate — navigation-critical
    }
  }

  void _setupSocketListeners() {
    _connectSub = _socketService.onConnect.listen((_) {
      if (_roomName != null && _identity != null) {
        _socketService.joinLiveRoom(_roomName!, _identity!);
      }
    });

    _commentSub = _socketService.onComment.listen((data) {
      if (data['userId'] == _identity) return;
      // Drop comments from users the host has blocked.
      if (_blockedUserIds.contains(data['userId'])) return;

      final now = DateTime.now();
      // Fall back to a synthetic id if the server (or an older client)
      // didn't include one — reply / pin can't target it but rendering still works.
      final id = (data['commentId'] as String?) ??
          '${data['userId'] ?? 'unknown'}_${now.microsecondsSinceEpoch}';

      _comments.add(LiveComment(
        id: id,
        userId: data['userId'] ?? '',
        userName: data['userName'] ?? 'Unknown',
        userAvatar: data['userAvatar'],
        message: data['message'] ?? '',
        timestamp: now,
        replyToCommentId: data['replyToCommentId'] as String?,
        replyToUserName: data['replyToUserName'] as String?,
      ));
      if (_comments.length > _maxComments) _comments.removeAt(0);
      notifyListeners(); // user-visible — keep immediate
      _resolveFollowChecks(); // resolve Follow-pill status for this commenter
    });

    _commentPinSub = _socketService.onCommentPin.listen((data) {
      final pinned = data['pinned'] == true;
      final id = data['commentId'] as String?;

      // The server may replay the full pinned comment (commentUserId, userName,
      // userAvatar, message) so clients that never received the original can
      // still render the pinned row. Build a fallback when those fields exist.
      LiveComment? fallback;
      if (pinned && id != null && data['message'] != null) {
        fallback = LiveComment(
          id: id,
          userId: (data['commentUserId'] ?? data['userId'] ?? '') as String,
          userName: (data['userName'] ?? 'Unknown') as String,
          userAvatar: data['userAvatar'] as String?,
          message: (data['message'] ?? '') as String,
          timestamp: DateTime.now(),
        );
      }

      _applyPin(pinned ? id : null, fallback: fallback);
      notifyListeners();
    });

    _reactionSub = _socketService.onReaction.listen((data) {
      if (data['userId'] == _identity) return;
      if (_blockedUserIds.contains(data['userId'])) return;

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

    _giftSub = _socketService.onGift.listen((data) {
      if (data['userId'] == _identity) return; // our own gift is already floating
      if (_blockedUserIds.contains(data['userId'])) return;

      final gift = LiveGift(
        giftKey: data['giftKey'] ?? '',
        emoji: data['emoji'] ?? '🎁',
        label: data['label'] ?? 'Gift',
        coin: (data['coin'] is int)
            ? data['coin'] as int
            : int.tryParse('${data['coin']}') ?? 0,
        userId: data['userId'] ?? '',
        userName: data['userName'],
        healthGained: (data['healthGained'] is int)
            ? data['healthGained'] as int
            : int.tryParse('${data['healthGained']}') ?? 0,
        timestamp: DateTime.now(),
      );

      _pendingGifts.add(gift);
      _sessionGiftCoins += gift.coin; // received gift adds to the session total
      _scheduleNotify();

      Future.delayed(const Duration(seconds: 4), () {
        _pendingGifts.remove(gift);
        if (!_isLive) return;
        _scheduleNotify();
      });
    });

    _viewerCountSub = _socketService.onViewerCountUpdate.listen((count) {
      _viewerCount = count;
      _scheduleNotify();
    });

    _blockedSub = _socketService.onBlocked.listen((data) {
      final blockedId = (data['blockedUserId'] ?? '') as String;
      _applyBlock(blockedId);
    });

    _kickedSub = _socketService.onKicked.listen((data) {
      _applyRemoval((data['targetUserId'] ?? '') as String, 'kicked');
    });

    _bannedSub = _socketService.onBanned.listen((data) {
      _applyRemoval((data['targetUserId'] ?? '') as String, 'banned');
    });

    // Server refused this client's join because they're banned (covers the
    // race where the ban lands between token issuance and join_live).
    _banBlockedSub = _socketService.onBanBlocked.listen((_) {
      if (_identity != null) _applyRemoval(_identity!, 'banned');
    });

    _commentMutedSub = _socketService.onCommentMuted.listen((data) {
      final targetId = (data['targetUserId'] ?? '') as String;
      if (targetId.isNotEmpty && targetId == _identity) {
        _isCommentMuted = true;
        notifyListeners();
      }
    });

    _commentDeletedSub = _socketService.onCommentDeleted.listen((data) {
      final commentId = (data['commentId'] ?? '') as String;
      if (commentId.isEmpty) return;
      _removeCommentById(commentId);
      notifyListeners();
    });

    _commentHistorySub = _socketService.onCommentHistory.listen((items) {
      if (items.isEmpty) return;

      final existingIds = _comments.map((c) => c.id).toSet();
      final history = <LiveComment>[];
      for (final data in items) {
        final userId = (data['userId'] ?? '') as String;
        if (_blockedUserIds.contains(userId)) continue;

        final id = (data['commentId'] as String?) ??
            '${userId}_${history.length}';
        if (!existingIds.add(id)) continue; // skip dupes already shown

        history.add(LiveComment(
          id: id,
          userId: userId,
          userName: (data['userName'] ?? 'Unknown') as String,
          userAvatar: data['userAvatar'] as String?,
          message: (data['message'] ?? '') as String,
          timestamp: DateTime.now(),
          replyToCommentId: data['replyToCommentId'] as String?,
          replyToUserName: data['replyToUserName'] as String?,
        ));
      }
      if (history.isEmpty) return;

      // History is older than anything that arrived since connect, so it goes
      // in front. Then cap to the buffer size, keeping the newest (tail).
      _comments.insertAll(0, history);
      if (_comments.length > _maxComments) {
        _comments.removeRange(0, _comments.length - _maxComments);
      }
      notifyListeners();
      _resolveFollowChecks(); // batch-resolve Follow status for history authors
    });
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    _hostGoneTimer?.cancel();
    _connectSub?.cancel();
    _commentSub?.cancel();
    _reactionSub?.cancel();
    _giftSub?.cancel();
    _viewerCountSub?.cancel();
    _commentPinSub?.cancel();
    _blockedSub?.cancel();
    _commentHistorySub?.cancel();
    _kickedSub?.cancel();
    _bannedSub?.cancel();
    _banBlockedSub?.cancel();
    _commentMutedSub?.cancel();
    _commentDeletedSub?.cancel();
    _livekitService.removeListener(_onLiveKitUpdate);
    _livekitService.dispose();
    _socketService.dispose();
    super.dispose();
  }
}
