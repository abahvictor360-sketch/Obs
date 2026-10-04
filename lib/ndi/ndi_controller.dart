import '../output/output_engine.dart';
import '../plugins/plugin_manager.dart';

/// Starts/stops NDI output when the built-in "NDI Output" plugin is turned
/// on/off or its name changes (like DistroAV's Tools > NDI Output settings).
class NdiController {
  NdiController(this.plugins, this.output) {
    plugins.addListener(_apply);
    _apply();
  }

  final PluginManager plugins;
  final OutputEngine output;

  static const defaultName = 'OBSpad';

  String get name {
    final n = (plugins.builtinSettings(ndiBuiltin.id)['name'] as String? ?? '').trim();
    return n.isEmpty ? defaultName : n;
  }

  String? get groups {
    final g = (plugins.builtinSettings(ndiBuiltin.id)['groups'] as String? ?? '').trim();
    return g.isEmpty ? null : g;
  }

  void _apply() {
    if (plugins.isEnabled(ndiBuiltin.id)) {
      if (!output.ndiActive || output.ndiName != name || output.ndiGroups != groups) {
        output.startNdi(name: name, groups: groups);
      }
    } else if (output.ndiActive) {
      output.stopNdi();
    }
  }

  void dispose() => plugins.removeListener(_apply);
}
