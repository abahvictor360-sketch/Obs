import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/models.dart';
import '../core/studio_controller.dart';
import 'av_packager.dart';
import '../ndi/ndi_output.dart';
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
class OutputEngine extends ChangeNotifier with WidgetsBindingObserver {
  OutputEngine({required this.studio, EncoderBackend? backend, NdiOutputSink? ndi})
      : backend = backend ?? MethodChannelEncoder() {
    this.ndi = ndi ?? createNdiOutput(onChanged: notifyListeners);
    studio.addListener(_onStudioChanged);
  }

  final StudioController studio;
  final EncoderBackend backend;

  /// NDI® program output (built-in "NDI Output" plugin).
  late final NdiOutputSink ndi;
  bool ndiActive = false;
  String? ndiError;
  String? ndiName;
  String? ndiGroups;
  StreamSubscription<PcmChunk>? _pcmSub;

  /// Wraps the program canvas; frames are captured from it.
  final GlobalKey programKey = GlobalKey(debugLabel: 'program');

  /// When the program scene contains a Screen Capture source, the program
  /// view is split into the layers below and above it. The native side
  /// composites under + live screen + over, which keeps working while the
  /// user is in another app.
  final GlobalKey underKey = GlobalKey(debugLabel: 'under-screen');
  final GlobalKey overKey = GlobalKey(debugLabel: 'over-screen');

  /// Multiview for a connected screen (see render/multiview.dart).
  final GlobalKey multiviewKey = GlobalKey(debugLabel: 'multiview');

  ScreenCaptureState screenState = const ScreenCaptureState();
  bool screenCaptureSupported = false;

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

  /// What the tablet is playing: video sources and other apps (Android).
  AudioLevel outputLevel = const AudioLevel(0, 0);
  int reconnectAttempt = 0;

  bool? _supported;
  bool get encoderSupported => _supported ?? false;
  bool get initialized => _supported != null;

  EncoderConfig? _config;

  /// The settings the running encoder uses (null when it's off).
  EncoderConfig? get encoderConfig => _encoderRunning ? _config : null;
  bool _encoderRunning = false;
  Timer? _pumpTimer;
  Timer? _statsTimer;
  bool _capturing = false;
  StreamSubscription<EncodedPacket>? _packetSub;
  StreamSubscription<AudioLevel>? _levelSub;
  StreamSubscription<AudioLevel>? _outputLevelSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<ScreenCaptureState>? _screenSub;

  bool _appResumed = true;
  bool _compositing = false;
  bool _layersDirty = true;
  int _tick = 0;
  DateTime _lastStaticGrab = DateTime(0);
  ScreenPlacement? _lastPlacement;

  PacketSink? _streamSink;
  AvPackager? _streamPackager;
  PacketSink? _recordSink;
  AvPackager? _recordPackager;
  bool _nativeMp4 = false;

  int _lastStreamBytes = 0;
  int _framesThisSecond = 0;
  double _lastMicGain = -1;
  bool _metering = false;
  String? _lastMicProcessing;
  bool _outputMetering = false;
  double _lastScreenGain = -1;

  /// Called with every program frame sent to the encoder (RGBA), so the
  /// connected screen can reuse it instead of capturing again.
  void Function(Uint8List rgba, int width, int height)? programFrameTap;

  /// True while the encoder pump captures the whole program each frame
  /// (not in screen-capture overlay mode, app in the foreground).
  bool get pumpingProgramFrames => _encoderRunning && !_compositing && _appResumed;

  /// A connected screen is showing the program: keep the tablet awake.
  bool _externalPresenting = false;
  set externalPresenting(bool v) {
    if (v == _externalPresenting) return;
    _externalPresenting = v;
    _updateWakelock();
  }

  bool get isStreaming => streamStatus != OutputStatus.idle;
  int get ndiConnections => ndi.connections;
  bool get isRecording => recordStatus != OutputStatus.idle;

