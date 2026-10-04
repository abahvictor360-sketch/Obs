import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../render/filter_view.dart';
import 'dialogs.dart';
import 'media_import.dart';
import 'theme.dart';

/// Edit › Filters with nothing selected: the Filters window on its own,
/// starting with [sourceId] or the first source that takes filters.
Future<void> showFiltersWindow(BuildContext context, {String? sourceId}) async {
  final studio = AppScope.of(context).studio;
  final choices = studio.sources.where((s) => s.type.isVisual || s.type.hasAudio);
  final source = (sourceId == null ? null : studio.sourceById(sourceId)) ?? choices.firstOrNull;
  if (source == null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add a source first')));
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 760),
    barrierColor: Colors.black26,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.8,
      child: Column(children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(children: [
            Icon(Icons.auto_awesome_outlined, color: ObsColors.textDim),
            SizedBox(width: 10),
            Text('Filters', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ]),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: studio,
            builder: (context, _) => FiltersPanel(key: const ValueKey('filters-window'), source: source),
          ),
        ),
      ]),
    ),
  );
}

/// OBS's Filters window: the source's filter chain (add, remove, reorder,
/// enable/disable, rename) and the selected filter's settings. Filters
/// belong to the source, so they apply in every scene it's used in.
class FiltersPanel extends StatefulWidget {
  const FiltersPanel({super.key, required this.source, this.item});

  final Source source;

  /// The scene item the panel was opened from (for older per-item color
  /// settings).
  final SceneItem? item;

  @override
  State<FiltersPanel> createState() => _FiltersPanelState();
}

class _FiltersPanelState extends State<FiltersPanel> {
  String? _selected;

  /// The source whose filters are shown; switch with the picker at the top.
  String? _sourceId;

  @override
  void didUpdateWidget(FiltersPanel old) {
    super.didUpdateWidget(old);
    if (old.source.id != widget.source.id) _sourceId = null;
  }

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final source = (_sourceId == null ? null : studio.sourceById(_sourceId!)) ?? widget.source;
    final available = [
      if (source.type.isVisual) ...FilterKind.values.where((k) => !k.isAudio),
      if (source.type.hasAudio) FilterKind.gain,
      if (source.type == SourceType.audioInput) ...FilterKind.values.where((k) => k.micOnly),
    ];
    final filters = source.filters;
    final selected = filters.where((f) => f.id == _selected).firstOrNull ?? filters.firstOrNull;
    final item = source.id == widget.source.id ? widget.item : null;
    final legacy = item != null && !item.color.isNeutral;
    final choices = studio.sources.where((s) => s.type.isVisual || s.type.hasAudio).toList();

