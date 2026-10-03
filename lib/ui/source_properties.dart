import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../core/studio_controller.dart';
import '../plugins/plugin_manifest.dart';
import 'dialogs.dart';
import 'theme.dart';

/// Properties / Transform / Filters for one scene item, in a sheet that
/// leaves the canvas visible so changes can be seen live.
Future<void> showSourceProperties(BuildContext context, String itemId, {int initialTab = 0}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 760),
    barrierColor: Colors.black26,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.62,
      child: _PropertiesSheet(itemId: itemId, initialTab: initialTab),
    ),
  );
}

class _PropertiesSheet extends StatelessWidget {
  const _PropertiesSheet({required this.itemId, required this.initialTab});

  final String itemId;
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        final item = studio.itemById(itemId);
        final source = item == null ? null : studio.sourceById(item.sourceId);
        if (item == null || source == null) {
          return const Center(child: Text('This source was removed.'));
        }
        final visual = source.type.isVisual;
        return DefaultTabController(
          length: visual ? 3 : 1,
          initialIndex: visual ? initialTab : 0,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(sourceIcon(source.type), color: ObsColors.textDim),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Properties for '${source.name}'",
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                  ],
                ),
              ),
              TabBar(tabs: [
                const Tab(text: 'Properties'),
                if (visual) const Tab(text: 'Transform'),
                if (visual) const Tab(text: 'Filters'),
              ]),
              Expanded(
                child: TabBarView(children: [
                  _SourceSettingsTab(source: source, item: item),
                  if (visual) _TransformTab(item: item),
                  if (visual) _FiltersTab(item: item),
                ]),
              ),
            ],
          ),
        );
      },
    );
  }
}

IconData sourceIcon(SourceType t) => switch (t) {
      SourceType.camera => Icons.videocam_outlined,
      SourceType.screen => Icons.screen_share_outlined,
      SourceType.usbVideo => Icons.usb,
      SourceType.image => Icons.image_outlined,
      SourceType.media => Icons.movie_outlined,
      SourceType.text => Icons.text_fields,
      SourceType.color => Icons.format_color_fill,
      SourceType.audioInput => Icons.mic_none,
      SourceType.plugin => Icons.extension_outlined,
    };

class _SourceSettingsTab extends StatelessWidget {
  const _SourceSettingsTab({required this.source, required this.item});

  final Source source;
  final SceneItem item;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final s = source.settings;
    void set(String k, Object v) => studio.updateSourceSettings(source.id, {k: v});

