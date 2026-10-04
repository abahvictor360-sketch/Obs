import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../output/output_engine.dart';
import 'add_source.dart';
import 'dialogs.dart';
import 'dock_layout.dart';
import 'filters_panel.dart';
import 'exit.dart';
import 'item_menu.dart';
import 'plugins_screen.dart';
import 'settings_screen.dart';
import 'source_properties.dart';
import 'theme.dart';

/// A panel with a title bar and an optional bottom toolbar, like OBS docks.
class Dock extends StatelessWidget {
  const Dock({super.key, required this.title, required this.child, this.toolbar = const [], this.showTitle = true});

  final String title;
  final Widget child;
  final List<Widget> toolbar;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ObsColors.panel,
        border: Border.all(color: ObsColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showTitle)
            Container(
              color: ObsColors.header,
              padding: const EdgeInsets.only(left: 12),
              height: 32,
              child: Row(children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ObsColors.textDim),
                  ),
                ),
                if (DockSlot.maybeOf(context) case final slot?)
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      key: ValueKey('close-dock-${slot.id}'),
                      tooltip: 'Close $title (reopen from the Docks menu)',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      color: ObsColors.textDim,
                      icon: const Icon(Icons.close),
                      onPressed: slot.onClose,
                    ),
                  ),
              ]),
            ),
          Expanded(child: child),
          if (toolbar.isNotEmpty)
            Container(
              height: 48,
              decoration: const BoxDecoration(
                color: ObsColors.header,
                border: Border(top: BorderSide(color: ObsColors.border)),
              ),
              child: LayoutBuilder(builder: (context, box) {
                // Narrow dock (many docks open): scroll the buttons instead
                // of overflowing; spacers need a bounded width.
                if (box.maxWidth >= toolbar.length * 56) return Row(children: toolbar);
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [for (final w in toolbar) if (w is! Spacer) w]),
                );
              }),
            ),
        ],
      ),
    );
  }
}

class DockButton extends StatelessWidget {
  const DockButton({super.key, required this.icon, required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon, size: 22),
        tooltip: tooltip,
        onPressed: onPressed,
        color: ObsColors.text,
        disabledColor: ObsColors.border,
      );
}

// -----------------------------------------------------------------------------

