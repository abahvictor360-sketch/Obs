import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/studio_controller.dart';
import 'browser_page.dart';

typedef BrowserPageFactory = BrowserPage? Function({
  required String url,
  required int width,
  required int height,
  required String css,
});

/// Live state of one Browser source: the latest snapshot of its page.
class BrowserFeed extends ChangeNotifier {
  ui.Image? image;
  String? error;
  bool loading = true;

  void _set(ui.Image img) {
    final old = image;
    image = img;
    loading = false;
    error = null;
    notifyListeners();
    // Let the frame that still shows the old image finish first.
    if (old != null) Timer(const Duration(milliseconds: 200), old.dispose);
  }

  void _fail(String message) {
    error = message;
    loading = false;
    notifyListeners();
  }

  void _clear() {
    final old = image;
    image = null;
    notifyListeners();
    old?.dispose();
  }
}

class _Running {
  _Running(this.page, this.key, this.fps);
  final BrowserPage page;
  final String key;
  final int fps;
  final feed = BrowserFeed();
  Timer? timer;
  bool busy = false;
}

/// Runs the web pages of Browser sources off screen and snapshots them at the
/// source's frame rate, like OBS's browser source (CEF). Pages run while
/// their source is in program or preview, or always if "Shut down source
/// when not visible" is off.
class BrowserSourceService {
  BrowserSourceService({BrowserPageFactory? factory}) : _factory = factory ?? createBrowserPage;

  static final instance = BrowserSourceService();

  /// Maps a source's URL to the page to load: plugin pages
  /// (`obspad-plugin://<id>/<page>`) resolve to the installed files ('' if
  /// the plugin is gone). Set by the app.
  static String Function(String url) urlResolver = _sameUrl;
  static String _sameUrl(String url) => url;

  final BrowserPageFactory _factory;
  final Map<String, _Running> _running = {};

  /// Feed for a source (null when its page isn't running).
  BrowserFeed? feed(String sourceId) => _running[sourceId]?.feed;

  late final bool supported = _factory(url: 'about:blank', width: 1, height: 1, css: '') != null;

  static String _key(Map<String, dynamic> s) =>
      '${s['url']}|${s['width']}|${s['height']}|${s['css']}|${s['fps']}|${s['refresh'] ?? 0}';

  /// Starts pages for [wanted] sources and stops the others.
  void sync(Iterable<Source> wanted) {
    final ids = {for (final s in wanted) s.id};
    for (final id in _running.keys.toList()) {
      if (!ids.contains(id)) _stop(id);
    }
    for (final s in wanted) {
      final key = _key(s.settings);
      final cur = _running[s.id];
      if (cur != null && cur.key == key) continue;
      if (cur != null) _stop(s.id);
      _start(s, key);
    }
  }

  void _start(Source s, String key) {
    final url = urlResolver((s.settings['url'] as String? ?? '').trim());
    if (url.isEmpty) return;
    final w = ((s.settings['width'] as num?)?.toInt() ?? 1280).clamp(16, 3840);
    final h = ((s.settings['height'] as num?)?.toInt() ?? 720).clamp(16, 2160);
    final fps = ((s.settings['fps'] as num?)?.toInt() ?? 15).clamp(1, 30);
    final page = _factory(url: url, width: w, height: h, css: s.settings['css'] as String? ?? '');
    if (page == null) return;
    final r = _Running(page, key, fps);
    _running[s.id] = r;
    page.start().then((_) {
      if (_running[s.id] != r) return;
      r.timer = Timer.periodic(Duration(milliseconds: 1000 ~/ fps), (_) => _grab(r));
    }).catchError((Object e) {
      r.feed._fail('Could not load page: $e');
    });
  }

  Future<void> _grab(_Running r) async {
    if (r.busy) return;
    r.busy = true;
    try {
      final png = await r.page.snapshot();
      if (png == null || png.isEmpty) return;
      final img = await _decode(png);
      if (r.timer == null) {
        img.dispose();
        return;
      }
      r.feed._set(img);
    } catch (e) {
      debugPrint('Browser source snapshot failed: $e');
    } finally {
      r.busy = false;
    }
  }

  static Future<ui.Image> _decode(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// Reloads the page (OBS's "Refresh cache of current page").
  Future<void> reload(String sourceId) async => _running[sourceId]?.page.reload();

  void _stop(String id) {
    final r = _running.remove(id);
    if (r == null) return;
    r.timer?.cancel();
    r.timer = null;
    r.page.dispose();
    r.feed._clear();
  }

  void dispose() {
    for (final id in _running.keys.toList()) {
      _stop(id);
    }
  }

  @visibleForTesting
  int get runningCount => _running.length;

  @visibleForTesting
  Future<void> debugGrab(String sourceId) async {
    final r = _running[sourceId];
    if (r != null) await _grab(r);
  }
}

/// Starts/stops Browser source pages as scenes change.
class BrowserSourceTracker {
  BrowserSourceTracker(this.studio, this.service) {
    studio.addListener(_sync);
    _sync();
  }

  final StudioController studio;
  final BrowserSourceService service;

  void _sync() {
    final wanted = <String, Source>{};
    for (final s in studio.sources) {
      if (s.type == SourceType.browser && s.settings['shutdown'] == false) wanted[s.id] = s;
    }
    for (final s in studio.activeSources) {
      if (s.type == SourceType.browser) wanted[s.id] = s;
    }
    service.sync(wanted.values);
  }

  void dispose() => studio.removeListener(_sync);
}
