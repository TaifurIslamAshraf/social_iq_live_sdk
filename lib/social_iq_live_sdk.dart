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
export 'src/services/callkit_service.dart';

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

/// Result of [SocialIqLiveSdk.initialize].
class SdkInitResult {
  /// Whether camera permission is granted.
  final bool cameraGranted;

  /// Whether microphone permission is granted.
  final bool microphoneGranted;

  /// Whether either camera or microphone is permanently denied (user must
  /// open system settings to re-enable).
  final bool anyPermanentlyDenied;

  const SdkInitResult({
    required this.cameraGranted,
    required this.microphoneGranted,
    required this.anyPermanentlyDenied,
  });

  /// Microphone is the minimum requirement — audio calls still work without
  /// the camera, but no form of call is possible without mic access.
  bool get canMakeCalls => microphoneGranted;
}

/// Main SDK class. Call [initialize] once in your app's `main()`.
class SocialIqLiveSdk {
  SocialIqLiveSdk._();

  static bool _initialized = false;

  /// Initialize the SDK with your server URLs.
  ///
  /// - [serverUrl]: LiveKit WebSocket URL (e.g., `wss://livekit.yourapp.com`)
  /// - [socketUrl]: Socket.IO server URL for comments/reactions
  /// - [apiBaseUrl]: Backend API base URL for token generation
  ///
  /// Returns a [SdkInitResult] describing which permissions were granted.
  /// Callers should inspect [SdkInitResult.canMakeCalls] before launching
  /// any call screen and surface a dialog pointing the user to system
  /// settings when [SdkInitResult.anyPermanentlyDenied] is true.
  static Future<SdkInitResult> initialize({
    required String serverUrl,
    required String socketUrl,
    required String apiBaseUrl,
  }) async {
    SocialIqLiveSdkConfig.serverUrl = serverUrl;
    SocialIqLiveSdkConfig.socketUrl = socketUrl;
    SocialIqLiveSdkConfig.apiBaseUrl = apiBaseUrl;

    final statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    final camera = statuses[Permission.camera] ?? PermissionStatus.denied;
    final mic = statuses[Permission.microphone] ?? PermissionStatus.denied;

    _initialized = true;

    return SdkInitResult(
      cameraGranted: camera.isGranted,
      microphoneGranted: mic.isGranted,
      anyPermanentlyDenied:
          camera.isPermanentlyDenied || mic.isPermanentlyDenied,
    );
  }

  /// Whether the SDK has been initialized.
  static bool get isInitialized => _initialized;
}
