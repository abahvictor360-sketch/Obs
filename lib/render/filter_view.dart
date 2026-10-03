import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/models.dart';

/// Compiled filter shaders. Loaded once at startup; key and sharpen filters
/// pass the source through unchanged where shaders can't run (devices
/// without Impeller, the web build, tests).
class FilterShaders {
  FilterShaders._();

  static ui.FragmentProgram? _key, _sharpen;

  static bool get supported => _key != null && _sharpen != null && ui.ImageFilter.isShaderFilterSupported;

  static Future<void> load() async {
    try {
      if (!ui.ImageFilter.isShaderFilterSupported) return;
      _key = await ui.FragmentProgram.fromAsset('shaders/key.frag');
      _sharpen = await ui.FragmentProgram.fromAsset('shaders/sharpen.frag');
    } catch (e) {
      debugPrint('Filter shaders unavailable: $e');
    }
  }

  static ui.ImageFilter? key(SourceFilter f) {
    final p = _key;
    if (p == null || !supported) return null;
    final sh = p.fragmentShader();
    final k = f.keyRgb;
    final mode = switch (f.kind) {
      FilterKind.chromaKey => 0.0,
      FilterKind.colorKey => 1.0,
      _ => 2.0,
    };
    final values = <double>[
      0, 0, // uSize (set by the engine)
      mode,
      k[0], k[1], k[2],
      f.dbl('similarity', 400) / 1000,
      f.dbl('smoothness', 80) / 1000,
      f.dbl('spill', 100) / 1000,
      f.dbl('opacity', 1),
      f.dbl('lumaMin'), f.dbl('lumaMinSmooth'), f.dbl('lumaMax', 1), f.dbl('lumaMaxSmooth'),
    ];
    for (var i = 0; i < values.length; i++) {
      sh.setFloat(i, values[i]);
    }
    return ui.ImageFilter.shader(sh);
  }

  static ui.ImageFilter? sharpen(SourceFilter f) {
    final p = _sharpen;
    if (p == null || !supported) return null;
    final sh = p.fragmentShader()
      ..setFloat(0, 0)
      ..setFloat(1, 0)
      ..setFloat(2, f.dbl('amount', 0.08));
    return ui.ImageFilter.shader(sh);
  }
}

/// Applies a source's filter chain to its rendered content.
Widget applySourceFilters(Source source, Widget child) {
  for (final f in source.filters) {
    if (!f.enabled || f.kind.isAudio) continue;
    child = switch (f.kind) {
      FilterKind.colorCorrection => ColorFiltered(colorFilter: ColorFilter.matrix(f.colorMatrix()), child: child),
      FilterKind.chromaKey || FilterKind.colorKey || FilterKind.lumaKey => _shader(FilterShaders.key(f), child),
      FilterKind.sharpen => _shader(FilterShaders.sharpen(f), child),
      FilterKind.blur => ClipRect(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: f.dbl('radius', 8) / 2,
              sigmaY: f.dbl('radius', 8) / 2,
              tileMode: TileMode.decal,
            ),
            child: child,
          ),
        ),
      FilterKind.scroll => ScrollFilterView(
          speedX: f.dbl('speedX'),
          speedY: f.dbl('speedY'),
          loop: f.settings['loop'] as bool? ?? true,
          child: child,
        ),
      FilterKind.mask => f.settings['shape'] == 'circle'
          ? ClipOval(child: child)
          : LayoutBuilder(
              builder: (context, box) => ClipRRect(
                borderRadius: BorderRadius.circular(f.dbl('radius', 0.1) * box.biggest.shortestSide),
                child: child,
              ),
            ),
      FilterKind.gain => child,
    };
  }
  return child;
}

Widget _shader(ui.ImageFilter? filter, Widget child) =>
    filter == null ? child : ImageFiltered(imageFilter: filter, child: child);

/// Scroll filter: moves the content continuously, wrapping around (tickers,
/// crawls, moving backgrounds).
class ScrollFilterView extends StatefulWidget {
  const ScrollFilterView({super.key, required this.speedX, required this.speedY, required this.loop, required this.child});

  final double speedX, speedY;
  final bool loop;
  final Widget child;

  @override
  State<ScrollFilterView> createState() => _ScrollFilterViewState();
}

class _ScrollFilterViewState extends State<ScrollFilterView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((d) => setState(() => _elapsed = d));
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(ScrollFilterView old) {
    super.didUpdateWidget(old);
    _update();
  }

  void _update() {
    final moving = widget.speedX != 0 || widget.speedY != 0;
    if (moving && !_ticker.isActive) _ticker.start();
    if (!moving && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.speedX == 0 && widget.speedY == 0) return widget.child;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final t = _elapsed.inMicroseconds / 1e6;
      var dx = -widget.speedX * t, dy = -widget.speedY * t;
      if (widget.loop) {
        dx = w > 0 ? dx % w : 0;
        dy = h > 0 ? dy % h : 0;
      }
      Widget at(double x, double y) => Positioned(left: x, top: y, width: w, height: h, child: widget.child);
      return ClipRect(
        child: Stack(children: [
          at(dx, dy),
          if (widget.loop) ...[
            if (dx != 0) at(dx - w, dy),
            if (dy != 0) at(dx, dy - h),
            if (dx != 0 && dy != 0) at(dx - w, dy - h),
          ],
        ]),
      );
    });
  }
}