    return ListView(padding: const EdgeInsets.all(16), children: [
      // Like OBS's Filters window: pick any source and edit its filters.
      DropdownButtonFormField<String>(
        key: const ValueKey('filters-source'),
        initialValue: source.id,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Source', isDense: true, prefixIcon: Icon(Icons.layers_outlined)),
        items: [
          for (final s in choices)
            DropdownMenuItem(
              value: s.id,
              child: Text(
                '${s.name}  ·  ${s.type.label}${s.filters.isEmpty ? '' : '  (${s.filters.length})'}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (id) => setState(() {
          _sourceId = id;
          _selected = null;
        }),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: Text(
            source.type.isVisual ? 'Effect Filters' : 'Audio Filters',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        PopupMenuButton<String>(
          key: const ValueKey('filters-more'),
          tooltip: 'Copy or paste filters',
          icon: const Icon(Icons.more_horiz),
          itemBuilder: (context) => [
            PopupMenuItem(value: 'copy', enabled: filters.isNotEmpty, child: const Text('Copy Filters')),
            PopupMenuItem(
              value: 'paste',
              enabled: studio.filterClipboard?.isNotEmpty ?? false,
              child: const Text('Paste Filters'),
            ),
          ],
          onSelected: (v) {
            if (v == 'copy') {
              studio.copyFilters(source.id);
            } else {
              final n = studio.pasteFilters(source.id);
              if (n == 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('None of the copied filters fit this source')));
              }
              setState(() {});
            }
          },
        ),
        PopupMenuButton<FilterKind>(
          key: const ValueKey('add-filter'),
          tooltip: 'Add filter',
          icon: const Icon(Icons.add),
          itemBuilder: (context) => [
            for (final k in available)
              PopupMenuItem(
                value: k,
                enabled: !k.usesShader || FilterShaders.supported,
                child: Text(k.usesShader && !FilterShaders.supported ? '${k.label} (needs a newer device)' : k.label),
              ),
          ],
          onSelected: (k) {
            final f = studio.addFilter(source.id, k);
            setState(() => _selected = f.id);
          },
        ),
      ]),
      const SizedBox(height: 4),
      if (filters.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('No filters. Tap + to add one (Chroma Key, Color Correction, Blur…).',
              style: TextStyle(color: ObsColors.textDim)),
        )
      else
        Container(
          decoration: BoxDecoration(border: Border.all(color: ObsColors.border), borderRadius: BorderRadius.circular(6)),
          child: ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => studio.moveFilter(source.id, filters[from].id, to),
            children: [
              for (final (i, f) in filters.indexed)
                ListTile(
                  key: ValueKey('filter-${f.id}'),
                  dense: true,
                  selected: f.id == selected?.id,
                  selectedTileColor: ObsColors.accentDim.withValues(alpha: 0.35),
                  onTap: () => setState(() => _selected = f.id),
                  leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_indicator)),
                  title: Text(f.name, overflow: TextOverflow.ellipsis),
                  subtitle: f.kind.usesShader && !FilterShaders.supported
                      ? const Text('Not supported on this device', style: TextStyle(color: ObsColors.warn))
                      : null,
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      key: ValueKey('filter-toggle-${f.id}'),
                      tooltip: f.enabled ? 'Disable' : 'Enable',
                      icon: Icon(f.enabled ? Icons.visibility : Icons.visibility_off, size: 20),
                      onPressed: () => studio.updateFilter(source.id, f.id, enabled: !f.enabled),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'More',
                      icon: const Icon(Icons.more_vert, size: 20),
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(value: 'remove', child: Text('Remove')),
                      ],
                      onSelected: (v) async {
                        if (v == 'remove') {
                          studio.removeFilter(source.id, f.id);
                        } else {
                          final name = await promptText(context, title: 'Rename filter', initial: f.name);
                          if (name != null) studio.updateFilter(source.id, f.id, name: name);
                        }
                      },
                    ),
                  ]),
                ),
            ],
          ),
        ),
      if (selected != null) ...[
        const SizedBox(height: 16),
        Text(selected.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        _FilterSettings(source: source, filter: selected),
      ],
      if (legacy) ...[
        const Divider(height: 32),
        const Text('Older color settings on this item', style: TextStyle(color: ObsColors.textDim)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset them (use a Color Correction filter instead)'),
            onPressed: () => studio.updateColor(item.id, (c) {
              c
                ..opacity = 1
                ..brightness = 0
                ..contrast = 0
                ..saturation = 0;
            }),
          ),
        ),
      ],
    ]);
  }
}

/// Apply LUT: the LUT file (.cube, or an OBS-style PNG), copied into the
/// app so it keeps working after a restart.
class _LutPicker extends StatelessWidget {
  const _LutPicker({required this.source, required this.filter});

