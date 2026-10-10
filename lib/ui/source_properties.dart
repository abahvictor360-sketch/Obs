import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../core/studio_controller.dart';
import '../network_video/mjpeg.dart';
import '../network_video/network_video_service.dart';
import '../plugins/plugin_manifest.dart';
import '../render/filter_view.dart';
import '../render/scene_canvas.dart';
import 'dialogs.dart';
import 'filters_panel.dart';
import 'media_import.dart';
import 'source_settings_more.dart';
import 'live_input_settings.dart';
import 'theme.dart';

/// Properties / Transform / Filters for one scene item, in a sheet that
/// leaves the canvas visible so changes can be seen live. The source itself
/// is previewed at the top, like OBS's properties window.
///
/// [creating]: the item was just added (hidden). "Add" puts it in the scene,
/// "Cancel" removes it, so nothing reaches preview or program before the
/// user is happy with it. Returns true if it was added.
Future<bool> showSourceProperties(BuildContext context, String itemId, {int initialTab = 0, bool creating = false}) async {
  final studio = AppScope.of(context).studio;
  final item = studio.itemById(itemId);
  studio.setInspectedSource(item?.sourceId);
  final added = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: !creating,
    enableDrag: !creating,
    constraints: const BoxConstraints(maxWidth: 760),
    barrierColor: Colors.black26,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.8,
      child: _PropertiesSheet(itemId: itemId, initialTab: initialTab, creating: creating),
    ),
  );
  if (studio.inspectedSourceId == item?.sourceId) studio.setInspectedSource(null);
  if (creating) {
    if (added == true) {
      studio.setItemVisible(itemId, true);
    } else {
      studio.removeItem(itemId);
    }
  }
  return added == true;
}

/// Opens the properties sheet on the Filters tab.
Future<void> showSourceFilters(BuildContext context, String itemId) async {
  final studio = AppScope.of(context).studio;
  final item = studio.itemById(itemId);
  if (item == null) {
    // The item is in another scene (e.g. from the mixer): open the Filters
    // window for its source instead of doing nothing.
    final other = studio.scenes.expand((s) => s.items).where((i) => i.id == itemId).firstOrNull;
    if (other != null) await showFiltersWindow(context, sourceId: other.sourceId);
    return;
  }
  final source = studio.sourceById(item.sourceId);
  if (source == null) return;
  await showSourceProperties(context, itemId, initialTab: source.type.isVisual ? 2 : 1);
}

class _PropertiesSheet extends StatelessWidget {
  const _PropertiesSheet({required this.itemId, required this.initialTab, this.creating = false});

