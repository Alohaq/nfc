import 'dart:typed_data';

/// LZO1X-compatible literal-only encoder.
///
/// This is a byte-for-byte port of `literal_lzo()` from
/// solar2ain/ink-nfc-fmsc-by-pn532 `src/ink_nfc_fmsc/protocol.py`.
///
/// The panel's D3 path expects an LZO1X stream (not raw bytes). A stream made
/// purely of literals is valid LZO1X and the reference project supports it as
/// `--compression literal`, so we do not need a match finder here. The cost is
/// roughly +0.6% on incompressible data and no size win on flat areas; the
/// benefit is a tiny, verifiable amount of code on the phone side.
class LzoLiteral {
  /// LZO1X literal-run length limit for one block, matching `BLOCK_BYTES`.
  static const int maxBlockBytes = 2000;

  /// Largest literal run the short form can encode (17 + 238).
  static const int shortFormLimit = 238;

  /// Encodes [raw] as a literal-only LZO1X stream.
  ///
  /// Rejects empty input and anything longer than [maxBlockBytes], exactly like
  /// the reference implementation.
  static Uint8List compress(Uint8List raw) {
    if (raw.isEmpty || raw.length > maxBlockBytes) {
      throw ArgumentError.value(
          raw.length, 'raw', 'LZO block size must be 1..$maxBlockBytes');
    }
    final out = BytesBuilder(copy: false);
    if (raw.length <= shortFormLimit) {
      out.addByte(17 + raw.length);
    } else {
      out.addByte(0);
      var rest = raw.length - 18;
      while (rest > 255) {
        out.addByte(0);
        rest -= 255;
      }
      out.addByte(rest);
    }
    out.add(raw);
    // M2/M3 end-of-stream marker.
    out.add(const [0x11, 0x00, 0x00]);
    return out.toBytes();
  }

  /// Splits [raw] into 2000-byte blocks and compresses each independently,
  /// mirroring `build_transfer_plan()` / `image_packets()`.
  static List<Uint8List> compressBlocks(Uint8List raw) {
    if (raw.isEmpty) return const [];
    final blocks = <Uint8List>[];
    for (var off = 0; off < raw.length; off += maxBlockBytes) {
      final end = (off + maxBlockBytes < raw.length) ? off + maxBlockBytes : raw.length;
      blocks.add(compress(Uint8List.sublistView(raw, off, end)));
    }
    return blocks;
  }
}
