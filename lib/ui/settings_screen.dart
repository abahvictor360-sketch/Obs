import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../core/models.dart';
import 'dialogs.dart';
import 'theme.dart';

void openSettings(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => const SettingsScreen(),
  ));
}

/// Settings > Stream / Output / Video / General, laid out as a sidebar +
/// page on tablets (like OBS's settings dialog) and as one list on phones.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _page = 0;

  static const _pages = [
    (Icons.podcasts, 'Stream'),
    (Icons.tune, 'Output'),
    (Icons.aspect_ratio, 'Video'),
    (Icons.settings_outlined, 'General'),
  ];

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), backgroundColor: ObsColors.header),
      body: ListenableBuilder(
        listenable: studio,
        builder: (context, _) {
          final pages = [
            const _StreamPage(),
            const _OutputPage(),
            const _VideoPage(),
            const _GeneralPage(),
          ];
          return LayoutBuilder(builder: (context, box) {
            if (box.maxWidth < 700) {
              return ListView(children: [
                for (var i = 0; i < pages.length; i++) ...[
                  _SectionHeader(_pages[i].$2),
                  pages[i],
                ],
              ]);
            }
            return Row(
              children: [
                SizedBox(
                  width: 220,
                  child: ListView(
                    children: [
                      for (var i = 0; i < _pages.length; i++)
                        ListTile(
                          leading: Icon(_pages[i].$1),
                          title: Text(_pages[i].$2),
                          selected: _page == i,
                          onTap: () => setState(() => _page = i),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [pages[_page]],
                  ),
                ),
              ],
            );
          });
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
        child: Text(text, style: const TextStyle(color: ObsColors.accent, fontWeight: FontWeight.bold)),
      );
}

class _Field extends StatefulWidget {
  const _Field({super.key, required this.label, required this.value, required this.onChanged, this.obscure = false, this.hint});

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final bool obscure;
  final String? hint;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  late final _ctl = TextEditingController(text: widget.value);
  late bool _hidden = widget.obscure;

  @override
  void didUpdateWidget(_Field old) {
    super.didUpdateWidget(old);
    if (widget.value != _ctl.text && old.value != widget.value) _ctl.text = widget.value;
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: TextField(
          controller: _ctl,
          obscureText: _hidden,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: widget.label,
            helperText: widget.hint,
            suffixIcon: widget.obscure
                ? IconButton(
                    icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
                    tooltip: _hidden ? 'Show' : 'Hide',
                    onPressed: () => setState(() => _hidden = !_hidden),
                  )
                : null,
          ),
          onChanged: widget.onChanged,
        ),
      );
}

class _StreamPage extends StatelessWidget {
  const _StreamPage();

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final s = studio.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: DropdownButtonFormField<String>(
            initialValue: kStreamingServices.containsKey(s.service) ? s.service : 'Custom',
            decoration: const InputDecoration(labelText: 'Service'),
            items: [
              for (final k in kStreamingServices.keys) DropdownMenuItem(value: k, child: Text(k)),
            ],
            onChanged: (v) {
              if (v == null) return;
              studio.updateSettings((s) {
                s.service = v;
                if (v != 'Custom') s.server = kStreamingServices[v]!;
              });
            },
          ),
        ),
        _Field(
          key: ValueKey('server-${s.service}'),
          label: 'Server',
          value: s.server,
          hint: 'rtmp://… or rtmps://…',
          onChanged: (v) => studio.updateSettings((s) => s.server = v.trim()),
        ),
        _Field(
          label: 'Stream Key',
          value: s.streamKey,
          obscure: true,
          hint: 'From your Twitch / YouTube / Facebook dashboard',
          onChanged: (v) => studio.updateSettings((s) => s.streamKey = v.trim()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.content_paste),
              label: const Text('Paste stream key'),
              onPressed: () async {
                final d = await Clipboard.getData(Clipboard.kTextPlain);
                final t = d?.text?.trim();
                if (t != null && t.isNotEmpty) studio.updateSettings((s) => s.streamKey = t);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _OutputPage extends StatelessWidget {
  const _OutputPage();

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final s = studio.settings;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledSlider(
            label: 'Video bitrate',
            value: s.videoBitrateKbps.toDouble(),
            min: 500,
            max: 12000,
            divisions: 115,
            format: (v) => '${v.round()} kbps',
            onChanged: (v) => studio.updateSettings((s) => s.videoBitrateKbps = v.round()),
          ),
          const Text(
            'Twitch: up to 6000 kbps. YouTube 720p30: 2500–4000, 1080p30: 4500–9000. '
            'Lower it if your Wi-Fi or mobile data is unstable.',
            style: TextStyle(color: ObsColors.textDim, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: DropdownButtonFormField<int>(
              initialValue: s.audioBitrateKbps,
              decoration: const InputDecoration(labelText: 'Audio bitrate'),
              items: [
                for (final v in [64, 96, 128, 160, 192, 256, 320])
                  DropdownMenuItem(value: v, child: Text('$v kbps')),
              ],
              onChanged: (v) => v == null ? null : studio.updateSettings((s) => s.audioBitrateKbps = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: DropdownButtonFormField<int>(
              initialValue: s.keyframeIntervalSec,
              decoration: const InputDecoration(labelText: 'Keyframe interval'),
              items: [
                for (final v in [1, 2, 3, 4]) DropdownMenuItem(value: v, child: Text('$v s')),
              ],
              onChanged: (v) => v == null ? null : studio.updateSettings((s) => s.keyframeIntervalSec = v),
            ),
          ),
          const SizedBox(height: 8),
          const Text('Recording format', style: TextStyle(color: ObsColors.textDim)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'mp4', label: Text('MP4')),
              ButtonSegment(value: 'flv', label: Text('FLV')),
            ],
            selected: {s.recordingFormat},
            onSelectionChanged: (v) => studio.updateSettings((s) => s.recordingFormat = v.first),
          ),
          const SizedBox(height: 6),
          const Text(
            'MP4 plays everywhere and is saved to your gallery. FLV survives crashes and '
            'battery loss better (like OBS\'s MKV) and can be remuxed later.',
            style: TextStyle(color: ObsColors.textDim, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _VideoPage extends StatelessWidget {
  const _VideoPage();

  static const _resolutions = [(854, 480), (1280, 720), (1600, 900), (1920, 1080)];

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final s = studio.settings;
    String label((int, int) r) => '${r.$1}x${r.$2}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Base (Canvas) Resolution',
                helperText: 'Scene layout coordinates. Sources keep their positions in this space.',
              ),
              child: Text('${s.canvasWidth}x${s.canvasHeight}'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: DropdownButtonFormField<String>(
              initialValue: '${s.outputWidth}x${s.outputHeight}',
              decoration: const InputDecoration(labelText: 'Output (Scaled) Resolution'),
              items: [
                for (final r in _resolutions) DropdownMenuItem(value: label(r), child: Text(label(r))),
                if (!_resolutions.any((r) => r.$1 == s.outputWidth && r.$2 == s.outputHeight))
                  DropdownMenuItem(
                    value: '${s.outputWidth}x${s.outputHeight}',
                    child: Text('${s.outputWidth}x${s.outputHeight}'),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                final parts = v.split('x').map(int.parse).toList();
                studio.updateSettings((s) {
                  s.outputWidth = parts[0];
                  s.outputHeight = parts[1];
                });
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: DropdownButtonFormField<int>(
              initialValue: s.fps,
              decoration: const InputDecoration(labelText: 'Frame rate (FPS)'),
              items: [
                for (final v in [24, 25, 30, 48, 50, 60]) DropdownMenuItem(value: v, child: Text('$v')),
              ],
              onChanged: (v) => v == null ? null : studio.updateSettings((s) => s.fps = v),
            ),
          ),
          const Text(
            '1280x720 at 30 FPS is the most reliable choice on tablets. 1080p or 60 FPS '
            'needs a recent, fast device.',
            style: TextStyle(color: ObsColors.textDim, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _GeneralPage extends StatelessWidget {
  const _GeneralPage();

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final s = studio.settings;
    return Column(
      children: [
        SwitchListTile(
          title: const Text('Keep screen on while live or recording'),
          value: s.keepScreenOn,
          onChanged: (v) => studio.updateSettings((s) => s.keepScreenOn = v),
        ),
        SwitchListTile(
          title: const Text('Confirm before starting/stopping a stream'),
          value: s.confirmStartStop,
          onChanged: (v) => studio.updateSettings((s) => s.confirmStartStop = v),
        ),
        ListTile(
          leading: const Icon(Icons.copy_all),
          title: const Text('Copy scene collection (JSON)'),
          subtitle: const Text('Back up your scenes or move them to another device'),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: studio.exportCollection()));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Scene collection copied')));
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('Reset scenes to default'),
          onTap: () async {
            if (await confirm(context, title: 'Reset scenes', message: 'Replace all scenes and sources with the starter layout?')) {
              studio.replaceCollection(SceneCollection.starter());
            }
          },
        ),
      ],
    );
  }
}