  Future<void> init() async {
    _supported = await backend.isSupported() && sinksSupported;
    _levelSub = backend.levels.listen((l) {
      micLevel = l;
      notifyListeners();
    });
    _outputLevelSub = backend.outputLevels.listen((l) {
      outputLevel = l;
      notifyListeners();
    });
    _errorSub = backend.errors.listen((e) {
      lastError = e;
      notifyListeners();
    });
    _screenSub = backend.screenStates.listen((st) {
      screenState = st;
      _layersDirty = true;
      notifyListeners();
    });
    screenCaptureSupported = await backend.isScreenCaptureSupported();
    WidgetsBinding.instance.addObserver(this);
    _onStudioChanged();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Flutter doesn't render in the background, so stop grabbing frames;
    // the native side keeps compositing the screen with the last overlays
    // (or repeats the last frame).
    // Inactive (notification shade, app switcher, Control Center) is still
    // on screen and still renders: keep going.
    _appResumed = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (_appResumed) _layersDirty = true;
    _updateMetering();
  }

  /// Keeps the Mic/Aux meter live (like OBS) whenever the app is in front and
  /// the collection has a microphone, not only while streaming or recording.
  void _updateMetering() {
    final types = {for (final s in studio.collection.sources) s.type};
    final wantOut = encoderSupported &&
        _appResumed &&
        (types.contains(SourceType.media) || types.contains(SourceType.audioOutput) || types.contains(SourceType.screen));
    if (wantOut != _outputMetering) {
      _outputMetering = wantOut;
      if (!wantOut) outputLevel = const AudioLevel(0, 0);
      backend.setOutputMetering(wantOut).catchError((_) {});
    }

    final want = encoderSupported && _appResumed && types.contains(SourceType.audioInput);
    if (want == _metering) return;
    _metering = want;
    if (!want && !_encoderRunning) {
      micLevel = const AudioLevel(0, 0);
      notifyListeners();
    }
    backend.setMetering(want).catchError((_) {});
  }

  /// Test hooks: run the encoder and frame pump steps without real outputs.
  @visibleForTesting
  Future<void> debugStartEncoder() => _ensureEncoder();

  @visibleForTesting
  Future<void> debugCaptureFrame() => _captureFrame();

  // ---------------------------------------------------------------------------
  // Screen capture

  Future<void> startScreenCapture() async {
    try {
      await backend.startScreenCapture();
    } catch (e) {
      screenState = ScreenCaptureState(error: 'Could not start screen capture: $e');
      notifyListeners();
    }
  }

  Future<void> stopScreenCapture() async {
    try {
      await backend.stopScreenCapture();
    } catch (_) {}
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
    final gen = ++_streamGen;
    notifyListeners();
    try {
      await _ensureEncoder();
      if (gen != _streamGen) return; // stopped while starting
      if (!await _openStreamSink(url, gen)) return;
      streamStatus = OutputStatus.active;
      streamStartedAt = DateTime.now();
      droppedFrames = 0;
      reconnectAttempt = 0;
      await backend.requestKeyframe();
      if (studio.settings.autoRecordWithStream && !isRecording) {
        _autoRecording = true;
        unawaited(startRecording());
      }
    } catch (e) {
      if (gen != _streamGen) return;
      _streamSink = null;
      _streamPackager = null;
      streamStatus = OutputStatus.idle;
      _error('Could not start streaming: $e');
      await _maybeStopEncoder();
    }
    _updateWakelock();
    notifyListeners();
  }

  /// Bumped by every start and stop, so a connect that finishes after the
  /// user pressed Stop is closed instead of going live.
  int _streamGen = 0;

  /// The recording was started by "Automatically record when streaming".
  bool _autoRecording = false;

  /// Opens the RTMP connection. False (and the socket closed) if the stream
  /// was stopped meanwhile.
  Future<bool> _openStreamSink(String url, int gen) async {
    final sink = createRtmpSink(url);
    sink.onError = (e) => _onStreamLost(e);
    await sink.open();
    if (gen != _streamGen) {
      try {
        await sink.close();
      } catch (_) {}
      return false;
    }
    _lastStreamBytes = 0;
    _streamSink = sink;
    _streamPackager = _newPackager(sink);
    return true;
  }

