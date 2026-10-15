import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../plugins/plugin_manager.dart';
import '../teleport/teleport_controller.dart';
import 'about.dart';
import 'theme.dart';

/// Settings and live status for the built-in Teleport Output plugin.
class TeleportSettingsPanel extends StatefulWidget {
  const TeleportSettingsPanel({super.key});

  @override
  State<TeleportSettingsPanel> createState() => _TeleportSettingsPanelState();
}

class _TeleportSettingsPanelState extends State<TeleportSettingsPanel> {
  TextEditingController? _name;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = AppScope.of(context).plugins.builtinSettings(teleportBuiltin.id);
    _name ??= TextEditingController(text: s['name'] as String? ?? TeleportController.defaultName);
  }

  @override
  void dispose() {
    _name?.dispose();
    super.dispose();
  }

  void _set(Map<String, dynamic> values) => AppScope.of(context).plugins.setBuiltinSettings(teleportBuiltin.id, values);

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final out = scope.output;
    final quality =
        (scope.plugins.builtinSettings(teleportBuiltin.id)['quality'] as num?)?.toInt() ?? TeleportController.defaultQuality;
    return ListenableBuilder(
      listenable: out,
      builder: (context, _) {
        final String status;
        final Color color;
        if (out.teleportError != null) {
          status = out.teleportError!;
          color = ObsColors.live;
        } else if (out.teleportActive) {
          final n = out.teleport.receivers;
          status = 'Sending "${out.teleport.name}" on port ${out.teleport.port} · '
              '${n == 0 ? 'waiting for a receiver' : '$n receiver${n == 1 ? '' : 's'} connected'}';
          color = n > 0 ? ObsColors.ok : ObsColors.textDim;
        } else {
          status = 'Starting…';
          color = ObsColors.textDim;
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 8),
                Expanded(child: Text(status, key: const ValueKey('teleport-status'), style: TextStyle(color: color))),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('teleport-name'),
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Teleport name', isDense: true),
                    onSubmitted: (v) => _set({'name': v.trim()}),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonal(onPressed: () => _set({'name': _name!.text.trim()}), child: const Text('Apply')),
              ]),
              if (out.teleportActive && out.teleport.addresses.isNotEmpty) ...[
                const SizedBox(height: 8),
                SelectableText(
                  'Manual IP: ${out.teleport.addresses.map((a) => '$a:${out.teleport.port}').join('  or  ')}',
                  key: const ValueKey('teleport-manual-ip'),
                  style: const TextStyle(fontSize: 13),
                ),
              ],
              const SizedBox(height: 12),
              Row(children: [
                const Text('Quality'),
                Expanded(
                  child: Slider(
                    key: const ValueKey('teleport-quality'),
                    value: quality.clamp(30, 100).toDouble(),
                    min: 30,
                    max: 100,
                    divisions: 14,
                    label: '$quality',
                    onChanged: (v) => _set({'quality': v.round()}),
                  ),
                ),
                SizedBox(width: 36, child: Text('$quality', textAlign: TextAlign.end)),
              ]),
              const Text(
                'In OBS on the computer: install the free Teleport plugin (obs-teleport), add a "Teleport" source '
                'and pick this name. Both must be on the same network. If it isn\'t listed (for example on an '
                'iPad, or a network that blocks discovery), type the Manual IP above into the Teleport source. '
                'Higher quality looks sharper but needs more Wi-Fi; 80-90 suits most networks.',
                style: TextStyle(color: ObsColors.textDim, fontSize: 12),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('teleport-link'),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Get Teleport for OBS'),
                  onPressed: () => openWebsite('github.com/fzwoch/obs-teleport/releases'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
