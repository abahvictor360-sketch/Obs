import 'dart:math' as math;
import 'dart:typed_data';

/// A 3D colour lookup table as a horizontal strip of [size] tiles, each
/// size×size: tile = blue, x in tile = red, y = green. RGBA8, [size]² wide,
/// [size] high. This is the layout lut.frag samples.
class LutStrip {
  LutStrip(this.size, this.rgba) : assert(rgba.length == size * size * size * 4);

  final int size;
  final Uint8List rgba;

  int get width => size * size;
  int get height => size;

  /// Parses an Adobe/Resolve `.cube` file (LUT_3D_SIZE, red changing
  /// fastest). Throws [FormatException] for 1D LUTs or broken files.
  static LutStrip parseCube(String text) {
    var size = 0;
    var dMin = [0.0, 0.0, 0.0], dMax = [1.0, 1.0, 1.0];
    final values = <double>[];
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(RegExp(r'\s+'));
      final head = parts.first.toUpperCase();
      if (head == 'LUT_3D_SIZE') {
        size = int.parse(parts[1]);
      } else if (head == 'LUT_1D_SIZE') {
        throw const FormatException('1D LUTs are not supported; export a 3D LUT (.cube)');
      } else if (head == 'DOMAIN_MIN') {
        dMin = parts.skip(1).take(3).map(double.parse).toList();
      } else if (head == 'DOMAIN_MAX') {
        dMax = parts.skip(1).take(3).map(double.parse).toList();
      } else if (head == 'TITLE' || head.startsWith('LUT_')) {
        continue;
      } else if (parts.length >= 3) {
        final r = double.tryParse(parts[0]), g = double.tryParse(parts[1]), b = double.tryParse(parts[2]);
        if (r == null || g == null || b == null) continue;
        values..add(r)..add(g)..add(b);
      }
    }
    if (size < 2 || size > 128) throw FormatException('Unsupported LUT size: $size');
    if (values.length < size * size * size * 3) {
      throw FormatException('LUT has ${values.length ~/ 3} entries, expected ${size * size * size}');
    }
    final out = Uint8List(size * size * size * 4);
    int byte(double v, int c) => (((v - dMin[c]) / (dMax[c] - dMin[c])).clamp(0.0, 1.0) * 255).round();
    var i = 0;
    for (var b = 0; b < size; b++) {
      for (var g = 0; g < size; g++) {
        for (var r = 0; r < size; r++, i += 3) {
          final o = ((g * size * size) + b * size + r) * 4;
          out[o] = byte(values[i], 0);
          out[o + 1] = byte(values[i + 1], 1);
          out[o + 2] = byte(values[i + 2], 2);
          out[o + 3] = 255;
        }
      }
    }
    return LutStrip(size, out);
  }

  /// Converts an image LUT (RGBA pixels) to a strip. Accepts the strip
  /// layout itself (width = height²) and the square layout OBS ships
  /// (e.g. 512×512 = 8×8 tiles of 64, tiles left to right, top to bottom).
  static LutStrip fromImage(Uint8List rgba, int w, int h) {
    if (w == h * h) return LutStrip(h, Uint8List.fromList(rgba));
    if (w == h) {
      final size = math.pow(w * h, 1 / 3).round();
      final tiles = size == 0 ? 0 : w ~/ size;
      if (size * size * size == w * h && tiles * size == w) {
        final out = Uint8List(size * size * size * 4);
        for (var b = 0; b < size; b++) {
          final tx = (b % tiles) * size, ty = (b ~/ tiles) * size;
          for (var g = 0; g < size; g++) {
            final src = ((ty + g) * w + tx) * 4;
            final dst = (g * size * size + b * size) * 4;
            out.setRange(dst, dst + size * 4, rgba, src);
          }
        }
        return LutStrip(size, out);
      }
    }
    throw FormatException('Not a LUT image (${w}x$h); use a .cube file or an OBS-style PNG LUT');
  }
}
