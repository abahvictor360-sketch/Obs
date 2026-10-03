import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../ui/theme.dart';
import 'platform_media.dart';

/// Renders a scene at full canvas resolution (e.g. 1920x1080 logical px).
/// Wrap in a FittedBox to display it at any size.
class SceneCanvas extends StatelessWidget {
  const SceneCanvas({
    super.key,
    required this.scene,
    this.showPlaceholders = true,
    this.start = 0,
    this.end,
    this.transparent = false,
  });

  final Scene scene;

  /// Only draw items in [start, end) (bottom-most first). Used to split a
  /// scene into layers below and above a Screen Capture item.
  final int start;
  final int? end;

  /// No black canvas background (for the layer above the screen).
  final bool transparent;

  /// Draw hints for sources that have no content yet (no image picked,
  /// camera missing). Turned off for the program output.
  final bool showPlaceholders;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final studio = scope.studio;
    final cw = studio.settings.canvasWidth.toDouble();
    final ch = studio.settings.canvasHeight.toDouble();
    return SizedBox(
      width: cw,
      height: ch,
      child: ClipRect(
        child: ColoredBox(
          color: transparent ? Colors.transparent : Colors.black,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (final item in scene.items.sublist(start, end ?? scene.items.length))
                if (item.visible)
                  if (studio.sourceById(item.sourceId) case final source? when source.type.isVisual)
                    SceneItemView(
                      key: ValueKey(item.id),
                      item: item,
                      source: source,
                      showPlaceholder: showPlaceholders,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class SceneItemView extends StatelessWidget {
  const SceneItemView({super.key, required this.item, required this.source, required this.showPlaceholder});

  final SceneItem item;
  final Source source;
  final bool showPlaceholder;

  @override
  Widget build(BuildContext context) {
    final t = item.transform;
    Widget child = SourceRenderer(source: source, fit: t.fit, showPlaceholder: showPlaceholder);

    // Crop: show only the inner part of the source, scaled to the box.
    if (t.cropLeft > 0 || t.cropTop > 0 || t.cropRight > 0 || t.cropBottom > 0) {
      final fx = math.max(0.01, 1 - t.cropLeft - t.cropRight);
      final fy = math.max(0.01, 1 - t.cropTop - t.cropBottom);
      final fullW = t.width / fx, fullH = t.height / fy;
      child = ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: fullW,
          maxWidth: fullW,
          minHeight: fullH,
          maxHeight: fullH,
          child: Transform.translate(
            offset: Offset(-t.cropLeft * fullW, -t.cropTop * fullH),
            child: SizedBox(width: fullW, height: fullH, child: child),
          ),
        ),
      );
    }

    if (t.flipH || t.flipV) {
      child = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(t.flipH ? -1 : 1, t.flipV ? -1 : 1, 1),
        child: child,
      );
    }

    if (!item.color.isNeutral) {
      child = ColorFiltered(colorFilter: ColorFilter.matrix(item.color.toMatrix()), child: child);
    }

    if (t.rotation != 0) {
      child = Transform.rotate(angle: t.rotation * math.pi / 180, child: child);
    }

    return Positioned(
      left: t.x,
      top: t.y,
      width: math.max(1, t.width),
      height: math.max(1, t.height),
      child: child,
    );
  }
}

BoxFit _boxFit(FitMode f) => switch (f) {
      FitMode.stretch => BoxFit.fill,
      FitMode.contain => BoxFit.contain,
      FitMode.cover => BoxFit.cover,
    };

/// Draws the pixels of a single source.
class SourceRenderer extends StatelessWidget {
  const SourceRenderer({super.key, required this.source, required this.fit, this.showPlaceholder = true});

  final Source source;
  final FitMode fit;
  final bool showPlaceholder;

  @override
  Widget build(BuildContext context) {
    final s = source.settings;
    switch (source.type) {
      case SourceType.color:
        return ColoredBox(color: Color(s['color'] as int));
      case SourceType.text:
        return _TextSource(settings: s);
      case SourceType.image:
        final path = s['path'] as String? ?? '';
        if (path.isEmpty) return _placeholder(Icons.image_outlined, 'Tap ⚙ to choose an image');
        return imageFromPath(path, fit: _boxFit(fit));
      case SourceType.camera:
        return _CameraSource(source: source, fit: _boxFit(fit), showPlaceholder: showPlaceholder);
      case SourceType.media:
        return _MediaSource(source: source, fit: _boxFit(fit), showPlaceholder: showPlaceholder);
      case SourceType.screen:
        return showPlaceholder ? ScreenSourceCard(source: source) : const ColoredBox(color: Colors.black);
      case SourceType.audioInput:
        return const SizedBox.shrink();
      case SourceType.plugin:
        return _PluginSource(source: source, fit: _boxFit(fit), showPlaceholder: showPlaceholder);
    }
  }

  Widget _placeholder(IconData icon, String text) =>
      showPlaceholder ? SourcePlaceholder(icon: icon, label: source.name, hint: text) : const SizedBox.expand();
}

class SourcePlaceholder extends StatelessWidget {
  const SourcePlaceholder({super.key, required this.icon, required this.label, this.hint});

  final IconData icon;
  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF15171C),
        border: Border.all(color: ObsColors.border, width: 4),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 160, color: ObsColors.textDim),
              const SizedBox(height: 16),
              Text(label, style: const TextStyle(fontSize: 56, color: ObsColors.text)),
              if (hint != null)
                Text(hint!, style: const TextStyle(fontSize: 36, color: ObsColors.textDim)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextSource extends StatelessWidget {
  const _TextSource({required this.settings});

  final Map<String, dynamic> settings;

  @override
  Widget build(BuildContext context) {
    final text = settings['text'] as String? ?? '';
    final size = (settings['fontSize'] as num?)?.toDouble() ?? 96;
    final color = Color(settings['color'] as int? ?? 0xFFFFFFFF);
    final align = switch (settings['align']) {
      'left' => TextAlign.left,
      'right' => TextAlign.right,
      _ => TextAlign.center,
    };
    final base = TextStyle(
      fontSize: size,
      height: 1.15,
      fontWeight: (settings['bold'] as bool? ?? false) ? FontWeight.bold : FontWeight.normal,
      fontStyle: (settings['italic'] as bool? ?? false) ? FontStyle.italic : FontStyle.normal,
    );
    final bg = Color(settings['background'] as int? ?? 0);
    Widget t = Text(text, textAlign: align, style: base.copyWith(color: color));
    if (settings['outline'] as bool? ?? false) {
      t = Stack(
        children: [
          Text(
            text,
            textAlign: align,
            style: base.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = math.max(2, size / 14)
                ..strokeJoin = StrokeJoin.round
                ..color = Color(settings['outlineColor'] as int? ?? 0xFF000000),
            ),
          ),
          t,
        ],
      );
    }
    return ColoredBox(
      color: bg,
      child: FittedBox(fit: BoxFit.contain, child: t),
    );
  }
}

class _CameraSource extends StatelessWidget {
  const _CameraSource({required this.source, required this.fit, required this.showPlaceholder});