  final Source source;
  final SourceFilter filter;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final path = filter.settings['path'] as String? ?? '';
    final name = path.isEmpty ? 'No LUT file' : path.split(RegExp(r'[/\\]')).last;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        const Icon(Icons.palette_outlined, color: ObsColors.textDim),
        const SizedBox(width: 10),
        Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
        if (AppScope.of(context).plugins.luts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PopupMenuButton<String>(
              key: const ValueKey('lut-plugins'),
              tooltip: 'LUTs from plugins',
              icon: const Icon(Icons.extension_outlined),
              itemBuilder: (_) => [
                for (final (p, name, path) in AppScope.of(context).plugins.luts)
                  PopupMenuItem(value: path, child: Text('$name  ·  ${p.manifest.name}')),
              ],
              onSelected: (path) => studio.updateFilter(source.id, filter.id, values: {'path': path}),
            ),
          ),
        OutlinedButton.icon(
          key: const ValueKey('lut-browse'),
          icon: const Icon(Icons.folder_open, size: 18),
          label: const Text('Browse…'),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            final picked = await pickMediaFile(context, MediaKind.lut);
            if (picked == null) return;
            final error = await LutCache.validate(picked);
            if (error != null) {
              messenger.showSnackBar(SnackBar(content: Text(error)));
              return;
            }
            studio.updateFilter(source.id, filter.id, values: {'path': picked});
          },
        ),
      ]),
    );
  }
}

class _FilterSettings extends StatelessWidget {
  const _FilterSettings({required this.source, required this.filter});

  final Source source;
  final SourceFilter filter;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final f = filter;
    void set(String k, Object v) => studio.updateFilter(source.id, f.id, values: {k: v});
    Widget slider(String label, String key, double min, double max, String Function(double) fmt, {double def = 0}) =>
        LabeledSlider(
          label: label,
          value: f.dbl(key, def).clamp(min, max),
          min: min,
          max: max,
          format: fmt,
          onChanged: (v) => set(key, v),
        );
    String pct(double v) => '${(v * 100).round()}%';
    String signed(double v) => '${v >= 0 ? '+' : ''}${(v * 100).round()}';
    String whole(double v) => '${v.round()}';
    String db(double v) => '${v.toStringAsFixed(1)} dB';
    String ms(double v) => '${v.round()} ms';

