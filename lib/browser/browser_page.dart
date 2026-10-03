import 'dart:typed_data';

import 'browser_page_stub.dart' if (dart.library.io) 'browser_page_io.dart' as impl;

/// An off-screen web page that can be snapshotted (Browser source).
abstract class BrowserPage {
  Future<void> start();

  /// PNG of the page (with transparency), or null if not ready.
  Future<Uint8List?> snapshot();
  Future<void> reload();
  Future<void> dispose();
}

/// Null where pages can't run (web build, tests).
BrowserPage? createBrowserPage({required String url, required int width, required int height, required String css}) =>
    impl.createBrowserPage(url: url, width: width, height: height, css: css);