  final Source source;
  final BoxFit fit;
  final bool showPlaceholder;

  @override
  Widget build(BuildContext context) {
    final cams = AppScope.of(context).cameras;
    return ListenableBuilder(
      listenable: cams,
      builder: (context, _) {
        final lens = source.settings['lens'] as String? ?? 'front';
        final c = cams.controllerFor(lens);
        if (c == null) {
          if (!showPlaceholder) return const ColoredBox(color: Colors.black);
          final err = cams.errorFor(lens);
          return SourcePlaceholder(
            icon: Icons.videocam_outlined,
            label: source.name,
            hint: err ?? 'Starting camera…',
          );
        }
        // previewSize is reported in sensor (landscape) orientation.
        final ps = c.value.previewSize ?? const Size(1280, 720);
        var w = math.max(ps.width, ps.height), h = math.min(ps.width, ps.height);
        // CameraPreview rotates the texture to match the device orientation.
        if (!kIsWeb && MediaQuery.orientationOf(context) == Orientation.portrait) (w, h) = (h, w);
        Widget preview = SizedBox(width: w, height: h, child: CameraPreview(c));
        final mirror = (source.settings['mirror'] as bool? ?? false) &&
            c.description.lensDirection == CameraLensDirection.front;
        if (mirror) {
          preview = Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(-1, 1, 1),
            child: preview,
          );
        }
        return ClipRect(child: FittedBox(fit: fit, child: preview));
      },
    );
  }
}

