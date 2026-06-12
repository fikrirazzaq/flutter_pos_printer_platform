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
  final bool? isImageReceipt;

  TcpPrinterInput({
    required this.ipAddress,
    this.port = 9100,
    this.timeout = const Duration(seconds: 5),
    this.retryInterval = const Duration(seconds: 1),
    this.maxRetries = 3,
    this.isImageReceipt,
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

  // Per-IP mutex: prevents two concurrent operations on the same IP from creating duplicate sockets or tearing down a socket mid-send.
  final Map<String, Completer<void>> _ipLocks = {};

  // Primary registry: IP → socket entry
  final Map<String, _SocketEntry> _socketRegistry = {};

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
    if (model == null) {
      return PrinterConnectStatusResult(isSuccess: false, exception: 'TCP model is null');
    }

    final connectionStatus = await _checkConnectionStatus(model, useDedicatedSocket);
    if (!connectionStatus.isSuccess) return connectionStatus;

    final ip = model.ipAddress;
    try {
      final socket = useDedicatedSocket ? _socketRegistry[ip]?.socket : _socket;
      if (socket == null) {
        return PrinterConnectStatusResult(isSuccess: false, exception: 'socket is not established');
      }
      socket.add(Uint8List.fromList(bytes));
      await socket.flush();
      return PrinterConnectStatusResult(isSuccess: true);
    } catch (e, stackTrace) {
      if (useDedicatedSocket) {
        _socketRegistry[ip]?.status = TCPStatus.none;
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
    if (model == null) {
      return PrinterConnectStatusResult(isSuccess: false, exception: 'TCP model is null');
    }

    _log(
        '1. splitSend ${bytes.length} sections to print, total size: ${bytes.fold(0, (sum, item) => sum + item.length)} bytes',
        level: 'warn');

    // Ensure properly connected
    final connectionStatus = await _checkConnectionStatus(model, useDedicatedSocket);
    if (!connectionStatus.isSuccess) return connectionStatus;

    final extraLog = '(useDedicatedSocket:$useDedicatedSocket ${model.ipAddress})';
    var socketConnection = useDedicatedSocket ? _socketRegistry[model.ipAddress]?.socket : _socket;

    await _acquireLock(model.ipAddress);

    try {
      if (socketConnection == null) {
        throw SocketException('${model.ipAddress} Socket is null');
      }

      // _log('2.0. Socket close $extraLog');
      // await _socket!.close();
      try {
        // Set important socket options for printer communication
        socketConnection.setOption(SocketOption.tcpNoDelay, true);
      } catch (e, s) {
        _log('2. Split send connect $extraLog');
        useDedicatedSocket ? await connectDedicatedSocket(model) : await connect(model);
        socketConnection = useDedicatedSocket ? _socketRegistry[model.ipAddress]?.socket : _socket;
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
            var flushTimeout = Duration(seconds: 5);
            try {
              validSocket.add(Uint8List.fromList(chunk));
            } catch (e, s) {
              if (e.toString().contains('StreamSink is closed')) {
                if (model != null) {
                  _log('splitSend try to reconnect due to closed StreamSink i:$i $extraLog', level: 'warn', error: e, stackTrace: s);
                  final PrinterConnectStatusResult result =
                      useDedicatedSocket ? await connectDedicatedSocket(model) : await connect(model);
                  if (result.isSuccess) {
                    socketConnection = useDedicatedSocket ? _socketRegistry[model.ipAddress]?.socket : _socket;
                    if (socketConnection == null) {
                      throw SocketException('Socket is null');
                    }
                    _log('reconnect out of closed StreamSink success', level: 'warn');
                    // Give the printer time to accept the new connection
                    await Future.delayed(Duration(milliseconds: 300));
                    // Use longer timeout following a reconnect
                    flushTimeout = Duration(seconds: 8);
                    // Socket supposed to be ready to add & send/flush data
                    validSocket = socketConnection;
                    validSocket.add(Uint8List.fromList(chunk));
                  } else {
                    _log('reconnect out of closed StreamSink failed', level: 'error');
                  }
                } else {
                  _log('model = null. splitSend try to reconnect after StreamSink is closed i:$i $extraLog', level: 'error', error: e, stackTrace: s);
                }
              }
            }

            _log('4. Sent print chunk ${i + 1}/${bytes.length}, chunk size: ${bytes[i].length} bytes $extraLog', level: 'info');
            try {
              await validSocket.flush().timeout(flushTimeout);
            } on TimeoutException {
              // flush() waits for the printer to acknowledge all pending data via TCP ACKs.
              // If the printer is unresponsive or the connection dropped, ACKs never arrive
              // and flush() hangs until timeout. The socket's sink is now in a dangling
              // async state and cannot be reused — destroy immediately.
              _log('Flush timed out, destroying socket immediately', level: 'warn');
              validSocket.destroy();
              if (useDedicatedSocket) {
                _socketRegistry.remove(model.ipAddress);
              } else {
                _socket = null;
              }
              // Now rethrow or throw a clean exception for the outer catch
              throw TimeoutException('Flush timed out - printer may be busy');
            }
            await Future.delayed(Duration(milliseconds: 20));
          }
        } else {
          // Small enough section to send at once
          var flushTimeout = Duration(seconds: 5);
          try {
            validSocket.add(Uint8List.fromList(section));
          } catch (e, s) {
            if (e.toString().contains('StreamSink is closed')) {
              if (model != null) {
                _log('Split send try to reconnect due to closed StreamSink i:$i $extraLog', level: 'warn', error: e, stackTrace: s);
                final PrinterConnectStatusResult result =
                    useDedicatedSocket ? await connectDedicatedSocket(model) : await connect(model);
                if (result.isSuccess) {
                  socketConnection = useDedicatedSocket ? _socketRegistry[model.ipAddress]?.socket : _socket;
                  if (socketConnection == null) {
                    throw SocketException('Socket is null');
                  }
                  _log('reconnect out of closed StreamSink success', level: 'warn');
                  // Give the printer time to accept the new connection
                  await Future.delayed(Duration(milliseconds: 300));
                  // Use longer timeout following a reconnect
                  flushTimeout = Duration(seconds: 8);
                  // Socket supposed to be ready to add & send/flush data
                  validSocket = socketConnection;
                  validSocket.add(Uint8List.fromList(section));
                } else {
                  _log('reconnect out of closed StreamSink failed', level: 'error');
                }
              } else {
                _log('model = null. splitSend try to reconnect after StreamSink is closed i:$i $extraLog', level: 'error', error: e, stackTrace: s);
              }
            }
          }

          _log('5. Sent small section print ${i + 1}/${bytes.length}, section size: ${bytes[i].length} bytes $extraLog',
              level: 'info');
          // Flush more frequently: always flush after each section
          try {
            await validSocket.flush().timeout(flushTimeout);
          } on TimeoutException {
            // flush() waits for the printer to acknowledge all pending data via TCP ACKs.
            // If the printer is unresponsive or the connection dropped, ACKs never arrive
            // and flush() hangs until timeout. The socket's sink is now in a dangling
            // async state and cannot be reused — destroy immediately.
            _log('Flush timed out, destroying socket immediately', level: 'warn');
            validSocket.destroy();
            if (useDedicatedSocket) {
              _socketRegistry.remove(model.ipAddress);
            } else {
              _socket = null;
            }
            // Now rethrow or throw a clean exception for the outer catch
            throw TimeoutException('Flush timed out - printer may be busy');
          }
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

      // Post-send printer status verification
      PrinterHwStatus hwStatus = PrinterHwStatus.unknown;
      int? statusByte;
      try {
        if (socketConnection != null && model != null) {
          String printerKey = '${model.ipAddress}:${model.port}';
          final statusResult = await PrinterStatusChecker.queryStatus(
            socketConnection!,
            printerKey,
            maxRetries: 1,
            retryDelay: Duration(milliseconds: 100),
          );
          hwStatus = statusResult.status;
          statusByte = statusResult.rawByte;

          if (statusResult.responded) {
            if (hwStatus == PrinterHwStatus.ready) {
              _log('6.1. Post-send status: READY $extraLog', level: 'info');
            } else {
              _log(
                '6.1. Post-send status: ${hwStatus.name} (raw: 0x${statusByte?.toRadixString(16) ?? 'null'}) $extraLog',
                level: 'error',
              );
            }
          } else {
            _log('6.1. Post-send status: printer did not respond to status query $extraLog', level: 'warn');
          }
        }
      } catch (e) {
        _log('6.1. Post-send status check failed (non-fatal): $e $extraLog', level: 'warn');
        // Non-fatal — data was already sent successfully
      }

      return PrinterConnectStatusResult(
        isSuccess: true,
        printerStatus: hwStatus,
        statusByte: statusByte,
      );
    } catch (e, stackTrace) {
      _log('7. Failed to splitSend print job $extraLog: $e', level: 'error', error: e, stackTrace: stackTrace);

      // Record printer issues
      if (model != null) {
        String printerKey = '${model.ipAddress}:${model.port}';
        _problematicPrinters[printerKey] = DateTime.now();
      }

      if (useDedicatedSocket) {
        if (model != null) {
          _socketRegistry[model.ipAddress]?.status = TCPStatus.none;
          await _closeIpDedicatedSocket(model.ipAddress);
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
    } finally {
      _releaseLock(model.ipAddress);
    }
  }

  Future<PrinterConnectStatusResult> splitSendV2(List<List<int>> bytes, {
    TcpPrinterInput? model,
    int delayBetweenMs = 50,
    bool useDedicatedSocket = false
  }) async {
    if (model == null) {
      return PrinterConnectStatusResult(isSuccess: false, exception: 'TCP model is null');
    }

    final ip = model.ipAddress;
    _log(
        '1. splitSendV2 $ip ${bytes.length} sections to print, total size: ${bytes.fold(0, (sum, item) => sum + item.length)} bytes',
        level: 'warn');

    // Ensure properly connected
    final connectionStatus = await _checkConnectionStatus(model, useDedicatedSocket);
    if (!connectionStatus.isSuccess) {
      return connectionStatus;
    }

    // Acquire IP lock — blocks concurrent prints to same printer
    await _acquireLock(ip);

    try {
      Socket? socket = useDedicatedSocket ? _socketRegistry[ip]?.socket : _socket;
      if (socket == null) {
        throw SocketException('$ip Socket is null after lock acquired');
      }

      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (e) {
        // Socket dead before we even started — reconnect now before sending anything
        _log('$ip socket dead before send (setOption failed) — reconnecting', level: 'warn');
        socket = await _reconnectSocket(model, useDedicatedSocket);
      }

      // Calculate adaptive delays based on data size
      final contentSections = bytes.where((section) {
        // For image receipts, exclude sync pulse sections (ESC @ = 2 bytes) and drain sentinel (0 bytes) from size calculation.
        // These are timing/control sections, not content — including them would inflate sectionCount and trigger unnecessary delay increases.
        return section.isNotEmpty && ((model.isImageReceipt ?? false) ? section.length > 4 : true);
      });
      int totalSize = contentSections.fold(0, (sum, section) => sum + section.length);
      int sectionCount = contentSections.length;

      // Calculate optimal delay between chunks (larger sections need more time)
      int adaptiveDelay = delayBetweenMs;
      if (sectionCount > 10) {
        adaptiveDelay = delayBetweenMs + 30;
      } else if (totalSize > 50000) {
        adaptiveDelay = delayBetweenMs + 20;
      }

      _log(
          '2. splitSendV2 $ip${useDedicatedSocket ? '' : ' (shared)'} sending ${bytes.length} sections, total size: $totalSize bytes, delay: $adaptiveDelay ms');

      // More conservative flushing strategy
      for (int i = 0; i < bytes.length; i++) {
        final sectionData = bytes[i];
        if (sectionData.isNotEmpty) {
          const int maxSendAttempts = 2;
          int attempt = 1;

          sendAttempt:
          while (attempt <= maxSendAttempts) {
            try {
              await _sendChunk(
                socket: socket!,
                model: model,
                useDedicatedSocket: useDedicatedSocket,
                sectionData: sectionData,
                sectionIndex: i,
              );
              // no exception when sending data, exit from while scope
              break sendAttempt;
            } on _SocketReconnectedException catch (e) {
              // socket was reconnected & replaced mid-send, retry with new socketConnection
              socket = e.newSocket;
              // Short pause to let printer settle after new connection
              await Future.delayed(const Duration(milliseconds: 300));
              attempt++;
              if (((model.isImageReceipt ?? false) && i > 0) || attempt > maxSendAttempts) {
                // if image receipt and reconnect on mid-send (section > 0), treat as a full failure
                // if still failed on 2nd attempt, after first reconnect attempt, regardless section
                // handle by outer catch
                rethrow;
              } else {
                _log('$ip${useDedicatedSocket ? '' : ' (shared)'} socket replaced when sending section:$i, retry send #$attempt', level: 'warn');
              }
            } catch (e, s) {
              rethrow; // handle by outer catch
            }
          }
        }

        _log(
            '3. splitSendV2 $ip${useDedicatedSocket ? '' : ' (shared)'} Sent section:$i, ${sectionData.isEmpty ? 'drain gap' : '${sectionData.length} bytes'}',
            level: 'info');
        if (i < bytes.length - 1) {
          // Use adaptive delay based on section size
          int currentDelay = adaptiveDelay;
          if (sectionData.isEmpty) {
            // Empty drain sentinel before cut — use full adaptive delay
            currentDelay = adaptiveDelay;
          } else if (sectionData.length <= 4) {
            // Likely reset section, or pre-cut-delay on image printing
            currentDelay = delayBetweenMs;
          } else if (sectionData.length > 4096) {
            currentDelay += 20; // Additional delay for larger sections
          }
          _log(
              '3.1. splitSendV2 $ip${useDedicatedSocket ? '' : ' (shared)'} Sent section:$i ${sectionData.length} bytes, delay $currentDelay',
              level: 'info');
          await Future.delayed(Duration(milliseconds: currentDelay));
        }
      }

      // Give printer time to process before returning
      await Future.delayed(Duration(milliseconds: 200));

      _log('4. splitSendV2 $ip${useDedicatedSocket ? '' : ' (shared)'} Successfully sent all ${bytes.length} print sections',
          level: 'warn');

      // TODO post-send printer check, apply later

      return PrinterConnectStatusResult(
        isSuccess: true,
      );
    } catch (e, stackTrace) {
      _log('splitSendV2 $ip${useDedicatedSocket ? '' : ' (shared)'} failed: $e',
          level: 'error', error: e, stackTrace: stackTrace);

      // Record printer issues
      String printerKey = '${model.ipAddress}:${model.port}';
      _problematicPrinters[printerKey] = DateTime.now();

      // Close socket
      if (useDedicatedSocket) {
        _socketRegistry[ip]?.status = TCPStatus.none;
        await _closeIpDedicatedSocket(ip);
      } else {
        status = TCPStatus.none;
        await _safeCloseSocket();
      }
      return PrinterConnectStatusResult(
        isSuccess: false,
        exception: 'splitSendV2 error $ip${useDedicatedSocket ? '' : ' (shared)'}: $e',
        stackTrace: stackTrace,
      );
    } finally {
      _releaseLock(ip);
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
      final isConnected = _socketRegistry[model.ipAddress]?.status == TCPStatus.connected;
      if (isConnected) {
        return PrinterConnectStatusResult(isSuccess: true);
      } else {
        return await connectDedicatedSocket(model);
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

  Future<void> _safeCloseSocket() async {
    final socketToClose = this._socket;
    if (socketToClose == null) {
      return;
    }

    // Nullify reference immediately so no other call touches this socket
    _socket = null;

    try {
      // Skip flush — this is always a teardown path.
      // flush() on a dangling sink throws Bad state; there's no data worth saving.
      await socketToClose.close().timeout(Duration(milliseconds: 500));
      _log('Socket closed successfully', level: 'debug');
    } catch (e, s) {
      // close() failed or timed out — destroy() below handles actual cleanup
      _log('Socket close failed - cleanup handled by destroy()', level: 'error', error: e, stackTrace:  s);
    } finally {
      // Unconditional — the only guaranteed cleanup for OS-level socket resources
      try {
        socketToClose.destroy();
      } catch (_) {
        // destroy() should never throw, but if it does, we silence it here so it won't suppress the error above
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

  // Connect to printers using IP-dedicated-socket (_socketRegistry)
  @override
  Future<PrinterConnectStatusResult> connectDedicatedSocket(TcpPrinterInput model) async {
    final ip = model.ipAddress;
    final printerKey = '${model.ipAddress}:${model.port}';

    await _acquireLock(ip);

    try {
      // Check if recently had a connection error and need to cool down
      await _applyCooldown(printerKey);

      // Close any existing socket for this IP before creating a new one
      await _closeIpDedicatedSocket(ip);

      int retryCount = 0;
      SocketException? lastException;
      StackTrace? lastStackTrace;

      while (retryCount < model.maxRetries) {
        try {
          final newSocket = await Socket.connect(ip, model.port, timeout: model.timeout);
          newSocket.setOption(SocketOption.tcpNoDelay, true);
          _socketRegistry[ip] =
              _SocketEntry(socket: newSocket, connectedAt: DateTime.now(), status: TCPStatus.connected);

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
      return PrinterConnectStatusResult(
        isSuccess: false,
        exception: '$printerKey: ${lastException}',
        stackTrace: lastStackTrace,
      );
    } finally {
      _releaseLock(ip);
    }
  }

  // Disconnect IP-dedicated-socket (_socketRegistry)
  @override
  Future<bool> disconnectDedicatedSocket({int? delayMs, required String printerIp}) async {
    try {
      // Wait before closing to allow queued commands to complete
      if (delayMs != null && delayMs > 0) {
        await Future.delayed(Duration(milliseconds: delayMs));
      }
      await _acquireLock(printerIp);
      await _closeIpDedicatedSocket(printerIp);
      _releaseLock(printerIp);
      return true;
    } catch (e, s) {
      _log('$printerIp Error during disconnect: $e', level: 'error', error: e, stackTrace: s);
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
    disposeAllDedicatedSockets();
    _statusStreamController.close();
  }

  Future<void> disposeAllDedicatedSockets({int? delayMs}) async {
    // Wait before closing to allow queued commands to complete
    if (delayMs != null && delayMs > 0) {
      await Future.delayed(Duration(milliseconds: delayMs));
    }
    final ips = List<String>.from(_socketRegistry.keys);
    for (final ip in ips) {
      await _closeIpDedicatedSocket(ip);
    }
  }

  /**
   * IP-level lock — ensures only one operation runs per IP at a time
   * Callers await _acquireLock, do their work, then call _releaseLock.
   */
  Future<void> _acquireLock(String ip) async {
    while (_ipLocks.containsKey(ip)) {
      await _ipLocks[ip]!.future;
    }
    _ipLocks[ip] = Completer<void>();
  }

  void _releaseLock(String ip) {
    final completer = _ipLocks.remove(ip);
    completer?.complete();
  }

  Future<void> _applyCooldown(String printerKey) async {
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
  }

  /**
   * Safely close and remove a socket entry for the given IP.
   * Always nullifies the registry entry first so no other caller can acquire the dangling socket reference.
   */
  Future<void> _closeIpDedicatedSocket(String ip) async {
    final entry = _socketRegistry.remove(ip);
    if (entry == null) return;
    try {
      await entry.socket.close().timeout(const Duration(milliseconds: 500));
      _log('${ip} Socket closed successfully', level: 'info');
    } catch (e, s) {
      _log('${ip} Socket close() failed - cleanup handled by destroy()', level: 'error', error: e, stackTrace: s);
    } finally {
      try {
        entry.socket.destroy();
      } catch (e, s) {
        _log('${ip} Socket destroy() failed', level: 'error', error: e, stackTrace: s);
      }
    }
  }

  /***
   * Sends one chunk, handles socket errors, returns active socket.
   * Throws _SocketReconnectedException when a reconnect was needed, for caller to catch and handle a retry send
   */
  Future<void> _sendChunk({
    required Socket socket,
    required TcpPrinterInput model,
    required bool useDedicatedSocket,
    required List<int> sectionData,
    required int sectionIndex,
  }) async {
    var flushTimeout = const Duration(seconds: 5);
    try {
      socket.add(Uint8List.fromList(sectionData));
    } catch (e, s) {
      _log(
          '${model.ipAddress}${useDedicatedSocket ? '' : ' (shared)'} socket.add() failed, sectionIndex:$sectionIndex. reconnecting',
          level: 'warn');
      final newSocket = await _reconnectSocket(model, useDedicatedSocket);
      // Signal the send caller to restart with the new socket
      throw _SocketReconnectedException(newSocket, sectionIndex: sectionIndex);
    }

    try {
      await socket.flush().timeout(flushTimeout);
    } on TimeoutException {
      _log('${model.ipAddress} flush() timed out, sectionIndex:$sectionIndex. destroying socket${useDedicatedSocket ? ' (dedicated)' : ''}', level: 'warn');
      socket.destroy();
      if (useDedicatedSocket) {
        _socketRegistry.remove(model.ipAddress);
      } else {
        _socket = null;
      }
      throw TimeoutException('[${model.ipAddress}] flush() timed out, printer may be busy${useDedicatedSocket ? ' (dedicated)' : ''}');
    }
  }

  /**
   * Closes current socket, opens a new one, returns it.
   * Must be called while the IP lock is held (splitSend holds it).
   */
  Future<Socket> _reconnectSocket(TcpPrinterInput model, bool useDedicatedSocket) async {
    assert(_ipLocks.containsKey(model.ipAddress),
        '_reconnectSocket called without holding IP lock for ${model.ipAddress}');

    final ip = model.ipAddress;
    if (useDedicatedSocket) {
      await _closeIpDedicatedSocket(ip);
      final newSocket = await Socket.connect(ip, model.port, timeout: model.timeout);
      newSocket.setOption(SocketOption.tcpNoDelay, true);
      _socketRegistry[ip] = _SocketEntry(socket: newSocket, connectedAt: DateTime.now(), status: TCPStatus.connected);
      await Future.delayed(const Duration(milliseconds: 300));
      _log('$ip Reconnected (dedicated)', level: 'info');
      return newSocket;
    } else {
      await _safeCloseSocket();
      final socket = await Socket.connect(ip, model.port, timeout: model.timeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      status = TCPStatus.connected;
      await Future.delayed(const Duration(milliseconds: 300));
      _log('$ip Reconnected (shared)', level: 'info');
      return socket;
    }
  }
}

// Per-IP socket entry — owns the socket and its lifecycle state
class _SocketEntry {
  Socket socket;
  TCPStatus status;
  DateTime connectedAt;

  _SocketEntry({
    required this.socket,
    required this.connectedAt,
    this.status = TCPStatus.connected,
  });
}

class _SocketReconnectedException {
  final Socket newSocket;
  final int sectionIndex; // which section was being sent

  const _SocketReconnectedException(this.newSocket, {
    required this.sectionIndex,
  });
}

