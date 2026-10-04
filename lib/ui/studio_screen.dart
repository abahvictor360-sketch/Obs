import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../devices/device_service.dart';
import '../output/output_engine.dart';
import '../render/editable_canvas.dart';
import '../render/multiview.dart';
import '../render/program_view.dart';
import '../render/scene_canvas.dart';
import 'dock_panel.dart';
import 'dock_layout.dart';
import 'docks.dart';
import 'menu_bar.dart';
import 'projector_menu.dart';
import 'theme.dart';
import 'transition_panel.dart';
import 'update_prompt.dart';

/// The main window. Landscape tablets get OBS's classic layout (canvas on top,
/// docks in a row below). Portrait tablets and phones get the canvas, a row of
/// big controls and tabbed docks.
class StudioScreen extends StatelessWidget {
  const StudioScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final out = AppScope.of(context).output;
    // The Multiview for a connected screen sits behind the (opaque) studio,
    // where it's laid out and painted for capture but never seen.
    return Stack(children: [
      const Positioned.fill(child: MultiviewHost()),
      Scaffold(
        body: SafeArea(
          child: _ErrorListener(
            output: out,
            child: UpdateListener(
              child: DockListener(
                devices: AppScope.of(context).devices,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final landscape = box.maxWidth > box.maxHeight && box.maxWidth >= 900;
                    return landscape ? _LandscapeLayout(height: box.maxHeight) : const _PortraitLayout();
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _LandscapeLayout extends StatelessWidget {
  const _LandscapeLayout({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _TopBar(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => LandscapeWorkspace(height: box.maxHeight, canvas: const _CanvasArea()),
          ),
        ),
        const StatusBar(),
      ],
    );
  }
}

class _PortraitLayout extends StatelessWidget {
  const _PortraitLayout();

  static const _tabTitles = {'scenes': 'Scenes', 'sources': 'Sources', 'mixer': 'Mixer', 'transitions': 'Transitions'};

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        final tabs = studio.allDocks
            .where((d) => (_tabTitles.containsKey(d.id) || d.id.startsWith('browser-')) && studio.isDockVisible(d.id))
            .toList();
        return DefaultTabController(
          key: ValueKey(tabs.map((d) => d.id).join(',')),
          length: tabs.length,
          child: Column(
            children: [
              const _TopBar(),
              LayoutBuilder(builder: (context, box) {
                final aspect = studio.settings.canvasWidth / studio.settings.canvasHeight;
                final h = box.maxWidth / aspect;
                final canvas = SizedBox(
                  height: studio.studioMode ? h * 0.55 + 56 : h + 12,
                  child: const Padding(padding: EdgeInsets.all(6), child: _CanvasArea()),
                );
                return canvas;
              }),
              if (studio.isDockVisible('controls'))
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                  child: ControlsDock(compact: true),
                ),
              if (tabs.isNotEmpty) ...[
                TabBar(
                  isScrollable: tabs.length > 4,
                  tabs: [for (final d in tabs) Tab(text: _tabTitles[d.id] ?? d.title)],
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: TabBarView(children: [for (final d in tabs) d.build(showTitle: false)]),
                  ),
                ),
              ] else
                const Spacer(),
              const StatusBar(),
            ],
          ),
        );
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.studio, scope.output]),
      builder: (context, _) {
        final out = scope.output;
        return Container(
          height: 44,
          color: ObsColors.header,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Image.asset('assets/logo.png', width: 26, height: 26, filterQuality: FilterQuality.medium),
              const SizedBox(width: 6),
              Flexible(
                flex: 8,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ObsMenuBar(compact: MediaQuery.sizeOf(context).width < 1000),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  '— ${scope.studio.programScene.name}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: ObsColors.textDim),
                ),
              ),
              const Spacer(),
              const DockChip(),
              if (out.isStreaming) const _Pill(text: 'LIVE', color: ObsColors.live),
              if (out.isRecording) const _Pill(text: 'REC', color: ObsColors.rec),
              if (out.initialized && !out.encoderSupported)
                const Tooltip(
                  message: 'Streaming and recording need the native encoder, which is not '
                      'available on this platform yet. Scene editing works fully.',
                  child: _Pill(text: 'PREVIEW ONLY', color: ObsColors.panelAlt),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      );
}

/// Preview (and in studio mode, program side by side with a Transition
/// button between them).
class _CanvasArea extends StatelessWidget {
  const _CanvasArea();

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        if (!studio.studioMode) {
          // Normal mode: what you edit is what's live.
          return EditableCanvas(
            content: const ProgramView(),
            onLongPressCanvas: (g) => showProjectorMenu(context, g),
          );
        }
        return LayoutBuilder(builder: (context, box) {
          final preview = EditableCanvas(
            label: 'Preview',
            content: FittedBox(child: SceneCanvas(scene: studio.previewScene)),
          );
          final program = EditableCanvas(
            label: 'Program',
            editable: false,
            content: const ProgramView(),
            onLongPressCanvas: (g) => showProjectorMenu(context, g),
          );
          // Wide: OBS's column between Preview and Program. Narrow: a strip
          // below them.
          if (box.maxWidth >= 760) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: preview),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Center(child: TransitionPanel()),
                ),
                Expanded(child: program),
              ],
            );
          }
          return Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: preview),
                    const SizedBox(width: 6),
                    Expanded(child: program),
                  ],
                ),
              ),
              const Padding(padding: EdgeInsets.only(top: 6), child: TransitionPanel(vertical: false)),
            ],
          );
        });
      },
    );
  }
}

