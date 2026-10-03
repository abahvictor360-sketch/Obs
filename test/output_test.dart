import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/output/amf0.dart';
import 'package:obs_tablet/output/av_packager.dart';
import 'package:obs_tablet/output/codec_utils.dart';
import 'package:obs_tablet/output/encoder_backend.dart';
import 'package:obs_tablet/output/rtmp_chunk.dart';
import 'package:obs_tablet/output/rtmp_client.dart';

Uint8List _b(List<int> v) => Uint8List.fromList(v);

void main() {
  group('AMF0', () {
    test('round-trips command values', () {
      final values = <Object?>[
        'connect',
        1.0,
        {'app': 'live', 'tcUrl': 'rtmp://h/live', 'n': 3.0, 'ok': true},
        null,
        const Amf0EcmaArray({'width': 1280.0, 'stereo': false}),
      ];
      final decoded = Amf0.decodeAll(Amf0.encodeAll(values));
      expect(decoded[0], 'connect');
      expect(decoded[1], 1.0);
      expect(decoded[2], {'app': 'live', 'tcUrl': 'rtmp://h/live', 'n': 3.0, 'ok': true});
      expect(decoded[3], isNull);
      expect(decoded[4], {'width': 1280.0, 'stereo': false});
    });
  });

  group('RTMP chunks', () {
    for (final chunkSize in [128, 4096]) {
      test('writer output parses back (chunk size $chunkSize)', () {
        final w = RtmpChunkWriter()..chunkSize = chunkSize;
        final got = <RtmpMessage>[];
        final r = RtmpChunkReader(got.add)..chunkSize = chunkSize;
        final big = Uint8List.fromList(List.generate(10000, (i) => i & 0xFF));
        final msgs = [
          RtmpMessage(chunkStreamId: 3, typeId: 20, timestamp: 0, streamId: 0, payload: _b([1, 2, 3])),
          RtmpMessage(chunkStreamId: 6, typeId: 9, timestamp: 33, streamId: 1, payload: big),
          // Extended timestamp (> 0xFFFFFF ms, ~4.6 hours into a stream).
          RtmpMessage(chunkStreamId: 4, typeId: 8, timestamp: 0x1234567, streamId: 1, payload: big),
          RtmpMessage(chunkStreamId: 70, typeId: 8, timestamp: 5, streamId: 1, payload: _b([9])),
        ];
        final bytes = BytesBuilder();
        for (final m in msgs) {
          bytes.add(w.encode(m));
        }
        // Feed in awkward slices to exercise partial parsing.
        final all = bytes.takeBytes();
        for (var i = 0; i < all.length; i += 37) {
          r.add(all.sublist(i, i + 37 > all.length ? all.length : i + 37));
        }
        expect(got.length, msgs.length);
        for (var i = 0; i < msgs.length; i++) {
          expect(got[i].chunkStreamId, msgs[i].chunkStreamId);
          expect(got[i].typeId, msgs[i].typeId);
          expect(got[i].timestamp, msgs[i].timestamp);
          expect(got[i].streamId, msgs[i].streamId);
          expect(got[i].payload, msgs[i].payload);
        }
      });
    }

    test('reader handles type 1/2/3 headers with deltas', () {
      final got = <RtmpMessage>[];
      final r = RtmpChunkReader(got.add);
      r.add([
        // fmt0 csid 4: ts=100 len=1 type=8 sid=1
        0x04, 0, 0, 100, 0, 0, 1, 8, 1, 0, 0, 0, 0xAA,
        // fmt1 csid 4: delta=20 len=2 type=8
        0x44, 0, 0, 20, 0, 0, 2, 8, 0xBB, 0xCC,
        // fmt2 csid 4: delta=30 (len 2 reused)
        0x84, 0, 0, 30, 0xDD, 0xEE,
        // fmt3 csid 4: same delta 30
        0xC4, 0x11, 0x22,
      ]);
      expect(got.map((m) => m.timestamp), [100, 120, 150, 180]);
      expect(got.last.payload, [0x11, 0x22]);
      expect(got.every((m) => m.streamId == 1), isTrue);
    });
  });

  group('RtmpUrl', () {
    test('parses common ingest URLs', () {
      var u = RtmpUrl.parse('rtmp://live.twitch.tv/app/live_123_abc');
      expect((u.secure, u.host, u.port, u.app, u.streamKey), (false, 'live.twitch.tv', 1935, 'app', 'live_123_abc'));
      u = RtmpUrl.parse('rtmps://a.rtmps.youtube.com:443/live2/xxxx-yyyy');
      expect((u.secure, u.port, u.app, u.streamKey), (true, 443, 'live2', 'xxxx-yyyy'));
      expect(u.tcUrl, 'rtmps://a.rtmps.youtube.com:443/live2');
      u = RtmpUrl.parse('rtmps://live-api-s.facebook.com:443/rtmp/FB-123?s_bl=1&a=b/c');
      expect((u.app, u.streamKey), ('rtmp', 'FB-123?s_bl=1&a=b/c'));
      u = RtmpUrl.parse('rtmp://10.0.0.5:1936/live/sub/key');
      expect((u.port, u.app, u.streamKey), (1936, 'live/sub', 'key'));
    });

    test('rejects URLs without a key or scheme', () {
      expect(() => RtmpUrl.parse('rtmp://host/app'), throwsFormatException);
      expect(() => RtmpUrl.parse('http://host/app/key'), throwsFormatException);
    });
  });

  group('codec utils', () {
    test('splits Annex-B with 3 and 4 byte start codes', () {
      final nals = H264.splitAnnexB(_b([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5]));
      expect(nals.map((n) => n.toList()), [
        [0x67, 1, 2],
        [0x68, 3],
        [0x65, 4, 5],
      ]);
    });

    test('AudioSpecificConfig for 44.1 kHz mono / 48 kHz stereo', () {
      expect(Aac.audioSpecificConfig(sampleRate: 44100, channels: 1), [0x12, 0x08]);
      expect(Aac.audioSpecificConfig(sampleRate: 48000, channels: 2), [0x11, 0x90]);
      expect(Aac.parseAudioSpecificConfig(_b([0x12, 0x10])), (44100, 2));
    });
  });

  group('AvPackager', () {
    final sps = [0x67, 0x42, 0xC0, 0x1E, 0xAB];
    final pps = [0x68, 0xCE, 0x38, 0x80];
    EncodedPacket v(List<int> annexB, int ptsUs, {bool config = false, bool key = false}) => EncodedPacket(
          isVideo: true, isConfig: config, isKeyframe: key, ptsUs: ptsUs, data: _b(annexB));
    EncodedPacket a(List<int> data, int ptsUs, {bool config = false}) =>
        EncodedPacket(isVideo: false, isConfig: config, isKeyframe: false, ptsUs: ptsUs, data: _b(data));

    test('waits for config + keyframe, rebases timestamps, strips parameter sets', () {
      final t = _RecordingTarget();
      final p = AvPackager(t, metadataBuilder: () => {'w': 1});
      p.push(a([0x12, 0x08], 0, config: true));
      p.push(v([0, 0, 0, 1, 0x41, 9], 900000)); // P-frame before start: dropped
      p.push(a([1, 2], 950000)); // audio before start: dropped
      p.push(v([0, 0, 0, 1, ...sps, 0, 0, 0, 1, ...pps], 0, config: true));
      p.push(v([0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x65, 7, 7], 1000000, key: true));
      p.push(a([3, 4], 1010000));
      p.push(v([0, 0, 0, 1, 0x41, 8], 1033333));

      expect(t.log, [
        'meta',
        'vconfig',
        'aconfig',
        'video 0 key [0, 0, 0, 3, 101, 7, 7]',
        'audio 10',
        'video 33 delta [0, 0, 0, 2, 65, 8]',
      ]);
      expect(p.skippedBeforeStart, 1);
    });

    test('in-band SPS/PPS before an IDR also works as config', () {
      final t = _RecordingTarget();
      final p = AvPackager(t, metadataBuilder: () => {});
      p.push(v([0, 0, 0, 1, ...sps, 0, 0, 0, 1, ...pps, 0, 0, 0, 1, 0x65, 1], 5000, key: true));
      expect(t.log, ['meta', 'vconfig', 'video 0 key [0, 0, 0, 2, 101, 1]']);
    });
  });
}

class _RecordingTarget implements FlvTarget {
  final log = <String>[];

  @override
  void metadata(Map<String, Object?> meta) => log.add('meta');

  @override
  void videoConfig(Uint8List rec) => log.add('vconfig');

  @override
  void audioConfig(Uint8List asc) => log.add('aconfig');

  @override
  bool video(Uint8List avcc, int ms, bool key) {
    log.add('video $ms ${key ? 'key' : 'delta'} ${avcc.toList()}');
    return true;
  }

  @override
  void audio(Uint8List frame, int ms) => log.add('audio $ms');
}
