import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../core/models.dart';
import '../core/studio_controller.dart';
import 'platform_media.dart';

/// Settings of a Video Capture Device source that affect the camera itself.
class CameraOptions {
  const CameraOptions({
    this.resolution = 'high',
    this.zoom = 1,
    this.torch = false,
    this.exposure = 0,
    this.focusLocked = false,
  });

  factory CameraOptions.fromSettings(Map<String, dynamic> s) => CameraOptions(
        resolution: s['resolution'] as String? ?? 'high',
        zoom: (s['zoom'] as num?)?.toDouble() ?? 1,
        torch: s['torch'] == true,
        exposure: (s['exposure'] as num?)?.toDouble() ?? 0,
        focusLocked: s['focusLocked'] == true,
      );

  /// medium (480p) | high (720p) | veryHigh (1080p) | ultraHigh (4K) | max
  final String resolution;
  final double zoom;
  final bool torch;
  final double exposure;
  final bool focusLocked;

  ResolutionPreset get preset => ResolutionPreset.values.where((p) => p.name == resolution).firstOrNull ?? ResolutionPreset.high;
}

/// What the open camera can do (for the properties sliders).
class CameraCaps {
  const CameraCaps({this.minZoom = 1, this.maxZoom = 1, this.minExposure = 0, this.maxExposure = 0, this.hasTorch = false});
  final double minZoom, maxZoom, minExposure, maxExposure;
  final bool hasTorch;
}

/// Opens cameras on demand and closes them when no visible scene uses them.
/// Several sources can share one lens (same controller, same texture); the
/// first visible source's options win.
class CameraService extends ChangeNotifier {
  List<CameraDescription>? _cameras;
  final Map<String, CameraController> _controllers = {};
  final Map<String, CameraOptions> _applied = {};
  final Map<String, CameraCaps> _caps = {};
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

  CameraCaps? capsFor(String lens) => _caps[lens];

  String? errorFor(String lens) => errors[lens] ?? errors['*'];

  /// Ensures exactly the cameras in [lenses] are open with these options.
  Future<void> sync(Map<String, CameraOptions> lenses) async {
    for (final lens in _controllers.keys.toList()) {
      final want = lenses[lens];
      // Resolution can only be chosen when opening.
      if (want == null || want.resolution != _applied[lens]?.resolution) {
        final c = _controllers.remove(lens);
        _applied.remove(lens);
        await c?.dispose();
      }
    }
    for (final e in lenses.entries) {
      if (_opening.contains(e.key)) continue;
      if (_controllers.containsKey(e.key)) {
        unawaited(_apply(e.key, e.value));
      } else {
        unawaited(_open(e.key, e.value));
      }
    }
  }

  Future<void> _open(String lens, CameraOptions options) async {
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
      final c = CameraController(desc, options.preset, enableAudio: false);
      await c.initialize();
      if (_disposed) {
        await c.dispose();
        return;
      }
      _controllers[lens] = c;
      _applied[lens] = CameraOptions(resolution: options.resolution);
      errors.remove(lens);
      try {
        _caps[lens] = CameraCaps(
          minZoom: await c.getMinZoomLevel(),
          maxZoom: await c.getMaxZoomLevel(),
          minExposure: await c.getMinExposureOffset(),
          maxExposure: await c.getMaxExposureOffset(),
          hasTorch: desc.lensDirection == CameraLensDirection.back,
        );
      } catch (_) {
        _caps[lens] = const CameraCaps();
      }
      await _apply(lens, options);
    } catch (e) {
      errors[lens] = e is CameraException ? (e.description ?? e.code) : '$e';
    } finally {
      _opening.remove(lens);
      if (!_disposed) notifyListeners();
    }
  }

  /// Applies the live controls (zoom, torch, exposure, focus) that changed.
  Future<void> _apply(String lens, CameraOptions o) async {
    final c = controllerFor(lens);
    final prev = _applied[lens];
    final caps = _caps[lens] ?? const CameraCaps();
    if (c == null || prev == null) return;
    _applied[lens] = o;
    try {
      if (o.zoom != prev.zoom && caps.maxZoom > caps.minZoom) {
        await c.setZoomLevel(o.zoom.clamp(caps.minZoom, caps.maxZoom));
      }
      if (o.torch != prev.torch && caps.hasTorch) {
        await c.setFlashMode(o.torch ? FlashMode.torch : FlashMode.off);
      }
      if (o.exposure != prev.exposure && caps.maxExposure > caps.minExposure) {
        await c.setExposureOffset(o.exposure.clamp(caps.minExposure, caps.maxExposure));
      }
      if (o.focusLocked != prev.focusLocked) {
        await c.setFocusMode(o.focusLocked ? FocusMode.locked : FocusMode.auto);
      }
    } on CameraException catch (e) {
      errors[lens] = e.description ?? e.code;
      notifyListeners();
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
    final lenses = <String, CameraOptions>{};
    final mediaSources = <String, Source>{};
    for (final s in studio.activeSources) {
      if (s.type == SourceType.camera) {
        lenses.putIfAbsent(s.settings['lens'] as String? ?? 'front', () => CameraOptions.fromSettings(s.settings));
      }
      if (s.type == SourceType.media) mediaSources[s.id] = s;
    }
    cameras.sync(lenses);
    media.sync(mediaSources.values);
  }

  void dispose() => studio.removeListener(_sync);
}
