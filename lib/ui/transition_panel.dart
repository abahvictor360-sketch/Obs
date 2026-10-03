import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../core/studio_controller.dart';
import 'theme.dart';

/// Studio mode controls between Preview and Program, like OBS: the
/// Transition button (with a menu for the transition and its duration),
/// Quick Transitions, and the T-bar.
class TransitionPanel extends StatelessWidget {
  const TransitionPanel({super.key, this.vertical = true});

  /// Column between the canvases (landscape) or a strip below them.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        final c = studio.collection;
        final same = c.programSceneId == c.previewSceneId;
        final transition = Row(children: [
          Expanded(
            child: _PanelButton(
              key: const ValueKey('transition-button'),
              label: 'Transition',
              primary: true,
              onPressed: same ? null : studio.transitionToProgram,
            ),
          ),
          const SizedBox(width: 6),
          _TransitionMenu(studio: studio),
        ]);
        final quickHeader = Row(children: [
          const Expanded(
            child: Text('Quick Transitions', style: TextStyle(fontSize: 13, color: ObsColors.text)),
          ),
          SizedBox(
            width: 40,
            height: 32,
            child: IconButton(
              tooltip: 'Add quick transition',
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.add, size: 20),
              style: IconButton.styleFrom(backgroundColor: ObsColors.panelAlt),
              onPressed: () => _addQuick(context, studio),
            ),
          ),
        ]);
        final quick = [
          for (final q in c.quickTransitions)
            _PanelButton(
              key: ValueKey('quick-${q.type.name}-${q.ms}'),
              label: q.label,
              onPressed: same ? null : () => studio.transitionToProgram(using: q),
              onLongPress: () => _removeQuick(context, studio, q),
            ),
        ];
        final tBar = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 8,
            thumbShape: const _TBarThumb(),
            overlayShape: SliderComponentShape.noOverlay,
            activeTrackColor: ObsColors.accent,
            inactiveTrackColor: ObsColors.panelAlt,
          ),
          child: Slider(
            key: const ValueKey('t-bar'),
            value: studio.tBar,
            onChanged: same ? null : studio.setTBar,
            onChangeEnd: (_) => studio.releaseTBar(),
          ),
        );

        if (vertical) {
          return SizedBox(
            width: 168,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                transition,
                const SizedBox(height: 10),
                quickHeader,
                const SizedBox(height: 6),
                for (final w in quick) Padding(padding: const EdgeInsets.only(bottom: 6), child: w),
                const SizedBox(height: 4),
                tBar,
              ]),
            ),
          );
        }
        return SizedBox(
          height: 44,
          child: Row(children: [
            SizedBox(width: 180, child: transition),
            const SizedBox(width: 8),
            Expanded(
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final w in quick)
                  Padding(padding: const EdgeInsets.only(right: 6), child: SizedBox(width: 150, child: w)),
                SizedBox(
                  width: 40,
                  child: IconButton(
                    tooltip: 'Add quick transition',
                    icon: const Icon(Icons.add),
                    onPressed: () => _addQuick(context, studio),
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 160, child: tBar),
          ]),
        );
      },
    );
  }

  static Future<void> _addQuick(BuildContext context, StudioController studio) async {
    var type = TransitionType.fade;
    var ms = 300.0;
    final q = await showDialog<QuickTransition>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add Quick Transition'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<TransitionType>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Transition'),
              items: [for (final t in TransitionType.values) DropdownMenuItem(value: t, child: Text(t.label))],
              onChanged: (v) => setState(() => type = v ?? type),
            ),
            if (type != TransitionType.cut) ...[
              const SizedBox(height: 12),
              Row(children: [
                const Text('Duration'),
                Expanded(
                  child: Slider(
                    value: ms,
                    min: 100,
                    max: 3000,
                    divisions: 29,
                    onChanged: (v) => setState(() => ms = v),
                  ),
                ),
                Text('${ms.round()} ms'),
              ]),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, QuickTransition(type, type == TransitionType.cut ? 0 : ms.round())),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (q != null) studio.addQuickTransition(q);
  }

  static Future<void> _removeQuick(BuildContext context, StudioController studio, QuickTransition q) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${q.label}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) studio.removeQuickTransition(q);
  }
}

class _PanelButton extends StatelessWidget {
  const _PanelButton({super.key, required this.label, this.onPressed, this.onLongPress, this.primary = false});

  final String label;
  final VoidCallback? onPressed, onLongPress;
  final bool primary;

  @override
  Widget build(BuildContext context) => FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: primary ? ObsColors.accent : ObsColors.panelAlt,
          foregroundColor: ObsColors.text,
          disabledBackgroundColor: ObsColors.panelAlt.withValues(alpha: 0.5),
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onPressed: onPressed,
        onLongPress: onLongPress,
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
}

/// ⋮ next to Transition: pick the transition and its duration.
class _TransitionMenu extends StatelessWidget {
  const _TransitionMenu({required this.studio});

  final StudioController studio;

  @override
  Widget build(BuildContext context) {
    final c = studio.collection;
    return SizedBox(
      width: 40,
      height: 40,
      child: PopupMenuButton<Object>(
        tooltip: 'Transition settings',
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.more_vert),
        style: IconButton.styleFrom(backgroundColor: ObsColors.panelAlt),
        itemBuilder: (context) => [
          for (final t in TransitionType.values)
            CheckedPopupMenuItem(value: t, checked: c.transition == t, child: Text(t.label)),
          const PopupMenuDivider(),
          for (final ms in const [100, 300, 500, 1000, 2000])
            CheckedPopupMenuItem(value: ms, checked: c.transitionMs == ms, child: Text('Duration: $ms ms')),
        ],
        onSelected: (v) {
          if (v is TransitionType) studio.setTransition(v);
          if (v is int) studio.setTransitionDuration(v);
        },
      ),
    );
  }
}

/// The T-bar's handle: a wide bar.
class _TBarThumb extends SliderComponentShape {
  const _TBarThumb();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(14, 28);

  @override
  void paint(PaintingContext context, Offset center,
      {required Animation<double> activationAnimation,
      required Animation<double> enableAnimation,
      required bool isDiscrete,
      required TextPainter labelPainter,
      required RenderBox parentBox,
      required SliderThemeData sliderTheme,
      required TextDirection textDirection,
      required double value,
      required double textScaleFactor,
      required Size sizeWithOverflow}) {
    final r = RRect.fromRectAndRadius(Rect.fromCenter(center: center, width: 14, height: 28), const Radius.circular(3));
    context.canvas.drawRRect(r, Paint()..color = enableAnimation.value > 0.5 ? Colors.white : ObsColors.textDim);
  }
}
