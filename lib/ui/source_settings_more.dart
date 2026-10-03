import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../browser/browser_source.dart';
import '../core/models.dart';
import '../render/slideshow.dart';
import 'dialogs.dart' show LabeledSlider;
import 'media_import.dart';
import 'theme.dart';

/// Image Slide Show: the image list (add from files or gallery, reorder,
/// remove), timing and transition.
class SlideShowSettings extends StatelessWidget {
  const SlideShowSettings({super.key, required this.source});

  final Source source;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final s = source.settings;
    final paths = List<String>.from((s['paths'] as List? ?? const []).cast<String>());
    void set(String k, Object v) => studio.updateSourceSettings(source.id, {k: v});
    void setPaths(List<String> p) => set('paths', p);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          icon: const Icon(Icons.folder_open),
          label: const Text('Add from files…'),
          onPressed: () async {
            final picked = await pickMediaFiles(context, MediaKind.image);
            if (picked.isNotEmpty) setPaths([...paths, ...picked]);
          },
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Add from gallery…'),
          onPressed: () async {
            final picked = await ImagePicker().pickMultiImage();
            if (picked.isNotEmpty) setPaths([...paths, ...picked.map((f) => f.path)]);
          },
        ),
        if (paths.isNotEmpty)
          TextButton.icon(
            icon: const Icon(Icons.clear_all),
            label: const Text('Remove all'),
            onPressed: () => setPaths([]),
          ),
      ]),
      const SizedBox(height: 8),
      if (paths.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('No images yet', style: TextStyle(color: ObsColors.textDim)),
        )
      else
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          decoration: BoxDecoration(border: Border.all(color: ObsColors.border), borderRadius: BorderRadius.circular(6)),
          child: ReorderableListView.builder(
            shrinkWrap: true,
            buildDefaultDragHandles: false,
            itemCount: paths.length,
            onReorderItem: (from, to) {
              final p = List<String>.from(paths);
              p.insert(to, p.removeAt(from));
              setPaths(p);
            },
            itemBuilder: (context, i) => ListTile(
              key: ValueKey('slide-$i-${paths[i]}'),
              dense: true,
              leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_indicator)),
              title: Text('${i + 1}. ${paths[i].split('/').last}', overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setPaths(List<String>.from(paths)..removeAt(i)),
              ),
            ),
          ),
        ),
      const SizedBox(height: 12),
      LabeledSlider(
        label: 'Time between slides',
        value: ((s['slideMs'] as num?)?.toDouble() ?? 5000).clamp(1000, 60000),
        min: 1000,
        max: 60000,
        format: (v) => '${(v / 1000).toStringAsFixed(1)} s',
        onChanged: (v) => set('slideMs', (v / 100).round() * 100),
      ),
      const SizedBox(height: 8),
      const Text('Transition', style: TextStyle(color: ObsColors.textDim)),
      const SizedBox(height: 6),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'cut', label: Text('Cut')),
          ButtonSegment(value: 'fade', label: Text('Fade')),
          ButtonSegment(value: 'slide', label: Text('Slide')),
          ButtonSegment(value: 'swipe', label: Text('Swipe')),
        ],
        selected: {s['transition'] as String? ?? 'fade'},
        onSelectionChanged: (v) => set('transition', v.first),
      ),
      if (s['transition'] != 'cut')
        LabeledSlider(
          label: 'Transition speed',
          value: ((s['transitionMs'] as num?)?.toDouble() ?? 700).clamp(100, 3000),
          min: 100,
          max: 3000,
          format: (v) => '${v.round()} ms',
          onChanged: (v) => set('transitionMs', v.round()),
        ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Loop'),
        value: s['loop'] as bool? ?? true,
        onChanged: (v) => set('loop', v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Randomize playback'),
        value: s['random'] as bool? ?? false,
        onChanged: (v) => set('random', v),
      ),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.skip_previous),
          label: const Text('Previous'),
          onPressed: () {
            SlideShowClock.skip(source.id, -1);
            studio.updateSourceSettings(source.id, {});
          },
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.skip_next),
          label: const Text('Next'),
          onPressed: () {
            SlideShowClock.skip(source.id, 1);
            studio.updateSourceSettings(source.id, {});
          },
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.restart_alt),
          label: const Text('Restart'),
          onPressed: () {
            SlideShowClock.restart(source.id);
            studio.updateSourceSettings(source.id, {});
          },
        ),
      ]),
    ]);
  }
}

/// Browser source: URL or local HTML file, page size, frame rate, CSS.
class BrowserSettings extends StatefulWidget {
  const BrowserSettings({super.key, required this.source});

  final Source source;

  @override
  State<BrowserSettings> createState() => _BrowserSettingsState();
}

