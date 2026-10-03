// On-disk plugin storage and GitHub downloads (dart:io).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'plugin_manifest.dart';
import 'plugin_package.dart';

/// Where an installed plugin came from, for updates.
class InstallRecord {
  InstallRecord({required this.source, required this.installedAt, required this.sha256, this.ref});

  /// GitHub URL, or `file:<name>` for a zip picked from storage.
  final String source;
  final String? ref;
  final DateTime installedAt;
  final String sha256;

  bool get fromGitHub => source.startsWith('https://github.com/');

  Map<String, dynamic> toJson() => {
        'source': source,
        if (ref != null) 'ref': ref,
        'installedAt': installedAt.toIso8601String(),
        'sha256': sha256,
      };

  factory InstallRecord.fromJson(Map<String, dynamic> j) => InstallRecord(
        source: j['source'] as String? ?? '',
        ref: j['ref'] as String?,
        installedAt: DateTime.tryParse(j['installedAt'] as String? ?? '') ?? DateTime(2000),
        sha256: j['sha256'] as String? ?? '',
      );
}

class InstalledPlugin {
  InstalledPlugin(this.manifest, this.record, this.directory);

  final PluginManifest manifest;
  final InstallRecord record;
  final Directory directory;

  File file(String rel) => File('${directory.path}/$rel');
}

/// Plugins live in `<base>/<id>/`, with an `.install.json` beside the files.
class PluginStore {
  PluginStore(this.base);

  final Directory base;

  static const _recordFile = '.install.json';

  Future<List<InstalledPlugin>> list() async {
    if (!await base.exists()) return [];
    final out = <InstalledPlugin>[];
    await for (final e in base.list()) {
      if (e is! Directory || e.path.split(Platform.pathSeparator).last.startsWith('.')) continue;
      try {
        final manifest = PluginManifest.fromJson(
          jsonDecode(await File('${e.path}/$kManifestFile').readAsString()) as Map<String, dynamic>,
        );
        final recFile = File('${e.path}/$_recordFile');
        final record = await recFile.exists()
            ? InstallRecord.fromJson(jsonDecode(await recFile.readAsString()) as Map<String, dynamic>)
            : InstallRecord(source: 'unknown', installedAt: DateTime(2000), sha256: '');
        out.add(InstalledPlugin(manifest, record, e));
      } catch (_) {
        // A broken folder must not stop the app from starting.
      }
    }
    out.sort((a, b) => a.manifest.name.toLowerCase().compareTo(b.manifest.name.toLowerCase()));
    return out;
  }

  /// Writes the package next to the old version, then swaps it in, so a
  /// failed update never leaves a half-written plugin.
  Future<InstalledPlugin> install(PluginPackage pkg, {required String source, String? ref, List<int>? zipBytes}) async {
    await base.create(recursive: true);
    final id = pkg.manifest.id;
    final staging = Directory('${base.path}/.staging-$id');
    if (await staging.exists()) await staging.delete(recursive: true);
    for (final entry in pkg.files.entries) {
      final f = File('${staging.path}/${entry.key}');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(entry.value, flush: true);
    }
    final record = InstallRecord(
      source: source,
      ref: ref,
      installedAt: DateTime.now(),
      sha256: zipBytes == null ? '' : sha256.convert(zipBytes).toString(),
    );
    await File('${staging.path}/$_recordFile').writeAsString(jsonEncode(record.toJson()));

    final target = Directory('${base.path}/$id');
    final old = Directory('${base.path}/.old-$id');
    if (await old.exists()) await old.delete(recursive: true);
    if (await target.exists()) await target.rename(old.path);
    await staging.rename(target.path);
    if (await old.exists()) await old.delete(recursive: true);
    return InstalledPlugin(pkg.manifest, record, target);
  }

  Future<void> uninstall(String id) async {
    final d = Directory('${base.path}/$id');
    if (await d.exists()) await d.delete(recursive: true);
  }
}

class DownloadException implements Exception {
  DownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads plugin zips from GitHub. Base URLs are injectable for tests.
class GitHubClient {
  GitHubClient({
    this.apiBase = 'https://api.github.com',
    this.codeloadBase = 'https://codeload.github.com',
    HttpClient? http,
  }) : _http = http ?? HttpClient();

  final String apiBase;
  final String codeloadBase;
  final HttpClient _http;

  static const maxDownload = 64 << 20;

  /// Resolves which zip to fetch: an explicit ref, else the latest release
  /// (a `.zip` asset if it has one, otherwise its source zip), else the
  /// default branch. Returns the bytes and the resolved ref.
  Future<(Uint8List, String)> download(GitHubRef r) async {
    if (r.ref != null) {
      return (await _get('$codeloadBase/${r.owner}/${r.repo}/zip/${r.ref}'), r.ref!);
    }
    final release = await _getJson('$apiBase/repos/${r.owner}/${r.repo}/releases/latest', allow404: true);
    if (release != null) {
      final tag = release['tag_name'] as String? ?? 'latest';
      final assets = (release['assets'] as List? ?? const []).cast<Map>();
      final zipAsset = assets.where((a) => '${a['name']}'.toLowerCase().endsWith('.zip')).firstOrNull;
      // A packaged asset only makes sense for a repo-root plugin.
      if (zipAsset != null && r.subdir == null) {
        return (await _get('${zipAsset['browser_download_url']}'), tag);
      }
      return (await _get('$codeloadBase/${r.owner}/${r.repo}/zip/refs/tags/$tag'), tag);
    }
    final repo = await _getJson('$apiBase/repos/${r.owner}/${r.repo}');
    final branch = repo!['default_branch'] as String? ?? 'main';
    return (await _get('$codeloadBase/${r.owner}/${r.repo}/zip/refs/heads/$branch'), branch);
  }

  /// Version of the plugin at the latest release/default branch, for updates.
  Future<PluginPackage> fetchPackage(GitHubRef r) async {
    final (bytes, _) = await download(r);
    return PluginPackageReader.read(bytes, subdir: r.subdir);
  }

  Future<Map<String, dynamic>?> _getJson(String url, {bool allow404 = false}) async {
    final res = await _request(url, accept: 'application/vnd.github+json');
    if (res.statusCode == 404 && allow404) {
      await res.drain<void>();
      return null;
    }
    if (res.statusCode == 404) {
      await res.drain<void>();
      throw DownloadException('Repository not found (is it public?)');
    }
    if (res.statusCode == 403) {
      await res.drain<void>();
      throw DownloadException('GitHub rate limit reached, try again in a few minutes');
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw DownloadException('GitHub returned ${res.statusCode}');
    }
    return jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
  }

  Future<Uint8List> _get(String url) async {
    final res = await _request(url);
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw DownloadException(res.statusCode == 404 ? 'Not found: $url' : 'Download failed (${res.statusCode})');
    }
    final b = BytesBuilder(copy: false);
    await for (final chunk in res) {
      b.add(chunk);
      if (b.length > maxDownload) throw DownloadException('Download is too large');
    }
    return b.takeBytes();
  }

  Future<HttpClientResponse> _request(String url, {String? accept}) async {
    try {
      final req = await _http.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'OBSpad');
      if (accept != null) req.headers.set(HttpHeaders.acceptHeader, accept);
      return await req.close().timeout(const Duration(seconds: 30));
    } on SocketException catch (e) {
      throw DownloadException('No connection: ${e.message}');
    } on HandshakeException {
      throw DownloadException('Secure connection to GitHub failed');
    }
  }

  void close() => _http.close(force: true);
}