    final children = <Widget>[];
    switch (source.type) {
      case SourceType.camera:
        children.addAll([
          const Text('Camera', style: TextStyle(color: ObsColors.textDim)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'front', label: Text('Front'), icon: Icon(Icons.camera_front)),
              ButtonSegment(value: 'back', label: Text('Back'), icon: Icon(Icons.camera_rear)),
              ButtonSegment(value: 'external', label: Text('USB / External'), icon: Icon(Icons.usb)),
            ],
            selected: {s['lens'] as String? ?? 'front'},
            onSelectionChanged: (v) => set('lens', v.first),
          ),
          SwitchListTile(
            title: const Text('Mirror front camera'),
            value: s['mirror'] as bool? ?? false,
            onChanged: (v) => set('mirror', v),
          ),
          const Text(
            'Most tablets can only run one camera at a time. Using the front and back '
            'camera in visible scenes at once may show an error on one of them.',
            style: TextStyle(color: ObsColors.textDim, fontSize: 13),
          ),
        ]);
      case SourceType.screen:
        children.add(const _ScreenCaptureSettings());
      case SourceType.usbVideo:
        children.add(_UsbVideoSettings(source: source));
      case SourceType.image:
      case SourceType.media:
        final isImage = source.type == SourceType.image;
        final path = s['path'] as String? ?? '';
        children.addAll([
          FilledButton.icon(
            icon: Icon(isImage ? Icons.photo_library_outlined : Icons.video_library_outlined),
            label: Text(isImage ? 'Choose image…' : 'Choose video…'),
            onPressed: () async {
              final picker = ImagePicker();
              final f = isImage
                  ? await picker.pickImage(source: ImageSource.gallery)
                  : await picker.pickVideo(source: ImageSource.gallery);
              if (f != null) set('path', f.path);
            },
          ),
          const SizedBox(height: 8),
          Text(path.isEmpty ? 'No file selected' : path,
              style: const TextStyle(color: ObsColors.textDim, fontSize: 13)),
          if (!isImage) ...[
            SwitchListTile(
              title: const Text('Loop'),
              value: s['loop'] as bool? ?? true,
              onChanged: (v) => set('loop', v),
            ),
            SwitchListTile(
              title: const Text('Mute video audio'),
              value: s['muted'] as bool? ?? false,
              onChanged: (v) => set('muted', v),
            ),
          ],
        ]);
      case SourceType.text:
        children.addAll([
          _TextField(
            initial: s['text'] as String? ?? '',
            onChanged: (v) => set('text', v),
          ),
          const SizedBox(height: 12),
          LabeledSlider(
            label: 'Font size',
            value: (s['fontSize'] as num?)?.toDouble() ?? 96,
            min: 12,
            max: 400,
            format: (v) => v.round().toString(),
            onChanged: (v) => set('fontSize', v),
          ),
          Wrap(spacing: 8, children: [
            FilterChip(
              label: const Text('Bold'),
              selected: s['bold'] as bool? ?? false,
              onSelected: (v) => set('bold', v),
            ),
            FilterChip(
              label: const Text('Italic'),
              selected: s['italic'] as bool? ?? false,
              onSelected: (v) => set('italic', v),
            ),
            FilterChip(
              label: const Text('Outline'),
              selected: s['outline'] as bool? ?? false,
              onSelected: (v) => set('outline', v),
            ),
            for (final a in ['left', 'center', 'right'])
              ChoiceChip(
                label: Icon(switch (a) {
                  'left' => Icons.format_align_left,
                  'right' => Icons.format_align_right,
                  _ => Icons.format_align_center,
                }, size: 18),
                selected: (s['align'] ?? 'center') == a,
                onSelected: (_) => set('align', a),
              ),
          ]),
          const SizedBox(height: 16),
          ColorPickerField(label: 'Text color', value: s['color'] as int, onChanged: (v) => set('color', v)),
          const SizedBox(height: 16),
          ColorPickerField(
            label: 'Outline color',
            value: s['outlineColor'] as int? ?? 0xFF000000,
            onChanged: (v) => set('outlineColor', v),
          ),
          const SizedBox(height: 16),
          ColorPickerField(
            label: 'Background',
            value: s['background'] as int? ?? 0,
            onChanged: (v) => set('background', v),
          ),
        ]);
      case SourceType.color:
        children.add(ColorPickerField(label: 'Color', value: s['color'] as int, onChanged: (v) => set('color', v)));
      case SourceType.plugin:
        children.add(_PluginSettings(source: source));
      case SourceType.audioInput:
        children.add(_AudioInputSettings(source: source));
    }
    return ListView(padding: const EdgeInsets.all(20), children: children);
  }
}

/// Text field that keeps its own controller so live updates don't reset the
/// cursor.
class _TextField extends StatefulWidget {
  const _TextField({required this.initial, required this.onChanged});

  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<_TextField> createState() => _TextFieldState();
}

class _TextFieldState extends State<_TextField> {
  late final _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _ctl,
        minLines: 2,
        maxLines: 5,
        decoration: const InputDecoration(labelText: 'Text'),
        onChanged: widget.onChanged,
      );
}

class _NumberField extends StatefulWidget {
  const _NumberField({required this.label, required this.value, required this.onSubmitted});

  final String label;
  final double value;
  final ValueChanged<double> onSubmitted;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _ctl = TextEditingController(text: widget.value.toStringAsFixed(0));
  final _focus = FocusNode();

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus) _ctl.text = widget.value.toStringAsFixed(0);
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final v = double.tryParse(_ctl.text);
    if (v != null) widget.onSubmitted(v);
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _ctl,
        focusNode: _focus,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(labelText: widget.label, isDense: true),
        onSubmitted: (_) => _submit(),
        onTapOutside: (_) {
          if (_focus.hasFocus) {
            _submit();
            _focus.unfocus();
          }
        },
      );
}

class _TransformTab extends StatelessWidget {
  const _TransformTab({required this.item});