  /// A packager for a new output, primed with the encoder's current video
  /// and audio configuration (sent only once when the encoder starts), so an
  /// output started or reconnected while the encoder runs gets them too.
  AvPackager _newPackager(FlvTarget target) {
    final p = AvPackager(target, metadataBuilder: _metadata);
    if (_videoConfig case final v?) p.push(v);
    if (_audioConfig case final a?) p.push(a);
    return p;
  }

  EncodedPacket? _videoConfig;
  EncodedPacket? _audioConfig;

  Future<void> _onStreamLost(Object error) async {
    if (streamStatus != OutputStatus.active) return;
    streamStatus = OutputStatus.reconnecting;
    _streamSink = null;
    _streamPackager = null;
    lastError = 'Disconnected: $error';
    final gen = _streamGen;
    notifyListeners();
    // Auto-reconnect like OBS: up to 10 tries, 5 s apart.
    for (reconnectAttempt = 1; reconnectAttempt <= 10; reconnectAttempt++) {
      notifyListeners();
      await Future<void>.delayed(const Duration(seconds: 5));
      if (streamStatus != OutputStatus.reconnecting || gen != _streamGen) return; // user stopped
      try {
        if (!await _openStreamSink(studio.settings.publishUrl, gen)) return;
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
    _streamGen++;
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
    if (_autoRecording && isRecording) await stopRecording();
    _autoRecording = false;
    await _maybeStopEncoder();
    _updateWakelock();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // NDI output

  /// Starts sending the program over NDI. Runs the capture pipeline like a
  /// stream or recording would (the hardware encoder idles if nothing else
  /// is using it).
  Future<void> startNdi({required String name, String? groups}) async {
    if (ndiActive && name == ndiName && groups == ndiGroups) return;
    if (ndiActive) await stopNdi();
    ndiError = null;
    if (!ndi.available) {
      ndiError = ndi.unavailableReason;
      notifyListeners();
      return;
    }
    try {
      await ndi.start(name: name, groups: groups);
      ndiActive = true;
      ndiName = name;
      ndiGroups = groups;
      if (encoderSupported) {
        await _ensureEncoder();
        await backend.setPcmTap(true);
        _pcmSub ??= backend.pcm.listen((c) {
          if (ndiActive) ndi.sendAudio(c.samples, c.sampleRate, c.channels);
        });
      }
    } catch (e) {
      ndiActive = false;
      ndiError = 'NDI output failed: $e';
    }
    _updateWakelock();
    notifyListeners();
  }

  Future<void> stopNdi() async {
    if (!ndiActive) return;
    ndiActive = false;
    ndiName = null;
    await _pcmSub?.cancel();
    _pcmSub = null;
    try {
      await backend.setPcmTap(false);
    } catch (_) {}
    await ndi.stop();
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
        _recordPackager = _newPackager(sink);
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
        lastRecordingPath = path;
        if (path == null) _error('Recording failed: nothing was recorded.');
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

  Future<void>? _encoderStarting;
  Timer? _reconfigureTimer;

  EncoderConfig _wantedConfig() {
    final s = studio.settings;
    // Hardware encoders want even dimensions.
    return EncoderConfig(
      width: s.outputWidth & ~1,
      height: s.outputHeight & ~1,
      fps: s.fps,
      videoBitrateKbps: s.videoBitrateKbps,
      audioBitrateKbps: s.audioBitrateKbps,
      keyframeIntervalSec: s.keyframeIntervalSec,
    );
  }

  static bool _sameConfig(EncoderConfig a, EncoderConfig b) =>
      a.width == b.width &&
      a.height == b.height &&
      a.fps == b.fps &&
      a.videoBitrateKbps == b.videoBitrateKbps &&
      a.audioBitrateKbps == b.audioBitrateKbps &&
      a.keyframeIntervalSec == b.keyframeIntervalSec;

  /// Video/output settings changed while only NDI keeps the encoder running:
  /// restart it so they apply (while streaming or recording they apply next
  /// time, and Settings says so).
  void _maybeApplyEncoderSettings() {
    final c = _config;
    if (!_encoderRunning || c == null || isStreaming || isRecording) return;
    if (_sameConfig(c, _wantedConfig())) return;
    _reconfigureTimer?.cancel();
    _reconfigureTimer = Timer(const Duration(milliseconds: 600), () async {
      if (!_encoderRunning || isStreaming || isRecording) return;
      if (_sameConfig(_config!, _wantedConfig())) return;
      await _stopEncoderNow();
      try {
        await _ensureEncoder();
        if (ndiActive) await backend.setPcmTap(true);
      } catch (e) {
        _error('Could not apply the new video settings: $e');
      }
    });
  }

  /// Settings that need a restart are in use by a live output.
  bool get encoderSettingsLocked => _encoderRunning && (isStreaming || isRecording);

  /// Starts the shared encoder once, even if several outputs ask at the same
  /// time; a failed start leaves nothing behind so it can be retried.
  Future<void> _ensureEncoder() {
    if (_encoderRunning) return Future.value();
    return _encoderStarting ??= _startEncoder().whenComplete(() => _encoderStarting = null);
  }

  Future<void> _startEncoder() async {
    final config = _wantedConfig();
    _config = config;
    _videoConfig = null;
    _audioConfig = null;
    _packetSub = backend.packets.listen(_onPacket);
    try {
      await backend.start(config);
    } catch (_) {
      await _packetSub?.cancel();
      _packetSub = null;
      try {
        await backend.stop();
      } catch (_) {}
      rethrow;
    }
    _lastMicGain = -1;
    _lastScreenGain = -1;
    _onStudioChanged();
    _encoderRunning = true;
    _capturing = false;
    _compositing = false;
    _layersDirty = true;
    _lastPlacement = null;
    renderedFrames = 0;
    laggedFrames = 0;
    _pumpTimer = Timer.periodic(Duration(microseconds: 1000000 ~/ config.fps), (_) => _captureFrame());
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickStats());
  }

  Future<void> _maybeStopEncoder() async {
    if (!_encoderRunning || isStreaming || isRecording || ndiActive) return;
    await _stopEncoderNow();
  }

  Future<void> _stopEncoderNow() async {
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
    if (p.isConfig) {
      if (p.isVideo) {
        _videoConfig = p;
      } else {
        _audioConfig = p;
      }
    }
    _streamPackager?.push(p);
    _recordPackager?.push(p);
  }

  Future<void> _captureFrame() async {
    if (_capturing) {
      laggedFrames++;
      return;
    }
    if (!_appResumed) return;
    _tick++;
    if (underKey.currentContext != null) {
      _capturing = true;
      try {
        await _captureLayers();
      } catch (e) {
        debugPrint('Overlay capture failed: $e');
      } finally {
        _capturing = false;
      }
      return;
    }
    if (_compositing) {
      _compositing = false;
      _lastPlacement = null;
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
        final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        if (ndiActive) ndi.sendVideo(rgba, w, h, config.fps);
        programFrameTap?.call(rgba, w, h);
        await backend.pushFrame(rgba, w, h);
        renderedFrames++;
        _framesThisSecond++;
      }
    } catch (e) {
      debugPrint('Frame capture failed: $e');
    } finally {
      _capturing = false;
    }
  }

  static RenderRepaintBoundary? _boundary(GlobalKey key) {
    final ro = key.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.attached || ro.size.isEmpty) return null;
    return ro;
  }

  Future<(Uint8List, int, int)?> _grab(RenderRepaintBoundary ro, double pixelRatio) async {
    final image = await ro.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = image.width, h = image.height;
    image.dispose();
    if (data == null) return null;
    return (data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), w, h);
  }

