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
  │                        │── FCM notification ──────────►│  app background/killed
  │                        │                               │
  │         receiver accepts                               │
  │◄── socket: call_accepted ──────────────────────────────│
  │                        │                               │
  │◄═══════ both join LiveKit room, media flows ══════════►│
```

When the app is **foreground**, the socket delivers `incoming_call` directly.
When the app is **background or killed**, your backend sends an FCM notification — your app handles the wakeup and navigates to the call screen.

---

## 1. Initialize — `main.dart`

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
    // Microphone denied — show a dialog and direct user to Settings
    // result.anyPermanentlyDenied == true → use openAppSettings()
  }

  runApp(const MyApp());
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
    onCallStarted:   () => setStatus('on_a_call'),  // state → connecting
    onCallConnected: () => startLogging(),           // state → connected, media live
    onCallEnded: (duration) => setStatus('online'), // call finished
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

## 3. Callbacks

All three are optional and fire exactly once.

| Callback | When |
|---|---|
| `onCallStarted` | State → `connecting` — call initiated or answered |
| `onCallConnected` | State → `connected` — LiveKit joined, media flowing |
| `onCallEnded(Duration)` | State → `ended` — either side hung up |

---

## 4. Receive a call (foreground)

Add this to your top-level widget after login:

```dart
class _HomeState extends State<Home> {
  final _socket = SocketService();

  @override
  void initState() {
    super.initState();
    _socket.connect(url: SocialIqLiveSdkConfig.socketUrl, authToken: myJwt);
    _socket.registerUser(myUserId);

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
  }

  void _openCallScreen(Map<String, dynamic> data, bool isVideo) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => isVideo
          ? VideoCallScreen(
              userToken:            myJwt,
              callerId:             data['callerId'],
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
              callerId:    data['callerId'],
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

## 5. Background calls — FCM notification

When the receiver's app is background or killed, send an FCM **data message** from your backend. Your existing Firebase setup in the app handles waking the device and showing the call screen.

### Backend — send FCM on `call_offer`

```js
const admin = require('firebase-admin');

socket.on('call_offer', async (data) => {
  const { callerId, receiverId, roomName, callType, callerName, callerAvatar } = data;

  // 1. Relay via socket — instant when receiver is online
  onlineUsers.get(receiverId)?.emit('incoming_call', data);

  // 2. Send FCM — wakes the device when socket is dead
  const { fcmToken } = await db.users.findById(receiverId);
  if (fcmToken) {
    await admin.messaging().send({
      token: fcmToken,

      // Data-only (no notification block) — your app handles the UI
      data: {
        type:         'incoming_call',
        callerId:     callerId,
        receiverId:   receiverId,
        roomName:     roomName,
        callType:     callType,           // 'audio' | 'video'
        callerName:   callerName  ?? '',
        callerAvatar: callerAvatar ?? '',
      },

      android: { priority: 'high' },     // bypass Doze mode
      apns: {
        headers: { 'apns-push-type': 'voip', 'apns-priority': '10' },
      },
    });
  }
});

// When caller cancels — dismiss any ringing UI on receiver's device
socket.on('call_end', async (data) => {
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

### FCM payload your app receives

```json
{
  "type":         "incoming_call",
  "callerId":     "user_123",
  "receiverId":   "user_456",
  "roomName":     "call_user_123_user_456",
  "callType":     "video",
  "callerName":   "John",
  "callerAvatar": "https://..."
}
```

Your Firebase message handler opens `VideoCallScreen` or `AudioCallScreen` with `isIncoming: true` using the data above.

### Store FCM tokens

```js
// POST /v1/api/fcm-token  { userId, token, platform }
app.post('/v1/api/fcm-token', auth, async (req, res) => {
  const { userId, token, platform } = req.body;
  await db.users.update({ id: userId }, { fcmToken: token, fcmPlatform: platform });
  res.json({ status: 'ok' });
});
```

```dart
// After login — upload token and re-upload on rotation
final token = await FirebaseMessaging.instance.getToken();
await http.post(Uri.parse('$apiBaseUrl/v1/api/fcm-token'), ...);
FirebaseMessaging.instance.onTokenRefresh.listen((_) => uploadToken());
```

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

**HTTP**

| Method | Endpoint | Body | Returns |
|---|---|---|---|
| POST | `/v1/api/get-token` | `{ callerId, receiverId, room }` | `{ livekitUrl, callerToken, receiverToken }` |
| POST | `/v1/api/end-call` | `{ roomName }` | `{ status }` |
| POST | `/v1/api/fcm-token` | `{ userId, token, platform }` | `{ status }` |

**Socket.IO**

| Direction | Event | Fields |
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
| "Calling…" forever | Check `register_user` is called; check FCM token is stored on backend |
| Receiver not notified (foreground) | Socket not connected or `register_user` not emitted after connect |
| Receiver not notified (background) | FCM token missing or `call_offer` handler not sending FCM |
| "Failed to connect" after accept | Wrong LiveKit URL, or UDP 50000–60000 blocked → enable TURN in `livekit.yaml` |
| No audio / one-sided | Mic permission denied, or speaker routing wrong |
| Call drops on mobile data | UDP blocked by carrier → enable TURN |
