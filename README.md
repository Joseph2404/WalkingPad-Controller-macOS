# WalkingPad Controller for macOS

A native macOS app for controlling compatible KingSmith WalkingPad treadmills over Bluetooth. No vendor account, cloud service, or phone app is required.

## Features

- Start/Stop with a three-second startup countdown.
- Speed dial, 0.1 mph adjustments, and three customizable presets.
- Live speed, session distance, elapsed time, and a distance goal.
- Local activity history with a reset button.
- Remembered device selection, automatic connection, and reconnection.
- Compact menu-bar controls with speed, presets, and goal progress.
- Resizable main window; closing it leaves the menu-bar app running.

## Compatibility

Requires macOS 13 or newer. The app builds for Apple silicon and Intel Macs.

Hardware testing has been performed with a WP400U4 / KS-Z1D. Other KingSmith models are allowed when they expose the required Bluetooth Fitness Machine Service (FTMS): treadmill data notifications, speed limits, a writable control point with indications, and machine-status notifications. A successful control handshake is required.

Other models are **not yet hardware-verified**. Legacy KingSmith WiLink devices and models requiring vendor-specific activation are not supported by the active controller. Model names alone do not establish compatibility.

The UI uses mph and a 4 mph maximum, further constrained by the device's reported speed range. Commands are rounded to the supported metric speed increments. Reconnection does not restart the belt or replay speed commands.

## Build and run

Install Xcode, then open `Package.swift`, select the WalkingPadController scheme, and Run.

To build a standalone universal app:

```sh
bash scripts/build-app.sh
```

The result is `build/WalkingPad Controller.app`. Copy it to Applications and launch it. Allow Bluetooth access, open Settings, choose Find devices, and select your treadmill. Device selection, presets, and goal are saved locally.

The build script applies an ad-hoc signature for local use. It does **not** produce an Apple Developer ID-signed or notarized release. Public binary distribution with normal Gatekeeper acceptance requires Developer ID signing and notarization.

## Using the app

Start uses the treadmill's startup speed. Adjust the dial after the belt begins moving. The orange dial represents the selected speed; the large number reports actual speed. The power button stops the belt.

Distance and elapsed time follow the treadmill's own counters. A session is saved when stopped; resumed sessions with continuous counters update the same record. New counters start a new activity. Goal progress is informational and does not stop the belt.

The treadmill icon opens the menu-bar panel. Open App restores the main window. Quit exits the app; quitting, closing the window, or losing Bluetooth does not send a Stop command.

## Privacy

No analytics, account, or network service is used by the app. Bluetooth identifiers, the selected device name, preferences, and activity history stay in macOS UserDefaults on the local Mac. They are not included in the source or app bundle.

Build products, Xcode user settings, credentials, and local configuration are excluded by `.gitignore`. Diagnostic reports can contain a Bluetooth device name; review them before posting an issue.

## Tests

```sh
swift test --disable-sandbox
```

Tests cover protocol parsing, speed conversion and limits, control handshakes, timeout handling, session time, and activity-history persistence. GitHub Actions runs these tests and builds a universal app.

Protocol references: [Bluetooth SIG FTMS tests](https://files.bluetooth.com/wp-content/uploads/dlm_uploads/2024/10/FTMS.TS_.p6.pdf) and [KingSmith FTMS reference](https://github.com/mcdax/walkingpad-controller/blob/main/docs/ftms-protocol-reference.md).

## Feedback

When reporting an issue, include the model, macOS version, firmware if available, expected behavior, and what happened. Do not include device serial numbers or private identifiers.

## License

No open-source license has been granted at this time.
