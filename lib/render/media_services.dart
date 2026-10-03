import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../core/models.dart';
import '../core/studio_controller.dart';
import 'platform_media.dart';

/// Opens cameras on demand and closes them when no visible scene uses them.
/// Several sources can share one lens (same controller, same texture).
class CameraService extends ChangeNotifier {
  List<CameraDescription>? _cameras;
  final Map<String, CameraController> _controllers = {};
  final Map<String, String> errors = {};
  final Set<String> _opening = {};
  bool _disposed = false;

  Future<List<CameraDescription>> cameras() async {
    if (_cameras != null) return _cameras!;
    try {
      _cameras = await availableCameras();
    } catch (e) {
      _cameras = const [];
      errors['*'] = 'Camera unavailable: $e';
    }
    return _cameras!;
  }

  CameraController? controllerFor(String lens) {
    final c = _controllers[lens];
    return (c != null && c.value.isInitialized) ? c : null;
  }

  String? errorFor(String lens) => errors[lens] ?? errors['*'];

  /// Ensures exactly the cameras in [lenses] are open.
  Future<void> sync(Set<String> lenses) async {
    for (final lens in _controllers.keys.toList()) {
      if (!lenses.contains(lens)) {
        final c = _controllers.remove(lens);
        await c?.dispose();
      }
    }
    for (final lens in lenses) {
      if (_controllers.containsKey(lens) || _opening.contains(lens)) continue;
      unawaited(_open(lens));
    }
  }

  Future<void> _open(String lens) async {
    _opening.add(lens);
    try {
      final all = await cameras();
      final dir = switch (lens) {
        'back' => CameraLensDirection.back,
        'external' => CameraLensDirection.external,
        _ => CameraLensDirection.front,
      };
      final desc = all.where((c) => c.lensDirection == dir).firstOrNull ?? all.firstOrNull;
      if (desc == null) {
        errors[lens] = 'No camera found';
        return;
      }
      final c = CameraController(desc, ResolutionPreset.high, enableAudio: false);
      await c.initialize();
      if (_disposed) {
        await c.dispose();
        return;
      }
      _controllers[lens] = c;
      errors.remove(lens);
    } catch (e) {
      errors[lens] = e is CameraException ? (e.description ?? e.code) : '$e';
    } finally {
      _opening.remove(lens);
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    super.dispose();
  }
}

/// Video players for Media Sources (looping clips, intros, overlays).
class MediaService extends ChangeNotifier {
  final Map<String, (String path, VideoPlayerController ctl)> _players = {};
  final Map<String, String> errors = {};
  bool _disposed = false;

  VideoPlayerController? controllerFor(String sourceId) {
    final p = _players[sourceId];
    return (p != null && p.$2.value.isInitialized) ? p.$2 : null;
  }

  Future<void> sync(Iterable<Source> active) async {
    final wanted = {for (final s in active) s.id: s};
    for (final id in _players.keys.toList()) {
      final s = wanted[id];
      if (s == null || s.settings['path'] != _players[id]!.$1) {
        final p = _players.remove(id)!;
        await p.$2.dispose();
      }
    }
    for (final s in wanted.values) {
      final path = (s.settings['path'] as String?) ?? '';
      final existing = _players[s.id];
      if (existing != null) {
        _applySettings(s, existing.$2);
        continue;
      }
      if (path.isEmpty) continue;
      final ctl = videoControllerFromPath(path);
      _players[s.id] = (path, ctl);
      ctl.initialize().then((_) {
        if (_disposed) return;
        _applySettings(s, ctl);
        ctl.play();
        errors.remove(s.id);
        notifyListeners();
      }).catchError((Object e) {
        errors[s.id] = '$e';
        if (!_disposed) notifyListeners();
      });
    }
  }

  void _applySettings(Source s, VideoPlayerController c) {
    c.setLooping(s.settings['loop'] as bool? ?? true);
    final muted = s.muted || (s.settings['muted'] as bool? ?? false);
    c.setVolume(muted ? 0 : s.volume);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final p in _players.values) {
      p.$2.dispose();
    }
    _players.clear();
    super.dispose();
  }
}

/// Keeps cameras and media players in sync with what's on program/preview.
class SourceActivityTracker {
  SourceActivityTracker(this.studio, this.cameras, this.media) {
    studio.addListener(_sync);
    _sync();
  }

  final StudioController studio;
  final CameraService cameras;
  final MediaService media;

  void _sync() {
    final scenes = {studio.programScene, studio.previewScene};
    final lenses = <String>{};
    final mediaSources = <String, Source>{};
    for (final scene in scenes) {
      for (final item in scene.items) {
        if (!item.visible) continue;
        final s = studio.sourceById(item.sourceId);
        if (s == null) continue;
        if (s.type == SourceType.camera) lenses.add(s.settings['lens'] as String? ?? 'front');
        if (s.type == SourceType.media) mediaSources[s.id] = s;
      }
    }
    cameras.sync(lenses);
    media.sync(mediaSources.values);
  }

  void dispose() => studio.removeListener(_sync);
}
