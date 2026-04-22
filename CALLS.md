# Audio & Video Calls — Integration Guide

Covers 1:1 **audio** and **video** calls including background/killed-app notifications via Firebase + CallKit.
For live broadcasts or group calls, see [doc.md](doc.md).

---

## Table of contents

1. [How calls work](#1-how-calls-work)
2. [Basic setup (foreground only)](#2-basic-setup-foreground-only)
3. [Make an outgoing call](#3-make-an-outgoing-call)
4. [Call lifecycle callbacks](#4-call-lifecycle-callbacks)
5. [Receive a call (foreground)](#5-receive-a-call-foreground)
6. [Background & killed-app calls — Firebase + CallKit](#6-background--killed-app-calls--firebase--callkit)
   - [6.1 App dependencies](#61-app-dependencies)
   - [6.2 Backend changes](#62-backend-changes)
   - [6.3 Flutter wiring](#63-flutter-wiring)
   - [6.4 Android platform setup](#64-android-platform-setup)
   - [6.5 iOS platform setup](#65-ios-platform-setup)
7. [Controls reference](#7-controls-reference)
8. [Backend contract](#8-backend-contract)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. How calls work

```
CALLER                         BACKEND                        RECEIVER
  │                               │                               │
  │── POST /v1/api/get-token ─────►│                               │
  │◄── { callerToken,             │                               │
  │      receiverToken,           │                               │
  │      livekitUrl } ────────────│                               │
  │                               │                               │
  │── socket: call_offer ─────────►│── socket: incoming_call ─────►│  (foreground)
  │                               │── FCM data message ───────────►│  (background/killed)
  │                               │                               │
  │             receiver taps Accept                              │
  │                               │◄── socket: call_answer ───────│
  │◄── socket: call_accepted ─────│                               │
  │                               │                               │
  │── joins LiveKit room ─────────────────────────────────────────►│
  │◄──────────── both in room, media flows ───────────────────────►│
```

**The gap without Firebase:** Socket.IO requires the app to be running. Android's Doze mode suspends WebSockets within ~30 s of backgrounding. iOS kills them in ~5 s. Firebase FCM wakes the device and shows a native call UI via `flutter_callkit_incoming` (CallKit on iOS, a heads-up notification on Android).

---

## 2. Basic setup (foreground only)

### SDK init — `main.dart`

```dart
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final result = await SocialIqLiveSdk.initialize(
    serverUrl:  'wss://livekit.yourapp.com',
    socketUrl:  'https://api.yourapp.com',
    apiBaseUrl: 'https://api.yourapp.com',
  );

  if (!result.canMakeCalls) {
    // Mic denied — show a dialog directing the user to system Settings.
    // result.anyPermanentlyDenied == true means .openAppSettings() is needed.
  }

  runApp(const MyApp());
}
```

---

## 3. Make an outgoing call

### Audio call

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => AudioCallScreen(
    userToken:     myJwt,
    callerId:      myUserId,
    receiverId:    otherUserId,
    callerName:    myName,           // shown on receiver's incoming screen
    callerAvatar:  myAvatarUrl,
    receiverName:  otherName,        // shown on MY "calling…" screen
    receiverAvatar: otherAvatarUrl,
    onCallStarted:   () { },         // state → connecting
    onCallConnected: () { },         // state → connected, media live
    onCallEnded: (duration) => debugPrint('Call: $duration'),
  ),
));
```

### Video call

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
    onCallStarted:   () { },
    onCallConnected: () { },
    onCallEnded: (duration) { },
  ),
));
```

Both screens handle LiveKit connect, mute, speaker toggle, camera flip, and end-call.
They auto-close when the other side rejects or hangs up, and time out after **45 s** if unanswered.
Video calls publish at **720p @ 30 fps / 1700 kbps**. Audio calls use DTX + RED.

---

## 4. Call lifecycle callbacks

Both `AudioCallScreen` and `VideoCallScreen` expose three callbacks that fire exactly once each at the corresponding state transition:

| Callback | Fires when | Typical use |
|---|---|---|
| `onCallStarted` | State → `connecting` — immediately on initiation or answer | Update user status to "on a call", hide dialler UI, start logging |
| `onCallConnected` | State → `connected` — LiveKit joined, media flowing | Analytics, call-quality monitoring, show in-call badge elsewhere in app |
| `onCallEnded(Duration)` | State → `ended` — either side hung up | Restore user status, save call history, show call summary |

### Audio call with all callbacks

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => AudioCallScreen(
    userToken:    myJwt,
    callerId:     myUserId,
    receiverId:   otherUserId,
    callerName:   myName,
    callerAvatar: myAvatarUrl,
    receiverName:  otherName,
    receiverAvatar: otherAvatarUrl,

    onCallStarted: () {
      // Fires at CallState.connecting
      updateUserStatus('on_a_call');
    },
    onCallConnected: () {
      // Fires at CallState.connected — media is live
      startCallLogging(roomName);
    },
    onCallEnded: (duration) {
      updateUserStatus('online');
      saveCallHistory(duration);
    },
  ),
));
```

### Video call with all callbacks

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => VideoCallScreen(
    userToken:    myJwt,
    callerId:     myUserId,
    receiverId:   otherUserId,
    callerName:   myName,
    callerAvatar: myAvatarUrl,
    receiverName:  otherName,
    receiverAvatar: otherAvatarUrl,

    onCallStarted: () {
      updateUserStatus('on_a_call');
    },
    onCallConnected: () {
      startCallLogging(roomName);
    },
    onCallEnded: (duration) {
      updateUserStatus('online');
      saveCallHistory(duration);
    },
  ),
));
```

> All three callbacks are optional. You can provide any combination or none.

---

## 5. Receive a call (foreground)

Listen on a top-level widget (e.g. `HomeScreen`) after login. This path works when the app is in the foreground:

```dart
class _HomeState extends State<Home> {
  final _socket = SocketService();

  @override
  void initState() {
    super.initState();
    _socket.connect(url: SocialIqLiveSdkConfig.socketUrl, authToken: myJwt);
    _socket.registerUser(myUserId);

    _socket.onIncomingCall.listen(_handleIncomingCall);
  }

  void _handleIncomingCall(Map<String, dynamic> data) {
    final isVideo = data['callType'] == 'video';
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => IncomingCallScreen(
        callerName:   data['callerName']   ?? 'Unknown',
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
  }

  void _openCallScreen(Map<String, dynamic> data, bool isVideo) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => isVideo
          ? VideoCallScreen(
              userToken:           myJwt,
              callerId:            data['callerId'],
              receiverId:          myUserId,
              roomName:            data['roomName'],
              isIncoming:          true,
              incomingCallerName:  data['callerName'],
              incomingCallerAvatar: data['callerAvatar'],
            )
          : AudioCallScreen(
              userToken:   myJwt,
              callerId:    data['callerId'],
              receiverId:  myUserId,
              roomName:    data['roomName'],
              isIncoming:  true,
              callerName:  data['callerName'],
              callerAvatar: data['callerAvatar'],
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

## 6. Background & killed-app calls — Firebase + CallKit

### 6.1 App dependencies

Add to your **app's** `pubspec.yaml` (not the SDK — Firebase config is per-app):

```yaml
dependencies:
  firebase_core: ^3.6.0
  firebase_messaging: ^15.1.3
  # flutter_callkit_incoming is already pulled in by the SDK — no need to re-add
```

Run:
```bash
flutter pub get
```

### 6.2 Backend changes

Your Node.js server needs two additions.

**A — Store FCM tokens**

Add an endpoint the app calls after login:

```js
// POST /v1/api/fcm-token
// Body: { userId, token, platform }   platform = 'android' | 'ios'
app.post('/v1/api/fcm-token', auth, async (req, res) => {
  const { userId, token, platform } = req.body;
  await db.users.update({ id: userId }, { fcmToken: token, fcmPlatform: platform });
  res.json({ status: 'ok' });
});
```

**B — Send FCM on `call_offer`**

In your socket handler, push an FCM message alongside (or instead of) the socket relay:

```js
const admin = require('firebase-admin');

socket.on('call_offer', async (data) => {
  const { callerId, receiverId, roomName, callType, callerName, callerAvatar } = data;

  // 1. Always relay via socket — instant delivery when receiver is foreground.
  const receiverSocket = onlineUsers.get(receiverId);
  if (receiverSocket) {
    receiverSocket.emit('incoming_call', data);
  }

  // 2. Always send FCM — wakes the device when socket is dead.
  const user = await db.users.findById(receiverId);
  if (user?.fcmToken) {
    await admin.messaging().send({
      token: user.fcmToken,

      // Use only 'data' (no 'notification' block) so the app handles the UI
      // via flutter_callkit_incoming instead of showing a regular notification.
      data: {
        type:        'incoming_call',
        callerId:    callerId,
        receiverId:  receiverId,
        roomName:    roomName,
        callType:    callType,          // 'audio' | 'video'
        callerName:  callerName  ?? '',
        callerAvatar: callerAvatar ?? '',
      },

      android: {
        priority: 'high',               // bypasses Doze mode
      },

      apns: {
        headers: {
          'apns-push-type': 'voip',     // triggers immediate iOS wakeup via PushKit
          'apns-priority':  '10',
        },
      },
    });
  }
});
```

> **Deduplication:** Both the socket and FCM paths may fire when the receiver is foreground. Guard against this by tracking the `roomName` — if `CallNotificationHandler.showIncomingCall` is called for a room already visible, `flutter_callkit_incoming` deduplicates by the `id` field (= `roomName`).

### 6.3 Flutter wiring

**A — `main.dart`** — Firebase init + background handler + CallKit listener

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

// Must be a top-level function — runs in a separate isolate when app is killed.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  if (message.data['type'] == 'incoming_call') {
    await CallNotificationHandler.showIncomingCall(message.data);
  }
}

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

  // Initialize SDK (requests mic + camera permissions).
  await SocialIqLiveSdk.initialize(
    serverUrl:  'wss://livekit.yourapp.com',
    socketUrl:  'https://api.yourapp.com',
    apiBaseUrl: 'https://api.yourapp.com',
  );

  // Start listening for CallKit accept / decline taps.
  CallNotificationHandler.initialize();

  runApp(MyApp(navigatorKey: navigatorKey));
}
```

**B — Upload FCM token after login**

```dart
Future<void> registerFcmToken(String myJwt) async {
  final token = await FirebaseMessaging.instance.getToken();
  if (token == null) return;

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

  // Re-upload if the token rotates.
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
    // call same endpoint with newToken
  });
}
```

**C — Handle foreground FCM (optional but recommended)**

If you want the native call UI even when the app is foreground (single consistent path instead of both socket + `IncomingCallScreen`):

```dart
// In initState of your top-level widget, alongside the socket listener:
FirebaseMessaging.onMessage.listen((message) {
  if (message.data['type'] == 'incoming_call') {
    CallNotificationHandler.showIncomingCall(message.data);
  }
});
```

**D — Listen for CallKit accept / decline** (top-level widget, e.g. `HomeScreen`)

```dart
@override
void initState() {
  super.initState();

  // Accept — open the call screen
  CallNotificationHandler.onCallAccepted.listen((data) {
    final isVideo = data['callType'] == 'video';
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
              onCallStarted:   () => updateUserStatus('on_a_call'),
              onCallConnected: () => startCallLogging(data['roomName']),
              onCallEnded: (_)     => updateUserStatus('online'),
            )
          : AudioCallScreen(
              userToken:   myJwt,
              callerId:    data['callerId']!,
              receiverId:  myUserId,
              roomName:    data['roomName'],
              isIncoming:  true,
              callerName:  data['callerName'],
              callerAvatar: data['callerAvatar'],
              onCallStarted:   () => updateUserStatus('on_a_call'),
              onCallConnected: () => startCallLogging(data['roomName']),
              onCallEnded: (_)     => updateUserStatus('online'),
            ),
    ));
  });

  // Decline — tell the caller
  CallNotificationHandler.onCallDeclined.listen((data) {
    _socket.rejectCall(
      callerId:   data['callerId']!,
      receiverId: myUserId,
    );
  });
}
```

**E — Dismiss CallKit UI when the caller cancels**

When the caller hangs up before the receiver answers, the CallKit screen must be dismissed too. Add this to the backend: when a `call_end` socket event arrives for a call that hasn't been answered yet, send another FCM data message:

```js
// backend
data: { type: 'call_cancelled', roomName: roomName }
```

```dart
// Flutter — in your FCM handlers (both background and foreground)
if (message.data['type'] == 'call_cancelled') {
  await CallNotificationHandler.endCall(message.data['roomName']!);
}
```

### 6.4 Android platform setup

1. Add `google-services.json` to `android/app/`.

2. In `android/build.gradle` (project level):
```groovy
dependencies {
  classpath 'com.google.gms:google-services:4.4.2'
}
```

3. In `android/app/build.gradle`:
```groovy
apply plugin: 'com.google.gms.google-services'
```

4. In `android/app/src/main/AndroidManifest.xml`, inside `<application>`:
```xml
<!-- Required by flutter_callkit_incoming for the full-screen call UI -->
<activity
    android:name="com.hiennv.flutter_callkit_incoming.CallkitIncomingActivity"
    android:exported="false" />

<receiver
    android:name="com.hiennv.flutter_callkit_incoming.CallkitIncomingBroadcastReceiver"
    android:exported="false" />

<!-- Required for FCM background handler -->
<service
    android:name="com.google.firebase.messaging.FirebaseMessagingService"
    android:exported="false">
  <intent-filter>
    <action android:name="com.google.firebase.MESSAGING_EVENT" />
  </intent-filter>
</service>
```

5. For Android 13+ (API 33), request notification permission on first launch:
```dart
await FirebaseMessaging.instance.requestPermission();
// flutter_callkit_incoming also exposes:
await FlutterCallkitIncoming.requestNotificationPermission({});
// For Android 14+ full-screen intent permission:
await FlutterCallkitIncoming.requestFullIntentPermission();
```

### 6.5 iOS platform setup

**A — Xcode capabilities** (Runner target → Signing & Capabilities):
- Push Notifications
- Background Modes → check:
  - Voice over IP
  - Background fetch
  - Remote notifications

**B — VoIP certificate**

Apple requires a **separate VoIP certificate** (`.p12`) to send `apns-push-type: voip` pushes. Regular APNs certs cannot send VoIP pushes.

1. In [developer.apple.com](https://developer.apple.com) → Certificates — create a **VoIP Services Certificate** for your App ID.
2. Export it as `.p12`.
3. In Firebase Console → Project Settings → Cloud Messaging → APNs Authentication Key **or** APNs Certificates — upload the **VoIP** `.p12` under the **APNs Certificates** section.

> If you skip VoIP certificates and use a regular push, iOS will throttle incoming-call pushes and your app will not reliably wake in the background. VoIP push is the only Apple-sanctioned way to trigger CallKit reliably.

**C — `Info.plist`** — no extra keys needed; `flutter_callkit_incoming` configures CallKit via code.

**D — `AppDelegate.swift`** — no changes needed for Flutter; the plugin handles PushKit registration automatically when the app first runs.

---

## 7. Controls reference

| Action | AudioCallScreen | VideoCallScreen |
|---|---|---|
| Mute / Unmute mic | ✅ | ✅ |
| Toggle speaker | ✅ | — |
| Toggle camera on/off | — | ✅ |
| Flip front / back camera | — | ✅ |
| End call | ✅ | ✅ |
| Auto-close on remote end | ✅ | ✅ |
| Reconnecting indicator | ✅ `isReconnecting` | ✅ `isReconnecting` |

---

## 8. Backend contract

### HTTP endpoints

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/v1/api/get-token` | `{ callerId, receiverId, room }` | `{ livekitUrl, callerToken, receiverToken }` |
| POST | `/v1/api/end-call` | `{ roomName }` | `{ status }` |
| POST | `/v1/api/fcm-token` | `{ userId, token, platform }` | `{ status }` |

### Socket.IO events

| Direction | Event | Key fields |
|---|---|---|
| client → server | `register_user` | `{ userId }` |
| client → server | `call_offer` | `{ callerId, receiverId, roomName, callType, callerName, callerAvatar }` |
| client → server | `call_answer` | `{ callerId, receiverId, roomName }` |
| client → server | `call_reject` | `{ callerId, receiverId }` |
| client → server | `call_end` | `{ callerId, receiverId }` |
| server → client | `incoming_call` | same as `call_offer` |
| server → client | `call_accepted` | — |
| server → client | `call_rejected` | — |
| server → client | `call_ended` | — |

---

## 9. Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Calling…" forever, receiver never notified | Receiver socket not registered; or FCM token not stored; or backend not sending FCM |
| CallKit screen shows but accept does nothing | `CallNotificationHandler.initialize()` not called at startup |
| App crashes on accept from killed state | `navigatorKey` not passed to `MaterialApp`; or app state not restored before navigation |
| "Failed to connect" after accept | LiveKit URL wrong, or UDP 50000-60000 blocked (enable TURN in livekit config) |
| iOS CallKit never fires from background | VoIP certificate not configured; regular APNs cert cannot send `apns-push-type: voip` |
| Android call notification not full-screen on lock screen | `isShowFullLockedScreen: true` set but `USE_FULL_SCREEN_INTENT` permission denied on Android 14+ — call `requestFullIntentPermission()` |
| Duplicate incoming call screens | Both socket and FCM fired for a foreground app — expected; `flutter_callkit_incoming` deduplicates by `id` (roomName) |
| No audio / one-way audio | Mic permission denied; or speaker routing wrong — check `isSpeakerOn` state |
| Call ends immediately on mobile data | UDP blocked by carrier — enable TURN server in `livekit.yaml` |