  /// Overlay mode: grab the layers under/over the screen source. Layers with
  /// live content (camera, video) refresh at ~15 fps; static layers only when
  /// the scene changes (or once a second as a safety net), which keeps the
  /// GPU readback cost low while a game is being streamed.
  Future<void> _captureLayers() async {
    final config = _config;
    final under = _boundary(underKey);
    if (config == null || under == null) return;
    final scene = studio.programScene;
    final idx = studio.screenItemIndex(scene);
    if (idx < 0) return;

    final cw = studio.settings.canvasWidth.toDouble();
    final k = config.width / cw;
    final t = scene.items[idx].transform;
    final placement = ScreenPlacement(
      x: t.x * k,
      y: t.y * k,
      width: t.width * k,
      height: t.height * k,
      rotation: t.rotation,
      fit: switch (t.fit) {
        FitMode.cover => 'cover',
        FitMode.stretch => 'stretch',
        FitMode.contain => 'contain',
      },
    );

    bool isLive(int from, int to) {
      for (final it in scene.items.sublist(from, to)) {
        if (!it.visible) continue;
        final src = studio.sourceById(it.sourceId);
        if (src == null) continue;
        // Anything that moves: cameras, video, capture cards, network
        // feeds, web pages, slide shows, plugins, scrolling text.
        const still = {SourceType.text, SourceType.color, SourceType.image};
        if (!still.contains(src.type)) return true;
        if (src.filters.any((f) => f.enabled && f.kind == FilterKind.scroll)) return true;
      }
      return false;
    }

    final now = DateTime.now();
    final staticDue = _layersDirty || !_compositing || now.difference(_lastStaticGrab).inMilliseconds > 1000;
    final liveDue = _tick % math.max(1, (config.fps / 15).round()) == 0;
    final grabUnder = staticDue || (liveDue && isLive(0, idx));
    final over = _boundary(overKey);
    final grabOver = over != null && (staticDue || (liveDue && isLive(idx + 1, scene.items.length)));

    if (!grabUnder && !grabOver && placement == _lastPlacement) {
      _framesThisSecond++; // native keeps producing frames on its own
      return;
    }
    final ratio = config.width / under.size.width;
    final u = grabUnder ? await _grab(under, ratio) : null;
    final o = grabOver ? await _grab(over, ratio) : null;
    if (!_encoderRunning) return;
    final w = u?.$2 ?? o?.$2 ?? config.width;
    final h = u?.$3 ?? o?.$3 ?? config.height;
    await backend.pushOverlays(
      under: u?.$1,
      over: o?.$1,
      clearOver: over == null,
      width: w,
      height: h,
      placement: placement,
    );
    if (staticDue) {
      _lastStaticGrab = now;
      _layersDirty = false;
    }
    _compositing = true;
    _lastPlacement = placement;
    renderedFrames++;
    _framesThisSecond++;
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
    _layersDirty = true;
    final g = studio.micGain;
    final mp = studio.micProcessing;
    final mpKey = jsonEncode(mp);
    if (mpKey != _lastMicProcessing && encoderSupported) {
      _lastMicProcessing = mpKey;
      backend.setMicProcessing(mp).catchError((_) {});
    }
    // Also while idle: the meter shows the level after the fader, like OBS.
    if (g != _lastMicGain) {
      _lastMicGain = g;
      if (encoderSupported) backend.setMicGain(g).catchError((_) {});
    }
    final sg = studio.screenAudioGain;
    if (sg != _lastScreenGain && (_encoderRunning || _lastScreenGain < 0)) {
      _lastScreenGain = sg;
      if (encoderSupported) backend.setScreenAudioGain(sg).catchError((_) {});
    }
    _updateMetering();
    _updateWakelock();
    _maybeApplyEncoderSettings();
  }

  String? _liveText;

  void _updateWakelock() {
    final parts = [
      if (isStreaming) 'Streaming',
      if (isRecording) 'Recording',
      if (ndiActive) 'NDI',
    ];
    final text = parts.isEmpty ? null : parts.join(' · ');
    if (text != _liveText && encoderSupported) {
      _liveText = text;
      backend.setLiveOutput(text).catchError((_) {});
    }
    final on = (isStreaming || isRecording || ndiActive || _externalPresenting) && studio.settings.keepScreenOn;
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
    _reconfigureTimer?.cancel();
    _pumpTimer?.cancel();
    _statsTimer?.cancel();
    _packetSub?.cancel();
    _levelSub?.cancel();
    _outputLevelSub?.cancel();
    _errorSub?.cancel();
    _screenSub?.cancel();
    _pcmSub?.cancel();
    if (ndiActive) ndi.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
