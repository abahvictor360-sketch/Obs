import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'ndi_input.dart';

/// Live state of one NDI® Source.
class NdiFeed extends ChangeNotifier {
  NdiFeed(this.name);

  final String name;
  ui.Image? image;
  NdiReceiverState state = NdiReceiverState.searching;
  String? message;
  int width = 0, height = 0;
  double fps = 0;

  int _frames = 0;
  DateTime _since = DateTime.now();

  void _set(ui.Image img) {
    final old = image;
    image = img;
    width = img.width;
    height = img.height;
    _frames++;
    final s = DateTime.now().difference(_since).inMilliseconds;
    if (s >= 1000) {
      fps = _frames * 1000 / s;
      _frames = 0;
      _since = DateTime.now();
    }
    notifyListeners();
    if (old != null) Timer(const Duration(milliseconds: 200), old.dispose);
  }

  void _clear() {
    image?.dispose();
    image = null;
  }
}

class _Rx {
  _Rx(this.name, this.lowBandwidth, this.feed);
  final String name;
  final bool lowBandwidth;
  final NdiFeed feed;
  NdiReceiverHandle? handle;
  bool closed = false;
}

/// Receives the NDI® Sources that are on Program or Preview: video becomes
/// an image for the canvas, sound goes to [onAudio] (the stream mix).
class NdiInputService extends ChangeNotifier {
  NdiInputService({NdiReceiverBackend? backend, this.onAudio}) : backend = backend ?? createNdiReceiverBackend();

  final NdiReceiverBackend backend;

  /// Sound of source [id]: interleaved float PCM.
  void Function(String id, Float32List pcm, int sampleRate, int channels)? onAudio;

  final Map<String, _Rx> _rx = {};

  bool get available => backend.available;
  String? get unavailableReason => backend.unavailableReason;

  NdiFeed? feed(String sourceId) => _rx[sourceId]?.feed;

  /// NDI senders on the network.
  Future<List<String>> discover() => backend.discover();

  /// Keeps exactly [wanted] (sourceId -> (NDI name, low bandwidth)) connected.
  void sync(Map<String, (String, bool)> wanted) {
    var changed = false;
    for (final id in _rx.keys.toList()) {
      final w = wanted[id];
      final r = _rx[id]!;
      if (w == null || w.$1 != r.name || w.$2 != r.lowBandwidth) {
        _close(id);
        changed = true;
      }
    }
    for (final e in wanted.entries) {
      if (_rx.containsKey(e.key) || e.value.$1.isEmpty) continue;
      _open(e.key, e.value.$1, e.value.$2);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _open(String id, String name, bool low) {
    final r = _Rx(name, low, NdiFeed(name));
    _rx[id] = r;
    r.handle = backend.open(
      name,
      lowBandwidth: low,
      onVideo: (rgba, w, h) {
        if (r.closed) return;
        ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, (img) {
          if (r.closed) {
            img.dispose();
            return;
          }
          r.feed._set(img);
          r.handle?.frameDone();
        });
      },
      onAudio: (pcm, rate, ch) {
        if (!r.closed) onAudio?.call(id, pcm, rate, ch);
      },
      onState: (state, message) {
        if (r.closed) return;
        r.feed
          ..state = state
          ..message = message;
        r.feed.notifyListeners();
        notifyListeners();
      },
    );
  }

  void _close(String id) {
    final r = _rx.remove(id);
    if (r == null) return;
    r.closed = true;
    r.handle?.close();
    r.feed._clear();
  }

  @override
  void dispose() {
    for (final id in _rx.keys.toList()) {
      _close(id);
    }
    super.dispose();
  }
}
