import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import 'filter_view.dart';
import 'scene_canvas.dart';

/// Logical size the Multiview is laid out at; it's captured scaled to the
/// connected screen.
const kMultiviewSize = Size(1280, 720);

/// What the small tiles of the Multiview show.
enum MultiviewTiles { scenes, sources }

/// OBS's Multiview: Preview and Program on top, the first 8 scenes below.
/// The program scene has a red border, the preview scene a green one.
///
///   ┌──────────────┬──────────────┐
///   │   Preview    │   Program    │
///   ├────┬────┬────┼────┬────┬────┤ ...
///   │ 1  │ 2  │ 3  │ 4  │          (2 rows of 4)
///
/// With [tiles] = sources, the small tiles are the sources of the scene being
/// edited instead. When [interactive] (fullscreen on the tablet), tapping a
/// scene switches to it, tapping the Preview transitions it to Program
/// (Studio Mode) and tapping a source cuts to it.
class Multiview extends StatelessWidget {
  const Multiview({super.key, this.interactive = false, this.tiles = MultiviewTiles.scenes});

  final bool interactive;
  final MultiviewTiles tiles;

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
        final scenes = studio.scenes.take(8).toList();
        final badges = [
          if (out.isStreaming) ('LIVE', _program),
          if (out.isRecording) ('REC', const Color(0xFFE0603A)),
          if (out.ndiActive) ('NDI', _preview),
        ];

        Widget tile(
          Widget picture,
          String label,
          Color? border, {
          double labelSize = 14,
          List<(String, Color)> badges = const [],
          VoidCallback? onTap,
          Key? key,
        }) {
          final box = Container(
            decoration: BoxDecoration(
              color: Colors.black,
              border: Border.all(color: border ?? const Color(0xFF3C404D), width: border == null ? 1 : 4),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(child: FittedBox(child: picture)),
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
          if (!interactive || onTap == null) return box;
          return GestureDetector(key: key, behavior: HitTestBehavior.opaque, onTap: onTap, child: box);
        }

        Widget canvas(Scene s) => SceneCanvas(scene: s, showPlaceholders: false);

        // The small tiles: scenes, or the pictures in the scene being edited
        // (top-most first).
        final small = <Widget>[];
        if (tiles == MultiviewTiles.scenes) {
          for (final (i, s) in scenes.indexed) {
            final border = s.id == program.id ? _program : (s.id == preview.id ? _preview : null);
            small.add(tile(canvas(s), '${i + 1}. ${s.name}', border,
                key: ValueKey('multiview-scene-${s.id}'), onTap: () => studio.selectScene(s.id)));
          }
        } else {
          final editing = studio.editingScene;
          final cw = studio.settings.canvasWidth.toDouble(), ch = studio.settings.canvasHeight.toDouble();
          for (final item in editing.items.reversed) {
            final source = studio.sourceById(item.sourceId);
            if (source == null || !source.type.isVisual) continue;
            if (small.length == 8) break;
            final picture = SizedBox(
              width: cw,
              height: ch,
              child: ColoredBox(
                color: Colors.black,
                child: applySourceFilters(source, SourceRenderer(source: source, fit: FitMode.contain, showPlaceholder: false)),
              ),
            );
            final border = item.visible ? (studio.studioMode ? _preview : _program) : null;
            small.add(tile(picture, '${small.length + 1}. ${source.name}', border,
                key: ValueKey('multiview-source-${item.id}'), onTap: () => studio.soloItem(item.id)));
          }
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
                      Expanded(
                        child: tile(canvas(preview), 'Preview · ${preview.name}', _preview, labelSize: 18,
                            key: const ValueKey('multiview-preview'),
                            onTap: studio.studioMode ? studio.transitionToProgram : null),
                      ),
                      Expanded(
                        child: tile(canvas(program), 'Program · ${program.name}', _program,
                            labelSize: 18, badges: badges),
                      ),
                    ],
                  ),
                ),
                for (var row = 0; row < 2; row++)
                  SizedBox(
                    height: h / 4,
                    child: Row(
                      children: [
                        for (var col = 0; col < 4; col++)
                          Expanded(
                            child: row * 4 + col < small.length
                                ? small[row * 4 + col]
                                : const ColoredBox(color: Color(0xFF111216)),
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
