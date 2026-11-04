import 'dart:typed_data';

import 'palette.dart';

/// Colour quantisation and error-diffusion dithering for the 2-bit panel.
///
/// The Atkinson routine is a line-by-line port of `atkinson_codes()` from
/// huawei-epd-pn532/image_codec.py, which that project describes as a recovery
/// of the vendor app's integer diffusion. Being a per-pixel inner loop it takes
/// roughly 0.1-0.3 s for one 552x768 frame on a phone, which is fine here.
class Quantizer {
  /// Nearest-palette colour, no dithering.
  static Uint8List nearest(Uint8List rgb, List<PaletteColor> palette) {
    _checkRgb(rgb);
    final codes = Uint8List(FrameGeometry.pixels);
    final count = palette.length;
    for (var i = 0; i < codes.length; i++) {
      final o = i * 3;
      var best = 0;
      var bestDistance = 1 << 30;
      for (var k = 0; k < count; k++) {
        final c = palette[k];
        final dr = rgb[o] - c.r;
        final dg = rgb[o + 1] - c.g;
        final db = rgb[o + 2] - c.b;
        final d = dr * dr + dg * dg + db * db;
        if (d < bestDistance) {
          best = k;
          bestDistance = d;
        }
      }
      codes[i] = best;
    }
    return codes;
  }

  /// Atkinson diffusion: 1/8 of the error to six neighbours.
  ///
  /// The source deliberately has no `x > 0` guard on the lower-left neighbour,
  /// so at x==0 the error lands on the last pixel of the *current* row. That
  /// quirk is reproduced here on purpose so output matches the reference tool
  /// byte for byte.
  static Uint8List atkinson(Uint8List rgb, List<PaletteColor> palette) {
    _checkRgb(rgb);
    const width = FrameGeometry.width;
    const height = FrameGeometry.height;
    final pixels = Uint8List.fromList(rgb);
    final codes = Uint8List(width * height);
    final count = palette.length;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final o = i * 3;
        final r = pixels[o];
        final g = pixels[o + 1];
        final b = pixels[o + 2];
        var best = 0;
        var bestDistance = 1 << 30;
        for (var k = 0; k < count; k++) {
          final c = palette[k];
          final dr = r - c.r;
          final dg = g - c.g;
          final db = b - c.b;
          final d = dr * dr + dg * dg + db * db;
          if (d < bestDistance) {
            best = k;
            bestDistance = d;
          }
        }
        codes[i] = best;
        final pc = palette[best];
        final dr = r - pc.r;
        final dg = g - pc.g;
        final db = b - pc.b;
        final ar = (dr.abs() ~/ 8) * (dr >= 0 ? 1 : -1);
        final ag = (dg.abs() ~/ 8) * (dg >= 0 ? 1 : -1);
        final ab = (db.abs() ~/ 8) * (db >= 0 ? 1 : -1);
        if (ar == 0 && ag == 0 && ab == 0) continue;

        // (x+1, y)
        if (x + 1 < width) _spread(pixels, i + 1, ar, ag, ab);
        // (x+2, y)
        if (x + 2 < width) _spread(pixels, i + 2, ar, ag, ab);
        if (y + 1 < height) {
          // (x-1, y+1) -- intentionally unguarded
          _spread(pixels, i + width - 1, ar, ag, ab);
          // (x, y+1)
          _spread(pixels, i + width, ar, ag, ab);
          // (x+1, y+1)
          if (x + 1 < width) _spread(pixels, i + width + 1, ar, ag, ab);
        }
        // (x, y+2)
        if (y + 2 < height) _spread(pixels, i + 2 * width, ar, ag, ab);
      }
    }
    return codes;
  }

  /// Floyd-Steinberg: 7/16, 3/16, 5/16, 1/16 of the error.
  static Uint8List floydSteinberg(Uint8List rgb, List<PaletteColor> palette) {
    _checkRgb(rgb);
    const width = FrameGeometry.width;
    const height = FrameGeometry.height;
    final pixels = Uint8List.fromList(rgb);
    final codes = Uint8List(width * height);
    final count = palette.length;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final o = i * 3;
        final r = pixels[o];
        final g = pixels[o + 1];
        final b = pixels[o + 2];
        var best = 0;
        var bestDistance = 1 << 30;
        for (var k = 0; k < count; k++) {
          final c = palette[k];
          final dr = r - c.r;
          final dg = g - c.g;
          final db = b - c.b;
          final d = dr * dr + dg * dg + db * db;
          if (d < bestDistance) {
            best = k;
            bestDistance = d;
          }
        }
        codes[i] = best;
        final pc = palette[best];
        final er = r - pc.r;
        final eg = g - pc.g;
        final eb = b - pc.b;
        _fsSpread(pixels, width, height, x + 1, y, er * 7 ~/ 16, eg * 7 ~/ 16, eb * 7 ~/ 16);
        _fsSpread(pixels, width, height, x - 1, y + 1, er * 3 ~/ 16, eg * 3 ~/ 16, eb * 3 ~/ 16);
        _fsSpread(pixels, width, height, x, y + 1, er * 5 ~/ 16, eg * 5 ~/ 16, eb * 5 ~/ 16);
        _fsSpread(pixels, width, height, x + 1, y + 1, er ~/ 16, eg ~/ 16, eb ~/ 16);
      }
    }
    return codes;
  }

  static void _spread(Uint8List pixels, int pixelIndex, int dr, int dg, int db) {
    final o = pixelIndex * 3;
    final r = pixels[o] + dr;
    final g = pixels[o + 1] + dg;
    final b = pixels[o + 2] + db;
    pixels[o] = r < 0 ? 0 : (r > 255 ? 255 : r);
    pixels[o + 1] = g < 0 ? 0 : (g > 255 ? 255 : g);
    pixels[o + 2] = b < 0 ? 0 : (b > 255 ? 255 : b);
  }

  static void _fsSpread(Uint8List pixels, int width, int height, int x, int y,
      int dr, int dg, int db) {
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    if (dr == 0 && dg == 0 && db == 0) return;
    _spread(pixels, y * width + x, dr, dg, db);
  }

  static void _checkRgb(Uint8List rgb) {
    if (rgb.length != FrameGeometry.pixels * 3) {
      throw ArgumentError.value(rgb.length, 'rgb',
          'expected ${FrameGeometry.pixels * 3} bytes');
    }
  }
}

