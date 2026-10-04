import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/update_service.dart';
import 'about.dart';
import 'theme.dart';

Future<void> openUpdate(UpdateInfo u) async {
  try {
    await launchUrl(Uri.parse(u.downloadUrl(defaultTargetPlatform)), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Shows a banner across the top of the studio when a newer build is out.
class UpdateListener extends StatefulWidget {
  const UpdateListener({super.key, required this.child});

  final Widget child;

  @override
  State<UpdateListener> createState() => _UpdateListenerState();
}

class _UpdateListenerState extends State<UpdateListener> {
  final _updates = UpdateService.instance;
  int? _shown;

  @override
  void initState() {
    super.initState();
    _updates.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _updates.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!mounted) return;
    final u = _updates.available;
    final messenger = ScaffoldMessenger.of(context);
    if (!_updates.shouldNotify || u == null) {
      if (_shown != null) messenger.hideCurrentMaterialBanner();
      _shown = null;
      return;
    }
    if (_shown == u.build) return;
    _shown = u.build;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(MaterialBanner(
        key: const ValueKey('update-banner'),
        backgroundColor: ObsColors.panelAlt,
        leading: const Icon(Icons.system_update, color: ObsColors.accent),
        content: Text('A new version of OBSpad is available: build ${u.build} (you have build $kAppBuild).'),
        actions: [
          TextButton(onPressed: _updates.dismiss, child: const Text('Later')),
          FilledButton.icon(
            key: const ValueKey('update-download'),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download'),
            onPressed: () => openUpdate(u),
          ),
        ],
      ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Help › Check for Updates.
Future<void> checkForUpdates(BuildContext context) async {
  final updates = UpdateService.instance;
  if (updates.currentBuild == null) {
    await _info(context, 'Development build', 'Update checks are only for builds downloaded from $kDownloadSite.');
    return;
  }
  UpdateInfo? u;
  Object? error;
  try {
    u = await updates.check();
  } catch (e) {
    error = e;
  }
  if (!context.mounted) return;
  if (error != null) {
    await _info(context, 'Could not check for updates', 'Check your internet connection and try again.');
  } else if (u == null) {
    await _info(context, 'OBSpad is up to date', 'You have the latest version (build $kAppBuild).');
  } else {
    final info = u;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('update-dialog'),
        icon: const Icon(Icons.system_update, color: ObsColors.accent),
        title: const Text('Update available'),
        content: Text('Build ${info.build} is ready to download (you have build $kAppBuild).\n\n'
            'Install it over this version; your scenes and settings are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
          FilledButton.icon(
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download'),
            onPressed: () {
              Navigator.pop(context);
              openUpdate(info);
            },
          ),
        ],
      ),
    );
  }
}

Future<void> _info(BuildContext context, String title, String message) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
