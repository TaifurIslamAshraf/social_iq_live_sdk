# Social IQ Live SDK — Integration Guide

Step-by-step guide for adding audio/video calls to your Flutter app.

---

## What you will implement

1. Add the SDK to your app
2. Initialize the SDK at startup
3. Connect to the socket server after login
4. Make an outgoing audio or video call
5. Receive an incoming call (app in foreground)
6. Receive an incoming call (app in background via FCM)

---

## Step 1 — Add the SDK to your app

In your app's `pubspec.yaml`, add the SDK as a local path dependency:

```yaml
dependencies:
  flutter:
    sdk: flutter

  social_iq_live_sdk:
    path: ../social_iq_live_sdk   # adjust path to where the SDK lives

  firebase_core: ^3.0.0
  firebase_messaging: ^15.0.0
  http: ^1.4.0
```

Run:

```bash
flutter pub get
```

---

## Step 2 — Android & iOS permissions

### Android

Open `android/app/src/main/AndroidManifest.xml` and add inside `<manifest>`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
```

### iOS

Open `ios/Runner/Info.plist` and add:

```xml
<key>NSCameraUsageDescription</key>
<string>Camera is needed for video calls</string>
<key>NSMicrophoneUsageDescription</key>
<string>Microphone is needed for audio and video calls</string>
```

---

## Step 3 — Initialize the SDK in `main.dart`

Call `SocialIqLiveSdk.initialize()` once before `runApp`. This stores your server URLs and requests camera/mic permissions from the OS.

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

// Required: top-level function for background FCM.
// This runs in a separate isolate when the app is killed.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Handle the call notification here — navigate to call screen
  // using message.data fields: type, callerId, receiverId,
  // roomName, callType, callerName, callerAvatar
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

  await SocialIqLiveSdk.initialize(
    serverUrl:  'wss://live.yourapp.com',    // LiveKit WebSocket URL
    socketUrl:  'https://api.yourapp.com',   // Socket.IO server URL
    apiBaseUrl: 'https://api.yourapp.com',   // Backend REST API URL
  );

  runApp(MyApp(navigatorKey: navigatorKey));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.navigatorKey});
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      home: const HomePage(),
    );
  }
}
```

> **Why `navigatorKey`?** When a call arrives via FCM while the app is in the background, the background handler runs in a separate isolate and cannot access `BuildContext`. The `navigatorKey` lets you push a new screen from anywhere without `context`.

---

## Step 4 — Connect the socket after login

The socket must be connected so your app can receive incoming calls in real time. Do this in the widget that is shown right after the user logs in (your home screen or dashboard).

```dart
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

class _HomePageState extends State<HomePage> {
  late final SocketService _socketService;

  // Replace with values from your auth layer
  final String myUserId   = 'user_123';
  final String myJwt      = 'your_auth_token';
  final String myName     = 'Alice';

  @override
  void initState() {
    super.initState();

    _socketService = SocketService();

    // 1. Connect to the socket server
    _socketService.connect(
      url:       SocialIqLiveSdkConfig.socketUrl,
      authToken: myJwt,
    );

    // 2. Register your user ID so the server knows you are online
    _socketService.registerUser(myUserId);

    // 3. Re-register after every reconnect (network drop, app resume, etc.)
    _socketService.onConnect.listen((_) {
      _socketService.registerUser(myUserId);
    });

    // 4. Listen for incoming calls
    _listenForIncomingCalls();

    // 5. Listen for foreground FCM (app is open, call notification arrives)
    FirebaseMessaging.onMessage.listen(_handleForegroundFcm);

    // 6. Upload FCM token so the backend can wake this device
    _registerFcmToken();

    // 7. Request notification permission (Android 13+)
    FirebaseMessaging.instance.requestPermission();
  }

  @override
  void dispose() {
    _socketService.dispose();
    super.dispose();
  }
}
```

---

## Step 5 — Make an outgoing call

Call this from a button or contact card. Pass the other user's ID as `receiverId`.

### Audio call

```dart
void startAudioCall(String targetUserId, String targetUserName) {
  Navigator.push(context, MaterialPageRoute(
    builder: (_) => AudioCallScreen(
      userToken:     myJwt,
      callerId:      myUserId,
      receiverId:    targetUserId,
      callerName:    myName,           // shown on receiver's ringing screen
      receiverName:  targetUserName,   // shown on your "Calling…" screen
      onCallStarted:   () { /* call is connecting */ },
      onCallConnected: () { /* media is live */ },
      onCallEnded: (duration) {
        debugPrint('Call ended after $duration');
      },
    ),
  ));
}
```

