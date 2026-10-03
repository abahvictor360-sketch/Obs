import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../devices/device_service.dart';
import 'output_engine.dart';

/// Sends the program to a screen connected through a docking station,
/// USB-C or HDMI (OBS's "fullscreen projector").
///
/// The native side shows the frames full screen on the external display
/// (Android Presentation, iPad external display scene). While the encoder is
/// running its frames are reused; otherwise the program view is captured
/// here at up to [maxFps].
class ExternalDisplayOutput {
  ExternalDisplayOutput({
    required this.output,
    required this.devices,
    BasicMessageChannel<ByteData?>? frames,
    this.maxFps = 30,
  }) : _frames = frames ?? const BasicMessageChannel<ByteData?>('obs_tablet/display_frames', BinaryCodec()) {
    devices.addListener(_sync);
    output.addListener(_sync);
    _sync();
  }

  final OutputEngine output;
  final DeviceService devices;
  final BasicMessageChannel<ByteData?> _frames;
  final int maxFps;

  Timer? _timer;
  bool _sending = false;
  bool _capturing = false;
  int _lastSentUs = 0;
  int framesSent = 0;

  bool get active => devices.dock.display?.presenting == true;

  void _sync() {
    final on = active;
    output.externalPresenting = on;
    if (on) {
      output.programFrameTap = _onEncoderFrame;
      _timer ??= Timer.periodic(Duration(microseconds: 1000000 ~/ maxFps), (_) => _tick());
    } else {
      if (output.programFrameTap == _onEncoderFrame) output.programFrameTap = null;
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Largest frame worth sending: the display's size, at most 1080p.
  (int, int) _targetSize() {
    final d = devices.dock.display;
    final w = math.min(d?.width ?? 1920, 1920);
    final h = math.min(d?.height ?? 1080, 1080);
    return (w, h);
  }

  void _onEncoderFrame(Uint8List rgba, int w, int h) {
    if (!active) return;
    _send(rgba, w, h);
  }

  @visibleForTesting
  Future<void> debugTick() => _tick();

  Future<void> _tick() async {
    // The encoder already captures the whole program: _onEncoderFrame sends it.
    if (output.pumpingProgramFrames || _capturing || _sending) return;
    final ro = output.programKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.attached || ro.size.isEmpty) return;
    _capturing = true;
    try {
      final (tw, th) = _targetSize();
      final ratio = math.min(tw / ro.size.width, th / ro.size.height);
      final image = await ro.toImage(pixelRatio: ratio);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = image.width, h = image.height;
      image.dispose();
      if (data != null && active) {
        await _send(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), w, h);
      }
    } catch (e) {
      debugPrint('External display capture failed: $e');
    } finally {
      _capturing = false;
    }
  }

  /// Frame message: width, height (uint32 LE) then RGBA pixels. Frames are
  /// dropped while the previous one is still being drawn.
  Future<void> _send(Uint8List rgba, int w, int h) async {
    if (_sending || rgba.length < w * h * 4) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    if (now - _lastSentUs < 1000000 ~/ maxFps - 2000) return;
    _lastSentUs = now;
    _sending = true;
    try {
      final msg = Uint8List(8 + w * h * 4);
      final header = ByteData.sublistView(msg, 0, 8);
      header.setUint32(0, w, Endian.little);
      header.setUint32(4, h, Endian.little);
      msg.setRange(8, msg.length, rgba);
      await _frames.send(ByteData.sublistView(msg));
      framesSent++;
    } catch (e) {
      debugPrint('External display send failed: $e');
    } finally {
      _sending = false;
    }
  }

  void dispose() {
    devices.removeListener(_sync);
    output.removeListener(_sync);
    _timer?.cancel();
    if (output.programFrameTap == _onEncoderFrame) output.programFrameTap = null;
    output.externalPresenting = false;
  }
}