  final SceneItem item;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final t = item.transform;
    void edit(void Function(ItemTransform t) f) => studio.updateTransform(item.id, f, persist: true);
    String pct(double v) => '${(v * 100).round()}%';

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (item.locked)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('This item is locked. Unlock it to change its transform.',
                style: TextStyle(color: ObsColors.warn)),
          ),
        Row(children: [
          Expanded(child: _NumberField(label: 'X', value: t.x, onSubmitted: (v) => edit((t) => t.x = v))),
          const SizedBox(width: 12),
          Expanded(child: _NumberField(label: 'Y', value: t.y, onSubmitted: (v) => edit((t) => t.y = v))),
          const SizedBox(width: 12),
          Expanded(
            child: _NumberField(
              label: 'Width',
              value: t.width,
              onSubmitted: (v) => edit((t) => t.width = v.clamp(1, 20000)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _NumberField(
              label: 'Height',
              value: t.height,
              onSubmitted: (v) => edit((t) => t.height = v.clamp(1, 20000)),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        LabeledSlider(
          label: 'Rotation',
          value: t.rotation,
          min: 0,
          max: 359,
          format: (v) => '${v.round()}°',
          onChanged: (v) => edit((t) => t.rotation = v.roundToDouble()),
        ),
        const SizedBox(height: 8),
        const Text('Fit inside box', style: TextStyle(color: ObsColors.textDim)),
        const SizedBox(height: 8),
        SegmentedButton<FitMode>(
          segments: const [
            ButtonSegment(value: FitMode.stretch, label: Text('Stretch')),
            ButtonSegment(value: FitMode.contain, label: Text('Fit')),
            ButtonSegment(value: FitMode.cover, label: Text('Fill / Crop')),
          ],
          selected: {t.fit},
          onSelectionChanged: (v) => edit((t) => t.fit = v.first),
        ),
        const SizedBox(height: 16),
        const Text('Crop', style: TextStyle(color: ObsColors.textDim)),
        LabeledSlider(label: 'Left', value: t.cropLeft, min: 0, max: 0.9, format: pct,
            onChanged: (v) => edit((t) => t.cropLeft = v)),
        LabeledSlider(label: 'Right', value: t.cropRight, min: 0, max: 0.9, format: pct,
            onChanged: (v) => edit((t) => t.cropRight = v)),
        LabeledSlider(label: 'Top', value: t.cropTop, min: 0, max: 0.9, format: pct,
            onChanged: (v) => edit((t) => t.cropTop = v)),
        LabeledSlider(label: 'Bottom', value: t.cropBottom, min: 0, max: 0.9, format: pct,
            onChanged: (v) => edit((t) => t.cropBottom = v)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in TransformPreset.values)
              OutlinedButton(
                onPressed: () => studio.applyTransformPreset(item.id, p),
                child: Text(p.label),
              ),
          ],
        ),
      ],
    );
  }
}

class _FiltersTab extends StatelessWidget {
  const _FiltersTab({required this.item});

  final SceneItem item;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final c = item.color;
    void edit(void Function(ColorCorrection c) f) => studio.updateColor(item.id, f);
    String signed(double v) => '${v >= 0 ? '+' : ''}${(v * 100).round()}';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('Color Correction', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        LabeledSlider(label: 'Opacity', value: c.opacity, min: 0, max: 1,
            format: (v) => '${(v * 100).round()}%', onChanged: (v) => edit((c) => c.opacity = v)),
        LabeledSlider(label: 'Brightness', value: c.brightness, min: -1, max: 1, format: signed,
            onChanged: (v) => edit((c) => c.brightness = v)),
        LabeledSlider(label: 'Contrast', value: c.contrast, min: -1, max: 1, format: signed,
            onChanged: (v) => edit((c) => c.contrast = v)),
        LabeledSlider(label: 'Saturation', value: c.saturation, min: -1, max: 1, format: signed,
            onChanged: (v) => edit((c) => c.saturation = v)),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset'),
            onPressed: () => edit((c) {
              c
                ..opacity = 1
                ..brightness = 0
                ..contrast = 0
                ..saturation = 0;
            }),
          ),
        ),
      ],
    );
  }
}

