import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../epd/transfer_plan.dart';
import 'palette.dart';
import 'quantizer.dart';

enum DitherMode { atkinson, floydSteinberg, off }

extension DitherModeLabel on DitherMode {
  String get label => switch (this) {
        DitherMode.atkinson => 'Atkinson',
        DitherMode.floydSteinberg => 'Floyd–Steinberg',
        DitherMode.off => 'Off',
      };
}

/// User-facing processing knobs. Ranges mirror ImageOptions in image_codec.py.
@immutable
class ProcessOptions {
  const ProcessOptions({
    this.fit = BoxFit.contain,
    this.rotation = 0,
    this.brightness = 1.0,
    this.contrast = 1.0,
    this.dither = DitherMode.atkinson,
    this.blackWhite = false,
    this.scalePercent = 100,
  });

  final BoxFit fit;
  final int rotation;
  final double brightness;
  final double contrast;
  final DitherMode dither;
  final bool blackWhite;
  final int scalePercent;

  ProcessOptions copyWith({
    BoxFit? fit,
    int? rotation,
    double? brightness,
    double? contrast,
    DitherMode? dither,
    bool? blackWhite,
    int? scalePercent,
  }) =>
      ProcessOptions(
        fit: fit ?? this.fit,
        rotation: rotation ?? this.rotation,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        dither: dither ?? this.dither,
        blackWhite: blackWhite ?? this.blackWhite,
        scalePercent: scalePercent ?? this.scalePercent,
      );

  bool get isNeutral =>
      brightness == 1.0 &&
      contrast == 1.0 &&
      scalePercent == 100 &&
      rotation == 0 &&
      fit == BoxFit.contain &&
      !blackWhite &&
      dither == DitherMode.atkinson;
}

/// The result of processing: a preview image plus the exact wire frame.
class PreparedFrame {
  PreparedFrame({
    required this.preview,
    required this.codes,
    required this.packed,
    required this.options,
  });

  /// Downscaled RGB preview for the UI (never the full 552x768 ARGB buffer,
  /// which would be ~1.7 MB of texture per rebuild).
  final ui.Image preview;
  final Uint8List codes;
  final Uint8List packed;
  final ProcessOptions options;

  int get paletteSize => options.blackWhite ? 2 : 4;

  TransferPlan buildPlan({int slot = 0}) => TransferPlan.build(packed, slot: slot);
}

class ImageProcessor {
  /// Longest edge of the preview texture handed to the widget tree.
  static const int previewMaxEdge = 276;

  /// Runs the whole pipeline off the platform thread.
  static Future<PreparedFrame> process(ui.Image source, ProcessOptions options) async {
    final rgb = await _resampleToFrame(source, options);
    final palette = Palette.of(blackWhite: options.blackWhite);
    final codes = switch (options.dither) {
      DitherMode.atkinson => Quantizer.atkinson(rgb, palette),
      DitherMode.floydSteinberg => Quantizer.floydSteinberg(rgb, palette),
      DitherMode.off => Quantizer.nearest(rgb, palette),
    };
    final packed = pack2bpp(codes);
    final preview = await _renderPreview(codes, palette);
    return PreparedFrame(
      preview: preview,
      codes: codes,
      packed: packed,
      options: options,
    );
  }

