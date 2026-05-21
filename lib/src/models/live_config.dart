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
  /// Stable id so the host can target a specific comment for reply / pin.
  /// Generated client-side as `${userId}_${microsecondsSinceEpoch}` when the
  /// comment is created locally; the same id is broadcast to other clients.
  final String id;
  final String userId;
  final String userName;
  final String? userAvatar;
  final String message;
  final DateTime timestamp;

  /// Id of the comment this one replies to, or null.
  final String? replyToCommentId;

  /// Display name of the user being replied to (denormalised so the bubble
  /// can render "@name" without a lookup).
  final String? replyToUserName;

  /// True when the host has pinned this comment.
  final bool isPinned;

  const LiveComment({
    required this.id,
    required this.userId,
    required this.userName,
    this.userAvatar,
    required this.message,
    required this.timestamp,
    this.replyToCommentId,
    this.replyToUserName,
    this.isPinned = false,
  });

  LiveComment copyWith({
    bool? isPinned,
  }) {
    return LiveComment(
      id: id,
      userId: userId,
      userName: userName,
      userAvatar: userAvatar,
      message: message,
      timestamp: timestamp,
      replyToCommentId: replyToCommentId,
      replyToUserName: replyToUserName,
      isPinned: isPinned ?? this.isPinned,
    );
  }
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
