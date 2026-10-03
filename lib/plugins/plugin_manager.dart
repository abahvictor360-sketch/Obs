import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'plugin_manifest.dart';
import 'plugin_package.dart';
import 'plugin_platform_stub.dart' if (dart.library.io) 'plugin_platform_io.dart' as platform;

/// A plugin on disk (platform-neutral view of an installed plugin).
class PluginEntry {
  PluginEntry({
    required this.manifest,
    required this.directory,
    required this.source,
    this.ref,
    required this.installedAt,
  });

  final PluginManifest manifest;
  final String directory;

  /// GitHub URL or `file:<name>`.
  final String source;
  final String? ref;
  final DateTime installedAt;

  bool get fromGitHub => source.startsWith('https://github.com/');
}

/// A downloaded, validated plugin waiting for the user's confirmation.
class PendingInstall {
  PendingInstall({required this.package, required this.source, this.ref, required this.zip, this.existing});

  final PluginPackage package;
  final String source;
  final String? ref;
  final Uint8List zip;

  /// Set when this would update an installed plugin.
  final PluginEntry? existing;

  PluginManifest get manifest => package.manifest;
  bool get isUpdate => existing != null;
}

class CatalogEntry {
  CatalogEntry({required this.name, required this.url, this.description = '', this.author = ''});

  final String name, url, description, author;

  factory CatalogEntry.fromJson(Map<String, dynamic> j) => CatalogEntry(
        name: j['name'] as String? ?? '?',
        url: j['url'] as String? ?? '',
        description: j['description'] as String? ?? '',
        author: j['author'] as String? ?? '',
      );
}

/// Callbacks from a plugin sandbox to the app.
class PluginHostCallbacks {
  PluginHostCallbacks({required this.onFrame, required this.onLog, required this.onError, required this.onControl});

  final void Function(String instanceId, Uint8List png) onFrame;
  final void Function(String message) onLog;
  final void Function(String? instanceId, String message) onError;

  /// Returns a JSON-encodable value or throws.
  final Future<Object?> Function(String op, Map<String, dynamic> args) onControl;
}

/// One plugin's sandbox (a headless WebView on Android/iOS).
abstract class PluginHost {
  Future<void> start();
  void createInstance(String id, String type, Map<String, dynamic> settings, int width, int height, int fps);
  void updateInstance(String id, Map<String, dynamic> settings);
  void destroyInstance(String id);
  void emit(String event, Object? data);
  Future<void> dispose();
}

/// Storage, downloads and sandboxes. Real on Android/iOS, unsupported on web.
abstract class PluginBackend {
  bool get supported;
  Future<List<PluginEntry>> list();
  Future<PendingInstall> fetchGitHub(String url, {PluginEntry? existing});
  PendingInstall readZip(Uint8List bytes, String fileName);
  Future<PluginEntry> install(PendingInstall p);
  Future<void> uninstall(String id);
  Future<String?> readState();
  Future<void> writeState(String json);
  Future<List<CatalogEntry>> fetchCatalog(String url);
  PluginHost createHost(PluginEntry plugin, PluginHostCallbacks callbacks);
}

PluginBackend createPlatformPluginBackend() => platform.createBackend();

/// Plugins compiled into the app (no download needed).
class BuiltinPlugin {
  const BuiltinPlugin({required this.id, required this.name, required this.description, this.defaultEnabled = false});

  final String id, name, description;
  final bool defaultEnabled;
}

const ndiBuiltin = BuiltinPlugin(
  id: 'builtin.ndi-output',
  name: 'NDI® Output (DistroAV)',
  description: 'Sends the program to your network as an NDI source, like DistroAV\'s Main Output. '
      'Receive it in vMix, OBS with DistroAV, NDI Studio Monitor, TriCaster and more.',
);

const kBuiltinPlugins = [ndiBuiltin];

const kDefaultCatalogUrl = 'https://raw.githubusercontent.com/abahvictor360-sketch/Obs/HEAD/plugins/catalog.json';

/// Owns installed plugins, which are enabled, their sandboxes and the frames
/// their sources produce.
class PluginManager extends ChangeNotifier {
  PluginManager(this.backend);

  final PluginBackend backend;

  List<PluginEntry> plugins = [];
  final Map<String, bool> _enabled = {};
  final Map<String, Map<String, dynamic>> _builtinSettings = {};
  String catalogUrl = kDefaultCatalogUrl;