class StatusBar extends StatefulWidget {
  const StatusBar({super.key});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String _dur(DateTime? since) {
    if (since == null) return '00:00:00';
    final d = DateTime.now().difference(since);
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(d.inHours)}:${p(d.inMinutes % 60)}:${p(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final out = AppScope.of(context).output;
    final devices = AppScope.of(context).devices;
    return ListenableBuilder(
      listenable: Listenable.merge([out, devices]),
      builder: (context, _) {
        final dim = const TextStyle(fontSize: 12, color: ObsColors.textDim, fontFeatures: [FontFeature.tabularFigures()]);
        final dropPct = out.renderedFrames == 0 ? 0 : out.droppedFrames * 100 / out.renderedFrames;
        Color dot(OutputStatus s, Color c) => switch (s) {
              OutputStatus.active => c,
              OutputStatus.idle => ObsColors.border,
              _ => ObsColors.warn,
            };
        return Container(
          height: 28,
          color: ObsColors.header,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (out.lastError != null)
                Expanded(
                  child: Text(out.lastError!,
                      overflow: TextOverflow.ellipsis, style: dim.copyWith(color: ObsColors.warn)),
                )
              else
                const Spacer(),
              if (out.isStreaming) ...[
                Text('Dropped ${out.droppedFrames} (${dropPct.toStringAsFixed(1)}%)', style: dim),
                const SizedBox(width: 16),
                Text('${out.streamKbps.round()} kb/s', style: dim),
                const SizedBox(width: 16),
              ],
              if (out.isStreaming || out.isRecording) ...[
                Text('${out.outputFps.toStringAsFixed(0)} fps', style: dim),
                const SizedBox(width: 16),
              ],
              if (devices.supported) ...[
                _NetworkBadge(info: devices.network, style: dim),
                const SizedBox(width: 16),
              ],
              if (out.ndiActive) ...[
                Text('NDI · ${out.ndiConnections}', style: dim.copyWith(color: ObsColors.ok)),
                const SizedBox(width: 16),
              ],
              Icon(Icons.podcasts, size: 14, color: dot(out.streamStatus, ObsColors.live)),
              const SizedBox(width: 4),
              Text(_dur(out.streamStartedAt), style: dim),
              const SizedBox(width: 16),
              Icon(Icons.fiber_manual_record, size: 14, color: dot(out.recordStatus, ObsColors.rec)),
              const SizedBox(width: 4),
              Text(_dur(out.recordStartedAt), style: dim),
            ],
          ),
        );
      },
    );
  }
}

/// Shows output errors as snack bars as they happen.
class _ErrorListener extends StatefulWidget {
  const _ErrorListener({required this.output, required this.child});

  final OutputEngine output;
  final Widget child;

  @override
  State<_ErrorListener> createState() => _ErrorListenerState();
}

class _ErrorListenerState extends State<_ErrorListener> {
  String? _shown;

  @override
  void initState() {
    super.initState();
    widget.output.addListener(_check);
  }

  @override
  void dispose() {
    widget.output.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final e = widget.output.lastError;
    if (e != null && e != _shown && mounted) {
      _shown = e;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e), backgroundColor: ObsColors.panelAlt));
    }
    if (e == null) _shown = null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Which network the stream goes out on (USB Ethernet shows as "Wired").
class _NetworkBadge extends StatelessWidget {
  const _NetworkBadge({required this.info, required this.style});

  final NetworkInfo info;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (info.transport) {
      'ethernet' => (Icons.settings_ethernet, 'Wired', ObsColors.ok),
      'wifi' => (Icons.wifi, 'Wi-Fi', ObsColors.textDim),
      'cellular' => (Icons.signal_cellular_alt, 'Mobile data', ObsColors.warn),
      'none' => (Icons.signal_wifi_off, 'Offline', ObsColors.live),
      _ => (Icons.lan_outlined, 'Network', ObsColors.textDim),
    };
    return Tooltip(
      message: info.wiredAvailable && info.transport != 'ethernet'
          ? 'A wired adapter is connected but not in use. Turn on "Prefer wired connection" in Settings.'
          : 'Streaming over: $label',
      child: Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: style.copyWith(color: color)),
      ]),
    );
  }
}
