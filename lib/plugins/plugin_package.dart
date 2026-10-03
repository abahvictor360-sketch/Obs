// Locating plugins on GitHub and unpacking plugin zips. Pure Dart (no I/O).

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'plugin_manifest.dart';

/// A plugin location on GitHub. Accepts what people paste:
///   owner/repo
///   github.com/owner/repo(.git)
///   `https://github.com/owner/repo/tree/<ref>/<path/to/plugin>`
///   `https://github.com/owner/repo/releases/tag/<tag>`
class GitHubRef {
  GitHubRef({required this.owner, required this.repo, this.ref, this.subdir});

  final String owner;
  final String repo;

  /// Branch, tag or commit. Null = latest release, else the default branch.
  final String? ref;

  /// Folder inside the repo that holds the plugin (monorepos).
  final String? subdir;

  static final _name = RegExp(r'^[A-Za-z0-9_.-]+$');

  static GitHubRef parse(String input) {
    var s = input.trim();
    s = s.replaceFirst(RegExp(r'^(https?://)?(www\.)?github\.com/', caseSensitive: false), '');
    s = s.replaceFirst(RegExp(r'[?#].*$'), '');
    final parts = s.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) {
      throw PluginFormatException('Enter a GitHub repository, like owner/repo');
    }
    final owner = parts[0];
    final repo = parts[1].replaceFirst(RegExp(r'\.git$'), '');
    if (!_name.hasMatch(owner) || !_name.hasMatch(repo)) {
      throw PluginFormatException('"$input" is not a GitHub repository');
    }
    String? ref;
    String? subdir;
    if (parts.length >= 4 && (parts[2] == 'tree' || parts[2] == 'blob')) {
      ref = parts[3];
      if (parts.length > 4) subdir = parts.sublist(4).join('/');
    } else if (parts.length >= 5 && parts[2] == 'releases' && parts[3] == 'tag') {
      ref = parts[4];
    } else if (parts.length > 2) {
      throw PluginFormatException('Unsupported GitHub link: $input');
    }
    if (subdir != null && (subdir.split('/').contains('..'))) {
      throw PluginFormatException('Invalid path in link');
    }
    // A link to the manifest file itself means "this folder".
    if (subdir != null && subdir.endsWith(kManifestFile)) {
      subdir = subdir.substring(0, subdir.length - kManifestFile.length).replaceFirst(RegExp(r'/$'), '');
      if (subdir.isEmpty) subdir = null;
    }
    return GitHubRef(owner: owner, repo: repo, ref: ref, subdir: subdir);
  }

  String get displayName => '$owner/$repo${subdir == null ? '' : '/$subdir'}${ref == null ? '' : '@$ref'}';

  String get url =>
      'https://github.com/$owner/$repo${ref == null ? '' : '/tree/$ref'}${subdir == null ? '' : '/$subdir'}';

  GitHubRef withRef(String r) => GitHubRef(owner: owner, repo: repo, ref: r, subdir: subdir);
}

/// A validated plugin ready to be written to disk.
class PluginPackage {
  PluginPackage(this.manifest, this.files);

  final PluginManifest manifest;

  /// Relative path -> contents. Includes the manifest.
  final Map<String, Uint8List> files;

  int get totalBytes => files.values.fold(0, (n, f) => n + f.length);
}

class PluginPackageReader {
  static const maxFiles = 1000;
  static const maxTotalBytes = 64 << 20;

  /// Finds the plugin in a zip (a GitHub source zip has one top-level
  /// folder; release zips may not) and returns its validated files.
  static PluginPackage read(List<int> zipBytes, {String? subdir}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (_) {
      throw PluginFormatException('Not a valid zip file');
    }
    final files = archive.files.where((f) => f.isFile).toList();
    if (files.length > maxFiles) throw PluginFormatException('Too many files (max $maxFiles)');

    // Where is the manifest?
    final manifests = files
        .map((f) => _normalize(f.name))
        .where((p) => p == kManifestFile || p.endsWith('/$kManifestFile'))
        .toList()
      ..sort((a, b) => a.split('/').length.compareTo(b.split('/').length));
    String? manifestPath;
    if (subdir != null) {
      final want = subdir.replaceAll(RegExp(r'^/+|/+$'), '');
      manifestPath = manifests.where((p) {
        final dir = p.substring(0, p.length - kManifestFile.length);
        // GitHub zips prefix everything with "<repo>-<ref>/".
        return dir == '$want/' || dir.endsWith('/$want/');
      }).firstOrNull;
      if (manifestPath == null) throw PluginFormatException('No $kManifestFile in "$want"');
    } else {
      if (manifests.isEmpty) throw PluginFormatException('No $kManifestFile found. Is this an OBS Tablet plugin?');
      manifestPath = manifests.first;
    }
    final root = manifestPath.substring(0, manifestPath.length - kManifestFile.length);

    final out = <String, Uint8List>{};
    var total = 0;
    for (final f in files) {
      final p = _normalize(f.name);
      if (!p.startsWith(root)) continue;
      final rel = p.substring(root.length);
      if (rel.isEmpty) continue;
      _checkPath(rel);
      final bytes = f.content;
      total += bytes.length;
      if (total > maxTotalBytes) throw PluginFormatException('Plugin is too large (max 64 MB)');
      out[rel] = bytes;
    }

    final PluginManifest manifest;
    try {
      manifest = PluginManifest.fromJson(
        jsonDecode(utf8.decode(out[kManifestFile]!)) as Map<String, dynamic>,
      );
    } on PluginFormatException {
      rethrow;
    } catch (e) {
      throw PluginFormatException('$kManifestFile is not valid JSON');
    }
    for (final ref in [manifest.main, ...manifest.docks.map((d) => d.page)]) {
      if (ref != null && !out.containsKey(ref)) throw PluginFormatException('Missing file "$ref"');
    }
    return PluginPackage(manifest, out);
  }

  static String _normalize(String p) => p.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');

  /// Zip-slip protection: entries must stay inside the plugin folder.
  static void _checkPath(String rel) {
    if (rel.startsWith('/') ||
        rel.contains(':') ||
        rel.split('/').any((s) => s == '..' || s == '.') ||
        rel.length > 255) {
      throw PluginFormatException('Unsafe file path in plugin: $rel');
    }
  }
}
