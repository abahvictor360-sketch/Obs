import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../plugins/plugin_manager.dart';
import '../plugins/plugin_manifest.dart';
import 'dialogs.dart';
import 'source_properties.dart';
import 'theme.dart';

/// OBS's "+" source menu: pick a type, then either create a new source or
/// add an existing one (shared across scenes).
Future<void> showAddSource(BuildContext context) async {
  final scope = AppScope.of(context);
  final studio = scope.studio;
  final pluginTypes = scope.plugins.sourceTypes;
  final overlays = scope.plugins.overlays;
  final pluginMedia = scope.plugins.media;

  Widget tile(BuildContext context, IconData icon, String label, Object value, {String? subtitle}) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.pop(context, value),
        child: Ink(
          decoration: BoxDecoration(
            color: ObsColors.panelAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ObsColors.border),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 32),
              const SizedBox(height: 8),
              Text(label, textAlign: TextAlign.center),
              if (subtitle != null)
                Text(subtitle, style: const TextStyle(fontSize: 11, color: ObsColors.textDim)),
            ],
          ),
        ),
      );

  Widget grid(List<Widget> children) => GridView.count(
        shrinkWrap: true,
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.6,
        physics: const NeverScrollableScrollPhysics(),
        children: children,
      );

  final picked = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add Source', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            grid([
              for (final t in SourceType.values)
                if (t != SourceType.plugin) tile(context, sourceIcon(t), t.label, t),
            ]),
            if (pluginTypes.isNotEmpty || overlays.isNotEmpty || pluginMedia.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text('From plugins', style: TextStyle(color: ObsColors.textDim)),
              const SizedBox(height: 8),
              grid([
                for (final (p, st) in pluginTypes)
                  tile(context, Icons.extension_outlined, st.name, (p, st), subtitle: p.manifest.name),
                for (final (p, o) in overlays)
                  tile(context, Icons.web, o.name, (p, o), subtitle: p.manifest.name),
                for (final (p, name, path) in pluginMedia)
                  tile(context, _isVideo(path) ? Icons.movie_outlined : Icons.image_outlined, name,
                      _PluginFile(p, name, path),
                      subtitle: p.manifest.name),
              ]),
            ],
          ],
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;

  if (picked is (PluginEntry, PluginOverlay)) {
    // A plugin's web overlay is a Browser source showing its page.
    final (plugin, o) = picked;
    final name = await promptText(context, title: 'Create new ${o.name}', initial: studio.uniqueSourceName(o.name));
    if (name == null || !context.mounted) return;
    final item = studio.addNewSource(SourceType.browser, name: name, settings: {
      'url': PluginManager.pageUrl(plugin.manifest.id, o.page),
      'width': o.width.toDouble(),
      'height': o.height.toDouble(),
    });
    studio.setItemVisible(item.id, false);
    if (context.mounted) await showSourceProperties(context, item.id, creating: true);
    return;
  }

  if (picked is _PluginFile) {
    final type = _isVideo(picked.path) ? SourceType.media : SourceType.image;
    final base = picked.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final name = await promptText(context, title: 'Create new ${type.label}', initial: studio.uniqueSourceName(base));
    if (name == null || !context.mounted) return;
    final item = studio.addNewSource(type, name: name, settings: {'path': picked.path});
    studio.setItemVisible(item.id, false);
    if (context.mounted) await showSourceProperties(context, item.id, creating: true);
    return;
  }

  if (picked is (PluginEntry, PluginSourceType)) {
    final (plugin, st) = picked;
    final name = await promptText(context, title: 'Create new ${st.name}', initial: studio.uniqueSourceName(st.name));
    if (name == null || !context.mounted) return;
    final item = studio.addNewSource(SourceType.plugin, name: name, settings: {
      'plugin': plugin.manifest.id,
      'type': st.type,
      'config': st.defaultSettings(),
      'width': st.width.toDouble(),
      'height': st.height.toDouble(),
    });
    studio.setItemVisible(item.id, false);
    if (context.mounted) await showSourceProperties(context, item.id, creating: true);
    return;
  }
  final type = picked as SourceType;

  final existing = studio.sources.where((s) => s.type == type).toList();
  String? choice = 'new';
  if (existing.isNotEmpty) {
    choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Add ${type.label}'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'new'),
            child: const ListTile(leading: Icon(Icons.add), title: Text('Create new')),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text('Add existing', style: TextStyle(color: ObsColors.textDim)),
          ),
          for (final s in existing)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, s.id),
              child: ListTile(leading: Icon(sourceIcon(type)), title: Text(s.name)),
            ),
        ],
      ),
    );
  }
  if (choice == null || !context.mounted) return;

  if (choice != 'new') {
    studio.addExistingSource(choice);
    return;
  }
  final name = await promptText(context, title: 'Create new ${type.label}', initial: studio.uniqueSourceName(type.label));
  if (name == null || !context.mounted) return;
  final item = studio.addNewSource(type, name: name);
  if (!type.isVisual) {
    // Audio sources have nothing to preview; show their settings.
    if (type == SourceType.audioOutput && context.mounted) await showSourceProperties(context, item.id);
    return;
  }
  // Visual sources stay hidden while they're set up and previewed in their
  // properties; "Add" puts them in the scene, "Cancel" removes them.
  studio.setItemVisible(item.id, false);
  if (context.mounted) await showSourceProperties(context, item.id, creating: true);
}

/// An image or video that came with a plugin.
class _PluginFile {
  const _PluginFile(this.plugin, this.name, this.path);
  final PluginEntry plugin;
  final String name;
  final String path;
}

bool _isVideo(String path) => RegExp(r'\.(webm|mp4|mov|m4v)$', caseSensitive: false).hasMatch(path);