### Video call

```dart
void startVideoCall(String targetUserId, String targetUserName) {
  Navigator.push(context, MaterialPageRoute(
    builder: (_) => VideoCallScreen(
      userToken:     myJwt,
      callerId:      myUserId,
      receiverId:    targetUserId,
      callerName:    myName,
      receiverName:  targetUserName,
      onCallStarted:   () { /* call is connecting */ },
      onCallConnected: () { /* media is live */ },
      onCallEnded: (duration) {
        debugPrint('Call ended after $duration');
      },
    ),
  ));
}
```

> The SDK creates the room name automatically from both user IDs. You do not need to generate one yourself.

---

## Step 6 — Receive an incoming call (foreground)

Add these two methods to your home page state. They are already wired up in Step 4.

```dart
bool _isShowingIncomingCall = false;

void _listenForIncomingCalls() {
  _socketService.onIncomingCall.listen((data) {
    if (!mounted || _isShowingIncomingCall) return;
    _isShowingIncomingCall = true;
    _showIncomingCallScreen(data);
  });
}

void _handleForegroundFcm(RemoteMessage message) {
  final data = message.data;
  if (data['type'] == 'incoming_call') {
    if (_isShowingIncomingCall) return; // already showing — ignore duplicate
    _isShowingIncomingCall = true;
    _showIncomingCallScreen(data);
  }
}

void _showIncomingCallScreen(Map<String, dynamic> data) {
  final isVideo     = data['callType'] == 'video';
  final callType    = isVideo ? CallType.video : CallType.audio;
  final callerName  = data['callerName']   as String? ?? 'Unknown';
  final callerAvatar= data['callerAvatar'] as String?;
  final callerId    = data['callerId']     as String? ?? '';
  final roomName    = data['roomName']     as String?;

  Navigator.push(context, MaterialPageRoute(
    builder: (_) => IncomingCallScreen(
      callerName:   callerName,
      callerAvatar: callerAvatar,
      callType:     callType,
      onAccept: () {
        Navigator.pop(context);
        _isShowingIncomingCall = false;
        _openAnsweredCallScreen(
          callType:    callType,
          callerId:    callerId,
          roomName:    roomName,
          callerName:  callerName,
          callerAvatar:callerAvatar,
        );
      },
      onDecline: () {
        Navigator.pop(context);
        _isShowingIncomingCall = false;
        _socketService.rejectCall(callerId: callerId, receiverId: myUserId);
      },
    ),
  )).then((_) => _isShowingIncomingCall = false);
}

void _openAnsweredCallScreen({
  required CallType callType,
  required String callerId,
  String? roomName,
  String? callerName,
  String? callerAvatar,
}) {
  if (callType == CallType.video) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => VideoCallScreen(
        userToken:            myJwt,
        callerId:             callerId,   // the person who called YOU
        receiverId:           myUserId,   // your own ID
        roomName:             roomName,
        isIncoming:           true,       // important — tells SDK to answer, not offer
        incomingCallerName:   callerName,
        incomingCallerAvatar: callerAvatar,
        onCallEnded: (d) => debugPrint('Call ended after $d'),
      ),
    ));
  } else {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => AudioCallScreen(
        userToken:   myJwt,
        callerId:    callerId,
        receiverId:  myUserId,
        roomName:    roomName,
        isIncoming:  true,
        callerName:  callerName,
        callerAvatar:callerAvatar,
        onCallEnded: (d) => debugPrint('Call ended after $d'),
      ),
    ));
  }
}
```

> **`isIncoming: true`** is required when answering a call. Without it the SDK will try to initiate a new call instead of joining the existing room.

---

## Step 7 — FCM token registration

Your backend needs the device's FCM token to send push notifications. Upload it after login and whenever it rotates.

```dart
import 'dart:convert';
import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

Future<void> _registerFcmToken() async {
  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return;
    await _uploadFcmToken(token);
    FirebaseMessaging.instance.onTokenRefresh.listen(_uploadFcmToken);
  } catch (e) {
    debugPrint('FCM token registration failed: $e');
  }
}

Future<void> _uploadFcmToken(String token) async {
  await http.post(
    Uri.parse('${SocialIqLiveSdkConfig.apiBaseUrl}/v1/api/fcm-token'),
    headers: {
      'Content-Type':  'application/json',
      'Authorization': 'Bearer $myJwt',
    },
    body: jsonEncode({
      'userId':   myUserId,
      'token':    token,
      'platform': Platform.isIOS ? 'ios' : 'android',
    }),
  );
}
```

