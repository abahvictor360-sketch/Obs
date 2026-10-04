// Plugin manifest: `obspad-plugin.json` at the root of a plugin.
//
// {
//   "id": "com.example.clock",          // reverse-DNS, unique
//   "name": "Clock",
//   "version": "1.2.0",                 // semver
//   "description": "A clock overlay",
//   "author": "Jane",
//   "homepage": "https://github.com/jane/obspad-clock",
//   "minAppVersion": "1.0.0",
//   "main": "main.js",                  // runs in the plugin's sandbox
//   "permissions": ["network", "control"],
//   "sources": [{
//     "type": "clock", "name": "Clock", "width": 800, "height": 200, "fps": 1,
//     "settings": [{"key": "format", "label": "Format", "type": "select",
//                   "default": "24h", "options": ["12h", "24h"]}]
//   }],
//   "docks": [{"id": "panel", "name": "Clock panel", "page": "dock.html"}]
// }

const kManifestFile = 'obspad-plugin.json';
const kAppVersion = '1.0.0';

class PluginFormatException implements Exception {
  PluginFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What a plugin may do. Shown to the user before installing.
enum PluginPermission {
  /// Talk to the internet (chat, alerts, APIs). Without it the sandbox blocks
  /// all network requests.
  network('Access the internet'),

  /// Switch scenes, show/hide sources, start/stop streaming and recording.
  control('Control the studio (scenes, sources, stream and recording)');

  const PluginPermission(this.description);
  final String description;
}

enum SettingType { text, number, bool, color, select }

class PluginSetting {
  PluginSetting({
    required this.key,
    required this.label,
    required this.type,
    this.defaultValue,
    this.options = const [],
    this.min,
    this.max,
  });

  final String key;
  final String label;
  final SettingType type;
  final Object? defaultValue;
  final List<String> options;
  final double? min, max;

