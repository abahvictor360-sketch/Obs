import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../core/studio_controller.dart';
import 'scene_canvas.dart';

/// The program (what goes out on stream/recording). Animates between scenes
/// using the configured transition whenever the program scene changes, and
/// wraps everything in the RepaintBoundary the output engine captures.
class ProgramView extends StatefulWidget {
  const ProgramView({super.key});

  @override
  State<ProgramView> createState() => _ProgramViewState();
}

class _ProgramViewState extends State<ProgramView> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, value: 1);
  String? _fromSceneId;
  String? _toSceneId;
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
    final programId = studio.collection.programSceneId;
    if (_toSceneId == null) {
      _toSceneId = programId;
      _serial = studio.transitionSerial;
      return;
    }
    if (studio.transitionSerial == _serial && programId == _toSceneId) return;
    _serial = studio.transitionSerial;
    if (programId == _toSceneId) return;
    _fromSceneId = _toSceneId;
    _toSceneId = programId;
    _type = studio.collection.transition;
    if (_type == TransitionType.cut) {
      _fromSceneId = null;
      _anim.value = 1;
      return;
    }
    _anim.duration = Duration(milliseconds: studio.collection.transitionMs);
    _anim.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _fromSceneId = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final studio = scope.studio;
    return Builder(
      builder: (context) {
        final to = studio.sceneById(_toSceneId ?? studio.collection.programSceneId) ?? studio.programScene;
        final from = _fromSceneId == null ? null : studio.sceneById(_fromSceneId!);
        final cw = studio.settings.canvasWidth.toDouble();

        Widget canvasFor(Scene s) => SceneCanvas(scene: s, showPlaceholders: false);

        return RepaintBoundary(
          key: scope.output.programKey,
          child: ColoredBox(
            color: Colors.black,
            child: FittedBox(
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (context, _) {
                    final t = Curves.easeInOut.transform(_anim.value);
                    if (from == null || _anim.value >= 1) return canvasFor(to);
                    switch (_type) {
                      case TransitionType.cut:
                        return canvasFor(to);
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