---

## Step 8 — Backend: send FCM when a call starts

When the caller emits `call_offer` via socket, your backend should:

1. Relay the event to the receiver via socket (covers foreground)
2. Send an FCM data message (covers background/killed)

```js
// Node.js example
const admin = require('firebase-admin');

socket.on('call_offer', async (data) => {
  const { callerId, receiverId, roomName, callType, callerName, callerAvatar } = data;

  // 1. Relay via socket — instant when receiver is online
  onlineUsers.get(receiverId)?.emit('incoming_call', data);

  // 2. Send FCM — wakes the device when socket is dead
  const { fcmToken } = await db.users.findById(receiverId);
  if (!fcmToken) return;

  await admin.messaging().send({
    token: fcmToken,
    data: {
      type:         'incoming_call',
      callerId:     callerId,
      receiverId:   receiverId,
      roomName:     roomName,
      callType:     callType,            // 'audio' | 'video'
      callerName:   callerName  ?? '',
      callerAvatar: callerAvatar ?? '',
    },
    android: { priority: 'high' },
    apns: {
      headers: { 'apns-push-type': 'voip', 'apns-priority': '10' },
    },
  });
});
```

Your app receives this payload and handles it in `_handleForegroundFcm` (Step 6) or in `_firebaseBackgroundHandler` (Step 3).

---

## Step 9 — Handle background / killed state

When the app is killed, `_firebaseBackgroundHandler` in `main.dart` is called in a separate isolate. Use `navigatorKey` to navigate to the call screen.

```dart
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  final data = message.data;
  if (data['type'] != 'incoming_call') return;

  final isVideo     = data['callType'] == 'video';
  final callType    = isVideo ? CallType.video : CallType.audio;
  final callerName  = data['callerName']   ?? 'Unknown';
  final callerAvatar= data['callerAvatar'] as String?;
  final callerId    = data['callerId']     ?? '';
  final receiverId  = data['receiverId']   ?? '';
  final roomName    = data['roomName']     as String?;

  // navigatorKey must be the same instance passed to MaterialApp
  navigatorKey.currentState?.push(MaterialPageRoute(
    builder: (_) => IncomingCallScreen(
      callerName:   callerName,
      callerAvatar: callerAvatar,
      callType:     callType,
      onAccept: () {
        navigatorKey.currentState?.pop();
        navigatorKey.currentState?.push(MaterialPageRoute(
          builder: (_) => isVideo
              ? VideoCallScreen(
                  userToken:            yourStoredJwt,
                  callerId:             callerId,
                  receiverId:           receiverId,
                  roomName:             roomName,
                  isIncoming:           true,
                  incomingCallerName:   callerName,
                  incomingCallerAvatar: callerAvatar,
                )
              : AudioCallScreen(
                  userToken:   yourStoredJwt,
                  callerId:    callerId,
                  receiverId:  receiverId,
                  roomName:    roomName,
                  isIncoming:  true,
                  callerName:  callerName,
                  callerAvatar:callerAvatar,
                ),
        ));
      },
      onDecline: () {
        navigatorKey.currentState?.pop();
        // Optionally emit call_reject via socket here
      },
    ),
  ));
}
```

> **`yourStoredJwt`**: read the JWT from secure storage (`flutter_secure_storage`) so it is available in the background isolate.

---

## Callbacks reference

All three callbacks are optional and fire exactly once per call.

| Callback | When it fires | Common use |
|---|---|---|
| `onCallStarted` | SDK state → `connecting` | Mark user as "busy", log call start |
| `onCallConnected` | SDK state → `connected` | Start analytics, show call quality UI |
| `onCallEnded(Duration)` | Either side hangs up | Mark user as "online", log call duration |

---

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| Forgetting `isIncoming: true` | SDK dials a second call instead of joining the room | Always pass `isIncoming: true` when answering |
| Not calling `registerUser` after reconnect | Incoming calls stop arriving after a network drop | Listen to `onConnect` and call `registerUser` again |
| FCM token not uploaded | Receiver never wakes up from background | Call `_registerFcmToken()` after login |
| Using `context` in background handler | Crash — no widget tree in background isolate | Use `navigatorKey.currentState` instead |
| Wrong `callerId`/`receiverId` on answer | Room mismatch, call fails to connect | On the receiver side: `callerId` = the caller's ID, `receiverId` = your own ID |

---

## Full working example

See `iq_live_demo/lib/main.dart` in this repo for a complete working demo of everything above.
