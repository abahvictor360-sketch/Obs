import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/studio_controller.dart';
import 'docks.dart';
import 'theme.dart';

/// The docks along the bottom of the window, like OBS. Each can be closed
/// (✕ in its title bar) and reopened from the Docks menu, and resized by
/// dragging the gaps between them.
class DockSpec {
  const DockSpec(this.id, this.title, this.weight, this.build);

  final String id, title;

  /// Default relative width.
  final double weight;
  final Widget Function({bool showTitle}) build;
}

final kDocks = <DockSpec>[
  DockSpec('scenes', 'Scenes', 4, ({showTitle = true}) => ScenesDock(showTitle: showTitle)),
  DockSpec('sources', 'Sources', 5, ({showTitle = true}) => SourcesDock(showTitle: showTitle)),
  DockSpec('mixer', 'Audio Mixer', 5, ({showTitle = true}) => MixerDock(showTitle: showTitle)),
  DockSpec('transitions', 'Scene Transitions', 3, ({showTitle = true}) => TransitionsDock(showTitle: showTitle)),
  DockSpec('controls', 'Controls', 3, ({showTitle = true}) => ControlsDock(showTitle: showTitle)),
];

extension DockLayoutControl on StudioController {
  bool isDockVisible(String id) => !settings.hiddenDocks.contains(id);

  void setDockVisible(String id, bool visible) => updateSettings((s) {
        s.hiddenDocks.remove(id);
        if (!visible) s.hiddenDocks.add(id);
      });

  /// Shows every dock at its default size.
  void resetDocks() => updateSettings((s) {
        s.hiddenDocks.clear();
        s.dockWeights.clear();
        s.dockHeight = 0;
      });

  double dockWeight(String id) => settings.dockWeights[id] ?? kDocks.firstWhere((d) => d.id == id).weight;
}

/// Lets a [Dock] show a close button for its slot.
class DockSlot extends InheritedWidget {
  const DockSlot({super.key, required this.id, required this.onClose, required super.child});

  final String id;
  final VoidCallback onClose;

  static DockSlot? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DockSlot>();

  @override
  bool updateShouldNotify(DockSlot old) => id != old.id;
}

/// Landscape: the canvas on top, a drag handle, then the visible docks in a
/// resizable row.
class LandscapeWorkspace extends StatelessWidget {
  const LandscapeWorkspace({super.key, required this.height, required this.canvas});

  final double height;
  final Widget canvas;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        final visible = kDocks.where((d) => studio.isDockVisible(d.id)).toList();
        if (visible.isEmpty) return Padding(padding: const EdgeInsets.all(6), child: canvas);
        final auto = (height * 0.36).clamp(220.0, 340.0);
        final dockHeight = (studio.settings.dockHeight > 0 ? studio.settings.dockHeight : auto)
            .clamp(140.0, (height * 0.7).clamp(140.0, double.infinity));
        return Column(children: [
          Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(6, 6, 6, 0), child: canvas)),
          _ResizeHandle(
            key: const ValueKey('dock-height-handle'),
            axis: Axis.vertical,
            onDrag: (d) => studio.updateSettings((s) => s.dockHeight = (dockHeight - d).clamp(140.0, height * 0.7)),
          ),
          SizedBox(
            height: dockHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
              child: _DockRow(docks: visible),
            ),
          ),
        ]);
      },
    );
  }
}

class _DockRow extends StatelessWidget {
  const _DockRow({required this.docks});

  final List<DockSpec> docks;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return LayoutBuilder(builder: (context, box) {
      final weights = [for (final d in docks) studio.dockWeight(d.id)];
      final total = weights.fold<double>(0, (a, b) => a + b);
      const gap = 8.0;
      final avail = box.maxWidth - gap * (docks.length - 1);
      final children = <Widget>[];
      for (var i = 0; i < docks.length; i++) {
        final d = docks[i];
        children.add(SizedBox(
          width: avail * weights[i] / total,
          child: DockSlot(
            id: d.id,
            onClose: () => studio.setDockVisible(d.id, false),
            child: KeyedSubtree(key: ValueKey('dock-${d.id}'), child: d.build()),
          ),
        ));
        if (i < docks.length - 1) {
          children.add(_ResizeHandle(
            key: ValueKey('dock-gap-${d.id}'),
            axis: Axis.horizontal,
            size: gap,
            onDrag: (dx) {
              // Move width between the docks on either side of the gap.
              final perPx = total / avail;
              final min = total * 70 / avail; // ~70 px
              var a = weights[i] + dx * perPx;
              var b = weights[i + 1] - dx * perPx;
              if (a < min) {
                b -= min - a;
                a = min;
              }
              if (b < min) {
                a -= min - b;
                b = min;
              }
              studio.updateSettings((s) {
                for (var k = 0; k < docks.length; k++) {
                  s.dockWeights[docks[k].id] = weights[k];
                }
                s.dockWeights[d.id] = a;
                s.dockWeights[docks[i + 1].id] = b;
              });
            },
          ));
        }
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    });
  }
}

/// A gap that can be dragged to resize what's around it.
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({super.key, required this.axis, required this.onDrag, this.size = 10});

  /// horizontal: a vertical gap dragged left/right; vertical: a horizontal
  /// gap dragged up/down.
  final Axis axis;
  final ValueChanged<double> onDrag;
  final double size;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final grip = Container(
      width: horizontal ? 3 : 36,
      height: horizontal ? 36 : 3,
      decoration: BoxDecoration(
        color: _active ? ObsColors.accent : ObsColors.border,
        borderRadius: BorderRadius.circular(2),
      ),
    );
    return MouseRegion(
      cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: horizontal ? (_) => setState(() => _active = true) : null,
        onHorizontalDragUpdate: horizontal ? (d) => widget.onDrag(d.delta.dx) : null,
        onHorizontalDragEnd: horizontal ? (_) => setState(() => _active = false) : null,
        onVerticalDragStart: horizontal ? null : (_) => setState(() => _active = true),
        onVerticalDragUpdate: horizontal ? null : (d) => widget.onDrag(d.delta.dy),
        onVerticalDragEnd: horizontal ? null : (_) => setState(() => _active = false),
        child: SizedBox(
          width: horizontal ? widget.size : double.infinity,
          height: horizontal ? double.infinity : widget.size,
          child: Center(child: grip),
        ),
      ),
    );
  }
}
