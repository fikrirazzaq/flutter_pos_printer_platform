// Regression test for the DLE EOT fixed-bit polarity bug: a printer
// answering the canonical all-OK byte (0x12) to DLE EOT n was discarded as
// "non-genuine" by `_isGenuineResponse`, which made every printer's status
// permanently unlearnable for cover/error (DLE-EOT-only) and, combined with
// a paper-out printer going silent on the buffered GS r / ESC v fallbacks,
// reported `notResponding` even for a printer that had just answered
// correctly. See printer_status_checker.dart's `_isGenuineResponse`.
//
// Exercises the real public API (`queryPrinterStatus`) end-to-end over a
// loopback TCP socket rather than the private validator directly, since
// Dart's per-file privacy makes `_isGenuineResponse` unreachable from a
// separate test file.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pos_printer_platform/printer.dart';
import 'package:flutter_pos_printer_platform/src/helpers/printer_status_checker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Starts a loopback TCP server that replies with [reply] to every byte
/// sequence it receives, mimicking a printer that answers every DLE EOT n
/// status probe with the same status byte.
Future<(ServerSocket, Socket)> _connectedLoopback(List<int> reply) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((client) {
    client.listen((_) => client.add(Uint8List.fromList(reply)));
  });
  final client = await Socket.connect(server.address, server.port);
  return (server, client);
}

void main() {
  group('PrinterStatusChecker.queryPrinterStatus (DLE EOT fixed-bit check)', () {
    test('accepts the canonical all-OK reply (0x12) and reports ready', () async {
      final (server, client) = await _connectedLoopback([0x12]);
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final result = await PrinterStatusChecker.queryPrinterStatus(
        client,
        client.asBroadcastStream(),
        'loopback-test:${server.port}',
        cacheTtl: 0,
      );

      // Before the fix, _isGenuineResponse rejected 0x12 for every DLE EOT
      // command (bit4 polarity inverted), leaving cover/error un-probeable
      // (DLE-EOT-only) and hwCondition reporting notResponding.
      expect(result.coverCommand, isNotNull, reason: 'cover status is DLE-EOT-only and must be learnable');
      expect(result.errorCommand, isNotNull, reason: 'error status is DLE-EOT-only and must be learnable');
      expect(result.coverStatus, PrinterHwStatus.ready);
      expect(result.paperStatus, PrinterHwStatus.ready);
      expect(result.errorStatus, PrinterHwStatus.ready);
      expect(result.hwCondition, PrinterHwStatus.ready);
      expect(result.hasEverResponded, isTrue);
    });

    test('still rejects a spec-violating byte as non-genuine', () async {
      // 0x00: fails the fixed bit1=1 requirement common to every DLE EOT
      // reply — must still be discarded so a corrupted/stray receive-buffer
      // byte is never decoded as real hardware status.
      final (server, client) = await _connectedLoopback([0x00]);
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final result = await PrinterStatusChecker.queryPrinterStatus(
        client,
        client.asBroadcastStream(),
        'loopback-test:${server.port}',
        cacheTtl: 0,
      );

      // Cover and error only have DLE EOT probes, so a spec-violating byte
      // must leave them un-learnable. Paper has a non-DLE-EOT fallback
      // (GS r 1), which has no fixed-bit spec to check and is expected to
      // still be accepted.
      expect(result.coverCommand, isNull);
      expect(result.errorCommand, isNull);
    });
  });
}
