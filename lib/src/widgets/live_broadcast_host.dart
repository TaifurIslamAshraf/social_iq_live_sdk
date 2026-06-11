import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../controllers/live_controller.dart';
import '../models/live_config.dart';
import '../services/api_service.dart';
import '../theme/sdk_theme.dart';
import 'comment_overlay.dart';
import 'live_avatar.dart';
import 'reaction_animation.dart';
import 'gift_animation.dart';

/// Full-screen live broadcast host screen.
///
/// Performance optimisations for low-resource VPS:
///  - [RepaintBoundary] around the video layer prevents GPU repaints from
///    propagating into the UI overlay layer and vice-versa.
///  - [VideoViewMirrorMode.mirror] gives the host a natural selfie preview
///    without extra CPU-side flipping.
///  - [VideoRenderMode.auto] lets the platform pick hardware decode.
///
/// Usage:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => LiveBroadcastHost(
///     userToken: authToken,
///     identity: userId,
///     displayName: userName,
///     avatarUrl: userAvatar,
///     title: 'My Live Stream',
///     onLiveEnded: (duration) { },
///   ),
/// ));
/// ```
class LiveBroadcastHost extends StatefulWidget {
  final String userToken;
  final String identity;
  final String displayName;
  final String? avatarUrl;
  final String? title;
  final ValueChanged<Duration>? onLiveEnded;

  /// Called once the live broadcast has successfully started.
  final VoidCallback? onLiveStarted;

  /// Follow a commenter. The app performs the actual follow and returns true if
  /// the current user now follows [userId]. When provided, a Follow pill appears
  /// on other users' comments.
  final Future<bool> Function(String userId)? onFollowUser;

  const LiveBroadcastHost({
    super.key,
    required this.userToken,
    required this.identity,
    required this.displayName,
    this.avatarUrl,
    this.title,
    this.onLiveEnded,
    this.onLiveStarted,
    this.onFollowUser,
  });

  @override
  State<LiveBroadcastHost> createState() => _LiveBroadcastHostState();
}

class _LiveBroadcastHostState extends State<LiveBroadcastHost> {
  late final LiveController _controller;
  DateTime? _startTime;
  bool _isConnecting = true; // true while WebRTC handshake is in progress
  LiveComment? _replyingTo;

  /// Users followed during this session — their Follow pill is hidden.
  final Set<String> _followedUserIds = {};

  Future<void> _handleFollow(LiveComment comment) async {
    final cb = widget.onFollowUser;
    if (cb == null) return;
    final nowFollowing = await cb(comment.userId);
    if (!mounted) return;
    setState(() {
      if (nowFollowing) {
        _followedUserIds.add(comment.userId);
      } else {
        _followedUserIds.remove(comment.userId);
      }
    });
    _showSnack(nowFollowing
        ? 'Following ${comment.userName}'
        : 'Unfollowed ${comment.userName}');
  }

  @override
  void initState() {
    super.initState();
    // Keep the screen awake for the whole broadcast so it never sleeps on the
    // system display timeout. Managed here (not by the host app) so it's
    // guaranteed on every device.
    WakelockPlus.enable();
    _controller = LiveController(
      apiService: ApiService(baseUrl: SocialIqLiveSdkConfig.apiBaseUrl),
    );
    _controller.addListener(_onUpdate);
    _startBroadcast();
  }

