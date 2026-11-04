import 'dart:typed_data';

/// Hex helpers used by the protocol layer and the log view.
class Hex {
  static String of(List<int> bytes, {String sep = ' '}) {
    final b = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      if (i > 0) b.write(sep);
      b.write(bytes[i].toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return b.toString();
  }

  static String sw(int hi, int lo) =>
      '${hi.toRadixString(16).padLeft(2, '0')}${lo.toRadixString(16).padLeft(2, '0')}'
          .toUpperCase();

  /// Parses "F0 D4 94 80 00", "f0d4948000" or "F0-D4" into bytes.
  /// Throws [FormatException] on odd length or non-hex characters.
  static Uint8List parse(String input) {
    final cleaned = input.replaceAll(RegExp(r'[\s,:\-]'), '');
    if (cleaned.isEmpty) return Uint8List(0);
    if (cleaned.length.isOdd) {
      throw const FormatException('hex length must be even');
    }
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(cleaned)) {
      throw const FormatException('contains non-hex characters');
    }
    final out = Uint8List(cleaned.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String str(Uint8List b) => String.fromCharCodes(b);
}
