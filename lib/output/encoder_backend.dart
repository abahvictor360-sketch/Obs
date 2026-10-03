import 'dart:async';
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

class AudioLevel {
  const AudioLevel(this.rms, this.peak);
  final double rms, peak; // linear 0..1
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

  /// Starts writing an MP4 natively. Returns the file path/uri.
  Future<String?> startMp4Recording();
  Future<String?> stopMp4Recording();
}

class MethodChannelEncoder implements EncoderBackend {
  MethodChannelEncoder() {
    _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (Object e) {
      _errors.add('$e');
    });
  }

  static const _method = MethodChannel('obs_tablet/encoder');
  static const _events = EventChannel('obs_tablet/encoder_events');

  StreamSubscription<dynamic>? _sub;
  final _packets = StreamController<EncodedPacket>.broadcast(sync: true);
  final _levels = StreamController<AudioLevel>.broadcast();
  final _errors = StreamController<String>.broadcast();

  bool? _supported;

  @override
  Stream<EncodedPacket> get packets => _packets.stream;
  @override
  Stream<AudioLevel> get levels => _levels.stream;
  @override
  Stream<String> get errors => _errors.stream;

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
        _levels.add(AudioLevel((e['rms'] as num).toDouble(), (e['peak'] as num).toDouble()));
      case 'error':
        _errors.add('${e['message']}');
    }
  }

  @override
  Future<bool> isSupported() async {
    if (_supported != null) return _supported!;
    try {
      _supported = await _method.invokeMethod<bool>('isSupported') ?? false;
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
  Future<String?> startMp4Recording() => _method.invokeMethod<String>('startRecording');

  @override
  Future<String?> stopMp4Recording() => _method.invokeMethod<String>('stopRecording');

  void dispose() {
    _sub?.cancel();
  }
}
