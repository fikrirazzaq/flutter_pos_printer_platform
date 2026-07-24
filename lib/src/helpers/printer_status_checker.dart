import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../printer.dart';

class PrinterStatusResult {
  final bool responded;
  final PrinterHwStatus status;
  final int? rawByte;

  const PrinterStatusResult({
    required this.responded,
    this.status = PrinterHwStatus.unknown,
    this.rawByte,
  });

  static const notResponding = PrinterStatusResult(
    responded: false,
    status: PrinterHwStatus.notResponding,
  );
}

class PrinterStatusChecker {
  // DLE EOT commands — most widely supported for real-time status. Printer responds immediately
  static const List<int> dleEot1 = [0x10, 0x04, 0x01]; // Printer status
  static const List<int> dleEot2 = [0x10, 0x04, 0x02]; // Offline cause status
  static const List<int> dleEot3 = [0x10, 0x04, 0x03]; // Error cause status
  static const List<int> dleEot4 = [0x10, 0x04, 0x04]; // Paper roll sensor status

  // GS r n — paper sensor status (buffered, may lag behind buffer)
  // Useful as fallback for printers that don't support DLE EOT
  static const List<int> gsR1   = [0x1D, 0x72, 0x01]; // GS r 1: paper sensor (buffered fallback)
  static const List<int> gsR49  = [0x1D, 0x72, 0x31]; // GS r 49: some Star/Generic models use n=49

  // paper sensor, older Epson (TM-T70, TM-U220)
  static const List<int> escV = [0x1B, 0x76];

  static const List<List<int>> statusCommands = [
    dleEot1, // DLE EOT 1 - Printer status (most common)
    dleEot4, // DLE EOT 4 - Paper roll sensor
    dleEot3, // DLE EOT 3 - Error cause
    [0x1B, 0x76], // ESC v - Epson
    [0x1D, 0x72, 0x01], // GS r n - Generic/Star
    [0x1D, 0x72, 0x11], // GS r n - Generic/Star (different status type)
    [0x1B, 0x75, 0x0], // ESC u 0 - Star
    [0x1B, 0x69], // ESC i - Star
    [0x1B, 0x31], // ESC 1 - POS-X
    [0x1D, 0x49, 0x01], // GS I n - Generic status
    [0x1D, 0x49, 0x02], // GS I n - Generic status (different type)
    [0x1B, 0x74, 0x01], // ESC t n - Generic status
    [0x1B, 0x76, 0x01], // ESC v n - Rongta/Generic
    [0x1D, 0x61, 0x01], // GS a n - Generic status
  ];

  // Cache of working commands per printer
  static final Map<String, List<int>> _workingCommands = {};

  /// Check printer status — returns true if printer responds (legacy API)
  static Future<bool> checkStatus(Socket socket, String printerKey,
      {int maxRetries = 3, Duration retryDelay = const Duration(milliseconds: 200)}) async {
    final result = await queryStatus(socket, printerKey, maxRetries: maxRetries, retryDelay: retryDelay);
    return result.responded;
  }

  /// Query printer status with detailed result including hardware status parsing
  static Future<PrinterStatusResult> queryStatus(
    Socket socket,
    String printerKey, {
    int maxRetries = 3,
    Duration retryDelay = const Duration(milliseconds: 200),
  }) async {
    int retryCount = 0;

    while (retryCount < maxRetries) {
      // Try cached command first
      if (_workingCommands.containsKey(printerKey)) {
        try {
          final result = await _tryCommandWithResponse(socket, _workingCommands[printerKey]!);
          if (result.responded) return result;
        } catch (e) {
          // Cached command failed, will try others
        }
      }

      // Try each command
      for (var command in statusCommands) {
        try {
          final result = await _tryCommandWithResponse(socket, command);
          if (result.responded) {
            _workingCommands[printerKey] = command;
            return result;
          }
        } catch (e) {
          continue;
        }
      }

      retryCount++;
      if (retryCount < maxRetries) {
        await Future.delayed(retryDelay);
      }
    }

    return PrinterStatusResult.notResponding;
  }