/// Fixed geometry of the panel this pipeline targets.
class FrameGeometry {
  static const int width = 552;
  static const int height = 768;
  static const int pixels = width * height;

  /// 2 bits per pixel.
  static const int packedBytes = pixels * 2 ~/ 8;
}

/// Packs 2-bit colour codes into the panel's wire frame.
///
/// Direct port of `pack_codes()` from image_codec.py:
///   for x in range(width-1, -1, -1):
///     for y in range(height-1, -1, -4):
///       byte = sum(codes[(y-i)*width+x] << (6-2i) for i in range(4))
///
/// Columns are emitted right-to-left; within a column, groups of four pixels
/// are emitted bottom-to-top with the lowest pixel in the two highest bits.
Uint8List pack2bpp(Uint8List codes) {
  if (codes.length != FrameGeometry.pixels) {
    throw ArgumentError.value(
        codes.length, 'codes', 'expected ${FrameGeometry.pixels} codes');
  }
  const width = FrameGeometry.width;
  const height = FrameGeometry.height;
  final out = Uint8List(FrameGeometry.packedBytes);
  var p = 0;
  for (var x = width - 1; x >= 0; x--) {
    for (var y = height - 1; y >= 0; y -= 4) {
      var v = 0;
      for (var i = 0; i < 4; i++) {
        final c = codes[(y - i) * width + x];
        if (c > 3) {
          throw ArgumentError.value(c, 'codes', 'colour code out of range');
        }
        v |= c << (6 - 2 * i);
      }
      out[p++] = v;
    }
  }
  if (p != out.length) {
    throw StateError('packed length mismatch: wrote $p of ${out.length}');
  }
  return out;
}
