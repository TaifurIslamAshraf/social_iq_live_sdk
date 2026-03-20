/// Type of call.
enum CallType { audio, video, group }

/// State of a call.
enum CallState { idle, ringing, connecting, connected, ended }

/// Configuration for a call session.
class CallConfig {
  /// LiveKit server WebSocket URL
  final String livekitUrl;

  /// LiveKit access token
  final String token;

  /// Room name for the call
  final String roomName;

  /// Current user's identity (user ID)
  final String identity;

  /// Current user's display name
  final String displayName;

  /// Current user's avatar URL
  final String? avatarUrl;

  /// Type of call
  final CallType callType;

  /// Receiver's user ID (for 1:1 calls)
  final String? receiverId;

  /// Receiver's display name
  final String? receiverName;

  /// Receiver's avatar URL
  final String? receiverAvatar;

  /// Max participants (for group calls)
  final int maxParticipants;

  const CallConfig({
    required this.livekitUrl,
    required this.token,
    required this.roomName,
    required this.identity,
    required this.displayName,
    this.avatarUrl,
    required this.callType,
    this.receiverId,
    this.receiverName,
    this.receiverAvatar,
    this.maxParticipants = 10,
  });
}

/// Information about a call participant.
class CallParticipant {
  final String identity;
  final String? name;
  final String? avatarUrl;
  final bool isMuted;
  final bool isCameraOff;

  const CallParticipant({
    required this.identity,
    this.name,
    this.avatarUrl,
    this.isMuted = false,
    this.isCameraOff = false,
  });
}
