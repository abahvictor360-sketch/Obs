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
  ///
  /// Without an obspad-plugin.json (most OBS plugins and overlays on
  /// GitHub), the contents are converted: web pages become overlays (Browser
  /// sources) or docks, .cube files LUTs, and images/videos media. [name],
  /// [id] and [version] name the converted plugin.
  static PluginPackage read(List<int> zipBytes, {String? subdir, String? name, String? id, String? version}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (_) {
      throw PluginFormatException('Not a valid zip file');
    }
    final files = archive.files.where((f) => f.isFile).toList();
    if (files.length > maxFiles * 20) throw PluginFormatException('Too many files');

    // Where is the manifest?
    final manifests = files
        .map((f) => _normalize(f.name))
        .where((p) => p == kManifestFile || p.endsWith('/$kManifestFile'))
        .toList()
      ..sort((a, b) => a.split('/').length.compareTo(b.split('/').length));
    String? manifestPath;
    final want = subdir?.replaceAll(RegExp(r'^/+|/+$'), '');
    if (want != null) {
      manifestPath = manifests.where((p) {
        final dir = p.substring(0, p.length - kManifestFile.length);
        // GitHub zips prefix everything with "<repo>-<ref>/".
        return dir == '$want/' || dir.endsWith('/$want/');
      }).firstOrNull;
    } else {
      manifestPath = manifests.firstOrNull;
    }
    if (manifestPath == null) {
      return PluginConverter.convert(files, subdir: want, name: name, id: id, version: version);
    }
    if (files.length > maxFiles) throw PluginFormatException('Too many files (max $maxFiles)');
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
    _checkRefs(manifest, out);
    return PluginPackage(manifest, out);
  }

  static void _checkRefs(PluginManifest manifest, Map<String, Uint8List> out) {
    for (final ref in [
      manifest.main,
      ...manifest.docks.map((d) => d.page),
      ...manifest.overlays.map((o) => o.page),
      ...manifest.luts,
      ...manifest.media,
    ]) {
      if (ref != null && !out.containsKey(ref)) throw PluginFormatException('Missing file "$ref"');
    }
  }

  static String normalize(String p) => _normalize(p);

  static String _normalize(String p) => p.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');

  /// Zip-slip protection: entries must stay inside the plugin folder.
  static void checkPath(String rel) => _checkPath(rel);

  static void _checkPath(String rel) {
    if (rel.startsWith('/') ||
        rel.contains(':') ||
        rel.split('/').any((s) => s == '..' || s == '.') ||
        rel.length > 255) {
      throw PluginFormatException('Unsafe file path in plugin: $rel');
    }
  }
}

/// Turns a repo or zip that isn't an OBSpad plugin into one, from what it
/// contains. Most "OBS plugins" on GitHub are one of:
///  - web overlays / widgets / control panels (HTML): usable here,
///  - LUT packs (.cube), overlay and stinger packs (images, videos): usable,
///  - native plugins (C/C++, .dll/.so/.dylib) or OBS Lua/Python scripts:
///    built for OBS Studio on a computer, so they can't run on a tablet.
class PluginConverter {
  static const maxPages = 24;
  static const maxLuts = 200;
  static const maxMedia = 80;

  static const _skipDirs = {'node_modules', '.git', '.github', '.vscode', '.idea', '__macosx', 'vendor'};
  static const _binaryExt = {'dll', 'so', 'dylib', 'exe', 'lib', 'a', 'o', 'obj', 'pdb', 'msi', 'pkg', 'dmg', 'deb', 'rpm'};
  static const _imageExt = {'png', 'jpg', 'jpeg', 'gif', 'webp'};
  static const _videoExt = {'webm', 'mp4', 'mov', 'm4v'};
  static final _dockName = RegExp(r'(dock|panel|control|remote|dashboard|admin)', caseSensitive: false);

