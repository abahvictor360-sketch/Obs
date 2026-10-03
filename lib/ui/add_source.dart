import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import 'dialogs.dart';
import 'source_properties.dart';
import 'theme.dart';

/// OBS's "+" source menu: pick a type, then either create a new source or
/// add an existing one (shared across scenes).
Future<void> showAddSource(BuildContext context) async {
  final studio = AppScope.of(context).studio;
  final type = await showModalBottomSheet<SourceType>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add Source', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.6,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final t in SourceType.values)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => Navigator.pop(context, t),
                    child: Ink(
                      decoration: BoxDecoration(
                        color: ObsColors.panelAlt,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: ObsColors.border),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(sourceIcon(t), size: 32),
                          const SizedBox(height: 8),
                          Text(t.label, textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (type == null || !context.mounted) return;

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
  // Open properties straight away for sources that need configuration.
  if (type != SourceType.color && type != SourceType.audioInput && context.mounted) {
    await showSourceProperties(context, item.id);
  }
}
