import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

/// Service that wraps the LiveKit client for room connection and track management.
class LiveKitService extends ChangeNotifier {
  Room? _room;
  LocalParticipant? _localParticipant;
  EventsListener<RoomEvent>? _listener;

  bool _isMicEnabled = true;
  bool _isCameraEnabled = true;

  // Public getters
  Room? get room => _room;
  LocalParticipant? get localParticipant => _localParticipant;
  bool get isConnected => _room?.connectionState == ConnectionState.connected;
  bool get isMicEnabled => _isMicEnabled;
  bool get isCameraEnabled => _isCameraEnabled;

  List<RemoteParticipant> get remoteParticipants =>
      _room?.remoteParticipants.values.toList() ?? [];

  int get participantCount => (_room?.remoteParticipants.length ?? 0) + 1;

  /// Connect to a LiveKit room.
  Future<void> connect({
    required String url,
    required String token,
    bool enableCamera = true,
    bool enableMicrophone = true,
  }) async {
    _room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultVideoPublishOptions: VideoPublishOptions(
          simulcast: true,
        ),
      ),
    );

    _listener = _room!.createListener();
    _setupListeners();

    await _room!.connect(url, token);

    _localParticipant = _room!.localParticipant;

    if (enableCamera) {
      await _localParticipant?.setCameraEnabled(true);
      _isCameraEnabled = true;
    } else {
      _isCameraEnabled = false;
    }
    if (enableMicrophone) {
      await _localParticipant?.setMicrophoneEnabled(true);
      _isMicEnabled = true;
    } else {
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
    final videoTrack = _localParticipant?.videoTrackPublications
        .firstOrNull
        ?.track;

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
      ..on<TrackPublishedEvent>((event) {
        notifyListeners();
      })
      ..on<TrackUnpublishedEvent>((event) {
        notifyListeners();
      })
      ..on<TrackSubscribedEvent>((event) {
        notifyListeners();
      })
      ..on<TrackUnsubscribedEvent>((event) {
        notifyListeners();
      })
      ..on<RoomDisconnectedEvent>((event) {
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