class ScenesDock extends StatelessWidget {
  const ScenesDock({super.key, this.showTitle = true});

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        final scenes = studio.scenes;
        final selectedId = studio.studioMode ? studio.collection.previewSceneId : studio.collection.programSceneId;
        final selIndex = scenes.indexWhere((s) => s.id == selectedId);
        return Dock(
          title: 'Scenes',
          showTitle: showTitle,
          toolbar: [
            DockButton(
              icon: Icons.add,
              tooltip: 'Add scene',
              onPressed: () async {
                final name = await promptText(context, title: 'Add Scene', initial: 'Scene ${scenes.length + 1}');
                if (name != null) studio.addScene(name);
              },
            ),
            DockButton(
              icon: Icons.remove,
              tooltip: 'Remove scene',
              onPressed: scenes.length <= 1 ? null : () => _remove(context, selectedId),
            ),
            DockButton(
              icon: Icons.more_horiz,
              tooltip: 'Scene options',
              onPressed: () => _sceneMenu(context, selectedId, null),
            ),
            const Spacer(),
            DockButton(
              icon: Icons.keyboard_arrow_up,
              tooltip: 'Move up',
              onPressed: selIndex > 0 ? () => studio.moveScene(selIndex, selIndex - 1) : null,
            ),
            DockButton(
              icon: Icons.keyboard_arrow_down,
              tooltip: 'Move down',
              onPressed: selIndex >= 0 && selIndex < scenes.length - 1
                  ? () => studio.moveScene(selIndex, selIndex + 1)
                  : null,
            ),
          ],
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: scenes.length,
            onReorderItem: studio.moveScene,
            itemBuilder: (context, i) {
              final s = scenes[i];
              final isProgram = s.id == studio.collection.programSceneId;
              final isSelected = s.id == selectedId;
              return ReorderableDelayedDragStartListener(
                key: ValueKey(s.id),
                index: i,
                child: Material(
                  color: isSelected ? ObsColors.accentDim : Colors.transparent,
                  child: InkWell(
                    onTap: () => studio.selectScene(s.id),
                    child: GestureDetector(
                      onSecondaryTapUp: (d) => _sceneMenu(context, s.id, d.globalPosition),
                      child: Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: isProgram ? ObsColors.live : Colors.transparent,
                              width: 4,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(child: Text(s.name, overflow: TextOverflow.ellipsis)),
                            if (isProgram && studio.studioMode)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Text('PGM', style: TextStyle(fontSize: 11, color: ObsColors.live)),
                              ),
                            IconButton(
                              icon: const Icon(Icons.more_vert, size: 20),
                              tooltip: 'Scene menu',
                              onPressed: () {
                                final box = context.findRenderObject() as RenderBox?;
                                final pos = box?.localToGlobal(Offset(box.size.width - 24, 24));
                                _sceneMenu(context, s.id, pos);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _remove(BuildContext context, String sceneId) async {
    final studio = AppScope.of(context).studio;
    final s = studio.sceneById(sceneId);
    if (s == null) return;
    if (await confirm(context, title: 'Remove Scene', message: 'Remove "${s.name}"?')) {
      studio.removeScene(sceneId);
    }
  }

  Future<void> _sceneMenu(BuildContext context, String sceneId, Offset? at) async {
    final studio = AppScope.of(context).studio;
    final s = studio.sceneById(sceneId);
    if (s == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = at ?? overlay.size.center(Offset.zero);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(pos & const Size(1, 1), Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(value: 'dup', child: Text('Duplicate')),
        PopupMenuItem(value: 'remove', child: Text('Remove')),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'rename':
        final name = await promptText(context, title: 'Rename Scene', initial: s.name);
        if (name != null) studio.renameScene(sceneId, name);
      case 'dup':
        studio.duplicateScene(sceneId);
      case 'remove':
        if (studio.scenes.length > 1) await _remove(context, sceneId);
    }
  }
}

// -----------------------------------------------------------------------------

class SourcesDock extends StatelessWidget {
  const SourcesDock({super.key, this.showTitle = true});

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        final scene = studio.editingScene;
        final items = scene.items.reversed.toList(); // top-most first, like OBS
        final selected = studio.selectedItem;
        final selIndex = selected == null ? -1 : items.indexOf(selected);
        return Dock(
          title: 'Sources',
          showTitle: showTitle,
          toolbar: [
            DockButton(icon: Icons.add, tooltip: 'Add source', onPressed: () => showAddSource(context)),
            DockButton(
              icon: Icons.remove,
              tooltip: 'Remove source',
              onPressed: selected == null ? null : () => confirmRemoveItem(context, selected.id),
            ),
            DockButton(
              icon: Icons.settings_outlined,
              tooltip: 'Properties',
              onPressed: selected == null ? null : () => showSourceProperties(context, selected.id),
            ),
            const Spacer(),
            DockButton(
              icon: Icons.keyboard_arrow_up,
              tooltip: 'Move up',
              onPressed: selIndex > 0 ? () => studio.moveItemDisplay(selIndex, selIndex - 1) : null,
            ),
            DockButton(
              icon: Icons.keyboard_arrow_down,
              tooltip: 'Move down',
              onPressed: selIndex >= 0 && selIndex < items.length - 1
                  ? () => studio.moveItemDisplay(selIndex, selIndex + 1)
                  : null,
            ),
          ],
          child: items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No sources yet.\nTap + to add a camera, image, text…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: ObsColors.textDim),
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: items.length,
                  onReorderItem: studio.moveItemDisplay,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    final src = studio.sourceById(item.sourceId);
                    final isSel = item.id == selected?.id;
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(item.id),
                      index: i,
                      child: Material(
                        color: isSel ? ObsColors.accentDim : Colors.transparent,
                        child: InkWell(
                          onTap: () => studio.selectItem(item.id),
                          child: SizedBox(
                            height: 48,
                            child: Row(
                              children: [
                                const SizedBox(width: 12),
                                Icon(sourceIcon(src?.type ?? SourceType.color), size: 20, color: ObsColors.textDim),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    src?.name ?? '?',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: item.visible ? ObsColors.text : ObsColors.textDim),
                                  ),
                                ),
                                if (src?.type == SourceType.screen) _ScreenToggle(),
                                IconButton(
                                  icon: Icon(item.visible ? Icons.visibility : Icons.visibility_off, size: 20),
                                  tooltip: item.visible ? 'Hide' : 'Show',
                                  onPressed: () => studio.setItemVisible(item.id, !item.visible),
                                ),
                                IconButton(
                                  icon: Icon(item.locked ? Icons.lock : Icons.lock_open, size: 20),
                                  tooltip: item.locked ? 'Unlock' : 'Lock',
                                  color: item.locked ? ObsColors.text : ObsColors.border,
                                  onPressed: () => studio.setItemLocked(item.id, !item.locked),
                                ),
                                Builder(
                                  builder: (btnCtx) => IconButton(
                                    icon: const Icon(Icons.more_vert, size: 20),
                                    tooltip: 'More',
                                    onPressed: () {
                                      final box = btnCtx.findRenderObject() as RenderBox;
                                      studio.selectItem(item.id);
                                      showItemMenu(context, box.localToGlobal(box.size.center(Offset.zero)), item.id);
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

/// Start/stop button for screen capture, shown on Screen Capture rows.
class _ScreenToggle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final out = AppScope.of(context).output;
    return ListenableBuilder(
      listenable: out,
      builder: (context, _) {
        if (!out.screenCaptureSupported) return const SizedBox.shrink();
        final active = out.screenState.active;
        return IconButton(
          icon: Icon(active ? Icons.stop_circle_outlined : Icons.play_circle_outline, size: 22),
          color: active ? ObsColors.live : ObsColors.ok,
          tooltip: active ? 'Stop screen capture' : 'Start screen capture',
          onPressed: active ? out.stopScreenCapture : out.startScreenCapture,
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------

/// Converts linear amplitude to dBFS.
double ampToDb(double a) => a <= 0.00001 ? -100 : 20 * math.log(a) / math.ln10;

/// OBS-style fader position <-> gain mapping (log taper, -inf .. 0 dB).
double faderToGain(double f) => f <= 0 ? 0 : math.pow(10, (f * 60 - 60) / 20).toDouble();
double gainToFader(double g) => g <= 0.001 ? 0 : ((ampToDb(g) + 60) / 60).clamp(0.0, 1.0);

class MixerDock extends StatelessWidget {
  const MixerDock({super.key, this.showTitle = true});

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final studio = scope.studio;
    return ListenableBuilder(
      listenable: Listenable.merge([studio, scope.output, scope.devices]),
      builder: (context, _) {
        final sources = studio.audioSources;
        return Dock(
          title: 'Audio Mixer',
          showTitle: showTitle,
          child: sources.isEmpty
              ? const Center(
                  child: Text('No audio sources', style: TextStyle(color: ObsColors.textDim)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: sources.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, i) => _MixerChannel(source: sources[i]),
                ),
        );
      },
    );
  }
}

class _MixerChannel extends StatelessWidget {
  const _MixerChannel({required this.source});

  final Source source;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final studio = scope.studio;
    // OBSpad records one microphone: the first Mic/Aux source.
    final primaryMic = studio.sources.where((s) => s.type == SourceType.audioInput).firstOrNull;
    final extraMic = source.type == SourceType.audioInput && primaryMic?.id != source.id;
    final isMic = source.type == SourceType.audioInput && !extraMic;
    final level = switch (source.type) {
      SourceType.audioInput => extraMic ? null : scope.output.micLevel,
      // Video sources: what the tablet plays, while this video is playing.
      SourceType.media =>
        scope.media.controllerFor(source.id)?.value.isPlaying ?? false ? scope.output.outputLevel : null,
      SourceType.audioOutput => scope.output.outputLevel,
      SourceType.screen => scope.output.screenState.active ? scope.output.outputLevel : null,
      _ => null,
    };
    final db = ampToDb(source.volume);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: Text(source.name, overflow: TextOverflow.ellipsis)),
            Text(
              source.volume <= 0.001 ? '-inf dB' : '${db.toStringAsFixed(1)} dB',
              style: const TextStyle(color: ObsColors.textDim, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ]),
          if (isMic) _InputDeviceRow(source: source),
          if (extraMic)
            Text(
              'Not captured: OBSpad records one microphone (${primaryMic?.name}). '
              'Choose which input it uses there, or remove this source.',
              key: ValueKey('extra-mic-${source.id}'),
              style: const TextStyle(color: ObsColors.warn, fontSize: 12),
            ),
          if (source.type == SourceType.audioOutput)
            const Text('Desktop audio (other apps)', style: TextStyle(color: ObsColors.textDim, fontSize: 12)),
          const SizedBox(height: 4),
          _LevelMeter(rms: level?.rms ?? 0, peak: level?.peak ?? 0, muted: source.muted),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: gainToFader(source.volume),
                  onChanged: (f) => studio.setVolume(source.id, faderToGain(f)),
                ),
              ),
              if (isMic) _MicAdjustButton(source: source),
              IconButton(
                icon: Icon(
                  Icons.auto_awesome_outlined,
                  size: 20,
                  color: source.filters.any((f) => f.enabled) ? ObsColors.accent : ObsColors.textDim,
                ),
                tooltip: 'Filters',
                onPressed: () => switch (studio.itemsOf(source.id).firstOrNull) {
                  final it? => showSourceFilters(context, it.id),
                  null => showFiltersWindow(context, sourceId: source.id),
                },
              ),
              IconButton(
                icon: Icon(source.muted ? Icons.volume_off : Icons.volume_up),
                color: source.muted ? ObsColors.live : ObsColors.text,
                tooltip: source.muted ? 'Unmute' : 'Mute',
                onPressed: () => studio.setMuted(source.id, !source.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Mic adjustments: one tap to switch the common voice filters on or off
/// (they're ordinary filters, fine-tuned in the Filters window).
class _MicAdjustButton extends StatelessWidget {
  const _MicAdjustButton({required this.source});

  final Source source;

  static const _kinds = [FilterKind.noiseSuppression, FilterKind.noiseGate, FilterKind.compressor, FilterKind.limiter];

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    SourceFilter? find(FilterKind k) => source.filters.where((f) => f.kind == k).firstOrNull;
    bool on(FilterKind k) => find(k)?.enabled ?? false;
    final boost = source.filters.where((f) => f.kind == FilterKind.gain && f.enabled).firstOrNull?.dbl('db') ?? 0;
    final active = _kinds.any(on) || boost != 0;

    void toggle(FilterKind k) {
      final f = find(k);
      if (f == null) {
        studio.addFilter(source.id, k);
      } else {
        studio.updateFilter(source.id, f.id, enabled: !f.enabled);
      }
    }

    void setBoost(double db) {
      final f = source.filters.where((f) => f.kind == FilterKind.gain).firstOrNull;
      if (f == null) {
        if (db == 0) return;
        final added = studio.addFilter(source.id, FilterKind.gain);
        studio.updateFilter(source.id, added.id, name: 'Mic boost', values: {'db': db});
      } else {
        studio.updateFilter(source.id, f.id, enabled: true, values: {'db': db});
      }
    }

    return PopupMenuButton<VoidCallback>(
      key: ValueKey('mic-adjust-${source.id}'),
      tooltip: 'Mic adjustments',
      icon: Icon(Icons.tune, size: 20, color: active ? ObsColors.accent : ObsColors.textDim),
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        const PopupMenuItem(
          enabled: false,
          height: 32,
          child: Text('Mic adjustments', style: TextStyle(fontSize: 12, color: ObsColors.textDim)),
        ),
        for (final k in _kinds)
          CheckedPopupMenuItem<VoidCallback>(
            key: ValueKey('mic-adjust-${k.name}'),
            value: () => toggle(k),
            checked: on(k),
            child: Text(k.label),
          ),
        const PopupMenuDivider(),
        for (final db in const [0.0, 6.0, 12.0, 20.0])
          CheckedPopupMenuItem<VoidCallback>(
            key: ValueKey('mic-boost-${db.round()}'),
            value: () => setBoost(db),
            checked: boost == db,
            child: Text(db == 0 ? 'No mic boost' : 'Mic boost +${db.round()} dB'),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<VoidCallback>(
          value: () => showFiltersWindow(context, sourceId: source.id),
          child: const Text('All filters and settings…'),
        ),
      ],
    );
  }
}

/// Green/yellow/red segmented meter (-60..0 dBFS).
/// Which device a Mic/Aux channel records from, with a picker. A USB sound
/// card plugged in directly, through a hub or a docking station appears here
/// and is used automatically.
class _InputDeviceRow extends StatelessWidget {
  const _InputDeviceRow({required this.source});

  final Source source;

  static IconData icon(String? type) => switch (type) {
        'usb' => Icons.usb,
        'bluetooth' => Icons.bluetooth_audio,
        'headset' => Icons.headset_mic,
        _ => Icons.mic_none,
      };

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final devices = scope.devices;
    if (!devices.supported) return const SizedBox.shrink();
    final setting = source.settings['device'] as String? ?? 'default';
    final active = devices.resolveAudioInput(setting);
    final auto = setting == 'default' || !devices.audioInputs.any((i) => i.id == setting);
    final label = active == null
        ? 'Built-in microphone'
        : '${active.type == 'usb' ? 'USB · ' : ''}${active.name}';
    return PopupMenuButton<String>(
      key: ValueKey('input-device-${source.id}'),
      tooltip: 'Input device',
      initialValue: auto ? 'default' : setting,
      onSelected: (v) => scope.studio.updateSourceSettings(source.id, {'device': v}),
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'default', child: Text('Automatic (USB sound card when plugged in)')),
        for (final i in devices.audioInputs)
          PopupMenuItem(
            value: i.id,
            child: Row(children: [
              Icon(icon(i.type), size: 18),
              const SizedBox(width: 8),
              Flexible(child: Text(i.name, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Icon(icon(active?.type), size: 14, color: active?.type == 'usb' ? ObsColors.ok : ObsColors.textDim),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              auto ? '$label (auto)' : label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: active?.type == 'usb' ? ObsColors.ok : ObsColors.textDim),
            ),
          ),
          const Icon(Icons.arrow_drop_down, size: 16, color: ObsColors.textDim),
        ]),
      ),
    );
  }
}

class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.rms, required this.peak, required this.muted});

  final double rms, peak;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    double pos(double a) => ((ampToDb(a) + 60) / 60).clamp(0.0, 1.0);
    return SizedBox(
      height: 8,
      child: CustomPaint(painter: _MeterPainter(pos(rms), pos(peak), muted)),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.level, this.peak, this.muted);

  final double level, peak;
  final bool muted;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Background zones like OBS: green < -20 dB, yellow < -9 dB, red above.
    const zones = [(0.0, 40 / 60, Color(0xFF2B5C2E)), (40 / 60, 51 / 60, Color(0xFF6B5E21)), (51 / 60, 1.0, Color(0xFF6B2525))];
    const active = [Color(0xFF4CD964), Color(0xFFFFD60A), Color(0xFFFF453A)];
    for (var i = 0; i < zones.length; i++) {
      final (a, b, bg) = zones[i];
      canvas.drawRect(Rect.fromLTRB(a * w, 0, b * w, h), Paint()..color = muted ? ObsColors.border : bg);
      if (!muted && level > a) {
        canvas.drawRect(Rect.fromLTRB(a * w, 0, math.min(level, b) * w, h), Paint()..color = active[i]);
      }
    }
    if (!muted && peak > 0) {
      canvas.drawRect(Rect.fromLTWH(peak * w - 2, 0, 2, h), Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.level != level || old.peak != peak || old.muted != muted;
}

// -----------------------------------------------------------------------------

class TransitionsDock extends StatelessWidget {
  const TransitionsDock({super.key, this.showTitle = true});

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        final c = studio.collection;
        return Dock(
          title: 'Scene Transitions',
          showTitle: showTitle,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              DropdownButtonFormField<TransitionType>(
                initialValue: c.transition,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Transition', isDense: true),
                items: [
                  for (final t in TransitionType.values) DropdownMenuItem(value: t, child: Text(t.label)),
                ],
                onChanged: (t) => t == null ? null : studio.setTransition(t),
              ),
              const SizedBox(height: 8),
              if (c.transition != TransitionType.cut)
                LabeledSlider(
                  label: 'Duration',
                  value: c.transitionMs.toDouble(),
                  min: 100,
                  max: 3000,
                  divisions: 29,
                  format: (v) => '${v.round()} ms',
                  onChanged: (v) => studio.setTransitionDuration(v.round()),
                ),
            ],
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------

class ControlsDock extends StatelessWidget {
  const ControlsDock({super.key, this.showTitle = true, this.compact = false});

  final bool showTitle;

  /// A single horizontal row of buttons (portrait layout).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final studio = scope.studio;
    final out = scope.output;
    return ListenableBuilder(
      listenable: Listenable.merge([studio, out]),
      builder: (context, _) {
        final buttons = <Widget>[
          _BigButton(
            label: switch (out.streamStatus) {
              OutputStatus.idle => 'Start Streaming',
              OutputStatus.starting => 'Connecting…',
              OutputStatus.active => 'Stop Streaming',
              OutputStatus.reconnecting => 'Reconnecting (${out.reconnectAttempt})…',
              OutputStatus.stopping => 'Stopping…',
            },
            icon: Icons.podcasts,
            active: out.isStreaming,
            activeColor: ObsColors.live,
            onPressed: () => toggleStreaming(context),
          ),
          _BigButton(
            label: switch (out.recordStatus) {
              OutputStatus.idle => 'Start Recording',
              OutputStatus.starting => 'Starting…',
              OutputStatus.active => 'Stop Recording',
              OutputStatus.reconnecting || OutputStatus.stopping => 'Stopping…',
            },
            icon: Icons.fiber_manual_record,
            active: out.isRecording,
            activeColor: ObsColors.rec,
            onPressed: () => toggleRecording(context),
          ),
          _BigButton(
            label: 'Studio Mode',
            icon: Icons.view_column_outlined,
            active: studio.studioMode,
            activeColor: ObsColors.accent,
            onPressed: () => studio.setStudioMode(!studio.studioMode),
          ),
          _BigButton(
            label: 'Plugins',
            icon: Icons.extension_outlined,
            active: out.ndiActive,
            activeColor: ObsColors.accentDim,
            onPressed: () => openPlugins(context),
          ),
          _BigButton(
            label: 'Settings',
            icon: Icons.settings_outlined,
            active: false,
            onPressed: () => openSettings(context),
          ),
          _BigButton(
            key: const ValueKey('exit-button'),
            label: 'Exit',
            icon: Icons.power_settings_new,
            active: false,
            onPressed: () => exitApp(context),
          ),
        ];
        if (compact) {
          return Row(
            children: [
              for (final b in buttons)
                Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: b)),
            ],
          );
        }
        return Dock(
          title: 'Controls',
          showTitle: showTitle,
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [
              for (final b in buttons) Padding(padding: const EdgeInsets.only(bottom: 5), child: b),
            ],
          ),
        );
      },
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    super.key,
    required this.label,
    required this.icon,
    required this.active,
    required this.onPressed,
    this.activeColor = ObsColors.accent,
  });

  final String label;
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: active ? activeColor : ObsColors.panelAlt,
          foregroundColor: ObsColors.text,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        icon: Icon(icon, size: 20),
        label: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
        onPressed: onPressed,
      ),
    );
  }
}

Future<void> toggleStreaming(BuildContext context) async {
  final scope = AppScope.of(context);
  final out = scope.output;
  final ask = scope.studio.settings.confirmStartStop;
  if (out.isStreaming) {
    if (!ask || await confirm(context, title: 'Stop Streaming', message: 'Are you sure you want to stop streaming?')) {
      await out.stopStreaming();
    }
  } else {
    if (scope.studio.settings.publishUrl.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(scope.studio.settings.usesPresetServer
            ? 'Add your ${scope.studio.settings.service} stream key first.'
            : 'Add your stream server and key first.'),
        action: SnackBarAction(label: 'Settings', onPressed: () => openSettings(context)),
      ));
      return;
    }
    if (!ask ||
        await confirm(context,
            title: 'Start Streaming', message: 'Are you sure you want to start streaming?', destructive: false)) {
      await out.startStreaming();
    }
  }
}

Future<void> toggleRecording(BuildContext context) async {
  final out = AppScope.of(context).output;
  if (out.isRecording) {
    await out.stopRecording();
    final path = out.lastRecordingPath;
    if (path != null && out.lastError == null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Recording saved: $path')));
    }
  } else {
    await out.startRecording();
  }
}
