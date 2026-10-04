import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import 'docks.dart';
import 'item_menu.dart';

/// Keyboard shortcuts (iPad / Android keyboards, Stream Deck-style key
/// senders), like OBS hotkeys. Ignored while typing in a text field.
const kShortcuts = <(String, String)>[
  ('1 – 9', 'Switch to scene 1–9 (into Preview in Studio Mode)'),
  ('Space or Enter', 'Transition (Studio Mode)'),
  ('Ctrl+Z / Ctrl+Shift+Z or Ctrl+Y', 'Undo / Redo'),
  ('Arrow keys (+Shift)', 'Move the selected source 1 px (10 px)'),
  ('Delete', 'Remove the selected source'),
  ('Ctrl+Shift+S', 'Start / stop streaming'),
  ('Ctrl+Shift+R', 'Start / stop recording'),
  ('Ctrl+Shift+T', 'Studio Mode on / off'),
];

class StudioHotkeys extends StatefulWidget {
  const StudioHotkeys({super.key, required this.child});

  final Widget child;

  @override
  State<StudioHotkeys> createState() => _StudioHotkeysState();
}

class _StudioHotkeysState extends State<StudioHotkeys> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  static bool _typing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return false;
    if (!mounted || _typing()) return false;
    // Only when the studio is the top screen (not under a dialog or sheet).
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final shift = kb.isShiftPressed;
    final key = e.logicalKey;
    final scope = AppScope.of(context);
    final studio = scope.studio;

    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      shift ? studio.redo() : studio.undo();
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.keyY) {
      studio.redo();
      return true;
    }
    if (ctrl && shift && key == LogicalKeyboardKey.keyS) {
      toggleStreaming(context);
      return true;
    }
    if (ctrl && shift && key == LogicalKeyboardKey.keyR) {
      toggleRecording(context);
      return true;
    }
    if (ctrl && shift && key == LogicalKeyboardKey.keyT) {
      studio.setStudioMode(!studio.studioMode);
      return true;
    }
    if (ctrl) return false;

    const digits = [
      LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit9,
    ];
    final n = digits.indexOf(key);
    if (n >= 0 && e is KeyDownEvent) {
      if (n < studio.scenes.length) studio.selectScene(studio.scenes[n].id);
      return true;
    }
    if ((key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.enter) && e is KeyDownEvent) {
      if (studio.studioMode) studio.transitionToProgram();
      return studio.studioMode;
    }
    final sel = studio.selectedItem;
    if (sel != null) {
      final step = shift ? 10.0 : 1.0;
      final (dx, dy) = switch (key) {
        LogicalKeyboardKey.arrowLeft => (-step, 0.0),
        LogicalKeyboardKey.arrowRight => (step, 0.0),
        LogicalKeyboardKey.arrowUp => (0.0, -step),
        LogicalKeyboardKey.arrowDown => (0.0, step),
        _ => (0.0, 0.0),
      };
      if (dx != 0 || dy != 0) {
        studio.updateTransform(sel.id, (t) {
          t.x += dx;
          t.y += dy;
        }, persist: true);
        return true;
      }
      if ((key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) && e is KeyDownEvent) {
        confirmRemoveItem(context, sel.id);
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Help › Keyboard Shortcuts.
Future<void> showShortcutsHelp(BuildContext context) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('shortcuts-dialog'),
        title: const Text('Keyboard Shortcuts'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (keys, what) in kShortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 190, child: Text(keys, style: const TextStyle(fontWeight: FontWeight.w600))),
                  Expanded(child: Text(what)),
                ]),
              ),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
