import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_pos_printer_platform/src/models/printer_device.dart';
import 'package:flutter_pos_printer_platform/discovery.dart';
import 'package:flutter_pos_printer_platform/printer.dart';
import 'package:ping_discover_network/ping_discover_network.dart';

import '../helpers/printer_status_checker.dart';

class TcpPrinterInput extends BasePrinterInput {
  final String ipAddress;
  final int port;
  final Duration timeout;
  final Duration retryInterval;
  final int maxRetries;

  TcpPrinterInput({
    required this.ipAddress,
    this.port = 9100,
    this.timeout = const Duration(seconds: 5),
    this.retryInterval = const Duration(seconds: 1),
    this.maxRetries = 3,
  });
}

class TcpPrinterInfo {
  String address;

  TcpPrinterInfo({
    required this.address,
  });
}

class TcpPrinterConnector implements PrinterConnector<TcpPrinterInput> {
  TcpPrinterConnector._();

  static final TcpPrinterConnector _instance = TcpPrinterConnector._();

  static TcpPrinterConnector get instance => _instance;

  String? _host;
  int? _port;
  Socket? _socket;
  TCPStatus _status = TCPStatus.none;

  final StreamController<TCPStatus> _statusStreamController = StreamController.broadcast();

  Stream<TCPStatus> get _statusStream => _statusStreamController.stream;

  TCPStatus get status => _status;

  set status(TCPStatus newStatus) {
    _status = newStatus;
    _statusStreamController.add(newStatus);
  }

  bool get isConnected => _socket != null && status == TCPStatus.connected;

  // Helper method to safely close socket
  Future<void> _safeCloseSocket() async {
    if (_socket != null) {
      try {
        await _socket!.flush();
        await _socket!.close();
        _socket!.destroy();
        _socket = null;
      } catch (e) {
        debugPrint('Error closing socket: $e');
        _socket?.destroy();
        _socket = null;
      }
    }
  }

  @override
  Future<PrinterConnectStatusResult> connect(TcpPrinterInput model) async {
    int retryCount = 0;
    SocketException? lastException;
    StackTrace? lastStackTrace;

    while (retryCount < model.maxRetries) {
      try {
        await _safeCloseSocket();

        _socket = await Socket.connect(
          model.ipAddress,
          model.port,
          timeout: model.timeout,
        );

        _host = model.ipAddress;
        _port = model.port;
        status = TCPStatus.connected;

        return PrinterConnectStatusResult(isSuccess: true);
      } on SocketException catch (e, stackTrace) {
        lastException = e;
        lastStackTrace = stackTrace;
        debugPrint('Connection attempt ${retryCount + 1} failed: ${e.message}');

        if (retryCount < model.maxRetries - 1) {
          await Future.delayed(model.retryInterval);
        }
        retryCount++;
      } catch (e, stackTrace) {
        debugPrint('Unexpected error during connect: $e');
        status = TCPStatus.none;
        return PrinterConnectStatusResult(
          isSuccess: false,
          exception: 'Unexpected error: $e',
          stackTrace: stackTrace,
        );
      }
    }

    status = TCPStatus.none;
    return PrinterConnectStatusResult(
      isSuccess: false,
      exception: '${model.ipAddress}:${model.port}:${lastException}',
      stackTrace: lastStackTrace,
    );
  }

