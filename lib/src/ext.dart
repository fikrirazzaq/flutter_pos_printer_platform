extension ReplaceNonAscii on String {
  String replaceNonAscii() {
    String cleaned = replaceAll("“", '"')
        .replaceAll("”", '"')
        .replaceAll("‘", "'")
        .replaceAll("’", "'")
        .replaceAll("‚", ",")
        .replaceAll("´", "'")
        .replaceAll("»", '"')
        .replaceAll(" ", ' ')
        .replaceAll("•", '.');
    return cleaned;
  }

  String replaceNonPrintable({String replaceWith = ' '}) {
    List<int> charCodes = <int>[];

    for (int codeUnit in codeUnits) {
      if (isPrintable(codeUnit)) {
        charCodes.add(codeUnit);
      } else {
        if (replaceWith.isNotEmpty) {
          charCodes.add(replaceWith.codeUnits[0]);
        }
      }
    }

    return String.fromCharCodes(charCodes);
  }

  /// Same shape as [replaceNonPrintable], but keeps bytes 128-255 — see
  /// [isPrintableKeepLatin1]. Used on the ESC/POS text-encode path only.
  String replaceNonPrintableKeepLatin1({String replaceWith = ''}) {
    List<int> charCodes = <int>[];

    for (int codeUnit in codeUnits) {
      if (isPrintableKeepLatin1(codeUnit)) {
        charCodes.add(codeUnit);
      } else {
        if (replaceWith.isNotEmpty) {
          charCodes.add(replaceWith.codeUnits[0]);
        }
      }
    }

    return String.fromCharCodes(charCodes);
  }
}

bool isPrintable(int codeUnit) {
  bool printable = true;

  if (codeUnit < 32) printable = false;
  if (codeUnit > 127) printable = false;

  return printable;
}

/// Like [isPrintable], but scoped to the ESC/POS text-encode path only:
/// bytes 128-255 (accented Latin letters, currency symbols, etc.) are kept
/// instead of dropped, because `latin1.encode()` (used by
/// `Generator._encode` for the non-Kanji path) handles the full 0-255 range
/// fine — the old `isPrintable` was silently DELETING those characters from
/// every receipt instead of printing them. Only codepoints beyond 255 are
/// excluded, since those can't be latin1-encoded at all (would throw).
///
/// Deliberately NOT a change to [isPrintable] itself: that helper is shared
/// by non-printing code (e.g. WebRTC data-channel label sanitization, KDS
/// item-name grouping keys) where flipping the 128-255 behavior would be an
/// unrelated, unreviewed change to those subsystems. Whether byte 128-255
/// renders as the RIGHT glyph on paper depends on the printer's active code
/// page (ESC t) matching Latin-1/CP1252 — see `ReceiptWriterNative`'s default
/// code table selection.
bool isPrintableKeepLatin1(int codeUnit) {
  if (codeUnit < 32) return false;
  if (codeUnit == 127) return false;
  if (codeUnit > 255) return false;
  return true;
}
