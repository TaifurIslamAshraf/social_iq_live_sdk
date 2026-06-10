import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Service that manages Socket.IO connection for real-time comments, reactions, and call signaling.
class SocketService extends ChangeNotifier {
  io.Socket? _socket;
  bool _isConnected = false;

  bool get isConnected => _isConnected;

  // Stream controllers for live events
  final _commentController = StreamController<Map<String, dynamic>>.broadcast();
  final _reactionController = StreamController<Map<String, dynamic>>.broadcast();
  final _giftController = StreamController<Map<String, dynamic>>.broadcast();
  final _viewerCountController = StreamController<int>.broadcast();
  final _connectController = StreamController<void>.broadcast(); // fires on (re)connect

  /// Fires when the host pins or unpins a comment. Payload:
  /// `{ commentId: String?, pinned: bool }`. A null `commentId` with
  /// `pinned: false` means the host cleared the pin.
  final _commentPinController = StreamController<Map<String, dynamic>>.broadcast();

  /// Emits the full live rooms list whenever the server pushes a `live_rooms_update` event.
  /// Payload shape: `{ status, total, rooms: [ { room_name, host_uid, host_name,
  ///   host_profile_picture, viewer_count, viewer_uids, started_at } ] }`
  final _liveRoomsController = StreamController<Map<String, dynamic>>.broadcast();

  /// Fires when the host blocks a user from the live room. Payload:
  /// `{ blockedUserId: String }`. The blocked user's own client uses this to
  /// disable commenting; everyone else uses it to drop that user's comments.
  final _blockedController = StreamController<Map<String, dynamic>>.broadcast();

  /// Fires once on join with the room's recent comments so a late joiner sees
  /// an active feed. Payload: `{ comments: [ {commentId, userId, userName,
  /// userAvatar, message, ...} ] }`.
  final _commentHistoryController =
      StreamController<List<Map<String, dynamic>>>.broadcast();

  /// Fires when the host kicks a user from the live. Payload:
  /// `{ targetUserId: String }`. The kicked user leaves; others drop them.
  final _kickedController = StreamController<Map<String, dynamic>>.broadcast();

  /// Fires when the host bans a user from the live session. Payload:
  /// `{ targetUserId: String }`.
  final _bannedController = StreamController<Map<String, dynamic>>.broadcast();

  /// Fires when a banned user's join is rejected by the server. Payload:
  /// `{ message: String }`.
  final _banBlockedController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Fires when the host comment-mutes a user. Payload: `{ targetUserId }`.
  final _commentMutedController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Fires when the host deletes a comment. Payload: `{ commentId }`.
  final _commentDeletedController =
      StreamController<Map<String, dynamic>>.broadcast();

  // Stream controllers for call signaling
  final _incomingCallController = StreamController<Map<String, dynamic>>.broadcast();
  final _callAcceptedController = StreamController<Map<String, dynamic>>.broadcast();
  final _callRejectedController = StreamController<Map<String, dynamic>>.broadcast();
  final _callEndedController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get onComment => _commentController.stream;
  Stream<Map<String, dynamic>> get onReaction => _reactionController.stream;

  /// Fires when someone sends a gift in the room. Payload:
  /// `{ room, userId, userName, giftKey, emoji, label, coin }`.
  Stream<Map<String, dynamic>> get onGift => _giftController.stream;
  Stream<int> get onViewerCountUpdate => _viewerCountController.stream;
  Stream<void> get onConnect => _connectController.stream;  // fires on every connect/reconnect
  Stream<Map<String, dynamic>> get onCommentPin => _commentPinController.stream;

  /// Realtime stream of live rooms. Listen to this instead of polling [ApiService.getLiveRooms].
  /// The server broadcasts an update on every host start/end and viewer join/leave.
  Stream<Map<String, dynamic>> get onLiveRoomsUpdate => _liveRoomsController.stream;

  /// Fires when the host blocks a user. Payload: `{ blockedUserId: String }`.
  Stream<Map<String, dynamic>> get onBlocked => _blockedController.stream;

  /// Emits the room's recent comments once on join (oldest first).
  Stream<List<Map<String, dynamic>>> get onCommentHistory =>
      _commentHistoryController.stream;

  /// Fires when the host kicks a user. Payload: `{ targetUserId: String }`.
  Stream<Map<String, dynamic>> get onKicked => _kickedController.stream;

