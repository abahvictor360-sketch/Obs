import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import 'media_import.dart';
import 'source_properties.dart';
import 'theme.dart';

/// OBS's source toolbar (context bar) under the canvas: the selected
/// source's name, Properties and Filters, and its most used setting
/// (image file, video file, text, web page) for quick changes.
class SourceContextBar extends StatelessWidget {
  const SourceContextBar({super.key});

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        final item = studio.selectedItem;
        final source = item == null ? null : studio.sourceById(item.sourceId);
        return Container(
          key: const ValueKey('context-bar'),
          height: 48,
          margin: const EdgeInsets.fromLTRB(6, 4, 6, 0),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: ObsColors.header, borderRadius: BorderRadius.circular(6)),
          child: item == null || source == null
              ? const Row(children: [
                  Icon(Icons.layers_outlined, size: 18, color: ObsColors.textDim),
                  SizedBox(width: 10),
                  Text('No source selected', style: TextStyle(color: ObsColors.textDim)),
                ])
              : Row(children: [
                  Icon(sourceIcon(source.type), size: 18, color: ObsColors.text),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(source.name.toUpperCase(),
                        overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 16),
                  _BarButton(
                    key: const ValueKey('context-properties'),
                    icon: Icons.settings,
                    label: 'Properties',
                    onPressed: () => showSourceProperties(context, item.id),
                  ),
                  const SizedBox(width: 6),
                  if (source.type.isVisual || source.type.hasAudio)
                    _BarButton(
                      key: const ValueKey('context-filters'),
                      icon: Icons.auto_awesome_outlined,
                      label: 'Filters',
                      onPressed: () => showSourceFilters(context, item.id),
                    ),
                  const SizedBox(width: 12),
                  Expanded(child: _QuickSetting(key: ValueKey('quick-${source.id}'), source: source)),
                ]),
        );
      },
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({super.key, required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        style: TextButton.styleFrom(
          backgroundColor: ObsColors.panelAlt,
          foregroundColor: ObsColors.text,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 40),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        icon: Icon(icon, size: 16),
        label: Text(label),
        onPressed: onPressed,
      );
}

/// The one setting OBS shows in its context bar for each source type.
class _QuickSetting extends StatefulWidget {
  const _QuickSetting({super.key, required this.source});

  final Source source;

  @override
  State<_QuickSetting> createState() => _QuickSettingState();
}

class _QuickSettingState extends State<_QuickSetting> {
  late final _text = TextEditingController(text: _value);

  String get _key => switch (widget.source.type) {
        SourceType.text => 'text',
        SourceType.browser => 'url',
        _ => 'path',
      };

  String get _value => widget.source.settings[_key] as String? ?? '';

  @override
  void didUpdateWidget(_QuickSetting old) {
    super.didUpdateWidget(old);
    // Changed elsewhere (Properties): show it, unless it's being typed here.
    if (_text.text != _value && !FocusScope.of(context).hasFocus) _text.text = _value;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final s = widget.source;
    void set(Object v) => studio.updateSourceSettings(s.id, {_key: v});

    Widget label(String t) =>
        Padding(padding: const EdgeInsets.only(right: 8), child: Text(t, style: const TextStyle(fontSize: 13)));

    Widget field({required bool editable, String? hint, ValueChanged<String>? onSubmitted}) => Expanded(
          child: SizedBox(
            height: 40,
            child: TextField(
              key: const ValueKey('context-field'),
              controller: _text,
              readOnly: !editable,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                filled: true,
                fillColor: ObsColors.bg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: const OutlineInputBorder(borderSide: BorderSide.none),
              ),
              onChanged: editable && s.type == SourceType.text ? set : null,
              onSubmitted: onSubmitted,
            ),
          ),
        );

    Widget browse(MediaKind kind) => Padding(
          padding: const EdgeInsets.only(left: 6),
          child: _BarButton(
            key: const ValueKey('context-browse'),
            icon: Icons.folder_open,
            label: 'Browse',
            onPressed: () async {
              final picked = await pickMediaFile(context, kind);
              if (picked != null) {
                set(picked);
                _text.text = picked;
              }
            },
          ),
        );

    return switch (s.type) {
      SourceType.image => Row(children: [label('Image File'), field(editable: false), browse(MediaKind.image)]),
      SourceType.media => Row(children: [
          _MediaControls(source: s),
          const SizedBox(width: 10),
          label('Local File'),
          field(editable: false),
          browse(MediaKind.video),
        ]),
      SourceType.text => Row(children: [label('Text'), field(editable: true, hint: 'Type the text')]),
      SourceType.browser => Row(children: [
          label('URL'),
          field(
            editable: true,
            hint: 'https://…',
            onSubmitted: (v) {
              final url = BrowserDockConfig.normalizeUrl(v);
              _text.text = url;
              set(url);
            },
          ),
        ]),
      SourceType.color => Row(children: [
          label('Color'),
          Container(
            width: 48,
            height: 24,
            decoration: BoxDecoration(
              color: Color(s.settings['color'] as int? ?? 0xFF000000),
              border: Border.all(color: ObsColors.border),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ]),
      _ => const SizedBox.shrink(),
    };
  }
}

/// Play / pause / restart for a Media Source, with its position, like OBS's
/// media controls.
class _MediaControls extends StatelessWidget {
  const _MediaControls({required this.source});

  final Source source;

  static String _t(Duration d) {
    String p(int v) => v.toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:${p(d.inMinutes % 60)}:${p(d.inSeconds % 60)}' : '${p(d.inMinutes)}:${p(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final media = AppScope.of(context).media;
    return ListenableBuilder(
      listenable: media,
      builder: (context, _) {
        final c = media.controllerFor(source.id);
        if (c == null) {
          return const Text('Not playing', style: TextStyle(color: ObsColors.textDim, fontSize: 13));
        }
        return ValueListenableBuilder(
          valueListenable: c,
          builder: (context, v, _) => Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              key: const ValueKey('media-restart'),
              tooltip: 'Restart',
              icon: const Icon(Icons.replay, size: 20),
              onPressed: () {
                c.seekTo(Duration.zero);
                c.play();
              },
            ),
            IconButton(
              key: const ValueKey('media-play-pause'),
              tooltip: v.isPlaying ? 'Pause' : 'Play',
              icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow, size: 22),
              onPressed: () => v.isPlaying ? c.pause() : c.play(),
            ),
            Text('${_t(v.position)} / ${_t(v.duration)}',
                style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
          ]),
        );
      },
    );
  }
}
