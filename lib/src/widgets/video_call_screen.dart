import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:floating/floating.dart';
import 'package:livekit_client/livekit_client.dart';
import '../controllers/call_controller.dart';
import '../models/call_config.dart';
import '../services/api_service.dart';
import '../services/call_foreground_service.dart';
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
  final String? callerName;
  final String? callerAvatar;
  final String? receiverName;
  final String? receiverAvatar;
  final String? roomName;
  final ValueChanged<Duration>? onCallEnded;

  /// Called once when the call begins connecting (socket registered, offer sent).
  final VoidCallback? onCallStarted;

  /// Called once when both sides are in the LiveKit room and media flows.
  final VoidCallback? onCallConnected;

  /// Set true if answering an incoming call.
  final bool isIncoming;
  final String? incomingCallerName;
  final String? incomingCallerAvatar;

  /// Optional pre-warmed controller from [CallController.prepareToAnswer].
  final CallController? controller;

  /// Show a persistent "Tap to return to call" notification with a Hang Up
  /// button while the call is active. Keeps the audio alive when the user
  /// navigates away.
  ///
  /// Requires foreground-service permissions in AndroidManifest.xml —
  /// see [CallForegroundService] for the required XML snippet.
  final bool enableForegroundService;

  /// Enable Android Picture-in-Picture (PiP) mode.
  ///
  /// When active the user can press the minimize button (↓) to shrink the
  /// call into a floating window. The app also auto-enters PiP when the user
  /// navigates home while a call is connected.
  ///
  /// Requires `android:supportsPictureInPicture="true"` on the Activity in
  /// AndroidManifest.xml. **iOS is not supported** — this flag is silently
  /// ignored on non-Android platforms.
  final bool enablePiP;

  /// Aspect ratio used when the app enters PiP mode. Defaults to portrait
  /// (9:16) which fits typical phone video. Use [Rational.landscape] for
  /// landscape video.
  final Rational pipAspectRatio;

  const VideoCallScreen({
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
    this.incomingCallerName,
    this.incomingCallerAvatar,
    this.controller,
    this.enableForegroundService = false,
    this.enablePiP = false,
    this.pipAspectRatio = const Rational(9, 16),
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  late final CallController _controller;
  final Floating _floating = Floating();
  bool _startedFired = false;
  bool _connectedFired = false;
  bool _fgStarted = false;
  bool _pipRegistered = false;
  bool _disposed = false;
  bool _callEnded = false;
  String? _lastNotificationText;

  /// PiP is Android-only — the `floating` package is a no-op elsewhere.
  bool get _pipEffective => widget.enablePiP && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ??
        CallController(
          apiService: ApiService(baseUrl: SocialIqLiveSdkConfig.apiBaseUrl),
        );
    _controller.addListener(_onUpdate);
    if (widget.enableForegroundService) CallForegroundService.init();
    _startCall();
  }

  Future<void> _startCall() async {
    try {
      final room = widget.roomName ??
          _deterministicRoom(widget.callerId, widget.receiverId);

      if (widget.isIncoming) {
        await _controller.answerCall(
          userToken: widget.userToken,
          callerId: widget.callerId,
          receiverId: widget.receiverId,
          roomName: room,
          callType: CallType.video,
          livekitUrl: SocialIqLiveSdkConfig.serverUrl,
          socketUrl: SocialIqLiveSdkConfig.socketUrl,
          callerName: widget.incomingCallerName,
          callerAvatar: widget.incomingCallerAvatar,
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

    // Start FG service as soon as the call begins (covers ringing phase).
    if (!_fgStarted &&
        (state == CallState.connecting || state == CallState.connected)) {
      _fgStarted = true;
      final initialText = state == CallState.connected
          ? _controller.formattedDuration
          : 'Tap to return to call • Calling…';
      if (widget.enableForegroundService) {
        CallForegroundService.start(
          callerName: _displayName(),
          callType: 'Video call',
          statusText: initialText,
          onHangUp: _safeHangUp,
        );
      }
      _lastNotificationText = initialText;
      if (_pipEffective && !_pipRegistered) {
        _pipRegistered = true;
        // Clear any stale auto-PiP from a previous screen first.
        _floating.cancelOnLeavePiP().then((_) {
          if (!_disposed) {
            _floating.enable(OnLeavePiP(aspectRatio: widget.pipAspectRatio));
          }
        });
      }
    }

    // Update the notification only when the text actually changes — _onUpdate
    // fires on mute / camera / participant changes too.
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
      _teardownBackgroundUi();
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

  void _teardownBackgroundUi() {
    if (_fgStarted) {
      _fgStarted = false;
      if (widget.enableForegroundService) CallForegroundService.stop();
    }
    if (_pipRegistered) {
      _pipRegistered = false;
      _floating.cancelOnLeavePiP();
    }
  }

  String _displayName() {
    if (widget.isIncoming) {
      // On the receiver side `receiverName` is *us*, never the caller.
      return widget.incomingCallerName ?? widget.callerName ?? 'Unknown';
    }
    return widget.receiverName ?? 'Unknown';
  }

  String? _displayAvatar() {
    if (widget.isIncoming) {
      return widget.incomingCallerAvatar ?? widget.callerAvatar;
    }
    return widget.receiverAvatar;
  }

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
    _teardownBackgroundUi();
    _controller.removeListener(_onUpdate);
    // Safety net: signal the server if the screen is torn down without an
    // explicit end (e.g. parent route popped). Fire-and-forget — dispose is
    // sync and the controller is about to be disposed anyway.
    if (!_callEnded) {
      _callEnded = true;
      _controller.endCall();
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = _pipEffective
        ? PiPSwitcher(
            floating: _floating,
            childWhenEnabled: _buildPiPContent(),
            childWhenDisabled: _buildFullScreen(context),
          )
        : _buildFullScreen(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_pipEffective) {
          final available = await _floating.isPipAvailable;
          final status = await _floating.enable(
            ImmediatePiP(aspectRatio: widget.pipAspectRatio),
          );
          debugPrint('[PiP] back-press: isPipAvailable=$available '
              'enable=$status');
          // PiP entered successfully — keep call alive in floating window.
          if (status == PiPStatus.enabled) return;
          // PiP unavailable (emulator, old Android, admin-disabled) — fall
          // through and end the call so the user isn't stuck on screen.
        }
        if (mounted) await _endCall();
      },
      child: screen,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PiP compact view (shown when the system shrinks the app window)
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildPiPContent() {
    final remoteParticipants = _controller.livekitService.remoteParticipants;
    final hasRemoteVideo = remoteParticipants.isNotEmpty &&
        remoteParticipants.first.videoTrackPublications.firstOrNull?.track
            is VideoTrack;

    if (hasRemoteVideo) {
      return Container(
        color: SdkTheme.backgroundDark,
        child: Stack(
          children: [
            Positioned.fill(
              child: VideoTrackRenderer(
                remoteParticipants
                    .first.videoTrackPublications.first.track as VideoTrack,
                fit: VideoViewFit.cover,
              ),
            ),
            Positioned(
              bottom: 4,
              left: 0,
              right: 0,
              child: Center(child: _pipStatusLabel()),
            ),
          ],
        ),
      );
    }
    return _CompactCallView(
      name: _displayName(),
      avatarUrl: _displayAvatar(),
      statusLabel: _pipStatusLabel(),
    );
  }

  Widget _pipStatusLabel() {
    final text = _controller.callState == CallState.connected
        ? _controller.formattedDuration
        : 'Calling…';
    return Text(
      text,
      style: const TextStyle(color: Colors.white70, fontSize: 10),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Full call screen
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildFullScreen(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomPadding = mediaQuery.padding.bottom;
    final remoteParticipants = _controller.livekitService.remoteParticipants;
    final avatarUrl = _displayAvatar();
    final name = _displayName();

    return Scaffold(
      backgroundColor: SdkTheme.backgroundDark,
      body: Stack(
        children: [
          if (remoteParticipants.isNotEmpty)
            Positioned.fill(
              child: _buildRemoteVideo(remoteParticipants.first),
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PulsingAvatar(avatarUrl: avatarUrl, name: name),
                  const SizedBox(height: 20),
                  Text(name, style: SdkTheme.headingBold),
                  const SizedBox(height: 8),
                  Text(
                    _controller.callState == CallState.connecting
                        ? 'Connecting...'
                        : 'Calling...',
                    style:
                        SdkTheme.bodyMedium.copyWith(color: Colors.white54),
                  ),
                ],
              ),
            ),

          // Local video PiP thumbnail (top-right).
          if (_controller.livekitService.localParticipant != null &&
              !_controller.isCameraOff)
            Positioned(
              top: mediaQuery.padding.top + 12,
              right: 12,
              child: ClipRRect(
                borderRadius:
                    BorderRadius.circular(SdkTheme.radiusMedium),
                child: SizedBox(
                  width: 120,
                  height: 160,
                  child: _buildLocalVideo(),
                ),
              ),
            ),

          // Minimize to PiP button (Android only).
          if (_pipEffective)
            Positioned(
              top: mediaQuery.padding.top + 12,
              left: 12,
              child: GestureDetector(
                onTap: () => _floating.enable(
                    ImmediatePiP(aspectRatio: widget.pipAspectRatio)),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.keyboard_arrow_down,
                      color: Colors.white, size: 24),
                ),
              ),
            ),

          // Call duration (top-center).
          if (_controller.callState == CallState.connected)
            Positioned(
              top: mediaQuery.padding.top + 12,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius:
                        BorderRadius.circular(SdkTheme.radiusRound),
                  ),
                  child: Text(
                    _controller.formattedDuration,
                    style: SdkTheme.labelBold,
                  ),
                ),
              ),
            ),

          // Bottom controls.
          Positioned(
            left: 0,
            right: 0,
            bottom: 32 + bottomPadding,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _CallControlButton(
                  icon:
                      _controller.isMuted ? Icons.mic_off : Icons.mic,
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
    final track = participant.videoTrackPublications.firstOrNull?.track;
    final videoTrack = track is VideoTrack ? track : null;
    final avatarUrl = _displayAvatar();
    final name = _displayName();
    if (videoTrack == null) {
      return Container(
        color: SdkTheme.backgroundDark,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 50,
                backgroundImage:
                    avatarUrl != null ? NetworkImage(avatarUrl) : null,
                child: avatarUrl == null
                    ? const Icon(Icons.person,
                        size: 50, color: Colors.white)
                    : null,
              ),
              const SizedBox(height: 12),
              Text(name, style: SdkTheme.headingBold),
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
    return VideoTrackRenderer(videoTrack, fit: VideoViewFit.cover);
  }

  Widget _buildLocalVideo() {
    final localParticipant =
        _controller.livekitService.localParticipant;
    final track =
        localParticipant?.videoTrackPublications.firstOrNull?.track;
    final videoTrack = track is VideoTrack ? track : null;
    if (videoTrack == null) return const SizedBox.shrink();
    return VideoTrackRenderer(
      videoTrack,
      fit: VideoViewFit.cover,
      mirrorMode: VideoViewMirrorMode.auto,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Supporting widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Compact avatar + name + status — sized for the Android PiP window.
class _CompactCallView extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final Widget statusLabel;

  const _CompactCallView({
    required this.name,
    required this.avatarUrl,
    required this.statusLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: SdkTheme.backgroundDark,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: SdkTheme.primaryPink.withValues(alpha: 0.4),
              backgroundImage:
                  avatarUrl != null ? NetworkImage(avatarUrl!) : null,
              child: avatarUrl == null
                  ? Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                name,
                style: const TextStyle(color: Colors.white, fontSize: 11),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(height: 2),
            statusLabel,
          ],
        ),
      ),
    );
  }
}

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
                  color: SdkTheme.primaryRed
                      .withValues(alpha: 0.3 * _scaleAnimation.value),
                  blurRadius: 30,
                  spreadRadius: 10,
                ),
              ],
            ),
            child: CircleAvatar(
              radius: 60,
              backgroundColor:
                  SdkTheme.primaryPink.withValues(alpha: 0.3),
              backgroundImage: widget.avatarUrl != null
                  ? NetworkImage(widget.avatarUrl!)
                  : null,
              child: widget.avatarUrl == null
                  ? Text(
                      widget.name.isNotEmpty
                          ? widget.name[0].toUpperCase()
                          : '?',
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
