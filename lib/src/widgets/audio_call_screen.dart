import 'package:flutter/material.dart';
import '../controllers/call_controller.dart';
import '../models/call_config.dart';
import '../services/api_service.dart';
import '../theme/sdk_theme.dart';
import 'live_broadcast_host.dart' show SocialIqLiveSdkConfig;

/// 1:1 Audio call screen with gradient background and centered avatar.
///
/// Usage:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => AudioCallScreen(
///     userToken: authToken,
///     callerId: myUserId,
///     receiverId: otherUserId,
///     receiverName: 'John',
///     receiverAvatar: 'https://...',
///     onCallEnded: (duration) { },
///   ),
/// ));
/// ```
class AudioCallScreen extends StatefulWidget {
  final String userToken;
  final String callerId;
  final String receiverId;
  final String? receiverName;
  final String? receiverAvatar;
  final String? roomName;
  final ValueChanged<Duration>? onCallEnded;
  final bool isIncoming;

  const AudioCallScreen({
    super.key,
    required this.userToken,
    required this.callerId,
    required this.receiverId,
    this.receiverName,
    this.receiverAvatar,
    this.roomName,
    this.onCallEnded,
    this.isIncoming = false,
  });

  @override
  State<AudioCallScreen> createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends State<AudioCallScreen>
    with SingleTickerProviderStateMixin {
  late final CallController _controller;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _controller = CallController(
      apiService: ApiService(baseUrl: SocialIqLiveSdkConfig.apiBaseUrl),
    );
    _controller.addListener(_onUpdate);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _startCall().then((_) {
      // Default speaker ON for audio calls so voice is immediately audible
      _controller.setSpeakerEnabled(true);
    });
  }

  Future<void> _startCall() async {
    try {
      final room = widget.roomName ?? 'call_${widget.callerId}_${widget.receiverId}';

      if (widget.isIncoming) {
        // isIncoming=true: this device IS the receiver.
        // widget.callerId  = the person who called us (the original caller)
        // widget.receiverId = us (receiver of the call)
        await _controller.answerCall(
          userToken: widget.userToken,
          callerId: widget.callerId,   // original caller's ID
          receiverId: widget.receiverId, // our own ID
          roomName: room,
          callType: CallType.audio,
          livekitUrl: SocialIqLiveSdkConfig.serverUrl,
          socketUrl: SocialIqLiveSdkConfig.socketUrl,
          callerName: widget.receiverName,
          callerAvatar: widget.receiverAvatar,
        );
      } else {
        await _controller.startCall(
          userToken: widget.userToken,
          callerId: widget.callerId,
          receiverId: widget.receiverId,
          roomName: room,
          callType: CallType.audio,
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
    _pulseController.dispose();
    _controller.removeListener(_onUpdate);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomPadding = mediaQuery.padding.bottom;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: SdkTheme.audioCallGradient),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 40),

              // Call status
              Text(
                _controller.callState == CallState.connected
                    ? _controller.formattedDuration
                    : _controller.callState == CallState.connecting
                        ? 'Connecting...'
                        : 'Calling...',
                style: SdkTheme.bodyMedium.copyWith(
                  color: Colors.white70,
                  fontSize: 16,
                ),
              ),

              const Spacer(flex: 2),

              // Avatar with pulse effect
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: SdkTheme.primaryRed
                              .withValues(alpha: 0.2 * _pulseAnimation.value),
                          blurRadius: 40 * _pulseAnimation.value,
                          spreadRadius: 15 * _pulseAnimation.value,
                        ),
                      ],
                    ),
                    child: CircleAvatar(
                      radius: 70,
                      backgroundColor: SdkTheme.primaryPink.withValues(alpha: 0.3),
                      backgroundImage: widget.receiverAvatar != null
                          ? NetworkImage(widget.receiverAvatar!)
                          : null,
                      child: widget.receiverAvatar == null
                          ? Text(
                              (widget.receiverName ?? '?')[0].toUpperCase(),
                              style: const TextStyle(
                                fontSize: 48,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    ),
                  );
                },
              ),

              const SizedBox(height: 24),

              // Name
              Text(
                widget.receiverName ?? 'Unknown',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Audio Call',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
              ),

              const Spacer(flex: 3),

              // Bottom controls
              Padding(
                padding: EdgeInsets.only(bottom: 40 + bottomPadding),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _AudioControlButton(
                      icon: _controller.isMuted ? Icons.mic_off : Icons.mic,
                      label: _controller.isMuted ? 'Unmute' : 'Mute',
                      isActive: _controller.isMuted,
                      onTap: _controller.toggleMute,
                    ),
                    _AudioControlButton(
                      icon: _controller.isSpeakerOn
                          ? Icons.volume_up
                          : Icons.volume_down,
                      label: 'Speaker',
                      isActive: _controller.isSpeakerOn,
                      onTap: _controller.toggleSpeaker,
                    ),
                    _AudioControlButton(
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
        ),
      ),
    );
  }
}

class _AudioControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  final Color? backgroundColor;

  const _AudioControlButton({
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
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: backgroundColor ??
                  (isActive
                      ? Colors.white.withValues(alpha: 0.25)
                      : Colors.white.withValues(alpha: 0.1)),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.15),
                width: 1,
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
