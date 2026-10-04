import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'plugin_manager.dart';
import 'plugin_package.dart';
import 'plugin_store.dart';
import 'plugin_webview_host.dart';

PluginBackend createBackend() => IoPluginBackend();

class IoPluginBackend implements PluginBackend {
  IoPluginBackend({Directory? base, GitHubClient? github, this.hostFactory})
      : _dirOverride = base,
        _github = github ?? GitHubClient();

  final Directory? _dirOverride;
  Directory? _base;
  final GitHubClient _github;

  /// Overridable for tests (no WebView there).
  final PluginHost Function(PluginEntry, PluginHostCallbacks)? hostFactory;

  Future<Directory> _dir() async {
    if (_base != null) return _base!;
    if (_dirOverride != null) return _base = _dirOverride;
    final docs = await getApplicationDocumentsDirectory();
    return _base = Directory('${docs.path}/obs_tablet/plugins');
  }

  Future<PluginStore> _store() async => PluginStore(await _dir());

  @override
  bool get supported => true;

  @override
  Future<List<PluginEntry>> list() async => [
        for (final p in await (await _store()).list())
          PluginEntry(
            manifest: p.manifest,
            directory: p.directory.path,
            source: p.record.source,
            ref: p.record.ref,
            installedAt: p.record.installedAt,
          ),
      ];

  @override
  Future<PendingInstall> fetchGitHub(String url, {PluginEntry? existing}) async {
    final ref = GitHubRef.parse(url);
    final (pkg, bytes, resolved) = await _github.fetch(ref);
    return PendingInstall(package: pkg, source: ref.url, ref: resolved, zip: bytes, existing: existing);
  }

  @override
  PendingInstall readZip(Uint8List bytes, String fileName) =>
      PendingInstall(
        package: PluginPackageReader.read(bytes,
            name: fileName.split(RegExp(r'[/\\]')).last.replaceFirst(RegExp(r'\.zip$', caseSensitive: false), '')),
        source: 'file:$fileName',
        zip: bytes,
      );

  @override
  Future<PluginEntry> install(PendingInstall p) async {
    final i = await (await _store()).install(p.package, source: p.source, ref: p.ref, zipBytes: p.zip);
    return PluginEntry(
      manifest: i.manifest,
      directory: i.directory.path,
      source: i.record.source,
      ref: i.record.ref,
      installedAt: i.record.installedAt,
    );
  }

  @override
  Future<void> uninstall(String id) async => (await _store()).uninstall(id);

  File _stateFile(Directory d) => File('${d.path}/.state.json');

  @override
  Future<String?> readState() async {
    final f = _stateFile(await _dir());
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> writeState(String json) async {
    final d = await _dir();
    await d.create(recursive: true);
    await _stateFile(d).writeAsString(json);
  }

  @override
  Future<List<CatalogEntry>> fetchCatalog(String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw DownloadException('Catalog not available (${res.statusCode})');
      }
      final j = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      return (j['plugins'] as List? ?? const [])
          .map((e) => CatalogEntry.fromJson((e as Map).cast<String, dynamic>()))
          .where((e) => e.url.isNotEmpty)
          .toList();
    } on SocketException catch (e) {
      throw DownloadException('No connection: ${e.message}');
    } finally {
      client.close();
    }
  }

  @override
  PluginHost createHost(PluginEntry plugin, PluginHostCallbacks callbacks) =>
      hostFactory?.call(plugin, callbacks) ?? WebViewPluginHost(plugin, callbacks);
}
