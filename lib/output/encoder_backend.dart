import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// One encoded packet from the native encoder.
class EncodedPacket {
  EncodedPacket({
    required this.isVideo,
    required this.isConfig,
    required this.isKeyframe,
    required this.ptsUs,
    required this.data,
  });

  final bool isVideo;

  /// Video: Annex-B SPS/PPS. Audio: AudioSpecificConfig.
  final bool isConfig;
  final bool isKeyframe;
  final int ptsUs;

  /// Video: Annex-B access unit. Audio: raw AAC frame.
  final Uint8List data;
}

class EncoderConfig {
  const EncoderConfig({
    required this.width,
    required this.height,
    required this.fps,
    required this.videoBitrateKbps,
    required this.audioBitrateKbps,
    required this.keyframeIntervalSec,
    this.sampleRate = 44100,
    this.channels = 1,
  });

  final int width, height, fps;
  final int videoBitrateKbps, audioBitrateKbps, keyframeIntervalSec;
  final int sampleRate, channels;

  Map<String, Object> toMap() => {
        'width': width,
        'height': height,
        'fps': fps,
        'videoBitrate': videoBitrateKbps * 1000,
        'audioBitrate': audioBitrateKbps * 1000,
        'keyframeInterval': keyframeIntervalSec,
        'sampleRate': sampleRate,
        'channels': channels,
      };
}

/// Mixed PCM (mic + app audio after mixer gain), for NDI audio.
class PcmChunk {
  const PcmChunk(this.samples, this.sampleRate, this.channels);
  final Float32List samples;
  final int sampleRate, channels;
}

class AudioLevel {
  const AudioLevel(this.rms, this.peak);
  final double rms, peak; // linear 0..1
}

/// State of the native screen capture (Android MediaProjection, iPad
/// ReplayKit broadcast extension).
class ScreenCaptureState {
  const ScreenCaptureState({this.active = false, this.width = 0, this.height = 0, this.error});

  final bool active;
  final int width, height;
  final String? error;
}

/// Where the native compositor draws the screen inside the output frame, in
/// output pixels. Rotation is in degrees around the rect center.
class ScreenPlacement {
  const ScreenPlacement({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotation = 0,
    this.fit = 'contain',
  });

  final double x, y, width, height, rotation;

  /// contain | cover | stretch
  final String fit;

  Map<String, Object> toMap() => {
        'x': x,
        'y': y,
        'w': width,
        'h': height,
        'rotation': rotation,
        'fit': fit,
      };

  @override
  bool operator ==(Object other) =>
      other is ScreenPlacement &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.rotation == rotation &&
      other.fit == fit;

  @override
  int get hashCode => Object.hash(x, y, width, height, rotation, fit);
}

/// Hardware encoder living on the native side (MediaCodec on Android,
/// VideoToolbox on iOS). The Dart side feeds it composited canvas frames and
/// receives encoded H.264 / AAC packets back.
abstract class EncoderBackend {
  Future<bool> isSupported();
  Stream<EncodedPacket> get packets;
  Stream<AudioLevel> get levels;
  Stream<String> get errors;

  Future<void> start(EncoderConfig config);
  Future<void> stop();
  Future<void> pushFrame(Uint8List rgba, int width, int height);
  Future<void> requestKeyframe();
  Future<void> setMicGain(double gain);

  /// Reports microphone [levels] while no output runs, for the mixer meter.
  /// Nothing is encoded; the encoder takes over while it runs.
  Future<void> setMetering(bool enabled);

  /// Microphone processing (see StudioController.micProcessing), applied
  /// natively to the stream, recordings, NDI and the meter.
  Future<void> setMicProcessing(Map<String, Object> config);

  /// Android: keep the app alive in the background while live, with a
  /// notification saying what's running ([text]); null when nothing is.
  Future<void> setLiveOutput(String? text);

  /// Media Sources whose audio is mixed into the output: {id, path, gain,
  /// playing, positionMs, loop}. Their levels come on [mediaLevels].
  Future<void> setMediaAudio(List<Map<String, Object>> sources);
  Stream<(String, AudioLevel)> get mediaLevels;

  /// Level of the sound the tablet plays (video sources, other apps), where
  /// the platform allows measuring it (Android).
  Future<void> setOutputMetering(bool enabled);
  Stream<AudioLevel> get outputLevels;

  /// Gain for other apps' audio captured along with the screen.
  Future<void> setScreenAudioGain(double gain);

  /// Delivers the mixed audio as [pcm] chunks while enabled (NDI output).
  Future<void> setPcmTap(bool enabled);
  Stream<PcmChunk> get pcm;

  /// Starts writing an MP4 natively. Returns the file path/uri.
  Future<String?> startMp4Recording();
  Future<String?> stopMp4Recording();

  // --- Screen capture ------------------------------------------------------

  Future<bool> isScreenCaptureSupported();
  Stream<ScreenCaptureState> get screenStates;

  /// Asks the user for permission and starts capturing the device screen.
  Future<void> startScreenCapture();
  Future<void> stopScreenCapture();

  /// Switches the encoder to native compositing: every output frame is
  /// [under] + live screen (at [placement]) + [over]. Layers are RGBA at
  /// [width]x[height]; a null layer keeps the previous one, [clearOver]
  /// removes the top layer. Calling [pushFrame] switches back to plain frames.
  Future<void> pushOverlays({
    Uint8List? under,
    Uint8List? over,
    bool clearOver = false,
    required int width,
    required int height,
    required ScreenPlacement placement,
  });
}

