# Social IQ Live — Deployment & Integration Guide

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [LiveKit Server Deployment (Docker)](#livekit-server-deployment)
3. [Backend Environment Variables](#backend-environment-variables)
4. [Flutter SDK Integration](#flutter-sdk-integration)
5. [Complete Example: Adding Live & Call Features](#complete-example)
6. [Live Broadcast — Comments & Reactions](#live-broadcast--comments--reactions)

---

## Architecture Overview

```
┌─────────────────┐      WebSocket (wss://)      ┌──────────────────┐
│  Flutter App     │◄────────────────────────────►│  LiveKit Server  │
│  (social_iq_     │                              │  (Docker)        │
│   live_sdk)      │      HTTP (https://)         │  Port: 7880      │
│                  │◄────────────────────────────►│                  │
│                  │      Socket.IO               ├──────────────────┤
│                  │◄────────────────────────────►│  Your Backend    │
└─────────────────┘                              │  (Node.js)       │
                                                  │  Port: 8000      │
                                                  └──────────────────┘
```

> **Same server or separate?** You can run LiveKit on the **same server** as your backend for small-medium scale (< 500 concurrent users). For production at scale, use a **separate server** with more CPU/RAM because LiveKit handles real-time media which is CPU-intensive.

### Minimum Server Requirements

| Setup | CPU | RAM | Use Case |
|-------|-----|-----|----------|
| Same server | 4 vCPU | 8 GB | Dev/staging, < 100 concurrent streams |
| Separate server | 4+ vCPU | 8+ GB | Production, 100-1000+ concurrent |

---

## LiveKit Server Deployment

### Step 1: Install Docker

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install docker.io docker-compose -y
sudo systemctl enable docker
sudo systemctl start docker
```

### Step 2: Create LiveKit Config

Create `livekit-config.yaml` on your server:

```yaml
port: 7880
log_level: info

rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true

redis:
  address: 127.0.0.1:6379

keys:
  YOUR_API_KEY: YOUR_API_SECRET

webhook:
  api_key: YOUR_API_KEY
  urls:
    - https://your-backend-domain.com/v1/api/livekit/webhook

# Uncomment for production with SSL/TURN:
# turn:
#   enabled: true
#   domain: turn.yourdomain.com
#   tls_port: 3478
```

> **Generate your own keys!** Don't use the defaults. Run:
> ```bash
> openssl rand -base64 12   # for API_KEY
> openssl rand -base64 36   # for API_SECRET
> ```

### Step 3: Run LiveKit with Docker

```bash
# Run on the same server as your backend
docker run -d \
  --name livekit-server \
  --restart unless-stopped \
  -p 7880:7880 \
  -p 7881:7881 \
  -p 50000-60000:50000-60000/udp \
  -v $(pwd)/livekit-config.yaml:/etc/livekit.yaml \
  livekit/livekit-server \
  --config /etc/livekit.yaml
```

### Step 4: Verify LiveKit is Running

```bash
docker ps                           # should show livekit-server
curl http://localhost:7880           # should return a response
docker logs livekit-server           # check for errors
```

### Step 5: Open Firewall Ports

```bash
# Required ports:
sudo ufw allow 7880/tcp    # LiveKit signaling (WebSocket + HTTP API)
sudo ufw allow 7881/tcp    # LiveKit RTC over TCP
sudo ufw allow 50000:60000/udp  # WebRTC media (UDP)
```

### Step 6: Production — Add SSL with Nginx (Recommended)

For production, put LiveKit behind Nginx to get `wss://` (secure WebSocket):

```nginx
# /etc/nginx/sites-available/livekit
server {
    listen 443 ssl;
    server_name livekit.yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/livekit.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/livekit.yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

Then get SSL cert:
```bash
sudo certbot --nginx -d livekit.yourdomain.com
```

---

## Backend Environment Variables

Add these to your backend `.env` file:

```env
# LiveKit Configuration (REQUIRED)
LIVEKIT_API_KEY=YOUR_API_KEY          # Must match livekit-config.yaml keys
LIVEKIT_API_SECRET=YOUR_API_SECRET    # Must match livekit-config.yaml keys
LIVEKIT_URL=ws://localhost:7880       # Use wss://livekit.yourdomain.com for production
```

> [!IMPORTANT]
> `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` must be **identical** in both your backend `.env` and your `livekit-config.yaml`. If they don't match, token generation will fail.

### Production `.env` example:

```env
LIVEKIT_API_KEY=APIyEYcWSAcsUrF
LIVEKIT_API_SECRET=V8KJy7a0glqvoBDYiAumuB8agCKP5JQ9VLThbHj5HqL
LIVEKIT_URL=wss://livekit.yourdomain.com
```

### Webhook URL in livekit-config.yaml

Update the webhook URL to point to your deployed backend:

```yaml
webhook:
  api_key: YOUR_API_KEY
  urls:
    - https://your-api-domain.com/v1/api/livekit/webhook
```

---

## Flutter SDK Integration

### Step 1: Add the SDK to your Flutter app

In your app's `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  social_iq_live_sdk:
    path: ../social_iq_live_sdk   # local path
  # OR if published:
  # social_iq_live_sdk: ^0.1.0
```

Then run:
```bash
flutter pub get
```

### Step 2: Add Platform Permissions

#### Android — `android/app/src/main/AndroidManifest.xml`

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

Also set `minSdkVersion` to 21+ in `android/app/build.gradle`:
```gradle
defaultConfig {
    minSdkVersion 21
}
```

#### iOS — `ios/Runner/Info.plist`

```xml
<key>NSCameraUsageDescription</key>
<string>Camera access is needed for video calls and live broadcasts</string>
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is needed for audio/video calls and live broadcasts</string>
```

### Step 3: Initialize the SDK in `main.dart`

```dart
import 'package:flutter/material.dart';
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize the SDK with your server URLs
  await SocialIqLiveSdk.initialize(
    serverUrl: 'wss://livekit.yourdomain.com',      // LiveKit WebSocket URL
    socketUrl: 'https://api.yourdomain.com',         // Socket.IO URL (your backend)
    apiBaseUrl: 'https://api.yourdomain.com',        // REST API base URL
  );

  runApp(const MyApp());
}
```

> [!NOTE]
> `socketUrl` and `apiBaseUrl` are typically the **same URL** (your backend server). `serverUrl` is your LiveKit server URL.

---

## Complete Example

### 1:1 Video Call

```dart
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

// Start a video call
void startVideoCall(BuildContext context) {
  final apiService = ApiService(baseUrl: 'https://api.yourdomain.com');
  final callController = CallController(apiService: apiService);

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => VideoCallScreen(
        controller: callController,
        userToken: 'user_jwt_token',          // Your app's auth token
        callerId: 'user_123',                 // Current user ID
        receiverId: 'user_456',               // Person to call
        roomName: 'call_123_456',             // Unique room name
        livekitUrl: 'wss://livekit.yourdomain.com',
        receiverName: 'Sarah Johnson',
        receiverAvatar: 'https://example.com/avatar.jpg',
        onCallEnded: () => Navigator.pop(context),
      ),
    ),
  );
}
```

### 1:1 Audio Call

```dart
void startAudioCall(BuildContext context) {
  final apiService = ApiService(baseUrl: 'https://api.yourdomain.com');
  final callController = CallController(apiService: apiService);

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => AudioCallScreen(
        controller: callController,
        userToken: 'user_jwt_token',
        callerId: 'user_123',
        receiverId: 'user_456',
        roomName: 'call_123_456',
        livekitUrl: 'wss://livekit.yourdomain.com',
        receiverName: 'Alex Morgan',
        onCallEnded: () => Navigator.pop(context),
      ),
    ),
  );
}
```

### Live Broadcast (Host)

```dart
void goLive(BuildContext context) {
  final apiService = ApiService(baseUrl: 'https://api.yourdomain.com');
  final liveController = LiveController(apiService: apiService);

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => LiveBroadcastHost(
        controller: liveController,
        userToken: 'user_jwt_token',
        identity: 'user_123',                       // Your user ID
        displayName: 'Muhammad Taifur',
        avatarUrl: 'https://example.com/avatar.jpg',
        livekitUrl: 'wss://livekit.yourdomain.com',
        socketUrl: 'https://api.yourdomain.com',
        onLiveEnded: () => Navigator.pop(context),
      ),
    ),
  );
}
```

### Live Broadcast (Viewer)

```dart
void watchLive(BuildContext context, String hostRoomName) {
  final apiService = ApiService(baseUrl: 'https://api.yourdomain.com');
  final liveController = LiveController(apiService: apiService);

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => LiveBroadcastViewer(
        controller: liveController,
        userToken: 'user_jwt_token',
        identity: 'viewer_456',
        displayName: 'Viewer Name',
        roomName: hostRoomName,                     // Host's room name
        livekitUrl: 'wss://livekit.yourdomain.com',
        socketUrl: 'https://api.yourdomain.com',
        onLiveEnded: () => Navigator.pop(context),
      ),
    ),
  );
}
```

---

## Live Broadcast — Comments & Reactions

Comments and reactions are **built-in and automatic** inside `LiveBroadcastHost` and `LiveBroadcastViewer`. The SDK connects to your Socket.IO server and handles all real-time events internally — no extra setup needed.

### How it works (Socket.IO Events)

| Event | Direction | Description |
|---|---|---|
| `join_live` | Client → Server | Fired when a viewer joins the broadcast room |
| `leave_live` | Client → Server | Fired when a viewer leaves |
| `live_comment` | Client ↔ Server | Sends/receives a chat message with user name & avatar |
| `live_reaction` | Client ↔ Server | Sends/receives an emoji reaction (❤️ 🔥 😂 👏 😮 🎉) |
| `viewer_count` | Server → Client | Backend pushes the updated viewer count to all clients |

### Automatic behaviour (built-in screens)

You don't need to write any code — the widgets below are already included in `LiveBroadcastHost` and `LiveBroadcastViewer`:

| Widget | What it does |
|---|---|
| `CommentOverlay` | Scrolling semi-transparent list of live comments (name + avatar + message) |
| `CommentInput` | Frosted-glass text field for viewers to type and send messages |
| `ReactionAnimation` | Floating emoji particles that drift upward when reactions arrive |
| `ReactionBar` | Emoji picker row shown when the ❤️ button is tapped |

### Manual usage (programmatic API)

If you are building a **custom UI**, you can call these methods directly on your `LiveController`:

```dart
// Send a comment
liveController.sendComment('Love this stream! 🔥');

