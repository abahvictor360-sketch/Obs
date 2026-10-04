import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/render/lut.dart';

/// Identity LUT of [n] in .cube text (red changes fastest).
String identityCube(int n, {String extra = ''}) {
  final b = StringBuffer('TITLE "id"\n# comment\nLUT_3D_SIZE $n\n$extra');
  for (var bl = 0; bl < n; bl++) {
    for (var g = 0; g < n; g++) {
      for (var r = 0; r < n; r++) {
        b.writeln('${r / (n - 1)} ${g / (n - 1)} ${bl / (n - 1)}');
      }
    }
  }
  return b.toString();
}

List<int> px(LutStrip s, int x, int y) {
  final o = (y * s.width + x) * 4;
  return s.rgba.sublist(o, o + 4);
}

void main() {
  test('.cube becomes a strip: tile = blue, x = red, y = green', () {
    final s = LutStrip.parseCube(identityCube(3));
    expect((s.size, s.width, s.height), (3, 9, 3));
    // r=2, g=1, b=1 -> x = 1*3 + 2, y = 1
    expect(px(s, 5, 1), [255, 128, 128, 255]);
    expect(px(s, 0, 0), [0, 0, 0, 255]);
    expect(px(s, 8, 2), [255, 255, 255, 255]);
  });

  test('.cube domain is normalised; 1D and broken files are rejected', () {
    final s = LutStrip.parseCube(
        'LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n${List.filled(8, '2 1 0').join('\n')}');
    expect(px(s, 0, 0), [255, 128, 0, 255]);
    expect(() => LutStrip.parseCube('LUT_1D_SIZE 4\n0 0 0'), throwsFormatException);
    expect(() => LutStrip.parseCube('LUT_3D_SIZE 4\n0 0 0'), throwsFormatException);
  });

  test('OBS square PNG layout is rearranged into a strip', () {
    // 4³ = 64 = 8×8 image: 2×2 tiles of 4×4. Encode (r, g, b) as pixel value.
    const n = 4, w = 8;
    final img = Uint8List(w * w * 4);
    for (var b = 0; b < n; b++) {
      final tx = (b % 2) * n, ty = (b ~/ 2) * n;
      for (var g = 0; g < n; g++) {
        for (var r = 0; r < n; r++) {
          final o = ((ty + g) * w + tx + r) * 4;
          img.setAll(o, [r * 10, g * 10, b * 10, 255]);
        }
      }
    }
    final s = LutStrip.fromImage(img, w, w);
    expect((s.size, s.width, s.height), (4, 16, 4));
    expect(px(s, 3 * 4 + 1, 2), [10, 20, 30, 255]); // b=3, r=1, g=2
    // A strip image is used as is; anything else is not a LUT.
    expect(LutStrip.fromImage(s.rgba, 16, 4).rgba, s.rgba);
    expect(() => LutStrip.fromImage(Uint8List(10 * 7 * 4), 10, 7), throwsFormatException);
  });
}
