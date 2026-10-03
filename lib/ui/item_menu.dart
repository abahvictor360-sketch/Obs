import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/studio_controller.dart';
import 'dialogs.dart';
import 'source_properties.dart';

/// The right-click menu of OBS's preview/source list, opened by long-press.
Future<void> showItemMenu(BuildContext context, Offset globalPosition, String itemId) async {
  final studio = AppScope.of(context).studio;
  final item = studio.itemById(itemId);
  if (item == null) return;
  final source = studio.sourceById(item.sourceId);
  if (source == null) return;

  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final position = RelativeRect.fromRect(
    globalPosition & const Size(1, 1),
    Offset.zero & overlay.size,
  );

  PopupMenuItem<VoidCallback> entry(IconData icon, String label, VoidCallback action) => PopupMenuItem(
        value: action,
        height: 44,
        child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)]),
      );

  final action = await showMenu<VoidCallback>(
    context: context,
    position: position,
    items: [
      entry(Icons.tune, 'Properties', () => showSourceProperties(context, itemId)),
      entry(Icons.auto_awesome_outlined, 'Filters', () => showSourceFilters(context, itemId)),
      entry(Icons.edit_outlined, 'Rename', () async {
        final name = await promptText(context, title: 'Rename Source', initial: source.name);
        if (name != null) studio.renameSource(source.id, name);
      }),
      entry(item.visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          item.visible ? 'Hide' : 'Show', () => studio.setItemVisible(itemId, !item.visible)),
      entry(item.locked ? Icons.lock_open : Icons.lock_outline, item.locked ? 'Unlock' : 'Lock',
          () => studio.setItemLocked(itemId, !item.locked)),
      const PopupMenuDivider(),
      for (final p in [
        TransformPreset.fitToScreen,
        TransformPreset.stretchToScreen,
        TransformPreset.centerToScreen,
        TransformPreset.rotate90cw,
        TransformPreset.flipHorizontal,
        TransformPreset.reset,
      ])
        entry(_presetIcon(p), p.label, () => studio.applyTransformPreset(itemId, p)),
      const PopupMenuDivider(),
      entry(Icons.vertical_align_top, 'Move to Top', () => studio.moveItem(itemId, OrderMove.top)),
      entry(Icons.arrow_upward, 'Move Up', () => studio.moveItem(itemId, OrderMove.up)),
      entry(Icons.arrow_downward, 'Move Down', () => studio.moveItem(itemId, OrderMove.down)),
      entry(Icons.vertical_align_bottom, 'Move to Bottom', () => studio.moveItem(itemId, OrderMove.bottom)),
      const PopupMenuDivider(),
      entry(Icons.copy, 'Duplicate', () => studio.duplicateItem(itemId)),
      entry(Icons.delete_outline, 'Remove', () => confirmRemoveItem(context, itemId)),
    ],
  );
  action?.call();
}

IconData _presetIcon(TransformPreset p) => switch (p) {
      TransformPreset.fitToScreen => Icons.fit_screen,
      TransformPreset.stretchToScreen => Icons.open_in_full,
      TransformPreset.centerToScreen => Icons.center_focus_strong,
      TransformPreset.rotate90cw => Icons.rotate_right,
      TransformPreset.rotate90ccw => Icons.rotate_left,
      TransformPreset.flipHorizontal => Icons.flip,
      TransformPreset.flipVertical => Icons.flip,
      _ => Icons.restart_alt,
    };

Future<void> confirmRemoveItem(BuildContext context, String itemId) async {
  final studio = AppScope.of(context).studio;
  final item = studio.itemById(itemId);
  if (item == null) return;
  final name = studio.sourceById(item.sourceId)?.name ?? 'source';
  final ok = await confirm(context, title: 'Remove', message: 'Remove "$name" from this scene?');
  if (ok) studio.removeItem(itemId);
}
