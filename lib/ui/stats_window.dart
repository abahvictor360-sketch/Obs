import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../output/output_engine.dart';
import 'theme.dart';

/// View › Stats, like OBS's Stats window: how the output is doing, updated
/// every second.
Future<void> showStats(BuildContext context) => showDialog<void>(
      context: context,
      builder: (context) => const _StatsDialog(),
    );

class _StatsDialog extends StatefulWidget {
  const _StatsDialog();

  @override
  State<_StatsDialog> createState() => _StatsDialogState();
}

class _StatsDialogState extends State<_StatsDialog> {
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  static String _duration(DateTime? since) {
    if (since == null) return '—';
    final d = DateTime.now().difference(since);
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(d.inHours)}:${p(d.inMinutes % 60)}:${p(d.inSeconds % 60)}';
  }

  static String _pct(int part, int whole) => whole <= 0 ? '0.0%' : '${(part * 100 / whole).toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    final out = AppScope.of(context).output;
    final c = out.encoderConfig;
    final status = switch (out.streamStatus) {
      OutputStatus.idle => 'Inactive',
      OutputStatus.starting => 'Connecting…',
      OutputStatus.active => 'Live',
      OutputStatus.reconnecting => 'Reconnecting (attempt ${out.reconnectAttempt})',
      OutputStatus.stopping => 'Stopping…',
    };
    final rendered = out.renderedFrames + out.laggedFrames;
    final dropped = out.droppedFrames;

    Widget row(String label, String value, {Color? color, Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(color: ObsColors.textDim))),
            Text(value,
                key: key,
                style: TextStyle(color: color, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        );
    Widget header(String t) => Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700)),
        );
    final droppedColor = dropped == 0 ? ObsColors.ok : (dropped * 100 > rendered ? ObsColors.live : ObsColors.warn);

    return AlertDialog(
      key: const ValueKey('stats-dialog'),
      title: const Text('Stats'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            header('Output'),
            row('Frame rate', c == null ? '—' : '${out.outputFps.toStringAsFixed(0)} / ${c.fps} FPS'),
            row('Resolution', c == null ? '—' : '${c.width}×${c.height}'),
            row('Frames missed due to rendering lag', '${out.laggedFrames} (${_pct(out.laggedFrames, rendered)})',
                color: out.laggedFrames == 0 ? ObsColors.ok : ObsColors.warn),
            header('Stream'),
            row('Status', status, color: out.streamStatus == OutputStatus.active ? ObsColors.ok : null),
            row('Duration', _duration(out.streamStartedAt)),
            row('Bitrate', out.isStreaming ? '${out.streamKbps.toStringAsFixed(0)} kb/s' : '—',
                key: const ValueKey('stats-bitrate')),
            row('Target bitrate', c == null ? '—' : '${c.videoBitrateKbps + c.audioBitrateKbps} kb/s'),
            row('Dropped frames (network)', '$dropped (${_pct(dropped, rendered)})', color: droppedColor),
            header('Recording'),
            row('Status', out.isRecording ? 'Recording' : 'Inactive', color: out.isRecording ? ObsColors.rec : null),
            row('Duration', _duration(out.recordStartedAt)),
            if (out.lastRecordingPath != null) row('Last file', out.lastRecordingPath!.split('/').last),
            header('NDI'),
            row('Status', out.ndiActive ? 'Sending as ${out.ndiName}' : 'Off'),
          ]),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
