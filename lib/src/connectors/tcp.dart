import 'dart:async';
import 'dart:io';
import 'dart:math';
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
  final Map<String, DateTime> _lastConnectionAttempts = {};
  final int _connectionCooldownMs = 2000; // 2 seconds cooldown between connection attempts

  final StreamController<TCPStatus> _statusStreamController = StreamController.broadcast();

  Stream<TCPStatus> get _statusStream => _statusStreamController.stream;

  TCPStatus get status => _status;

  set status(TCPStatus newStatus) {
    _status = newStatus;
    _statusStreamController.add(newStatus);
  }

  bool get isConnected => _socket != null && status == TCPStatus.connected;

  // to track printers that are having issues
  final Map<String, DateTime> _problematicPrinters = {};

  static Function(String message, {String? level, dynamic error, StackTrace? stackTrace})? logCallback;

  static void _log(String message, {String level = 'info', dynamic error, StackTrace? stackTrace}) {
    if (level == 'error') {
      debugPrint('ERROR: $message');
      if (error != null) debugPrint('Error details: $error');
    } else {
      debugPrint(message);
    }

    // Send to callback if available
    if (logCallback != null) {
      logCallback!(message, level: level, error: error, stackTrace: stackTrace);
    }
  }

  // Dedicated socket per printer IP
  final socketsPerIp = <String, Socket>{};
  final _socketStatuses = <String, TCPStatus>{};

  // Connect to printers using shared socket (_socket)
  @override
  Future<PrinterConnectStatusResult> connect(TcpPrinterInput model) async {
    // Clear any existing socket first
    await _safeCloseSocket();

    String printerKey = '${model.ipAddress}:${model.port}';
    // Check if recently had a connection error and need to cool down
    if (_lastConnectionAttempts.containsKey(printerKey)) {
      DateTime lastAttempt = _lastConnectionAttempts[printerKey]!;
      Duration timeSince = DateTime.now().difference(lastAttempt);

      if (timeSince.inMilliseconds < _connectionCooldownMs) {
        // Force a delay to avoid overwhelming the printer
        int waitTime = _connectionCooldownMs - timeSince.inMilliseconds;
        _log('Waiting ${waitTime}ms before reconnecting to $printerKey after previous error', level: 'info');
        await Future.delayed(Duration(milliseconds: waitTime));
      }
    }

    // Always ensure socket is closed before creating a new one
    await _safeCloseSocket();

    int retryCount = 0;
    SocketException? lastException;
    StackTrace? lastStackTrace;

    while (retryCount < model.maxRetries) {
      try {
        _socket = await Socket.connect(
          model.ipAddress,
          model.port,
          timeout: model.timeout,
        );

        _host = model.ipAddress;
        _port = model.port;
        status = TCPStatus.connected;

        // Success - remove from tracking
        _lastConnectionAttempts.remove(printerKey);

        // Add a small delay after connecting to ensure printer is ready
        await Future.delayed(Duration(milliseconds: 100));

        return PrinterConnectStatusResult(isSuccess: true);
      } catch (e, stackTrace) {
        lastException = e is SocketException ? e : SocketException(e.toString());
        lastStackTrace = stackTrace;

        // Track this failed attempt
        _lastConnectionAttempts[printerKey] = DateTime.now();

        _log('Connection attempt ${retryCount + 1} failed: $e', level: 'error', error: e, stackTrace: stackTrace);

        if (retryCount < model.maxRetries - 1) {
          // Add some jitter to retry delays to avoid connection storms
          int jitter = (Random().nextInt(200) - 100); // -100ms to +100ms
          int delay = (1000 * (1 << retryCount) + jitter).clamp(500, 5000);
          await Future.delayed(Duration(milliseconds: delay));
        }
        retryCount++;
      }
    }

    status = TCPStatus.none;
    return PrinterConnectStatusResult(
      isSuccess: false,
      exception: '${model.ipAddress}:${model.port}: ${lastException}',
      stackTrace: lastStackTrace,
    );
  }

  @override
  Future<PrinterConnectStatusResult> send(List<int> bytes, {
    TcpPrinterInput? model,
    bool useDedicatedSocket = false
  }) async {
    final connectionStatus = await _checkConnectionStatus(model, useDedicatedSocket);
    if (!connectionStatus.isSuccess) return connectionStatus;

    try {
      if (useDedicatedSocket) {
        final socket = socketsPerIp[model!.ipAddress];
        socket!.add(Uint8List.fromList(bytes));
        await socket!.flush();
      } else {
        _socket!.add(Uint8List.fromList(bytes));
        await _socket!.flush();
      }
      return PrinterConnectStatusResult(isSuccess: true);
    } catch (e, stackTrace) {
      if (useDedicatedSocket) {
        _socketStatuses[model!.ipAddress] = TCPStatus.none;
        return PrinterConnectStatusResult(
          isSuccess: false,
          exception: 'Send error: $e',
          stackTrace: stackTrace,
        );
      } else {
        status = TCPStatus.none;
        return PrinterConnectStatusResult(
          isSuccess: false,
          exception: 'Send error: $e',
          stackTrace: stackTrace,
        );
      }
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

        _log('Print attempt ${retryCount + 1} failed: $e');

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
  Future<PrinterConnectStatusResult> splitSend(List<List<int>> bytes, {
    TcpPrinterInput? model,
    int delayBetweenMs = 50,
    bool useDedicatedSocket = false
  }) async {
    _log(
        '1. splitSend ${bytes.length} sections to print, total size: ${bytes.fold(0, (sum, item) => sum + item.length)} bytes',
        level: 'warn');

    // Ensure properly connected
    final connectionStatus = await _checkConnectionStatus(model, useDedicatedSocket);
    if (!connectionStatus.isSuccess) return connectionStatus;

    final extraLog = '(useDedicatedSocket:$useDedicatedSocket ${model?.ipAddress})';
    var socketConnection = useDedicatedSocket ? socketsPerIp[model?.ipAddress] : _socket;
    try {
      if (socketConnection == null) {
        throw SocketException('Socket is null');
      }

      _log('2.0. Socket close $extraLog');
      // await _socket!.close();
      try {
        // Set important socket options for printer communication
        socketConnection.setOption(SocketOption.tcpNoDelay, true);
      } catch (e, s) {
        if (model != null) {
          _log('2. Split send connect $extraLog');
          useDedicatedSocket ? await connectDedicatedSocket(model) : await connect(model);
        }
      }

      // Calculate adaptive delays based on data size
      int totalSize = bytes.fold(0, (sum, section) => sum + section.length);
      int sectionCount = bytes.length;

      // Calculate optimal delay between chunks (larger sections need more time)
      int adaptiveDelay = delayBetweenMs;
      if (sectionCount > 10) {
        adaptiveDelay = delayBetweenMs + 30;
      } else if (totalSize > 50000) {
        adaptiveDelay = delayBetweenMs + 20;
      }

      _log('3. Starting split send with ${bytes.length} sections, total size: $totalSize bytes, delay: $adaptiveDelay ms $extraLog');

      // More conservative flushing strategy
      for (int i = 0; i < bytes.length; i++) {
        if (socketConnection == null) throw SocketException('Socket is null');

        Socket validSocket = socketConnection;

        final section = bytes[i];
        if (section.isEmpty) continue;

        // Send data in smaller chunks if section is large
        if (section.length > 8192) {
          // Break large sections into chunks of 4KB
          final chunks = _splitIntoChunks(section, 4096);
          for (final chunk in chunks) {
            try {
              validSocket.add(Uint8List.fromList(chunk));
            } catch (e, s) {
              if (e.toString().contains('StreamSink is closed')) {
                if (model != null) {
                  _log('Split send try to reconnect after StreamSink is closed i:$i $extraLog', level: 'error', error: e, stackTrace: s);
                  useDedicatedSocket ? await connectDedicatedSocket(model) : await connect(model);
                }
                socketConnection = useDedicatedSocket ? socketsPerIp[model?.ipAddress] : _socket;
                if (socketConnection == null) throw SocketException('Socket is null');
                validSocket = socketConnection;
                validSocket.add(Uint8List.fromList(chunk));
              }
            }

            _log('4. Sent print chunk ${i + 1}/${bytes.length}, chunk size: ${bytes[i].length} bytes $extraLog', level: 'info');

            await validSocket.flush().timeout(Duration(seconds: 5), onTimeout: () {
              throw TimeoutException('Flush operation timed out - printer may be busy');
            });
            await Future.delayed(Duration(milliseconds: 20));
          }
        } else {
          // Small enough section to send at once
          try {
            validSocket.add(Uint8List.fromList(section));
          } catch (e, s) {
            if (e.toString().contains('StreamSink is closed')) {
              if (model != null) {
                _log('Split send try to reconnect after StreamSink is closed i:$i $extraLog', level: 'error', error: e, stackTrace: s);
                useDedicatedSocket ? await connectDedicatedSocket(model) : await connect(model);
              }
              socketConnection = useDedicatedSocket ? socketsPerIp[model?.ipAddress] : _socket;
              if (socketConnection == null) throw SocketException('Socket is null');
              validSocket = socketConnection;
              validSocket.add(Uint8List.fromList(section));
            }
          }
          _log('5. Sent small section print ${i + 1}/${bytes.length}, section size: ${bytes[i].length} bytes $extraLog',
              level: 'info');

          // Flush more frequently: always flush after each section
          await validSocket.flush().timeout(Duration(seconds: 3), onTimeout: () {
            throw TimeoutException('Flush operation timed out - printer may be busy');
          });
        }

        // Add delay between sections
        if (i < bytes.length - 1) {
          // Use adaptive delay based on section size
          int currentDelay = adaptiveDelay;
          if (section.length > 4096) {
            currentDelay += 20; // Additional delay for larger sections
          }
          await Future.delayed(Duration(milliseconds: currentDelay));
        }
      }

      // Give printer time to process before returning
      await Future.delayed(Duration(milliseconds: 200));

      _log('6. Successfully sent all ${bytes.length} print sections $extraLog', level: 'warn');
      return PrinterConnectStatusResult(isSuccess: true);
    } catch (e, stackTrace) {
      _log('7. Failed to splitSend print job $extraLog: $e', level: 'error', error: e, stackTrace: stackTrace);

      // Record printer issues
      if (model != null) {
        String printerKey = '${model.ipAddress}:${model.port}';
        _problematicPrinters[printerKey] = DateTime.now();
      }

      if (useDedicatedSocket) {
        if (model != null) {
          _socketStatuses[model.ipAddress] = TCPStatus.none;
          await _safeCloseSocket(printerIp: model.ipAddress);
        }
      } else {
        status = TCPStatus.none;
        await _safeCloseSocket();
      }
      return PrinterConnectStatusResult(
        isSuccess: false,
        exception: 'Split send error $extraLog: $e',
        stackTrace: stackTrace,
      );
    }
  }

  Future<PrinterConnectStatusResult> _checkConnectionStatus(TcpPrinterInput? model, bool useDedicatedSocket) async {
    if (model == null) {
      return PrinterConnectStatusResult(
        isSuccess: false,
        exception: 'Not connected and no connection details provided',
      );
    }

    if (useDedicatedSocket) {
      if (_socketStatuses[model.ipAddress] != TCPStatus.connected) {
        final connectResult = await connectDedicatedSocket(model);
        return connectResult;
      } else {
        return PrinterConnectStatusResult(isSuccess: true);
      }
    } else {
      if (!isConnected) {
        final connectResult = await connect(model);
        return connectResult;
      } else {
        return PrinterConnectStatusResult(isSuccess: true);
      }
    }
  }

  // Helper to split large chunks
  List<List<int>> _splitIntoChunks(List<int> source, int chunkSize) {
    List<List<int>> result = [];
    for (var i = 0; i < source.length; i += chunkSize) {
      var end = (i + chunkSize < source.length) ? i + chunkSize : source.length;
      result.add(source.sublist(i, end));
    }
    return result;
  }

  Future<void> _safeCloseSocket({String? printerIp}) async {
    final socketToClose = printerIp != null ? socketsPerIp[printerIp] : this._socket;
    if (socketToClose != null) {
      try {
        // Set a shorter timeout for closing operations
        bool socketClosed = false;

        // Try the gentle approach first
        try {
          await socketToClose.flush().timeout(Duration(milliseconds: 500), onTimeout: () {
            _log('${printerIp != null ? '$printerIp ' : ''}Socket flush timed out, proceeding to close', level: 'warn');
            return null;
          });

          await socketToClose.close().timeout(Duration(milliseconds: 500), onTimeout: () {
            _log('${printerIp != null ? '$printerIp ' : ''}Socket close timed out, will destroy socket', level: 'warn');
            return null;
          });

          socketClosed = true;
        } catch (e, s) {
          _log('${printerIp != null ? '$printerIp ' : ''}Error during socket close: $e',
              level: 'error', error: e, stackTrace: s);
        }

        // Always destroy the socket even if close fails
        socketToClose.destroy();
        if (printerIp != null) {
          socketsPerIp.remove(printerIp);
        } else {
          _socket = null;
        }

        if (socketClosed) {
          _log('${printerIp != null ? '$printerIp ' : ''}Socket closed successfully', level: 'debug');
        } else {
          _log('${printerIp != null ? '$printerIp ' : ''}Socket was destroyed after close failure', level: 'warn');
        }
      } catch (e) {
        _log('${printerIp != null ? '$printerIp ' : ''}Error during socket cleanup: $e', level: 'error', error: e);

        // Last resort - null out the socket
        if (printerIp != null) {
          socketsPerIp.remove(printerIp);
        } else {
          _socket = null;
        }
      }
    }
  }

  // Disconnect shared socket (_socket)
  @override
  Future<bool> disconnect({int? delayMs}) async {
    try {
      // Wait before closing to allow queued commands to complete
      if (delayMs != null && delayMs > 0) {
        await Future.delayed(Duration(milliseconds: delayMs));
      }

      await _safeCloseSocket();
      status = TCPStatus.none;
      return true;
    } catch (e) {
      _log('Error during disconnect: $e', level: 'error', error: e);
      status = TCPStatus.none;
      return false;
    }
  }

  // Connect to printers using 1 socket per IP (_sockets)
  @override
  Future<PrinterConnectStatusResult> connectDedicatedSocket(TcpPrinterInput model) async {
    // Clear any existing socket first
    await _safeCloseSocket(printerIp: model.ipAddress);

    String printerKey = '${model.ipAddress}:${model.port}';
    // Check if recently had a connection error and need to cool down
    if (_lastConnectionAttempts.containsKey(printerKey)) {
      DateTime lastAttempt = _lastConnectionAttempts[printerKey]!;
      Duration timeSince = DateTime.now().difference(lastAttempt);

      if (timeSince.inMilliseconds < _connectionCooldownMs) {
        // Force a delay to avoid overwhelming the printer
        int waitTime = _connectionCooldownMs - timeSince.inMilliseconds;
        _log('Waiting ${waitTime}ms before reconnecting to $printerKey after previous error', level: 'info');
        await Future.delayed(Duration(milliseconds: waitTime));
      }
    }

    // Always ensure socket is closed before creating a new one
    await _safeCloseSocket(printerIp: model.ipAddress);

    int retryCount = 0;
    SocketException? lastException;
    StackTrace? lastStackTrace;

    while (retryCount < model.maxRetries) {
      try {
        socketsPerIp[model.ipAddress] = await Socket.connect(
          model.ipAddress,
          model.port,
          timeout: model.timeout,
        );

        _socketStatuses[model.ipAddress] = TCPStatus.connected;

        // Success - remove from tracking
        _lastConnectionAttempts.remove(printerKey);

        // Add a small delay after connecting to ensure printer is ready
        await Future.delayed(Duration(milliseconds: 100));

        return PrinterConnectStatusResult(isSuccess: true);
      } catch (e, stackTrace) {
        lastException = e is SocketException ? e : SocketException(e.toString());
        lastStackTrace = stackTrace;

        // Track this failed attempt
        _lastConnectionAttempts[printerKey] = DateTime.now();

        _log('Connection attempt ${retryCount + 1} failed: $e', level: 'error', error: e, stackTrace: stackTrace);

        if (retryCount < model.maxRetries - 1) {
          // Add some jitter to retry delays to avoid connection storms
          int jitter = (Random().nextInt(200) - 100); // -100ms to +100ms
          int delay = (1000 * (1 << retryCount) + jitter).clamp(500, 5000);
          await Future.delayed(Duration(milliseconds: delay));
        }
        retryCount++;
      }
    }

    _socketStatuses[model.ipAddress] = TCPStatus.none;
    return PrinterConnectStatusResult(
      isSuccess: false,
      exception: '${model.ipAddress}:${model.port}: ${lastException}',
      stackTrace: lastStackTrace,
    );
  }

  // Disconnect socket connection map to 1 printer (_sockets)
  @override
  Future<bool> disconnectDedicatedSocket({int? delayMs, required String printerIp}) async {
    try {
      // Wait before closing to allow queued commands to complete
      if (delayMs != null && delayMs > 0) {
        await Future.delayed(Duration(milliseconds: delayMs));
      }

      await _safeCloseSocket(printerIp: printerIp);
      _socketStatuses[printerIp] = TCPStatus.none;
      return true;
    } catch (e) {
      _log('$printerIp Error during disconnect: $e', level: 'error', error: e);
      _socketStatuses[printerIp] = TCPStatus.none;
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
      _log('Error during printer discovery: $e');
    }

    return result;
  }

  Stream<PrinterDevice> discovery({required TcpPrinterInput? model}) async* {
    if (model?.ipAddress == null || model!.ipAddress.isEmpty) {
      _log('Invalid IP address provided');
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
      _log('Error during printer discovery: $e');
    }
  }

  Stream<TCPStatus> get currentStatus async* {
    yield status;
    yield* _statusStream;
  }

  // Clean up resources
  void dispose() {
    _safeCloseSocket();
    for (final ip in socketsPerIp.keys) {
      _safeCloseSocket(printerIp: ip);
    }
    _statusStreamController.close();
  }
}
