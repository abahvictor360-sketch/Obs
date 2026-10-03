import 'dart:typed_data';

import 'plugin_manager.dart';

PluginBackend createBackend() => _Unsupported();

class _Unsupported implements PluginBackend {
  Never _no() => throw UnsupportedError('Plugins are available in the Android and iPad apps');

  @override
  bool get supported => false;
  @override
  Future<List<PluginEntry>> list() async => [];
  @override
  Future<PendingInstall> fetchGitHub(String url, {PluginEntry? existing}) async => _no();
  @override
  PendingInstall readZip(Uint8List bytes, String fileName) => _no();
  @override
  Future<PluginEntry> install(PendingInstall p) async => _no();
  @override
  Future<void> uninstall(String id) async {}
  @override
  Future<String?> readState() async => null;
  @override
  Future<void> writeState(String json) async {}
  @override
  Future<List<CatalogEntry>> fetchCatalog(String url) async => _no();
  @override
  PluginHost createHost(PluginEntry plugin, PluginHostCallbacks callbacks) => _no();
}