  /// Fires when the host bans a user. Payload: `{ targetUserId: String }`.
  Stream<Map<String, dynamic>> get onBanned => _bannedController.stream;

  /// Fires when a banned user is refused entry. Payload: `{ message: String }`.
  Stream<Map<String, dynamic>> get onBanBlocked =>
      _banBlockedController.stream;

  /// Fires when the host comment-mutes a user. Payload: `{ targetUserId }`.
  Stream<Map<String, dynamic>> get onCommentMuted =>
      _commentMutedController.stream;

  /// Fires when the host deletes a comment. Payload: `{ commentId }`.
  Stream<Map<String, dynamic>> get onCommentDeleted =>
      _commentDeletedController.stream;

  Stream<Map<String, dynamic>> get onIncomingCall => _incomingCallController.stream;
  Stream<Map<String, dynamic>> get onCallAccepted => _callAcceptedController.stream;
  Stream<Map<String, dynamic>> get onCallRejected => _callRejectedController.stream;
  Stream<Map<String, dynamic>> get onCallEnded => _callEndedController.stream;

  /// Connect to the Socket.IO server.
  void connect({
    required String url,
    String? authToken,
  }) {
    _socket = io.io(
      url,
      io.OptionBuilder()
          .setTransports(['websocket'])
          // CRITICAL: force a dedicated connection. Without this, socket.io
          // multiplexes by host and hands back the *host app's* already-open
          // socket (the empty-path namespace mismatch means it isn't recognised
          // as a separate namespace). That socket is already connected, so our
          // onConnect below never fires → `join_live` is never emitted → the
          // client never joins the room and receives no comments/reactions/
          // viewer_count/pins. Forcing a new connection keeps the live socket
          // isolated from the app's main socket.
          .enableForceNew()
          .enableAutoConnect()
          .enableReconnection()
          .setExtraHeaders(
            authToken != null ? {'Authorization': 'Bearer $authToken'} : {},
          )
          .build(),
    );

    _socket!.onConnect((_) {
      _isConnected = true;
      _connectController.add(null); // notify listeners of (re)connect
      debugPrint('[SocketService] Connected');
      notifyListeners();
      // Request current live rooms immediately so onLiveRoomsUpdate fires
      // without needing a separate HTTP call.
      _socket?.emit('get_live_rooms', {});
    });

    _socket!.onDisconnect((_) {
      _isConnected = false;
      debugPrint('[SocketService] Disconnected');
      notifyListeners();
    });

    // Live stream events
    _socket!.on('live_comment', (data) {
      if (data is Map) _commentController.add(Map<String, dynamic>.from(data));
    });

    _socket!.on('live_reaction', (data) {
      if (data is Map) _reactionController.add(Map<String, dynamic>.from(data));
    });

    _socket!.on('live_gift', (data) {
      if (data is Map) _giftController.add(Map<String, dynamic>.from(data));
    });

    _socket!.on('comment_pinned', (data) {
      if (data is Map) {
        _commentPinController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('live_blocked', (data) {
      if (data is Map) {
        _blockedController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('live_comment_history', (data) {
      if (data is Map && data['comments'] is List) {
        final list = (data['comments'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _commentHistoryController.add(list);
      }
    });

    _socket!.on('live_kicked', (data) {
      if (data is Map) _kickedController.add(Map<String, dynamic>.from(data));
    });

    _socket!.on('live_banned', (data) {
      if (data is Map) _bannedController.add(Map<String, dynamic>.from(data));
    });

    _socket!.on('live_ban_blocked', (data) {
      if (data is Map) {
        _banBlockedController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('live_comment_muted', (data) {
      if (data is Map) {
        _commentMutedController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('live_comment_deleted', (data) {
      if (data is Map) {
        _commentDeletedController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('viewer_count', (data) {
      if (data is int) {
        _viewerCountController.add(data);
      } else if (data is Map && data['count'] != null) {
        _viewerCountController.add(data['count'] as int);
      }
    });

    // Realtime live rooms list — emitted globally by the server on any rooms mutation
    _socket!.on('live_rooms_update', (data) {
      if (data is Map) {
        debugPrint('[SocketService] live_rooms_update: ${data['total']} room(s)');
        _liveRoomsController.add(Map<String, dynamic>.from(data));
      }
    });

    // Call signaling events
    _socket!.on('incoming_call', (data) {
      if (data is Map) {
        debugPrint('[SocketService] Incoming call from ${data['callerId']}');
        _incomingCallController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('call_accepted', (data) {
      if (data is Map) {
        debugPrint('[SocketService] Call accepted by ${data['receiverId']}');
        _callAcceptedController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('call_rejected', (data) {
      if (data is Map) {
        debugPrint('[SocketService] Call rejected by ${data['receiverId']}');
        _callRejectedController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('call_ended', (data) {
      if (data is Map) {
        debugPrint('[SocketService] Call ended');
        _callEndedController.add(Map<String, dynamic>.from(data));
      }
    });

    // Defensive: if the socket was already connected by the time we attached
    // (should not happen now that we force a new connection, but guards against
    // any future reuse), surface a synthetic connect so listeners can join the
    // room instead of waiting for an onConnect that will never come.
    if (_socket!.connected) {
      _isConnected = true;
      _connectController.add(null);
      notifyListeners();
    }
  }

  /// Register this user on the socket server so they can receive incoming calls.
  void registerUser(String userId) {
    _socket?.emit('register_user', {'userId': userId});
  }

  /// Notify server that host is starting a live broadcast.
  void startLive(String roomName, String userId) {
    _socket?.emit('start_live', {'room': roomName, 'userId': userId});
  }

  /// Join a live stream room on socket.
  void joinLiveRoom(String roomName, String userId) {
    _socket?.emit('join_live', {'room': roomName, 'userId': userId});
  }

  /// Leave a live stream room on socket.
  void leaveLiveRoom(String roomName, String userId, {bool isHost = false}) {
    _socket?.emit('leave_live', {'room': roomName, 'userId': userId, 'isHost': isHost});
  }

  /// Ask the server to push the current live rooms list via [onLiveRoomsUpdate].
  /// Useful if you want a manual refresh without an HTTP call.
  void requestLiveRooms() {
    _socket?.emit('get_live_rooms', {});
  }

  /// Send a comment to the live stream.
  ///
  /// [commentId] is the stable id used by reply / pin so all clients refer to
  /// the same comment. [replyToCommentId] and [replyToUserName] are populated
  /// when the host taps "reply" on an existing comment.
  void sendComment({
    required String roomName,
    required String userId,
    required String userName,
    String? userAvatar,
    required String message,
    String? commentId,
    String? replyToCommentId,
    String? replyToUserName,
  }) {
    if (!_isConnected || _socket == null) {
      debugPrint('[SocketService] Cannot send comment: not connected');
      return;
    }
    _socket!.emit('live_comment', {
      'room': roomName,
      'userId': userId,
      'userName': userName,
      'userAvatar': userAvatar,
      'message': message,
      'commentId': commentId,
      'replyToCommentId': replyToCommentId,
      'replyToUserName': replyToUserName,
    });
  }

  /// Host-only: pin a comment. [commentId] null + [pinned] false clears the pin.
  ///
  /// The full comment fields ([commentUserId], [userName], [userAvatar],
  /// [message]) are sent alongside the id so the server can replay the pinned
  /// comment to late joiners who never received the original `live_comment`.
  /// They are omitted when clearing the pin.
  void pinComment({
    required String roomName,
    required String userId,
    required String? commentId,
    required bool pinned,
    String? commentUserId,
    String? userName,
    String? userAvatar,
    String? message,
  }) {
    if (!_isConnected || _socket == null) {
      debugPrint('[SocketService] Cannot pin comment: not connected');
      return;
    }
    _socket!.emit('pin_comment', {
      'room': roomName,
      'userId': userId,
      'commentId': commentId,
      'pinned': pinned,
      'commentUserId': commentUserId,
      'userName': userName,
      'userAvatar': userAvatar,
      'message': message,
    });
  }

  /// Send a reaction to the live stream.
  void sendReaction({
    required String roomName,
    required String userId,
    required String emoji,
  }) {
    if (!_isConnected || _socket == null) {
      debugPrint('[SocketService] Cannot send reaction: not connected');
      return;
    }
    _socket!.emit('live_reaction', {
      'room': roomName,
      'userId': userId,
      'emoji': emoji,
    });
  }

  /// Broadcast a gift to the live stream (visual only — the coin transfer is
  /// done via the HTTP POST /send_gift before calling this).
  void sendGift({
    required String roomName,
    required String userId,
    String? userName,
    required String giftKey,
    required String emoji,
    required String label,
    required int coin,
    int healthGained = 0,
  }) {
    if (!_isConnected || _socket == null) {
      debugPrint('[SocketService] Cannot send gift: not connected');
      return;
    }
    _socket!.emit('live_gift', {
      'room': roomName,
      'userId': userId,
      'userName': userName,
      'giftKey': giftKey,
      'emoji': emoji,
      'label': label,
      'coin': coin,
      'healthGained': healthGained,
    });
  }

  /// Host-only: block a user from the live room. The server authorises (only the
  /// room host may block), drops the blocked user's future comments/reactions,
  /// and notifies the room via `live_blocked`.
  void blockLiveUser({
    required String roomName,
    required String userId,
    required String blockedUserId,
  }) {
    if (!_isConnected || _socket == null) {
      debugPrint('[SocketService] Cannot block user: not connected');
      return;
    }
    _socket!.emit('block_live_user', {
      'room': roomName,
      'userId': userId,
      'blockedUserId': blockedUserId,
    });
  }

  /// Host-only: kick a user from the current live (they may rejoin).
  void kickLiveUser({
    required String roomName,
    required String userId,
    required String targetUserId,
  }) {
    if (!_isConnected || _socket == null) return;
    _socket!.emit('kick_live_user', {
      'room': roomName,
      'userId': userId,
      'targetUserId': targetUserId,
    });
  }

  /// Host-only: ban a user from this live session (cannot rejoin until the
  /// host ends the broadcast).
  void banLiveUser({
    required String roomName,
    required String userId,
    required String targetUserId,
  }) {
    if (!_isConnected || _socket == null) return;
    _socket!.emit('ban_live_user', {
      'room': roomName,
      'userId': userId,
      'targetUserId': targetUserId,
    });
  }

  /// Host-only: comment-block (mute) a user for the live session.
  void muteLiveUser({
    required String roomName,
    required String userId,
    required String targetUserId,
  }) {
    if (!_isConnected || _socket == null) return;
    _socket!.emit('mute_live_user', {
      'room': roomName,
      'userId': userId,
      'targetUserId': targetUserId,
    });
  }

  /// Host-only: delete a single comment for everyone in the room.
  void deleteLiveComment({
    required String roomName,
    required String userId,
    required String commentId,
  }) {
    if (!_isConnected || _socket == null) return;
    _socket!.emit('delete_live_comment', {
      'room': roomName,
      'userId': userId,
      'commentId': commentId,
    });
  }

  /// Report a comment to the server for moderation review. Fire-and-forget.
  void reportLiveComment({
    required String roomName,
    required String reporterId,
    String? commentId,
    String? commentUserId,
    String? userName,
    String? message,
  }) {
    _socket?.emit('report_live_comment', {
      'room': roomName,
      'reporterId': reporterId,
      'commentId': commentId,
      'commentUserId': commentUserId,
      'userName': userName,
      'message': message,
    });
  }

  /// Send a call offer to a receiver.
  void sendCallOffer({
    required String callerId,
    required String receiverId,
    required String roomName,
    required String callType,
    String? callerName,
    String? callerAvatar,
  }) {
    _socket?.emit('call_offer', {
      'callerId': callerId,
      'receiverId': receiverId,
      'roomName': roomName,
      'callType': callType,
      'callerName': callerName,
      'callerAvatar': callerAvatar,
    });
  }

  /// Accept an incoming call.
  void acceptCall({required String callerId, required String receiverId, required String roomName}) {
    _socket?.emit('call_answer', {
      'callerId': callerId,
      'receiverId': receiverId,
      'roomName': roomName,
    });
  }

  /// Reject an incoming call.
  void rejectCall({required String callerId, required String receiverId}) {
    _socket?.emit('call_reject', {'callerId': callerId, 'receiverId': receiverId});
  }

  /// Notify both parties that the call has ended.
  void endCallSignal({required String callerId, required String receiverId}) {
    _socket?.emit('call_end', {'callerId': callerId, 'receiverId': receiverId});
  }

  /// Disconnect from socket.
  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
  }

  @override
  void dispose() {
    disconnect();
    _commentController.close();
    _reactionController.close();
    _giftController.close();
    _viewerCountController.close();
    _connectController.close();
    _commentPinController.close();
    _liveRoomsController.close();
    _blockedController.close();
    _commentHistoryController.close();
    _kickedController.close();
    _bannedController.close();
    _banBlockedController.close();
    _commentMutedController.close();
    _commentDeletedController.close();
    _incomingCallController.close();
    _callAcceptedController.close();
    _callRejectedController.close();
    _callEndedController.close();
    super.dispose();
  }
}