  Future<void> _startBroadcast() async {
    try {
      await _controller.startBroadcast(
        userToken: widget.userToken,
        identity: widget.identity,
        displayName: widget.displayName,
        avatarUrl: widget.avatarUrl,
        title: widget.title,
        livekitUrl: SocialIqLiveSdkConfig.serverUrl,
        socketUrl: SocialIqLiveSdkConfig.socketUrl,
      );
      _startTime = DateTime.now();
      if (mounted) setState(() => _isConnecting = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isConnecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start live: $e'),
            backgroundColor: SdkTheme.endCallRed,
          ),
        );
        Navigator.of(context).pop();
      }
    }
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _endStream() async {
    final duration = _startTime != null
        ? DateTime.now().difference(_startTime!)
        : Duration.zero;
    await _controller.stopBroadcast();
    widget.onLiveEnded?.call(duration);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmEnd() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SdkTheme.backgroundDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SdkTheme.radiusMedium),
        ),
        title: const Text('End Live?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to end this live broadcast?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End',
                style: TextStyle(color: SdkTheme.primaryRed)),
          ),
        ],
      ),
    );
    if (result == true) _endStream();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _controller.removeListener(_onUpdate);
    _controller.dispose();
    super.dispose();
  }

  void _sendCommentFromInput(String text) {
    _controller.sendComment(text, replyTo: _replyingTo);
    if (_replyingTo != null) {
      setState(() => _replyingTo = null);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottomPad = mq.padding.bottom;
    final keyboard = mq.viewInsets.bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmEnd();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // ── Camera preview ─────────────────────────────────────────────
          // RepaintBoundary isolates the video texture repaints from the
          // overlay widgets. Without this, every video frame invalidates
          // the entire Stack, causing unnecessary UI redraws.
          if (_isConnecting)
            // Shown while the WebRTC handshake is in progress.
            // LiveKit first tries UDP (50000-60000); if those ports are
            // firewalled it falls back to TCP after ~10-12 s.
            const Positioned.fill(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white70),
                    SizedBox(height: 16),
                    Text(
                      'Starting broadcast...',
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                  ],
                ),
              ),
            )
          else if (_controller.livekitService.localParticipant != null)
            Positioned.fill(
              child: RepaintBoundary(
                child: _LocalVideoView(
                  participant: _controller.livekitService.localParticipant!,
                  isFrontCamera: _controller.livekitService.isFrontCamera,
                ),
              ),
            ),

          // Camera-off fallback
          if (!_isConnecting && _controller.isCameraOff)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LiveAvatar(
                    radius: 50,
                    imageUrl: widget.avatarUrl,
                    name: widget.displayName,
                    fontSize: 36,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Camera Off',
                    style:
                        SdkTheme.bodyMedium.copyWith(color: Colors.white54),
                  ),
                ],
              ),
            ),

          // ── Top scrim (legibility) ─────────────────────────────────────
          // A subtle dark gradient under the top bar so white text and
          // controls stay readable over bright camera frames.
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(child: _TopScrim()),
          ),

          // ── Bottom scrim (legibility) ──────────────────────────────────
          const Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(child: _BottomScrim()),
          ),

          // ── Top bar ────────────────────────────────────────────────────
          Positioned(
            top: mq.padding.top + 10,
            left: 12,
            right: 12,
            child: Row(
              children: [
                // Host identity chip (avatar + display name)
                _HostChip(
                  avatarUrl: widget.avatarUrl,
                  displayName: widget.displayName,
                ),
                const SizedBox(width: 8),
                // LIVE badge with pulsing dot
                const _LivePill(),
                const SizedBox(width: 8),
                // Viewer count
                _GlassPill(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.remove_red_eye_outlined,
                          color: Colors.white, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        _formatCount(_controller.viewerCount),
                        style: SdkTheme.labelBold,
                      ),
                    ],
                  ),
                ),
                if (_controller.sessionGiftCoins > 0) ...[
                  const SizedBox(width: 8),
                  // Gift coins received this session (gross value)
                  _GlassPill(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.monetization_on,
                            color: Colors.amber, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          _formatCount(_controller.sessionGiftCoins),
                          style: SdkTheme.labelBold,
                        ),
                      ],
                    ),
                  ),
                ],
                const Spacer(),
                // Close button
                _CircleIconButton(
                  icon: Icons.close,
                  onTap: _confirmEnd,
                ),
              ],
            ),
          ),

          // Pinned comment now renders as a sticky row at the top of the
          // comment section below (Facebook-live style), not as a separate
          // floating banner.

          // ── Reaction animations ────────────────────────────────────────
          Positioned(
            right: 8,
            bottom: 200 + bottomPad + keyboard,
            child: ReactionAnimation(
                reactions: _controller.pendingReactions),
          ),

          // ── Gift animations ────────────────────────────────────────────
          Positioned(
            left: 8,
            bottom: 200 + bottomPad + keyboard,
            child: GiftAnimation(gifts: _controller.pendingGifts),
          ),

          // ── Comments overlay ───────────────────────────────────────────
          Positioned(
            left: 0,
            right: 80,
            bottom: 140 + bottomPad + keyboard,
            child: CommentOverlay(
              comments: _controller.comments,
              isHost: true,
              pinnedComment: _controller.pinnedComment,
              currentUserId: widget.identity,
              followedUserIds: _followedUserIds,
              onFollow: widget.onFollowUser != null ? _handleFollow : null,
              onReply: (c) => setState(() => _replyingTo = c),
              onPin: _controller.pinComment,
              onUnpin: _controller.unpinComment,
              onBlock: (c) {
                _controller.blockUser(c.userId);
                _showSnack('${c.userName} blocked');
              },
              onReport: (c) {
                _controller.reportComment(c);
                _showSnack('Comment reported');
              },
              onKick: (c) {
                _controller.kickUser(c.userId);
                _showSnack('${c.userName} removed from live');
              },
              onBan: (c) {
                _controller.banUser(c.userId);
                _showSnack('${c.userName} banned from this live');
              },
              onMute: (c) {
                _controller.muteUser(c.userId);
                _showSnack("${c.userName}'s comments blocked");
              },
              onDelete: (c) {
                _controller.deleteComment(c);
                _showSnack('Comment deleted');
              },
            ),
          ),

          // ── Bottom: comment input + controls ──────────────────────────
          Positioned(
            left: 12,
            right: 12,
            bottom: 16 + bottomPad + keyboard,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CommentInput(
                  onSubmit: _sendCommentFromInput,
                  replyingTo: _replyingTo,
                  onCancelReply: () => setState(() => _replyingTo = null),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _ControlButton(
                      icon: Icons.flip_camera_ios_rounded,
                      onTap: _controller.switchCamera,
                    ),
                    const SizedBox(width: 12),
                    _ControlButton(
                      icon: _controller.isMuted ? Icons.mic_off : Icons.mic,
                      isActive: _controller.isMuted,
                      onTap: _controller.toggleMute,
                    ),
                    const Spacer(),
                    _EndLiveButton(onTap: _confirmEnd),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Local video renderer
// ─────────────────────────────────────────────────────────────────────────────

/// Renders the host's own camera track.
///
/// [VideoViewMirrorMode.mirror] flips the image horizontally for a natural
/// selfie view — this is done in the GPU pipeline so it costs essentially zero
/// extra CPU compared to software flipping.
///
/// [VideoRenderMode.auto] tells the platform renderer to prefer hardware decode
/// (VideoToolbox on iOS, MediaCodec on Android), which keeps video decoding
/// off the main thread.
class _LocalVideoView extends StatelessWidget {
  final LocalParticipant participant;

  /// Mirror only for front camera — back camera must not be flipped.
  final bool isFrontCamera;

  const _LocalVideoView({
    required this.participant,
    required this.isFrontCamera,
  });

  @override
  Widget build(BuildContext context) {
    final videoTrack =
        participant.videoTrackPublications.firstOrNull?.track;
    if (videoTrack == null) return const SizedBox.shrink();

    return VideoTrackRenderer(
      videoTrack as VideoTrack,
      mirrorMode: isFrontCamera
          ? VideoViewMirrorMode.mirror
          : VideoViewMirrorMode.off,
      renderMode: VideoRenderMode.auto,
      // Fill the screen edge-to-edge regardless of source aspect ratio.
      // Without this, a 16:9 camera feed letterboxes on a 9:19 phone.
      fit: VideoViewFit.cover,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Control button
// ─────────────────────────────────────────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;

  const _ControlButton({
    required this.icon,
    required this.onTap,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: isActive
              ? Colors.white.withValues(alpha: 0.28)
              : Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top / bottom scrims — keep overlays legible over bright video.
// ─────────────────────────────────────────────────────────────────────────────

class _TopScrim extends StatelessWidget {
  const _TopScrim();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 140,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.55),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}

class _BottomScrim extends StatelessWidget {
  const _BottomScrim();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 260,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.65),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top bar pieces
// ─────────────────────────────────────────────────────────────────────────────

class _GlassPill extends StatelessWidget {
  final Widget child;
  const _GlassPill({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 1,
        ),
      ),
      child: child,
    );
  }
}

class _HostChip extends StatelessWidget {
  final String? avatarUrl;
  final String displayName;
  const _HostChip({required this.avatarUrl, required this.displayName});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: _GlassPill(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LiveAvatar(
              radius: 12,
              imageUrl: avatarUrl,
              name: displayName,
              fontSize: 11,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                displayName,
                style: SdkTheme.labelBold,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// LIVE pill with a softly pulsing white dot — signals to the host that the
/// stream is actually transmitting (helps catch silent freezes during testing).
class _LivePill extends StatefulWidget {
  const _LivePill();

  @override
  State<_LivePill> createState() => _LivePillState();
}

class _LivePillState extends State<_LivePill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        gradient: SdkTheme.liveGradient,
        borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
        boxShadow: [
          BoxShadow(
            color: SdkTheme.primaryRed.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
            child: Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 6),
          const Text('LIVE', style: SdkTheme.labelBold),
        ],
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}

class _EndLiveButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EndLiveButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [SdkTheme.primaryRed, SdkTheme.endCallRed],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
          boxShadow: [
            BoxShadow(
              color: SdkTheme.primaryRed.withValues(alpha: 0.45),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.stop_rounded, color: Colors.white, size: 18),
            SizedBox(width: 6),
            Text('END', style: SdkTheme.labelBold),
          ],
        ),
      ),
    );
  }
}

/// Compact-format viewer count: 1.2K, 3.4M, etc.
String _formatCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final v = n / 1000.0;
    return '${v.toStringAsFixed(v >= 10 ? 0 : 1)}K';
  }
  final v = n / 1000000.0;
  return '${v.toStringAsFixed(v >= 10 ? 0 : 1)}M';
}

// ─────────────────────────────────────────────────────────────────────────────
// SDK config holder
// ─────────────────────────────────────────────────────────────────────────────

class SocialIqLiveSdkConfig {
  static String serverUrl = '';
  static String socketUrl = '';
  static String apiBaseUrl = '';
}
