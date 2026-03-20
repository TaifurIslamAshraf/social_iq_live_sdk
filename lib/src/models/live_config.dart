/// Configuration for a live broadcast session.
class LiveConfig {
  /// LiveKit server WebSocket URL (e.g., wss://livekit.yourapp.com)
  final String livekitUrl;

  /// LiveKit access token (obtained from backend)
  final String token;

  /// Room name / live stream ID
  final String roomName;

  /// Current user's identity (user ID)
  final String identity;

  /// Display name shown in the live stream
  final String displayName;

  /// User's avatar URL
  final String? avatarUrl;

  /// Title of the live broadcast
  final String? title;

  const LiveConfig({
    required this.livekitUrl,
    required this.token,
    required this.roomName,
    required this.identity,
    required this.displayName,
    this.avatarUrl,
    this.title,
  });
}

/// A comment in the live stream.
class LiveComment {
  final String userId;
  final String userName;
  final String? userAvatar;
  final String message;
  final DateTime timestamp;

  const LiveComment({
    required this.userId,
    required this.userName,
    this.userAvatar,
    required this.message,
    required this.timestamp,
  });
}

/// A reaction in the live stream.
class LiveReaction {
  final String emoji;
  final String userId;
  final DateTime timestamp;

  const LiveReaction({
    required this.emoji,
    required this.userId,
    required this.timestamp,
  });
}
