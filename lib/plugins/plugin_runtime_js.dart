// JavaScript injected into every plugin page (sandbox runtime and docks).
// It defines the `obstablet` API that plugin authors use; see
// docs/PLUGINS.md.

const kPluginRuntimeJs = r'''
(function () {
  if (window.obstablet) return;
  var queue = [];
  var bridgeReady = false;
  function flush() {
    bridgeReady = true;
    var q = queue; queue = [];
    q.forEach(function (m) { m.resolve(window.flutter_inappwebview.callHandler('obst', JSON.stringify(m.msg))); });
  }
  window.addEventListener('flutterInAppWebViewPlatformReady', flush);
  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) setTimeout(flush, 0);
  function send(msg) {
    if (bridgeReady) return window.flutter_inappwebview.callHandler('obst', JSON.stringify(msg));
    return new Promise(function (resolve) { queue.push({ msg: msg, resolve: resolve }); });
  }

  var types = {};
  var instances = {};
  var listeners = {};

  function control(op, args) {
    var m = Object.assign({ t: 'control', op: op }, args || {});
    return send(m).then(function (r) {
      var res = typeof r === 'string' ? JSON.parse(r) : r;
      if (res && res.error) throw new Error(res.error);
      return res ? res.value : undefined;
    });
  }

  window.obstablet = {
    version: '1.0',
    /** Register a source type declared in obspad-plugin.json. */
    registerSource: function (type, impl) { types[type] = impl; },
    /** Events: sceneChanged, streamingChanged, recordingChanged. */
    on: function (event, cb) { (listeners[event] = listeners[event] || []).push(cb); },
    log: function () {
      send({ t: 'log', msg: Array.prototype.map.call(arguments, String).join(' ') });
    },
    /** Read-only studio state: {scenes, programScene, streaming, recording}. */
    getState: function () { return control('getState'); },
    /** Needs the "control" permission. */
    control: {
      switchScene: function (name) { return control('switchScene', { name: name }); },
      setSourceVisible: function (source, visible, scene) {
        return control('setSourceVisible', { source: source, visible: !!visible, scene: scene });
      },
      startStreaming: function () { return control('startStreaming'); },
      stopStreaming: function () { return control('stopStreaming'); },
      startRecording: function () { return control('startRecording'); },
      stopRecording: function () { return control('stopRecording'); }
    }
  };

  // Called by the app.
  window.__obst = {
    create: function (id, type, settings, w, h, fps) {
      var impl = types[type];
      if (!impl) { send({ t: 'error', id: id, msg: 'Unknown source type "' + type + '"' }); return; }
      var canvas = document.createElement('canvas');
      canvas.width = w; canvas.height = h;
      var last = 0, timer = null, gap = 1000 / Math.max(1, fps);
      var ctx = {
        id: id, canvas: canvas, width: w, height: h, settings: settings,
        /** Show what is on the canvas (throttled to the source's fps). */
        present: function () {
          var now = Date.now();
          if (now - last < gap) {
            if (!timer) timer = setTimeout(function () { timer = null; ctx.present(); }, gap - (now - last));
            return;
          }
          last = now;
          send({ t: 'frame', id: id, data: canvas.toDataURL('image/png') });
        },
        onSettings: function (cb) { ctx._onSettings = cb; }
      };
      instances[id] = { impl: impl, ctx: ctx };
      try { if (impl.create) impl.create(ctx); ctx.present(); }
      catch (e) { send({ t: 'error', id: id, msg: String(e && e.stack || e) }); }
    },
    update: function (id, settings) {
      var i = instances[id]; if (!i) return;
      i.ctx.settings = settings;
      try { if (i.ctx._onSettings) i.ctx._onSettings(settings); i.ctx.present(); }
      catch (e) { send({ t: 'error', id: id, msg: String(e) }); }
    },
    destroy: function (id) {
      var i = instances[id]; if (!i) return;
      try { if (i.impl.destroy) i.impl.destroy(i.ctx); } catch (e) {}
      delete instances[id];
    },
    emit: function (event, data) {
      (listeners[event] || []).forEach(function (cb) { try { cb(data); } catch (e) {} });
    }
  };

  window.addEventListener('error', function (e) { send({ t: 'error', msg: e.message + ' (' + e.filename + ':' + e.lineno + ')' }); });
  window.addEventListener('unhandledrejection', function (e) { send({ t: 'error', msg: 'Unhandled: ' + e.reason }); });
})();
''';

/// Page that hosts a plugin's main script. Network access is blocked by the
/// Content-Security-Policy unless the plugin has the "network" permission.
String pluginRuntimePage({required String mainScript, required bool network}) {
  final connect = network ? "connect-src * data: blob:; img-src * data: blob:;" : "connect-src 'none'; img-src 'self' data: blob:;";
  return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:; $connect">
</head><body>
<script src="$mainScript"></script>
</body></html>''';
}
