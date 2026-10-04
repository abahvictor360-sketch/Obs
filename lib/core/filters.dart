import 'dart:math' as math;

/// Filters, like OBS's source filters: an ordered chain per source, applied
/// first to last before the item's transform.
enum FilterKind {
  colorCorrection('Color Correction'),
  applyLut('Apply LUT'),
  chromaKey('Chroma Key'),
  colorKey('Color Key'),
  lumaKey('Luma Key'),
  sharpen('Sharpen'),
  blur('Blur'),
  scroll('Scroll'),
  mask('Mask (Shape)'),

  /// Audio: volume boost/cut before the mixer fader.
  gain('Gain'),

  /// Audio (microphone): the device's own noise reduction (Android
  /// NoiseSuppressor, iPad voice processing).
  noiseSuppression('Noise Suppression'),

  /// Audio (microphone): mutes the mic below a level (breathing, room hum).
  noiseGate('Noise Gate'),

  /// Audio (microphone): evens out loud and quiet speech.
  compressor('Compressor'),

  /// Audio (microphone): keeps peaks under a ceiling (no clipping).
  limiter('Limiter');

  const FilterKind(this.label);
  final String label;

  bool get isAudio =>
      this == FilterKind.gain ||
      this == FilterKind.noiseSuppression ||
      this == FilterKind.noiseGate ||
      this == FilterKind.compressor ||
      this == FilterKind.limiter;

  /// Processed by the native microphone path, so only for Audio Input
  /// Capture (Mic/Aux) sources.
  bool get micOnly => isAudio && this != FilterKind.gain;

  /// Needs a fragment shader (Impeller): not available on every device.
  bool get usesShader =>
      this == FilterKind.chromaKey ||
      this == FilterKind.colorKey ||
      this == FilterKind.lumaKey ||
      this == FilterKind.sharpen ||
      this == FilterKind.applyLut;

  static FilterKind? fromName(String? n) => FilterKind.values.where((k) => k.name == n).firstOrNull;

  Map<String, dynamic> get defaults => switch (this) {
        FilterKind.colorCorrection => {
            'gamma': 0.0, // -1..1 (approximated with a curve on brightness)
            'contrast': 0.0, // -1..1
            'brightness': 0.0, // -1..1
            'saturation': 0.0, // -1..1
            'hue': 0.0, // degrees -180..180
            'opacity': 1.0, // 0..1
            'multiply': 0xFFFFFFFF, // ARGB tint
          },
        FilterKind.applyLut => {
            'path': '', // .cube or PNG LUT, copied into the app's storage
            'amount': 1.0, // 0..1
          },
        FilterKind.chromaKey => {
            'keyColor': 'green', // green | blue | magenta | custom
            'customColor': 0xFF00FF00,
            'similarity': 400, // 1..1000, like OBS
            'smoothness': 80, // 1..1000
            'spill': 100, // 1..1000
            'opacity': 1.0,
          },
        FilterKind.colorKey => {
            'keyColor': 'green',
            'customColor': 0xFF00FF00,
            'similarity': 80,
            'smoothness': 50,
            'opacity': 1.0,
          },
        FilterKind.lumaKey => {
            'lumaMax': 1.0,
            'lumaMaxSmooth': 0.0,
            'lumaMin': 0.0,
            'lumaMinSmooth': 0.0,
          },
        FilterKind.sharpen => {'amount': 0.08}, // 0..1
        FilterKind.blur => {'radius': 8.0}, // canvas px
        FilterKind.scroll => {
            'speedX': 0.0, // px/s, positive = left
            'speedY': 0.0,
            'loop': true,
          },
        FilterKind.mask => {
            'shape': 'rounded', // rounded | circle
            'radius': 0.1, // fraction of the shorter side
          },
        FilterKind.gain => {'db': 0.0}, // -30..30
        FilterKind.noiseSuppression => {},
        // OBS's defaults.
        FilterKind.noiseGate => {
            'closeDb': -32.0,
            'openDb': -26.0,
            'attackMs': 25.0,
            'holdMs': 200.0,
            'releaseMs': 150.0,
          },
        FilterKind.compressor => {
            'ratio': 10.0,
            'thresholdDb': -18.0,
            'attackMs': 6.0,
            'releaseMs': 60.0,
            'outputDb': 0.0,
          },
        FilterKind.limiter => {'thresholdDb': -6.0, 'releaseMs': 60.0},
      };
}

