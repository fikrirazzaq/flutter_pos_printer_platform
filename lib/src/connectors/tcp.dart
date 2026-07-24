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

/// Tunables for feed-distance-based print pacing. Defaults are conservative
/// (worst-case cheap-printer values) so pacing is safe on the slowest supported
/// hardware; a caller may replace [TcpPrinterConnector.pacing] with faster
/// values derived from a known printer's capability profile.
class TcpPacingConfig {
  final double printSpeedMmPerMs; // 0.08 = 80 mm/s (slowest tier)
  final int dotsPerMm; // 8 = 203 dpi
  final int textLineHeightDots; // per-line feed distance for text sections

  /// Time to hold the socket/lock after a receipt's cut command before the
  /// NEXT receipt is allowed to start on this IP, covering the autocutter's
  /// mechanical cut-and-retract cycle.
  ///
  /// This was briefly raised to 1800ms while investigating a RONGTA WiFi
  /// jam under a 22+ receipt burst, on a theory that the cutter needed more
  /// recovery time. That theory was WRONG and the raise did not fix the jam
  /// — the real causes were three socket-layer defects (always-reconnect
  /// defeating socket reuse, `.listen()` on a reused single-subscription
  /// socket, and a too-short flush timeout; all P22-4885). With those
  /// fixed, the 1800ms was pure overhead: it accounted for ~53% of every
  /// kitchen receipt's wall time. Reverted to the researched 500ms.
  final int autocutterMechanicalMs;

  final int minInterSectionMs; // floor between sections

  /// Per-section margin added on top of the pure feed-distance estimate, to
  /// cover firmware command-parsing and WiFi round-trip latency a
  /// distance-only model doesn't capture. Also briefly raised (20→35) on the
  /// same wrong cutter theory above; reverted. This is a per-section fixed
  /// cost, so it is multiplied by section count — on a 74-section customer
  /// receipt each extra 15ms cost >1s of wall time for no benefit.
  final int safetyMarginMs;

  /// Fixed (NOT payload-scaled) settle applied only on the abort-recovery
  /// path, before the defensive cut is sent — i.e. only when a previous
  /// receipt to this IP aborted mid-send. It exists to let a status-less
  /// printer (a) finish draining its own internal buffer from the aborted
  /// attempt and (b) hit its firmware's per-command inter-byte timeout and
  /// abandon the truncated fixed-length raster command it was mid-way
  /// through, before any new bytes (the cut, then the fresh receipt) arrive.
  /// Without this, the cut and the head of the retry get consumed as pixel
  /// data for the stale command instead of being read as commands.
  ///
  /// Deliberately not scaled to unsent bytes/sections: what this waits out
  /// (bounded buffer drain + a firmware timeout) does not scale with payload
  /// size. This is a mitigation for a quick/mild stall only — it is NOT
  /// sufficient for a genuine hard jam that leaves the printer unresponsive
  /// for minutes; that case must be handled by the caller refusing to
  /// auto-retry into it, not by waiting longer here.
  final int abortRecoverySettleMs;

