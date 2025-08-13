import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_pos_printer_platform/flutter_pos_printer_platform.dart';
import '../esc_pos_utils_platform/esc_pos_utils_platform.dart';
import 'universal_chinese_printer.dart';

enum PrinterType { bluetooth, usb, network }

class PrinterManager {
  final bluetoothPrinterConnector = BluetoothPrinterConnector.instance;
  final tcpPrinterConnector = TcpPrinterConnector.instance;
  final usbPrinterConnector = UsbPrinterConnector.instance;

  bool useDedicatedSocket = false;

  PrinterManager._();

  static PrinterManager _instance = PrinterManager._();

  static PrinterManager get instance => _instance;

  static Function(String message, {String? level, dynamic error, StackTrace? stackTrace})? logCallback;

  static Map<String, Map<String, int>> _printerConfigs = {};

  void _log(String message, {String level = 'info', dynamic error, StackTrace? stackTrace}) {
    if (level == 'error') {
      print('ERROR: $message');
      if (error != null) print('Error details: $error');
    } else {
      print(message);
    }

    // Send to callback if available
    if (logCallback != null) {
      logCallback!(message, level: level, error: error, stackTrace: stackTrace);
    }
  }

  PrinterManager enableDedicatedSocket(bool value) {
    return this..useDedicatedSocket = value;
  }

  Future<bool> checkPrinterStatus({required PrinterType type, required BasePrinterInput model}) async {
    if (type == PrinterType.network) {
      try {
        final tcpModel = model as TcpPrinterInput;
        Socket socket = await Socket.connect(tcpModel.ipAddress, tcpModel.port, timeout: Duration(seconds: 2));

        // Send a status request command (common for ESC/POS printers)
        List<List<int>> statusCommands = [
          [0x10, 0x04, 0x01], // DLE EOT n - Epson
          [0x1D, 0x72, 0x01], // GS r n - Generic
        ];

        for (final cmd in statusCommands) {
          socket.add(Uint8List.fromList(cmd));
          await socket.flush();
        }

        // Create a completer for async response handling
        Completer<bool> completer = Completer<bool>();

        // Set a timeout
        Timer(Duration(seconds: 1), () {
          if (!completer.isCompleted) {
            completer.complete(false);
          }
        });

        // Listen for response
        socket.listen(
          (data) {
            if (!completer.isCompleted && data.isNotEmpty) {
              completer.complete(true);
            }
          },
          onError: (e) {
            if (!completer.isCompleted) {
              completer.complete(false);
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.complete(false);
            }
          },
        );

        bool result = await completer.future;
        await socket.close();
        return result;
      } catch (e) {
        _log('Error checking printer status: $e');
        return false;
      }
    }

    // For non-network printers
    return true;
  }

  Future<bool> testPrint({required PrinterType type, required BasePrinterInput model}) async {
    try {
      // Create a simple test page
      List<int> testData = [
        // Initialize printer
        0x1B, 0x40,
        // Text formatting - normal
        0x1B, 0x21, 0x00,
        // Test message
        ...utf8.encode("Printer Test\n${DateTime.now()}\n\n"),
        // Line feeds & cut
        0x0A, 0x0A, 0x0A,
        0x1D, 0x56, 0x41, 0x03 // Cut paper
      ];

      // Connect and send
      final connectResult = await connect(type: type, model: model);
      if (!connectResult.isSuccess) {
        return false;
      }

      // Send test data
      final sendResult = await send(type: type, bytes: testData, model: model);

      // Wait for printing to complete
      await Future.delayed(Duration(milliseconds: 500));

      // Disconnect
      await disconnect(type: type, delayMs: 200);

      return sendResult.isSuccess;
    } catch (e) {
      _log('Test print failed: $e');
      return false;
    }
  }

  Stream<PrinterDevice> discovery({required PrinterType type, bool isBle = false, TcpPrinterInput? model}) {
    if (type == PrinterType.bluetooth && (Platform.isIOS || Platform.isAndroid)) {
      return bluetoothPrinterConnector.discovery(isBle: isBle);
    } else if (type == PrinterType.usb && (Platform.isAndroid || Platform.isWindows)) {
      return usbPrinterConnector.discovery();
    } else {
      return tcpPrinterConnector.discovery(model: model);
    }
  }