class MethodChannelEncoder implements EncoderBackend {
  MethodChannelEncoder();

  static const _method = MethodChannel('obs_tablet/encoder');
  static const _events = EventChannel('obs_tablet/encoder_events');

  StreamSubscription<dynamic>? _sub;
  final _packets = StreamController<EncodedPacket>.broadcast(sync: true);
  final _levels = StreamController<AudioLevel>.broadcast();
  final _outputLevels = StreamController<AudioLevel>.broadcast();
  final _mediaLevels = StreamController<(String, AudioLevel)>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _screen = StreamController<ScreenCaptureState>.broadcast();
  final _pcm = StreamController<PcmChunk>.broadcast(sync: true);

  bool? _supported;

  @override
  Stream<EncodedPacket> get packets => _packets.stream;
  @override
  Stream<AudioLevel> get levels => _levels.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  Stream<ScreenCaptureState> get screenStates => _screen.stream;
  @override
  Stream<PcmChunk> get pcm => _pcm.stream;

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    switch (e['type']) {
      case 'packet':
        _packets.add(EncodedPacket(
          isVideo: e['kind'] == 'video',
          isConfig: e['config'] == true,
          isKeyframe: e['key'] == true,
          ptsUs: (e['pts'] as num).toInt(),
          data: e['data'] as Uint8List,
        ));
      case 'level':
        final l = AudioLevel((e['rms'] as num).toDouble(), (e['peak'] as num).toDouble());
        switch (e['source']) {
          case 'output':
            _outputLevels.add(l);
          case 'media':
            _mediaLevels.add(('${e['id']}', l));
          default:
            _levels.add(l);
        }
      case 'error':
        _errors.add('${e['message']}');
      case 'pcm':
        final raw = e['data'] as Uint8List;
        // Copy to an aligned buffer before viewing it as floats.
        final aligned = Uint8List.fromList(raw);
        _pcm.add(PcmChunk(
          aligned.buffer.asFloat32List(0, aligned.length ~/ 4),
          (e['sampleRate'] as num).toInt(),
          (e['channels'] as num).toInt(),
        ));
      case 'screen':
        _screen.add(ScreenCaptureState(
          active: e['state'] == 'active',
          width: (e['width'] as num?)?.toInt() ?? 0,
          height: (e['height'] as num?)?.toInt() ?? 0,
          error: e['error'] as String?,
        ));
    }
  }

  @override
  Future<bool> isSupported() async {
    if (_supported != null) return _supported!;
    try {
      _supported = await _method.invokeMethod<bool>('isSupported') ?? false;
      // Only listen when a native side exists (avoids errors on web).
      if (_supported! && _sub == null) {
        _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (Object e) {
          _errors.add('$e');
        });
      }
    } on MissingPluginException {
      _supported = false;
    } catch (_) {
      _supported = false;
    }
    return _supported!;
  }

  @override
  Future<void> start(EncoderConfig config) => _method.invokeMethod('start', config.toMap());

  @override
  Future<void> stop() => _method.invokeMethod('stop');

  @override
  Future<void> pushFrame(Uint8List rgba, int width, int height) =>
      _method.invokeMethod('frame', {'data': rgba, 'width': width, 'height': height});

  @override
  Future<void> requestKeyframe() => _method.invokeMethod('requestKeyframe');

  @override
  Future<void> setMicGain(double gain) => _method.invokeMethod('setMicGain', {'gain': gain});

  @override
  Future<void> setMetering(bool enabled) => _method.invokeMethod('setMetering', {'enabled': enabled});

  @override
  Future<void> setMicProcessing(Map<String, Object> config) => _method.invokeMethod('setMicProcessing', config);

  @override
  Future<void> setLiveOutput(String? text) => _method.invokeMethod('setLiveOutput', {'text': text});

  @override
  Future<void> setMediaAudio(List<Map<String, Object>> sources) =>
      _method.invokeMethod('setMediaAudio', {'sources': sources});
  @override
  Stream<(String, AudioLevel)> get mediaLevels => _mediaLevels.stream;

  @override
  Future<void> setOutputMetering(bool enabled) => _method.invokeMethod('setOutputMetering', {'enabled': enabled});
  @override
  Stream<AudioLevel> get outputLevels => _outputLevels.stream;

  @override
  Future<void> setPcmTap(bool enabled) => _method.invokeMethod('setPcmTap', {'enabled': enabled});

  @override
  Future<void> setScreenAudioGain(double gain) => _method.invokeMethod('setScreenAudioGain', {'gain': gain});

  @override
  Future<String?> startMp4Recording() => _method.invokeMethod<String>('startRecording');

  @override
  Future<String?> stopMp4Recording() => _method.invokeMethod<String>('stopRecording');

  @override
  Future<bool> isScreenCaptureSupported() async {
    if (!await isSupported()) return false;
    try {
      return await _method.invokeMethod<bool>('isScreenCaptureSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> startScreenCapture() => _method.invokeMethod('startScreenCapture');

  @override
  Future<void> stopScreenCapture() => _method.invokeMethod('stopScreenCapture');

  @override
  Future<void> pushOverlays({
    Uint8List? under,
    Uint8List? over,
    bool clearOver = false,
    required int width,
    required int height,
    required ScreenPlacement placement,
  }) =>
      _method.invokeMethod('overlays', {
        'under': under,
        'over': over,
        'clearOver': clearOver,
        'width': width,
        'height': height,
        'placement': placement.toMap(),
      });

  void dispose() {
    _sub?.cancel();
  }
}