// Send a reaction emoji
liveController.sendReaction('❤️');  // ❤️ 🔥 😂 👏 😮 🎉

// Read the current comment list
final List<LiveComment> comments = liveController.comments;
// comment.userName    → sender's display name
// comment.userAvatar  → sender's avatar URL (nullable)
// comment.message     → text content
// comment.timestamp   → DateTime when received

// Read pending reaction animations
final List<LiveReaction> reactions = liveController.pendingReactions;
// reaction.emoji      → emoji string, e.g. "❤️"
// reaction.userName   → sender's display name
```

### Custom screen layout example

If you want to build a fully custom live viewer UI, overlay the widgets like this:

```dart
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

Stack(
  children: [
    // Full-screen video feed here ...

    // Comment list — bottom left area
    Positioned(
      left: 0, right: 80, bottom: 100,
      child: CommentOverlay(comments: liveController.comments),
    ),

    // Floating emoji reactions — bottom right
    Positioned(
      right: 8, bottom: 160,
      child: ReactionAnimation(reactions: liveController.pendingReactions),
    ),

    // Comment input + reaction button — very bottom
    Positioned(
      left: 12, right: 12, bottom: 16,
      child: Row(
        children: [
          Expanded(
            child: CommentInput(onSubmit: liveController.sendComment),
          ),
          const SizedBox(width: 10),
          ReactionBar(onReaction: liveController.sendReaction),
        ],
      ),
    ),
  ],
)
```

> [!NOTE]
> `SocialIqLiveSdk.initialize(socketUrl: 'https://api.yourdomain.com')` must be called in `main.dart` before using any live feature. The Socket.IO connection is established automatically when the broadcast starts.

---

### Handle Incoming Calls

```dart
void showIncomingCall(BuildContext context, Map<String, dynamic> callData) {
  final apiService = ApiService(baseUrl: 'https://api.yourdomain.com');
  final callController = CallController(apiService: apiService);

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => IncomingCallScreen(
        controller: callController,
        userToken: 'user_jwt_token',
        receiverId: 'user_456',                     // Current user (receiver)
        callerId: callData['callerId'],
        roomName: callData['roomName'],
        callType: CallType.video,
        livekitUrl: 'wss://livekit.yourdomain.com',
        callerName: callData['callerName'],
        callerAvatar: callData['callerAvatar'],
        onCallEnded: () => Navigator.pop(context),
      ),
    ),
  );
}
```

---

## Quick Reference: All URLs

| What | Dev (local) | Production |
|------|-------------|------------|
| `serverUrl` (LiveKit) | `ws://localhost:7880` | `wss://livekit.yourdomain.com` |
| `socketUrl` (Socket.IO) | `http://localhost:8000` | `https://api.yourdomain.com` |
| `apiBaseUrl` (REST API) | `http://localhost:8000` | `https://api.yourdomain.com` |
| `LIVEKIT_URL` (.env) | `ws://localhost:7880` | `wss://livekit.yourdomain.com` |

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| LiveKit token error | Verify `LIVEKIT_API_KEY` + `LIVEKIT_API_SECRET` match in both `.env` and `livekit-config.yaml` |
| WebSocket connection refused | Check firewall allows port 7880, verify `docker ps` shows livekit running |
| No audio/video | Check Android permissions in `AndroidManifest.xml` and iOS `Info.plist` |
| Comments/reactions not working | Verify Socket.IO is running in `server.js` (check for `[Socket.IO] Live broadcast socket server initialized` in logs) |
| Webhook not received | Verify webhook URL in `livekit-config.yaml` is publicly reachable from your LiveKit server |