  /// Applies rotation / fit / scale / brightness / contrast and returns the
  /// final 552x768 RGB buffer, matching prepare_image() in image_codec.py.
  static Future<Uint8List> _resampleToFrame(
      ui.Image source, ProcessOptions options) async {
    const w = FrameGeometry.width;
    const h = FrameGeometry.height;

    // 1. Rotation about the source, with expansion (Pillow rotate(expand=True)).
    final rotated = _rotate(source, options.rotation);

    // 2. Fit into the frame without distortion.
    final factor = _fitFactor(rotated, options.fit);
    // 3. User scale on top of the fitted result.
    final scale = options.scalePercent / 100.0;
    final drawW = (rotated.width * factor * scale).round().clamp(1, 1 << 20);
    final drawH = (rotated.height * factor * scale).round().clamp(1, 1 << 20);
    final dx = (w - drawW) / 2.0;
    final dy = (h - drawH) / 2.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // White letterbox, as the reference uses Image.new('RGB', .., 'white').
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
    canvas.drawImageRect(
      rotated,
      Rect.fromLTWH(0, 0, rotated.width.toDouble(), rotated.height.toDouble()),
      Rect.fromLTWH(dx, dy, drawW.toDouble(), drawH.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final fitted = await picture.toImage(w, h);
    picture.dispose();

    final data = await fitted.toByteData(format: ui.ImageByteFormat.rawRgba);
    fitted.dispose();
    if (rotated != source) rotated.dispose();
    final rgba = data!.buffer.asUint8List();

    // 4. Brightness / contrast, then drop alpha -> packed RGB.
    return _applyBrightnessContrast(rgba, options.brightness, options.contrast);
  }

  static double _fitFactor(ui.Image image, BoxFit fit) {
    const w = FrameGeometry.width;
    const h = FrameGeometry.height;
    final sx = w / image.width;
    final sy = h / image.height;
    return switch (fit) {
      BoxFit.cover => sx > sy ? sx : sy,
      // contain and anything else fall back to contain
      _ => sx < sy ? sx : sy,
    };
  }

  static ui.Image _rotate(ui.Image source, int degrees) {
    final normalized = ((degrees % 360) + 360) % 360;
    if (normalized == 0) return source;
    final swap = normalized == 90 || normalized == 270;
    final outW = swap ? source.height : source.width;
    final outH = swap ? source.width : source.height;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.translate(outW / 2.0, outH / 2.0);
    canvas.rotate(normalized * 3.1415926535897932 / 180.0);
    canvas.translate(-source.width / 2.0, -source.height / 2.0);
    canvas.drawImage(source, Offset.zero, Paint());
    final picture = recorder.endRecording();
    final image = picture.toImageSync(outW, outH);
    picture.dispose();
    return image;
  }

  /// Mirrors ImageEnhance.Brightness(...).enhance(b) then Contrast(...).enhance(c):
  /// brightness is a straight multiply, contrast pivots on mid-grey.
  static Uint8List _applyBrightnessContrast(Uint8List rgba, double b, double c) {
    final out = Uint8List(FrameGeometry.pixels * 3);
    final lut = Uint8List(256);
    for (var v = 0; v < 256; v++) {
      var x = v * b;
      // Pillow: contrast value 1.0 is neutral, 0.0 is flat grey.
      x = (x - 127.5) * c + 127.5;
      lut[v] = x < 0 ? 0 : (x > 255 ? 255 : x.round());
    }
    var o = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      // Composite alpha over white first, as prepare_image() does.
      final a = rgba[i + 3];
      if (a == 255) {
        out[o++] = lut[rgba[i]];
        out[o++] = lut[rgba[i + 1]];
        out[o++] = lut[rgba[i + 2]];
      } else {
        final af = a / 255.0;
        final r = (rgba[i] * af + 255 * (1 - af)).round();
        final g = (rgba[i + 1] * af + 255 * (1 - af)).round();
        final bl = (rgba[i + 2] * af + 255 * (1 - af)).round();
        out[o++] = lut[r < 0 ? 0 : (r > 255 ? 255 : r)];
        out[o++] = lut[g < 0 ? 0 : (g > 255 ? 255 : g)];
        out[o++] = lut[bl < 0 ? 0 : (bl > 255 ? 255 : bl)];
      }
    }
    return out;
  }

  /// Expands the code buffer back to an RGB texture, downscaled for the UI.
  static Future<ui.Image> _renderPreview(
      Uint8List codes, List<PaletteColor> palette) async {
    const w = FrameGeometry.width;
    const h = FrameGeometry.height;
    final rgba = Uint8List(w * h * 4);
    // Build a code -> ARGB lookup so the inner loop stays branch-free.
    final lut = List<int>.filled(4, 0xFFFFFFFF);
    for (final c in palette) {
      lut[c.code] = c.argb;
    }
    for (var i = 0; i < codes.length; i++) {
      final argb = lut[codes[i]];
      final o = i * 4;
      rgba[o] = (argb >> 16) & 0xFF;
      rgba[o + 1] = (argb >> 8) & 0xFF;
      rgba[o + 2] = argb & 0xFF;
      rgba[o + 3] = 0xFF;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec(
      targetWidth: previewMaxEdge,
      targetHeight: (h * previewMaxEdge / w).round(),
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }
}