  factory PluginSetting.fromJson(Map<String, dynamic> j) {
    final key = _str(j, 'key', pattern: _keyPattern);
    final type = SettingType.values.where((t) => t.name == j['type']).firstOrNull;
    if (type == null) throw PluginFormatException('Setting "$key": unknown type ${j['type']}');
    final options = (j['options'] as List?)?.map((e) => '$e').toList() ?? const [];
    if (type == SettingType.select && options.isEmpty) {
      throw PluginFormatException('Setting "$key": select needs options');
    }
    return PluginSetting(
      key: key,
      label: j['label'] as String? ?? key,
      type: type,
      defaultValue: j['default'],
      options: options,
      min: (j['min'] as num?)?.toDouble(),
      max: (j['max'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'type': type.name,
        if (defaultValue != null) 'default': defaultValue,
        if (options.isNotEmpty) 'options': options,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
      };
}

class PluginSourceType {
  PluginSourceType({
    required this.type,
    required this.name,
    this.width = 1280,
    this.height = 720,
    this.fps = 10,
    this.settings = const [],
  });

  final String type;
  final String name;
  final int width, height;

  /// Max frames per second the plugin can present.
  final int fps;
  final List<PluginSetting> settings;

  Map<String, dynamic> defaultSettings() => {
        for (final s in settings)
          if (s.defaultValue != null) s.key: s.defaultValue,
      };

  factory PluginSourceType.fromJson(Map<String, dynamic> j) {
    int dim(String k, int def, int max) {
      final v = (j[k] as num?)?.toInt() ?? def;
      if (v < 1 || v > max) throw PluginFormatException('Source "${j['type']}": $k must be 1..$max');
      return v;
    }

    return PluginSourceType(
      type: _str(j, 'type', pattern: _keyPattern),
      name: _str(j, 'name'),
      width: dim('width', 1280, 3840),
      height: dim('height', 720, 2160),
      fps: dim('fps', 10, 30),
      settings: (j['settings'] as List? ?? const [])
          .map((e) => PluginSetting.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'name': name,
        'width': width,
        'height': height,
        'fps': fps,
        'settings': settings.map((s) => s.toJson()).toList(),
      };
}

class PluginDock {
  PluginDock({required this.id, required this.name, required this.page});

  final String id, name, page;

  factory PluginDock.fromJson(Map<String, dynamic> j) => PluginDock(
        id: _str(j, 'id', pattern: _keyPattern),
        name: _str(j, 'name'),
        page: _relativePath(_str(j, 'page')),
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'page': page};
}

/// A web page shown as a Browser source (an OBS-style HTML overlay or widget).
class PluginOverlay {
  PluginOverlay({required this.name, required this.page, this.width = 1920, this.height = 1080});

  final String name;
  final String page;
  final int width, height;

  factory PluginOverlay.fromJson(Map<String, dynamic> j) => PluginOverlay(
        name: _str(j, 'name'),
        page: _relativePath(_str(j, 'page')),
        width: ((j['width'] as num?)?.toInt() ?? 1920).clamp(1, 3840),
        height: ((j['height'] as num?)?.toInt() ?? 1080).clamp(1, 2160),
      );

  Map<String, dynamic> toJson() => {'name': name, 'page': page, 'width': width, 'height': height};
}

class PluginManifest {
  PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.author = '',
    this.homepage,
    this.minAppVersion,
    this.main,
    this.permissions = const {},
    this.sources = const [],
    this.docks = const [],
    this.overlays = const [],
    this.luts = const [],
    this.media = const [],
    this.converted = false,
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String? homepage;
  final String? minAppVersion;

  /// Script loaded into the plugin's sandbox (relative path).
  final String? main;
  final Set<PluginPermission> permissions;
  final List<PluginSourceType> sources;
  final List<PluginDock> docks;

  /// Web pages to add as Browser sources.
  final List<PluginOverlay> overlays;

  /// LUT files (.cube / PNG) offered in the Apply LUT filter.
  final List<String> luts;

  /// Images and videos to add as Image / Media sources.
  final List<String> media;

  /// Made by OBSpad from a repo or zip without an obspad-plugin.json.
  final bool converted;

  /// Everything the plugin adds, for the install dialog and plugin list.
  List<String> get contents => [
        if (sources.isNotEmpty) 'Sources: ${sources.map((s) => s.name).join(', ')}',
        if (overlays.isNotEmpty) 'Overlays: ${overlays.map((o) => o.name).join(', ')}',
        if (docks.isNotEmpty) 'Docks: ${docks.map((d) => d.name).join(', ')}',
        if (luts.isNotEmpty) '${luts.length} LUT${luts.length == 1 ? '' : 's'}',
        if (media.isNotEmpty) '${media.length} image${media.length == 1 ? '' : 's'} and video${media.length == 1 ? '' : 's'}',
      ];

  PluginSourceType? sourceType(String type) => sources.where((s) => s.type == type).firstOrNull;

  factory PluginManifest.fromJson(Map<String, dynamic> j) {
    final id = _str(j, 'id', pattern: RegExp(r'^[a-z0-9]+([._-][a-z0-9]+)+$'));
    final version = _str(j, 'version');
    if (Version.tryParse(version) == null) throw PluginFormatException('version must be like 1.2.3');
    final minApp = j['minAppVersion'] as String?;
    if (minApp != null) {
      final need = Version.tryParse(minApp);
      if (need == null) throw PluginFormatException('minAppVersion must be like 1.2.3');
      if (need > Version.parse(kAppVersion)) {
        throw PluginFormatException('Needs OBSpad $minApp or newer');
      }
    }
    final perms = <PluginPermission>{};
    for (final p in (j['permissions'] as List? ?? const [])) {
      final perm = PluginPermission.values.where((x) => x.name == p).firstOrNull;
      if (perm == null) throw PluginFormatException('Unknown permission "$p"');
      perms.add(perm);
    }
    final sources = (j['sources'] as List? ?? const [])
        .map((e) => PluginSourceType.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    final docks = (j['docks'] as List? ?? const [])
        .map((e) => PluginDock.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    List<String> paths(String k) =>
        [for (final e in (j[k] as List? ?? const [])) _relativePath('$e')];
    final overlays = (j['overlays'] as List? ?? const [])
        .map((e) => PluginOverlay.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    final main = j['main'] as String?;
    if (sources.isNotEmpty && main == null) {
      throw PluginFormatException('Plugins with sources need a "main" script');
    }
    if (sources.map((s) => s.type).toSet().length != sources.length) {
      throw PluginFormatException('Duplicate source types');
    }
    return PluginManifest(
      id: id,
      name: _str(j, 'name'),
      version: version,
      description: j['description'] as String? ?? '',
      author: j['author'] as String? ?? '',
      homepage: j['homepage'] as String?,
      minAppVersion: minApp,
      main: main == null ? null : _relativePath(main),
      permissions: perms,
      sources: sources,
      docks: docks,
      overlays: overlays,
      luts: paths('luts'),
      media: paths('media'),
      converted: j['converted'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'description': description,
        'author': author,
        if (homepage != null) 'homepage': homepage,
        if (minAppVersion != null) 'minAppVersion': minAppVersion,
        if (main != null) 'main': main,
        'permissions': permissions.map((p) => p.name).toList(),
        'sources': sources.map((s) => s.toJson()).toList(),
        'docks': docks.map((d) => d.toJson()).toList(),
        if (overlays.isNotEmpty) 'overlays': overlays.map((o) => o.toJson()).toList(),
        if (luts.isNotEmpty) 'luts': luts,
        if (media.isNotEmpty) 'media': media,
        if (converted) 'converted': true,
      };
}

final _keyPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

String _str(Map<String, dynamic> j, String key, {RegExp? pattern}) {
  final v = j[key];
  if (v is! String || v.trim().isEmpty) throw PluginFormatException('Missing "$key"');
  if (pattern != null && !pattern.hasMatch(v)) throw PluginFormatException('Invalid "$key": $v');
  return v.trim();
}

/// Rejects absolute paths and `..` so a plugin can't point outside itself.
String _relativePath(String p) {
  final norm = p.replaceAll('\\', '/');
  if (norm.startsWith('/') || norm.split('/').any((s) => s == '..') || norm.contains(':')) {
    throw PluginFormatException('Invalid path "$p"');
  }
  return norm;
}

/// Minimal semantic version (major.minor.patch, optional -prerelease).
class Version implements Comparable<Version> {
  Version(this.major, this.minor, this.patch, [this.pre = '']);

  final int major, minor, patch;
  final String pre;

  static Version? tryParse(String s) {
    final m = RegExp(r'^v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?$').firstMatch(s.trim());
    if (m == null) return null;
    return Version(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3] ?? '0'), m[4] ?? '');
  }

  static Version parse(String s) => tryParse(s) ?? (throw FormatException('Bad version $s'));

  @override
  int compareTo(Version o) {
    for (final d in [major - o.major, minor - o.minor, patch - o.patch]) {
      if (d != 0) return d;
    }
    if (pre == o.pre) return 0;
    if (pre.isEmpty) return 1; // 1.0.0 > 1.0.0-beta
    if (o.pre.isEmpty) return -1;
    return pre.compareTo(o.pre);
  }

  bool operator >(Version o) => compareTo(o) > 0;
  bool operator <(Version o) => compareTo(o) < 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, pre);

  @override
  String toString() => '$major.$minor.$patch${pre.isEmpty ? '' : '-$pre'}';
}