  Future<PrinterConnectStatusResult> connect({required PrinterType type, required BasePrinterInput model}) async {
    if (type == PrinterType.bluetooth && (Platform.isIOS || Platform.isAndroid)) {
      try {
        var conn = await bluetoothPrinterConnector.connect(model as BluetoothPrinterInput);
        return conn;
      } catch (e, stackTrace) {
        throw Exception('Err bluetoothPrinterConnector.connect: ${e}, $stackTrace');
      }
    } else if (type == PrinterType.usb && (Platform.isAndroid || Platform.isWindows)) {
      try {
        var conn = await usbPrinterConnector.connect(model as UsbPrinterInput);
        return conn;
      } catch (e, stackTrace) {
        throw Exception('Err usbPrinterConnector.connect: ${e}, $stackTrace');
      }
    } else {
      try {
        var conn = useDedicatedSocket
            ? await tcpPrinterConnector.connectDedicatedSocket(model as TcpPrinterInput)
            : await tcpPrinterConnector.connect(model as TcpPrinterInput);
        return conn;
      } catch (e, stackTrace) {
        throw Exception('Err tcpPrinterConnector.connect: ${e}, $stackTrace');
      }
    }
  }

  Future<bool> disconnect({required PrinterType type, int? delayMs, String? dedicatedSocketIp}) async {
    if (type == PrinterType.bluetooth && (Platform.isIOS || Platform.isAndroid)) {
      return await bluetoothPrinterConnector.disconnect();
    } else if (type == PrinterType.usb && (Platform.isAndroid || Platform.isWindows)) {
      return await usbPrinterConnector.disconnect(delayMs: delayMs);
    } else {
      if (dedicatedSocketIp != null && tcpPrinterConnector.socketsPerIp.containsKey(dedicatedSocketIp!)) {
        return await tcpPrinterConnector.disconnectDedicatedSocket(printerIp: dedicatedSocketIp);
      } else {
        return await tcpPrinterConnector.disconnect();
      }
    }
  }

  Future<PrinterConnectStatusResult> send(
      {required PrinterType type, required List<int> bytes, BasePrinterInput? model}) async {
    if (type == PrinterType.bluetooth && (Platform.isIOS || Platform.isAndroid)) {
      return await bluetoothPrinterConnector.send(bytes);
    } else if (type == PrinterType.usb && (Platform.isAndroid || Platform.isWindows)) {
      return await usbPrinterConnector.send(bytes);
    } else {
      return await tcpPrinterConnector.send(bytes,
          model: model as TcpPrinterInput?, useDedicatedSocket: useDedicatedSocket);
    }
  }

  Future<PrinterConnectStatusResult> sendWithRetries(
      {required PrinterType type, required List<int> bytes, BasePrinterInput? model}) async {
    if (type == PrinterType.bluetooth && (Platform.isIOS || Platform.isAndroid)) {
      return await bluetoothPrinterConnector.sendWithRetries(bytes);
    } else if (type == PrinterType.usb && (Platform.isAndroid || Platform.isWindows)) {
      return await usbPrinterConnector.sendWithRetries(bytes);
    } else {
      return await tcpPrinterConnector.sendWithRetries(bytes, model as TcpPrinterInput?);
    }
  }

  Future<PrinterConnectStatusResult> splitSend(
      {required PrinterType type,
      required List<List<int>> bytes,
      BasePrinterInput? model,
      int delayBetweenMs = 50}) async {
    if (type == PrinterType.bluetooth && (Platform.isIOS || Platform.isAndroid)) {
      return await bluetoothPrinterConnector.splitSend(bytes);
    } else if (type == PrinterType.usb && (Platform.isAndroid || Platform.isWindows)) {
      return await usbPrinterConnector.splitSend(bytes);
    } else {
      return await tcpPrinterConnector.splitSend(bytes,
          model: model as TcpPrinterInput?, delayBetweenMs: delayBetweenMs, useDedicatedSocket: useDedicatedSocket);
    }
  }

  Future<bool> disconnectAllSocket({required PrinterType type, int? delayMs}) async {
    if (type == PrinterType.bluetooth && (Platform.isIOS || Platform.isAndroid)) {
      return await bluetoothPrinterConnector.disconnect();
    } else if (type == PrinterType.usb && (Platform.isAndroid || Platform.isWindows)) {
      return await usbPrinterConnector.disconnect(delayMs: delayMs);
    } else {
      bool disconnected = false;
      disconnected = await tcpPrinterConnector.disconnect();
      for (final ip in tcpPrinterConnector.socketsPerIp.keys) {
        disconnected = await tcpPrinterConnector.disconnectDedicatedSocket(printerIp: ip);
      }
      return disconnected;
    }
  }

