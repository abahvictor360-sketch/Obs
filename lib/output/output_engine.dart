import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/studio_controller.dart';
import 'av_packager.dart';
import 'encoder_backend.dart';
import 'flv.dart';
import 'sinks.dart';

enum OutputStatus { idle, starting, active, reconnecting, stopping }

/// Drives streaming and recording, like OBS's output subsystem:
///
///   program canvas --(frame pump)--> native encoder --(packets)--> sinks
///
/// One encoder is shared by the stream and the recording; each has its own
/// [AvPackager] so they can start/stop independently.
class OutputEngine extends ChangeNotifier {
  OutputEngine({required this.studio, EncoderBackend? backend})
      : backend = backend ?? MethodChannelEncoder() {
    studio.addListener(_onStudioChanged);
  }

  final StudioController studio;
  final EncoderBackend backend;

  /// Wraps the program canvas; frames are captured from it.
  final GlobalKey programKey = GlobalKey(debugLabel: 'program');

  OutputStatus streamStatus = OutputStatus.idle;
  OutputStatus recordStatus = OutputStatus.idle;
  DateTime? streamStartedAt;
  DateTime? recordStartedAt;
  String? lastError;
  String? lastRecordingPath;

  /// Live stats, refreshed every second.
  double streamKbps = 0;
  int droppedFrames = 0;
  int renderedFrames = 0;
  int laggedFrames = 0;
  double outputFps = 0;
  AudioLevel micLevel = const AudioLevel(0, 0);
  int reconnectAttempt = 0;

  bool? _supported;
  bool get encoderSupported => _supported ?? false;
  bool get initialized => _supported != null;

  EncoderConfig? _config;
  bool _encoderRunning = false;
  Timer? _pumpTimer;
  Timer? _statsTimer;
  bool _capturing = false;
  StreamSubscription<EncodedPacket>? _packetSub;
  StreamSubscription<AudioLevel>? _levelSub;
  StreamSubscription<String>? _errorSub;

  PacketSink? _streamSink;
  AvPackager? _streamPackager;
  PacketSink? _recordSink;
  AvPackager? _recordPackager;
  bool _nativeMp4 = false;

  int _lastStreamBytes = 0;
  int _framesThisSecond = 0;
  double _lastMicGain = -1;

  bool get isStreaming => streamStatus != OutputStatus.idle;
  bool get isRecording => recordStatus != OutputStatus.idle;

