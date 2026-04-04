import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service for making HTTP calls to the backend API.
class ApiService {
  final String baseUrl;
  String? _authToken;
  static const _timeout = Duration(seconds: 10);

  ApiService({required this.baseUrl});

  /// Set the auth token for API requests.
  void setAuthToken(String token) {
    _authToken = token;
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      };

  /// Get token for 1:1 call.
  Future<Map<String, dynamic>> getCallToken({
    required String callerId,
    required String receiverId,
    required String room,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/api/get-token'),
          headers: _headers,
          body: jsonEncode({
            'callerId': callerId,
            'receiverId': receiverId,
            'room': room,
          }),
        )
        .timeout(_timeout);
    return _handleResponse(response);
  }

  /// Get token for live broadcast.
  Future<Map<String, dynamic>> getLiveToken({
    required String userType,
    required String identity,
    required String room,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/api/get-live-token'),
          headers: _headers,
          body: jsonEncode({
            'userType': userType,
            'identity': identity,
            'room': room,
          }),
        )
        .timeout(_timeout);
    return _handleResponse(response);
  }

  /// Get token for group call.
  Future<Map<String, dynamic>> getGroupCallToken({
    required String identity,
    required String room,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/api/get-group-call-token'),
          headers: _headers,
          body: jsonEncode({
            'identity': identity,
            'room': room,
          }),
        )
        .timeout(_timeout);
    return _handleResponse(response);
  }

  /// Create a room.
  Future<Map<String, dynamic>> createRoom({
    required String roomName,
    int maxParticipants = 0,
    int emptyTimeout = 300,
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/api/create-room'),
          headers: _headers,
          body: jsonEncode({
            'roomName': roomName,
            'maxParticipants': maxParticipants,
            'emptyTimeout': emptyTimeout,
          }),
        )
        .timeout(_timeout);
    return _handleResponse(response);
  }

  /// End a 1:1 call / close a room.
  Future<Map<String, dynamic>> endCall({required String roomName}) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/api/end-call'),
          headers: _headers,
          body: jsonEncode({'roomName': roomName}),
        )
        .timeout(_timeout);
    return _handleResponse(response);
  }

  /// Fetches the current snapshot of all active live rooms (one-shot HTTP call).
  ///
  /// Use this **once** on screen load to seed the initial list.
  /// Then subscribe to [SocketService.onLiveRoomsUpdate] for realtime push
  /// updates — the server emits `live_rooms_update` whenever a host goes live,
  /// ends a broadcast, or a viewer joins/leaves.
  ///
  /// Example:
  /// ```dart
  /// // 1. Seed initial list
  /// final data = await apiService.getLiveRooms();
  /// setState(() => _rooms = List<Map<String, dynamic>>.from(data['rooms']));
  ///
  /// // 2. Subscribe to realtime updates (no polling needed)
  /// socketService.onLiveRoomsUpdate.listen((data) {
  ///   setState(() => _rooms = List<Map<String, dynamic>>.from(data['rooms']));
  /// });
  /// ```
  Future<Map<String, dynamic>> getLiveRooms() async {
    final response = await http
        .get(
          Uri.parse('$baseUrl/v1/api/live/rooms'),
          headers: _headers,
        )
        .timeout(_timeout);
    return _handleResponse(response);
  }

  /// End a live broadcast room.
  Future<Map<String, dynamic>> endLive({required String roomName}) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/api/end-live'),
          headers: _headers,
          body: jsonEncode({'roomName': roomName}),
        )
        .timeout(_timeout);
    return _handleResponse(response);
  }

  Map<String, dynamic> _handleResponse(http.Response response) {
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body;
    }
    throw ApiException(
      statusCode: response.statusCode,
      message: body['msg']?.toString() ?? 'Unknown error',
    );
  }
}

/// Exception thrown by API calls.
class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException({required this.statusCode, required this.message});

  @override
  String toString() => 'ApiException($statusCode): $message';
}