  final String itemId;
  final int initialTab;
  final bool creating;

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
        final filters = visual || source.type.hasAudio;
        final tabs = 1 + (visual ? 1 : 0) + (filters ? 1 : 0);
        return DefaultTabController(
          length: tabs,
          initialIndex: initialTab.clamp(0, tabs - 1),
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
                    if (creating) ...[
                      TextButton(
                        key: const ValueKey('properties-cancel'),
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 6),
                      FilledButton(
                        key: const ValueKey('properties-add'),
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(studio.studioMode ? 'Add to Preview' : 'Add to Scene'),
                      ),
                    ] else
                      TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done')),
                  ],
                ),
              ),
              if (visual) _SourcePreview(source: source, item: item, creating: creating),
              TabBar(tabs: [
                const Tab(text: 'Properties'),
                if (visual) const Tab(text: 'Transform'),
                if (filters) const Tab(text: 'Filters'),
              ]),
              Expanded(
                child: TabBarView(children: [
                  _SourceSettingsTab(source: source, item: item),
                  if (visual) _TransformTab(item: item),
                  if (filters) FiltersPanel(source: source, item: item),
                ]),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Live preview of the source alone, at the size it has in the scene.
class _SourcePreview extends StatelessWidget {
  const _SourcePreview({required this.source, required this.item, required this.creating});

  final Source source;
  final SceneItem item;
  final bool creating;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final t = item.transform;
    final w = t.width <= 1 ? studio.settings.canvasWidth.toDouble() : t.width;
    final h = t.height <= 1 ? studio.settings.canvasHeight.toDouble() : t.height;
    final live = !creating && item.visible && studio.programScene.items.any((i) => i.id == item.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 170,
          child: Container(
            key: const ValueKey('source-preview'),
            decoration: BoxDecoration(
              color: const Color(0xFF0D0E12),
              border: Border.all(color: ObsColors.border),
              borderRadius: BorderRadius.circular(6),
            ),
            clipBehavior: Clip.antiAlias,
            child: FittedBox(
              child: SizedBox(
                width: w,
                height: h,
                child: applySourceFilters(source, SourceRenderer(source: source, fit: t.fit, showPlaceholder: true)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          creating
              ? 'Preview only: nothing goes live until you tap ${studio.studioMode ? '"Add to Preview" and then Transition' : '"Add to Scene"'}.'
              : live
                  ? 'This source is live in the program.'
                  : 'This source is not live.',
          style: TextStyle(fontSize: 12, color: live ? ObsColors.live : ObsColors.textDim),
        ),
      ]),
    );
  }
}

IconData sourceIcon(SourceType t) => switch (t) {
      SourceType.camera => Icons.videocam_outlined,
      SourceType.screen => Icons.screen_share_outlined,
      SourceType.usbVideo => Icons.usb,
      SourceType.networkVideo => Icons.wifi_tethering,
      SourceType.ndiInput => Icons.settings_input_antenna,
      SourceType.rtmpInput => Icons.phone_android,
      SourceType.image => Icons.image_outlined,
      SourceType.imageSlideShow => Icons.collections_outlined,
      SourceType.media => Icons.movie_outlined,
      SourceType.browser => Icons.language,
      SourceType.text => Icons.text_fields,
      SourceType.color => Icons.format_color_fill,
      SourceType.audioInput => Icons.mic_none,
      SourceType.audioOutput => Icons.volume_up_outlined,
      SourceType.scene => Icons.collections_outlined,
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
          _CameraControls(source: source),
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
      case SourceType.networkVideo:
        children.add(_NetworkVideoSettings(source: source));
      case SourceType.ndiInput:
        children.add(NdiInputSettings(source: source));
      case SourceType.rtmpInput:
        children.add(RtmpInputSettings(source: source));
      case SourceType.image:
      case SourceType.media:
        final isImage = source.type == SourceType.image;
        final path = s['path'] as String? ?? '';
        children.addAll([
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Browse files…'),
              onPressed: () async {
                final picked = await pickMediaFile(context, isImage ? MediaKind.image : MediaKind.video);
                if (picked != null) set('path', picked);
              },
            ),
            OutlinedButton.icon(
              icon: Icon(isImage ? Icons.photo_library_outlined : Icons.video_library_outlined),
              label: const Text('Photos / gallery…'),
              onPressed: () async {
                final picker = ImagePicker();
                final f = isImage
                    ? await picker.pickImage(source: ImageSource.gallery)
                    : await picker.pickVideo(source: ImageSource.gallery);
                if (f != null) set('path', f.path);
              },
            ),
          ]),
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
            const SizedBox(height: 8),
            const Text('Audio Monitoring', style: TextStyle(color: ObsColors.textDim)),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              key: const ValueKey('media-monitoring'),
              segments: const [
                ButtonSegment(value: 'off', label: Text('Stream only')),
                ButtonSegment(value: 'both', label: Text('Stream + tablet')),
                ButtonSegment(value: 'monitor', label: Text('Tablet only')),
              ],
              selected: {s['monitoring'] as String? ?? 'off'},
              onSelectionChanged: (v) => set('monitoring', v.first),
            ),
            const SizedBox(height: 4),
            const Text(
              'The video\'s sound goes into the stream and recording directly. Hear it on the tablet '
              'or headphones too with "Stream + tablet" (keep the tablet speaker away from the mic).',
              style: TextStyle(color: ObsColors.textDim, fontSize: 12),
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
            onChanged: (v) => studio.setTextFontSize(source.id, v),
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
      case SourceType.scene:
        final options = studio.nestableScenes(studio.editingScene.id);
        final current = s['sceneId'] as String? ?? '';
        children.addAll([
          DropdownButtonFormField<String>(
            key: const ValueKey('nested-scene'),
            initialValue: options.any((o) => o.id == current) ? current : null,
            decoration: const InputDecoration(labelText: 'Scene'),
            items: [for (final o in options) DropdownMenuItem(value: o.id, child: Text(o.name))],
            onChanged: (v) => v == null ? null : set('sceneId', v),
          ),
          const SizedBox(height: 8),
          const Text(
            'Shows another scene inside this one, scaled to the box. Edit that scene to change what it shows; '
            'it updates everywhere it is used. Use it to group items that move together.',
            style: TextStyle(color: ObsColors.textDim, fontSize: 13),
          ),
        ]);
      case SourceType.plugin:
        children.add(_PluginSettings(source: source));
      case SourceType.audioInput:
        children.add(_AudioInputSettings(source: source));
      case SourceType.imageSlideShow:
        children.add(SlideShowSettings(source: source));
      case SourceType.browser:
        children.add(BrowserSettings(source: source));
      case SourceType.audioOutput:
        children.add(const AudioOutputSettings());
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
                  ? 'On iPad, choose "OBSpad Screen" in the broadcast sheet and tap Start '
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
                    await devices.openUsbVideo(v, retry: true);
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
              Row(children: [
                Expanded(child: Text(devices.usbError!, style: const TextStyle(color: ObsColors.warn))),
                TextButton(
                  key: const ValueKey('usb-retry'),
                  onPressed: () => devices.openUsbVideo(source.settings['device'] as String?, retry: true),
                  child: const Text('Try again'),
                ),
              ]),
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
                    const DropdownMenuItem(value: 'default', child: Text('Automatic (USB sound card when plugged in)')),
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
              'USB microphones, sound cards and audio interfaces show up here when plugged in, '
              'directly (USB-C / OTG) or through a hub or docking station. On Automatic, OBSpad '
              'switches to a USB sound card as soon as it is connected. Adjust the level in the Audio Mixer.',
              style: TextStyle(color: ObsColors.textDim, fontSize: 13),
            ),
          ],
        );
      },
    );
  }
}

