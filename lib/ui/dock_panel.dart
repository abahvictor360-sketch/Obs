import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../devices/device_service.dart';
import 'theme.dart';

/// Top-bar chip shown while a docking station (or anything it brings: a
/// screen, Ethernet, USB audio/video) is connected. Tap for details.
class DockChip extends StatelessWidget {
  const DockChip({super.key});

  @override
  Widget build(BuildContext context) {
    final devices = AppScope.of(context).devices;
    return ListenableBuilder(
      listenable: Listenable.merge([devices, AppScope.of(context).studio]),
      builder: (context, _) => _build(context, devices),
    );
  }

  Widget _build(BuildContext context, DeviceService devices) {
    final dock = devices.dock;
    if (!devices.supported || !dock.docked) return const SizedBox.shrink();
    final d = dock.display;
    final mode = AppScope.of(context).studio.settings.externalDisplay;
    final label = d == null
        ? 'Docked'
        : !d.presenting
            ? 'Docked · Mirroring'
            : mode == 'multiview'
                ? 'Docked · Multiview'
                : 'Docked · Program';
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: InkWell(
        key: const ValueKey('dock-chip'),
        borderRadius: BorderRadius.circular(4),
        onTap: () => showDockSheet(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: ObsColors.ok),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(d != null ? Icons.desktop_windows_outlined : Icons.dock, size: 14, color: ObsColors.ok),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12, color: ObsColors.ok)),
          ]),
        ),
      ),
    );
  }
}

Future<void> showDockSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: ObsColors.panel,
    builder: (_) => const DockPanel(),
  );
}

/// What's connected through the dock, and what the connected screen shows.
class DockPanel extends StatelessWidget {
  const DockPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.devices, scope.studio]),
      builder: (context, _) {
        final dock = scope.devices.dock;
        final d = dock.display;
        Widget row(IconData icon, String title, bool on, [String? detail]) => ListTile(
              dense: true,
              leading: Icon(icon, color: on ? ObsColors.ok : ObsColors.textDim),
              title: Text(title),
              subtitle: Text(detail ?? (on ? 'Connected' : 'Not connected'),
                  style: const TextStyle(color: ObsColors.textDim)),
            );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(dock.docked ? 'Docking station connected' : 'No docking station',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              row(Icons.desktop_windows_outlined, 'Screen', d != null,
                  d == null ? 'Connect a monitor or TV via the dock, USB-C or HDMI' : '${d.name} · ${d.width}×${d.height}'),
              if (d == null) _NoScreenHelp(billboard: dock.billboard, ios: defaultTargetPlatform == TargetPlatform.iOS),
              if (d != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DisplayModeSelector(display: d),
                ),
              row(Icons.settings_ethernet, 'Ethernet', dock.ethernet,
                  dock.ethernet ? 'Wired network available (Settings › Prefer wired connection)' : null),
              row(Icons.mic_external_on, 'USB audio', dock.usbAudio,
                  dock.usbAudio ? 'Pick it in a Mic/Aux source’s properties' : null),
              row(Icons.videocam_outlined, 'Capture card / USB camera', dock.usbVideo,
                  dock.usbVideo ? 'Add a "USB Video" source to use it' : null),
              row(Icons.battery_charging_full, 'Power', dock.charging, dock.charging ? 'Charging' : 'Not charging'),
              if (dock.seen.isNotEmpty)
                ExpansionTile(
                  key: const ValueKey('dock-seen'),
                  dense: true,
                  title: const Text('What the tablet sees'),
                  subtitle: Text('${dock.seen.length} item${dock.seen.length == 1 ? '' : 's'}',
                      style: const TextStyle(color: ObsColors.textDim)),
                  children: [
                    for (final line in dock.seen)
                      ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          title: Text(line, style: const TextStyle(fontSize: 13))),
                  ],
                ),
            ]),
          ),
        );
      },
    );
  }
}

/// Why no screen shows up, and what to try.
class _NoScreenHelp extends StatelessWidget {
  const _NoScreenHelp({required this.billboard, required this.ios});

  final bool billboard;
  final bool ios;

  @override
  Widget build(BuildContext context) {
    final tips = [
      if (billboard)
        'The dock or adapter reports that this tablet refused video over USB-C: its USB-C port has no '
            'video output (DisplayPort Alt Mode). The dock\'s USB devices, network and charging still work.',
      if (!billboard && !ios)
        'If the TV shows no picture at all (not even the tablet mirrored), the tablet\'s USB-C port '
            'doesn\'t send video. Many tablets only charge and transfer data over USB-C: check that the '
            'model supports "DisplayPort Alt Mode" / video out, or cast wirelessly instead.',
      if (!ios)
        'Samsung tablets: after plugging in, pull down the notification shade and pick "Samsung DeX" or '
            '"Screen mirroring"; OBSpad then shows the program on the TV.',
      if (ios)
        'iPad: if the screen is mirroring or used by Stage Manager, unplug it and plug it in again with '
            'OBSpad open.',
      'Plug the HDMI cable into the dock before connecting the dock to the tablet, and power the dock '
          'with its own charger.',
    ];
    return Padding(
      key: const ValueKey('dock-no-screen-help'),
      padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final (i, t) in tips.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('• $t',
                style: TextStyle(fontSize: 12, color: billboard && i == 0 ? ObsColors.warn : ObsColors.textDim)),
          ),
      ]),
    );
  }
}

