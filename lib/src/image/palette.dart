/// One palette entry: an RGB triple plus its 2-bit code.
class PaletteColor {
  const PaletteColor(this.code, this.r, this.g, this.b, this.label);
  final int code;
  final int r;
  final int g;
  final int b;
  final String label;

  int get argb => (0xFF << 24) | (r << 16) | (g << 8) | b;
}

/// Panel palette, taken from `PALETTE` in huawei-epd-pn532/image_codec.py.
class Palette {
  static const PaletteColor black = PaletteColor(0, 0, 0, 0, 'Black');
  static const PaletteColor white = PaletteColor(1, 255, 255, 255, 'White');
  static const PaletteColor yellow = PaletteColor(2, 245, 205, 0, 'Yellow');
  static const PaletteColor red = PaletteColor(3, 200, 0, 0, 'Red');

  static const List<PaletteColor> fourColor = [black, white, yellow, red];
  static const List<PaletteColor> mono = [black, white];

  /// Palette order matters: it is the index written into the 2-bit code stream.
  static List<PaletteColor> of({required bool blackWhite}) =>
      blackWhite ? mono : fourColor;
}
