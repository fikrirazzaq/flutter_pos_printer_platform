import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
  // DLE EOT commands — most widely supported for real-time status
  static const List<int> dleEot1 = [0x10, 0x04, 0x01]; // Printer status
  static const List<int> dleEot2 = [0x10, 0x04, 0x02]; // Offline cause status
  static const List<int> dleEot3 = [0x10, 0x04, 0x03]; // Error cause status
  static const List<int> dleEot4 = [0x10, 0x04, 0x04]; // Paper roll sensor status

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
}