class _MediaSource extends StatelessWidget {
  const _MediaSource({required this.source, required this.fit, required this.showPlaceholder});

  final Source source;
  final BoxFit fit;
  final bool showPlaceholder;

  @override
  Widget build(BuildContext context) {
    final media = AppScope.of(context).media;
    return ListenableBuilder(
      listenable: media,
      builder: (context, _) {
        final c = media.controllerFor(source.id);
        if (c == null) {
          if (!showPlaceholder) return const SizedBox.expand();
          final path = source.settings['path'] as String? ?? '';
          return SourcePlaceholder(
            icon: Icons.movie_outlined,
            label: source.name,
            hint: media.errors[source.id] ?? (path.isEmpty ? 'Tap ⚙ to choose a video' : 'Loading…'),
          );
        }
        final size = c.value.size;
        return ClipRect(
          child: FittedBox(
            fit: fit,
            child: SizedBox(width: size.width, height: size.height, child: VideoPlayer(c)),
          ),
        );
      },
    );
  }
}

/// On-screen stand-in for a Screen Capture source. The real screen pixels are
/// composited natively into the output (they keep flowing while you use other
/// apps), so the editor shows status and a start button instead of a
/// recursive mirror of this app.
class ScreenSourceCard extends StatelessWidget {
  const ScreenSourceCard({super.key, required this.source});

  final Source source;

  @override
  Widget build(BuildContext context) {
    final out = AppScope.of(context).output;
    return ListenableBuilder(
      listenable: out,
      builder: (context, _) {
        final st = out.screenState;
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF15171C),
            border: Border.all(color: st.active ? ObsColors.ok : ObsColors.border, width: 6),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(st.active ? Icons.screen_share : Icons.screen_share_outlined,
                      size: 160, color: st.active ? ObsColors.ok : ObsColors.textDim),
                  const SizedBox(height: 16),
                  Text(source.name, style: const TextStyle(fontSize: 56, color: ObsColors.text)),
                  const SizedBox(height: 8),
                  Text(
                    st.active
                        ? 'Capturing your screen. Switch to any app: it streams live.'
                        : (st.error ?? 'Screen capture is off'),
                    style: const TextStyle(fontSize: 36, color: ObsColors.textDim),
                  ),
                  if (!st.active && out.screenCaptureSupported)
                    const Text(
                      'Tap ▶ next to it in Sources to start',
                      style: TextStyle(fontSize: 36, color: ObsColors.textDim),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Pixels produced by a script plugin (drawn by the plugin on its canvas in
/// the sandbox, delivered as images).
class _PluginSource extends StatelessWidget {
  const _PluginSource({required this.source, required this.fit, required this.showPlaceholder});

  final Source source;
  final BoxFit fit;
  final bool showPlaceholder;

  @override
  Widget build(BuildContext context) {
    final plugins = AppScope.of(context).plugins;
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: plugins.frameFor(source.id),
      builder: (context, image, _) {
        if (image != null) return RawImage(image: image, fit: fit, filterQuality: FilterQuality.medium);
        if (!showPlaceholder) return const SizedBox.expand();
        final pluginId = source.settings['plugin'] as String? ?? '';
        final plugin = plugins.plugin(pluginId);
        final String hint;
        if (!plugins.supported) {
          hint = 'Plugins run in the Android and iPad apps';
        } else if (plugin == null) {
          hint = 'Plugin "$pluginId" is not installed';
        } else if (!plugins.isEnabled(pluginId)) {
          hint = 'Plugin "${plugin.manifest.name}" is disabled';
        } else {
          hint = plugins.instanceErrors[source.id] ?? 'Starting…';
        }
        return SourcePlaceholder(icon: Icons.extension_outlined, label: source.name, hint: hint);
      },
    );
  }
}
