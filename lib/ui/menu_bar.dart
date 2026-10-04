import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../core/studio_controller.dart';
import 'about.dart';
import 'add_source.dart';
import 'dialogs.dart';
import 'dock_layout.dart';
import 'dock_panel.dart';
import 'docks.dart';
import 'browser_dock.dart';
import 'exit.dart';
import 'filters_panel.dart';
import 'projector_menu.dart';
import 'update_prompt.dart';
import 'item_menu.dart';
import 'plugins_screen.dart';
import 'settings_screen.dart';
import 'source_properties.dart';
import 'theme.dart';

/// OBS's menu bar: File, Edit, View, Docks, Scene Collection, Tools, Help.
class ObsMenuBar extends StatelessWidget {
  const ObsMenuBar({super.key, this.compact = false});

  /// One ☰ button holding the menus (narrow screens).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final studio = scope.studio;
    final out = scope.output;

    MenuItemButton item(String label, VoidCallback? onPressed, {IconData? icon, Key? key}) => MenuItemButton(
          key: key,
          leadingIcon: icon == null ? null : Icon(icon, size: 18),
          onPressed: onPressed,
          child: Text(label),
        );

    final devices = scope.devices;

    /// One entry per connected screen; the one showing [mode] is checked.
    List<Widget> screenItems(String mode) {
      final screens = devices.dock.displays;
      if (screens.isEmpty) {
        return [
          item('No screen connected', null, icon: Icons.desktop_access_disabled_outlined),
        ];
      }
      final current = devices.dock.display;
      return [
        for (final d in screens)
          MenuItemButton(
            key: ValueKey('menu-$mode-${d.id}'),
            leadingIcon: Icon(
              current?.id == d.id && current!.presenting && studio.settings.externalDisplay == mode
                  ? Icons.check
                  : Icons.desktop_windows_outlined,
              size: 18,
            ),
            onPressed: () => sendToScreen(studio, d, mode),
            child: Text('${d.name}  ${d.width}×${d.height}'),
          ),
      ];
    }

    final selected = studio.selectedItemId;
    final selectedItem = selected == null ? null : studio.editingScene.items.where((i) => i.id == selected).firstOrNull;

