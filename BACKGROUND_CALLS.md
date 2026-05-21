# Background Calls — Foreground Notification & PiP

Persistent "Tap to return to call" notification (with **Hang Up** button) plus
Android Picture-in-Picture for when the user leaves the call screen.
**Android only**; iOS gets a basic notification and no PiP.

## 1. AndroidManifest.xml

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>

    <application …>
        <activity
            android:name=".MainActivity"
            android:supportsPictureInPicture="true"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            … />

        <service
            android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
            android:foregroundServiceType="phoneCall"
            android:exported="false"
            tools:replace="android:foregroundServiceType" />
    </application>
</manifest>
```

`screenSize`/`screenLayout`/`smallestScreenSize` in `configChanges` are
required — without them the Activity is recreated on PiP resize and the call
drops.

## 2. Turn on the flags

```dart
VideoCallScreen(
  // …existing params…
  enableForegroundService: true,   // notification + Hang Up
  enablePiP: true,                 // floating window on Home press
)

AudioCallScreen(
  // …existing params…
  enableForegroundService: true,
)
```

That's the whole integration. The SDK handles starting/stopping the service,
updating the duration each second, wiring the Hang Up button to `endCall()`,
auto-entering PiP, and tearing everything down on dispose.

Both flags default to `false`, so existing code is unaffected.

## 3. Optional knobs

- **PiP aspect ratio**: `pipAspectRatio: const Rational.landscape()` (default
  `Rational(9, 16)`). Must be within `1/2.39 ≤ r ≤ 2.39/1`.
- **Custom notification icon**: call once before any call screen opens:
  ```dart
  CallForegroundService.init(
    notificationIcon: const NotificationIcon(
      metaDataName: 'com.example.app.iq_call_icon',
    ),
  );
  ```
  Add a matching `<meta-data android:name="…" android:resource="@drawable/…"/>`
  in the manifest pointing to a 24dp white-on-transparent drawable.

## Troubleshooting

| Symptom | Cause |
|---|---|
| No notification appears | `POST_NOTIFICATIONS` denied — reinstall or grant in system settings |
| Manifest merger error | Missing `tools:replace` or `xmlns:tools` |
| `SecurityException: Starting FGS with type phoneCall` (Android 14) | Missing `FOREGROUND_SERVICE_PHONE_CALL` permission or `foregroundServiceType="phoneCall"` on the service |
| PiP button does nothing | Activity missing `android:supportsPictureInPicture="true"` |
| Call drops on entering PiP | `configChanges` missing `screenSize` / `screenLayout` / `smallestScreenSize` |
| Hang Up button does nothing | Screen was popped before `controller.endCall()` ran — check your `onCallEnded` |

## Limits

- iOS: PiP is no-op, notification has no Hang Up button (iOS platform limit).
- Emulators: PiP auto-on-Home is unreliable — test on a real device.
- `minSdkVersion`: `21` for the service, `26` for PiP (gated at runtime).