    Widget keyColor() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Key color', style: TextStyle(color: ObsColors.textDim)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'green', label: Text('Green')),
              ButtonSegment(value: 'blue', label: Text('Blue')),
              ButtonSegment(value: 'magenta', label: Text('Magenta')),
              ButtonSegment(value: 'custom', label: Text('Custom')),
            ],
            selected: {f.settings['keyColor'] as String? ?? 'green'},
            onSelectionChanged: (v) => set('keyColor', v.first),
          ),
          if (f.settings['keyColor'] == 'custom') ...[
            const SizedBox(height: 8),
            ColorPickerField(
              label: 'Custom color',
              value: (f.settings['customColor'] as num?)?.toInt() ?? 0xFF00FF00,
              onChanged: (v) => set('customColor', v),
            ),
          ],
          const SizedBox(height: 8),
        ]);

    final children = switch (f.kind) {
      FilterKind.colorCorrection => [
          slider('Gamma', 'gamma', -1, 1, signed),
          slider('Contrast', 'contrast', -1, 1, signed),
          slider('Brightness', 'brightness', -1, 1, signed),
          slider('Saturation', 'saturation', -1, 1, signed),
          slider('Hue shift', 'hue', -180, 180, (v) => '${v.round()}°'),
          slider('Opacity', 'opacity', 0, 1, pct, def: 1),
          const SizedBox(height: 8),
          ColorPickerField(
            label: 'Color multiply',
            value: (f.settings['multiply'] as num?)?.toInt() ?? 0xFFFFFFFF,
            onChanged: (v) => set('multiply', v),
          ),
        ],
      FilterKind.applyLut => [_LutPicker(source: source, filter: f), slider('Amount', 'amount', 0, 1, pct, def: 1)],
      FilterKind.chromaKey => [
          keyColor(),
          slider('Similarity', 'similarity', 1, 1000, whole, def: 400),
          slider('Smoothness', 'smoothness', 1, 1000, whole, def: 80),
          slider('Key color spill reduction', 'spill', 1, 1000, whole, def: 100),
          slider('Opacity', 'opacity', 0, 1, pct, def: 1),
        ],
      FilterKind.colorKey => [
          keyColor(),
          slider('Similarity', 'similarity', 1, 1000, whole, def: 80),
          slider('Smoothness', 'smoothness', 1, 1000, whole, def: 50),
          slider('Opacity', 'opacity', 0, 1, pct, def: 1),
        ],
      FilterKind.lumaKey => [
          slider('Luma max', 'lumaMax', 0, 1, pct, def: 1),
          slider('Luma max smooth', 'lumaMaxSmooth', 0, 1, pct),
          slider('Luma min', 'lumaMin', 0, 1, pct),
          slider('Luma min smooth', 'lumaMinSmooth', 0, 1, pct),
        ],
      FilterKind.sharpen => [slider('Sharpness', 'amount', 0, 1, pct, def: 0.08)],
      FilterKind.blur => [slider('Radius', 'radius', 0, 100, (v) => '${v.round()} px', def: 8)],
      FilterKind.scroll => [
          slider('Horizontal speed', 'speedX', -500, 500, (v) => '${v.round()} px/s'),
          slider('Vertical speed', 'speedY', -500, 500, (v) => '${v.round()} px/s'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Loop'),
            value: f.settings['loop'] as bool? ?? true,
            onChanged: (v) => set('loop', v),
          ),
        ],
      FilterKind.mask => [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'rounded', label: Text('Rounded corners')),
              ButtonSegment(value: 'circle', label: Text('Circle / oval')),
            ],
            selected: {f.settings['shape'] as String? ?? 'rounded'},
            onSelectionChanged: (v) => set('shape', v.first),
          ),
          if (f.settings['shape'] != 'circle') slider('Corner radius', 'radius', 0, 0.5, pct, def: 0.1),
        ],
      FilterKind.gain => [slider('Gain', 'db', -30, 30, (v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} dB')],
      FilterKind.noiseSuppression => [
          const Text(
            'Removes steady background noise (fans, hum, traffic) using the tablet\'s own noise reduction. '
            'Add a Noise Gate after it to silence the mic between sentences.',
            style: TextStyle(color: ObsColors.textDim, fontSize: 13),
          ),
        ],
      FilterKind.noiseGate => [
          slider('Close threshold', 'closeDb', -96, 0, db, def: -32),
          slider('Open threshold', 'openDb', -96, 0, db, def: -26),
          slider('Attack time', 'attackMs', 1, 500, ms, def: 25),
          slider('Hold time', 'holdMs', 1, 2000, ms, def: 200),
          slider('Release time', 'releaseMs', 1, 2000, ms, def: 150),
        ],
      FilterKind.compressor => [
          slider('Ratio', 'ratio', 1, 32, (v) => '${v.toStringAsFixed(1)}:1', def: 10),
          slider('Threshold', 'thresholdDb', -60, 0, db, def: -18),
          slider('Attack', 'attackMs', 1, 500, ms, def: 6),
          slider('Release', 'releaseMs', 1, 1000, ms, def: 60),
          slider('Output gain', 'outputDb', -32, 32, db, def: 0),
        ],
      FilterKind.limiter => [
          slider('Threshold', 'thresholdDb', -60, 0, db, def: -6),
          slider('Release', 'releaseMs', 1, 1000, ms, def: 60),
        ],
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...children,
      if (f.kind.usesShader && !FilterShaders.supported)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'This filter needs the Impeller graphics engine, which this device or build does not use. '
            'It is kept but has no effect here.',
            style: TextStyle(color: ObsColors.warn, fontSize: 13),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.restart_alt),
          label: const Text('Defaults'),
          onPressed: () => studio.updateFilter(source.id, f.id, values: f.kind.defaults),
        ),
      ),
    ]);
  }
}
