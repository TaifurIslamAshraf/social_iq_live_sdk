# Audio & Video Calls

> For live broadcasts or group calls see [doc.md](doc.md).

---

## How it works

```
Caller                    Backend                   Receiver
  │── get-token ─────────►│                               │
  │◄── callerToken ────────│                               │
  │                        │                               │
  │── socket: call_offer ─►│── socket: incoming_call ─────►│  app foreground
  │                        │── FCM push ──────────────────►│  app background/killed
  │                        │                               │
  │         receiver accepts                               │
  │◄── socket: call_accepted ──────────────────────────────│
  │                        │                               │
  │◄═══════ both join LiveKit room, media flows ══════════►│
```

Without Firebase, Socket.IO dies when the app is backgrounded (~30 s Android, ~5 s iOS). FCM wakes the device and shows a native call UI via `flutter_callkit_incoming`.

---

## 1. Initialize — `main.dart`

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

// Top-level function — runs in its own isolate when app is killed
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
  if (message.data['type'] == 'incoming_call') {
    await CallNotificationHandler.showIncomingCall(message.data);
  }
  if (message.data['type'] == 'call_cancelled') {
    await CallNotificationHandler.endCall(message.data['roomName']!);
  }
}

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);

  final result = await SocialIqLiveSdk.initialize(
    serverUrl:  'wss://livekit.yourapp.com',
    socketUrl:  'https://api.yourapp.com',
    apiBaseUrl: 'https://api.yourapp.com',
  );

  if (!result.canMakeCalls) {
    // Microphone denied — show a dialog and direct user to Settings
    // result.anyPermanentlyDenied == true → use openAppSettings()
  }

  // Start listening for CallKit accept/decline taps
  CallNotificationHandler.initialize();

  runApp(MyApp(navigatorKey: navigatorKey));
}
```

---

## 2. Make an outgoing call

### Audio

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => AudioCallScreen(
    userToken:     myJwt,
    callerId:      myUserId,
    receiverId:    otherUserId,
    callerName:    myName,          // shown on receiver's ringing screen
    callerAvatar:  myAvatarUrl,
    receiverName:  otherName,       // shown on your own "Calling…" screen
    receiverAvatar: otherAvatarUrl,
    onCallStarted:   () => setStatus('on_a_call'),   // state → connecting
    onCallConnected: () => startLogging(),            // state → connected, media live
    onCallEnded: (duration) => setStatus('online'),  // call finished
  ),
));
```

### Video

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => VideoCallScreen(
    userToken:     myJwt,
    callerId:      myUserId,
    receiverId:    otherUserId,
    callerName:    myName,
    callerAvatar:  myAvatarUrl,
    receiverName:  otherName,
    receiverAvatar: otherAvatarUrl,
    onCallStarted:   () => setStatus('on_a_call'),
    onCallConnected: () => startLogging(),
    onCallEnded: (duration) => setStatus('online'),
  ),
));
```

Video publishes at **720p @ 30 fps / 1700 kbps**. Calls auto-close after **45 s** if unanswered or when the other side hangs up.

---

## 3. Callbacks reference

All three callbacks are optional and fire exactly once each.

| Callback | When it fires |
|---|---|
| `onCallStarted` | State → `connecting` — call initiated or answered |
| `onCallConnected` | State → `connected` — LiveKit joined, media flowing |
| `onCallEnded(Duration)` | State → `ended` — either side hung up |

---

## 4. Receive a call (foreground)

Add this to your top-level widget (e.g. `HomeScreen`) after login:

```dart
class _HomeState extends State<Home> {
  final _socket = SocketService();

