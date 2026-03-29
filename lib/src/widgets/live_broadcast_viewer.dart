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
  });

  @override
  State<LiveBroadcastViewer> createState() => _LiveBroadcastViewerState();
}

class _LiveBroadcastViewerState extends State<LiveBroadcastViewer> {
  late final LiveController _controller;
  bool _showReactionBar = false;
  bool _hasNavigatedAway = false;

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
      );
    } catch (e) {
      if (mounted) {
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

  /// Safely navigate away exactly once, deferred to after the current frame.
  void _navigateAway() {
    if (_hasNavigatedAway) return;
    _hasNavigatedAway = true;
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

    // If host disconnected, navigate viewer away after the frame
    if (!_controller.isLive) {
      _navigateAway();
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
    final mediaQuery = MediaQuery.of(context);
    final bottomPadding = mediaQuery.padding.bottom;
    final remoteParticipants = _controller.livekitService.remoteParticipants;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Host video (full screen)
          if (remoteParticipants.isNotEmpty)
            Positioned.fill(
              child: _RemoteVideoView(
                participant: remoteParticipants.first,
              ),
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: SdkTheme.primaryPink.withValues(alpha: 0.3),
                    backgroundImage: widget.hostAvatar != null
                        ? NetworkImage(widget.hostAvatar!)
                        : null,
                    child: widget.hostAvatar == null
                        ? const Icon(Icons.person, color: Colors.white, size: 40)
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Waiting for host...',
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
                // Host info
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundImage: widget.hostAvatar != null
                            ? NetworkImage(widget.hostAvatar!)
                            : null,
                        child: widget.hostAvatar == null
                            ? const Icon(Icons.person, size: 14, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        widget.hostName ?? 'Host',
                        style: SdkTheme.labelBold,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // LIVE badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: SdkTheme.liveGradient,
                    borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
                  ),
                  child: const Text('LIVE', style: SdkTheme.labelBold),
                ),
                const SizedBox(width: 8),
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
                      const Icon(Icons.visibility, color: Colors.white, size: 14),
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
                  onTap: _leaveStream,
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

          // Reaction animation (right side)
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

          // Bottom area: comment input + reaction button
          Positioned(
            left: 12,
            right: 12,
            bottom: 16 + bottomPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Reaction bar (toggle)
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
                    // Comment input
                    Expanded(
                      child: CommentInput(
                        onSubmit: _controller.sendComment,
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Reaction toggle
                    GestureDetector(
                      onTap: () {
                        setState(() => _showReactionBar = !_showReactionBar);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: SdkTheme.primaryRed.withValues(alpha: 0.9),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.favorite,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper widget to render remote video.
class _RemoteVideoView extends StatelessWidget {
  final RemoteParticipant participant;

  const _RemoteVideoView({required this.participant});

  @override
  Widget build(BuildContext context) {
    final videoTrack = participant.videoTrackPublications.firstOrNull?.track;
    if (videoTrack == null) {
      return Container(
        color: SdkTheme.backgroundDark,
        child: const Center(
          child: Icon(Icons.videocam_off, color: Colors.white38, size: 48),
        ),
      );
    }
    return VideoTrackRenderer(videoTrack as VideoTrack);
  }
}