class _ScreenCaptureSettings extends StatelessWidget {
  const _ScreenCaptureSettings();

  @override
  Widget build(BuildContext context) {
    final out = AppScope.of(context).output;
    return ListenableBuilder(
      listenable: out,
      builder: (context, _) {
        final st = out.screenState;
        final ios = Theme.of(context).platform == TargetPlatform.iOS;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(st.active ? Icons.screen_share : Icons.stop_screen_share_outlined,
                  color: st.active ? ObsColors.ok : ObsColors.textDim),
              title: Text(st.active ? 'Capturing (${st.width}x${st.height})' : 'Not capturing'),
              subtitle: st.error == null ? null : Text(st.error!, style: const TextStyle(color: ObsColors.warn)),
            ),
            if (!out.screenCaptureSupported)
              const Text('Screen capture is not available on this platform.',
                  style: TextStyle(color: ObsColors.textDim))
            else
              FilledButton.icon(
                icon: Icon(st.active ? Icons.stop : Icons.play_arrow),
                label: Text(st.active ? 'Stop screen capture' : 'Start screen capture'),
                style: st.active ? FilledButton.styleFrom(backgroundColor: ObsColors.live) : null,
                onPressed: st.active ? out.stopScreenCapture : out.startScreenCapture,
              ),
            const SizedBox(height: 16),
            Text(
              ios
                  ? 'On iPad, choose "OBS Tablet Screen" in the broadcast sheet and tap Start '
                      'Broadcast. Then switch to the app or game you want to show; your other '
                      'sources stay on top of it.'
                  : 'Android will ask for permission to capture the screen. Then switch to the '
                      'app or game you want to show; your other sources stay on top of it, and '
                      'the stream keeps running in the background.',
              style: const TextStyle(color: ObsColors.textDim, fontSize: 13),
            ),
            const SizedBox(height: 8),
            const Text(
              'While this app is open the screen source shows a status card instead of a '
              'mirror of the app itself. Cameras in other layers freeze while you are in another '
              'app (the OS pauses camera access in the background).',
              style: TextStyle(color: ObsColors.textDim, fontSize: 13),
            ),
          ],
        );
      },
    );
  }
}

/// Form generated from the plugin manifest's settings schema.
class _PluginSettings extends StatelessWidget {
  const _PluginSettings({required this.source});

  final Source source;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final plugin = scope.plugins.plugin(source.settings['plugin'] as String? ?? '');
    final type = plugin?.manifest.sourceType(source.settings['type'] as String? ?? '');
    if (plugin == null || type == null) {
      return const Text('This plugin is not installed. Install it from Plugins to use this source.',
          style: TextStyle(color: ObsColors.warn));
    }
    final config = {
      ...type.defaultSettings(),
      ...((source.settings['config'] as Map?) ?? const {}).cast<String, dynamic>(),
    };
    void set(String key, Object? value) {
      scope.studio.updateSourceSettings(source.id, {'config': {...config, key: value}});
    }

