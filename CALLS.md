# Audio & Video Calls — Quick Start

Only covers 1:1 **audio** and **video** calls. For live broadcasts or group calls, see [doc.md](doc.md).

---

## 1. Initialize once in `main.dart`

```dart
import 'package:flutter/material.dart';
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final result = await SocialIqLiveSdk.initialize(
    serverUrl:  'wss://livekit.yourapp.com',
    socketUrl:  'https://api.yourapp.com',
    apiBaseUrl: 'https://api.yourapp.com',
  );

  // Microphone is required for any call. Camera is required for video calls.
  if (!result.canMakeCalls) {
    debugPrint('Microphone permission denied — calls will not work');
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
    userToken:   myJwt,            // your auth token
    callerId:    myUserId,
    receiverId:  otherUserId,
    callerName:  myName,           // shown on receiver's incoming screen
    callerAvatar: myAvatarUrl,
    receiverName:  otherName,      // shown on MY calling… screen
    receiverAvatar: otherAvatarUrl,
    onCallEnded: (duration) {
      debugPrint('Call lasted $duration');
    },
  ),
));
```

### Video

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => VideoCallScreen(
    userToken:   myJwt,
    callerId:    myUserId,
    receiverId:  otherUserId,
    callerName:  myName,
    callerAvatar: myAvatarUrl,
    receiverName:  otherName,
    receiverAvatar: otherAvatarUrl,
    onCallEnded: (duration) { },
  ),
));
```

Both screens:
- Handle LiveKit connect, mute, speaker toggle, end-call
- Auto-close when the other side rejects or hangs up
- Time out after **45 s** if the receiver never answers

Video call publishes at **720p @ 30 fps, 1700 kbps**. Audio calls use DTX + RED for reliable low-bandwidth speech.

---

## 3. Receive an incoming call

Somewhere in your app (usually a top-level widget after login), listen for incoming-call signals:

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
          callerName:   data['callerName']   ?? 'Unknown',
          callerAvatar: data['callerAvatar'],
          callType: isVideo ? CallType.video : CallType.audio,
          onAccept: () {
            Navigator.pop(context); // close incoming screen
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => isVideo
                  ? VideoCallScreen(
                      userToken:  myJwt,
                      callerId:   data['callerId'],     // the other person
                      receiverId: myUserId,             // you
                      roomName:   data['roomName'],
                      isIncoming: true,
                      incomingCallerName:   data['callerName'],
                      incomingCallerAvatar: data['callerAvatar'],
                    )
                  : AudioCallScreen(
                      userToken:  myJwt,
                      callerId:   data['callerId'],
                      receiverId: myUserId,
                      roomName:   data['roomName'],
                      isIncoming: true,
                      callerName:   data['callerName'],
                      callerAvatar: data['callerAvatar'],
                    ),
            ));
          },
          onDecline: () {
            _socket.rejectCall(
              callerId:   data['callerId'],
              receiverId: myUserId,
            );
            Navigator.pop(context);
          },
        ),
      ));
    });
  }
}
```

---

## 4. Controls available on both screens

| Action | Audio | Video |
|---|---|---|
| Mute / Unmute mic | ✅ | ✅ |
| Toggle speaker | ✅ | — |
| Toggle camera | — | ✅ |
| Flip front / back camera | — | ✅ |
| End call | ✅ | ✅ |

---

## 5. Backend endpoints required

The SDK calls these on your API (`apiBaseUrl`):

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/api/get-token` | Returns `{ livekitUrl, callerToken, receiverToken }` |
| POST | `/v1/api/end-call` | Closes the LiveKit room |

And these Socket.IO events:

| Direction | Event | Payload |
|---|---|---|
| client → server | `register_user` | `{ userId }` |
| client → server | `call_offer` | `{ callerId, receiverId, roomName, callType, callerName, callerAvatar }` |
| client → server | `call_answer` | `{ callerId, receiverId, roomName }` |
| client → server | `call_reject` | `{ callerId, receiverId }` |
| client → server | `call_end` | `{ callerId, receiverId }` |
| server → client | `incoming_call` | same shape as `call_offer` |
| server → client | `call_accepted` / `call_rejected` / `call_ended` | — |

---

## 6. Troubleshooting

| Symptom | Cause |
|---|---|
| "Calling…" forever | Receiver not registered on socket, or `incoming_call` not routed server-side |
| "Failed to connect" on accept | LiveKit URL wrong, or UDP 50000-60000 blocked by firewall |
| No audio / one-way audio | Mic permission denied, or speaker toggled to earpiece |
| Black remote video | Remote side never enabled camera, or low-bandwidth downgrade — check network quality |
| Call ends immediately on mobile data | Likely UDP blocked on carrier; enable TURN in LiveKit config |
