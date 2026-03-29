import 'package:flutter/material.dart';
import '../models/call_config.dart';
import '../theme/sdk_theme.dart';

/// Incoming call screen with accept/decline buttons.
///
/// Usage:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => IncomingCallScreen(
///     callerName: 'John Doe',
///     callerAvatar: 'https://...',
///     callType: CallType.video,
///     onAccept: () {
///       // Navigate to VideoCallScreen / AudioCallScreen
///     },
///     onDecline: () {
///       Navigator.pop(context);
///     },
///   ),
/// ));
/// ```
class IncomingCallScreen extends StatefulWidget {
  final String callerName;
  final String? callerAvatar;
  final CallType callType;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const IncomingCallScreen({
    super.key,
    required this.callerName,
    this.callerAvatar,
    required this.callType,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _ringController;
  late Animation<double> _ringAnimation;

  @override
  void initState() {
    super.initState();

    // Avatar pulse
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Ring ripple
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _ringAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ringController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _ringController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: SdkTheme.callGradient),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 60),

              // Call type label
              Text(
                widget.callType == CallType.video
                    ? 'Incoming Video Call'
                    : widget.callType == CallType.group
                        ? 'Incoming Group Call'
                        : 'Incoming Audio Call',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                ),
              ),

              const Spacer(flex: 2),

              // Avatar with ripple effect
              SizedBox(
                width: 200,
                height: 200,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Ripple rings
                    AnimatedBuilder(
                      animation: _ringAnimation,
                      builder: (context, child) {
                        return Container(
                          width: 160 + (40 * _ringAnimation.value),
                          height: 160 + (40 * _ringAnimation.value),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: SdkTheme.primaryRed.withValues(
                                alpha: 0.4 * (1 - _ringAnimation.value),
                              ),
                              width: 2,
                            ),
                          ),
                        );
                      },
                    ),
                    AnimatedBuilder(
                      animation: _ringAnimation,
                      builder: (context, child) {
                        final delayed = (_ringAnimation.value + 0.5) % 1.0;
                        return Container(
                          width: 160 + (40 * delayed),
                          height: 160 + (40 * delayed),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: SdkTheme.primaryRed.withValues(
                                alpha: 0.3 * (1 - delayed),
                              ),
                              width: 1.5,
                            ),
                          ),
                        );
                      },
                    ),
                    // Avatar
                    AnimatedBuilder(
                      animation: _pulseAnimation,
                      builder: (context, child) {
                        return Transform.scale(
                          scale: _pulseAnimation.value,
                          child: CircleAvatar(
                            radius: 65,
                            backgroundColor:
                                SdkTheme.primaryPink.withValues(alpha: 0.3),
                            backgroundImage: widget.callerAvatar != null
                                ? NetworkImage(widget.callerAvatar!)
                                : null,
                            child: widget.callerAvatar == null
                                ? Text(
                                    widget.callerName.isNotEmpty
                                        ? widget.callerName[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                      fontSize: 44,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  )
                                : null,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // Caller name
              Text(
                widget.callerName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),

              const Spacer(flex: 3),

              // Accept / Decline buttons
              Padding(
                padding: EdgeInsets.only(
                  bottom: 50 + bottomPadding,
                  left: 40,
                  right: 40,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    // Decline
                    _IncomingCallButton(
                      icon: Icons.call_end,
                      label: 'Decline',
                      color: SdkTheme.endCallRed,
                      onTap: widget.onDecline,
                    ),
                    // Accept
                    _IncomingCallButton(
                      icon: widget.callType == CallType.video
                          ? Icons.videocam
                          : Icons.call,
                      label: 'Accept',
                      color: SdkTheme.acceptGreen,
                      onTap: widget.onAccept,
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

class _IncomingCallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _IncomingCallButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
