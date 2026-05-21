import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../controllers/live_controller.dart';
import '../services/api_service.dart';
import '../theme/sdk_theme.dart';
import 'comment_overlay.dart';
import 'reaction_animation.dart';
import 'live_broadcast_host.dart' show SocialIqLiveSdkConfig;

/// Full-screen live broadcast viewer screen.
///
/// Performance optimisations for low-resource VPS:
///  - Subscribes at [VideoQuality.MEDIUM] by default so the server does not
///    need to route the full-bitrate simulcast layer to every viewer.
///  - [RepaintBoundary] around the remote video texture prevents video repaints
///    from invalidating the comment/reaction overlay widgets.
///  - [VideoRenderMode.auto] prefers hardware decode on mobile.
///
/// Usage:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => LiveBroadcastViewer(
///     userToken: authToken,
///     identity: userId,
///     displayName: userName,
///     roomName: 'live_hostUserId',
///     hostName: 'Host Name',
///     hostAvatar: 'https://...',
///     onLiveEnded: () => Navigator.pop(context),
///   ),
/// ));
/// ```
class LiveBroadcastViewer extends StatefulWidget {
  final String userToken;
  final String identity;
  final String displayName;
  final String? avatarUrl;
  final String roomName;
  final String? hostName;
  final String? hostAvatar;
  final VoidCallback? onLiveEnded;

  /// Called once the viewer has successfully joined the live stream.
  final VoidCallback? onLiveViewStarted;

  /// Called when the viewer leaves the stream — either by pressing the close
  /// button or because the host ended the broadcast.
  final VoidCallback? onLiveViewLeave;

  /// Override the default subscription quality.
  /// Use [VideoQuality.LOW] on very slow connections to save server bandwidth.
  final VideoQuality preferredQuality;

  const LiveBroadcastViewer({
    super.key,
    required this.userToken,
    required this.identity,
    required this.displayName,
    this.avatarUrl,
    required this.roomName,
    this.hostName,
    this.hostAvatar,
    this.onLiveEnded,
    this.onLiveViewStarted,
    this.onLiveViewLeave,
    this.preferredQuality = VideoQuality.MEDIUM, // ← reduced default
  });

  @override
  State<LiveBroadcastViewer> createState() => _LiveBroadcastViewerState();
}

class _LiveBroadcastViewerState extends State<LiveBroadcastViewer> {
  late final LiveController _controller;
  bool _showReactionBar = false;
  bool _hasNavigatedAway = false;
  bool _liveEnded = false; // true once host ends stream; shows overlay before pop
  bool _isConnecting = true; // true while WebRTC handshake is in progress

  @override
  void initState() {
    super.initState();
    _controller = LiveController(
      apiService: ApiService(baseUrl: SocialIqLiveSdkConfig.apiBaseUrl),
    );
    _controller.addListener(_onUpdate);
    _joinStream();
  }

