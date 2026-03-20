# social_iq_live_sdk

A Flutter UI SDK for **live broadcast** (with real-time comments & reactions), **1:1 video calls**, **1:1 audio calls**, and **group calls** — powered by LiveKit and Socket.IO.

---

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  social_iq_live_sdk:
    git:
      url: https://github.com/yourcompany/social_iq_live_sdk
```

### Android permissions (`android/app/src/main/AndroidManifest.xml`)

```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
```

### iOS permissions (`ios/Runner/Info.plist`)

```xml
<key>NSCameraUsageDescription</key>
<string>Camera is required for video calls</string>
<key>NSMicrophoneUsageDescription</key>
<string>Microphone is required for calls</string>
```

---

## Setup (once in `main.dart`)

```dart
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SocialIqLiveSdk.initialize(
    serverUrl:  'wss://livekit.yourapp.com',   // or ws://localhost:7880 for dev
    socketUrl:  'https://api.yourapp.com',
    apiBaseUrl: 'https://api.yourapp.com',
  );

  runApp(MyApp());
}
```

---

## Live Broadcast

### Host (start a live stream)

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => LiveBroadcastHost(
    userToken:   authToken,      // your backend JWT
    identity:    userId,         // your user ID
    displayName: userName,
    avatarUrl:   userAvatarUrl,  // optional
    title:       'My Live',      // optional
    onLiveEnded: (duration) {
      print('Streamed for ${duration.inMinutes} minutes');
    },
  ),
));
```

### Viewer (join a live stream)

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => LiveBroadcastViewer(
    userToken:   authToken,
    identity:    myUserId,
    displayName: myName,
    roomName:    'live_$hostUserId',   // room is always "live_" + host's userId
    hostName:    hostDisplayName,
    hostAvatar:  hostAvatarUrl,
    onLiveEnded: () => Navigator.pop(context),
  ),
));
```

---

## Video Call

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => VideoCallScreen(
    userToken:    authToken,
    callerId:     myUserId,
    receiverId:   otherUserId,
    receiverName: otherUserName,
    receiverAvatar: otherUserAvatar,
    onCallEnded: (duration) {
      print('Call lasted ${duration.inSeconds}s');
    },
  ),
));
```

---

## Audio Call

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => AudioCallScreen(
    userToken:    authToken,
    callerId:     myUserId,
    receiverId:   otherUserId,
    receiverName: otherUserName,
    receiverAvatar: otherUserAvatar,
    onCallEnded: (duration) {},
  ),
));
```

---

## Group Call

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => GroupCallScreen(
    userToken:   authToken,
    identity:    myUserId,
    displayName: myName,
    avatarUrl:   myAvatar,
    roomName:    'group_$groupId',
    onCallEnded: (duration) {},
  ),
));
```

---

## Incoming Call screen

Show this when you receive a push notification or socket event for an incoming call:

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => IncomingCallScreen(
    callerName:   callerName,
    callerAvatar: callerAvatar,
    callType:     CallType.video,  // or CallType.audio / CallType.group
    onAccept: () {
      Navigator.pop(context); // dismiss incoming screen
      // then push VideoCallScreen / AudioCallScreen with isIncoming: true
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => VideoCallScreen(
          userToken:  authToken,
          callerId:   myUserId,
          receiverId: callerUserId,
          isIncoming: true,
        ),
      ));
    },
    onDecline: () => Navigator.pop(context),
  ),
));
```

---

## SDK File Structure

```
lib/
├── social_iq_live_sdk.dart       # Main export + SocialIqLiveSdk.initialize()
└── src/
    ├── theme/
    │   └── sdk_theme.dart        # Colors, gradients, text styles
    ├── models/
    │   ├── live_config.dart      # LiveConfig, LiveComment, LiveReaction
    │   └── call_config.dart      # CallConfig, CallType, CallState, CallParticipant
    ├── services/
    │   ├── livekit_service.dart  # LiveKit room connection & track management
    │   ├── api_service.dart      # Backend HTTP calls (token generation)
    │   └── socket_service.dart   # Socket.IO for comments & reactions
    ├── controllers/
    │   ├── live_controller.dart  # Live broadcast state management
    │   ├── call_controller.dart  # Call state, duration timer, toggles
    │   └── socket_controller.dart
    └── widgets/
        ├── live_broadcast_host.dart    # Full-screen host view
        ├── live_broadcast_viewer.dart  # Full-screen viewer view
        ├── video_call_screen.dart      # 1:1 video call
        ├── audio_call_screen.dart      # 1:1 audio call
        ├── group_call_screen.dart      # Multi-participant grid
        ├── incoming_call_screen.dart   # Accept/decline UI with ripple animation
        ├── comment_overlay.dart        # Scrolling comment list + input field
        └── reaction_animation.dart     # Floating emoji animations + reaction bar
```
