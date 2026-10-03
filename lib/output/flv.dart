// FLV tag bodies. RTMP video/audio messages carry exactly these bodies, and
// an .flv file is just a header followed by tags with these bodies.

import 'dart:typed_data';

import 'amf0.dart';

class Flv {
  static const tagAudio = 8;
  static const tagVideo = 9;
  static const tagScript = 18;

  /// Video tag body containing an AVCDecoderConfigurationRecord.
  static Uint8List avcSequenceHeader(Uint8List decoderConfigRecord) {
    final b = BytesBuilder(copy: false);
    b.add(const [0x17, 0x00, 0, 0, 0]); // keyframe | AVC, seq header, cts 0
    b.add(decoderConfigRecord);
    return b.takeBytes();
  }

  /// Video tag body for AVCC-formatted NAL units.
  static Uint8List avcNalu(Uint8List avcc, {required bool keyframe, int compositionTimeMs = 0}) {
    final cts = compositionTimeMs & 0xFFFFFF;
    final b = BytesBuilder(copy: false);
    b.add([
      keyframe ? 0x17 : 0x27,
      0x01,
      (cts >> 16) & 0xFF,
      (cts >> 8) & 0xFF,
      cts & 0xFF,
    ]);
    b.add(avcc);
    return b.takeBytes();
  }

  /// SoundFormat=10 (AAC), rate=3 (44kHz, always for AAC), 16-bit, stereo flag
  /// (FLV spec: AAC always signals stereo; the real layout is in the ASC).
  static const _aacHeader = 0xAF;

  static Uint8List aacSequenceHeader(Uint8List audioSpecificConfig) {
    final b = BytesBuilder(copy: false);
    b.add(const [_aacHeader, 0x00]);
    b.add(audioSpecificConfig);
    return b.takeBytes();
  }

  static Uint8List aacRaw(Uint8List frame) {
    final b = BytesBuilder(copy: false);
    b.add(const [_aacHeader, 0x01]);
    b.add(frame);
    return b.takeBytes();
  }

  static Map<String, Object?> metadata({
    required int width,
    required int height,
    required int fps,
    required int videoKbps,
    required int audioKbps,
    required int sampleRate,
    required int channels,
  }) =>
      {
        'duration': 0.0,
        'width': width.toDouble(),
        'height': height.toDouble(),
        'videodatarate': videoKbps.toDouble(),
        'framerate': fps.toDouble(),
        'videocodecid': 7.0,
        'audiodatarate': audioKbps.toDouble(),
        'audiosamplerate': sampleRate.toDouble(),
        'audiosamplesize': 16.0,
        'stereo': channels > 1,
        'audiocodecid': 10.0,
        'encoder': 'OBS Tablet',
        'filesize': 0.0,
      };

  /// Script tag body for an .flv file (onMetaData, ECMA array).
  static Uint8List onMetaDataFileBody(Map<String, Object?> meta) =>
      Amf0.encodeAll(['onMetaData', Amf0EcmaArray(meta)]);

  /// RTMP data message body (@setDataFrame onMetaData).
  static Uint8List setDataFrameBody(Map<String, Object?> meta) =>
      Amf0.encodeAll(['@setDataFrame', 'onMetaData', Amf0EcmaArray(meta)]);

  /// FLV file header + PreviousTagSize0.
  static Uint8List fileHeader({bool audio = true, bool video = true}) => Uint8List.fromList([
        0x46, 0x4C, 0x56, 0x01, //
        (audio ? 0x04 : 0) | (video ? 0x01 : 0),
        0, 0, 0, 9,
        0, 0, 0, 0,
      ]);

  /// A complete FLV file tag including trailing PreviousTagSize.
  static Uint8List fileTag(int type, int timestampMs, Uint8List body) {
    final size = body.length;
    final ts = timestampMs & 0xFFFFFFFF;
    final b = BytesBuilder(copy: false);
    b.add([
      type,
      (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF,
      (ts >> 16) & 0xFF, (ts >> 8) & 0xFF, ts & 0xFF, (ts >> 24) & 0xFF,
      0, 0, 0, // stream id
    ]);
    b.add(body);
    final total = size + 11;
    b.add([(total >> 24) & 0xFF, (total >> 16) & 0xFF, (total >> 8) & 0xFF, total & 0xFF]);
    return b.takeBytes();
  }
}
