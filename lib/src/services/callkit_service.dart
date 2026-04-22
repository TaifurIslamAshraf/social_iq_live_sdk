import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';

/// Handles incoming call notifications for both foreground and background/killed
/// app states using [flutter_callkit_incoming].
///
/// ## Typical wiring
///
/// 1. Call [CallNotificationHandler.initialize] once at app startup.
/// 2. In your FCM background message handler (top-level function), call
///    [showIncomingCall] with `message.data`.
/// 3. Listen to [onCallAccepted] to navigate to [VideoCallScreen] /
///    [AudioCallScreen], and to [onCallDeclined] to send a reject signal.
///
/// See CALLS.md §4 for the full Firebase + CallKit setup guide.
class CallNotificationHandler {
  CallNotificationHandler._();

  static StreamSubscription<CallEvent?>? _eventSub;

  static final _acceptedController =
      StreamController<Map<String, dynamic>>.broadcast();
  static final _declinedController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Fires when the user taps **Accept** on the native call UI.
  ///
  /// Payload is the `extra` map passed to [showIncomingCall]:
  /// `{ callerId, receiverId, roomName, callType, callerName, callerAvatar }`.
  static Stream<Map<String, dynamic>> get onCallAccepted =>
      _acceptedController.stream;

  /// Fires when the user taps **Decline**, or when the call times out.
  ///
  /// Same payload as [onCallAccepted]. Use it to send a reject signal back to
  /// the caller via `SocketService.rejectCall(...)`.
  static Stream<Map<String, dynamic>> get onCallDeclined =>
      _declinedController.stream;

  /// Start listening for native call UI events (accept / decline / timeout).
  ///
  /// Call **once** at app startup after `Firebase.initializeApp()` and
  /// `SocialIqLiveSdk.initialize(...)`. Safe to call more than once — the
  /// previous subscription is cancelled before registering a new one.
  static void initialize() {
    _eventSub?.cancel();
    _eventSub = FlutterCallkitIncoming.onEvent.listen((CallEvent? event) {
      if (event == null) return;

      final raw = event.body['extra'];
      final data = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};

      if (event.event == Event.actionCallAccept) {
        _acceptedController.add(data);
      } else if (event.event == Event.actionCallDecline ||
          event.event == Event.actionCallTimeout) {
        _declinedController.add(data);
      }
      // actionCallEnded — remote hung up while CallKit UI was still on screen.
      // The call screen manages its own teardown; nothing to do here.
    });
  }

  /// Show the native incoming call screen.
  /// - **iOS**: full-screen CallKit UI (requires VoIP push certificate — see CALLS.md §4.5)
  /// - **Android**: heads-up / full-screen notification using ConnectionService
  ///
  /// Call this from:
  /// - `FirebaseMessaging.onBackgroundMessage` — app killed or backgrounded
  /// - `FirebaseMessaging.onMessage.listen`    — app in foreground (optional)
  ///
  /// Required keys in [data]:
  /// ```
  /// callerId     — String
  /// receiverId   — String
  /// roomName     — String   (used as the unique call ID)
  /// callType     — 'audio' | 'video'
  /// callerName   — String   (shown to user)
  /// callerAvatar — String?  (avatar URL, optional)
  /// ```
  static Future<void> showIncomingCall(Map<String, dynamic> data) async {
    final isVideo = data['callType'] == 'video';

    await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
      id: (data['roomName'] as String?) ?? 'incoming_call',
      nameCaller: (data['callerName'] as String?) ?? 'Unknown',
      avatar: data['callerAvatar'] as String?,
      handle: (data['callerId'] as String?) ?? '',
      type: isVideo ? 1 : 0, // 0 = audio, 1 = video
      duration: 45000, // 45 s — matches SDK ringing timeout
      extra: data,
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        isShowFullLockedScreen: true,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0A0A0A',
        actionColor: '#E53935',
      ),
      ios: const IOSParams(
        supportsVideo: true,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    ));
  }

  /// Dismiss the native call UI for a specific call.
  ///
  /// Call when:
  /// - The caller cancels before the receiver answers
  /// - The in-app call ends via [VideoCallScreen] / [AudioCallScreen]
  ///
  /// Pass the same `roomName` used in [showIncomingCall].
  static Future<void> endCall(String roomName) async {
    await FlutterCallkitIncoming.endCall(roomName);
  }

  /// Dismiss all active call UIs — call on user logout.
  static Future<void> endAllCalls() async {
    await FlutterCallkitIncoming.endAllCalls();
    debugPrint('[CallNotificationHandler] All calls ended');
  }

  /// Mark a call as connected (updates iOS call history in the Phone app).
  ///
  /// Call this once the LiveKit room is successfully joined inside the call
  /// screen — [VideoCallScreen] / [AudioCallScreen] do this automatically
  /// when their state reaches [CallState.connected].
  static Future<void> setCallConnected(String roomName) async {
    await FlutterCallkitIncoming.setCallConnected(roomName);
  }

  /// Cancel the event listener. Call on logout to stop receiving events.
  static void dispose() {
    _eventSub?.cancel();
    _eventSub = null;
  }
}
