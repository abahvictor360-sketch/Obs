import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../core/models.dart';
import 'platform_media.dart';

/// Where an Image Slide Show is: which image, and how far into the
/// transition to the next one. Computed from a clock shared by every view of
/// the source (preview, program, multiview), so they all show the same slide.
class SlideShowClock {
  SlideShowClock._();

  static final Map<String, (DateTime, int)> _starts = {};
  static final Map<String, int> _manualOffset = {};

  /// Test hook: the current time.
  static DateTime Function() now = DateTime.now;

  static int _hash(Map<String, dynamic> s) =>
      Object.hash(Object.hashAll((s['paths'] as List? ?? const []).cast<Object?>()), s['random'], s['slideMs']);

  static DateTime _start(Source source) {
    final h = _hash(source.settings);
    final cur = _starts[source.id];
    if (cur != null && cur.$2 == h) return cur.$1;
    final t = now();
    _starts[source.id] = (t, h);
    _manualOffset.remove(source.id);
    return t;
  }

  /// Restart from the first image.
  static void restart(String sourceId) {
    _starts.remove(sourceId);
    _manualOffset.remove(sourceId);
  }

  /// Skip [delta] slides (next = 1, previous = -1).
  static void skip(String sourceId, int delta) => _manualOffset[sourceId] = (_manualOffset[sourceId] ?? 0) + delta;

  /// (current index, next index, transition progress 0..1 or null when not
  /// transitioning, ms until the next change).
  static ({int index, int next, double? progress, int waitMs}) position(Source source) {
    final s = source.settings;
    final count = (s['paths'] as List? ?? const []).length;
    final slideMs = math.max(500, (s['slideMs'] as num?)?.toInt() ?? 5000);
    final transMs = math.min(slideMs ~/ 2, math.max(0, (s['transitionMs'] as num?)?.toInt() ?? 700));
    final loop = s['loop'] as bool? ?? true;
    if (count <= 1) return (index: 0, next: 0, progress: null, waitMs: 1 << 30);
    final elapsed = now().difference(_start(source)).inMilliseconds;
    var step = elapsed ~/ slideMs + (_manualOffset[source.id] ?? 0);
    final phase = elapsed % slideMs;
    if (!loop && step >= count - 1) return (index: _order(source, count - 1, count), next: 0, progress: null, waitMs: 1 << 30);
    step = step % count;
    if (step < 0) step += count;
    final index = _order(source, step, count);
    final next = _order(source, (step + 1) % count, count);
    final toEnd = slideMs - phase;
    if (s['transition'] != 'cut' && transMs > 0 && toEnd <= transMs && (loop || step + 1 < count)) {
      return (index: index, next: next, progress: 1 - toEnd / transMs, waitMs: 16);
    }
    return (index: index, next: next, progress: null, waitMs: math.max(16, toEnd - transMs));
  }

  /// Shuffled order (stable per source) when "random" is on.
  static int _order(Source source, int step, int count) {
    if (source.settings['random'] != true) return step;
    final order = List<int>.generate(count, (i) => i)..shuffle(math.Random(source.id.hashCode));
    return order[step];
  }
}

/// Renders an Image Slide Show source.
class SlideShowView extends StatefulWidget {
  const SlideShowView({super.key, required this.source, required this.fit, required this.placeholder});

  final Source source;
  final BoxFit fit;
  final Widget placeholder;

  @override
  State<SlideShowView> createState() => _SlideShowViewState();
}

class _SlideShowViewState extends State<SlideShowView> {
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule(int ms) {
    _timer?.cancel();
    if (ms >= 1 << 29) return;
    _timer = Timer(Duration(milliseconds: ms), () {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final paths = (widget.source.settings['paths'] as List? ?? const []).cast<String>();
    if (paths.isEmpty) {
      _timer?.cancel();
      return widget.placeholder;
    }
    final p = SlideShowClock.position(widget.source);
    _schedule(p.waitMs);
    Widget img(int i) => SizedBox.expand(
          child: imageFromPath(paths[i.clamp(0, paths.length - 1)], fit: widget.fit),
        );
    final t = p.progress;
    if (t == null) return img(p.index);
    final eased = Curves.easeInOut.transform(t);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return ClipRect(
        child: Stack(fit: StackFit.expand, children: switch (widget.source.settings['transition']) {
          'slide' => [
              Transform.translate(offset: Offset(-w * eased, 0), child: img(p.index)),
              Transform.translate(offset: Offset(w * (1 - eased), 0), child: img(p.next)),
            ],
          'swipe' => [
              img(p.index),
              Transform.translate(offset: Offset(w * (1 - eased), 0), child: img(p.next)),
            ],
          _ => [
              img(p.index),
              Opacity(opacity: eased, child: img(p.next)),
            ],
        }),
      );
    });
  }
}