class SourceFilter {
  SourceFilter({
    required this.id,
    required this.kind,
    required this.name,
    this.enabled = true,
    Map<String, dynamic>? settings,
  }) : settings = {...kind.defaults, ...?settings};

  final String id;
  final FilterKind kind;
  String name;
  bool enabled;
  final Map<String, dynamic> settings;

  double dbl(String k, [double def = 0]) => (settings[k] as num?)?.toDouble() ?? def;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'enabled': enabled,
        'settings': settings,
      };

  static SourceFilter? fromJson(Map<String, dynamic> j) {
    final kind = FilterKind.fromName(j['kind'] as String?);
    if (kind == null) return null;
    return SourceFilter(
      id: j['id'] as String? ?? 'filter-${j.hashCode}',
      kind: kind,
      name: j['name'] as String? ?? kind.label,
      enabled: j['enabled'] as bool? ?? true,
      settings: (j['settings'] as Map?)?.cast<String, dynamic>(),
    );
  }

  SourceFilter copy() =>
      SourceFilter(id: id, kind: kind, name: name, enabled: enabled, settings: Map.of(settings));

  /// Linear gain for a Gain filter.
  double get linearGain => math.pow(10, dbl('db') / 20).toDouble();

  /// RGB (0..1) of the key color for Chroma / Color Key.
  List<double> get keyRgb {
    final argb = switch (settings['keyColor']) {
      'blue' => 0xFF0000FF,
      'magenta' => 0xFFFF00FF,
      'custom' => (settings['customColor'] as num?)?.toInt() ?? 0xFF00FF00,
      _ => 0xFF00FF00,
    };
    return [((argb >> 16) & 0xFF) / 255, ((argb >> 8) & 0xFF) / 255, (argb & 0xFF) / 255];
  }

  /// 5x4 matrix for `ColorFilter.matrix` (Color Correction).
  List<double> colorMatrix() {
    final c = dbl('contrast') + 1;
    final s = dbl('saturation') + 1;
    // Gamma is approximated as extra brightness so it stays a linear matrix.
    final b = (dbl('brightness') - dbl('gamma') * 0.25) * 255;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
    final t = (1 - c) * 128 + b;
    var m = <double>[
      c * (sr + s), c * sg, c * sb, 0, t, //
      c * sr, c * (sg + s), c * sb, 0, t, //
      c * sr, c * sg, c * (sb + s), 0, t, //
      0, 0, 0, dbl('opacity', 1), 0, //
    ];
    final hue = dbl('hue');
    if (hue != 0) m = _mul(_hueMatrix(hue * math.pi / 180), m);
    final mul = (settings['multiply'] as num?)?.toInt() ?? 0xFFFFFFFF;
    if (mul != 0xFFFFFFFF) {
      final r = ((mul >> 16) & 0xFF) / 255, g = ((mul >> 8) & 0xFF) / 255, bl = (mul & 0xFF) / 255;
      m = _mul([r, 0, 0, 0, 0, 0, g, 0, 0, 0, 0, 0, bl, 0, 0, 0, 0, 0, 1, 0], m);
    }
    return m;
  }

  static List<double> _hueMatrix(double a) {
    final cos = math.cos(a), sin = math.sin(a);
    const lr = 0.213, lg = 0.715, lb = 0.072;
    return [
      lr + cos * (1 - lr) + sin * -lr, lg + cos * -lg + sin * -lg, lb + cos * -lb + sin * (1 - lb), 0, 0, //
      lr + cos * -lr + sin * 0.143, lg + cos * (1 - lg) + sin * 0.140, lb + cos * -lb + sin * -0.283, 0, 0, //
      lr + cos * -lr + sin * -(1 - lr), lg + cos * -lg + sin * lg, lb + cos * (1 - lb) + sin * lb, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// a ∘ b for 5x4 color matrices (apply b, then a).
  static List<double> _mul(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 5; c++) {
        var v = c == 4 ? a[r * 5 + 4] : 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[r * 5 + k] * b[k * 5 + c];
        }
        out[r * 5 + c] = v;
      }
    }
    return out;
  }
}