  Future<void> _joinStream() async {
    try {
      await _controller.joinAsViewer(
        userToken: widget.userToken,
        identity: widget.identity,
        displayName: widget.displayName,
        avatarUrl: widget.avatarUrl,
        roomName: widget.roomName,
        livekitUrl: SocialIqLiveSdkConfig.serverUrl,
        socketUrl: SocialIqLiveSdkConfig.socketUrl,
        preferredQuality: widget.preferredQuality,
      );
      if (mounted) setState(() => _isConnecting = false);
      widget.onLiveViewStarted?.call();
    } catch (e) {
      if (mounted) {
        setState(() => _isConnecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to join live: $e'),
            backgroundColor: SdkTheme.endCallRed,
          ),
        );
        Navigator.of(context).pop();
      }
    }
  }

  void _navigateAway() {
    if (_hasNavigatedAway) return;
    _hasNavigatedAway = true;
    widget.onLiveViewLeave?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onLiveEnded?.call();
        Navigator.of(context).pop();
      }
    });
  }

  void _onUpdate() {
    if (!mounted) return;
    setState(() {});
    // When the host ends the stream, show the "Live has ended" overlay for
    // 2 seconds so the viewer sees feedback instead of a sudden black screen,
    // then navigate away.
    if (!_controller.isLive && !_liveEnded && !_hasNavigatedAway) {
      setState(() => _liveEnded = true);
      Future.delayed(const Duration(seconds: 2), _navigateAway);
    }
  }

  Future<void> _leaveStream() async {
    await _controller.stopBroadcast();
    _navigateAway();
  }

  @override
  void dispose() {
    _controller.removeListener(_onUpdate);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottomPad = mq.padding.bottom;
    final remoteParticipants = _controller.livekitService.remoteParticipants;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _leaveStream();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Host video ─────────────────────────────────────────────────
          // RepaintBoundary keeps video texture repaints isolated from the
          // overlay widgets (comments, reactions, top bar) so they don't
          // trigger unnecessary re-renders when video frames arrive.
          if (remoteParticipants.isNotEmpty)
            Positioned.fill(
              child: RepaintBoundary(
                child: _RemoteVideoView(
                  participant: remoteParticipants.first,
                ),
              ),
            )
          else if (_isConnecting)
            // Shown while the WebRTC handshake is in progress.
            // LiveKit first tries UDP (50000-60000); if those ports are
            // firewalled it falls back to TCP after ~10-12 s.  The spinner
            // makes this wait visible so it doesn't look like a crash.
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white70),
                  SizedBox(height: 16),
                  Text(
                    'Connecting...',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ],
              ),
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundColor:
                        SdkTheme.primaryPink.withValues(alpha: 0.3),
                    backgroundImage: widget.hostAvatar != null
                        ? NetworkImage(widget.hostAvatar!)
                        : null,
                    child: widget.hostAvatar == null
                        ? const Icon(Icons.person,
                            color: Colors.white, size: 40)
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Waiting for host...',
                    style: SdkTheme.bodyMedium
                        .copyWith(color: Colors.white54),
                  ),
                ],
              ),
            ),

          // ── Top scrim ──────────────────────────────────────────────────
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(child: _ViewerTopScrim()),
          ),

          // ── Bottom scrim ───────────────────────────────────────────────
          const Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(child: _ViewerBottomScrim()),
          ),

          // ── Top bar ────────────────────────────────────────────────────
          Positioned(
            top: mq.padding.top + 10,
            left: 12,
            right: 12,
            child: Row(
              children: [
                _ViewerHostChip(
                  avatarUrl: widget.hostAvatar,
                  displayName: widget.hostName ?? 'Host',
                ),
                const SizedBox(width: 8),
                const _ViewerLivePill(),
                const SizedBox(width: 8),
                _ViewerGlassPill(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.remove_red_eye_outlined,
                          color: Colors.white, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        _formatViewerCount(_controller.viewerCount),
                        style: SdkTheme.labelBold,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                _ViewerCircleIconButton(
                  icon: Icons.close,
                  onTap: _leaveStream,
                ),
              ],
            ),
          ),

          // ── Reaction animations ────────────────────────────────────────
          Positioned(
            right: 8,
            bottom: 160 + bottomPad,
            child: ReactionAnimation(
                reactions: _controller.pendingReactions),
          ),

          // ── Comments overlay ───────────────────────────────────────────
          Positioned(
            left: 0,
            right: 80,
            bottom: 100 + bottomPad,
            child: CommentOverlay(comments: _controller.comments),
          ),

          // ── Bottom: comment input + reaction bar ───────────────────────
          Positioned(
            left: 12,
            right: 12,
            bottom: 16 + bottomPad,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_showReactionBar)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ReactionBar(
                      onReaction: (emoji) {
                        _controller.sendReaction(emoji);
                        setState(() => _showReactionBar = false);
                      },
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: CommentInput(
                        onSubmit: _controller.sendComment,
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () => setState(
                          () => _showReactionBar = !_showReactionBar),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: SdkTheme.primaryRed.withValues(alpha: 0.9),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.favorite,
                            color: Colors.white, size: 22),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Live ended overlay ─────────────────────────────────────────
          // Shown when the host ends the broadcast so the viewer always
          // sees feedback instead of a black screen while the pop animates.
          if (_liveEnded)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.75),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: const BoxDecoration(
                          color: SdkTheme.endCallRed,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.live_tv,
                            color: Colors.white, size: 36),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Live has ended',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'The host has ended the broadcast',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Remote video renderer
// ─────────────────────────────────────────────────────────────────────────────

/// Renders the host's video track received by the viewer.
///
/// [VideoRenderMode.auto] lets the platform use hardware-accelerated decode,
/// keeping video processing off the main isolate.
class _RemoteVideoView extends StatelessWidget {
  final RemoteParticipant participant;

  const _RemoteVideoView({required this.participant});

  @override
  Widget build(BuildContext context) {
    final videoTrack =
        participant.videoTrackPublications.firstOrNull?.track;

    if (videoTrack == null) {
      return Container(
        color: SdkTheme.backgroundDark,
        child: const Center(
          child: Icon(Icons.videocam_off, color: Colors.white38, size: 48),
        ),
      );
    }

    return VideoTrackRenderer(
      videoTrack as VideoTrack,
      renderMode: VideoRenderMode.auto,
      // Fill the viewport edge-to-edge; without `cover`, source aspect
      // mismatches with the device produce black letterbox bars.
      fit: VideoViewFit.cover,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Viewer-local UI atoms — kept private to the file so we don't leak overlay
// internals through the SDK barrel export.
// ─────────────────────────────────────────────────────────────────────────────

class _ViewerTopScrim extends StatelessWidget {
  const _ViewerTopScrim();
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 140,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.55), Colors.transparent],
        ),
      ),
    );
  }
}

class _ViewerBottomScrim extends StatelessWidget {
  const _ViewerBottomScrim();
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 260,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.65), Colors.transparent],
        ),
      ),
    );
  }
}

class _ViewerGlassPill extends StatelessWidget {
  final Widget child;
  const _ViewerGlassPill({required this.child});
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

class _ViewerHostChip extends StatelessWidget {
  final String? avatarUrl;
  final String displayName;
  const _ViewerHostChip(
      {required this.avatarUrl, required this.displayName});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 150),
      child: _ViewerGlassPill(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: SdkTheme.primaryPink.withValues(alpha: 0.3),
              backgroundImage:
                  avatarUrl != null ? NetworkImage(avatarUrl!) : null,
              child: avatarUrl == null
                  ? Text(
                      displayName.isNotEmpty
                          ? displayName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
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

class _ViewerLivePill extends StatefulWidget {
  const _ViewerLivePill();
  @override
  State<_ViewerLivePill> createState() => _ViewerLivePillState();
}

class _ViewerLivePillState extends State<_ViewerLivePill>
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

class _ViewerCircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ViewerCircleIconButton({required this.icon, required this.onTap});

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

String _formatViewerCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final v = n / 1000.0;
    return '${v.toStringAsFixed(v >= 10 ? 0 : 1)}K';
  }
  final v = n / 1000000.0;
  return '${v.toStringAsFixed(v >= 10 ? 0 : 1)}M';
}
