/*
 * esc_pos_utils
 * Created by Andrey U.
 * 
 * Copyright (c) 2019-2020. All rights reserved.
 * See LICENSE for distribution and usage details.
 */

import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_pos_printer_platform/src/ext.dart';
import 'package:image/image.dart' as img;
import 'package:gbk_codec/gbk_codec.dart';
import "package:hex/hex.dart";
import '../esc_pos_utils_platform.dart';
import 'commands.dart';
import 'mixed_text_processor.dart';

class Generator {
  Generator(this._paperSize, this._profile, {this.spaceBetweenRows = 5});

  // Ticket config
  final PaperSize _paperSize;
  CapabilityProfile _profile;
  int? _maxCharsPerLine;

  // Global styles
  String? _codeTable;
  PosFontType? _font;

  // Current styles
  PosStyles _styles = const PosStyles();
  int spaceBetweenRows;

  // ************************ Internal helpers ************************
  int _getMaxCharsPerLine(PosFontType? font) {
    if (_paperSize == PaperSize.mm58) {
      return (font == null || font == PosFontType.fontA) ? 32 : 42;
    } else if (_paperSize == PaperSize.mm80) {
      return (font == null || font == PosFontType.fontA) ? 42 : 56;
    } else {
      return (font == null || font == PosFontType.fontA) ? 48 : 64;
    }
  }

  // charWidth = default width * text size multiplier
  double _getCharWidth(PosStyles styles, {int? maxCharsPerLine}) {
    int charsPerLine = _getCharsPerLine(styles, maxCharsPerLine);
    double charWidth = (_paperSize.width / charsPerLine) * styles.width.value;
    return charWidth;
  }

  double _colIndToPosition(int colInd) {
    final int width = _paperSize.width;
    return colInd == 0 ? 0 : (width * colInd / 12 - 1);
  }

  int _getCharsPerLine(PosStyles styles, int? maxCharsPerLine) {
    int charsPerLine;
    if (maxCharsPerLine != null) {
      charsPerLine = maxCharsPerLine;
    } else {
      if (styles.fontType != null) {
        charsPerLine = _getMaxCharsPerLine(styles.fontType);
      } else {
        charsPerLine = _maxCharsPerLine ?? _getMaxCharsPerLine(_styles.fontType);
      }
    }
    return charsPerLine;
  }

  Uint8List _encode(String text, {bool isKanji = false}) {
    // replace some non-ascii characters
    text = text
        .replaceAll("'", "'")
        .replaceAll("´", "'")
        .replaceAll("»", '"')
        .replaceAll(" ", ' ')
        .replaceAll("•", '.')
        .replaceNonAscii();

    if (!isKanji) {
      text = text.replaceNonPrintable(replaceWith: '');
      return latin1.encode(text);
    } else {
      // For Chinese characters, use GBK encoding (maybe required for Epson printers)
      try {
        return Uint8List.fromList(gbk_bytes.encode(text));
      } catch (e) {
        // Fallback to UTF-8 if GBK encoding fails (for Rongta compatibility)
        return utf8.encode(text);
      }
    }
  }

  List _getLexemes(String text, {bool containsChinese = false}) {
    String textCleaned = text.replaceNonAscii();
    if (!containsChinese) {
      textCleaned = textCleaned.replaceNonPrintable(replaceWith: '');
    }
    final List<String> lexemes = List.empty(growable: true);
    final List<bool> isLexemeChinese = List.empty(growable: true);
    int start = 0;
    int end = 0;
    bool curLexemeChinese = _isChinese(textCleaned[0]);
    for (var i = 1; i < textCleaned.length; ++i) {
      if (curLexemeChinese == _isChinese(textCleaned[i])) {
        end += 1;
      } else {
        lexemes.add(textCleaned.substring(start, end + 1));
        isLexemeChinese.add(curLexemeChinese);
        start = i;
        end = i;
        curLexemeChinese = !curLexemeChinese;
      }
    }
    lexemes.add(textCleaned.substring(start, end + 1));
    isLexemeChinese.add(curLexemeChinese);

    return <dynamic>[lexemes, isLexemeChinese];
  }