    return MenuBarTheme(
      data: MenuBarThemeData(
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(ObsColors.header),
          elevation: const WidgetStatePropertyAll(0),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
        ),
      ),
      child: MenuBar(children: _wrap([
        SubmenuButton(
          key: const ValueKey('menu-file'),
          menuChildren: [
            item(out.isStreaming ? 'Stop Streaming' : 'Start Streaming', () => toggleStreaming(context),
                icon: Icons.podcasts),
            item(out.isRecording ? 'Stop Recording' : 'Start Recording', () => toggleRecording(context),
                icon: Icons.fiber_manual_record),
            const Divider(height: 1),
            item('Settings', () => openSettings(context), icon: Icons.settings_outlined),
            const Divider(height: 1),
            item('Exit', () => exitApp(context), icon: Icons.power_settings_new, key: const ValueKey('menu-exit')),
          ],
          child: const Text('File'),
        ),
        SubmenuButton(
          menuChildren: [
            item('Add Source…', () => showAddSource(context), icon: Icons.add),
            item('Source Properties…', selectedItem == null ? null : () => showSourceProperties(context, selectedItem.id),
                icon: Icons.tune),
            item('Filters…',
                () => selectedItem == null ? showFiltersWindow(context) : showSourceFilters(context, selectedItem.id),
                icon: Icons.auto_awesome_outlined),
            SubmenuButton(
              menuChildren: [
                for (final p in TransformPreset.values)
                  item(p.label, selectedItem == null ? null : () => studio.applyTransformPreset(selectedItem.id, p)),
              ],
              leadingIcon: const Icon(Icons.transform, size: 18),
              child: const Text('Transform'),
            ),
            item('Remove Source', selectedItem == null ? null : () => confirmRemoveItem(context, selectedItem.id),
                icon: Icons.delete_outline),
          ],
          child: const Text('Edit'),
        ),
        SubmenuButton(
          menuChildren: [
            CheckboxMenuButton(
              value: studio.studioMode,
              onChanged: (v) => studio.setStudioMode(v ?? false),
              child: const Text('Studio Mode'),
            ),
            const Divider(height: 1),
            // Like OBS: pick the screen for the Multiview or the Program.
            SubmenuButton(
              key: const ValueKey('menu-multiview'),
              leadingIcon: const Icon(Icons.grid_view, size: 18),
              menuChildren: screenItems('multiview'),
              child: const Text('Multiview (Fullscreen)'),
            ),
            SubmenuButton(
              key: const ValueKey('menu-projector'),
              leadingIcon: const Icon(Icons.fullscreen, size: 18),
              menuChildren: [
                item('This tablet', () => openProjector(context),
                    icon: Icons.tablet_android, key: const ValueKey('menu-projector-tablet')),
                const Divider(height: 1),
                ...screenItems('program'),
              ],
              child: const Text('Fullscreen Projector (Program)'),
            ),
            if (devices.dock.display?.presenting ?? false)
              item('Stop projecting (mirror the tablet)',
                  () => studio.updateSettings((s) => s.externalDisplay = 'mirror'),
                  icon: Icons.cancel_presentation_outlined, key: const ValueKey('menu-projector-stop')),
          ],
          child: const Text('View'),
        ),
        SubmenuButton(
          key: const ValueKey('menu-docks'),
          menuChildren: [
            for (final d in studio.allDocks)
              CheckboxMenuButton(
                key: ValueKey('menu-dock-${d.id}'),
                value: studio.isDockVisible(d.id),
                onChanged: (v) => studio.setDockVisible(d.id, v ?? true),
                child: Text(d.title),
              ),
            const Divider(height: 1),
            item('Custom Browser Docks…', () => showBrowserDocksDialog(context),
                icon: Icons.web, key: const ValueKey('menu-browser-docks')),
            item('Reset Docks', studio.resetDocks, icon: Icons.restart_alt, key: const ValueKey('menu-reset-docks')),
          ],
          child: const Text('Docks'),
        ),
        SubmenuButton(
          menuChildren: [
            item('Copy as JSON (export)', () => _export(context, studio), icon: Icons.copy_all),
            item('Paste from clipboard (import)…', () => _import(context, studio), icon: Icons.content_paste),
            const Divider(height: 1),
            item('Reset to starter scenes…', () => _reset(context, studio), icon: Icons.restart_alt),
          ],
          child: const Text('Scene Collection'),
        ),
        SubmenuButton(
          menuChildren: [
            item('Plugins', () => openPlugins(context), icon: Icons.extension_outlined),
            item('Docking Station & Screen', () => showDockSheet(context), icon: Icons.desktop_windows_outlined),
          ],
          child: const Text('Tools'),
        ),
        SubmenuButton(
          menuChildren: [
            item('Check for Updates…', () => checkForUpdates(context),
                icon: Icons.system_update_outlined, key: const ValueKey('menu-check-updates')),
            item('About OBSpad', () => _about(context), icon: Icons.info_outline),
          ],
          child: const Text('Help'),
        ),
      ])),
    );
  }

  List<Widget> _wrap(List<Widget> menus) => compact
      ? [
          SubmenuButton(
            key: const ValueKey('menu-compact'),
            menuChildren: menus,
            child: const Icon(Icons.menu, size: 20),
          ),
        ]
      : menus;

  static Future<void> _export(BuildContext context, StudioController studio) async {
    await Clipboard.setData(ClipboardData(text: studio.exportCollection()));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Scene collection copied')));
    }
  }

  static Future<void> _import(BuildContext context, StudioController studio) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!context.mounted) return;
    final SceneCollection c;
    try {
      c = SceneCollection.fromJson(jsonDecode(data?.text ?? '') as Map<String, dynamic>);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The clipboard does not contain a scene collection (JSON)')));
      return;
    }
    if (await confirm(context,
        title: 'Import scene collection',
        message: 'Replace your scenes and sources with "${c.name}" (${c.scenes.length} scenes)?')) {
      studio.replaceCollection(c);
    }
  }

  static Future<void> _reset(BuildContext context, StudioController studio) async {
    if (await confirm(context, title: 'Reset scenes', message: 'Replace all scenes and sources with the starter layout?')) {
      studio.replaceCollection(SceneCollection.starter());
    }
  }

  static void _about(BuildContext context) => showObsAbout(context);
}
