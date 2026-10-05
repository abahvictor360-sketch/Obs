import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../core/studio_controller.dart';
import '../devices/device_service.dart';
import '../render/multiview.dart';
import '../render/program_view.dart';
import 'theme.dart';

/// Long-press on the Program: choose where to send it, like OBS's
/// "Fullscreen Projector (Program)" menu. Every connected screen is listed
/// (dock, USB-C, HDMI, wireless), plus fullscreen on the tablet itself.
Future<void> showProjectorMenu(BuildContext context, Offset globalPosition) async {
  final scope = AppScope.of(context);
  final studio = scope.studio;
  final devices = scope.devices;
  final screens = devices.dock.displays;
  final current = devices.dock.display;
  final mode = studio.settings.externalDisplay;
  bool isCurrent(ExternalDisplayInfo d) => current != null && current.id == d.id && current.presenting;

  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final position = RelativeRect.fromRect(globalPosition & const Size(1, 1), Offset.zero & overlay.size);

  PopupMenuItem<VoidCallback> entry(String label, VoidCallback? action,
          {IconData? icon, bool checked = false, Key? key, String? subtitle}) =>
      PopupMenuItem<VoidCallback>(
        key: key,
        value: action,
        enabled: action != null,
        height: subtitle == null ? 44 : 52,
        child: Row(children: [
          Icon(checked ? Icons.check : (icon ?? Icons.circle_outlined), size: 20,
              color: checked ? ObsColors.ok : null),
          const SizedBox(width: 12),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, overflow: TextOverflow.ellipsis),
              if (subtitle != null)
                Text(subtitle, style: const TextStyle(fontSize: 12, color: ObsColors.textDim)),
            ]),
          ),
        ]),
      );

  void sendTo(ExternalDisplayInfo d, String m) => sendToScreen(studio, d, m);

  final action = await showMenu<VoidCallback>(
    context: context,
    position: position,
    items: [
      const PopupMenuItem<VoidCallback>(
        enabled: false,
        height: 32,
        child: Text('Send Program to…', style: TextStyle(fontSize: 12, color: ObsColors.textDim)),
      ),
      entry('This tablet (fullscreen)', () => openProjector(context),
          icon: Icons.fullscreen, key: const ValueKey('projector-tablet')),
      entry('This tablet: Multiview', () => openProjector(context, multiview: true),
          icon: Icons.grid_view, key: const ValueKey('projector-tablet-multiview')),
      if (screens.isEmpty)
        entry('No screen connected', null,
            icon: Icons.desktop_access_disabled_outlined,
            subtitle: 'Plug in a monitor or TV (dock, USB-C or HDMI)')
      else ...[
        const PopupMenuDivider(),
        for (final d in screens) ...[
          entry(
            d.name,
            () => sendTo(d, 'program'),
            key: ValueKey('projector-${d.id}-program'),
            icon: Icons.desktop_windows_outlined,
            checked: isCurrent(d) && mode == 'program',
            subtitle: 'Program · ${d.width}×${d.height}',
          ),
          entry(
            '${d.name}: Multiview',
            () => sendTo(d, 'multiview'),
            key: ValueKey('projector-${d.id}-multiview'),
            icon: Icons.grid_view,
            checked: isCurrent(d) && mode == 'multiview',
          ),
        ],
      ],
      const PopupMenuDivider(),
      entry('Cast to a wireless screen…', () => startScreenCast(context, 'program'),
          icon: Icons.cast, key: const ValueKey('projector-cast'),
          subtitle: 'Smart TV, Miracast, Smart View or AirPlay'),
      if (current?.presenting == true)
        entry('Stop sending (mirror the tablet)', () => studio.updateSettings((s) => s.externalDisplay = 'mirror'),
            icon: Icons.cancel_presentation_outlined, key: const ValueKey('projector-stop')),
    ],
  );
  action?.call();
}