  /// Break text into chinese/non-chinese lexemes
  bool _isChinese(String ch) {
    return ch.codeUnitAt(0) > 255;
  }

  /// Generate multiple bytes for a number: In lower and higher parts, or more parts as needed.
  ///
  /// [value] Input number
  /// [bytesNb] The number of bytes to output (1 - 4)
  List<int> _intLowHigh(int value, int bytesNb) {
    final dynamic maxInput = 256 << (bytesNb * 8) - 1;

    if (bytesNb < 1 || bytesNb > 4) {
      throw Exception('Can only output 1-4 bytes');
    }
    if (value < 0 || value > maxInput) {
      throw Exception('Number is too large. Can only output up to $maxInput in $bytesNb bytes');
    }

    final List<int> res = <int>[];
    int buf = value;
    for (int i = 0; i < bytesNb; ++i) {
      res.add(buf % 256);
      buf = buf ~/ 256;
    }
    return res;
  }

  /// Extract slices of an image as equal-sized blobs of column-format data.
  ///
  /// [image] img.Image to extract from
  /// [lineHeight] Printed line height in dots
  List<List<int>> _toColumnFormat(img.Image imgSrc, int lineHeight) {
    final img.Image image = img.Image.from(imgSrc); // make a copy

    // Determine new width: closest integer that is divisible by lineHeight
    final int widthPx = (image.width + lineHeight) - (image.width % lineHeight);
    final int heightPx = image.height;

    // Create a black bottom layer
    final biggerImage = img.copyResize(image, width: widthPx, height: heightPx);
    img.fill(biggerImage, 0);
    // Insert source image into bigger one
    img.drawImage(biggerImage, image, dstX: 0, dstY: 0);

    int left = 0;
    final List<List<int>> blobs = List.empty(growable: true);

    while (left < widthPx) {
      final img.Image slice = img.copyCrop(biggerImage, left, 0, lineHeight, heightPx);
      final Uint8List bytes = slice.getBytes(format: img.Format.luminance);
      blobs.add(bytes);
      left += lineHeight;
    }

    return blobs;
  }

  /// img.Image rasterization
  List<int> _toRasterFormat(img.Image imgSrc) {
    final img.Image image = img.Image.from(imgSrc); // make a copy
    final int widthPx = image.width;
    final int heightPx = image.height;

    img.grayscale(image);
    img.invert(image);

    // R/G/B channels are same -> keep only one channel
    final List<int> oneChannelBytes = List.empty(growable: true);
    final List<int> buffer = image.getBytes(format: img.Format.rgba);
    for (int i = 0; i < buffer.length; i += 4) {
      oneChannelBytes.add(buffer[i]);
    }

    // Add some empty pixels at the end of each line (to make the width divisible by 8)
    if (widthPx % 8 != 0) {
      final targetWidth = (widthPx + 8) - (widthPx % 8);
      final missingPx = targetWidth - widthPx;
      final extra = Uint8List(missingPx);
      for (int i = 0; i < heightPx; i++) {
        final pos = (i * widthPx + widthPx) + i * missingPx;
        oneChannelBytes.insertAll(pos, extra);
      }
    }

    // Pack bits into bytes
    return _packBitsIntoBytes(oneChannelBytes);
  }

  /// Merges each 8 values (bits) into one byte
  List<int> _packBitsIntoBytes(List<int> bytes) {
    const pxPerLine = 8;
    final List<int> res = <int>[];
    const threshold = 127; // set the greyscale -> b/w threshold here
    for (int i = 0; i < bytes.length; i += pxPerLine) {
      int newVal = 0;
      for (int j = 0; j < pxPerLine; j++) {
        newVal = _transformUint32Bool(
          newVal,
          pxPerLine - j,
          bytes[i + j] > threshold,
        );
      }
      res.add(newVal ~/ 2);
    }
    return res;
  }

  /// Replaces a single bit in a 32-bit unsigned integer.
  int _transformUint32Bool(int uint32, int shift, bool newValue) {
    return ((0xFFFFFFFF ^ (0x1 << shift)) & uint32) | ((newValue ? 1 : 0) << shift);
  }

  // ************************ (end) Internal helpers  ************************

