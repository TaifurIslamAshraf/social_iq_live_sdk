import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/call_controller.dart';
import '../models/call_config.dart';
import '../services/api_service.dart';
import '../services/call_foreground_service.dart';
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
  final String? callerName;
  final String? callerAvatar;
  final String? receiverName;
  final String? receiverAvatar;
  final String? roomName;
  final ValueChanged<Duration>? onCallEnded;

  /// Called once when the call begins connecting (offer sent / answer initiated).
  final VoidCallback? onCallStarted;

  /// Called once when both sides are in the LiveKit room and media flows.
  final VoidCallback? onCallConnected;

  final bool isIncoming;

  /// Optional pre-warmed controller from [CallController.prepareToAnswer].
  /// When provided the call connects almost instantly instead of waiting for
  /// a fresh token fetch and LiveKit handshake.
  final CallController? controller;

  /// Show a persistent "Tap to return to call" notification with a Hang Up
  /// button while the call is active. Keeps the audio alive when the user
  /// navigates away.
  ///
  /// Requires foreground-service permissions in AndroidManifest.xml —
  /// see [CallForegroundService] for the required XML snippet.
  final bool enableForegroundService;

  const AudioCallScreen({
    super.key,
    required this.userToken,
    required this.callerId,
    required this.receiverId,
    this.callerName,
    this.callerAvatar,
    this.receiverName,
    this.receiverAvatar,
    this.roomName,
    this.onCallEnded,
    this.onCallStarted,
    this.onCallConnected,
    this.isIncoming = false,
    this.controller,
    this.enableForegroundService = false,
  });

  @override
  State<AudioCallScreen> createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends State<AudioCallScreen>
    with SingleTickerProviderStateMixin {
  late final CallController _controller;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _startedFired = false;
  bool _connectedFired = false;
  bool _fgStarted = false;
  bool _disposed = false;
  bool _callEnded = false;
  String? _lastNotificationText;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ??
        CallController(
          apiService: ApiService(baseUrl: SocialIqLiveSdkConfig.apiBaseUrl),
        );
    _controller.addListener(_onUpdate);
    if (widget.enableForegroundService) CallForegroundService.init();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _startCall();
  }

  Future<void> _startCall() async {
    try {
      final room = widget.roomName ?? _deterministicRoom(widget.callerId, widget.receiverId);

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
          callerName: widget.callerName ?? widget.receiverName,
          callerAvatar: widget.callerAvatar ?? widget.receiverAvatar,
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
          callerName: widget.callerName,
          callerAvatar: widget.callerAvatar,
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

    final state = _controller.callState;

    if (!_startedFired && state == CallState.connecting) {
      _startedFired = true;
      widget.onCallStarted?.call();
    }

    if (!_connectedFired && state == CallState.connected) {
      _connectedFired = true;
      widget.onCallConnected?.call();
    }

    // Start the FG service the moment the call begins so the ringing phase
    // is covered (matches the "Tap to return to call • Calling…" screenshot).
    if (!_fgStarted &&
        (state == CallState.connecting || state == CallState.connected)) {
      _fgStarted = true;
      final initialText = state == CallState.connected
          ? _controller.formattedDuration
          : 'Tap to return to call • Calling…';
      if (widget.enableForegroundService) {
        CallForegroundService.start(
          callerName: _displayName(),
          callType: 'Audio call',
          statusText: initialText,
          onHangUp: _safeHangUp,
        );
      }
      _lastNotificationText = initialText;
    }

    // Dedup notification updates — _onUpdate fires on mute / speaker / etc.
    if (_fgStarted && widget.enableForegroundService) {
      final nextText = state == CallState.connected
          ? _controller.formattedDuration
          : 'Tap to return to call • Calling…';
      if (nextText != _lastNotificationText) {
        _lastNotificationText = nextText;
        CallForegroundService.updateNotification(text: nextText);
      }
    }

    if (state == CallState.ended) {
      _stopForegroundService();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _closeScreen();
      });
    }
  }

  /// Invoked from the notification "Hang Up" button. Static callbacks can
  /// outlive this State, so guard against use-after-dispose.
  void _safeHangUp() {
    if (_disposed) return;
    _endCall();
  }

  void _stopForegroundService() {
    if (!_fgStarted) return;
    _fgStarted = false;
    if (widget.enableForegroundService) CallForegroundService.stop();
  }

  String _displayName() {
    if (widget.isIncoming) {
      // On the receiver side `receiverName` is *us*, never the caller.
      return widget.callerName ?? 'Unknown';
    }
    return widget.receiverName ?? 'Unknown';
  }

  /// Room name independent of caller/receiver order, so both sides agree
  /// on the same room regardless of who initiated the call.
  static String _deterministicRoom(String a, String b) {
    final ids = [a, b]..sort();
    return 'call_${ids[0]}_${ids[1]}';
  }

  Future<void> _endCall() async {
    if (_callEnded) return;
    _callEnded = true;
    final duration = _controller.callDuration;
    await _controller.endCall();
    widget.onCallEnded?.call(duration);
    _closeScreen();
  }

  /// Pop the call screen if there's a route below it; otherwise close the
  /// activity (sends the user back to their launcher). Without this fallback,
  /// calls opened directly from a push notification leave a black screen on
  /// hang-up because Navigator.pop has nothing to reveal.
  void _closeScreen() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopForegroundService();
    _pulseController.dispose();
    _controller.removeListener(_onUpdate);
    // Safety net: signal the server if the screen is torn down without an
    // explicit end. Fire-and-forget — dispose is sync.
    if (!_callEnded) {
      _callEnded = true;
      _controller.endCall();
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomPadding = mediaQuery.padding.bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Audio calls have no PiP — back press should end the call cleanly
        // (notifies the peer instead of silently disposing).
        if (mounted) await _endCall();
      },
      child: Scaffold(
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