/// Screen cast: opens the system's casting (Cast / Smart View / wireless
/// display on Android; on iPad, explains Screen Mirroring, which only
/// Control Center can start). A TV connected this way is a screen like any
/// other: it shows [mode] ('program' or 'multiview') as soon as it connects.
Future<void> startScreenCast(BuildContext context, String mode) async {
  final scope = AppScope.of(context);
  scope.studio.updateSettings((s) {
    s.externalDisplay = mode;
    s.externalDisplayId = null;
  });
  final what = mode == 'multiview' ? 'the Multiview' : 'the Program';
  final ios = defaultTargetPlatform == TargetPlatform.iOS;
  final opened = ios ? null : await scope.devices.openScreenCast();
  if (!context.mounted) return;
  if (opened != null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('Pick your TV. When it connects, OBSpad shows $what on it. '
          'Chromecast only mirrors the whole tablet; Miracast and Smart View TVs show $what.'),
    ));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('screen-cast-help'),
      title: const Text('Cast to a wireless screen'),
      content: Text(ios
          ? '1. Open Control Center (swipe down from the top-right corner).\n'
              '2. Tap Screen Mirroring and pick your Apple TV or AirPlay TV.\n\n'
              'OBSpad then shows $what on the TV while you keep working on the iPad.'
          : '1. Swipe down twice from the top of the screen for Quick Settings.\n'
              '2. Tap Screen Cast, Smart View or Cast and pick your TV.\n\n'
              'When it connects, OBSpad shows $what on the TV.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ),
  );
}

/// Shows [mode] ('program' or 'multiview') on connected screen [d].
void sendToScreen(StudioController studio, ExternalDisplayInfo d, String mode) => studio.updateSettings((s) {
      s.externalDisplay = mode;
      s.externalDisplayId = d.id.isEmpty ? null : d.id;
    });

/// Fullscreen Projector on the tablet: the program (or the Multiview with
/// [multiview]) edge to edge. Needs no connected screen. Tap (the Program) or
/// press back to close; the Multiview has a close button, since tapping its
/// tiles switches scenes and sources.
void openProjector(BuildContext context, {bool multiview = false}) {
  Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: true,
    pageBuilder: (_, _, _) => ProjectorScreen(multiview: multiview),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ));
}

class ProjectorScreen extends StatefulWidget {
  const ProjectorScreen({super.key, this.multiview = false});

  /// Shows the Multiview instead of the program.
  final bool multiview;

  @override
  State<ProjectorScreen> createState() => _ProjectorScreenState();
}

class _ProjectorScreenState extends State<ProjectorScreen> {
  MultiviewTiles _tiles = MultiviewTiles.scenes;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    if (widget.multiview) {
      return Scaffold(
        key: const ValueKey('projector-screen'),
        backgroundColor: Colors.black,
        body: Stack(children: [
          Center(child: FittedBox(child: Multiview(interactive: true, tiles: _tiles))),
          Positioned(
            top: 8,
            right: 8,
            child: Row(children: [
              SegmentedButton<MultiviewTiles>(
                key: const ValueKey('multiview-tiles'),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: WidgetStatePropertyAll(Color(0xB0000000)),
                ),
                segments: const [
                  ButtonSegment(value: MultiviewTiles.scenes, label: Text('Scenes'), icon: Icon(Icons.grid_view)),
                  ButtonSegment(value: MultiviewTiles.sources, label: Text('Sources'), icon: Icon(Icons.videocam_outlined)),
                ],
                selected: {_tiles},
                onSelectionChanged: (v) => setState(() => _tiles = v.first),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const ValueKey('projector-close'),
                tooltip: 'Close',
                style: const ButtonStyle(backgroundColor: WidgetStatePropertyAll(Color(0xB0000000))),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ]),
          ),
        ]),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        key: const ValueKey('projector-screen'),
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).maybePop(),
        child: Center(
          child: AspectRatio(
            aspectRatio: studio.settings.canvasWidth / studio.settings.canvasHeight,
            child: const ProgramView(capture: false),
          ),
        ),
      ),
    );
  }
}