    final rows = <Widget>[
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.extension_outlined),
        title: Text('${type.name} · ${plugin.manifest.name} ${plugin.manifest.version}'),
        subtitle: plugin.manifest.author.isEmpty ? null : Text('by ${plugin.manifest.author}'),
      ),
    ];
    for (final s in type.settings) {
      final v = config[s.key];
      switch (s.type) {
        case SettingType.text:
          rows.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _PluginTextField(label: s.label, initial: '${v ?? ''}', onChanged: (t) => set(s.key, t)),
          ));
        case SettingType.number:
          final min = s.min ?? 0, max = s.max ?? 100;
          rows.add(LabeledSlider(
            label: s.label,
            value: ((v as num?) ?? min).toDouble().clamp(min, max),
            min: min,
            max: max,
            format: (x) => x.toStringAsFixed(x.abs() >= 10 ? 0 : 1),
            onChanged: (x) => set(s.key, x),
          ));
        case SettingType.bool:
          rows.add(SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.label),
            value: v == true,
            onChanged: (b) => set(s.key, b),
          ));
        case SettingType.color:
          rows.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: ColorPickerField(
              label: s.label,
              value: (v as num?)?.toInt() ?? 0xFFFFFFFF,
              onChanged: (c) => set(s.key, c),
            ),
          ));
        case SettingType.select:
          rows.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: DropdownButtonFormField<String>(
              initialValue: s.options.contains('$v') ? '$v' : s.options.first,
              decoration: InputDecoration(labelText: s.label),
              items: [for (final o in s.options) DropdownMenuItem(value: o, child: Text(o))],
              onChanged: (o) => set(s.key, o),
            ),
          ));
      }
    }
    final err = scope.plugins.instanceErrors[source.id];
    if (err != null) rows.add(Text(err, style: const TextStyle(color: ObsColors.warn, fontSize: 13)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

class _PluginTextField extends StatefulWidget {
  const _PluginTextField({required this.label, required this.initial, required this.onChanged});

  final String label;
  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<_PluginTextField> createState() => _PluginTextFieldState();
}

class _PluginTextFieldState extends State<_PluginTextField> {
  late final _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _ctl,
        decoration: InputDecoration(labelText: widget.label),
        onChanged: widget.onChanged,
      );
}

class _UsbVideoSettings extends StatelessWidget {
  const _UsbVideoSettings({required this.source});

  final Source source;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final devices = scope.devices;
    return ListenableBuilder(
      listenable: devices,
      builder: (context, _) {
        final current = source.settings['device'] as String? ?? '';
        final ids = devices.usbCameras.map((c) => c.id).toSet();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: ids.contains(current) ? current : '',
                  decoration: const InputDecoration(labelText: 'Device'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('First connected device')),
                    for (final c in devices.usbCameras) DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) async {
                    scope.studio.updateSourceSettings(source.id, {'device': v ?? ''});
                    await devices.closeUsbVideo();
                    await devices.openUsbVideo(v);
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Look for devices',
                onPressed: devices.refreshUsbCameras,
              ),
            ]),
            const SizedBox(height: 12),
            if (devices.usbVideo != null)
              Text('Receiving ${devices.usbVideo!.width}x${devices.usbVideo!.height}',
                  style: const TextStyle(color: ObsColors.ok))
            else if (devices.usbError != null)
              Text(devices.usbError!, style: const TextStyle(color: ObsColors.warn)),
            const SizedBox(height: 12),
            const Text(
              'Plug an HDMI capture card (camera, console, PC) or a USB webcam into the tablet with a '
              'USB-C / OTG adapter. Android asks for permission to use it the first time; on iPad it needs '
              'iPadOS 17. One USB video device can be used at a time, and most tablets can\'t run a USB '
              'camera and a built-in camera together.',
              style: TextStyle(color: ObsColors.textDim, fontSize: 13),
            ),
          ],
        );
      },
    );
  }
}

class _AudioInputSettings extends StatelessWidget {
  const _AudioInputSettings({required this.source});

  final Source source;

  static IconData _icon(String type) => switch (type) {
        'usb' => Icons.usb,
        'bluetooth' => Icons.bluetooth_audio,
        'headset' => Icons.headset_mic,
        _ => Icons.mic,
      };

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final devices = scope.devices;
    return ListenableBuilder(
      listenable: devices,
      builder: (context, _) {
        final current = source.settings['device'] as String? ?? 'default';
        final ids = devices.audioInputs.map((i) => i.id).toSet();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: ids.contains(current) ? current : 'default',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Input device'),
                  items: [
                    const DropdownMenuItem(value: 'default', child: Text('Default (system choice)')),
                    for (final i in devices.audioInputs)
                      DropdownMenuItem(
                        value: i.id,
                        child: Row(children: [
                          Icon(_icon(i.type), size: 18),
                          const SizedBox(width: 8),
                          Flexible(child: Text(i.name, overflow: TextOverflow.ellipsis)),
                        ]),
                      ),
                  ],
                  onChanged: (v) => scope.studio.updateSourceSettings(source.id, {'device': v ?? 'default'}),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Look for devices',
                onPressed: devices.refreshAudioInputs,
              ),
            ]),
            const SizedBox(height: 12),
            const Text(
              'USB microphones and audio interfaces show up here when plugged in (USB-C / OTG). '
              'Adjust the level in the Audio Mixer.',
              style: TextStyle(color: ObsColors.textDim, fontSize: 13),
            ),
          ],
        );
      },
    );
  }
}
