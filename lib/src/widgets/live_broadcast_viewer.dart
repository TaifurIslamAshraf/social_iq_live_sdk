import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
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

  // Double-tap-to-react: position of the last tap and the live heart pops.
  Offset? _lastTapPos;
  final List<Widget> _heartBursts = [];
  int _heartSeq = 0;

  @override
  void initState() {
    super.initState();
    // Keep the screen awake while watching so it doesn't sleep on the system
    // display timeout (the viewer path previously had no wakelock at all).
    WakelockPlus.enable();
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
      if (!mounted) return;
      setState(() => _isConnecting = false);

      // A 403 from the token endpoint means the host banned this viewer from the
      // live — show the server's message prominently instead of a generic error.
      final isBan = e is ApiException && e.statusCode == 403;
      final message = e is ApiException ? e.message : 'Failed to join live';

      if (isBan) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: SdkTheme.backgroundDark,
            title: const Text('Banned', style: TextStyle(color: Colors.white)),
            content: Text(message,
                style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK',
                    style: TextStyle(color: SdkTheme.primaryRed)),
              ),
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message),
              backgroundColor: SdkTheme.endCallRed),
        );
      }
      if (mounted) Navigator.of(context).pop();
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

  void _onDoubleTapReact() {
    // Blocked viewers and the pre-join state can't react.
    if (_controller.isBlocked || _isConnecting) return;

    _controller.sendReaction('❤️');

    final pos = _lastTapPos;
    if (pos == null) return;

    final key = ValueKey('heart_${_heartSeq++}');
    late final Widget heart;
    heart = _TapHeart(
      key: key,
      position: pos,
      onDone: () {
        if (!mounted) return;
        setState(() => _heartBursts.removeWhere((w) => w.key == key));
      },
    );
    setState(() => _heartBursts.add(heart));
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

  // ── Removed/ended overlay copy — depends on why the viewer is leaving ──────
  IconData get _removedOverlayIcon {
    switch (_controller.removedReason) {
      case 'banned':
        return Icons.gavel;
      case 'kicked':
        return Icons.logout;
      default:
        return Icons.live_tv;
    }
  }

  String get _removedOverlayTitle {
    switch (_controller.removedReason) {
      case 'banned':
        return 'Banned from live';
      case 'kicked':
        return 'Removed from live';
      default:
        return 'Live has ended';
    }
  }

  String get _removedOverlayBody {
    switch (_controller.removedReason) {
      case 'banned':
        return "You've been banned from this live by the host";
      case 'kicked':
        return 'The host removed you from this live';
      default:
        return 'The host has ended the broadcast';
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
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

          // ── Double-tap to react ────────────────────────────────────────
          // Full-screen gesture layer just above the video. It sits below the
          // top bar / comment input (added later in the Stack) so those still
          // receive their own taps. A double-tap sends a ❤️ and pops a heart
          // at the tap point (TikTok/Facebook-live style).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTapDown: (d) => _lastTapPos = d.localPosition,
              onDoubleTap: _onDoubleTapReact,
            ),
          ),

          // Floating hearts spawned by double-taps.
          ..._heartBursts,

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
            child: CommentOverlay(
              comments: _controller.comments,
              pinnedComment: _controller.pinnedComment,
            ),
          ),

          // ── Bottom: comment input + reaction bar ───────────────────────
          Positioned(
            left: 12,
            right: 12,
            bottom: 16 + bottomPad,
            child: _controller.isBlocked
                ? const _BlockedNotice()
                : Column(
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
                                color:
                                    SdkTheme.primaryRed.withValues(alpha: 0.9),
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

          // ── Live ended / removed overlay ───────────────────────────────
          // Shown when the host ends the broadcast, or when this viewer is
          // kicked/banned, so they get feedback instead of a black screen.
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
                        child: Icon(_removedOverlayIcon,
                            color: Colors.white, size: 36),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _removedOverlayTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _removedOverlayBody,
                        textAlign: TextAlign.center,
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

/// A single heart that pops at the double-tap point, drifts up while scaling and
/// fading, then removes itself via [onDone]. Purely visual feedback — the actual
/// reaction is broadcast separately through the controller.
class _TapHeart extends StatefulWidget {
  final Offset position;
  final VoidCallback onDone;

  const _TapHeart({super.key, required this.position, required this.onDone});

  @override
  State<_TapHeart> createState() => _TapHeartState();
}

class _TapHeartState extends State<_TapHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;
  late final Animation<double> _rise;
  // Small random horizontal drift + tilt so repeated taps don't stack identically.
  late final double _drift;
  late final double _tilt;

  @override
  void initState() {
    super.initState();
    _drift = (widget.position.dx % 7 - 3) * 6.0;
    _tilt = (widget.position.dx % 5 - 2) * 0.06;
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.4, end: 1.3), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 1.0), weight: 70),
    ]).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut));
    _opacity = Tween(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _c, curve: const Interval(0.5, 1.0)),
    );
    _rise = Tween(begin: 0.0, end: -90.0).animate(
      CurvedAnimation(parent: _c, curve: Curves.easeOut),
    );
    _c.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        return Positioned(
          left: widget.position.dx - 24 + _drift,
          top: widget.position.dy - 24 + _rise.value,
          child: Opacity(
            opacity: _opacity.value,
            child: Transform.rotate(
              angle: _tilt,
              child: Transform.scale(
                scale: _scale.value,
                child: const Icon(Icons.favorite,
                    color: SdkTheme.primaryRed, size: 48),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Replaces the comment input for a viewer the host has blocked.
class _BlockedNotice extends StatelessWidget {
  const _BlockedNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(SdkTheme.radiusXL),
        border: Border.all(
          color: SdkTheme.primaryRed.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.block, color: Colors.white70, size: 16),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              "You've been blocked by the host",
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
