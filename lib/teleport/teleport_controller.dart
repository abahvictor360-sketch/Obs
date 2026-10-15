import '../output/output_engine.dart';
import '../plugins/plugin_manager.dart';

/// Starts/stops Teleport output when the built-in "Teleport Output" plugin is
/// turned on/off or its settings change (like obs-teleport's Tools > Teleport).
class TeleportController {
  TeleportController(this.plugins, this.output) {
    plugins.addListener(_apply);
    _apply();
  }

  final PluginManager plugins;
  final OutputEngine output;

  static const defaultName = 'OBSpad';
  static const defaultQuality = 85;

  Map<String, dynamic> get _s => plugins.builtinSettings(teleportBuiltin.id);

  String get name {
    final n = (_s['name'] as String? ?? '').trim();
    return n.isEmpty ? defaultName : n;
  }

  int get quality => (_s['quality'] as num?)?.toInt() ?? defaultQuality;

  /// 0 = any free port.
  int get port => (_s['port'] as num?)?.toInt() ?? 0;

  void _apply() {
    if (plugins.isEnabled(teleportBuiltin.id)) {
      output.startTeleport(name: name, quality: quality, port: port);
    } else if (output.teleportActive) {
      output.stopTeleport();
    }
  }

  void dispose() => plugins.removeListener(_apply);
}
