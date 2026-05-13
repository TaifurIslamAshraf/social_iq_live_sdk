import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Entry point executed in the foreground-task isolate.
@pragma('vm:entry-point')
void callForegroundTaskEntryPoint() {
  FlutterForegroundTask.setTaskHandler(_CallTaskHandler());
}

class _CallTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  /// Routes the "Hang Up" notification button tap back to the main isolate.
  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'btn_hangup') {
      FlutterForegroundTask.sendDataToMain('hangup');
    }
  }
}

/// Manages the Android foreground service shown during an active call.
///
/// Displays a persistent notification — e.g. "Rakibul Islam Hridoy /
/// Tap to return to call • Calling…" — with a **Hang Up** button that ends
/// the call from the notification shade even when the user has navigated away.
///
/// **Setup**: Pass `enableForegroundService: true` to [VideoCallScreen] or
/// [AudioCallScreen]; they call [init] automatically. To customise the
/// notification icon, call [init] yourself once before the first call:
/// ```dart
/// CallForegroundService.init(
///   notificationIcon: const NotificationIcon(
///     metaDataName: 'com.example.app.iq_call_icon',
///   ),
/// );
/// ```
///
/// **Android manifest** — add inside `<manifest>`:
/// ```xml
/// <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
/// <uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />
/// <!-- Android 13+ -->
/// <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
/// ```
/// Inside `<application>` (required for Android 14+ `phoneCall` type):
/// ```xml
/// <service
///   android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
///   android:foregroundServiceType="phoneCall"
///   android:exported="false" />
/// ```
class CallForegroundService {
  CallForegroundService._();

  static bool _initialized = false;
  static VoidCallback? _onHangUp;
  static NotificationIcon? _notificationIcon;

  /// One-time configuration — safe to call more than once (idempotent).
  ///
  /// [notificationIcon] customises the icon shown in the status bar. If null
  /// the app's default launcher icon is used.
  static void init({NotificationIcon? notificationIcon}) {
    if (_initialized) {
      _notificationIcon ??= notificationIcon;
      return;
    }
    _initialized = true;
    _notificationIcon = notificationIcon;

    FlutterForegroundTask.initCommunicationPort();

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'iq_social_call_channel',
        channelName: 'Ongoing Call',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
        enableVibration: false,
        playSound: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Request POST_NOTIFICATIONS (Android 13+). Returns true if granted.
  ///
  /// Call once at app startup or when the user enables foreground notifications
  /// — without this, the notification will not display on Android 13+.
  static Future<bool> requestNotificationPermission() async {
    final status = await FlutterForegroundTask.checkNotificationPermission();
    if (status == NotificationPermission.granted) return true;
    final result = await FlutterForegroundTask.requestNotificationPermission();
    return result == NotificationPermission.granted;
  }

  /// Start the foreground notification for an active call.
  ///
  /// [callerName] is shown as the notification title.
  /// [callType] appears after "Tap to return to call •" (e.g. "Video call").
  /// [statusText] overrides the default body — pass "Calling…" while ringing
  /// or a formatted duration once connected.
  /// [onHangUp] is invoked on the main isolate when the user taps Hang Up.
  static Future<void> start({
    required String callerName,
    String callType = 'Calling…',
    String? statusText,
    VoidCallback? onHangUp,
  }) async {
    if (!_initialized) init();
    _onHangUp = onHangUp;
    FlutterForegroundTask.addTaskDataCallback(_handleData);

    // Auto-request POST_NOTIFICATIONS — without it the notification is silently
    // suppressed on Android 13+. Best-effort, ignore the result.
    await requestNotificationPermission();

    if (await FlutterForegroundTask.isRunningService) {
      // A previous call left the service running — update in place instead of
      // throwing ServiceAlreadyStartedException.
      await FlutterForegroundTask.updateService(
        notificationTitle: callerName,
        notificationText: statusText ?? 'Tap to return to call • $callType',
      );
      return;
    }

    await FlutterForegroundTask.startService(
      notificationTitle: callerName,
      notificationText: statusText ?? 'Tap to return to call • $callType',
      notificationIcon: _notificationIcon,
      notificationButtons: [
        const NotificationButton(id: 'btn_hangup', text: 'Hang Up'),
      ],
      callback: callForegroundTaskEntryPoint,
    );
  }

  /// Update the notification — call once per second to show live duration.
  static Future<void> updateNotification({String? title, String? text}) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  /// Stop the foreground notification. Call when the call ends.
  static Future<void> stop() async {
    FlutterForegroundTask.removeTaskDataCallback(_handleData);
    _onHangUp = null;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.stopService();
  }

  static void _handleData(Object data) {
    if (data == 'hangup') _onHangUp?.call();
  }
}