  //**************************** Public command generators ************************
  /// Clear the buffer and reset text styles
  List<int> reset() {
    List<int> bytes = List.empty(growable: true);
    bytes += cInit.codeUnits;
    _styles = const PosStyles();
    bytes += setGlobalCodeTable(_codeTable);
    bytes += setGlobalFont(_font);
    return bytes;
  }

  /// Set global code table which will be used instead of the default printer's code table
  /// (even after resetting)
  List<int> setGlobalCodeTable(String? codeTable) {
    List<int> bytes = List.empty(growable: true);
    _codeTable = codeTable;
    if (codeTable != null) {
      bytes += Uint8List.fromList(
        List.from(cCodeTable.codeUnits)..add(_profile.getCodePageId(codeTable)),
      );
      _styles = _styles.copyWith(codeTable: codeTable);
    }
    return bytes;
  }

  /// Set global font which will be used instead of the default printer's font
  /// (even after resetting)
  List<int> setGlobalFont(PosFontType? font, {int? maxCharsPerLine}) {
    List<int> bytes = List.empty(growable: true);
    _font = font;
    if (font != null) {
      _maxCharsPerLine = maxCharsPerLine ?? _getMaxCharsPerLine(font);
      bytes += font == PosFontType.fontB ? cFontB.codeUnits : cFontA.codeUnits;
      _styles = _styles.copyWith(fontType: font);
    }
    return bytes;
  }

  List<int> setStyles(PosStyles styles, {bool isKanji = false, int chineseModeAttempt = 1}) {
    List<int> bytes = List.empty(growable: true);

    if (styles.align != _styles.align) {
      bytes += latin1.encode(
          styles.align == PosAlign.left ? cAlignLeft : (styles.align == PosAlign.center ? cAlignCenter : cAlignRight));
      _styles = _styles.copyWith(align: styles.align);
    }

    if (styles.bold != _styles.bold) {
      bytes += styles.bold ? cBoldOn.codeUnits : cBoldOff.codeUnits;
      _styles = _styles.copyWith(bold: styles.bold);
    }

    if (styles.turn90 != _styles.turn90) {
      bytes += styles.turn90 ? cTurn90On.codeUnits : cTurn90Off.codeUnits;
      _styles = _styles.copyWith(turn90: styles.turn90);
    }

    if (styles.reverse != _styles.reverse) {
      bytes += styles.reverse ? cReverseOn.codeUnits : cReverseOff.codeUnits;
      _styles = _styles.copyWith(reverse: styles.reverse);
    }

    if (styles.underline != _styles.underline) {
      bytes += styles.underline ? cUnderline1dot.codeUnits : cUnderlineOff.codeUnits;
      _styles = _styles.copyWith(underline: styles.underline);
    }

    // Set font
    if (styles.fontType != null && styles.fontType != _styles.fontType) {
      bytes += styles.fontType == PosFontType.fontB ? cFontB.codeUnits : cFontA.codeUnits;
      _styles = _styles.copyWith(fontType: styles.fontType);
    } else if (_font != null && _font != _styles.fontType) {
      bytes += _font == PosFontType.fontB ? cFontB.codeUnits : cFontA.codeUnits;
      _styles = _styles.copyWith(fontType: _font);
    }

    // Characters size
    if (styles.height.value != _styles.height.value || styles.width.value != _styles.width.value) {
      bytes += Uint8List.fromList(
        List.from(cSizeGSn.codeUnits)..add(PosTextSize.decSize(styles.height, styles.width)),
      );
      _styles = _styles.copyWith(height: styles.height, width: styles.width);
    }

    // Universal Chinese mode activation - try different methods based on attempt
    if (isKanji) {
      bytes += _activateChineseMode(enable: true, attempt: chineseModeAttempt);
    } else {
      bytes += _activateChineseMode(enable: false, attempt: chineseModeAttempt);
    }

    // Set local code table
    if (styles.codeTable != null) {
      bytes += Uint8List.fromList(
        List.from(cCodeTable.codeUnits)..add(_profile.getCodePageId(styles.codeTable)),
      );
      _styles = _styles.copyWith(align: styles.align, codeTable: styles.codeTable);
    } else if (_codeTable != null) {
      bytes += Uint8List.fromList(
        List.from(cCodeTable.codeUnits)..add(_profile.getCodePageId(_codeTable)),
      );
      _styles = _styles.copyWith(align: styles.align, codeTable: _codeTable);
    }

    return bytes;
  }