  Future<void> init() async {
    _supported = await backend.isSupported() && sinksSupported;
    _levelSub = backend.levels.listen((l) {
      micLevel = l;
      notifyListeners();
    });
    _errorSub = backend.errors.listen((e) {
      lastError = e;
      notifyListeners();
    });
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Streaming

  Future<void> startStreaming() async {
    if (isStreaming) return;
    final url = studio.settings.publishUrl;
    if (url.isEmpty) {
      _error('Set a server and stream key in Settings > Stream first.');
      return;
    }
    if (!encoderSupported) {
      _error('Hardware encoder is not available on this device yet.');
      return;
    }
    lastError = null;
    streamStatus = OutputStatus.starting;
    notifyListeners();
    try {
      await _ensureEncoder();
      await _openStreamSink(url);
      streamStatus = OutputStatus.active;
      streamStartedAt = DateTime.now();
      droppedFrames = 0;
      reconnectAttempt = 0;
      await backend.requestKeyframe();
    } catch (e) {
      _streamSink = null;
      _streamPackager = null;
      streamStatus = OutputStatus.idle;
      _error('Could not start streaming: $e');
      await _maybeStopEncoder();
    }
    _updateWakelock();
    notifyListeners();
  }

  Future<void> _openStreamSink(String url) async {
    final sink = createRtmpSink(url);
    sink.onError = (e) => _onStreamLost(e);
    await sink.open();
    _lastStreamBytes = 0;
    _streamSink = sink;
    _streamPackager = AvPackager(sink, metadataBuilder: _metadata);
  }

  Future<void> _onStreamLost(Object error) async {
    if (streamStatus != OutputStatus.active) return;
    streamStatus = OutputStatus.reconnecting;
    _streamSink = null;
    _streamPackager = null;
    lastError = 'Disconnected: $error';
    notifyListeners();
    // Auto-reconnect like OBS: up to 10 tries, 5 s apart.
    for (reconnectAttempt = 1; reconnectAttempt <= 10; reconnectAttempt++) {
      notifyListeners();
      await Future<void>.delayed(const Duration(seconds: 5));
      if (streamStatus != OutputStatus.reconnecting) return; // user stopped
      try {
        await _openStreamSink(studio.settings.publishUrl);
        streamStatus = OutputStatus.active;
        lastError = null;
        await backend.requestKeyframe();
        notifyListeners();
        return;
      } catch (e) {
        lastError = 'Reconnect $reconnectAttempt failed: $e';
      }
    }
    streamStatus = OutputStatus.idle;
    streamStartedAt = null;
    _error('Stream disconnected and could not reconnect.');
    await _maybeStopEncoder();
    _updateWakelock();
  }

  Future<void> stopStreaming() async {
    if (!isStreaming) return;
    streamStatus = OutputStatus.stopping;
    notifyListeners();
    final sink = _streamSink;
    _streamSink = null;
    _streamPackager = null;
    try {
      await sink?.close();
    } catch (_) {}
    streamStatus = OutputStatus.idle;
    streamStartedAt = null;
    streamKbps = 0;
    await _maybeStopEncoder();
    _updateWakelock();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Recording

  Future<void> startRecording() async {
    if (isRecording) return;
    if (!encoderSupported) {
      _error('Hardware encoder is not available on this device yet.');
      return;
    }
    lastError = null;
    recordStatus = OutputStatus.starting;
    notifyListeners();
    try {
      await _ensureEncoder();
      final wantMp4 = studio.settings.recordingFormat == 'mp4';
      String? path;
      if (wantMp4) {
        try {
          path = await backend.startMp4Recording();
        } catch (_) {
          path = null; // fall back to FLV
        }
      }
      if (path != null) {
        _nativeMp4 = true;
      } else {
        _nativeMp4 = false;
        final dir = await recordingsDirectory();
        path = '$dir/${_timestampName()}.flv';
        final sink = createFlvFileSink(path);
        sink.onError = (e) {
          _error('Recording failed: $e');
          stopRecording();
        };
        await sink.open();
        _recordSink = sink;
        _recordPackager = AvPackager(sink, metadataBuilder: _metadata);
      }
      lastRecordingPath = path;
      recordStatus = OutputStatus.active;
      recordStartedAt = DateTime.now();
      await backend.requestKeyframe();
    } catch (e) {
      recordStatus = OutputStatus.idle;
      _error('Could not start recording: $e');
      await _maybeStopEncoder();
    }
    _updateWakelock();
    notifyListeners();
  }

  Future<void> stopRecording() async {
    if (!isRecording) return;
    recordStatus = OutputStatus.stopping;
    notifyListeners();
    try {
      if (_nativeMp4) {
        final path = await backend.stopMp4Recording();
        if (path != null) lastRecordingPath = path;
      } else {
        final sink = _recordSink;
        _recordSink = null;
        _recordPackager = null;
        await sink?.close();
      }
    } catch (e) {
      _error('Error finishing recording: $e');
    }
    _nativeMp4 = false;
    recordStatus = OutputStatus.idle;
    recordStartedAt = null;
    await _maybeStopEncoder();
    _updateWakelock();
    notifyListeners();
  }

  static String _timestampName() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${p(n.month)}-${p(n.day)} ${p(n.hour)}-${p(n.minute)}-${p(n.second)}';
  }

  // ---------------------------------------------------------------------------
  // Encoder + frame pump

  Map<String, Object?> _metadata() {
    final c = _config!;
    return Flv.metadata(
      width: c.width,
      height: c.height,
      fps: c.fps,
      videoKbps: c.videoBitrateKbps,
      audioKbps: c.audioBitrateKbps,
      sampleRate: c.sampleRate,
      channels: c.channels,
    );
  }

  Future<void> _ensureEncoder() async {
    if (_encoderRunning) return;
    final s = studio.settings;
    // Hardware encoders want even dimensions.
    final config = EncoderConfig(
      width: s.outputWidth & ~1,
      height: s.outputHeight & ~1,
      fps: s.fps,
      videoBitrateKbps: s.videoBitrateKbps,
      audioBitrateKbps: s.audioBitrateKbps,
      keyframeIntervalSec: s.keyframeIntervalSec,
    );
    _config = config;
    _packetSub = backend.packets.listen(_onPacket);
    await backend.start(config);
    _lastMicGain = -1;
    _onStudioChanged();
    _encoderRunning = true;
    renderedFrames = 0;
    laggedFrames = 0;
    _pumpTimer = Timer.periodic(Duration(microseconds: 1000000 ~/ config.fps), (_) => _captureFrame());
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickStats());
  }

