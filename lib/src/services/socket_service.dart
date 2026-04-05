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
  final _viewerCountController = StreamController<int>.broadcast();
  final _connectController = StreamController<void>.broadcast(); // fires on (re)connect

  /// Emits the full live rooms list whenever the server pushes a `live_rooms_update` event.
  /// Payload shape: `{ status, total, rooms: [ { room_name, host_uid, host_name,
  ///   host_profile_picture, viewer_count, viewer_uids, started_at } ] }`
  final _liveRoomsController = StreamController<Map<String, dynamic>>.broadcast();

  // Stream controllers for call signaling
  final _incomingCallController = StreamController<Map<String, dynamic>>.broadcast();
  final _callAcceptedController = StreamController<Map<String, dynamic>>.broadcast();
  final _callRejectedController = StreamController<Map<String, dynamic>>.broadcast();
  final _callEndedController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get onComment => _commentController.stream;
  Stream<Map<String, dynamic>> get onReaction => _reactionController.stream;
  Stream<int> get onViewerCountUpdate => _viewerCountController.stream;
  Stream<void> get onConnect => _connectController.stream;  // fires on every connect/reconnect

  /// Realtime stream of live rooms. Listen to this instead of polling [ApiService.getLiveRooms].
  /// The server broadcasts an update on every host start/end and viewer join/leave.
  Stream<Map<String, dynamic>> get onLiveRoomsUpdate => _liveRoomsController.stream;

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
  void sendComment({
    required String roomName,
    required String userId,
    required String userName,
    String? userAvatar,
    required String message,
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
    _viewerCountController.close();
    _connectController.close();
    _liveRoomsController.close();
    _incomingCallController.close();
    _callAcceptedController.close();
    _callRejectedController.close();
    _callEndedController.close();
    super.dispose();
  }
}


