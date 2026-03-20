import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../controllers/call_controller.dart';
import '../models/call_config.dart';
import '../services/api_service.dart';
import '../theme/sdk_theme.dart';
import 'live_broadcast_host.dart' show SocialIqLiveSdkConfig;

/// Group call screen with adaptive grid layout.
///
/// Usage:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => GroupCallScreen(
///     userToken: authToken,
///     identity: myUserId,
///     roomName: 'group_roomId',
///     displayName: 'My Name',
///     onCallEnded: (duration) { },
///   ),
/// ));
/// ```
class GroupCallScreen extends StatefulWidget {
  final String userToken;
  final String identity;
  final String displayName;
  final String? avatarUrl;
  final String roomName;
  final ValueChanged<Duration>? onCallEnded;

  const GroupCallScreen({
    super.key,
    required this.userToken,
    required this.identity,
    required this.displayName,
    this.avatarUrl,
    required this.roomName,
    this.onCallEnded,
  });

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  late final CallController _controller;

  @override
  void initState() {
    super.initState();
    _controller = CallController(
      apiService: ApiService(baseUrl: SocialIqLiveSdkConfig.apiBaseUrl),
    );
    _controller.addListener(_onUpdate);
    _joinCall();
  }

  Future<void> _joinCall() async {
    try {
      await _controller.joinGroupCall(
        userToken: widget.userToken,
        identity: widget.identity,
        roomName: widget.roomName,
        livekitUrl: SocialIqLiveSdkConfig.serverUrl,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to join group call: $e'),
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
    final localParticipant = _controller.livekitService.localParticipant;

    return Scaffold(
      backgroundColor: SdkTheme.backgroundDark,
      body: Stack(
        children: [
          // Participant grid
          Positioned(
            top: mediaQuery.padding.top + 60,
            left: 8,
            right: 8,
            bottom: 120 + bottomPadding,
            child: _buildParticipantGrid(localParticipant, remoteParticipants),
          ),

          // Top bar
          Positioned(
            top: mediaQuery.padding.top + 8,
            left: 12,
            right: 12,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.group, color: Colors.white, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        'Group Call • ${_controller.participantCount}',
                        style: SdkTheme.labelBold,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (_controller.callState == CallState.connected)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(SdkTheme.radiusRound),
                    ),
                    child: Text(
                      _controller.formattedDuration,
                      style: SdkTheme.labelBold,
                    ),
                  ),
              ],
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
                _GroupControlButton(
                  icon: _controller.isMuted ? Icons.mic_off : Icons.mic,
                  label: _controller.isMuted ? 'Unmute' : 'Mute',
                  isActive: _controller.isMuted,
                  onTap: _controller.toggleMute,
                ),
                _GroupControlButton(
                  icon: _controller.isCameraOff
                      ? Icons.videocam_off
                      : Icons.videocam,
                  label: 'Camera',
                  isActive: _controller.isCameraOff,
                  onTap: _controller.toggleCamera,
                ),
                _GroupControlButton(
                  icon: Icons.flip_camera_ios,
                  label: 'Flip',
                  onTap: _controller.switchCamera,
                ),
                _GroupControlButton(
                  icon: _controller.isSpeakerOn
                      ? Icons.volume_up
                      : Icons.volume_down,
                  label: 'Speaker',
                  isActive: _controller.isSpeakerOn,
                  onTap: _controller.toggleSpeaker,
                ),
                _GroupControlButton(
                  icon: Icons.call_end,
                  label: 'Leave',
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

  Widget _buildParticipantGrid(
    LocalParticipant? localParticipant,
    List<RemoteParticipant> remoteParticipants,
  ) {
    final totalCount = (localParticipant != null ? 1 : 0) + remoteParticipants.length;

    if (totalCount == 0) {
      return const Center(
        child: Text(
          'Waiting for participants...',
          style: TextStyle(color: Colors.white54, fontSize: 16),
        ),
      );
    }

    // Determine grid layout
    int crossAxisCount;
    if (totalCount <= 1) {
      crossAxisCount = 1;
    } else if (totalCount <= 4) {
      crossAxisCount = 2;
    } else {
      crossAxisCount = 3;
    }

    return GridView.builder(
      physics: const BouncingScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: totalCount <= 2 ? 0.75 : 0.85,
      ),
      itemCount: totalCount,
      itemBuilder: (context, index) {
        if (index == 0 && localParticipant != null) {
          return _ParticipantTile(
            participant: localParticipant,
            isLocal: true,
            name: widget.displayName,
          );
        }

        final remoteIndex = localParticipant != null ? index - 1 : index;
        if (remoteIndex < remoteParticipants.length) {
          final remote = remoteParticipants[remoteIndex];
          return _ParticipantTile(
            participant: remote,
            isLocal: false,
            name: remote.name,
          );
        }

        return const SizedBox.shrink();
      },
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  final Participant participant;
  final bool isLocal;
  final String name;

  const _ParticipantTile({
    required this.participant,
    required this.isLocal,
    required this.name,
  });

  @override
  Widget build(BuildContext context) {
    final videoTrack = participant.videoTrackPublications.firstOrNull?.track;

    return ClipRRect(
      borderRadius: BorderRadius.circular(SdkTheme.radiusMedium),
      child: Container(
        color: const Color(0xFF2A2A3E),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video or avatar
            if (videoTrack != null)
              VideoTrackRenderer(videoTrack as VideoTrack)
            else
              Center(
                child: CircleAvatar(
                  radius: 30,
                  backgroundColor: SdkTheme.primaryPink.withValues(alpha: 0.25),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

            // Name badge
            Positioned(
              bottom: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(SdkTheme.radiusSmall),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLocal) ...[
                      const Text('You', style: TextStyle(color: SdkTheme.primaryPink, fontSize: 11, fontWeight: FontWeight.w600)),
                    ] else ...[
                      Text(
                        name,
                        style: const TextStyle(color: Colors.white, fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Mute indicator
            if (participant.isMuted)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.mic_off, color: SdkTheme.endCallRed, size: 14),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GroupControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  final Color? backgroundColor;

  const _GroupControlButton({
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
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: backgroundColor ??
                  (isActive
                      ? Colors.white.withValues(alpha: 0.25)
                      : Colors.white.withValues(alpha: 0.1)),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
