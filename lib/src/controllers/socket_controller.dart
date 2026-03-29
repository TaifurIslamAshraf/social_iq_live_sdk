import '../services/socket_service.dart';

/// Re-export SocketService as SocketController for API consistency.
/// The SocketService already extends ChangeNotifier and handles
/// all real-time communication. This file exists to match the
/// folder structure convention.
typedef SocketController = SocketService;