  Future<bool> printChineseTextUniversal(String chineseText, PrinterType printerType, BasePrinterInput model,
      {bool autoDetect = true}) async {
    try {
      String printerKey = _getPrinterKey(model);
      Map<String, int>? config = _printerConfigs[printerKey];

      // Auto-detect optimal settings if not cached
      if (config == null && autoDetect) {
        _log('Auto-detecting Chinese settings for printer: $printerKey');
        config = await UniversalChinesePrinter.autoConfigureChinesePrinting(this, printerType, model);
        _printerConfigs[printerKey] = config;
        _log('Detected config: $config');
      }

      // Use detected or default configuration
      int chineseModeAttempt = config?['chineseModeAttempt'] ?? 1;
      int encodingAttempt = config?['encodingAttempt'] ?? 1;

      // Create generator
      final profile = await CapabilityProfile.load(name: 'default');
      final generator = Generator(PaperSize.mm80, profile);

      List<int> bytes = [];

      // Initialize printer
      bytes += generator.reset();

      // Print Chinese text with optimal settings
      bytes += generator.textMixed(
        chineseText,
        styles: const PosStyles(
          align: PosAlign.center,
          height: PosTextSize.size1,
          width: PosTextSize.size1,
        ),
        chineseModeAttempt: chineseModeAttempt,
        encodingAttempt: encodingAttempt,
      );

      // Cut paper
      bytes += generator.cut();

      // Connect and send
      final connectResult = await connect(type: printerType, model: model);
      if (!connectResult.isSuccess) {
        return false;
      }

      final sendResult = await send(type: printerType, bytes: bytes, model: model);

      // Disconnect
      await disconnect(type: printerType);

      return sendResult.isSuccess;
    } catch (e) {
      _log('Universal Chinese printing failed: $e', level: 'error');
      return false;
    }
  }

  Future<bool> printMixedText(
    String mixedText,
    PrinterType printerType,
    BasePrinterInput model, {
    PosStyles? styles,
    bool autoDetect = true,
  }) async {
    try {
      String printerKey = _getPrinterKey(model);
      Map<String, int>? config = _printerConfigs[printerKey];

      // Auto-detect optimal settings if not cached
      if (config == null && autoDetect) {
        _log('Auto-detecting mixed text settings for printer: $printerKey');
        config = await UniversalChinesePrinter.autoConfigureChinesePrinting(this, printerType, model);
        _printerConfigs[printerKey] = config;
        _log('Detected config: $config');
      }

      // Use detected or default configuration
      int chineseModeAttempt = config?['chineseModeAttempt'] ?? 1;
      int encodingAttempt = config?['encodingAttempt'] ?? 1;

      // Create generator
      final profile = await CapabilityProfile.load(name: 'default');
      final generator = Generator(PaperSize.mm80, profile);

      List<int> bytes = [];

      // Initialize printer
      bytes += generator.reset();

      // Print mixed text with optimal settings
      bytes += generator.textMixed(
        mixedText,
        styles: styles ??
            const PosStyles(
              align: PosAlign.left,
              height: PosTextSize.size1,
              width: PosTextSize.size1,
            ),
        chineseModeAttempt: chineseModeAttempt,
        encodingAttempt: encodingAttempt,
      );

      // Cut paper
      bytes += generator.cut();

      // Connect and send
      final connectResult = await connect(type: printerType, model: model);
      if (!connectResult.isSuccess) {
        return false;
      }

      final sendResult = await send(type: printerType, bytes: bytes, model: model);

      // Disconnect
      await disconnect(type: printerType);

      return sendResult.isSuccess;
    } catch (e) {
      _log('Mixed text printing failed: $e', level: 'error');
      return false;
    }
  }

  // Generate unique printer identifier
  String _getPrinterKey(BasePrinterInput model) {
    if (model is TcpPrinterInput) {
      return '${model.ipAddress}';
    } else if (model is BluetoothPrinterInput) {
      return '${model.address}';
    } else if (model is UsbPrinterInput) {
      return '${model.vendorId}_${model.productId}';
    }
    return model.toString();
  }

  // Manual configuration for specific printers
  void setChineseConfig(BasePrinterInput model, int chineseModeAttempt, int encodingAttempt) {
    String printerKey = _getPrinterKey(model);
    _printerConfigs[printerKey] = {
      'chineseModeAttempt': chineseModeAttempt,
      'encodingAttempt': encodingAttempt,
    };
  }

  // Get cached configuration
  Map<String, int>? getChineseConfig(BasePrinterInput model) {
    return _printerConfigs[_getPrinterKey(model)];
  }

  // Clear cached configurations
  void clearChineseConfigs() {
    _printerConfigs.clear();
  }

  Stream<BTStatus> get stateBluetooth => bluetoothPrinterConnector.currentStatus.cast<BTStatus>();

  Stream<USBStatus> get stateUSB => usbPrinterConnector.currentStatus.cast<USBStatus>();

  Stream<TCPStatus> get stateTCP => tcpPrinterConnector.currentStatus.cast<TCPStatus>();

  BTStatus get currentStatusBT => bluetoothPrinterConnector.status;

  USBStatus get currentStatusUSB => usbPrinterConnector.status;

  TCPStatus get currentStatusTCP => tcpPrinterConnector.status;
}
