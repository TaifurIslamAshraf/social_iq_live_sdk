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

/// A gift the viewer can send (catalog item). `coin` is the gross cost charged
/// to the sender's wallet — must match the backend gift catalog by [key].
class GiftType {
  /// Stable key sent to the backend (e.g. `rose`, `diamond`).
  final String key;
  final String emoji;
  final String label;
  final int coin;

  const GiftType({
    required this.key,
    required this.emoji,
    required this.label,
    required this.coin,
  });
}

/// Default gift catalog — mirrors the backend `utils/gift.catalog.js`.
/// Override via `LiveBroadcastViewer(giftCatalog: ...)` if the server changes.
const List<GiftType> kDefaultGiftCatalog = [
  GiftType(key: 'rose', emoji: '🌹', label: 'Rose', coin: 100),
  GiftType(key: 'trophy', emoji: '🏆', label: 'Trophy', coin: 200),
  GiftType(key: 'crown', emoji: '👑', label: 'Crown', coin: 300),
  GiftType(key: 'rocket', emoji: '🚀', label: 'Rocket', coin: 400),
  GiftType(key: 'star', emoji: '⭐', label: 'Star', coin: 500),
  GiftType(key: 'diamond', emoji: '💎', label: 'Diamond', coin: 1000),
];

/// A gift shown floating in the live stream (sent locally or received over socket).
class LiveGift {
  final String giftKey;
  final String emoji;
  final String label;
  final int coin;
  final String userId;
  final String? userName;

  /// Health points the sender gained from this gift (shown to everyone). 0 = none.
  final int healthGained;
  final DateTime timestamp;

  const LiveGift({
    required this.giftKey,
    required this.emoji,
    required this.label,
    required this.coin,
    required this.userId,
    this.userName,
    this.healthGained = 0,
    required this.timestamp,
  });
}