  @override
  void initState() {
    super.initState();
    _socket.connect(url: SocialIqLiveSdkConfig.socketUrl, authToken: myJwt);
    _socket.registerUser(myUserId);

    // Foreground: socket delivers the call
    _socket.onIncomingCall.listen((data) {
      final isVideo = data['callType'] == 'video';
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => IncomingCallScreen(
          callerName:   data['callerName'] ?? 'Unknown',
          callerAvatar: data['callerAvatar'],
          callType: isVideo ? CallType.video : CallType.audio,
          onAccept: () {
            Navigator.pop(context);
            _openCallScreen(data, isVideo);
          },
          onDecline: () {
            _socket.rejectCall(callerId: data['callerId'], receiverId: myUserId);
            Navigator.pop(context);
          },
        ),
      ));
    });

    // Background/killed: CallKit delivers the call — listen for accept/decline
    CallNotificationHandler.onCallAccepted.listen((data) {
      _openCallScreen(data, data['callType'] == 'video');
    });
    CallNotificationHandler.onCallDeclined.listen((data) {
      _socket.rejectCall(callerId: data['callerId']!, receiverId: myUserId);
    });

    // Foreground FCM — show native call UI for consistency (optional)
    FirebaseMessaging.onMessage.listen((msg) {
      if (msg.data['type'] == 'incoming_call') {
        CallNotificationHandler.showIncomingCall(msg.data);
      }
      if (msg.data['type'] == 'call_cancelled') {
        CallNotificationHandler.endCall(msg.data['roomName']!);
      }
    });
  }

  void _openCallScreen(Map<String, dynamic> data, bool isVideo) {
    navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => isVideo
          ? VideoCallScreen(
              userToken:            myJwt,
              callerId:             data['callerId']!,
              receiverId:           myUserId,
              roomName:             data['roomName'],
              isIncoming:           true,
              incomingCallerName:   data['callerName'],
              incomingCallerAvatar: data['callerAvatar'],
              onCallStarted:   () => setStatus('on_a_call'),
              onCallConnected: () => startLogging(),
              onCallEnded: (_)     => setStatus('online'),
            )
          : AudioCallScreen(
              userToken:   myJwt,
              callerId:    data['callerId']!,
              receiverId:  myUserId,
              roomName:    data['roomName'],
              isIncoming:  true,
              callerName:  data['callerName'],
              callerAvatar: data['callerAvatar'],
              onCallStarted:   () => setStatus('on_a_call'),
              onCallConnected: () => startLogging(),
              onCallEnded: (_)     => setStatus('online'),
            ),
    ));
  }

  @override
  void dispose() {
    _socket.dispose();
    super.dispose();
  }
}
```

---

## 5. Background calls — Firebase setup

### 5.1 Flutter dependencies (`pubspec.yaml`)

```yaml
dependencies:
  firebase_core: ^3.6.0
  firebase_messaging: ^15.1.3
  # flutter_callkit_incoming — already included by the SDK, no need to add
```

### 5.2 FCM token — upload after login

```dart
Future<void> registerFcmToken() async {
  final token = await FirebaseMessaging.instance.getToken();
  if (token == null) return;

  await http.post(
    Uri.parse('${SocialIqLiveSdkConfig.apiBaseUrl}/v1/api/fcm-token'),
    headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $myJwt'},
    body: jsonEncode({'userId': myUserId, 'token': token, 'platform': Platform.isIOS ? 'ios' : 'android'}),
  );

  FirebaseMessaging.instance.onTokenRefresh.listen((_) => registerFcmToken());
}
```

### 5.3 Backend — send FCM on `call_offer`

```js
const admin = require('firebase-admin');

socket.on('call_offer', async (data) => {
  const { callerId, receiverId, roomName, callType, callerName, callerAvatar } = data;

  // Always relay via socket (instant when receiver is online)
  onlineUsers.get(receiverId)?.emit('incoming_call', data);

  // Always push FCM (wakes the device when socket is dead)
  const { fcmToken } = await db.users.findById(receiverId);
  if (fcmToken) {
    await admin.messaging().send({
      token: fcmToken,
      data: { type: 'incoming_call', callerId, receiverId, roomName, callType,
              callerName: callerName ?? '', callerAvatar: callerAvatar ?? '' },
      android: { priority: 'high' },
      apns: { headers: { 'apns-push-type': 'voip', 'apns-priority': '10' } },
    });
  }
});

