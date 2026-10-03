import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../output/output_engine.dart';
import '../render/editable_canvas.dart';
import '../render/program_view.dart';
import '../render/scene_canvas.dart';
import 'docks.dart';
import 'theme.dart';

/// The main window. Landscape tablets get OBS's classic layout (canvas on top,
/// docks in a row below). Portrait tablets and phones get the canvas, a row of
/// big controls and tabbed docks.
class StudioScreen extends StatelessWidget {
  const StudioScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final out = AppScope.of(context).output;
    return Scaffold(
      body: SafeArea(
        child: _ErrorListener(
          output: out,
          child: LayoutBuilder(
            builder: (context, box) {
              final landscape = box.maxWidth > box.maxHeight && box.maxWidth >= 900;
              return landscape ? _LandscapeLayout(height: box.maxHeight) : const _PortraitLayout();
            },
          ),
        ),
      ),
    );
  }
}

class _LandscapeLayout extends StatelessWidget {
  const _LandscapeLayout({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final dockHeight = (height * 0.36).clamp(220.0, 340.0);
    return Column(
      children: [
        const _TopBar(),
        const Expanded(child: Padding(padding: EdgeInsets.all(6), child: _CanvasArea())),
        SizedBox(
          height: dockHeight,
          child: const Padding(
            padding: EdgeInsets.fromLTRB(6, 0, 6, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 4, child: ScenesDock()),
                SizedBox(width: 6),
                Expanded(flex: 5, child: SourcesDock()),
                SizedBox(width: 6),
                Expanded(flex: 5, child: MixerDock()),
                SizedBox(width: 6),
                Expanded(flex: 3, child: TransitionsDock()),
                SizedBox(width: 6),
                Expanded(flex: 3, child: ControlsDock()),
              ],
            ),
          ),
        ),
        const StatusBar(),
      ],
    );
  }
}

class _PortraitLayout extends StatelessWidget {
  const _PortraitLayout();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const _TopBar(),
          LayoutBuilder(builder: (context, box) {
            final studio = AppScope.of(context).studio;
            final aspect = studio.settings.canvasWidth / studio.settings.canvasHeight;
            final h = box.maxWidth / aspect;
            return ListenableBuilder(
              listenable: studio,
              builder: (context, _) => SizedBox(
                height: studio.studioMode ? h * 0.55 + 56 : h + 12,
                child: const Padding(padding: EdgeInsets.all(6), child: _CanvasArea()),
              ),
            );
          }),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: ControlsDock(compact: true),
          ),
          const TabBar(
            tabs: [
              Tab(text: 'Scenes'),
              Tab(text: 'Sources'),
              Tab(text: 'Mixer'),
              Tab(text: 'Transitions'),
            ],
          ),
          const Expanded(
            child: Padding(
              padding: EdgeInsets.all(6),
              child: TabBarView(
                children: [
                  ScenesDock(showTitle: false),
                  SourcesDock(showTitle: false),
                  MixerDock(showTitle: false),
                  TransitionsDock(showTitle: false),
                ],
              ),
            ),
          ),
          const StatusBar(),
        ],
      ),
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
              Container(
                width: 26,
                height: 26,
                decoration: const BoxDecoration(color: ObsColors.text, shape: BoxShape.circle),
                child: const Icon(Icons.radio_button_checked, size: 20, color: ObsColors.header),
              ),
              const SizedBox(width: 10),
              const Text('OBS Tablet', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  '— ${scope.studio.programScene.name}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: ObsColors.textDim),
                ),
              ),
              const Spacer(),
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
          return const EditableCanvas(content: ProgramView());
        }
        return LayoutBuilder(builder: (context, box) {
          final preview = EditableCanvas(
            label: 'Preview',
            content: FittedBox(child: SceneCanvas(scene: studio.previewScene)),
          );
          const program = EditableCanvas(label: 'Program', editable: false, content: ProgramView());
          final transitionButton = FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: ObsColors.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(140, 48),
            ),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Transition'),
            onPressed: studio.transitionToProgram,
          );
          return Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: preview),
                    const SizedBox(width: 6),
                    const Expanded(child: program),
                  ],
                ),
              ),
              Padding(padding: const EdgeInsets.only(top: 6), child: transitionButton),
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
    return ListenableBuilder(
      listenable: out,
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
