// End-to-end test of the Dart RTMP publisher against a real RTMP server
// (ffmpeg in `-listen 1` mode). Skipped automatically if ffmpeg is missing.

@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/output/codec_utils.dart';
import 'package:obs_tablet/output/flv.dart';
import 'package:obs_tablet/output/rtmp_client.dart';

bool _hasFfmpeg() {
  try {
    return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Groups Annex-B NAL units into access units using AUD delimiters.
List<List<Uint8List>> _accessUnits(Uint8List annexB) {
  final aus = <List<Uint8List>>[];
  for (final nal in H264.splitAnnexB(annexB)) {
    if (H264.nalType(nal) == H264.nalAud) {
      aus.add([]);
    } else if (aus.isNotEmpty) {
      aus.last.add(nal);
    }
  }
  return aus.where((a) => a.isNotEmpty).toList();
}

void main() {
  final skip = _hasFfmpeg() ? false : 'ffmpeg not installed';

  test('publishes H.264 + AAC that an RTMP server can record', () async {
    final dir = await Directory.systemTemp.createTemp('rtmp_test');
    final h264 = File('${dir.path}/in.h264');
    final aac = File('${dir.path}/in.aac');
    final out = File('${dir.path}/out.flv');

    // 3 seconds of 30 fps test pattern, keyframe every 30 frames, no B-frames
    // (mobile hardware encoders don't emit them in baseline/main realtime).
    var r = await Process.run('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=30',
      '-t', '3', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-profile:v', 'baseline', '-g', '30', '-bf', '0',
      '-x264-params', 'aud=1', '-f', 'h264', h264.path,
    ]);
    expect(r.exitCode, 0, reason: r.stderr.toString());
    r = await Process.run('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
      '-t', '3', '-ac', '2', '-c:a', 'aac', '-b:a', '128k', '-f', 'adts', aac.path,
    ]);
    expect(r.exitCode, 0, reason: r.stderr.toString());

    const port = 19357;
    final server = await Process.start('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-listen', '1', '-i', 'rtmp://127.0.0.1:$port/live/testkey',
      '-c', 'copy', out.path,
    ]);
    final serverErr = StringBuffer();
    server.stderr.transform(const SystemEncoding().decoder).listen(serverErr.write);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final pub = RtmpPublisher(RtmpUrl.parse('rtmp://127.0.0.1:$port/live/testkey'));
    await pub.connect();
    expect(pub.isPublishing, isTrue);

    final aus = _accessUnits(await h264.readAsBytes());
    final (asc, aacFrames) = Aac.parseAdts(await aac.readAsBytes());
    final sps = aus.first.firstWhere((n) => H264.nalType(n) == H264.nalSps);
    final pps = aus.first.firstWhere((n) => H264.nalType(n) == H264.nalPps);

    pub.sendMetadata(Flv.metadata(
      width: 320, height: 240, fps: 30, videoKbps: 500, audioKbps: 128,
      sampleRate: 44100, channels: 2,
    ));
    pub.sendVideoConfig(H264.decoderConfigRecord(sps, pps));
    pub.sendAudioConfig(asc);

    // Interleave by timestamp, like a live encoder would.
    var vi = 0, ai = 0;
    while (vi < aus.length || ai < aacFrames.length) {
      final vts = vi < aus.length ? (vi * 1000 / 30).round() : 1 << 30;
      final ats = ai < aacFrames.length ? (ai * 1024 * 1000 / 44100).round() : 1 << 30;
      if (vts <= ats) {
        final au = aus[vi++];
        final key = au.any((n) => H264.nalType(n) == H264.nalIdr);
        final nals = au.where((n) {
          final t = H264.nalType(n);
          return t != H264.nalSps && t != H264.nalPps;
        });
        pub.sendVideo(H264.toAvcc(nals), vts, keyframe: key);
      } else {
        pub.sendAudio(aacFrames[ai++], ats);
      }
    }
    expect(pub.stats.droppedVideoFrames, 0);
    await pub.close();

    final code = await server.exitCode.timeout(const Duration(seconds: 15));
    expect(code, 0, reason: serverErr.toString());

    final probe = await Process.run('ffprobe', [
      '-v', 'error', '-count_frames',
      '-show_entries', 'stream=codec_name,width,height,nb_read_frames',
      '-of', 'csv=p=0', out.path,
    ]);
    final lines = probe.stdout.toString().trim().split('\n')..sort();
    // e.g. "aac,129" and "h264,320,240,90"
    expect(lines.length, 2, reason: probe.stdout.toString() + probe.stderr.toString());
    expect(lines[0], startsWith('aac'));
    expect(lines[1], 'h264,320,240,${aus.length}');
    await dir.delete(recursive: true);
  }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
}