  /// Sens raw command(s)
  List<int> rawBytes(List<int> cmd, {bool isKanji = false}) {
    List<int> bytes = List.empty(growable: true);
    if (!isKanji) {
      bytes += cKanjiOff.codeUnits;
    }
    bytes += Uint8List.fromList(cmd);
    return bytes;
  }

  List<int> text(
    String text, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    bool containsChinese = false,
    int? maxCharsPerLine,
  }) {
    List<int> bytes = List.empty(growable: true);

    if (!containsChinese) {
      bytes += _text(
        _encode(text, isKanji: containsChinese),
        styles: styles,
        isKanji: containsChinese,
        maxCharsPerLine: maxCharsPerLine,
      );
      // Ensure at least one line break after the text
      bytes += emptyLines(linesAfter + 1);
    } else {
      bytes += _mixedKanji(
        text,
        styles: styles,
        linesAfter: linesAfter,
      );
    }
    return bytes;
  }

  /// Skips [n] lines
  ///
  /// Similar to [feed] but uses an alternative command
  List<int> emptyLines(int n) {
    List<int> bytes = List.empty(growable: true);
    if (n > 0) {
      bytes += List.filled(n, '\n').join().codeUnits;
    }
    return bytes;
  }

  /// Skips [n] lines
  ///
  /// Similar to [emptyLines] but uses an alternative command
  List<int> feed(int n) {
    List<int> bytes = List.empty(growable: true);
    if (n >= 0 && n <= 255) {
      bytes += Uint8List.fromList(
        List.from(cFeedN.codeUnits)..add(n),
      );
    }
    return bytes;
  }

  /// Cut the paper
  ///
  /// [mode] is used to define the full or partial cut (if supported by the priner)
  List<int> cut({PosCutMode mode = PosCutMode.full}) {
    List<int> bytes = List.empty(growable: true);
    bytes += emptyLines(5);
    if (mode == PosCutMode.partial) {
      bytes += cCutPart.codeUnits;
    } else {
      bytes += cCutFull.codeUnits;
    }
    return bytes;
  }

  /// Print selected code table.
  ///
  /// If [codeTable] is null, global code table is used.
  /// If global code table is null, default printer code table is used.
  List<int> printCodeTable({String? codeTable}) {
    List<int> bytes = List.empty(growable: true);
    bytes += cKanjiOff.codeUnits;

    if (codeTable != null) {
      bytes += Uint8List.fromList(
        List.from(cCodeTable.codeUnits)..add(_profile.getCodePageId(codeTable)),
      );
    }

    bytes += Uint8List.fromList(List<int>.generate(256, (i) => i));

    // Back to initial code table
    setGlobalCodeTable(_codeTable);
    return bytes;
  }

  /// Beeps [n] times
  ///
  /// Beep [duration] could be between 50 and 450 ms.
  List<int> beep({int n = 3, PosBeepDuration duration = PosBeepDuration.beep450ms}) {
    List<int> bytes = List.empty(growable: true);
    if (n <= 0) {
      return [];
    }

    int beepCount = n;
    if (beepCount > 9) {
      beepCount = 9;
    }

    bytes += Uint8List.fromList(
      List.from(cBeep.codeUnits)..addAll([beepCount, duration.value]),
    );

    beep(n: n - 9, duration: duration);
    return bytes;
  }

  /// Reverse feed for [n] lines (if supported by the priner)
  List<int> reverseFeed(int n) {
    List<int> bytes = List.empty(growable: true);
    bytes += Uint8List.fromList(
      List.from(cReverseFeedN.codeUnits)..add(n),
    );
    return bytes;
  }

  /// Print a row.
  ///
  /// A row contains up to 12 columns. A column has a width between 1 and 12.
  /// Total width of columns in one row must be equal 12.
  List<int> row(List<PosColumn> cols) {
    List<int> bytes = List.empty(growable: true);
    final isSumValid = cols.fold(0, (int sum, col) => sum + col.width) == 12;
    if (!isSumValid) {
      // throw Exception('Total columns width must be equal to 12');
    }
    bool isNextRow = false;
    List<PosColumn> nextRow = <PosColumn>[];

    for (int i = 0; i < cols.length; ++i) {
      int colInd = cols.sublist(0, i).fold(0, (int sum, col) => sum + col.width);
      double charWidth = _getCharWidth(cols[i].styles);
      double fromPos = _colIndToPosition(colInd);
      final double toPos = _colIndToPosition(colInd + cols[i].width) - spaceBetweenRows;
      int maxCharactersNb = ((toPos - fromPos) / charWidth).floor();

      if (!cols[i].containsChinese) {
        // CASE 1: containsChinese = false
        Uint8List encodedToPrint = cols[i].textEncoded != null ? cols[i].textEncoded! : _encode(cols[i].text);

        // If the col's content is too long, split it to the next row
        int realCharactersNb = encodedToPrint.length;
        if (realCharactersNb > maxCharactersNb) {
          // Print max possible and split to the next row
          Uint8List encodedToPrintNextRow = encodedToPrint.sublist(maxCharactersNb);
          encodedToPrint = encodedToPrint.sublist(0, maxCharactersNb);
          isNextRow = true;
          nextRow.add(PosColumn(textEncoded: encodedToPrintNextRow, width: cols[i].width, styles: cols[i].styles));
        } else {
          // Insert an empty col
          nextRow.add(PosColumn(text: '', width: cols[i].width, styles: cols[i].styles));
        }
        // end rows splitting
        bytes += _text(
          encodedToPrint,
          styles: cols[i].styles,
          colInd: colInd,
          colWidth: cols[i].width,
        );
      } else {
        // CASE 1: containsChinese = true
        // Split text into multiple lines if it too long
        String text = cols[i].text.replaceNonAscii().replaceNonPrintable(replaceWith: '');
        int counter = 0;
        int splitPos = 0;
        for (int p = 0; p < text.length; ++p) {
          final int w = _isChinese(text[p]) ? 2 : 1;
          if (counter + w >= maxCharactersNb) {
            break;
          }
          counter += w;
          splitPos += 1;
        }
        String toPrintNextRow = text.substring(splitPos);
        String toPrint = text.substring(0, splitPos);

        if (toPrintNextRow.isNotEmpty) {
          isNextRow = true;
          nextRow.add(
              PosColumn(text: toPrintNextRow, containsChinese: true, width: cols[i].width, styles: cols[i].styles));
        } else {
          // Insert an empty col
          nextRow.add(PosColumn(text: '', width: cols[i].width, styles: cols[i].styles));
        }

        // Print current row
        final list = _getLexemes(toPrint);
        final List<String> lexemes = list[0];
        final List<bool> isLexemeChinese = list[1];

        // Print each lexeme using codetable OR kanji
        for (var j = 0; j < lexemes.length; ++j) {
          bytes += _text(
            _encode(lexemes[j], isKanji: isLexemeChinese[j]),
            styles: cols[i].styles,
            colInd: colInd,
            colWidth: cols[i].width,
            isKanji: isLexemeChinese[j],
          );
          // Define the absolute position only once (we print one line only)
          // colInd = null;
        }
      }
    }

    bytes += emptyLines(1);

    if (isNextRow) {
      row(nextRow);
    }
    return bytes;
  }

  /// Print an image using (ESC *) command
  ///
  /// [image] is an instanse of class from [Image library](https://pub.dev/packages/image)
  List<int> image(img.Image imgSrc, {PosAlign align = PosAlign.center}) {
    List<int> bytes = List.empty(growable: true);
    // img.Image alignment
    bytes += setStyles(const PosStyles().copyWith(align: align));

    final img.Image image = img.Image.from(imgSrc); // make a copy
    const bool highDensityHorizontal = true;
    const bool highDensityVertical = true;

    img.invert(image);
    img.flip(image, img.Flip.horizontal);
    final img.Image imageRotated = img.copyRotate(image, 270);

    const int lineHeight = highDensityVertical ? 3 : 1;
    final List<List<int>> blobs = _toColumnFormat(imageRotated, lineHeight * 8);

    // Compress according to line density
    // Line height contains 8 or 24 pixels of src image
    // Each blobs[i] contains greyscale bytes [0-255]
    // const int pxPerLine = 24 ~/ lineHeight;
    for (int blobInd = 0; blobInd < blobs.length; blobInd++) {
      blobs[blobInd] = _packBitsIntoBytes(blobs[blobInd]);
    }

    final int heightPx = imageRotated.height;
    const int densityByte = (highDensityHorizontal ? 1 : 0) + (highDensityVertical ? 32 : 0);

    final List<int> header = List.from(cBitImg.codeUnits);
    header.add(densityByte);
    header.addAll(_intLowHigh(heightPx, 2));

    // Adjust line spacing (for 16-unit line feeds): ESC 3 0x10 (HEX: 0x1b 0x33 0x10)
    bytes += [27, 51, 16];
    for (int i = 0; i < blobs.length; ++i) {
      bytes += List.from(header)
        ..addAll(blobs[i])
        ..addAll('\n'.codeUnits);
    }
    // Reset line spacing: ESC 2 (HEX: 0x1b 0x32)
    bytes += [27, 50];
    return bytes;
  }

  /// Print an image using (GS v 0) obsolete command
  ///
  /// [image] is an instanse of class from [Image library](https://pub.dev/packages/image)
  List<int> imageRaster(
    img.Image image, {
    PosAlign align = PosAlign.center,
    bool highDensityHorizontal = true,
    bool highDensityVertical = true,
    PosImageFn imageFn = PosImageFn.bitImageRaster,
  }) {
    List<int> bytes = List.empty(growable: true);
    // img.Image alignment
    bytes += setStyles(const PosStyles().copyWith(align: align));

    final int widthPx = image.width;
    final int heightPx = image.height;
    final int widthBytes = (widthPx + 7) ~/ 8;
    final List<int> resterizedData = _toRasterFormat(image);

    if (imageFn == PosImageFn.bitImageRaster) {
      // GS v 0
      final int densityByte = (highDensityVertical ? 0 : 1) + (highDensityHorizontal ? 0 : 2);

      final List<int> header = List.from(cRasterImg2.codeUnits);
      header.add(densityByte); // m
      header.addAll(_intLowHigh(widthBytes, 2)); // xL xH
      header.addAll(_intLowHigh(heightPx, 2)); // yL yH
      bytes += List.from(header)..addAll(resterizedData);
    } else if (imageFn == PosImageFn.graphics) {
      // 'GS ( L' - FN_112 (Image data)
      final List<int> header1 = List.from(cRasterImg.codeUnits);
      header1.addAll(_intLowHigh(widthBytes * heightPx + 10, 2)); // pL pH
      header1.addAll([48, 112, 48]); // m=48, fn=112, a=48
      header1.addAll([1, 1]); // bx=1, by=1
      header1.addAll([49]); // c=49
      header1.addAll(_intLowHigh(widthBytes, 2)); // xL xH
      header1.addAll(_intLowHigh(heightPx, 2)); // yL yH
      bytes += List.from(header1)..addAll(resterizedData);

      // 'GS ( L' - FN_50 (Run print)
      final List<int> header2 = List.from(cRasterImg.codeUnits);
      header2.addAll([2, 0]); // pL pH
      header2.addAll([48, 50]); // m fn[2,50]
      bytes += List.from(header2);
    }
    return bytes;
  }

  /// Print a QR Code
  List<int> qrcode(
    String text, {
    PosAlign align = PosAlign.center,
    QRSize size = QRSize.Size4,
    QRCorrection cor = QRCorrection.L,
  }) {
    List<int> bytes = List.empty(growable: true);
    // Set alignment
    bytes += setStyles(const PosStyles().copyWith(align: align));
    QRCode qr = QRCode(text, size, cor);
    bytes += qr.bytes;
    return bytes;
  }

  /// Open cash drawer
  List<int> drawer({PosDrawer pin = PosDrawer.pin2}) {
    List<int> bytes = List.empty(growable: true);
    if (pin == PosDrawer.pin2) {
      bytes += cCashDrawerPin2.codeUnits;
    } else {
      bytes += cCashDrawerPin5.codeUnits;
    }
    return bytes;
  }

  /// Print horizontal full width separator
  /// If [len] is null, then it will be defined according to the paper width
  List<int> hr({String ch = '-', int? len, int linesAfter = 0}) {
    List<int> bytes = List.empty(growable: true);
    int n = len ?? _maxCharsPerLine ?? _getMaxCharsPerLine(_styles.fontType);
    String ch1 = ch.length == 1 ? ch : ch[0];
    bytes += setStyles(const PosStyles(
      align: PosAlign.center,
      height: PosTextSize.size1,
      width: PosTextSize.size1,
    ));
    bytes += text(List.filled(n, ch1).join(), linesAfter: linesAfter);
    return bytes;
  }

  List<int> textEncoded(
    Uint8List textBytes, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    int? maxCharsPerLine,
  }) {
    List<int> bytes = List.empty(growable: true);
    bytes += _text(textBytes, styles: styles, maxCharsPerLine: maxCharsPerLine);
    // Ensure at least one line break after the text
    bytes += emptyLines(linesAfter + 1);
    return bytes;
  }

  // ************************ (end) Public command generators ************************

  // ************************ (end) Internal command generators ************************
  /// Generic print for internal use
  ///
  /// [colInd] range: 0..11. If null: do not define the position
  List<int> _text(
    Uint8List textBytes, {
    PosStyles styles = const PosStyles(),
    int? colInd = 0,
    bool isKanji = false,
    int colWidth = 12,
    int? maxCharsPerLine,
    int chineseModeAttempt = 1,
  }) {
    List<int> bytes = List.empty(growable: true);

    if (colInd != null) {
      double charWidth = _getCharWidth(styles, maxCharsPerLine: maxCharsPerLine);
      double fromPos = _colIndToPosition(colInd);

      // Align
      if (colWidth != 12) {
        final double toPos = _colIndToPosition(colInd + colWidth) - spaceBetweenRows;
        final double textLen = textBytes.length * charWidth;

        if (styles.align == PosAlign.right) {
          fromPos = toPos - textLen;
        } else if (styles.align == PosAlign.center) {
          fromPos = fromPos + (toPos - fromPos) / 2 - textLen / 2;
        }
        if (fromPos < 0) {
          fromPos = 0;
        }
      }

      final hexStr = fromPos.round().toRadixString(16).padLeft(3, '0');
      final hexPair = HEX.decode(hexStr);

      // Position
      bytes += Uint8List.fromList(
        List.from(cPos.codeUnits)..addAll([hexPair[1], hexPair[0]]),
      );
    }

    bytes += setStyles(styles, isKanji: isKanji, chineseModeAttempt: chineseModeAttempt);
    bytes += textBytes;
    return bytes;
  }

  /// Prints one line of styled mixed (chinese and latin symbols) text
  List<int> _mixedKanji(
    String text, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    int? maxCharsPerLine,
    int chineseModeAttempt = 1,
    int encodingAttempt = 1,
  }) {
    List<int> bytes = List.empty(growable: true);

    // Use the enhanced lexeme analysis for better mixed text support
    final list = MixedTextProcessor.getLexemesAdvanced(text);
    final List<String> lexemes = list[0];
    final List<String> lexemeTypes = list[1];

    // Print each lexeme using appropriate encoding and mode
    int? colInd = 0;
    for (var i = 0; i < lexemes.length; ++i) {
      String lexeme = lexemes[i];
      String type = lexemeTypes[i];

      // Determine if this lexeme is Asian (Chinese/Japanese/Korean)
      bool isAsianLexeme = ['chinese', 'japanese', 'korean'].contains(type);

      // Encode based on character type with fallback options
      Uint8List encodedText;
      if (isAsianLexeme) {
        // Use advanced encoding for Asian characters
        encodedText = MixedTextEncoder.encodeByType(lexeme, type, encodingAttempt: encodingAttempt);
      } else {
        // Use standard encoding for Latin characters
        encodedText = _encode(lexeme, isKanji: false);
      }

      bytes += _text(
        encodedText,
        styles: styles,
        colInd: colInd,
        isKanji: isAsianLexeme,
        maxCharsPerLine: maxCharsPerLine,
        chineseModeAttempt: chineseModeAttempt,
      );

      // Define the absolute position only once (we print one line only)
      colInd = null;
    }

    bytes += emptyLines(linesAfter + 1);
    return bytes;
  }

  List<int> textMixed(
    String text, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    int? maxCharsPerLine,
    int? chineseModeAttempt,
    int? encodingAttempt,
  }) {
    // Auto-detect if text contains Asian characters
    bool containsAsian = text.split('').any((char) => MixedTextProcessor.isAsianCharacter(char));

    if (!containsAsian) {
      // Pure Latin text - use standard encoding
      List<int> bytes = List.empty(growable: true);
      bytes += _text(
        _encode(text, isKanji: false),
        styles: styles,
        isKanji: false,
        maxCharsPerLine: maxCharsPerLine,
        chineseModeAttempt: chineseModeAttempt ?? 1,
      );
      bytes += emptyLines(linesAfter + 1);
      return bytes;
    } else {
      // Mixed or Asian text - use advanced processing
      return _mixedTextAdvanced(
        text,
        styles: styles,
        linesAfter: linesAfter,
        maxCharsPerLine: maxCharsPerLine,
        chineseModeAttempt: chineseModeAttempt ?? 1,
        encodingAttempt: encodingAttempt ?? 1,
      );
    }
  }

  List<int> _mixedTextAdvanced(
    String text, {
    PosStyles styles = const PosStyles(),
    int linesAfter = 0,
    int? maxCharsPerLine,
    int chineseModeAttempt = 1,
    int encodingAttempt = 1,
  }) {
    List<int> bytes = List.empty(growable: true);

    // Parse text into lexemes with type information
    final analysis = MixedTextProcessor.getLexemesAdvanced(text);
    final List<String> lexemes = analysis[0];
    final List<String> lexemeTypes = analysis[1];

    int? colInd = 0;

    for (int i = 0; i < lexemes.length; i++) {
      String lexeme = lexemes[i];
      String type = lexemeTypes[i];

      bool isAsianLexeme = ['chinese', 'japanese', 'korean'].contains(type);

      // Encode based on character type
      Uint8List encodedText = MixedTextEncoder.encodeByType(lexeme, type, encodingAttempt: encodingAttempt);

      // Print with appropriate mode
      bytes += _text(
        encodedText,
        styles: styles,
        colInd: colInd,
        isKanji: isAsianLexeme,
        maxCharsPerLine: maxCharsPerLine,
        chineseModeAttempt: chineseModeAttempt,
      );

      // Only set position once per line
      colInd = null;
    }

    bytes += emptyLines(linesAfter + 1);
    return bytes;
  }

  List<int> _activateChineseMode({required bool enable, int attempt = 1}) {
    List<int> bytes = [];

    if (enable) {
      switch (attempt) {
        case 1: // Standard ESC/POS approach (works for most printers)
          bytes += ChineseCommands.epsonChineseModeOn.codeUnits; // FS &
          bytes += ChineseCommands.epsonChineseFontA.codeUnits; // FS C 0
          break;
        case 2: // Alternative Kanji mode
          bytes += ChineseCommands.kanjiModeOn.codeUnits;
          break;
        case 3: // Code page approach
          bytes += Uint8List.fromList(
            List.from(cCodeTable.codeUnits)..add(ChineseCommands.chineseCodePage255),
          );
          break;
        case 4: // Alternative command set
          bytes += ChineseCommands.altChineseModeOn.codeUnits;
          break;
        default: // Minimal approach
          bytes += ChineseCommands.kanjiModeOn.codeUnits;
      }
    } else {
      switch (attempt) {
        case 1:
          bytes += ChineseCommands.epsonChineseModeOff.codeUnits;
          break;
        case 2:
          bytes += ChineseCommands.kanjiModeOff.codeUnits;
          break;
        case 3:
          // Reset to default code page
          bytes += Uint8List.fromList(
            List.from(cCodeTable.codeUnits)..add(0), // CP437
          );
          break;
        case 4:
          bytes += ChineseCommands.altChineseModeOff.codeUnits;
          break;
        default:
          bytes += ChineseCommands.kanjiModeOff.codeUnits;
      }
    }

    return bytes;
  }
// ************************ (end) Internal command generators ************************
}