  static String _ext(String p) {
    final name = p.split('/').last;
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  static PluginPackage convert(List<ArchiveFile> files, {String? subdir, String? name, String? id, String? version}) {
    final paths = {for (final f in files) PluginPackageReader.normalize(f.name): f};

    // The folder to convert: the requested subfolder, or the zip's single
    // top-level folder (GitHub zips), or everything.
    var root = '';
    if (subdir != null && subdir.isNotEmpty) {
      final hit = paths.keys.map((p) {
        final i = p.indexOf('$subdir/');
        return i == 0 || (i > 0 && p[i - 1] == '/') ? p.substring(0, i + subdir.length + 1) : null;
      }).whereType<String>().firstOrNull;
      if (hit == null) throw PluginFormatException('Nothing found in "$subdir"');
      root = hit;
    } else {
      final tops = paths.keys.map((p) => p.contains('/') ? p.substring(0, p.indexOf('/') + 1) : '').toSet();
      if (tops.length == 1 && tops.first.isNotEmpty) root = tops.first;
    }

    final rel = <String, ArchiveFile>{};
    for (final e in paths.entries) {
      if (!e.key.startsWith(root)) continue;
      final r = e.key.substring(root.length);
      if (r.isEmpty) continue;
      final dirs = r.split('/')..removeLast();
      if (dirs.any((d) => _skipDirs.contains(d.toLowerCase()))) continue;
      rel[r] = e.value;
    }

    int depth(String p) => '/'.allMatches(p).length;
    final html = rel.keys.where((p) => const {'html', 'htm'}.contains(_ext(p))).toList()
      ..sort((a, b) => depth(a) != depth(b) ? depth(a).compareTo(depth(b)) : a.compareTo(b));
    final luts = rel.keys
        .where((p) => _ext(p) == 'cube' || (_ext(p) == 'png' && RegExp(r'(^|/)luts?/', caseSensitive: false).hasMatch(p)))
        .toList()
      ..sort();
    final media = html.isEmpty
        ? (rel.keys
            .where((p) => (_imageExt.contains(_ext(p)) || _videoExt.contains(_ext(p))) && !luts.contains(p))
            .toList()
          ..sort())
        : <String>[];

    if (html.isEmpty && luts.isEmpty && media.isEmpty) throw PluginFormatException(_whyUnusable(rel.keys));

    // Files to keep: everything but compiled binaries (a web page may use
    // any of its folder's files).
    final out = <String, Uint8List>{};
    var total = 0;
    for (final e in rel.entries) {
      if (_binaryExt.contains(_ext(e.key))) continue;
      if (e.key == kManifestFile) continue;
      PluginPackageReader.checkPath(e.key);
      final bytes = e.value.content;
      total += bytes.length;
      if (total > PluginPackageReader.maxTotalBytes) throw PluginFormatException('Plugin is too large (max 64 MB)');
      out[e.key] = bytes;
    }
    if (out.length > PluginPackageReader.maxFiles) {
      throw PluginFormatException('Too many files (max ${PluginPackageReader.maxFiles})');
    }

    String title(String page) {
      final text = utf8.decode(out[page] ?? const [], allowMalformed: true);
      final t = RegExp(r'<title[^>]*>([^<]{1,80})</title>', caseSensitive: false).firstMatch(text)?[1]?.trim();
      if (t != null && t.isNotEmpty) return _unescape(t);
      final parts = page.split('/');
      final file = parts.last.replaceFirst(RegExp(r'\.html?$', caseSensitive: false), '');
      final base = file.toLowerCase() == 'index' && parts.length > 1 ? parts[parts.length - 2] : file;
      return _pretty(base.toLowerCase() == 'index' ? (name ?? 'Overlay') : base);
    }

    final overlays = <PluginOverlay>[];
    final docks = <PluginDock>[];
    final used = <String>{};
    for (final page in html.take(maxPages)) {
      final t = title(page);
      if (_dockName.hasMatch(page)) {
        var key = t.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
        if (key.isEmpty) key = 'dock';
        if (key.length > 60) key = key.substring(0, 60);
        while (!used.add(key)) {
          key = '$key-${used.length}';
        }
        docks.add(PluginDock(id: key, name: t, page: page));
      } else {
        overlays.add(PluginOverlay(name: t, page: page));
      }
    }
    final usesNetwork = out.entries.any((e) =>
        const {'html', 'htm', 'js'}.contains(_ext(e.key)) &&
        utf8.decode(e.value, allowMalformed: true).contains(RegExp(r'https?://|wss?://')));

    final manifest = PluginManifest(
      id: _id(id ?? 'zip.${name ?? 'plugin'}'),
      name: name == null ? 'Plugin' : _pretty(name),
      version: Version.tryParse(version ?? '')?.toString() ?? '1.0.0',
      description: 'Converted by OBSpad (no $kManifestFile in this package).',
      permissions: {if (usesNetwork && docks.isNotEmpty) PluginPermission.network},
      docks: docks,
      overlays: overlays,
      luts: luts.take(maxLuts).toList(),
      media: media.take(maxMedia).toList(),
      converted: true,
    );
    out[kManifestFile] = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest.toJson())));
    PluginPackageReader._checkRefs(manifest, out);
    return PluginPackage(manifest, out);
  }

  /// Why a package has nothing OBSpad can use, in the user's terms.
  static String _whyUnusable(Iterable<String> paths) {
    final exts = paths.map(_ext).toSet();
    final names = paths.map((p) => p.split('/').last.toLowerCase()).toSet();
    const usable = 'OBSpad can install plugins made of web pages (overlays, widgets, docks), LUTs (.cube), '
        'images and videos.';
    if (exts.intersection(const {'dll', 'so', 'dylib', 'c', 'cpp', 'cc', 'h', 'hpp'}).isNotEmpty ||
        names.contains('cmakelists.txt') ||
        paths.any((p) => p.contains('.plugin/'))) {
      return 'This is a native OBS Studio plugin (compiled C/C++ for Windows, macOS or Linux), so it can\'t run '
          'on a tablet. $usable';
    }
    if (exts.contains('lua') || exts.contains('py')) {
      return 'This is an OBS Studio script (Lua or Python), which only runs inside OBS on a computer. $usable';
    }
    if (exts.intersection(const {'shader', 'effect', 'hlsl'}).isNotEmpty) {
      return 'This is a set of OBS shader effects, which OBSpad can\'t run. $usable';
    }
    return 'Nothing OBSpad can use was found. $usable';
  }

  static String _id(String raw) {
    final parts = raw
        .toLowerCase()
        .split('.')
        .map((p) => p.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), ''))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length < 2) parts.insert(0, 'plugin');
    return parts.join('.');
  }

  static String _pretty(String s) {
    final words = s
        .replaceAll(RegExp(r'[-_.]+'), ' ')
        .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
        .trim()
        .split(RegExp(r'\s+'));
    return words.where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}
