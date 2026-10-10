import 'dart:async';
import 'dart:convert';

import '../core/models.dart';
import '../core/studio_controller.dart';
import '../render/media_services.dart';
import 'output_engine.dart';

/// Audio monitoring for a Media Source, like OBS: 'off' (stream only, the
/// default), 'monitor' (tablet/headphones only) or 'both'.
String monitoringOf(Source s) => s.settings['monitoring'] as String? ?? 'off';

/// Keeps the native media audio mixer in step with the Media Sources on
/// Program: which files, their volume, and where each player is.
class MediaAudioBridge {
  MediaAudioBridge(this.studio, this.media, this.output) {
    studio.addListener(_push);
    media.addListener(_push);
    // Positions drift slowly; a regular update keeps audio on the picture.
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _push(force: true));
    _push();
  }

  final StudioController studio;
  final MediaService media;
  final OutputEngine output;
  Timer? _timer;
  String _last = '';

  /// The list sent to the native mixer.
  List<Map<String, Object>> describe() {
    final out = <Map<String, Object>>[];
    final seen = <String>{};
    for (final item in studio.programScene.items) {
      if (!item.visible || !seen.add(item.sourceId)) continue;
      final s = studio.sourceById(item.sourceId);
      if (s == null || s.type != SourceType.media) continue;
      final c = media.controllerFor(s.id);
      final path = s.settings['path'] as String? ?? '';
      if (c == null || path.isEmpty) continue;
      final silenced = s.muted || (s.settings['muted'] as bool? ?? false) || monitoringOf(s) == 'monitor';
      out.add({
        'id': s.id,
        'path': path,
        'gain': silenced ? 0.0 : s.volume * s.filterGain,
        'playing': c.value.isPlaying,
        'positionMs': c.value.position.inMilliseconds,
        'loop': s.settings['loop'] as bool? ?? true,
        'delayMs': s.syncOffsetMs,
      });
    }
    return out;
  }

  /// [force]: the timer tick, which re-sends positions so the native side
  /// can correct drift; other changes send only when something besides the
  /// position changed (dragging an item notifies every frame).
  void _push({bool force = false}) {
    if (!output.encoderSupported) return;
    final list = describe();
    final key = jsonEncode([for (final m in list) Map.of(m)..remove('positionMs')]);
    if (!force && key == _last) return;
    if (force && list.isEmpty && _last == '[]') return;
    _last = key;
    output.backend.setMediaAudio(list).catchError((_) {});
  }

  void dispose() {
    _timer?.cancel();
    studio.removeListener(_push);
    media.removeListener(_push);
  }
}
