// Social IQ Live SDK — drop-in Flutter UI for live broadcast, video/audio calls, and group calls.
//
// Setup once in main.dart:
//   await SocialIqLiveSdk.initialize(
//     serverUrl: 'wss://livekit.yourapp.com',
//     socketUrl:  'https://api.yourapp.com',
//     apiBaseUrl: 'https://api.yourapp.com',
//   );

import 'package:permission_handler/permission_handler.dart';
import 'src/widgets/live_broadcast_host.dart' show SocialIqLiveSdkConfig;

// Models
export 'src/models/live_config.dart';
export 'src/models/call_config.dart';

// Services
export 'src/services/api_service.dart';
export 'src/services/livekit_service.dart';
export 'src/services/socket_service.dart';

// Controllers
export 'src/controllers/live_controller.dart';
export 'src/controllers/call_controller.dart';
export 'src/controllers/socket_controller.dart';

// Widgets
export 'src/widgets/live_broadcast_host.dart';
export 'src/widgets/live_broadcast_viewer.dart';
export 'src/widgets/video_call_screen.dart';
export 'src/widgets/audio_call_screen.dart';
export 'src/widgets/group_call_screen.dart';
export 'src/widgets/incoming_call_screen.dart';
export 'src/widgets/comment_overlay.dart';
export 'src/widgets/reaction_animation.dart';

// Theme
export 'src/theme/sdk_theme.dart';

/// Main SDK class. Call [initialize] once in your app's `main()`.
class SocialIqLiveSdk {
  SocialIqLiveSdk._();

  static bool _initialized = false;

  /// Initialize the SDK with your server URLs.
  ///
  /// - [serverUrl]: LiveKit WebSocket URL (e.g., `wss://livekit.yourapp.com`)
  /// - [socketUrl]: Socket.IO server URL for comments/reactions
  /// - [apiBaseUrl]: Backend API base URL for token generation
  static Future<void> initialize({
    required String serverUrl,
    required String socketUrl,
    required String apiBaseUrl,
  }) async {
    SocialIqLiveSdkConfig.serverUrl = serverUrl;
    SocialIqLiveSdkConfig.socketUrl = socketUrl;
    SocialIqLiveSdkConfig.apiBaseUrl = apiBaseUrl;

    // Request camera and microphone permissions
    await [
      Permission.camera,
      Permission.microphone,
    ].request();

    _initialized = true;
  }

  /// Whether the SDK has been initialized.
  static bool get isInitialized => _initialized;
}
