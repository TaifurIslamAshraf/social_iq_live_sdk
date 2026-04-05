import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

/// Describes how this connection will be used.
/// Different modes apply different video quality / bitrate constraints
/// to protect the single-CPU VPS from being overwhelmed.
enum StreamMode {
  /// Live broadcast host: 540p @ 20 fps, 800 kbps max, 2-layer simulcast.
  livestream,

  /// 1-on-1 or group video call: 360p @ 15 fps, 500 kbps max, no simulcast.
  videoCall,

  /// 1-on-1 audio call: camera disabled, only audio constraints applied.
  audioCall,
}

/// Service that wraps the LiveKit client for room connection and track management.
/// Optimised for a low-resource VPS (1 CPU core, 4 GB RAM, ~150 ms RTT).
class LiveKitService extends ChangeNotifier {
  Room? _room;
  LocalParticipant? _localParticipant;
  EventsListener<RoomEvent>? _listener;

  bool _isMicEnabled = true;
  bool _isCameraEnabled = true;
  StreamMode _currentMode = StreamMode.livestream;

  // Public getters
  Room? get room => _room;
  LocalParticipant? get localParticipant => _localParticipant;
  bool get isConnected => _room?.connectionState == ConnectionState.connected;
  bool get isMicEnabled => _isMicEnabled;
  bool get isCameraEnabled => _isCameraEnabled;
  StreamMode get currentMode => _currentMode;

  List<RemoteParticipant> get remoteParticipants =>
      _room?.remoteParticipants.values.toList() ?? [];

  int get participantCount => (_room?.remoteParticipants.length ?? 0) + 1;

  // ─────────────────────────────────────────────────────────────────────────────
  // Video publish presets
  // ─────────────────────────────────────────────────────────────────────────────

  /// Livestream host preset: 540p @ 20 fps, 800 kbps ceiling.
  /// Two simulcast layers keep server CPU usage roughly half of three layers.
  static VideoPublishOptions get _livestreamPublishOptions =>
      const VideoPublishOptions(
        simulcast: true,
        // Two layers: low (180p) and medium (540p). No high (720p+) layer.
        videoSimulcastLayers: [
          VideoParameters(
            dimensions: VideoDimensionsPresets.h180_169,
            encoding: VideoEncoding(maxBitrate: 150 * 1000, maxFramerate: 15),
          ),
          VideoParameters(
            dimensions: VideoDimensionsPresets.h540_169,
            encoding: VideoEncoding(maxBitrate: 800 * 1000, maxFramerate: 20),
          ),
        ],
      );

  /// Video-call preset: 360p @ 15 fps, 500 kbps. No simulcast for 1:1.
  static VideoPublishOptions get _videoCallPublishOptions =>
      const VideoPublishOptions(
        simulcast: false,
        videoEncoding: VideoEncoding(maxBitrate: 500 * 1000, maxFramerate: 15),
      );

  /// Shared capture config for livestream — 540p @ 20 fps.
  static CameraCaptureOptions get _livestreamCaptureOptions =>
      const CameraCaptureOptions(
        cameraPosition: CameraPosition.front,
        params: VideoParametersPresets.h540_169,
      );

  /// Shared capture config for calls — 360p @ 15 fps.
  static CameraCaptureOptions get _callCaptureOptions =>
      const CameraCaptureOptions(
        cameraPosition: CameraPosition.front,
        params: VideoParametersPresets.h360_169,
      );

  // ─────────────────────────────────────────────────────────────────────────────
  // Connection
  // ─────────────────────────────────────────────────────────────────────────────

