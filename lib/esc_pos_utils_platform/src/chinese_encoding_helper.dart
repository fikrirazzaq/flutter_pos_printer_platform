import 'dart:convert';
import 'dart:typed_data';
import 'package:gbk_codec/gbk_codec.dart';

class ChineseEncodingHelper {
  static List<Uint8List> getEncodingOptions(String text) {
    List<Uint8List> options = [];

    try {
      // Option 1: GBK encoding (preferred for most Chinese printers)
      options.add(Uint8List.fromList(gbk_bytes.encode(text)));
    } catch (e) {
      print('GBK encoding failed: $e');
    }

    try {
      // Option 2: GB18030 encoding (extended GBK)
      // Note: You might need to add gb18030_codec package
      options.add(Uint8List.fromList(gbk_bytes.encode(text))); // Fallback to GBK
    } catch (e) {
      print('GB18030 encoding failed: $e');
    }

    try {
      // Option 3: UTF-8 encoding (for modern printers like Rongta)
      options.add(utf8.encode(text));
    } catch (e) {
      print('UTF-8 encoding failed: $e');
    }

    try {
      // Option 4: Big5 encoding (for Traditional Chinese)
      // This would require a big5_codec package
      options.add(utf8.encode(text)); // Fallback to UTF-8
    } catch (e) {
      print('Big5 encoding failed: $e');
    }

    return options;
  }
}