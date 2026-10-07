import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../core/models.dart';
import '../core/studio_controller.dart';
import 'mjpeg.dart';
import 'transport_stub.dart' if (dart.library.io) 'transport_io.dart' as transport;

/// Opens an HTTP byte stream (abstracted for tests and the web build).
typedef ByteStreamOpener = Future<Stream<List<int>>> Function(String url, void Function(void Function()) onCancel);

enum FeedState { connecting, live, retrying, error }

/// Live state of one Network Video source.
class NetworkFeed {
  NetworkFeed(this.url, this.kind);

  final String url;
  final NetworkVideoKind kind;
  final frame = ValueNotifier<ui.Image?>(null);
  FeedState state = FeedState.connecting;
  String? error;
  int width = 0, height = 0;
  double fps = 0;

  /// For stream kinds (HLS/HTTP video).
  VideoPlayerController? player;

  int _frames = 0;
  DateTime _since = DateTime.now();
  bool _decoding = false;
  bool _closed = false;
  void Function()? _cancel;
  Timer? _retry;
}

/// Video from other devices on the network: a phone running DroidCam or
/// IP Webcam, IP cameras (MJPEG), or HLS/HTTP streams.
class NetworkVideoService extends ChangeNotifier {
  NetworkVideoService({ByteStreamOpener? opener, Future<bool> Function(String url)? get})
      : _open = opener ?? transport.openHttpStream,
        _get = get ?? transport.httpGet;

  final ByteStreamOpener _open;
  final Future<bool> Function(String url) _get;

  /// Camera switch requests last sent, per source (see [phoneCameraUrl]).
  final Map<String, String> _cameraSent = {};

  /// Switches each phone to the camera its source asks for (front or back),
  /// once per change and each time the source becomes active again.
  void applyPhoneCameras(Map<String, String> wanted) {
    _cameraSent.removeWhere((id, _) => !wanted.containsKey(id));
    for (final e in wanted.entries) {
      if (_cameraSent[e.key] == e.value) continue;
      _cameraSent[e.key] = e.value;
      _get(e.value).then((ok) {
        // Not reachable yet (phone app not started): try again on the next change.
        if (!ok && _cameraSent[e.key] == e.value) _cameraSent.remove(e.key);
      });
    }
  }
  final Map<String, NetworkFeed> _feeds = {};

  bool get supported => transport.supported;

  NetworkFeed? feed(String sourceId) => _feeds[sourceId];

  /// Makes exactly [wanted] (sourceId -> (kind, url)) connected.
  void sync(Map<String, (NetworkVideoKind, String)> wanted) {
    for (final id in _feeds.keys.toList()) {
      final w = wanted[id];
      final f = _feeds[id]!;
      if (w == null || w.$2 != f.url || w.$1 != f.kind) _close(id);
    }
    for (final e in wanted.entries) {
      if (_feeds.containsKey(e.key)) continue;
      final f = NetworkFeed(e.value.$2, e.value.$1);
      _feeds[e.key] = f;
      if (f.kind.isMjpeg) {
        _connectMjpeg(f);
      } else {
        _openPlayer(f);
      }
    }
  }

  /// Drops and reopens a feed (e.g. after the phone app was restarted).
  void reconnect(String sourceId) {
    final f = _feeds[sourceId];
    if (f == null) return;
    _close(sourceId);
    sync({sourceId: (f.kind, f.url)});
  }

  Future<void> _connectMjpeg(NetworkFeed f) async {
    if (f._closed) return;
    f.state = f.frame.value == null ? FeedState.connecting : FeedState.retrying;
    notifyListeners();
    try {
      final parser = MjpegParser((jpeg) => _onJpeg(f, jpeg));
      final stream = await _open(f.url, (cancel) => f._cancel = cancel);
      if (f._closed) {
        f._cancel?.call();
        return;
      }
      await for (final chunk in stream) {
        if (f._closed) break;
        parser.add(chunk);
      }
      if (!f._closed) throw StateError('The camera closed the connection');
    } catch (e) {
      if (f._closed) return;
      f.error = _friendly(e);
      f.state = FeedState.retrying;
      notifyListeners();
      f._retry = Timer(const Duration(seconds: 2), () => _connectMjpeg(f));
    }
  }

