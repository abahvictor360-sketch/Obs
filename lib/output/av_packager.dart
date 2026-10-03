import 'dart:typed_data';

import 'codec_utils.dart';
import 'encoder_backend.dart';

/// Destination for FLV-style packets (an RTMP connection or an .flv file).
abstract class FlvTarget {
  void metadata(Map<String, Object?> meta);
  void videoConfig(Uint8List decoderConfigRecord);
  void audioConfig(Uint8List asc);

  /// Returns false if the frame was dropped (congestion).
  bool video(Uint8List avcc, int timestampMs, bool keyframe);
  void audio(Uint8List aacFrame, int timestampMs);
}

/// Turns raw encoder packets into a valid FLV packet sequence for one output:
/// waits for codec config and the first keyframe, rebases timestamps to 0,
/// strips in-band SPS/PPS/AUD NAL units and converts Annex-B to AVCC.
///
/// Each output (stream, recording) gets its own packager so they can start
/// and stop independently while sharing one encoder, just like OBS.
class AvPackager {
  AvPackager(this.target, {required this.metadataBuilder});

  final FlvTarget target;
  final Map<String, Object?> Function() metadataBuilder;

  Uint8List? _avcConfig;
  Uint8List? _asc;
  bool _started = false;
  int _basePtsUs = 0;
  int _lastVideoMs = -1;
  int _lastAudioMs = -1;

  bool get started => _started;

  /// Packets this output received but couldn't use yet (waiting on keyframe).
  int skippedBeforeStart = 0;

  void push(EncodedPacket p) {
    if (p.isVideo) {
      _video(p);
    } else {
      _audio(p);
    }
  }

  void _video(EncodedPacket p) {
    final nals = H264.splitAnnexB(p.data);
    Uint8List? sps, pps;
    final frameNals = <Uint8List>[];
    var hasIdr = false;
    for (final n in nals) {
      switch (H264.nalType(n)) {
        case H264.nalSps:
          sps = n;
        case H264.nalPps:
          pps = n;
        case H264.nalAud:
          break;
        case H264.nalIdr:
          hasIdr = true;
          frameNals.add(n);
        default:
          frameNals.add(n);
      }
    }
    if (sps != null && pps != null) {
      final rec = H264.decoderConfigRecord(sps, pps);
      final changed = _avcConfig == null || !_bytesEqual(_avcConfig!, rec);
      _avcConfig = rec;
      if (_started && changed) target.videoConfig(rec);
    }
    if (p.isConfig || frameNals.isEmpty) return;

    final key = p.isKeyframe || hasIdr;
    if (!_started) {
      if (!key || _avcConfig == null) {
        skippedBeforeStart++;
        return;
      }
      _started = true;
      _basePtsUs = p.ptsUs;
      target.metadata(metadataBuilder());
      target.videoConfig(_avcConfig!);
      if (_asc != null) target.audioConfig(_asc!);
    }
    var ms = ((p.ptsUs - _basePtsUs) / 1000).round();
    if (ms <= _lastVideoMs) ms = _lastVideoMs + 1; // keep strictly increasing
    _lastVideoMs = ms;
    target.video(H264.toAvcc(frameNals), ms, key);
  }

  void _audio(EncodedPacket p) {
    if (p.isConfig) {
      final changed = _asc == null || !_bytesEqual(_asc!, p.data);
      _asc = Uint8List.fromList(p.data);
      if (_started && changed) target.audioConfig(_asc!);
      return;
    }
    if (!_started || _asc == null) return;
    if (p.ptsUs < _basePtsUs) return;
    var ms = ((p.ptsUs - _basePtsUs) / 1000).round();
    if (ms < _lastAudioMs) ms = _lastAudioMs;
    _lastAudioMs = ms;
    target.audio(p.data, ms);
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
