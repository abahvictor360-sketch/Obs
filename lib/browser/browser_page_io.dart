import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'browser_page.dart';

BrowserPage? createBrowserPage({required String url, required int width, required int height, required String css}) {
  // Only the Android and iPad apps have a WebView (not desktop test runs).
  if (!(Platform.isAndroid || Platform.isIOS)) return null;
  return _WebViewPage(url, width, height, css);
}

/// Headless WebView sized like the source, with a transparent background
/// (pages can be overlays) and the source's custom CSS.
class _WebViewPage implements BrowserPage {
  _WebViewPage(this.url, this.width, this.height, this.css);

  final String url, css;
  final int width, height;
  HeadlessInAppWebView? _view;
  InAppWebViewController? _controller;

  @override
  Future<void> start() async {
    final uri = url.startsWith('/') ? WebUri.uri(Uri.file(url)) : WebUri(url);
    final cssJs = 'var s=document.createElement("style");s.textContent=${jsonEncode(css)};'
        '(document.head||document.documentElement).appendChild(s);';
    _view = HeadlessInAppWebView(
      initialSize: Size(width.toDouble(), height.toDouble()),
      initialUrlRequest: URLRequest(url: uri),
      initialUserScripts: UnmodifiableListView([
        if (css.trim().isNotEmpty) UserScript(source: cssJs, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        allowFileAccess: url.startsWith('/'),
        allowFileAccessFromFileURLs: url.startsWith('/'),
        allowingReadAccessTo: url.startsWith('/') ? WebUri.uri(Uri.file(File(url).parent.path)) : null,
        useWideViewPort: false,
        supportZoom: false,
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (c) => _controller = c,
    );
    await _view!.run();
  }

  @override
  Future<Uint8List?> snapshot() async {
    final c = _controller;
    if (c == null) return null;
    return c.takeScreenshot(
      screenshotConfiguration: ScreenshotConfiguration(compressFormat: CompressFormat.PNG, afterScreenUpdates: true),
    );
  }

  @override
  Future<void> reload() async => _controller?.reload();

  @override
  Future<void> dispose() async {
    await _view?.dispose();
    _view = null;
    _controller = null;
  }
}
