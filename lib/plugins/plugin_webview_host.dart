import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'plugin_manager.dart';
import 'plugin_manifest.dart';
import 'plugin_runtime_js.dart';

/// Runs one plugin's `main` script in an invisible WebView. The page can
/// only reach the network if the plugin has the "network" permission, and
/// can only read its own folder.
class WebViewPluginHost implements PluginHost {
  WebViewPluginHost(this.plugin, this.callbacks);

  final PluginEntry plugin;
  final PluginHostCallbacks callbacks;

  HeadlessInAppWebView? _view;
  InAppWebViewController? _controller;
  final _loaded = Completer<void>();
  final List<String> _queue = [];
  bool _disposed = false;

  @override
  Future<void> start() async {
    final main = plugin.manifest.main;
    if (main == null) throw StateError('Plugin has no main script');
    final page = File('${plugin.directory}/.runtime.html');
    await page.writeAsString(pluginRuntimePage(
      mainScript: main,
      network: plugin.manifest.permissions.contains(PluginPermission.network),
    ));

    _view = HeadlessInAppWebView(
      initialSize: const Size(1, 1),
      initialUrlRequest: URLRequest(url: WebUri.uri(Uri.file(page.path))),
      initialUserScripts: UnmodifiableListView([
        UserScript(source: kPluginRuntimeJs, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        allowFileAccess: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: false,
        allowContentAccess: false,
        allowingReadAccessTo: WebUri.uri(Uri.directory(plugin.directory)),
        mediaPlaybackRequiresUserGesture: false,
        transparentBackground: true,
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (c) {
        _controller = c;
        c.addJavaScriptHandler(handlerName: 'obst', callback: _onMessage);
      },
      onLoadStop: (c, url) {
        if (!_loaded.isCompleted) _loaded.complete();
        final q = List.of(_queue);
        _queue.clear();
        q.forEach(_eval);
      },
      onConsoleMessage: (c, m) => callbacks.onLog(m.message),
      onReceivedError: (c, req, err) {
        if (req.isForMainFrame ?? false) callbacks.onError(null, 'Load error: ${err.description}');
      },
    );
    await _view!.run();
    await _loaded.future.timeout(const Duration(seconds: 15));
  }

  Future<Object?> _onMessage(List<dynamic> args) async {
    if (args.isEmpty) return null;
    final Map<String, dynamic> m;
    try {
      m = jsonDecode('${args.first}') as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    switch (m['t']) {
      case 'frame':
        final data = m['data'] as String? ?? '';
        final comma = data.indexOf(',');
        if (comma > 0) {
          try {
            callbacks.onFrame('${m['id']}', Uint8List.fromList(base64Decode(data.substring(comma + 1))));
          } catch (_) {}
        }
      case 'log':
        callbacks.onLog('${m['msg']}');
      case 'error':
        callbacks.onError(m['id'] as String?, '${m['msg']}');
      case 'control':
        try {
          final value = await callbacks.onControl('${m['op']}', m);
          return jsonEncode({'value': value});
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
    }
    return null;
  }

  void _call(String fn, List<Object?> args) {
    final js = 'window.__obst && window.__obst.$fn(${args.map(jsonEncode).join(',')});';
    if (_loaded.isCompleted) {
      _eval(js);
    } else {
      _queue.add(js);
    }
  }

  void _eval(String js) {
    if (_disposed) return;
    _controller?.evaluateJavascript(source: js).catchError((Object e) {
      callbacks.onError(null, 'Script error: $e');
      return null;
    });
  }

  @override
  void createInstance(String id, String type, Map<String, dynamic> settings, int width, int height, int fps) =>
      _call('create', [id, type, settings, width, height, fps]);

  @override
  void updateInstance(String id, Map<String, dynamic> settings) => _call('update', [id, settings]);

  @override
  void destroyInstance(String id) => _call('destroy', [id]);

  @override
  void emit(String event, Object? data) => _call('emit', [event, data]);

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _view?.dispose();
    _view = null;
  }
}
