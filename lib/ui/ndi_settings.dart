import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../plugins/plugin_manager.dart';
import 'theme.dart';

/// Settings and live status for the built-in NDI Output plugin.
class NdiSettingsPanel extends StatefulWidget {
  const NdiSettingsPanel({super.key});

  @override
  State<NdiSettingsPanel> createState() => _NdiSettingsPanelState();
}

class _NdiSettingsPanelState extends State<NdiSettingsPanel> {
  TextEditingController? _name;
  TextEditingController? _groups;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = AppScope.of(context).plugins.builtinSettings(ndiBuiltin.id);
    _name ??= TextEditingController(text: s['name'] as String? ?? 'OBSpad');
    _groups ??= TextEditingController(text: s['groups'] as String? ?? '');
  }

  @override
  void dispose() {
    _name?.dispose();
    _groups?.dispose();
    super.dispose();
  }

  void _save() {
    AppScope.of(context).plugins.setBuiltinSettings(ndiBuiltin.id, {
      'name': _name!.text.trim(),
      'groups': _groups!.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final out = AppScope.of(context).output;
    return ListenableBuilder(
      listenable: out,
      builder: (context, _) {
        final String status;
        final Color color;
        if (!out.ndi.available) {
          status = out.ndi.unavailableReason ?? 'NDI runtime not available';
          color = ObsColors.warn;
        } else if (out.ndiError != null) {
          status = out.ndiError!;
          color = ObsColors.live;
        } else if (out.ndiActive) {
          final n = out.ndiConnections;
          status = 'Sending "${out.ndiName}" · $n receiver${n == 1 ? '' : 's'} connected';
          color = ObsColors.ok;
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
                Expanded(child: Text(status, style: TextStyle(color: color))),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'NDI source name', isDense: true),
                    onSubmitted: (_) => _save(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _groups,
                    decoration: const InputDecoration(labelText: 'Groups (optional)', isDense: true),
                    onSubmitted: (_) => _save(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonal(onPressed: _save, child: const Text('Apply')),
              ]),
              const SizedBox(height: 8),
              const Text(
                'Receivers see it as "DEVICE (name)". Program video and audio are sent while the app is '
                'open; while a Screen Capture source is live, NDI keeps the last frame. '
                'NDI® is a registered trademark of Vizrt NDI AB (ndi.video).',
                style: TextStyle(color: ObsColors.textDim, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}