  @override
  Future<PrinterConnectStatusResult> send(List<int> bytes, [TcpPrinterInput? model]) async {
    if (!isConnected) {
      if (model != null) {
        final connectResult = await connect(model);
        if (!connectResult.isSuccess) {
          return connectResult;
        }
      } else {
        return PrinterConnectStatusResult(
          isSuccess: false,
          exception: 'Not connected and no connection details provided',
        );
      }
    }

    try {
      _socket!.add(Uint8List.fromList(bytes));
      await _socket!.flush();
      return PrinterConnectStatusResult(isSuccess: true);
    } catch (e, stackTrace) {
      status = TCPStatus.none;
      return PrinterConnectStatusResult(
        isSuccess: false,
        exception: 'Send error: $e',
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<PrinterConnectStatusResult> sendWithRetries(List<int> bytes, [TcpPrinterInput? model]) async {
    if (!isConnected) {
      if (model != null) {
        final connectResult = await connect(model);
        if (!connectResult.isSuccess) {
          return connectResult;
        }
        await Future.delayed(Duration(milliseconds: 100));
      } else {
        return PrinterConnectStatusResult(
          isSuccess: false,
          exception: 'Not connected and no connection details provided',
        );
      }
    }

    int retryCount = 0;
    const int maxRetries = 3;
    const Duration retryDelay = Duration(milliseconds: 500);
    SocketException? lastException;
    StackTrace? lastStackTrace;

    while (retryCount < maxRetries) {
      try {
        // Check printer status
        String printerKey = '${model?.ipAddress}:9100';
        bool printerReady = await PrinterStatusChecker.checkStatus(
          _socket!, printerKey,
          maxRetries: 2, // Less retries for status check within send retry loop
          retryDelay: Duration(milliseconds: 200),
        );

        if (!printerReady) {
          throw SocketException('Printer not ready or in error state');
        }

        // Send data
        _socket!.add(Uint8List.fromList(bytes));
        await _socket!.flush();

        return PrinterConnectStatusResult(isSuccess: true);
      } catch (e, stackTrace) {
        lastException = e is SocketException ? e : SocketException(e.toString());
        lastStackTrace = stackTrace;

        debugPrint('Print attempt ${retryCount + 1} failed: $e');

        retryCount++;
        if (retryCount < maxRetries) {
          await Future.delayed(retryDelay);

          // Try to reconnect if needed
          if (!isConnected && model != null) {
            final reconnectResult = await connect(model);
            if (!reconnectResult.isSuccess) {
              continue;
            }
          }
        }
      }
    }

    status = TCPStatus.none;
    return PrinterConnectStatusResult(
      isSuccess: false,
      exception: 'Send error after $maxRetries attempts: ${lastException?.message}',
      stackTrace: lastStackTrace,
    );
  }

  @override
  Future<PrinterConnectStatusResult> splitSend(List<List<int>> bytes,
      {TcpPrinterInput? model, int delayBetweenMs = 50}) async {
    if (!isConnected) {
      if (model != null) {
        final connectResult = await connect(model);
        if (!connectResult.isSuccess) {
          return connectResult;
        }
      } else {
        return PrinterConnectStatusResult(
          isSuccess: false,
          exception: 'Not connected and no connection details provided',
        );
      }
    }

    try {
      if (_socket == null) {
        throw SocketException('Socket is null');
      }

      int totalSize = bytes.fold(0, (sum, section) => sum + section.length);
      debugPrint('Starting split send with ${bytes.length} sections, total size: $totalSize bytes');

      // Track accumulated data size to determine when to flush
      int accumulatedSize = 0;
      final int flushThreshold = 8 * 1024; // 8KB threshold for flushing

      for (int i = 0; i < bytes.length; i++) {
        final section = bytes[i];
        if (section.isEmpty) continue;

        // Add data to socket (synchronous operation)
        _socket!.add(Uint8List.fromList(section));
        accumulatedSize += section.length;

        // Flush only when:
        // 1. We've accumulated significant data
        // 2. Or it's the last section
        // 3. Or we're about to wait anyway
        bool shouldFlush = accumulatedSize >= flushThreshold || i == bytes.length - 1 || delayBetweenMs > 0;

        if (shouldFlush) {
          try {
            await _socket!.flush().timeout(Duration(seconds: 5), onTimeout: () {
              debugPrint('Flush timeout after $accumulatedSize bytes');
              throw TimeoutException('Flush operation timed out');
            });
            accumulatedSize = 0; // Reset accumulated size after flush
          } catch (e) {
            debugPrint('Flush error: $e');
            rethrow;
          }
        }

        if (delayBetweenMs > 0 && i < bytes.length - 1) {
          await Future.delayed(Duration(milliseconds: delayBetweenMs));
        }
      }

      debugPrint('Successfully sent all sections');
      return PrinterConnectStatusResult(isSuccess: true);
    } catch (e, stackTrace) {
      debugPrint('Split send failed: $e');
      status = TCPStatus.none;
      await _safeCloseSocket();
      return PrinterConnectStatusResult(
        isSuccess: false,
        exception: 'Split send error: $e',
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<bool> disconnect({int? delayMs}) async {
    try {
      await _safeCloseSocket();

      if (delayMs != null) {
        await Future.delayed(Duration(milliseconds: delayMs));
      }

      status = TCPStatus.none;
      return true;
    } catch (e) {
      debugPrint('Error during disconnect: $e');
      status = TCPStatus.none;
      return false;
    }
  }

  static Future<List<PrinterDiscovered<TcpPrinterInfo>>> discoverPrinters({
    required String ipAddress,
    int? port,
    Duration? timeOut,
  }) async {
    final List<PrinterDiscovered<TcpPrinterInfo>> result = [];

    if (ipAddress.isEmpty) {
      return result;
    }

    try {
      final String subnet = ipAddress.substring(0, ipAddress.lastIndexOf('.'));
      final stream = NetworkScanner(
        subnet: subnet,
        port: port ?? 9100,
        timeout: timeOut ?? const Duration(milliseconds: 4000),
      ).discover();

      await for (var addr in stream) {
        if (addr.exists) {
          result.add(PrinterDiscovered<TcpPrinterInfo>(
            name: "${addr.ip}:${port ?? 9100}",
            detail: TcpPrinterInfo(address: addr.ip),
          ));
        }
      }
    } catch (e) {
      debugPrint('Error during printer discovery: $e');
    }

    return result;
  }

  Stream<PrinterDevice> discovery({required TcpPrinterInput? model}) async* {
    if (model?.ipAddress == null || model!.ipAddress.isEmpty) {
      debugPrint('Invalid IP address provided');
      return;
    }

    try {
      final String subnet = model.ipAddress.substring(0, model.ipAddress.lastIndexOf('.'));
      final stream = NetworkScanner(
        subnet: subnet,
        port: model.port,
        timeout: model.timeout,
      ).discover();

      await for (var data in stream) {
        if (data.exists) {
          yield PrinterDevice(
            name: "${data.ip}:${model.port}",
            address: data.ip,
          );
        }
      }
    } catch (e) {
      debugPrint('Error during printer discovery: $e');
    }
  }

  Stream<TCPStatus> get currentStatus async* {
    yield status;
    yield* _statusStream;
  }

  // Clean up resources
  void dispose() {
    _safeCloseSocket();
    _statusStreamController.close();
  }
}