  Future<void> _onJpeg(NetworkFeed f, Uint8List jpeg) async {
    // Keep latency low: drop frames while the previous one is decoding.
    if (f._decoding || f._closed) return;
    f._decoding = true;
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      if (f._closed) {
        image.dispose();
        return;
      }
      final old = f.frame.value;
      f.frame.value = image;
      old?.dispose();
      f._frames++;
      final first = f.state != FeedState.live || f.width != image.width || f.height != image.height;
      f
        ..state = FeedState.live
        ..error = null
        ..width = image.width
        ..height = image.height;
      final secs = DateTime.now().difference(f._since).inMilliseconds / 1000;
      if (secs >= 1) {
        f.fps = f._frames / secs;
        f._frames = 0;
        f._since = DateTime.now();
        notifyListeners();
      } else if (first) {
        notifyListeners();
      }
    } catch (_) {
      // A corrupt frame: skip it.
    } finally {
      f._decoding = false;
    }
  }

  Future<void> _openPlayer(NetworkFeed f) async {
    final uri = Uri.tryParse(f.url);
    if (uri == null) {
      f
        ..state = FeedState.error
        ..error = 'Invalid URL';
      notifyListeners();
      return;
    }
    final c = VideoPlayerController.networkUrl(uri);
    f.player = c;
    notifyListeners();
    try {
      await c.initialize();
      if (f._closed) return;
      await c.setVolume(0); // network video audio isn't mixed (yet)
      await c.play();
      f
        ..state = FeedState.live
        ..width = c.value.size.width.round()
        ..height = c.value.size.height.round();
      // A live stream that errors or ends (camera off, Wi-Fi drop) is
      // reopened, like the MJPEG path does.
      void watch() {
        final v = c.value;
        if (f._closed || f.player != c || f.state != FeedState.live) return;
        if (v.hasError || v.isCompleted) {
          c.removeListener(watch);
          _retryPlayer(f, c);
        }
      }

      c.addListener(watch);
    } catch (e) {
      f
        ..state = FeedState.error
        ..error = _friendly(e);
      _retryPlayer(f, c, after: const Duration(seconds: 5));
    }
    notifyListeners();
  }

  void _retryPlayer(NetworkFeed f, VideoPlayerController c, {Duration after = const Duration(seconds: 2)}) {
    if (f._closed) return;
    if (f.state == FeedState.live) f.state = FeedState.retrying;
    notifyListeners();
    f._retry?.cancel();
    f._retry = Timer(after, () async {
      if (f._closed || f.player != c) return;
      f.player = null;
      await c.dispose();
      if (!f._closed) await _openPlayer(f);
    });
  }

  void _close(String id) {
    final f = _feeds.remove(id);
    if (f == null) return;
    f._closed = true;
    f._retry?.cancel();
    f._cancel?.call();
    f.player?.dispose();
    final img = f.frame.value;
    f.frame.value = null;
    img?.dispose();
    notifyListeners();
  }

  static String _friendly(Object e) {
    final s = '$e';
    if (s.contains('Connection refused')) {
      return 'Connection refused. Is the camera app open, and is the IP/port right?';
    }
    if (s.contains('timed out') || s.contains('TimeoutException')) {
      return 'No answer. Check that both devices are on the same Wi-Fi.';
    }
    if (s.contains('No route') || s.contains('Network is unreachable')) {
      return 'Network unreachable. Check the IP address and Wi-Fi.';
    }
    return s.replaceFirst('Exception: ', '');
  }

  @override
  void dispose() {
    for (final id in _feeds.keys.toList()) {
      _close(id);
    }
    super.dispose();
  }
}

/// Connects the Network Video sources that are on program/preview.
class NetworkVideoTracker {
  NetworkVideoTracker(this.studio, this.service) {
    studio.addListener(_sync);
    _sync();
  }

  final StudioController studio;
  final NetworkVideoService service;

  void _sync() {
    if (!service.supported) return;
    final wanted = <String, (NetworkVideoKind, String)>{};
    final cameras = <String, String>{};
    for (final s in studio.activeSources) {
      if (s.type != SourceType.networkVideo) continue;
      final url = networkVideoUrl(s.settings);
      if (url != null) wanted[s.id] = (NetworkVideoKind.fromName(s.settings['kind'] as String?), url);
      final cam = phoneCameraUrl(s.settings);
      if (cam != null) cameras[s.id] = cam;
    }
    service.applyPhoneCameras(cameras);
    service.sync(wanted);
  }

  void dispose() => studio.removeListener(_sync);
}