// When caller cancels before receiver answers
socket.on('call_end', async (data) => {
  // ... your existing logic ...
  // Also push to dismiss any active CallKit screen on receiver's device
  const { fcmToken } = await db.users.findById(data.receiverId);
  if (fcmToken) {
    await admin.messaging().send({
      token: fcmToken,
      data: { type: 'call_cancelled', roomName: data.roomName ?? '' },
      android: { priority: 'high' },
      apns: { headers: { 'apns-push-type': 'voip', 'apns-priority': '10' } },
    });
  }
});
```

### 5.4 Android setup

1. Add `google-services.json` → `android/app/`

2. `android/build.gradle`:
```groovy
dependencies {
  classpath 'com.google.gms:google-services:4.4.2'
}
```

3. `android/app/build.gradle`:
```groovy
apply plugin: 'com.google.gms.google-services'
```

4. `AndroidManifest.xml` inside `<application>`:
```xml
<activity android:name="com.hiennv.flutter_callkit_incoming.CallkitIncomingActivity" android:exported="false" />
<receiver android:name="com.hiennv.flutter_callkit_incoming.CallkitIncomingBroadcastReceiver" android:exported="false" />
<service android:name="com.google.firebase.messaging.FirebaseMessagingService" android:exported="false">
  <intent-filter><action android:name="com.google.firebase.MESSAGING_EVENT" /></intent-filter>
</service>
```

5. Request permissions on first launch:
```dart
await FirebaseMessaging.instance.requestPermission();
await FlutterCallkitIncoming.requestNotificationPermission({});  // Android 13+
await FlutterCallkitIncoming.requestFullIntentPermission();      // Android 14+
```

### 5.5 iOS setup

**Xcode** → Runner target → Signing & Capabilities → add:
- Push Notifications
- Background Modes → `Voice over IP`, `Background fetch`, `Remote notifications`

**VoIP certificate** (required — regular APNs certs cannot send `apns-push-type: voip`):
1. [developer.apple.com](https://developer.apple.com) → Certificates → create **VoIP Services Certificate**
2. Export as `.p12`
3. Firebase Console → Project Settings → Cloud Messaging → upload under **APNs Certificates**

No changes needed to `Info.plist` or `AppDelegate.swift` — the plugin handles PushKit registration automatically.

---

## 6. Controls

| Control | Audio | Video |
|---|---|---|
| Mute / Unmute | ✅ | ✅ |
| Speaker toggle | ✅ | — |
| Camera on/off | — | ✅ |
| Flip camera | — | ✅ |
| End call | ✅ | ✅ |

---

## 7. Backend API reference

| Method | Endpoint | Body | Returns |
|---|---|---|---|
| POST | `/v1/api/get-token` | `{ callerId, receiverId, room }` | `{ livekitUrl, callerToken, receiverToken }` |
| POST | `/v1/api/end-call` | `{ roomName }` | `{ status }` |
| POST | `/v1/api/fcm-token` | `{ userId, token, platform }` | `{ status }` |

| Direction | Socket event | Fields |
|---|---|---|
| client → server | `register_user` | `{ userId }` |
| client → server | `call_offer` | `{ callerId, receiverId, roomName, callType, callerName, callerAvatar }` |
| client → server | `call_answer` | `{ callerId, receiverId, roomName }` |
| client → server | `call_reject` | `{ callerId, receiverId }` |
| client → server | `call_end` | `{ callerId, receiverId }` |
| server → client | `incoming_call` | same as `call_offer` |
| server → client | `call_accepted` / `call_rejected` / `call_ended` | — |

---

## 8. Troubleshooting

| Problem | Fix |
|---|---|
| "Calling…" forever | Check socket `register_user` is called; check FCM token is stored on backend |
| CallKit shows but Accept does nothing | `CallNotificationHandler.initialize()` missing from `main()` |
| Crash on Accept from killed app | Pass `navigatorKey` to `MaterialApp` |
| "Failed to connect" | Wrong LiveKit URL, or UDP 50000–60000 blocked → enable TURN in `livekit.yaml` |
| iOS CallKit never fires | VoIP certificate not configured — regular APNs won't work |
| Android no full-screen on lock screen | Call `requestFullIntentPermission()` on Android 14+ |
| Double incoming screen | Normal when both socket + FCM fire — `flutter_callkit_incoming` deduplicates by `roomName` |
| No audio / one-sided | Mic permission denied, or speaker routing off |
| Call drops on mobile data | UDP blocked by carrier → enable TURN |
