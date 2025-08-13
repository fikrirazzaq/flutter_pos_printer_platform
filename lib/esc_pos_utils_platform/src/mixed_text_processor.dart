import 'dart:convert';
import 'dart:typed_data';
import 'package:gbk_codec/gbk_codec.dart';
import 'chinese_encoding_helper.dart';

class MixedTextProcessor {
  // Enhanced character detection
  static bool isChinese(String ch) {
    int codeUnit = ch.codeUnitAt(0);
    return (codeUnit >= 0x4E00 && codeUnit <= 0x9FFF) || // CJK Unified Ideographs
        (codeUnit >= 0x3400 && codeUnit <= 0x4DBF) || // CJK Extension A
        (codeUnit >= 0x20000 && codeUnit <= 0x2A6DF) || // CJK Extension B
        (codeUnit >= 0x2A700 && codeUnit <= 0x2B73F) || // CJK Extension C
        (codeUnit >= 0x2B740 && codeUnit <= 0x2B81F) || // CJK Extension D
        (codeUnit >= 0x3000 && codeUnit <= 0x303F) || // CJK Symbols and Punctuation
        (codeUnit >= 0xFF00 && codeUnit <= 0xFFEF); // Halfwidth and Fullwidth Forms
  }

  static bool isJapanese(String ch) {
    int codeUnit = ch.codeUnitAt(0);
    return (codeUnit >= 0x3040 && codeUnit <= 0x309F) || // Hiragana
        (codeUnit >= 0x30A0 && codeUnit <= 0x30FF); // Katakana
  }

  static bool isKorean(String ch) {
    int codeUnit = ch.codeUnitAt(0);
    return (codeUnit >= 0xAC00 && codeUnit <= 0xD7AF) || // Hangul Syllables
        (codeUnit >= 0x1100 && codeUnit <= 0x11FF) || // Hangul Jamo
        (codeUnit >= 0x3130 && codeUnit <= 0x318F); // Hangul Compatibility Jamo
  }

  static bool isAsianCharacter(String ch) {
    return isChinese(ch) || isJapanese(ch) || isKorean(ch);
  }

  static bool isNumber(String ch) {
    return ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57; // 0-9
  }

  static bool isEnglishLetter(String ch) {
    int code = ch.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122); // A-Z, a-z
  }

  static bool isPunctuation(String ch) {
    const punctuationChars = '.,!?;:()\'"\\-\s\t\n\r';
    return punctuationChars.contains(ch);
  }

  // Enhanced lexeme analysis with more granular character classification
  static List<dynamic> getLexemesAdvanced(String text) {
    if (text.isEmpty) return [<String>[], <String>[]];

    List<String> lexemes = [];
    List<String> lexemeTypes = []; // 'latin', 'chinese', 'japanese', 'korean', 'number', 'punctuation'

    int start = 0;
    String currentType = _getCharacterType(text[0]);

    for (int i = 1; i < text.length; i++) {
      String charType = _getCharacterType(text[i]);

      // Group consecutive characters of the same type, with special rules
      if (charType != currentType || _shouldSplitHere(currentType, charType, text, i)) {
        // Add the current lexeme
        lexemes.add(text.substring(start, i));
        lexemeTypes.add(currentType);

        start = i;
        currentType = charType;
      }
    }

    // Add the last lexeme
    lexemes.add(text.substring(start));
    lexemeTypes.add(currentType);

    return [lexemes, lexemeTypes];
  }

  static String _getCharacterType(String ch) {
    if (isChinese(ch)) return 'chinese';
    if (isJapanese(ch)) return 'japanese';
    if (isKorean(ch)) return 'korean';
    if (isNumber(ch)) return 'number';
    if (isEnglishLetter(ch)) return 'latin';
    if (isPunctuation(ch)) return 'punctuation';
    return 'other';
  }

  static bool _shouldSplitHere(String currentType, String nextType, String text, int position) {
    // Special rules for better text segmentation

    // Don't split numbers and letters (e.g., "ABC123" stays together)
    if ((currentType == 'number' && nextType == 'latin') || (currentType == 'latin' && nextType == 'number')) {
      return false;
    }

    // Don't split punctuation from adjacent characters in some cases
    if (currentType == 'punctuation' || nextType == 'punctuation') {
      // Keep decimal points with numbers
      if (text[position] == '.' && position > 0 && position < text.length - 1) {
        if (isNumber(text[position - 1]) && isNumber(text[position + 1])) {
          return false;
        }
      }
    }

    return true;
  }
}

// Enhanced encoding for mixed text
class MixedTextEncoder {
  static Uint8List encodeByType(String text, String type, {int encodingAttempt = 1}) {
    // Clean text first
    text =
        text.replaceAll("'", "'").replaceAll("´", "'").replaceAll("»", '"').replaceAll(" ", ' ').replaceAll("•", '.');

    switch (type) {
      case 'chinese':
      case 'japanese':
      case 'korean':
        return _encodeAsianText(text, encodingAttempt);

      case 'latin':
      case 'number':
      case 'punctuation':
      case 'other':
      default:
        return _encodeLatin(text);
    }
  }

  static Uint8List _encodeAsianText(String text, int encodingAttempt) {
    final encodingOptions = ChineseEncodingHelper.getEncodingOptions(text);

    if (encodingAttempt <= encodingOptions.length) {
      return encodingOptions[encodingAttempt - 1];
    }

    // Fallback encodings based on attempt number
    try {
      switch (encodingAttempt) {
        case 1:
          return Uint8List.fromList(gbk_bytes.encode(text));
        case 2:
          return utf8.encode(text);
        case 3:
          // Try with GB18030 if available
          return Uint8List.fromList(gbk_bytes.encode(text));
        default:
          return utf8.encode(text);
      }
    } catch (e) {
      return utf8.encode(text);
    }
  }

  static Uint8List _encodeLatin(String text) {
    // Remove non-printable characters for Latin text (keep only ASCII 32-126)
    String cleanText = '';
    for (int i = 0; i < text.length; i++) {
      int code = text.codeUnitAt(i);
      if (code >= 32 && code <= 126) {
        cleanText += text[i];
      }
    }
    return latin1.encode(cleanText);
  }
}