  /// Recent log/error lines per plugin, for the plugin details screen.
  final Map<String, List<String>> logs = {};

  final Map<String, PluginHost> _hosts = {};

  /// sourceId -> (pluginId, type, settings) of live plugin source instances.
  final Map<String, _Instance> _instances = {};
  final Map<String, ValueNotifier<ui.Image?>> _frames = {};
  final Map<String, String> instanceErrors = {};

  /// Wired up by the app: performs studio actions for "control" plugins.
  Future<Object?> Function(String op, Map<String, dynamic> args)? controlHandler;

  bool get supported => backend.supported;

  Future<void> load() async {
    if (!supported) return;
    try {
      final raw = await backend.readState();
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        (j['enabled'] as Map? ?? {}).forEach((k, v) => _enabled['$k'] = v == true);
        (j['builtinSettings'] as Map? ?? {}).forEach(
          (k, v) => _builtinSettings['$k'] = (v as Map).cast<String, dynamic>(),
        );
        catalogUrl = j['catalogUrl'] as String? ?? catalogUrl;
      }
    } catch (e) {
      debugPrint('Plugin state unreadable: $e');
    }
    plugins = await backend.list();
    notifyListeners();
  }

  Future<void> _saveState() => backend.writeState(jsonEncode({
        'enabled': _enabled,
        'builtinSettings': _builtinSettings,
        'catalogUrl': catalogUrl,
      }));

  bool isEnabled(String id) {
    final builtin = kBuiltinPlugins.where((b) => b.id == id).firstOrNull;
    return _enabled[id] ?? builtin?.defaultEnabled ?? true;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    _enabled[id] = enabled;
    if (!enabled) await _stopHost(id);
    notifyListeners();
    await _saveState();
  }

  Map<String, dynamic> builtinSettings(String id) => _builtinSettings[id] ?? {};

  Future<void> setBuiltinSettings(String id, Map<String, dynamic> values) async {
    _builtinSettings[id] = {...builtinSettings(id), ...values};
    notifyListeners();
    await _saveState();
  }

  Future<void> setCatalogUrl(String url) async {
    catalogUrl = url.trim().isEmpty ? kDefaultCatalogUrl : url.trim();
    notifyListeners();
    await _saveState();
  }

  PluginEntry? plugin(String id) => plugins.where((p) => p.manifest.id == id).firstOrNull;

  /// All source types offered by enabled plugins.
  List<(PluginEntry, PluginSourceType)> get sourceTypes => [
        for (final p in plugins)
          if (isEnabled(p.manifest.id))
            for (final s in p.manifest.sources) (p, s),
      ];

  // ---------------------------------------------------------------------------
  // Install / update / remove

  Future<PendingInstall> fetchFromGitHub(String url) {
    final ref = GitHubRef.parse(url);
    final existing = plugins.where((p) => p.fromGitHub && GitHubRef.parse(p.source).displayName.split('@').first ==
        ref.displayName.split('@').first).firstOrNull;
    return backend.fetchGitHub(url, existing: existing);
  }

  PendingInstall readZip(Uint8List bytes, String fileName) => backend.readZip(bytes, fileName);

  /// Downloads the plugin's source again; returns a pending update if newer.
  Future<PendingInstall?> checkUpdate(PluginEntry p) async {
    if (!p.fromGitHub) return null;
    final ref = GitHubRef.parse(p.source);
    // Follow releases/default branch rather than the pinned ref.
    final latest = GitHubRef(owner: ref.owner, repo: ref.repo, subdir: ref.subdir);
    final pending = await backend.fetchGitHub(latest.url, existing: p);
    final newer = Version.parse(pending.manifest.version) > Version.parse(p.manifest.version);
    return newer ? pending : null;
  }

  Future<PluginEntry> install(PendingInstall pending) async {
    final id = pending.manifest.id;
    await _stopHost(id);
    final entry = await backend.install(pending);
    plugins = await backend.list();
    _enabled.putIfAbsent(id, () => true);
    await _saveState();
    _restartInstancesOf(id);
    notifyListeners();
    return entry;
  }

  Future<void> uninstall(String id) async {
    await _stopHost(id);
    await backend.uninstall(id);
    plugins = await backend.list();
    _enabled.remove(id);
    await _saveState();
    notifyListeners();
  }

  Future<List<CatalogEntry>> fetchCatalog() => backend.fetchCatalog(catalogUrl);

  // ---------------------------------------------------------------------------
  // Source instances

  ValueListenable<ui.Image?> frameFor(String sourceId) =>
      _frames.putIfAbsent(sourceId, () => ValueNotifier<ui.Image?>(null));

  /// Makes exactly [wanted] (sourceId -> (pluginId, type, settings)) live.
  Future<void> syncInstances(Map<String, (String, String, Map<String, dynamic>)> wanted) async {
    for (final id in _instances.keys.toList()) {
      final w = wanted[id];
      final cur = _instances[id]!;
      if (w == null || w.$1 != cur.pluginId || w.$2 != cur.type || !isEnabled(cur.pluginId)) {
        _hosts[cur.pluginId]?.destroyInstance(id);
        _instances.remove(id);
      } else if (!mapEquals(w.$3, cur.settings)) {
        cur.settings = Map.of(w.$3);
        _hosts[cur.pluginId]?.updateInstance(id, cur.settings);
      }
    }
    for (final e in wanted.entries) {
      if (_instances.containsKey(e.key)) continue;
      final (pluginId, type, settings) = e.value;
      final plugin = this.plugin(pluginId);
      final st = plugin?.manifest.sourceType(type);
      if (plugin == null || st == null || !isEnabled(pluginId)) continue;
      final host = await _hostFor(plugin);
      if (host == null) continue;
      _instances[e.key] = _Instance(pluginId, type, Map.of(settings));
      host.createInstance(e.key, type, {...st.defaultSettings(), ...settings}, st.width, st.height, st.fps);
    }
  }

  /// Broadcasts a studio event to every running plugin.
  void emit(String event, Object? data) {
    for (final h in _hosts.values) {
      h.emit(event, data);
    }
  }

  Future<PluginHost?> _hostFor(PluginEntry p) async {
    final id = p.manifest.id;
    final existing = _hosts[id];
    if (existing != null) return existing;
    final host = backend.createHost(
      p,
      PluginHostCallbacks(
        onFrame: _onFrame,
        onLog: (m) => _log(id, m),
        onError: (instance, m) {
          _log(id, 'ERROR: $m');
          if (instance != null) instanceErrors[instance] = m;
          notifyListeners();
        },
        onControl: (op, args) => control(p, op, args),
      ),
    );
    _hosts[id] = host;
    try {
      await host.start();
    } catch (e) {
      _log(id, 'ERROR: could not start: $e');
      _hosts.remove(id);
      return null;
    }
    return host;
  }

  /// Runs a studio action for [p], enforcing its permissions.
  Future<Object?> control(PluginEntry p, String op, Map<String, dynamic> args) async {
    final handler = controlHandler;
    if (handler == null) throw StateError('Studio not ready');
    if (op != 'getState' && !p.manifest.permissions.contains(PluginPermission.control)) {
      throw StateError('"${p.manifest.name}" does not have the "control" permission');
    }
    return handler(op, args);
  }

  Future<void> _onFrame(String instanceId, Uint8List png) async {
    try {
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final n = _frames.putIfAbsent(instanceId, () => ValueNotifier<ui.Image?>(null));
      final old = n.value;
      n.value = frame.image;
      old?.dispose();
      instanceErrors.remove(instanceId);
    } catch (e) {
      debugPrint('Bad plugin frame: $e');
    }
  }

  void log(String pluginId, String msg) => _log(pluginId, msg);

  void _log(String pluginId, String msg) {
    final l = logs.putIfAbsent(pluginId, () => []);
    l.add('${DateTime.now().toIso8601String().substring(11, 19)}  $msg');
    if (l.length > 200) l.removeRange(0, l.length - 200);
  }

  Future<void> _stopHost(String pluginId) async {
    final h = _hosts.remove(pluginId);
    _instances.removeWhere((_, i) => i.pluginId == pluginId);
    await h?.dispose();
  }

  void _restartInstancesOf(String pluginId) {
    // Instances are recreated by the next syncInstances() call.
    _instances.removeWhere((_, i) => i.pluginId == pluginId);
  }

  @visibleForTesting
  Set<String> get liveInstances => _instances.keys.toSet();

  @override
  void dispose() {
    for (final h in _hosts.values) {
      h.dispose();
    }
    _hosts.clear();
    super.dispose();
  }
}

class _Instance {
  _Instance(this.pluginId, this.type, this.settings);

  final String pluginId;
  final String type;
  Map<String, dynamic> settings;
}