  const TcpPacingConfig({
    this.printSpeedMmPerMs = 0.08,
    this.dotsPerMm = 8,
    this.textLineHeightDots = 32,
    this.autocutterMechanicalMs = 500,
    this.minInterSectionMs = 30,
    this.safetyMarginMs = 20,
    this.abortRecoverySettleMs = 3000,
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

  // Cached broadcast-stream wrapper for the SHARED (_socket) path, mirroring
  // _SocketEntry.byteStream — see its doc comment. Identity-keyed so it's
  // only rewrapped when _socket is actually a different instance (a raw
  // Socket can only be wrapped/listened to once).
  Socket? _sharedByteStreamSocket;
  Stream<Uint8List>? _sharedByteStream;

  Stream<Uint8List> _byteStreamFor(Socket socket) {
    if (!identical(_sharedByteStreamSocket, socket)) {
      _sharedByteStreamSocket = socket;
      _sharedByteStream = socket.asBroadcastStream();
    }
    return _sharedByteStream!;
  }

  /// Feed-distance pacing tunables (see [TcpPacingConfig]). Conservative
  /// defaults; can be swapped for profile-derived values per printer tier.
  static TcpPacingConfig pacing = const TcpPacingConfig();

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

  // IPs whose previous receipt aborted mid-send. The next receipt to such an IP
  // prepends a defensive cut so any partial slip left buffered in the printer is
  // severed onto its own paper instead of merging with the new receipt.
  final Set<String> _abortedIps = {};

  // ESC d 3 (feed 3 lines) + GS V 0 (full cut) — the defensive cut above.
  static const List<int> _defensiveCut = [0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00];

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
    // Serialize writes per IP so a plain send() cannot interleave with a
    // concurrent splitSend/splitSendV2 on the same socket — an interleaved
    // write corrupts an in-flight receipt (scrambled/merged output). Acquired
    // AFTER _checkConnectionStatus because connectDedicatedSocket() also takes
    // this lock and _acquireLock is not reentrant.
    await _acquireLock(ip);
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
    } finally {
      _releaseLock(ip);
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

    // Serialize the whole retry/write loop per IP so it cannot interleave with
    // a concurrent splitSend on the same shared socket. connect() (shared) does
    // not take this lock, so reconnecting inside the loop won't deadlock.
    final ip = model?.ipAddress;
    if (ip != null) await _acquireLock(ip);
    try {
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
    } finally {
      if (ip != null) _releaseLock(ip);
    }
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
    bool useDedicatedSocket = false,
    required bool queryStatusPreSend,
    required bool isImageBased,
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

      PrinterQueryResult? queryResult;
      if (queryStatusPreSend) {
        queryResult =
            await PrinterStatusChecker.queryPrinterStatus(
          socket,
          useDedicatedSocket ? _socketRegistry[ip]!.byteStream : _byteStreamFor(socket),
          '${model.ipAddress}:${model.port}',
          cacheTtl: 5,
        );
        if (queryResult.hwCondition != PrinterHwStatus.ready) {
          return PrinterConnectStatusResult(
            isSuccess: false,
            exception: 'Pre-send check, printer is not ready: ${queryResult.hwCondition}',
            printerStatus: queryResult.hwCondition,
            queryResult: queryResult,
          );
        }
      }

      // Defensive cut: if the previous receipt to this IP aborted mid-send, its
      // partial bytes may still sit in the printer's buffer (ESC @ does not
      // clear it). Sever them onto their own slip before this receipt's content
      // so the two never merge (overlap / header-in-wrong-receipt / mid cut).
      // Done only after a real abort, and only once the printer checked ready.
      if (_abortedIps.remove(ip)) {
        // Settle before the cut, not after: the printer's parser must
        // drain/abandon the stale truncated command before any new bytes
        // arrive, or those bytes (the cut, then the fresh receipt) get read
        // as pixel data for the old command instead of as commands.
        await Future.delayed(Duration(milliseconds: pacing.abortRecoverySettleMs));
        _log('$ip prior receipt aborted — prepending defensive cut', level: 'warn');
        await _sendDataSection(
          socket: socket,
          model: model,
          useDedicatedSocket: useDedicatedSocket,
          sectionData: _defensiveCut,
          sectionIndex: -1,
        );
        await Future.delayed(Duration(milliseconds: pacing.autocutterMechanicalMs));
      }

      int totalSize = bytes.fold(0, (sum, section) => sum + section.length);
      _log(
          '2. splitSendV2 $ip${useDedicatedSocket ? '' : ' (shared)'} sending ${bytes.length} sections, total size: $totalSize bytes');

      for (int i = 0; i < bytes.length; i++) {
        final sectionData = bytes[i];
        if (sectionData.isNotEmpty) {
          // Single attempt per section — never re-send a section that may have
          // been partially written (that duplicated bytes → overlap/garble).
          // Any mid-receipt socket error is fatal for the whole receipt: it
          // propagates to the outer catch (which destroys the socket) and the
          // bloc re-sends the ENTIRE receipt from the start (atomic retry).
          await _sendDataSection(
            socket: socket,
            model: model,
            useDedicatedSocket: useDedicatedSocket,
            sectionData: sectionData,
            sectionIndex: i,
          );
        }

        _log(
            '3. splitSendV2 $ip${useDedicatedSocket ? '' : ' (shared)'} Sent section:$i, ${sectionData.isEmpty ? 'drain gap' : '${sectionData.length} bytes'}',
            level: 'info');
        // Apply inter-section delay
        if (i < bytes.length - 1) {
          final delayAfterSection = _calculateInterSectionDelay(
            isImageBased: isImageBased,
            currentSection: sectionData,
          );
          _log(
              '3.1. splitSendV2 $ip${useDedicatedSocket ? '' : ' (shared)'} Sent section:$i ${sectionData.length} bytes, delay $delayAfterSection',
              level: 'info');
          await Future.delayed(Duration(milliseconds: delayAfterSection));
        }
      }

      // End-of-receipt drain: wait for the final section (cut + trailing feed)
      // to physically print and the autocutter to fire before releasing the
      // socket/lock. Otherwise the next receipt on this IP can begin while the
      // cut is still mid-travel → mid-receipt cut / overlap under burst.
      final drainMs = bytes.isNotEmpty
          ? _endOfReceiptDrainMs(bytes.last, isImageBased)
          : pacing.autocutterMechanicalMs;
      await Future.delayed(Duration(milliseconds: drainMs));

      _log('4. splitSendV2 $ip${useDedicatedSocket ? '' : ' (shared)'} Successfully sent all ${bytes.length} print sections',
          level: 'warn');

      if (!queryStatusPreSend && socket != null) {
        queryResult =
            await PrinterStatusChecker.queryPrinterStatus(
          socket,
          useDedicatedSocket ? _socketRegistry[ip]!.byteStream : _byteStreamFor(socket),
          '${model.ipAddress}:${model.port}',
          cacheTtl: 5,
        );
      }

      return PrinterConnectStatusResult(
        isSuccess: true,
        printerStatus: queryResult?.hwCondition ?? PrinterHwStatus.unknown,
        queryResult: queryResult,
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
      // Flag this IP so the next receipt prepends a defensive cut to sever any
      // partial slip this aborted receipt may have left buffered in the printer.
      _abortedIps.add(ip);
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
      // Reuse a socket that's already open and live for this IP instead of
      // always tearing it down and reconnecting. This method is called at
      // the START of every print job (print_bloc.dart's _printReceipt calls
      // printerManager.connect() unconditionally, before splitSend), so
      // until now EVERY job forced a fresh TCP handshake here regardless of
      // worker mode's intent to keep one dedicated socket open across
      // successful jobs — silently defeating that design (P22-4885): the
      // "keep-socket-open so the printer's own TCP backpressure paces the
      // stream" architecture never actually took effect, because the socket
      // was destroyed and rebuilt right here before every single send. That
      // forces repeated connect/disconnect churn cheap WiFi-to-serial
      // printer modules (RONGTA) are known to handle poorly under sustained
      // back-to-back load — a very plausible contributor to jams under a
      // large multi-receipt burst that this reuse restores the pacing
      // benefit for.
      final existing = _socketRegistry[ip];
      if (existing != null && existing.status == TCPStatus.connected) {
        try {
          // Cheap local liveness probe (same pattern splitSendV2 uses):
          // throws only if the socket object itself was already closed/
          // destroyed locally, not a true end-to-end check.
          existing.socket.setOption(SocketOption.tcpNoDelay, true);
          _log('$ip reusing existing dedicated socket (skip reconnect)', level: 'info');
          return PrinterConnectStatusResult(isSuccess: true);
        } catch (_) {
          _log('$ip existing dedicated socket is dead — reconnecting', level: 'warn');
          await _closeIpDedicatedSocket(ip);
        }
      }

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
      // Hold the per-IP lock during teardown so a bulk reset can't close a
      // socket out from under a splitSendV2 still mid-receipt on that IP.
      // Do not wrap this in .timeout(): _acquireLock's wait loop keeps
      // running after a timeout throws, stranding a Completer nobody
      // releases and permanently wedging that IP's lock.
      await _acquireLock(ip);
      try {
        await _closeIpDedicatedSocket(ip);
      } finally {
        _releaseLock(ip);
      }
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
   * Sends one section of a receipt. On ANY socket error (add failure or flush
   * timeout) it destroys the socket and throws — the error is fatal for the
   * whole receipt. It never reconnects or resends mid-receipt (that duplicated
   * already-written bytes); the bloc re-sends the entire receipt on a fresh
   * socket instead.
   */
  Future<void> _sendDataSection({
    required Socket socket,
    required TcpPrinterInput model,
    required bool useDedicatedSocket,
    required List<int> sectionData,
    required int sectionIndex,
  }) async {
    // flush() blocking is the intended TCP-backpressure signal that a slow,
    // small-buffer printer (RONGTA) is still draining what we already sent.
    // It is NOT evidence the connection is dead, and the bytes are not lost
    // — they sit in the kernel send buffer and will be delivered once the
    // printer's receive window reopens. Destroying the socket here throws
    // that in-flight data away and forces a whole-receipt atomic retry,
    // which under load makes things strictly worse: the retry's fresh flood
    // lands on a printer still working through the previous attempt.
    //
    // Field data (P22-4885, RONGTA, 22+ receipt burst): at 2s this tripped
    // constantly; at 8s it still tripped ~once per run, each time costing a
    // ~11s stall AND a duplicate send of the entire receipt. Ordinary
    // congestion must never be fatal — so this is set well above any
    // plausible backpressure stall. It exists only to catch a genuinely
    // dead link; the bloc's 60s per-job watchdog is the real backstop for a
    // wedged printer (it tears the socket down and applies capped retry).
    var flushTimeout = const Duration(seconds: 30);
    try {
      socket.add(Uint8List.fromList(sectionData));
    } catch (e) {
      // Fatal: the socket broke mid-receipt. Destroy it and abort the whole
      // receipt (no reconnect, no resume, no resend).
      _log(
          '${model.ipAddress}${useDedicatedSocket ? '' : ' (shared)'} socket.add() failed, sectionIndex:$sectionIndex. aborting receipt',
          level: 'warn');
      socket.destroy();
      if (useDedicatedSocket) {
        _socketRegistry.remove(model.ipAddress);
      } else {
        _socket = null;
      }
      throw SocketException('[${model.ipAddress}] socket.add() failed at section $sectionIndex: $e');
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

  /// Inter-section pacing based on the physical **feed distance** of the section
  /// just sent, not its raw byte count. Raster bytes are not proportional to
  /// paper feed (an ESC * stripe packs 3 bytes/column × 24 dot-rows), so the old
  /// byte formula massively under-paced large images and let small-buffer
  /// printers overflow (dropped/garbled bytes). We estimate feed dots → mm → ms
  /// at the worst-case print speed, with NO upper clamp so large receipts pace
  /// out fully. Combined with buffer-aware chunk sizes, the printer's receive
  /// buffer never accumulates more than ~one section of un-printed data.
  int _calculateInterSectionDelay({
    required bool isImageBased,
    required List<int> currentSection,
  }) {
    if (currentSection.isEmpty) return pacing.minInterSectionMs;
    return _sectionPrintMs(currentSection, isImageBased) + pacing.safetyMarginMs;
  }

  /// Estimated milliseconds for the printer to physically render [section].
  int _sectionPrintMs(List<int> section, bool isImageBased) {
    final cfg = pacing;
    final feedDots = _estimateFeedDots(section, isImageBased);
    if (feedDots <= 0) return cfg.minInterSectionMs;
    final feedMm = feedDots / cfg.dotsPerMm;
    return max((feedMm / cfg.printSpeedMmPerMs).ceil(), cfg.minInterSectionMs);
  }

  /// Physical feed distance of a section, in printer dots. For raster, counts
  /// ESC * (0x1B 0x2A) stripe commands (each = 24 dot-rows) — robust and does
  /// not need the paper width. For text (or raster command-only sections),
  /// counts LF (0x0A) line feeds × line height.
  int _estimateFeedDots(List<int> section, bool isImageBased) {
    if (isImageBased) {
      var stripes = 0;
      for (var i = 0; i < section.length - 1; i++) {
        if (section[i] == 0x1B && section[i + 1] == 0x2A) stripes++;
      }
      if (stripes > 0) return stripes * 24;
    }
    var lineFeeds = 0;
    for (final b in section) {
      if (b == 0x0A) lineFeeds++;
    }
    return lineFeeds * pacing.textLineHeightDots;
  }

  /// End-of-receipt drain: time for the final section (cut + trailing feed) to
  /// physically print PLUS the autocutter's mechanical time, so the paper is
  /// fully advanced and cut before the socket/lock is released and the next
  /// receipt (possibly from another virtual printer on this IP) can begin.
  int _endOfReceiptDrainMs(List<int> lastSection, bool isImageBased) {
    return _sectionPrintMs(lastSection, isImageBased) + pacing.autocutterMechanicalMs;
  }
}

// Per-IP socket entry — owns the socket and its lifecycle state
class _SocketEntry {
  Socket socket;
  TCPStatus status;
  DateTime connectedAt;

  /// A raw `Socket` is a single-subscription stream: calling `.listen()` on
  /// it more than once ever throws "Bad state: Stream has already been
  /// listened to." `PrinterStatusChecker` calls `.listen()` fresh on every
  /// status query — harmless while every job got a brand-new socket, but
  /// once the socket started being REUSED across jobs (P22-4885), the
  /// second query on a reused socket crashed the whole receipt, which then
  /// auto-retried and printed a defensive-cut blank strip ahead of the
  /// retried content. Wrapping once, here, in a broadcast stream (which
  /// *does* support repeated listen/cancel cycles) fixes it for this
  /// socket's entire reused lifetime — a fresh entry (and fresh wrap) is
  /// only created when a real reconnect happens.
  late final Stream<Uint8List> byteStream = socket.asBroadcastStream();

  _SocketEntry({
    required this.socket,
    required this.connectedAt,
    this.status = TCPStatus.connected,
  });
}