/// "Program" (full screen, like OBS's fullscreen projector), "Multiview"
/// (preview, program and scenes) or "Mirror tablet".
class DisplayModeSelector extends StatelessWidget {
  const DisplayModeSelector({super.key, required this.display});

  final ExternalDisplayInfo display;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final mode = studio.settings.externalDisplay;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'program', icon: Icon(Icons.live_tv), label: Text('Program')),
          ButtonSegment(value: 'multiview', icon: Icon(Icons.grid_view), label: Text('Multiview')),
          ButtonSegment(value: 'mirror', icon: Icon(Icons.tablet), label: Text('Mirror tablet')),
        ],
        selected: {mode},
        onSelectionChanged: (v) => studio.updateSettings((s) => s.externalDisplay = v.first),
      ),
      const SizedBox(height: 6),
      Text(
        mode != 'mirror'
            ? (display.presenting
                ? (mode == 'multiview'
                    ? 'The screen shows Preview and Program on top and your scenes below (red: program, '
                        'green: preview).'
                    : 'The screen shows the program full screen. The tablet stays your control surface.')
                : display.needsReconnect
                    ? 'To show the program, unplug and reconnect the screen (with Stage Manager, turn off its '
                        'extended display first).'
                    : 'Starting the program on the screen…')
            : 'The screen mirrors the tablet.',
        style: const TextStyle(fontSize: 12, color: ObsColors.textDim),
      ),
    ]);
  }
}

/// Shows a snack bar when a dock or screen is connected or removed.
class DockListener extends StatefulWidget {
  const DockListener({super.key, required this.devices, required this.child});

  final DeviceService devices;
  final Widget child;

  @override
  State<DockListener> createState() => _DockListenerState();
}

class _DockListenerState extends State<DockListener> {
  late bool _docked = widget.devices.dock.docked;
  late bool _screen = widget.devices.dock.display != null;
  late Set<String> _usbAudio = {for (final i in widget.devices.usbAudioInputs) i.id};

  @override
  void initState() {
    super.initState();
    widget.devices.addListener(_check);
  }

  @override
  void dispose() {
    widget.devices.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!mounted) return;
    _checkUsbAudio();
    final dock = widget.devices.dock;
    final screen = dock.display;
    String? msg;
    if (screen != null && !_screen) {
      msg = 'Screen connected: ${screen.name} (${screen.width}×${screen.height})';
    } else if (screen == null && _screen) {
      msg = 'Screen disconnected';
    } else if (dock.docked && !_docked) {
      msg = 'Docking station connected: ${dock.features.join(', ')}';
    } else if (!dock.docked && _docked) {
      msg = 'Docking station disconnected';
    }
    _docked = dock.docked;
    _screen = screen != null;
    if (msg != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: ObsColors.panelAlt,
        action: dock.docked ? SnackBarAction(label: 'Details', onPressed: () => showDockSheet(context)) : null,
      ));
    }
  }

  /// A USB sound card / mic / interface appeared (directly, through a hub or
  /// a docking station): say where it's used, or offer to add it.
  void _checkUsbAudio() {
    final usb = widget.devices.usbAudioInputs;
    final added = usb.where((i) => !_usbAudio.contains(i.id)).toList();
    _usbAudio = {for (final i in usb) i.id};
    if (added.isEmpty) return;
    final device = added.first;
    final studio = AppScope.of(context).studio;
    final mic = studio.sources.where((s) => s.type == SourceType.audioInput).firstOrNull;
    final auto = mic != null && (mic.settings['device'] as String? ?? 'default') == 'default';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(mic == null
          ? 'USB audio connected: ${device.name}'
          : auto
              ? 'USB audio connected: ${device.name}. ${mic.name} now records from it.'
              : 'USB audio connected: ${device.name}'),
      backgroundColor: ObsColors.panelAlt,
      action: mic == null
          ? SnackBarAction(
              label: 'Add to Mixer',
              onPressed: () => studio.addNewSource(SourceType.audioInput,
                  name: studio.uniqueSourceName(device.name), settings: {'device': device.id}),
            )
          : auto
              ? null
              : SnackBarAction(
                  label: 'Use it',
                  onPressed: () => studio.updateSourceSettings(mic.id, {'device': device.id}),
                ),
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