class _NetworkVideoSettings extends StatelessWidget {
  const _NetworkVideoSettings({required this.source});

  final Source source;

  static const _help = {
    NetworkVideoKind.droidcam:
        'On the phone: install DroidCam (Android/iPhone) and open it. Enter the "WiFi IP" it shows. '
            'Both devices must be on the same Wi-Fi. Only one app can use the phone\'s feed at a time.',
    NetworkVideoKind.ipWebcam:
        'On an Android phone: install IP Webcam, tap "Start server" and enter the IP it shows '
            '(e.g. 192.168.1.23). Both devices must be on the same Wi-Fi.',
    NetworkVideoKind.mjpeg:
        'Any camera that serves Motion JPEG over HTTP, e.g. http://192.168.1.50/video or '
            'http://user:password@camera.local/mjpg/video.mjpg',
    NetworkVideoKind.stream: 'HLS (.m3u8) or HTTP video URL, e.g. a stream from another encoder.',
  };

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final s = source.settings;
    final kind = NetworkVideoKind.fromName(s['kind'] as String?);
    void set(String k, Object v) => scope.studio.updateSourceSettings(source.id, {k: v});

    return ListenableBuilder(
      listenable: scope.networkVideo,
      builder: (context, _) {
        final feed = scope.networkVideo.feed(source.id);
        final (statusText, statusColor) = switch (feed?.state) {
          null => (networkVideoUrl(s) == null ? 'Not set up yet' : 'Not connected (source hidden)', ObsColors.textDim),
          FeedState.live => (
              'Live · ${feed!.width}x${feed.height}${feed.fps > 0 ? ' · ${feed.fps.toStringAsFixed(0)} fps' : ''}',
              ObsColors.ok
            ),
          FeedState.connecting => ('Connecting…', ObsColors.textDim),
          FeedState.retrying => ('Reconnecting… ${feed!.error ?? ''}', ObsColors.warn),
          FeedState.error => (feed!.error ?? 'Error', ObsColors.live),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<NetworkVideoKind>(
              initialValue: kind,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Source'),
              items: [for (final k in NetworkVideoKind.values) DropdownMenuItem(value: k, child: Text(k.label))],
              onChanged: (k) => k == null ? null : set('kind', k.name),
            ),
            const SizedBox(height: 12),
            if (kind.usesHost) ...[
              _SettingTextField(
                key: ValueKey('host-${kind.name}'),
                label: 'Phone IP address',
                hint: kind == NetworkVideoKind.droidcam ? 'e.g. 192.168.1.23 (port ${kind.defaultPort})' : 'e.g. 192.168.1.23',
                initial: s['host'] as String? ?? '',
                keyboard: TextInputType.url,
                onSubmitted: (v) => set('host', v.trim()),
              ),
              if (kind == NetworkVideoKind.droidcam) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: const ['auto', '640x480', '1280x720', '1920x1080'].contains(s['resolution'])
                      ? s['resolution'] as String
                      : 'auto',
                  decoration: const InputDecoration(labelText: 'Resolution'),
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('As set in the DroidCam app')),
                    DropdownMenuItem(value: '640x480', child: Text('640x480')),
                    DropdownMenuItem(value: '1280x720', child: Text('1280x720 (DroidCam Pro/OBS)')),
                    DropdownMenuItem(value: '1920x1080', child: Text('1920x1080 (DroidCam Pro/OBS)')),
                  ],
                  onChanged: (v) => set('resolution', v ?? 'auto'),
                ),
              ],
              const SizedBox(height: 12),
              const Text('Phone camera', style: TextStyle(color: ObsColors.textDim)),
              const SizedBox(height: 6),
              if (kind == NetworkVideoKind.ipWebcam)
                SegmentedButton<String>(
                  key: const ValueKey('phone-camera'),
                  segments: const [
                    ButtonSegment(value: 'back', label: Text('Back'), icon: Icon(Icons.camera_rear)),
                    ButtonSegment(value: 'front', label: Text('Front'), icon: Icon(Icons.camera_front)),
                    ButtonSegment(value: 'app', label: Text('As in the app')),
                  ],
                  selected: {
                    switch (s['phoneCamera']) { 'front' => 'front', 'back' => 'back', _ => 'app' },
                  },
                  onSelectionChanged: (v) => set('phoneCamera', v.first),
                )
              else
                const Text(
                  'DroidCam: tap the switch-camera button in the DroidCam app on the phone to use its front '
                  'or back camera. DroidCam doesn\'t let other apps switch it; IP Webcam does.',
                  key: ValueKey('droidcam-camera-help'),
                  style: TextStyle(color: ObsColors.textDim, fontSize: 13),
                ),
            ] else
              _SettingTextField(
                key: ValueKey('url-${kind.name}'),
                label: 'URL',
                hint: kind == NetworkVideoKind.stream ? 'https://…/index.m3u8' : 'http://192.168.1.50/video',
                initial: s['url'] as String? ?? '',
                keyboard: TextInputType.url,
                onSubmitted: (v) => set('url', v.trim()),
              ),
            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.circle, size: 10, color: statusColor),
              const SizedBox(width: 8),
              Expanded(child: Text(statusText, style: TextStyle(color: statusColor))),
              if (feed != null)
                TextButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect'),
                  onPressed: () => scope.networkVideo.reconnect(source.id),
                ),
            ]),
            if (networkVideoUrl(s) case final url?)
              Text(url, style: const TextStyle(color: ObsColors.textDim, fontSize: 12)),
            const SizedBox(height: 12),
            Text(_help[kind]!, style: const TextStyle(color: ObsColors.textDim, fontSize: 13)),
            const SizedBox(height: 8),
            const Text(
              'Iriun Webcam uses a closed protocol that only its own desktop driver understands, so it '
              'can\'t be received here. DroidCam or IP Webcam do the same job for free.',
              style: TextStyle(color: ObsColors.textDim, fontSize: 12),
            ),
          ],
        );
      },
    );
  }
}

