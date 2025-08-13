import 'dart:async';
import '../esc_pos_utils_platform/esc_pos_utils_platform.dart';
import '../flutter_pos_printer_platform.dart';

class UniversalChinesePrinter {
  static int _currentChineseModeAttempt = 1;
  static int _currentEncodingAttempt = 1;

  // Test if Chinese characters are printing correctly
  static Future<bool> testChinesePrinting(
      PrinterManager printerManager, PrinterType type, BasePrinterInput model) async {
    try {
      const testText = "测试"; // Simple test text
      final profile = await CapabilityProfile.load(name: 'default');
      final generator = Generator(PaperSize.mm80, profile);

      List<int> bytes = [];
      bytes += generator.reset();
      bytes += generator.textMixed(
        testText,
        chineseModeAttempt: _currentChineseModeAttempt,
        encodingAttempt: _currentEncodingAttempt,
      );

      final connectResult = await printerManager.connect(type: type, model: model);
      if (!connectResult.isSuccess) return false;

      final sendResult = await printerManager.send(type: type, bytes: bytes, model: model);
      await printerManager.disconnect(type: type);

      return sendResult.isSuccess;
    } catch (e) {
      return false;
    }
  }

  // Auto-configure Chinese printing for any printer
  static Future<Map<String, int>> autoConfigureChinesePrinting(
      PrinterManager printerManager, PrinterType type, BasePrinterInput model) async {
    // Try different combinations of encoding and mode
    for (int modeAttempt = 1; modeAttempt <= 4; modeAttempt++) {
      for (int encodingAttempt = 1; encodingAttempt <= 4; encodingAttempt++) {
        _currentChineseModeAttempt = modeAttempt;
        _currentEncodingAttempt = encodingAttempt;

        if (await testChinesePrinting(printerManager, type, model)) {
          return {
            'chineseModeAttempt': modeAttempt,
            'encodingAttempt': encodingAttempt,
          };
        }

        // Small delay between attempts
        await Future.delayed(Duration(milliseconds: 200));
      }
    }

    // Return default if nothing works
    return {'chineseModeAttempt': 1, 'encodingAttempt': 1};
  }
}
