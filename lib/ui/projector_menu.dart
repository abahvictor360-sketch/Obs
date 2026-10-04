import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../core/studio_controller.dart';
import '../devices/device_service.dart';
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
        if (current?.presenting == true)
          entry('Stop sending (mirror the tablet)', () => studio.updateSettings((s) => s.externalDisplay = 'mirror'),
              icon: Icons.cancel_presentation_outlined, key: const ValueKey('projector-stop')),
      ],
    ],
  );
  action?.call();
}

/// Shows [mode] ('program' or 'multiview') on connected screen [d].
void sendToScreen(StudioController studio, ExternalDisplayInfo d, String mode) => studio.updateSettings((s) {
      s.externalDisplay = mode;
      s.externalDisplayId = d.id.isEmpty ? null : d.id;
    });

/// Fullscreen Projector on the tablet: just the program, edge to edge.
/// Tap or press back to close.
void openProjector(BuildContext context) {
  Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: true,
    pageBuilder: (_, _, _) => const ProjectorScreen(),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ));
}

class ProjectorScreen extends StatefulWidget {
  const ProjectorScreen({super.key});

  @override
  State<ProjectorScreen> createState() => _ProjectorScreenState();
}

class _ProjectorScreenState extends State<ProjectorScreen> {
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