  /// Connect to a LiveKit room.
  ///
  /// [mode] controls publish quality and simulcast behaviour:
  /// - [StreamMode.livestream] — host broadcast (540p, 2-layer simulcast)
  /// - [StreamMode.videoCall]  — 1:1 / group video call (360p, no simulcast)
  /// - [StreamMode.audioCall]  — audio-only call
  Future<void> connect({
    required String url,
    required String token,
    bool enableCamera = true,
    bool enableMicrophone = true,
    StreamMode mode = StreamMode.livestream,
  }) async {
    _currentMode = mode;

    final isLivestream = mode == StreamMode.livestream;
    final isVideoCall = mode == StreamMode.videoCall;

    // Speaker routing must be decided BEFORE Room is created so that WebRTC's
    // Acoustic Echo Canceller (AEC) is calibrated for the correct audio route
    // from the very start. Changing the route after connection breaks AEC and
    // causes the echo / "ring-back" artefact the caller hears.
    //
    // Audio calls → earpiece (speaker off): eliminates mic pickup of speaker.
    // Video calls / livestream → loudspeaker: user faces the screen; AEC
    //   handles the reference signal correctly when routing is set up front.
    final useSpeaker = mode != StreamMode.audioCall;

    _room = Room(
      roomOptions: RoomOptions(
        // AdaptiveStream downgrades subscriber quality when bandwidth drops.
        adaptiveStream: true,
        // Dynacast pauses layers nobody is watching, saving server CPU.
        dynacast: true,

        defaultCameraCaptureOptions:
            isLivestream ? _livestreamCaptureOptions : _callCaptureOptions,

        defaultVideoPublishOptions: isLivestream
            ? _livestreamPublishOptions
            : isVideoCall
                ? _videoCallPublishOptions
                : const VideoPublishOptions(simulcast: false),

        // Audio optimised for VoIP — noise suppression, DTX, RED redundancy.
        defaultAudioCaptureOptions: const AudioCaptureOptions(
          noiseSuppression: true,
          echoCancellation: true,
          autoGainControl: true,
          highPassFilter: true,
          typingNoiseDetection: true,
        ),
        defaultAudioPublishOptions: const AudioPublishOptions(
          // DTX (discontinuous transmission) silences audio when no speech —
          // major bandwidth saver on a constrained uplink.
          dtx: true,
          // RED adds minimal overhead but recovers lost audio packets.
          red: true,
        ),
        // Set the correct speaker routing BEFORE connecting so AEC is
        // calibrated for the right audio route from the first packet.
        defaultAudioOutputOptions: AudioOutputOptions(
          speakerOn: useSpeaker,
        ),
      ),
    );

    _listener = _room!.createListener();
    _setupListeners();

    await _room!.connect(url, token);
    _localParticipant = _room!.localParticipant;

    if (enableCamera && mode != StreamMode.audioCall) {
      await _localParticipant?.setCameraEnabled(true);
      _isCameraEnabled = true;
    } else {
      _isCameraEnabled = false;
    }

    if (enableMicrophone) {
      await _localParticipant?.setMicrophoneEnabled(true);
      _isMicEnabled = true;
    } else {
      await _localParticipant?.setMicrophoneEnabled(false);
      _isMicEnabled = false;
    }

    notifyListeners();
  }

  /// Disconnect from the room.
  Future<void> disconnect() async {
    await _room?.disconnect();
    _listener?.dispose();
    _room = null;
    _localParticipant = null;
    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Track controls
  // ─────────────────────────────────────────────────────────────────────────────

  /// Toggle microphone.
  Future<void> toggleMicrophone() async {
    _isMicEnabled = !_isMicEnabled;
    await _localParticipant?.setMicrophoneEnabled(_isMicEnabled);
    notifyListeners();
  }

  /// Toggle camera.
  Future<void> toggleCamera() async {
    _isCameraEnabled = !_isCameraEnabled;
    await _localParticipant?.setCameraEnabled(_isCameraEnabled);
    notifyListeners();
  }

  /// Switch between front and rear camera.
  Future<void> switchCamera() async {
    final videoTrack =
        _localParticipant?.videoTrackPublications.firstOrNull?.track;
    if (videoTrack != null) {
      try {
        final currentOptions = videoTrack.currentOptions;
        if (currentOptions is CameraCaptureOptions) {
          final newPosition =
              currentOptions.cameraPosition == CameraPosition.front
                  ? CameraPosition.back
                  : CameraPosition.front;
          await videoTrack.setCameraPosition(newPosition);
        }
      } catch (e) {
        debugPrint('Failed to switch camera: $e');
      }
    }
  }

  /// Enable/disable speaker output.
  Future<void> setSpeakerOn(bool enabled) async {
    await _room?.setSpeakerOn(enabled);
  }

  /// Set preferred subscription quality for a remote participant's video.
  ///
  /// Viewers on slow connections should call:
  ///   `setPreferredVideoQuality(participant, VideoQuality.LOW)`
  ///
  /// This tells the server to send only the lowest simulcast layer,
  /// dramatically reducing server CPU for routing.
  Future<void> setPreferredVideoQuality(
    RemoteParticipant participant,
    VideoQuality quality,
  ) async {
    for (final pub in participant.videoTrackPublications) {
      if (pub.subscribed) {
        await pub.setVideoQuality(quality);
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Internal
  // ─────────────────────────────────────────────────────────────────────────────

  void _setupListeners() {
    _listener
      ?..on<ParticipantConnectedEvent>((event) {
        debugPrint('Participant connected: ${event.participant.identity}');
        notifyListeners();
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        debugPrint('Participant disconnected: ${event.participant.identity}');
        notifyListeners();
      })
      ..on<TrackPublishedEvent>((_) => notifyListeners())
      ..on<TrackUnpublishedEvent>((_) => notifyListeners())
      ..on<TrackSubscribedEvent>((_) => notifyListeners())
      ..on<TrackUnsubscribedEvent>((_) => notifyListeners())
      ..on<RoomDisconnectedEvent>((_) {
        debugPrint('Room disconnected');
        notifyListeners();
      });
  }

  @override
  void dispose() {
    _listener?.dispose();
    _room?.disconnect();
    _room = null;
    _localParticipant = null;
    super.dispose();
  }
}
