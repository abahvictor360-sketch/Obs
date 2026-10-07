import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import 'scene_canvas.dart';

/// Logical size the Multiview is laid out at; it's captured scaled to the
/// connected screen.
const kMultiviewSize = Size(1280, 720);

/// Columns and rows of the scene grid for each Multiview layout (scene
/// count), filling the bottom half of the 16:9 Multiview.
const kMultiviewGrids = {4: (4, 1), 6: (3, 2), 8: (4, 2), 16: (8, 2)};

/// OBS's Multiview: Preview and Program on top, the first 4, 6, 8 or 16
/// scenes below (the multiviewScenes setting).
/// The program scene has a red border, the preview scene a green one.
///
///   ┌──────────────┬──────────────┐
///   │   Preview    │   Program    │
///   ├────┬────┬────┼────┬────┬────┤ ...
///   │ 1  │ 2  │ 3  │ 4  │          (2 rows of 4)
class Multiview extends StatelessWidget {
  const Multiview({super.key, this.onSceneTap, this.onSceneTransition});

  /// Tapping a scene tile (fullscreen Multiview on the tablet): like OBS's
  /// "click to preview / switch".
  final void Function(Scene scene)? onSceneTap;

  /// Double-tapping or holding a scene tile for a second: put it live.
  final void Function(Scene scene)? onSceneTransition;

  static const _program = Color(0xFFD7334B);
  static const _preview = Color(0xFF3FB950);

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.studio, scope.output]),
      builder: (context, _) {
        final studio = scope.studio;
        final out = scope.output;
        final program = studio.programScene;
        final preview = studio.studioMode ? studio.previewScene : program;
        final count = studio.settings.multiviewScenes;
        final (cols, rows) = kMultiviewGrids[count] ?? (4, 2);
        final sceneLabel = switch (count) { 4 => 16.0, 16 => 11.0, _ => 14.0 };
        final scenes = studio.scenes.take(cols * rows).toList();
        final badges = [
          if (out.isStreaming) ('LIVE', _program),
          if (out.isRecording) ('REC', const Color(0xFFE0603A)),
          if (out.ndiActive) ('NDI', _preview),
        ];

        Widget tile(
          Scene s,
          String label,
          Color? border, {
          double labelSize = 14,
          List<(String, Color)> badges = const [],
        }) {
          return Container(
            decoration: BoxDecoration(
              color: Colors.black,
              border: Border.all(color: border ?? const Color(0xFF3C404D), width: border == null ? 1 : 4),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(
                  child: FittedBox(child: SceneCanvas(scene: s, showPlaceholders: false)),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 6,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      color: const Color(0xB0000000),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white, fontSize: labelSize, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
                if (badges.isNotEmpty)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Row(
                      children: [
                        for (final (text, color) in badges)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            color: color,
                            child: Text(
                              text,
                              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        }

        final w = kMultiviewSize.width, h = kMultiviewSize.height;
        return Material(
          type: MaterialType.transparency,
          child: Container(
            width: w,
            height: h,
            color: const Color(0xFF111216),
            child: Column(
              children: [
                SizedBox(
                  height: h / 2,
                  child: Row(
                    children: [
                      Expanded(child: tile(preview, 'Preview · ${preview.name}', _preview, labelSize: 18)),
                      Expanded(
                        child: tile(program, 'Program · ${program.name}', _program, labelSize: 18, badges: badges),
                      ),
                    ],
                  ),
                ),
                for (var row = 0; row < rows; row++)
                  SizedBox(
                    height: h / 2 / rows,
                    child: Row(
                      children: [
                        for (var col = 0; col < cols; col++)
                          Expanded(
                            child: Builder(
                              builder: (context) {
                                final i = row * cols + col;
                                if (i >= scenes.length) return const ColoredBox(color: Color(0xFF111216));
                                final s = scenes[i];
                                final border = s.id == program.id ? _program : (s.id == preview.id ? _preview : null);
                                final t = tile(s, '${i + 1}. ${s.name}', border, labelSize: sceneLabel);
                                if (onSceneTap == null && onSceneTransition == null) return t;
                                return _SceneTileGestures(
                                  key: ValueKey('multiview-scene-${s.id}'),
                                  onTap: onSceneTap == null ? null : () => onSceneTap!(s),
                                  onGoLive: onSceneTransition == null ? null : () => onSceneTransition!(s),
                                  child: t,
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Keeps the Multiview laid out (behind the app's UI, which covers it) while
/// a connected screen shows it, so it can be captured.
class MultiviewHost extends StatelessWidget {
  const MultiviewHost({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.devices, scope.studio]),
      builder: (context, _) {
        final on =
            scope.studio.settings.externalDisplay == 'multiview' && scope.devices.dock.display?.presenting == true;
        if (!on) return const SizedBox.shrink();
        return OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: kMultiviewSize.width,
          maxWidth: kMultiviewSize.width,
          minHeight: kMultiviewSize.height,
          maxHeight: kMultiviewSize.height,
          child: RepaintBoundary(key: scope.output.multiviewKey, child: const Multiview()),
        );
      },
    );
  }
}

/// Tap, double-tap and a one-second hold on a Multiview scene.
class _SceneTileGestures extends StatelessWidget {
  const _SceneTileGestures({super.key, this.onTap, this.onGoLive, required this.child});

  static const holdDuration = Duration(seconds: 1);

  final VoidCallback? onTap;
  final VoidCallback? onGoLive;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          TapGestureRecognizer.new,
          (r) => r.onTap = onTap,
        ),
        if (onGoLive != null) ...{
          DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
            DoubleTapGestureRecognizer.new,
            (r) => r.onDoubleTap = onGoLive,
          ),
          LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(duration: holdDuration),
            (r) => r.onLongPress = onGoLive,
          ),
        },
      },
      child: child,
    );
  }
}
