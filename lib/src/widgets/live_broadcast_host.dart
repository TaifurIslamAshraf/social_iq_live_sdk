import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../controllers/live_controller.dart';
import '../services/api_service.dart';
import '../theme/sdk_theme.dart';
import 'comment_overlay.dart';
import 'reaction_animation.dart';

/// Full-screen live broadcast host screen.
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

  const LiveBroadcastHost({
    super.key,
    required this.userToken,
    required this.identity,
    required this.displayName,
    this.avatarUrl,
    this.title,
    this.onLiveEnded,
  });

  @override
  State<LiveBroadcastHost> createState() => _LiveBroadcastHostState();
}

class _LiveBroadcastHostState extends State<LiveBroadcastHost> {
  late final LiveController _controller;
  DateTime? _startTime;

  @override
  void initState() {
    super.initState();
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
    } catch (e) {
      if (mounted) {
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
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End', style: TextStyle(color: SdkTheme.primaryRed)),
          ),
        ],
      ),
    );
    if (result == true) _endStream();
  }

  @override
  void dispose() {
    _controller.removeListener(_onUpdate);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomPadding = mediaQuery.padding.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera preview (full screen)
          if (_controller.livekitService.localParticipant != null)
            Positioned.fill(
              child: _LocalVideoView(
                participant: _controller.livekitService.localParticipant!,
              ),
            ),

          // If camera is off, show avatar
          if (_controller.isCameraOff)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 50,
                    backgroundColor: SdkTheme.primaryPink.withValues(alpha: 0.3),
                    backgroundImage: widget.avatarUrl != null
                        ? NetworkImage(widget.avatarUrl!)
                        : null,
                    child: widget.avatarUrl == null
                        ? Text(
                            widget.displayName[0].toUpperCase(),
                            style: const TextStyle(
                              fontSize: 36,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Camera Off',
                    style: SdkTheme.bodyMedium.copyWith(color: Colors.white54),
                  ),
                ],
              ),
            ),

          // Top bar
          Positioned(
            top: mediaQuery.padding.top + 8,
            left: 12,
            right: 12,
            child: Row(
              children: [
                // LIVE badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: SdkTheme.liveGradient,
                    borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text('LIVE', style: SdkTheme.labelBold),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Viewer count
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.visibility, color: Colors.white, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        '${_controller.viewerCount}',
                        style: SdkTheme.labelBold,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // Close button
                GestureDetector(
                  onTap: _confirmEnd,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, color: Colors.white, size: 22),
                  ),
                ),
              ],
            ),
          ),

          // Reaction animations (right side)
          Positioned(
            right: 8,
            bottom: 160 + bottomPadding,
            child: ReactionAnimation(reactions: _controller.pendingReactions),
          ),

          // Comments overlay
          Positioned(
            left: 0,
            right: 80,
            bottom: 100 + bottomPadding,
            child: CommentOverlay(comments: _controller.comments),
          ),

          // Bottom controls
          Positioned(
            left: 12,
            right: 12,
            bottom: 20 + bottomPadding,
            child: Row(
              children: [
                // Flip camera
                _ControlButton(
                  icon: Icons.flip_camera_ios_rounded,
                  onTap: _controller.switchCamera,
                ),
                const SizedBox(width: 12),
                // Mute toggle
                _ControlButton(
                  icon: _controller.isMuted ? Icons.mic_off : Icons.mic,
                  isActive: _controller.isMuted,
                  onTap: _controller.toggleMute,
                ),
                const SizedBox(width: 12),
                // Camera toggle
                _ControlButton(
                  icon: _controller.isCameraOff
                      ? Icons.videocam_off
                      : Icons.videocam,
                  isActive: _controller.isCameraOff,
                  onTap: _controller.toggleCamera,
                ),
                const Spacer(),
                // End stream button
                GestureDetector(
                  onTap: _confirmEnd,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: SdkTheme.endCallRed,
                      borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
                    ),
                    child: const Text('END', style: SdkTheme.labelBold),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper widget to render local video.
class _LocalVideoView extends StatelessWidget {
  final LocalParticipant participant;

  const _LocalVideoView({required this.participant});

  @override
  Widget build(BuildContext context) {
    final videoTrack = participant.videoTrackPublications.firstOrNull?.track;
    if (videoTrack == null) {
      return const SizedBox.shrink();
    }
    return VideoTrackRenderer(videoTrack as VideoTrack);
  }
}

/// Circular control button used in bottom bars.
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
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.white.withValues(alpha: 0.3)
              : Colors.black.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}

/// Config holder (set during SDK init).
class SocialIqLiveSdkConfig {
  static String serverUrl = '';
  static String socketUrl = '';
  static String apiBaseUrl = '';
}
