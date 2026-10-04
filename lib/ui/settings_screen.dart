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
          // Not const: the pages read the settings, so they must rebuild
          // whenever the studio changes.
          // ignore_for_file: prefer_const_constructors
          final pages = <Widget>[
            _StreamPage(key: ValueKey('stream-${studio.settings.service}')),
            _OutputPage(),
            _VideoPage(),
            _GeneralPage(),
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
  const _StreamPage({super.key});

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
        if (s.usesPresetServer)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Text(
              'Server is set automatically for ${s.service}. Just paste your stream key.',
              key: const ValueKey('preset-server-note'),
              style: const TextStyle(color: ObsColors.textDim, fontSize: 13),
            ),
          )
        else
          _Field(
            key: ValueKey('server-${s.service}'),
            label: 'Server',
            value: s.server,
            hint: 'rtmp://… or rtmps://…',
            onChanged: (v) => studio.updateSettings((s) => s.server = v.trim()),
          ),
        _Field(
          key: ValueKey('key-${s.service}'),
          label: 'Stream Key',
          value: s.streamKey,
          obscure: true,
          hint: switch (s.service) {
            'Facebook Live' => 'Facebook: Live Producer › Streaming software › Stream key',
            'Twitch' => 'Twitch: Creator Dashboard › Settings › Stream › Primary stream key',
            'YouTube (RTMPS)' || 'YouTube (RTMP)' => 'YouTube Studio: Go live › Stream key',
            'Kick' => 'Kick: Creator Dashboard › Settings › Stream URL & Key',
            _ => 'From your streaming service',
          },
          onChanged: (v) => studio.updateSettings((s) => s.streamKey = s.keyFromPasted(v)),
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
                if (t != null && t.isNotEmpty) studio.updateSettings((s) => s.streamKey = s.keyFromPasted(t));
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
          if (AppScope.of(context).output.encoderSettingsLocked)
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 4),
              child: Text(
                'You are live: changes here are saved and apply the next time you start streaming or recording.',
                style: TextStyle(color: ObsColors.warn, fontSize: 13),
              ),
            ),
          LabeledSlider(
            label: 'Video bitrate',
            value: s.videoBitrateKbps.toDouble(),
            min: 500,
            max: 20000,
            divisions: 195,
            format: (v) => '${v.round()} kbps',
            onChanged: (v) => studio.updateSettings((s) => s.videoBitrateKbps = v.round()),
          ),
          LabeledSlider(
            key: const ValueKey('stream-delay'),
            label: 'Stream delay',
            value: s.streamDelaySec.toDouble(),
            min: 0,
            max: 60,
            divisions: 60,
            format: (v) => v == 0 ? 'Off' : '${v.round()} s',
            onChanged: (v) => studio.updateSettings((s) => s.streamDelaySec = v.round()),
          ),
          LabeledSlider(
            label: 'Replay buffer length',
            value: s.replaySeconds.toDouble(),
            min: 5,
            max: 120,
            divisions: 23,
            format: (v) => '${v.round()} s',
            onChanged: (v) => studio.updateSettings((s) => s.replaySeconds = v.round()),
          ),
          const Text(
            'Stream delay: viewers see everything that many seconds late (recordings are not delayed). '
            'Replay buffer: keeps the last seconds in memory; Save Replay writes them to a file.\n'
            'Twitch: up to 6000 kbps. YouTube 720p30: 2500–4000, 1080p30: 4500–9000, '
            '1440p (2K) 30: 9000–18000. '
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

  static const _resolutions = [(854, 480), (1280, 720), (1600, 900), (1920, 1080), (2560, 1440)];

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final s = studio.settings;
    String label((int, int) r) => '${r.$1}x${r.$2}';
    String name((int, int) r) => switch (r.$2) {
          1440 => '2560x1440 (2K)',
          1080 => '1920x1080 (Full HD)',
          720 => '1280x720 (HD)',
          _ => label(r),
        };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (AppScope.of(context).output.encoderSettingsLocked)
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 4),
              child: Text(
                'You are live: changes here are saved and apply the next time you start streaming or recording.',
                style: TextStyle(color: ObsColors.warn, fontSize: 13),
              ),
            ),
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
                for (final r in _resolutions) DropdownMenuItem(value: label(r), child: Text(name(r))),
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
          if (s.outputHeight > 1080) ...[
            const SizedBox(height: 8),
            Text(
              '2K (1440p) needs a recent, fast tablet: use 30 FPS and 9000–18000 kbps, and a '
              'wired or strong Wi-Fi connection. YouTube accepts 1440p; Facebook Live and Twitch '
              'take at most 1080p, so choose 1920x1080 for them.'
              '${s.service == 'Facebook Live' || s.service == 'Twitch' ? '\n\nYour stream service (${s.service}) is limited to 1080p.' : ''}',
              key: const ValueKey('res-2k-note'),
              style: const TextStyle(color: ObsColors.warn, fontSize: 13),
            ),
          ],
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
          key: const ValueKey('auto-record'),
          title: const Text('Automatically record when streaming'),
          subtitle: const Text('Starts a recording with the stream and stops it when the stream ends'),
          value: s.autoRecordWithStream,
          onChanged: (v) => studio.updateSettings((s) => s.autoRecordWithStream = v),
        ),
        SwitchListTile(
          title: const Text('Keep screen on while live or recording'),
          value: s.keepScreenOn,
          onChanged: (v) => studio.updateSettings((s) => s.keepScreenOn = v),
        ),
        Builder(builder: (context) {
          final devices = AppScope.of(context).devices;
          return ListenableBuilder(
            listenable: devices,
            builder: (context, _) => SwitchListTile(
              title: const Text('Prefer wired connection (USB Ethernet)'),
              subtitle: Text(!devices.supported
                  ? 'Available in the Android and iPad apps'
                  : !devices.network.canPreferWired
                      ? 'iPadOS uses a connected Ethernet adapter automatically'
                      : devices.network.wiredAvailable
                          ? 'Adapter connected: streaming goes over the cable'
                          : 'Plug a USB Ethernet adapter into the tablet (USB-C / OTG)'),
              value: s.preferWired,
              onChanged: devices.network.canPreferWired ? (v) => studio.updateSettings((s) => s.preferWired = v) : null,
            ),
          );
        }),
        ListTile(
          title: const Text('Connected screen'),
          subtitle: const Text('What a monitor or TV on a docking station, USB-C or HDMI shows'),
          trailing: DropdownButton<String>(
            value: s.externalDisplay,
            items: const [
              DropdownMenuItem(value: 'program', child: Text('Program (full screen)')),
              DropdownMenuItem(value: 'multiview', child: Text('Multiview')),
              DropdownMenuItem(value: 'mirror', child: Text('Mirror tablet')),
            ],
            onChanged: (v) => studio.updateSettings((s) => s.externalDisplay = v ?? 'program'),
          ),
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
