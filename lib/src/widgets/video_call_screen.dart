import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../controllers/call_controller.dart';
import '../models/call_config.dart';
import '../services/api_service.dart';
import '../theme/sdk_theme.dart';
import 'live_broadcast_host.dart' show SocialIqLiveSdkConfig;

/// 1:1 Video call screen.
///
/// Usage:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => VideoCallScreen(
///     userToken: authToken,
///     callerId: myUserId,
///     receiverId: otherUserId,
///     receiverName: 'John',
///     receiverAvatar: 'https://...',
///     onCallEnded: (duration) { },
///   ),
/// ));
/// ```
class VideoCallScreen extends StatefulWidget {
  final String userToken;
  final String callerId;
  final String receiverId;
  final String? receiverName;
  final String? receiverAvatar;
  final String? roomName;
  final ValueChanged<Duration>? onCallEnded;

  /// Set true if answering an incoming call.
  final bool isIncoming;
  final String? incomingCallerName;

  const VideoCallScreen({
    super.key,
    required this.userToken,
    required this.callerId,
    required this.receiverId,
    this.receiverName,
    this.receiverAvatar,
    this.roomName,
    this.onCallEnded,
    this.isIncoming = false,
    this.incomingCallerName,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  late final CallController _controller;

  @override
  void initState() {
    super.initState();
    _controller = CallController(
      apiService: ApiService(baseUrl: SocialIqLiveSdkConfig.apiBaseUrl),
    );
    _controller.addListener(_onUpdate);
    _startCall();
  }

  Future<void> _startCall() async {
    try {
      final room = widget.roomName ?? 'call_${widget.callerId}_${widget.receiverId}';

      if (widget.isIncoming) {
        await _controller.answerCall(
          userToken: widget.userToken,
          receiverId: widget.callerId,
          callerId: widget.receiverId,
          roomName: room,
          callType: CallType.video,
          livekitUrl: SocialIqLiveSdkConfig.serverUrl,
          socketUrl: SocialIqLiveSdkConfig.socketUrl,
          callerName: widget.incomingCallerName,
          callerAvatar: widget.receiverAvatar,
        );
      } else {
        await _controller.startCall(
          userToken: widget.userToken,
          callerId: widget.callerId,
          receiverId: widget.receiverId,
          roomName: room,
          callType: CallType.video,
          livekitUrl: SocialIqLiveSdkConfig.serverUrl,
          socketUrl: SocialIqLiveSdkConfig.socketUrl,
          receiverName: widget.receiverName,
          receiverAvatar: widget.receiverAvatar,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to connect: $e'),
            backgroundColor: SdkTheme.endCallRed,
          ),
        );
        Navigator.of(context).pop();
      }
    }
  }

  void _onUpdate() {
    if (!mounted) return;
    setState(() {});
    // Auto-pop when the remote party ends the call
    if (_controller.callState == CallState.ended) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  Future<void> _endCall() async {
    final duration = _controller.callDuration;
    await _controller.endCall();
    widget.onCallEnded?.call(duration);
    if (mounted) Navigator.of(context).pop();
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
      backgroundColor: SdkTheme.backgroundDark,
      body: Stack(
        children: [
          // Remote video (full screen)
          if (remoteParticipants.isNotEmpty)
            Positioned.fill(
              child: _buildRemoteVideo(remoteParticipants.first),
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Avatar with pulse animation
                  _PulsingAvatar(
                    avatarUrl: widget.receiverAvatar,
                    name: widget.receiverName ?? 'Calling...',
                  ),
                  const SizedBox(height: 20),
                  Text(
                    widget.receiverName ?? 'Unknown',
                    style: SdkTheme.headingBold,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _controller.callState == CallState.connecting
                        ? 'Connecting...'
                        : 'Calling...',
                    style: SdkTheme.bodyMedium.copyWith(color: Colors.white54),
                  ),
                ],
              ),
            ),

          // Local video (PiP - top right corner)
          if (_controller.livekitService.localParticipant != null &&
              !_controller.isCameraOff)
            Positioned(
              top: mediaQuery.padding.top + 12,
              right: 12,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(SdkTheme.radiusMedium),
                child: SizedBox(
                  width: 120,
                  height: 160,
                  child: _buildLocalVideo(),
                ),
              ),
            ),

          // Top bar - call duration
          if (_controller.callState == CallState.connected)
            Positioned(
              top: mediaQuery.padding.top + 12,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
                  ),
                  child: Text(
                    _controller.formattedDuration,
                    style: SdkTheme.labelBold,
                  ),
                ),
              ),
            ),

          // Bottom controls
          Positioned(
            left: 0,
            right: 0,
            bottom: 32 + bottomPadding,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _CallControlButton(
                  icon: _controller.isMuted ? Icons.mic_off : Icons.mic,
                  label: _controller.isMuted ? 'Unmute' : 'Mute',
                  isActive: _controller.isMuted,
                  onTap: _controller.toggleMute,
                ),
                _CallControlButton(
                  icon: _controller.isCameraOff
                      ? Icons.videocam_off
                      : Icons.videocam,
                  label: 'Camera',
                  isActive: _controller.isCameraOff,
                  onTap: _controller.toggleCamera,
                ),
                _CallControlButton(
                  icon: Icons.flip_camera_ios,
                  label: 'Flip',
                  onTap: _controller.switchCamera,
                ),
                _CallControlButton(
                  icon: Icons.call_end,
                  label: 'End',
                  backgroundColor: SdkTheme.endCallRed,
                  onTap: _endCall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteVideo(RemoteParticipant participant) {
    final videoTrack = participant.videoTrackPublications.firstOrNull?.track;
    if (videoTrack == null) {
      return Container(
        color: SdkTheme.backgroundDark,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 50,
                backgroundImage: widget.receiverAvatar != null
                    ? NetworkImage(widget.receiverAvatar!)
                    : null,
                child: widget.receiverAvatar == null
                    ? const Icon(Icons.person, size: 50, color: Colors.white)
                    : null,
              ),
              const SizedBox(height: 12),
              Text(
                widget.receiverName ?? '',
                style: SdkTheme.headingBold,
              ),
              const SizedBox(height: 4),
              const Text(
                'Camera Off',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
    return VideoTrackRenderer(videoTrack as VideoTrack);
  }

  Widget _buildLocalVideo() {
    final localParticipant = _controller.livekitService.localParticipant;
    final videoTrack = localParticipant?.videoTrackPublications.firstOrNull?.track;
    if (videoTrack == null) return const SizedBox.shrink();
    return VideoTrackRenderer(videoTrack as VideoTrack);
  }
}

/// Audio call screen with gradient background and centered avatar.
class _PulsingAvatar extends StatefulWidget {
  final String? avatarUrl;
  final String name;

  const _PulsingAvatar({this.avatarUrl, required this.name});

  @override
  State<_PulsingAvatar> createState() => _PulsingAvatarState();
}

class _PulsingAvatarState extends State<_PulsingAvatar>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: SdkTheme.primaryRed.withValues(alpha: 0.3 * _scaleAnimation.value),
                  blurRadius: 30,
                  spreadRadius: 10,
                ),
              ],
            ),
            child: CircleAvatar(
              radius: 60,
              backgroundColor: SdkTheme.primaryPink.withValues(alpha: 0.3),
              backgroundImage: widget.avatarUrl != null
                  ? NetworkImage(widget.avatarUrl!)
                  : null,
              child: widget.avatarUrl == null
                  ? Text(
                      widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?',
                      style: const TextStyle(
                        fontSize: 40,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
          ),
        );
      },
    );
  }
}

/// Call control button.
class _CallControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  final Color? backgroundColor;

  const _CallControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isActive = false,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: backgroundColor ??
                  (isActive
                      ? Colors.white.withValues(alpha: 0.25)
                      : Colors.white.withValues(alpha: 0.12)),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