  /// Send a status command and read + parse the response byte
  static Future<PrinterStatusResult> _tryCommandWithResponse(Socket socket, List<int> command) async {
    final completer = Completer<PrinterStatusResult>();

    // Listen for response before sending
    StreamSubscription<Uint8List>? sub;
    Timer? timeout;

    timeout = Timer(const Duration(milliseconds: 300), () {
      sub?.cancel();
      if (!completer.isCompleted) {
        completer.complete(PrinterStatusResult.notResponding);
      }
    });

    sub = socket.listen(
      (data) {
        timeout?.cancel();
        sub?.cancel();
        if (!completer.isCompleted && data.isNotEmpty) {
          final statusByte = data[0];
          final hwStatus = _parseStatusByte(statusByte, command);
          completer.complete(PrinterStatusResult(
            responded: true,
            status: hwStatus,
            rawByte: statusByte,
          ));
        }
      },
      onError: (e) {
        timeout?.cancel();
        sub?.cancel();
        if (!completer.isCompleted) {
          completer.complete(PrinterStatusResult.notResponding);
        }
      },
      onDone: () {
        timeout?.cancel();
        if (!completer.isCompleted) {
          completer.complete(PrinterStatusResult.notResponding);
        }
      },
    );

    // Send the status command
    try {
      socket.add(Uint8List.fromList(command));
      await socket.flush();
    } catch (e) {
      timeout?.cancel();
      sub?.cancel();
      if (!completer.isCompleted) {
        completer.complete(PrinterStatusResult.notResponding);
      }
    }

    return completer.future;
  }

  /// Parse DLE EOT response bytes according to ESC/POS specification
  ///
  /// DLE EOT 1 (printer status): Bit 3 = online, Bit 5 = cover open
  /// DLE EOT 2 (offline cause):  Bit 2 = cover open, Bit 3 = feed button, Bit 5 = error
  /// DLE EOT 3 (error cause):    Bit 2 = recoverable, Bit 3 = auto-cutter, Bit 5 = unrecoverable
  /// DLE EOT 4 (paper sensor):   Bit 2,3 = paper near-end, Bit 5,6 = paper absent
  static PrinterHwStatus _parseStatusByte(int byte, List<int> command) {
    // Check if this is a DLE EOT response
    if (command.length == 3 && command[0] == 0x10 && command[1] == 0x04) {
      final n = command[2];

      switch (n) {
        case 1: // Printer status
          // Bit 3 (0x08): 0=online, 1=offline
          if (byte & 0x08 != 0) return PrinterHwStatus.error;
          return PrinterHwStatus.ready;

        case 2: // Offline cause
          // Bit 2 (0x04): cover open
          if (byte & 0x04 != 0) return PrinterHwStatus.coverOpen;
          // Bit 5 (0x20): error occurred
          if (byte & 0x20 != 0) return PrinterHwStatus.error;
          return PrinterHwStatus.ready;

        case 3: // Error cause
          // Bit 2 (0x04): recoverable error
          // Bit 3 (0x08): auto-cutter error
          // Bit 5 (0x20): unrecoverable error
          if (byte & 0x20 != 0) return PrinterHwStatus.error;
          if (byte & 0x08 != 0) return PrinterHwStatus.error;
          if (byte & 0x04 != 0) return PrinterHwStatus.error;
          return PrinterHwStatus.ready;

        case 4: // Paper roll sensor
          // Bit 5 (0x20) + Bit 6 (0x40): paper end detected
          if (byte & 0x60 != 0) return PrinterHwStatus.paperOut;
          // Bit 2 (0x04) + Bit 3 (0x08): paper near-end (still printable, but warning)
          // Don't fail for near-end, just return ready
          return PrinterHwStatus.ready;
      }
    }

    // For non-DLE-EOT commands, any response means printer is alive
    return PrinterHwStatus.ready;
  }

