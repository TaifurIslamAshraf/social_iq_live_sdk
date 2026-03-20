import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Service that manages Socket.IO connection for real-time comments and reactions.
class SocketService extends ChangeNotifier {
  io.Socket? _socket;
  bool _isConnected = false;

  bool get isConnected => _isConnected;

  // Stream controllers for events
  final _commentController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _reactionController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _viewerCountController = StreamController<int>.broadcast();

  Stream<Map<String, dynamic>> get onComment => _commentController.stream;
  Stream<Map<String, dynamic>> get onReaction => _reactionController.stream;
  Stream<int> get onViewerCountUpdate => _viewerCountController.stream;

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
      debugPrint('[SocketService] Connected');
      notifyListeners();
    });

    _socket!.onDisconnect((_) {
      _isConnected = false;
      debugPrint('[SocketService] Disconnected');
      notifyListeners();
    });

    // Listen for live stream events
    _socket!.on('live_comment', (data) {
      if (data is Map) {
        _commentController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('live_reaction', (data) {
      if (data is Map) {
        _reactionController.add(Map<String, dynamic>.from(data));
      }
    });

    _socket!.on('viewer_count', (data) {
      if (data is int) {
        _viewerCountController.add(data);
      } else if (data is Map && data['count'] != null) {
        _viewerCountController.add(data['count'] as int);
      }
    });
  }

  /// Join a live stream room on socket.
  void joinLiveRoom(String roomName) {
    _socket?.emit('join_live', {'room': roomName});
  }

  /// Leave a live stream room on socket.
  void leaveLiveRoom(String roomName) {
    _socket?.emit('leave_live', {'room': roomName});
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
    super.dispose();
  }
}
