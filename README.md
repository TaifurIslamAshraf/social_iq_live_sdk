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

## Live Broadcast — Comments & Reactions

Comments and reactions are **fully automatic** inside `LiveBroadcastHost` and `LiveBroadcastViewer`. The SDK handles all Socket.IO events internally — you don't need to wire anything up manually.

### How it works under the hood

| Event | Direction | What happens |
|---|---|---|
| `join_live` | Client → Server | Viewer joins the Socket.IO room |
| `leave_live` | Client → Server | Viewer leaves the Socket.IO room |
| `live_comment` | Client ↔ Server | Message is broadcast to every viewer |
| `live_reaction` | Client ↔ Server | Emoji is broadcast and triggers floating animation |
| `viewer_count` | Server → Client | Updates the viewer counter shown on screen |

### Sending a comment (manual / custom UI)

If you are building a **custom viewer UI** and want to send a comment programmatically:

```dart
// You already have a LiveController in your custom widget
liveController.sendComment('Great stream! 🔥');
```

Each comment is broadcast to all viewers with the sender's **name** and **avatar** automatically included.

### Sending a reaction (manual / custom UI)

```dart
// Supported emojis: ❤️ 🔥 😂 👏 😮 🎉
liveController.sendReaction('❤️');
```

### Accessing the comment list

```dart
// Returns List<LiveComment>
final comments = liveController.comments;

// Each LiveComment has:
// comment.userName    → sender's display name
// comment.userAvatar  → sender's avatar URL (nullable)
// comment.message     → the text message
// comment.timestamp   → DateTime when sent
```

### Accessing the reaction list

```dart
// Returns List<LiveReaction> (pending animations)
final reactions = liveController.pendingReactions;

// Each LiveReaction has:
// reaction.emoji      → the emoji string  e.g. "❤️"
// reaction.userName   → sender's display name
```

### Widgets used automatically inside the built-in screens

| Widget | Description |
|---|---|
| `CommentOverlay` | Scrolling semi-transparent list of live comments |
| `CommentInput` | Frosted-glass text field for viewers to type messages |
| `ReactionAnimation` | Floating emoji particles that drift upward |
| `ReactionBar` | Emoji picker row (❤️ 🔥 😂 👏 😮 🎉) |

### Using widgets in a custom screen

```dart
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

// Inside a Stack, e.g. overlaid on a full-screen video:
Stack(
  children: [
    // ... your video widget ...

    // Comment list (bottom-left)
    Positioned(
      left: 0, right: 80, bottom: 100,
      child: CommentOverlay(comments: controller.comments),
    ),

    // Floating reactions (bottom-right)
    Positioned(
      right: 8, bottom: 160,
      child: ReactionAnimation(reactions: controller.pendingReactions),
    ),

    // Input bar + reaction button (very bottom)
    Positioned(
      left: 12, right: 12, bottom: 16,
      child: Row(
        children: [
          Expanded(child: CommentInput(onSubmit: controller.sendComment)),
          const SizedBox(width: 10),
          ReactionBar(onReaction: controller.sendReaction),
        ],
      ),
    ),
  ],
)
```

> **Note:** Make sure `SocialIqLiveSdk.initialize(socketUrl: ...)` is called in `main.dart`. The Socket.IO connection is created automatically when a broadcast starts.

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