class _BrowserSettingsState extends State<BrowserSettings> {
  late final _url = TextEditingController(text: widget.source.settings['url'] as String? ?? '');
  late final _css = TextEditingController(text: widget.source.settings['css'] as String? ?? '');
  late final _w = TextEditingController(text: '${(widget.source.settings['width'] as num?)?.round() ?? 1280}');
  late final _h = TextEditingController(text: '${(widget.source.settings['height'] as num?)?.round() ?? 720}');

  @override
  void dispose() {
    for (final c in [_url, _css, _w, _h]) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(String k, Object v) => AppScope.of(context).studio.updateSourceSettings(widget.source.id, {k: v});

  void _applyUrl() {
    var u = _url.text.trim();
    if (u.isNotEmpty && !u.startsWith('/') && !u.contains('://')) u = 'https://$u';
    if (u != _url.text) _url.text = u;
    _set('url', u);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.source.settings;
    final local = (s['url'] as String? ?? '').startsWith('/');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _url,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: local ? 'Local file' : 'URL',
          hintText: 'https://… (alerts, chat, overlay widget)',
          suffixIcon: IconButton(icon: const Icon(Icons.check), tooltip: 'Load', onPressed: _applyUrl),
        ),
        onSubmitted: (_) => _applyUrl(),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.folder_open),
          label: const Text('Local HTML file…'),
          onPressed: () async {
            final p = await pickMediaFile(context, MediaKind.html);
            if (p != null) {
              _url.text = p;
              _set('url', p);
            }
          },
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh page'),
          onPressed: () => _set('refresh', DateTime.now().millisecondsSinceEpoch),
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _w,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Width'),
            onSubmitted: (v) => _set('width', (double.tryParse(v) ?? 1280).clamp(16, 3840)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _h,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Height'),
            onSubmitted: (v) => _set('height', (double.tryParse(v) ?? 720).clamp(16, 2160)),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      LabeledSlider(
        label: 'FPS',
        value: ((s['fps'] as num?)?.toDouble() ?? 15).clamp(1, 30),
        min: 1,
        max: 30,
        format: (v) => '${v.round()}',
        onChanged: (v) => _set('fps', v.round()),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _css,
        maxLines: 4,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: InputDecoration(
          labelText: 'Custom CSS',
          suffixIcon: IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Apply',
            onPressed: () => _set('css', _css.text),
          ),
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Shut down source when not visible'),
        subtitle: const Text('Off: the page keeps running (and playing sound) in every scene'),
        value: s['shutdown'] as bool? ?? true,
        onChanged: (v) => _set('shutdown', v),
      ),
      const SizedBox(height: 4),
      Text(
        BrowserSourceService.instance.supported
            ? 'The page is drawn at up to the FPS above; transparent pages stay see-through. '
                'Page sound plays on the tablet: add an Audio Output Capture source to put it on stream.'
            : 'Browser sources run in the Android and iPad apps.',
        style: const TextStyle(color: ObsColors.textDim, fontSize: 13),
      ),
    ]);
  }
}

/// Audio Output Capture ("Desktop Audio"): other apps' sound, captured with
/// the system's screen-recording permission.
class AudioOutputSettings extends StatelessWidget {
  const AudioOutputSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final out = AppScope.of(context).output;
    return ListenableBuilder(
      listenable: out,
      builder: (context, _) {
        final st = out.screenState;
        final ios = Theme.of(context).platform == TargetPlatform.iOS;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(st.active ? Icons.volume_up : Icons.volume_off_outlined,
                color: st.active ? ObsColors.ok : ObsColors.textDim),
            title: Text(st.active ? 'Capturing app audio' : 'Not capturing'),
            subtitle: st.error == null ? null : Text(st.error!, style: const TextStyle(color: ObsColors.warn)),
          ),
          if (!out.screenCaptureSupported)
            const Text('Audio output capture is not available on this platform.',
                style: TextStyle(color: ObsColors.textDim))
          else
            FilledButton.icon(
              icon: Icon(st.active ? Icons.stop : Icons.play_arrow),
              label: Text(st.active ? 'Stop audio capture' : 'Start audio capture'),
              style: st.active ? FilledButton.styleFrom(backgroundColor: ObsColors.live) : null,
              onPressed: st.active ? out.stopScreenCapture : out.startScreenCapture,
            ),
          const SizedBox(height: 16),
          Text(
            ios
                ? 'iPadOS only shares other apps\' sound through a screen broadcast: choose "ObsPad Screen" '
                    'and tap Start Broadcast. Only the sound is used unless a scene also has a Screen Capture '
                    'source.'
                : 'Android captures other apps\' sound (music, games, videos, browser sources) with its '
                    'screen-recording permission. Only the sound is used unless a scene also has a Screen '
                    'Capture source. Some apps block capture (calls, protected media).',
            style: const TextStyle(color: ObsColors.textDim, fontSize: 13),
          ),
          const SizedBox(height: 8),
          const Text('Use the Audio Mixer fader for its volume.', style: TextStyle(color: ObsColors.textDim, fontSize: 13)),
        ]);
      },
    );
  }
}
