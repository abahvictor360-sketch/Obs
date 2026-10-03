import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../render/filter_view.dart';
import 'dialogs.dart';
import 'theme.dart';

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

  List<FilterKind> get _available => [
        if (widget.source.type.isVisual) ...FilterKind.values.where((k) => !k.isAudio),
        if (widget.source.type.hasAudio) FilterKind.gain,
      ];

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final filters = widget.source.filters;
    final selected = filters.where((f) => f.id == _selected).firstOrNull ?? filters.firstOrNull;
    final legacy = widget.item != null && !widget.item!.color.isNeutral;

    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
          child: Text(
            widget.source.type.isVisual ? 'Effect Filters' : 'Audio Filters',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        PopupMenuButton<FilterKind>(
          key: const ValueKey('add-filter'),
          tooltip: 'Add filter',
          icon: const Icon(Icons.add),
          itemBuilder: (context) => [
            for (final k in _available)
              PopupMenuItem(
                value: k,
                enabled: !k.usesShader || FilterShaders.supported,
                child: Text(k.usesShader && !FilterShaders.supported ? '${k.label} (needs a newer device)' : k.label),
              ),
          ],
          onSelected: (k) {
            final f = studio.addFilter(widget.source.id, k);
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
            onReorderItem: (from, to) => studio.moveFilter(widget.source.id, filters[from].id, to),
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
                      onPressed: () => studio.updateFilter(widget.source.id, f.id, enabled: !f.enabled),
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
                          studio.removeFilter(widget.source.id, f.id);
                        } else {
                          final name = await promptText(context, title: 'Rename filter', initial: f.name);
                          if (name != null) studio.updateFilter(widget.source.id, f.id, name: name);
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
        _FilterSettings(source: widget.source, filter: selected),
      ],
      if (legacy) ...[
        const Divider(height: 32),
        const Text('Older color settings on this item', style: TextStyle(color: ObsColors.textDim)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset them (use a Color Correction filter instead)'),
            onPressed: () => studio.updateColor(widget.item!.id, (c) {
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