  static final Map<String, PrinterQueryResult> _queryResultCache = {};
  static const List<PrinterStatusCommand> _probeCommands = [
    PrinterStatusCommand(
      statusType: PrinterStatusType.cover,
      priority: 1,
      bytes: PrinterStatusChecker.dleEot2,
      canBlockPrint: true,
    ),
    PrinterStatusCommand(
      statusType: PrinterStatusType.paper,
      priority: 1,
      bytes: PrinterStatusChecker.dleEot4,
      canBlockPrint: true,
    ),
    PrinterStatusCommand(
      statusType: PrinterStatusType.paper,
      priority: 2,
      bytes: gsR1,
      canBlockPrint: true,
    ),
    PrinterStatusCommand(
      statusType: PrinterStatusType.paper,
      priority: 3,
      bytes: gsR49,
      canBlockPrint: true,
    ),
    PrinterStatusCommand(
      statusType: PrinterStatusType.paper,
      priority: 4,
      bytes: escV,
      canBlockPrint: true,
    ),
    PrinterStatusCommand(
      statusType: PrinterStatusType.error,
      priority: 1,
      bytes: PrinterStatusChecker.dleEot3,
      canBlockPrint: true,
    ),
  ];

  /// [byteStream] must be a broadcast-stream wrapper of [socket]'s incoming
  /// bytes (e.g. `socket.asBroadcastStream()`, cached and reused for the
  /// socket's whole lifetime by the caller — see `TcpPrinterConnector`'s
  /// `_SocketEntry.byteStream`). A raw `Socket` is single-subscription: once
  /// something calls `.listen()` on it, listening again ever — even after
  /// canceling — throws "Bad state: Stream has already been listened to."
  /// This function used to call `socket.listen()` directly each time, which
  /// was fine only because every job got a brand-new socket; once sockets
  /// started being reused across jobs (P22-4885), the second status query
  /// on a reused socket crashed the whole receipt.
  static Future<PrinterQueryResult> queryPrinterStatus(
      Socket socket, Stream<Uint8List> byteStream, String printerKey, {int? cacheTtl}) async {
    final cached = _queryResultCache[printerKey];

    if (cached != null) {
      if (DateTime.now().difference(cached.lastQueried!) < Duration(seconds: cacheTtl ?? 3)) {
        debugPrint('${printerKey} (queryPrinterStatus) ${DateTime.now()} _queryUsingProfile skipped. use recent cache ${cached.toString()}');
        return cached;
      } else {
        debugPrint('${printerKey} (queryPrinterStatus) ${DateTime.now()} _queryUsingProfile ${cached.toString()}');
        return await _queryUsingProfile(socket, byteStream, printerKey, cached);
      }
    }

    return await _probeAndBuildProfile(socket, byteStream, printerKey);
  }

