import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../core/studio_controller.dart';
import 'scene_canvas.dart';

/// The program (what goes out on stream/recording). Animates between scenes
/// using the configured transition whenever the program scene changes, and
/// wraps everything in the RepaintBoundary the output engine captures.
class ProgramView extends StatefulWidget {
  const ProgramView({super.key, this.capture = true});

  /// The instance the output engine captures (owns the capture keys). Extra
  /// views, like the fullscreen projector, pass false.
  final bool capture;

  @override
  State<ProgramView> createState() => _ProgramViewState();
}

class _ProgramViewState extends State<ProgramView> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, value: 1);
  /// The program before and after the running transition. Scene objects,
  /// not ids: in Studio Mode a Transition to the same scene swaps in a new
  /// copy of it (see StudioController.programScene).
  Scene? _from;
  Scene? _to;
  int _serial = -1;
  TransitionType _type = TransitionType.cut;

  StudioController? _studio;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final studio = AppScope.of(context).studio;
    if (!identical(studio, _studio)) {
      _studio?.removeListener(_onStudio);
      _studio = studio..addListener(_onStudio);
      _onStudio();
    }
  }

  @override
  void dispose() {
    _studio?.removeListener(_onStudio);
    _anim.dispose();
    super.dispose();
  }

  void _onStudio() {
    if (!mounted) return;
    _maybeStartTransition();
    setState(() {});
  }

  void _maybeStartTransition() {
    final studio = _studio!;
    final current = studio.programScene;
    if (_to == null || studio.transitionSerial == _serial) {
      // No new transition: follow the program as it is (live edits outside
      // Studio Mode, a deleted program scene...).
      _to = current;
      _serial = studio.transitionSerial;
      return;
    }
    _serial = studio.transitionSerial;
    if (identical(current, _to)) return;
    _from = _to;
    _to = current;
    _type = studio.activeTransition;
    if (_type == TransitionType.cut) {
      _from = null;
      _anim.value = 1;
      return;
    }
    _anim.duration = Duration(milliseconds: math.max(1, studio.activeTransitionMs));
    _anim.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _from = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final studio = scope.studio;
    return Builder(
      builder: (context) {
        final to = _to ?? studio.programScene;
        final from = _from;
        final cw = studio.settings.canvasWidth.toDouble();

        Widget canvasFor(Scene s) => SceneCanvas(scene: s, showPlaceholders: false);

        // A settled scene with a Screen Capture source is split into the
        // layers below and above it. The output engine captures those two
        // layers and the native side puts the live screen between them, so
        // the stream keeps running while the user is in another app. The
        // status card in between is only shown on the tablet.
        Widget settled(Scene s) {
          final idx = studio.screenItemIndex(s);
          if (idx < 0) return canvasFor(s);
          final item = s.items[idx];
          return Stack(children: [
            RepaintBoundary(
              key: widget.capture ? scope.output.underKey : null,
              child: SceneCanvas(scene: s, showPlaceholders: false, end: idx),
            ),
            SizedBox(
              width: cw,
              height: studio.settings.canvasHeight.toDouble(),
              child: Stack(children: [
                SceneItemView(item: item, source: studio.sourceById(item.sourceId)!, showPlaceholder: true),
              ]),
            ),
            if (idx < s.items.length - 1)
              RepaintBoundary(
                key: widget.capture ? scope.output.overKey : null,
                child: SceneCanvas(scene: s, showPlaceholders: false, start: idx + 1, transparent: true),
              ),
          ]);
        }

        Widget mix(Scene from, Scene to, TransitionType type, double progress) {
          final t = Curves.easeInOut.transform(progress);
          switch (type) {
            case TransitionType.cut:
              return canvasFor(progress >= 1 ? to : from);
            case TransitionType.fade:
              return Stack(children: [
                canvasFor(from),
                Opacity(opacity: t, child: canvasFor(to)),
              ]);
            case TransitionType.fadeToBlack:
              final showTo = t >= 0.5;
              final o = showTo ? (t - 0.5) * 2 : 1 - t * 2;
              return ColoredBox(
                color: Colors.black,
                child: Opacity(opacity: o.clamp(0, 1), child: canvasFor(showTo ? to : from)),
              );
            case TransitionType.slide:
              return Stack(children: [
                Transform.translate(offset: Offset(-cw * t, 0), child: canvasFor(from)),
                Transform.translate(offset: Offset(cw * (1 - t), 0), child: canvasFor(to)),
              ]);
            case TransitionType.swipe:
              return Stack(children: [
                canvasFor(from),
                Transform.translate(offset: Offset(cw * (1 - t), 0), child: canvasFor(to)),
              ]);
          }
        }

        return RepaintBoundary(
          key: widget.capture ? scope.output.programKey : null,
          child: ColoredBox(
            color: Colors.black,
            child: FittedBox(
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (context, _) {
                    // Studio mode T-bar: a manual mix towards the preview.
                    final tBar = studio.tBar;
                    if (studio.studioMode && tBar > 0 && (from == null || _anim.value >= 1)) {
                      return mix(to, studio.previewScene, studio.collection.transition, tBar);
                    }
                    if (from == null || _anim.value >= 1) return settled(to);
                    return mix(from, to, _type, _anim.value);
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