  Future<void> _maybeStopEncoder() async {
    if (!_encoderRunning || isStreaming || isRecording) return;
    _encoderRunning = false;
    _pumpTimer?.cancel();
    _statsTimer?.cancel();
    _pumpTimer = null;
    _statsTimer = null;
    await _packetSub?.cancel();
    _packetSub = null;
    try {
      await backend.stop();
    } catch (_) {}
    outputFps = 0;
    micLevel = const AudioLevel(0, 0);
  }

  void _onPacket(EncodedPacket p) {
    _streamPackager?.push(p);
    _recordPackager?.push(p);
  }

  Future<void> _captureFrame() async {
    if (_capturing) {
      laggedFrames++;
      return;
    }
    final config = _config;
    final ctx = programKey.currentContext;
    final ro = ctx?.findRenderObject();
    if (config == null || ro is! RenderRepaintBoundary || !ro.attached || ro.size.isEmpty) return;
    _capturing = true;
    try {
      final image = await ro.toImage(pixelRatio: config.width / ro.size.width);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = image.width, h = image.height;
      image.dispose();
      if (data != null && _encoderRunning) {
        await backend.pushFrame(data.buffer.asUint8List(), w, h);
        renderedFrames++;
        _framesThisSecond++;
      }
    } catch (e) {
      debugPrint('Frame capture failed: $e');
    } finally {
      _capturing = false;
    }
  }

  void _tickStats() {
    outputFps = _framesThisSecond.toDouble();
    _framesThisSecond = 0;
    final sink = _streamSink;
    if (sink != null) {
      final b = sink.bytesWritten;
      streamKbps = (b - _lastStreamBytes) * 8 / 1000;
      _lastStreamBytes = b;
      droppedFrames = sink.droppedFrames;
    }
    notifyListeners();
  }

  void _onStudioChanged() {
    final g = studio.micGain;
    if (g != _lastMicGain && (_encoderRunning || _lastMicGain < 0)) {
      _lastMicGain = g;
      if (encoderSupported) backend.setMicGain(g).catchError((_) {});
    }
  }

  void _updateWakelock() {
    final on = (isStreaming || isRecording) && studio.settings.keepScreenOn;
    WakelockPlus.toggle(enable: on).catchError((_) {});
  }

  void _error(String msg) {
    lastError = msg;
    notifyListeners();
  }

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    studio.removeListener(_onStudioChanged);
    _pumpTimer?.cancel();
    _statsTimer?.cancel();
    _packetSub?.cancel();
    _levelSub?.cancel();
    _errorSub?.cancel();
    super.dispose();
  }
}