  static Future<PrinterQueryResult> _probeAndBuildProfile(Socket socket, Stream<Uint8List> byteStream, String printerKey) async {
    final profile = PrinterQueryResult();

    // Single listener for the entire probe session, sourced from the
    // caller's persistent broadcast wrapper (see the [byteStream] doc above)
    // so this can run again later on the same (reused) socket without
    // hitting "stream already listened to".
    final responseStream = StreamController<int>.broadcast();
    final sub = byteStream.listen(
      (data) {
        for (final byte in data) {
          responseStream.add(byte);
        }
      },
      onError: (_) => responseStream.close(),
      onDone: () => responseStream.close(),
      cancelOnError: true,
    );

    try {
      for (final statusType in PrinterStatusType.values) {
        final candidates = _probeCommands.where((c) => c.statusType == statusType).toList()
          ..sort((a, b) => a.priority.compareTo(b.priority));
        for (final command in candidates) {
          debugPrint(
              '${printerKey} (queryPrinterStatus) _probeAndBuildProfile -> _getStatusResponse ${statusType.name} ${command.priority} ${command.bytes.toHex()}..');
          final response = await _getValidatedStatusResponse(socket, responseStream.stream, command.bytes);
          await Future.delayed(const Duration(milliseconds: 30)); // let buffer settle
          if (response != null) {
            // This command works for this printer — cache it
            final status = _decodeStatusResponse(command, response);
            debugPrint(
                '${printerKey} (queryPrinterStatus) _probeAndBuildProfile -> _getStatusResponse ${statusType.name} ${command.priority} ${command.bytes.toHex()}.. RESPONDED dec=${response}, hex=${response.toRadixString(16).padLeft(2, '0')}, status=${status.name}');
            switch (command.statusType) {
              case PrinterStatusType.paper:
                profile.paperCommand = command;
                profile.paperStatus = status;
                profile.paperLastBytes = response;
                break;
              case PrinterStatusType.cover:
                profile.coverCommand = command;
                profile.coverStatus = status;
                profile.coverLastBytes = response;
                break;
              case PrinterStatusType.error:
                profile.errorCommand = command;
                profile.errorStatus = status;
                profile.errorLastBytes = response;
                break;
            }
            // break `candidates` loop after working command for x status identified
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('(queryPrinterStatus) _probeAndBuildProfile Err $e');
    } finally {
      await sub.cancel();
      await responseStream.close();
    }

    _updateResponsiveness(profile);
    profile.lastQueried = DateTime.now();
    _queryResultCache.putIfAbsent(printerKey, () => profile);
    return profile;
  }

  /// Tracks whether THIS round got a genuine response for any status type,
  /// and maintains [PrinterQueryResult.hasEverResponded] /
  /// [PrinterQueryResult.consecutiveMisses] — the state [hwCondition] uses to
  /// tell "this printer never supports status queries" (assume-ready is the
  /// only sane default) apart from "this printer used to answer and has gone
  /// silent" (a real fault: offline, unplugged, wedged buffer).
  static void _updateResponsiveness(PrinterQueryResult profile) {
    final respondedThisRound = profile.coverStatus != PrinterHwStatus.unknown ||
        profile.paperStatus != PrinterHwStatus.unknown ||
        profile.errorStatus != PrinterHwStatus.unknown;
    if (respondedThisRound) {
      profile.hasEverResponded = true;
      profile.consecutiveMisses = 0;
    } else {
      profile.consecutiveMisses++;
    }
  }

  static Future<PrinterQueryResult> _queryUsingProfile(
      Socket socket, Stream<Uint8List> byteStream, String printerKey, PrinterQueryResult profile) async {

    // Single listener for the entire check, sourced from the caller's
    // persistent broadcast wrapper — see [queryPrinterStatus]'s doc comment.
    final responseStream = StreamController<int>.broadcast();
    final sub = byteStream.listen(
      (data) {
        for (final byte in data) {
          responseStream.add(byte);
        }
      },
      onError: (_) => responseStream.close(),
      onDone: () => responseStream.close(),
      cancelOnError: true,
    );

    try {
      // Cover Check
      if (profile.coverCommand != null) {
        debugPrint(
            '${printerKey} (queryPrinterStatus) _queryUsingProfile -> _getStatusResponse cover ${profile.coverCommand!
                .priority} ${profile.coverCommand!.bytes.toHex()}..');
        final response = await _getValidatedStatusResponse(socket, responseStream.stream, profile.coverCommand!.bytes);
        if (response != null) {
          profile.coverLastBytes = response;
          profile.coverStatus = _decodeStatusResponse(profile.coverCommand!, response);
          debugPrint(
              '${printerKey} (queryPrinterStatus) _queryUsingProfile -> _getStatusResponse cover ${profile.coverCommand!
                  .priority} ${profile.coverCommand!.bytes.toHex()}.. RESPONDED dec=${response}, hex=${response
                  .toRadixString(16).padLeft(2, '0')}, status=${profile.coverStatus.name}');
        } else {
          // Previous command not working anymore, likely the printer model is changed or current printer status is different (i.e: normal -> paper out)
          final (newRespondedCommand, response) = await _reDiscoverPrinterProfile(
              socket, responseStream, printerKey, type: PrinterStatusType.cover, currentCommand: profile.coverCommand!);
          if (newRespondedCommand != null && response != null) {
            profile.coverLastBytes = response;
            profile.coverStatus = _decodeStatusResponse(newRespondedCommand, response);
            profile.coverCommand = newRespondedCommand;
            debugPrint(
                '${printerKey} (queryPrinterStatus) _reDiscoverPrinterProfile -> _getStatusResponse ${PrinterStatusType.cover} ${newRespondedCommand.priority} ${newRespondedCommand.bytes.toHex()}.. RESPONDED dec=${response}, hex=${response.toRadixString(16).padLeft(2, '0')}, status=${profile.coverStatus.name}');
          } else {
            profile.coverStatus = PrinterHwStatus.unknown;
          }
        }
      }

      // Paper Check
      if (profile.paperCommand != null && profile.isCoverNormal) {
        debugPrint(
            '${printerKey} (queryPrinterStatus) _queryUsingProfile -> _getStatusResponse paper ${profile.paperCommand!
                .priority} ${profile.paperCommand!.bytes.toHex()}..');
        await Future.delayed(const Duration(milliseconds: 30)); // let buffer settle
        final response = await _getValidatedStatusResponse(socket, responseStream.stream, profile.paperCommand!.bytes);
        if (response != null) {
          profile.paperLastBytes = response;
          profile.paperStatus = _decodeStatusResponse(profile.paperCommand!, response);
          debugPrint(
              '${printerKey} (queryPrinterStatus) _queryUsingProfile -> _getStatusResponse paper ${profile.paperCommand!
                  .priority} ${profile.paperCommand!.bytes.toHex()}.. RESPONDED dec=${response}, hex=${response
                  .toRadixString(16).padLeft(2, '0')}, status=${profile.paperStatus.name}');
        } else {
          // Previous command not working anymore, likely the printer model is changed or current printer status is different (i.e: normal -> paper out)
          final (newRespondedCommand, response) = await _reDiscoverPrinterProfile(
              socket, responseStream, printerKey, type: PrinterStatusType.paper, currentCommand: profile.paperCommand!);
          if (newRespondedCommand != null && response != null) {
            profile.paperLastBytes = response;
            profile.paperStatus = _decodeStatusResponse(newRespondedCommand, response);
            profile.paperCommand = newRespondedCommand;
            debugPrint('${printerKey} (queryPrinterStatus) _reDiscoverPrinterProfile -> _getStatusResponse ${PrinterStatusType.paper} ${newRespondedCommand.priority} ${newRespondedCommand.bytes.toHex()}.. RESPONDED dec=${response}, hex=${response.toRadixString(16).padLeft(2, '0')}, status=${profile.paperStatus.name}');
          } else {
            profile.paperStatus = PrinterHwStatus.unknown;
          }
        }
      }

      // Error Check
      if (profile.errorCommand != null && profile.isCoverNormal && profile.isPaperNormal) {
        debugPrint(
            '${printerKey} (queryPrinterStatus) _queryUsingProfile -> _getStatusResponse errorstate ${profile
                .errorCommand!.priority} ${profile.errorCommand!.bytes.toHex()}..');
        await Future.delayed(const Duration(milliseconds: 30)); // let buffer settle
        final response = await _getValidatedStatusResponse(socket, responseStream.stream, profile.errorCommand!.bytes);
        if (response != null) {
          profile.errorLastBytes = response;
          profile.errorStatus = _decodeStatusResponse(profile.errorCommand!, response);
          debugPrint(
              '${printerKey} (queryPrinterStatus) _queryUsingProfile -> _getStatusResponse errorstate ${profile
                  .errorCommand!.priority} ${profile.errorCommand!.bytes
                  .toHex()}.. RESPONDED dec=${response}, hex=${response.toRadixString(16).padLeft(
                  2, '0')}, status=${profile.errorStatus.name}');
        } else {
          // Previous command not working anymore, likely the printer model is changed or current printer status is different (i.e: normal -> paper out)
          final (newRespondedCommand, response) = await _reDiscoverPrinterProfile(
              socket, responseStream, printerKey, type: PrinterStatusType.error, currentCommand: profile.errorCommand!);
          if (newRespondedCommand != null && response != null) {
            profile.errorLastBytes = response;
            profile.errorStatus = _decodeStatusResponse(newRespondedCommand, response);
            profile.errorCommand = newRespondedCommand;
            debugPrint(
                '${printerKey} (queryPrinterStatus) _reDiscoverPrinterProfile -> _getStatusResponse ${PrinterStatusType.error} ${newRespondedCommand.priority} ${newRespondedCommand.bytes.toHex()}.. RESPONDED dec=${response}, hex=${response.toRadixString(16).padLeft(2, '0')}, status=${profile.errorStatus.name}');
          } else {
            profile.errorStatus = PrinterHwStatus.unknown;
          }
        }
      }
    } catch (e) {
      debugPrint('(queryPrinterStatus) _queryUsingProfile Err $e');
    } finally {
      await sub.cancel();
      await responseStream.close();
    }

    _updateResponsiveness(profile);
    profile.lastQueried = DateTime.now();
    _queryResultCache[printerKey] = profile;

    return profile;
  }

  static Future<(PrinterStatusCommand?, int?)> _reDiscoverPrinterProfile(
      Socket socket, StreamController<int> responseStream, String printerKey,
      {required PrinterStatusType type, required PrinterStatusCommand currentCommand}) async {
    final candidates = _probeCommands.where((c) => c.statusType == type && c.priority != currentCommand.priority).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    if (candidates.isNotEmpty) {
      await Future.delayed(const Duration(milliseconds: 30)); // let buffer settle from previous not responded cached command
    }
    for (final command in candidates) {
      debugPrint(
          '${printerKey} (queryPrinterStatus) _reDiscoverPrinterProfile -> _getStatusResponse ${type.name} ${command
              .priority} ${command.bytes.toHex()}..');
      final response = await _getValidatedStatusResponse(socket, responseStream.stream, command.bytes);
      await Future.delayed(const Duration(milliseconds: 30)); // let buffer settle
      if (response != null) {
        return (command, response);
      }
    }
    return (null, null);
  }

  /// Real-time status reply bytes (DLE EOT n, n=1..4) carry vendor-fixed bits
  /// per the ESC/POS spec, constant across all four sub-commands: bit0=0,
  /// bit1=1, bit4=0, bit7=0. A byte that violates this is not a genuine
  /// status reply — most likely a stray byte still sitting in the socket's
  /// receive buffer from a previous send (see RC-1/RC-2 buffer-overflow /
  /// socket-reuse corruption) — and must not be decoded as real hardware
  /// status, or a corrupted byte could be misread as "printer ready".
  static bool _isDleEotCommand(List<int> command) =>
      listEquals(command, dleEot1) ||
      listEquals(command, dleEot2) ||
      listEquals(command, dleEot3) ||
      listEquals(command, dleEot4);

  static bool _isGenuineResponse(List<int> command, int response) {
    if (!_isDleEotCommand(command)) return true; // no fixed-bit spec to check
    return (response & 0x01) == 0x00 &&
        (response & 0x02) == 0x02 &&
        (response & 0x10) == 0x00 &&
        (response & 0x80) == 0x00;
  }

  /// Wraps [_getStatusResponse], discarding replies that fail the fixed-bit
  /// check so callers never treat a non-genuine byte as a real status.
  static Future<int?> _getValidatedStatusResponse(
      Socket socket, Stream<int> byteStream, List<int> command) async {
    final response = await _getStatusResponse(socket, byteStream, command);
    if (response == null) return null;
    if (!_isGenuineResponse(command, response)) {
      debugPrint(
          '(queryPrinterStatus) discarded non-genuine reply for ${command.toHex()}: '
          '0x${response.toRadixString(16).padLeft(2, '0')} (fixed-bit check failed)');
      return null;
    }
    return response;
  }

  static Future<int?> _getStatusResponse(Socket socket, Stream<int> byteStream, List<int> command) async {
    final completer = Completer<int?>();
    StreamSubscription<int>? sub;
    Timer? timeout;

    void stopListeningResponse([int? response]) {
      if (completer.isCompleted) return;
      debugPrint(
          '(queryPrinterStatus) finish - CMD: ${command.toHex()} | RESPONSE: dec=$response, hex=${response?.toRadixString(16).padLeft(2, '0')}');
      completer.complete(response);
      sub?.cancel();
      timeout?.cancel();
    }

    try {
      sub = byteStream.listen(
        (byte) => stopListeningResponse(byte),
        onError: (_) => stopListeningResponse(),
        onDone: () => stopListeningResponse(),
        cancelOnError: true,
      );
      timeout = Timer(const Duration(milliseconds: 300), () => stopListeningResponse());
      socket.add(command);
      await socket.flush();
    } catch (e) {
      debugPrint('(queryPrinterStatus) _getStatusResponse Err $e');
      stopListeningResponse();
    }

    return completer.future;
  }

  static PrinterHwStatus _decodeStatusResponse(PrinterStatusCommand command, int response) {
    switch (command.statusType) {
      case PrinterStatusType.paper:
        if (listEquals(command.bytes, dleEot4)) {
          // Bits 5,6: paper end sensor — On = paper not present
          if ((response & 0x60) != 0) return PrinterHwStatus.paperOut;
          // Standard ESC/POS Paper Low bitmask (0x0C checks both Bit 3 and Bit 4)
          // bool isPaperLow = (response & 0x0C) != 0;
          return PrinterHwStatus.ready;
        }
        if (listEquals(command.bytes, gsR1) || listEquals(command.bytes, gsR49)) {
          // Bits 2,3: paper roll near-end sensor (On = near end, not fully out)
          // True paper-out takes the printer offline; treat near-end as a warning
          if ((response & 0x0C) != 0) return PrinterHwStatus.paperOut;
          return PrinterHwStatus.ready;
        }
        if (listEquals(command.bytes, escV)) {
          // Bit 2 On (0x04) → paper end (hard out)
          // Bit 0 On (0x01) → paper near end — treat as warning, not full block
          if ((response & 0x04) != 0) return PrinterHwStatus.paperOut;
          if ((response & 0x01) != 0) return PrinterHwStatus.paperOut;
          return PrinterHwStatus.ready;
        }
        return PrinterHwStatus.unknown;

      case PrinterStatusType.cover:
        if (listEquals(command.bytes, dleEot2)) {
          // Bit 2: Cover Status (0 = Closed, 1 = Open)
          if ((response & 0x04) != 0) return PrinterHwStatus.coverOpen;
          // Bit 3: FEED Button Status (0 = Not pressed, 1 = Pressed)
          // Indicates the physical button on the housing is actively being held down.
          if ((response & 0x08) != 0) return PrinterHwStatus.feedBtnPressed;
          // Bit 5: Printing Stop Status (0 = Normal, 1 = Stopped)
          // Triggered when the printer halts execution because a sensor lacks paper.
          if ((response & 0x20) != 0) return PrinterHwStatus.error;
          // Bit 6: Error Status (0 = No error, 1 = Error occurred)
          // Active during cutter jams, thermal overheating, or board faults.
          if ((response & 0x40) != 0) return PrinterHwStatus.error; // Checks Bit 6
          return PrinterHwStatus.ready;
        }
        return PrinterHwStatus.unknown;

      case PrinterStatusType.error:
        if (listEquals(command.bytes, dleEot3)) {
          // Unrecoverable or auto-cutter errors are blocking
          if ((response & 0x20) != 0) return PrinterHwStatus.error; // unrecoverable
          if ((response & 0x08) != 0) return PrinterHwStatus.error; // auto-cutter
          if ((response & 0x40) != 0) return PrinterHwStatus.error; // auto-recoverable
          return PrinterHwStatus.ready;
        }
        return PrinterHwStatus.unknown;
    }
  }

  /// GS I 1 (transmit printer ID) — used ONLY as an in-order completion
  /// barrier, never for hardware-status decoding.
  static const List<int> _completionBarrierCommand = [0x1D, 0x49, 0x01];

  /// In-order completion barrier: unlike DLE EOT (a REAL-TIME command the
  /// printer answers immediately, jumping ahead of anything still queued —
  /// which is why it can report "online" mid-print and proves nothing about
  /// completion), GS I is processed IN BUFFER ORDER. Its reply can only
  /// arrive after the printer has physically consumed everything queued
  /// ahead of it in this call — including the receipt's own cut command.
  /// So a reply here is a genuine physical-completion signal, for printers
  /// that support it.
  ///
  /// Returns true if the printer answered within [timeout] (physically
  /// caught up); false on timeout or any socket error, in which case the
  /// caller should fall back to the open-loop drain estimate — this makes
  /// enabling the barrier safe even for hardware that never replies
  /// (status-less RONGTA-class printers): worst case it costs [timeout] of
  /// extra latency once, it never blocks forever and never reports a false
  /// completion.
  static Future<bool> awaitInOrderCompletion(
    Socket socket,
    Stream<Uint8List> byteStream, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final completer = Completer<bool>();
    StreamSubscription<Uint8List>? sub;
    Timer? timer;

    void finish(bool result) {
      if (completer.isCompleted) return;
      completer.complete(result);
      sub?.cancel();
      timer?.cancel();
    }

    sub = byteStream.listen(
      (data) => finish(data.isNotEmpty),
      onError: (_) => finish(false),
      onDone: () => finish(false),
      cancelOnError: true,
    );
    timer = Timer(timeout, () => finish(false));

    try {
      socket.add(Uint8List.fromList(_completionBarrierCommand));
      await socket.flush();
    } catch (e) {
      debugPrint('(awaitInOrderCompletion) send failed: $e');
      finish(false);
    }

    return completer.future;
  }
}

enum PrinterStatusType { cover, paper, error }

class PrinterStatusCommand {
  final PrinterStatusType statusType;
  final List<int> bytes;
  final int priority;
  final bool canBlockPrint;

  const PrinterStatusCommand({required this.statusType, required this.bytes, required this.priority, required this.canBlockPrint});
}

class PrinterQueryResult {
  PrinterStatusCommand? coverCommand;
  PrinterHwStatus coverStatus;
  int? coverLastBytes;

  PrinterStatusCommand? paperCommand;
  PrinterHwStatus paperStatus;
  int? paperLastBytes;

  PrinterStatusCommand? errorCommand;
  PrinterHwStatus errorStatus;
  int? errorLastBytes;

  /// Timestamp of last successful query — used for TTL check
  DateTime? lastQueried;

  /// True once this printer key has EVER produced a genuine response to any
  /// status command, across the life of this cached profile. Distinguishes
  /// hardware that is genuinely status-less (no ASB / DLE EOT support —
  /// RONGTA-style, where all-unknown is normal and assume-ready is correct)
  /// from a printer that used to answer and has gone silent (offline,
  /// unplugged, wedged buffer — a real fault [[RC-4]]).
  bool hasEverResponded = false;

  /// Consecutive query rounds with zero genuine responses across cover/
  /// paper/error. Anti-flap: one missed poll (a transient blip) must not
  /// flip a healthy, previously-responsive printer to [PrinterHwStatus.notResponding].
  int consecutiveMisses = 0;

  /// Number of consecutive silent rounds required, for a printer that has
  /// responded before, before [hwCondition] reports [PrinterHwStatus.notResponding].
  static const int consecutiveMissThreshold = 2;

  PrinterQueryResult({
    this.coverCommand,
    this.coverStatus = PrinterHwStatus.unknown,
    this.paperCommand,
    this.paperStatus = PrinterHwStatus.unknown,
    this.errorCommand,
    this.errorStatus = PrinterHwStatus.unknown,
    this.lastQueried,
  });

  PrinterHwStatus get hwCondition {
    // By priority order -> cover, paper, error state
    if (coverStatus != PrinterHwStatus.unknown) return coverStatus;
    if (paperStatus != PrinterHwStatus.unknown) return paperStatus;
    if (errorStatus != PrinterHwStatus.unknown) return errorStatus;

    // All three unknown this round. A printer that has never once answered a
    // status command has nothing to compare against — assume-ready is the
    // only sane default for status-less hardware.
    if (!hasEverResponded) return PrinterHwStatus.ready;

    // This printer HAS answered before, so all-unknown now means it stopped
    // responding rather than never supporting status — but require a couple
    // of consecutive misses first so a single dropped poll doesn't flip a
    // healthy printer into a false fault (which would abort/retry a receipt
    // that actually printed fine).
    if (consecutiveMisses >= consecutiveMissThreshold) return PrinterHwStatus.notResponding;
    return PrinterHwStatus.ready;
  }

  bool get isCoverNormal =>
      coverStatus != PrinterHwStatus.coverOpen &&
      coverStatus != PrinterHwStatus.feedBtnPressed &&
      coverStatus != PrinterHwStatus.error;

  bool get isPaperNormal => paperStatus != PrinterHwStatus.paperOut;

  bool get isStateNormal => errorStatus != PrinterHwStatus.error;

  @override
  String toString() =>
      'PrinterQueryResult(paperCommand=${paperCommand?.priority}, paperStatus=${paperStatus.name}, paperLastBytes=${paperLastBytes}, coverCommand=${coverCommand?.priority}, coverStatus=${coverStatus.name}, coverLastBytes=${coverLastBytes}, errorCommand=${errorCommand?.priority}, errorStatus=${errorStatus.name}, errorLastBytes=${errorLastBytes}, hasEverResponded=$hasEverResponded, consecutiveMisses=$consecutiveMisses, lastQueried=${lastQueried})';
}

extension on List<int> {
  String toHex() {
    return map((b) => '\\x${b.toRadixString(16).padLeft(2, '0')}').join('');
  }
}