/// Text field that applies on submit / focus loss (not on every keystroke,
/// which would reconnect the camera for each character).
class _SettingTextField extends StatefulWidget {
  const _SettingTextField({
    super.key,
    required this.label,
    required this.initial,
    required this.onSubmitted,
    this.hint,
    this.keyboard,
  });

  final String label;
  final String? hint;
  final String initial;
  final TextInputType? keyboard;
  final ValueChanged<String> onSubmitted;

  @override
  State<_SettingTextField> createState() => _SettingTextFieldState();
}

class _SettingTextFieldState extends State<_SettingTextField> {
  late final _ctl = TextEditingController(text: widget.initial);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _ctl.text != widget.initial) widget.onSubmitted(_ctl.text);
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _ctl,
        focusNode: _focus,
        keyboardType: widget.keyboard,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          suffixIcon: IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Apply',
            onPressed: () => widget.onSubmitted(_ctl.text),
          ),
        ),
        onSubmitted: widget.onSubmitted,
      );
}

/// Resolution, zoom, torch, exposure and focus for the tablet's cameras.
class _CameraControls extends StatelessWidget {
  const _CameraControls({required this.source});

  final Source source;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final s = source.settings;
    void set(String k, Object v) => scope.studio.updateSourceSettings(source.id, {k: v});
    return ListenableBuilder(
      listenable: scope.cameras,
      builder: (context, _) {
        final caps = scope.cameras.capsFor(s['lens'] as String? ?? 'front');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: const ['medium', 'high', 'veryHigh', 'ultraHigh', 'max'].contains(s['resolution'])
                  ? s['resolution'] as String
                  : 'high',
              decoration: const InputDecoration(labelText: 'Resolution'),
              items: const [
                DropdownMenuItem(value: 'medium', child: Text('480p (lightest)')),
                DropdownMenuItem(value: 'high', child: Text('720p (recommended)')),
                DropdownMenuItem(value: 'veryHigh', child: Text('1080p')),
                DropdownMenuItem(value: 'ultraHigh', child: Text('4K (if supported)')),
                DropdownMenuItem(value: 'max', child: Text('Highest available')),
              ],
              onChanged: (v) => set('resolution', v ?? 'high'),
            ),
            if (caps != null && caps.maxZoom > caps.minZoom)
              LabeledSlider(
                label: 'Zoom',
                value: ((s['zoom'] as num?)?.toDouble() ?? 1).clamp(caps.minZoom, caps.maxZoom),
                min: caps.minZoom,
                max: caps.maxZoom.clamp(caps.minZoom, 10),
                format: (v) => '${v.toStringAsFixed(1)}x',
                onChanged: (v) => set('zoom', v),
              ),
            if (caps != null && caps.maxExposure > caps.minExposure)
              LabeledSlider(
                label: 'Exposure',
                value: ((s['exposure'] as num?)?.toDouble() ?? 0).clamp(caps.minExposure, caps.maxExposure),
                min: caps.minExposure,
                max: caps.maxExposure,
                format: (v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} EV',
                onChanged: (v) => set('exposure', v),
              ),
            if (caps?.hasTorch ?? false)
              SwitchListTile(
                title: const Text('Torch (light)'),
                value: s['torch'] == true,
                onChanged: (v) => set('torch', v),
              ),
            SwitchListTile(
              title: const Text('Lock focus'),
              subtitle: const Text('Stops the camera hunting for focus when things move in front of it'),
              value: s['focusLocked'] == true,
              onChanged: (v) => set('focusLocked', v),
            ),
            if (caps == null)
              const Text('More controls appear while the camera is running.',
                  style: TextStyle(color: ObsColors.textDim, fontSize: 13)),
          ],
        );
      },
    );
  }
}
