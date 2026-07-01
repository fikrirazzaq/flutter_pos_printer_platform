# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Flutter plugin (`flutter_pos_printer_platform`) that discovers POS/receipt printers and sends raw ESC/POS, Star, and TSPL command bytes to them over Bluetooth (classic + BLE), USB, and TCP/network (Ethernet/WiFi). Supports Android, iOS, and Windows. Native platform code lives under `android/`, `ios/`, `windows/`; Dart API surface lives under `lib/`.

## Commands

```bash
flutter pub get              # install deps (run from repo root)
flutter analyze              # lint (analysis_options.yaml)
flutter test                 # run tests in test/
flutter test test/flutter_pos_printer_platform_test.dart  # single test file
cd example && flutter run    # run the example app (exercises the full plugin surface)
```

There is no CI config and the test suite is currently just the default plugin scaffold test — most validation of connector changes happens by running `example/` against a real or emulated printer, not via unit tests.

## Architecture

### Dart layer (`lib/`)

`PrinterManager` (`lib/src/printer_manager.dart`) is the single entry point apps use (`PrinterManager.instance`). It dispatches every operation (`discovery`, `connect`, `disconnect`, `send`, `sendWithRetries`, `splitSend`, status streams) to one of three connector singletons based on `PrinterType` (`bluetooth`, `usb`, `network`) and platform (`Platform.isAndroid/isIOS/isWindows`):

- `BluetoothPrinterConnector` (`lib/src/connectors/bluetooth.dart`) — Android/iOS only, talks to native code via `flutterPrinterChannel`/`iosChannel` (MethodChannel) and `flutterPrinterEventChannelBT`/`iosStateChannel` (EventChannel), defined in `lib/src/ext.dart`.
- `UsbPrinterConnector` (`lib/src/connectors/usb.dart`) — Android/Windows only, also bridges to native code via the same channels (`flutterPrinterEventChannelUSB`).
- `TcpPrinterConnector` (`lib/src/connectors/tcp.dart`) — all platforms, **pure Dart** (`dart:io` `Socket`), no native bridge involved. This is the largest and most actively developed connector (~1100 lines): it manages per-IP socket registry/locking (`_socketRegistry`, `_ipLocks`) to avoid duplicate/torn-down sockets on concurrent operations against the same printer, connection cooldowns after failures, optional "dedicated socket" mode (`connectDedicatedSocket`/`useDedicatedSocket`) for keeping a persistent connection per IP, and two generations of chunked sending: `splitSend` (legacy) and `splitSendV2` (current, supports `queryStatusPreSend` and `isImageBased` flush-timeout tuning).

All three connectors implement the `PrinterConnector<T>` interface (`lib/printer.dart`), which is also where `BasePrinterInput`, `Printer`, `GenericPrinter`, and `PrinterConnectStatusResult` (the common result type carrying `isSuccess`, hardware status, and query results) are defined.

`PrinterStatusChecker` (`lib/src/helpers/printer_status_checker.dart`) sends real-time status query commands (DLE EOT, GS r, ESC v, etc. — printer command dialect varies a lot across Epson/Star/Rongta/generic clones) over a raw `Socket`, caches whichever command dialect worked per printer (`_workingCommands`), and parses the response byte into a `PrinterHwStatus` (`ready`, `paperOut`, `coverOpen`, `notResponding`, etc.). This is TCP-only status probing, used by `checkPrinterStatus`/`splitSendV2`'s pre-send check.

Command generation for different printer languages lives in `lib/src/printers/`: `escpos.dart` (ESC/POS), `star.dart` (Star Line Mode), `tspl.dart` (TSPL for label printers) — these build `List<int>` byte sequences that get handed to a connector's `send`/`splitSend`.

`lib/esc_pos_utils_platform/` is a vendored/forked copy of ESC/POS generator utilities (barcode, capability profiles, columns, styles, QR codes) — treat it as a semi-independent module when making changes there.

### Native layer

- **Android** (`android/src/main/kotlin/.../flutter_pos_printer_platform/`): `FlutterPosPrinterPlatformPlugin.kt` is the MethodChannel/EventChannel entry point; `bluetooth/` (classic + BLE via `BluetoothConnection.kt`/`BluetoothBleConnection.kt`), `usb/` (`USBPrinterService.kt`, `UsbReceiver.kt` for the USB broadcast receiver), `adapter/USBPrinterAdapter.kt`.
- **iOS** (`ios/Classes/`): `SwiftFlutterPosPrinterPlatformPlugin.swift` is the channel entry point; `Connecter.h`/`ConnecterManager.h`/`BLEConnecter.h`/`EthernetConnecter.h` define the Obj-C connection abstractions (iOS has no USB or classic-BT support — only BLE and network).
- **Windows** (`windows/`): `flutter_pos_printer_platform_plugin.cpp` + `include/printer.cpp`/`printer.h` — handles USB and network only (no Bluetooth on Windows).

When changing connector behavior, check whether the change needs to be mirrored in the corresponding native implementation (Bluetooth/USB) — the Dart side for those two is a thin bridge, not where the actual I/O happens. TCP is the exception: all logic is in Dart.

### Cross-platform support matrix

USB: Android + Windows only. Bluetooth classic: Android only. BLE: Android + iOS. Network/TCP: all three platforms.
