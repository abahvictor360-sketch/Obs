@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/live/mpegts.dart';
import 'package:obs_tablet/live/rtmp_input_service.dart';
import 'package:obs_tablet/live/srt.dart';

import 'live_inputs_test.dart' show FakeDecoder;

/// ffmpeg built with libsrt, if this machine has one (the reference SRT).
bool get _ffmpegSrt {
  try {
    final r = Process.runSync('ffmpeg', ['-hide_banner', '-protocols']);
    return '${r.stdout}'.split('\n').any((l) => l.trim() == 'srt');
  } catch (_) {
    return false;
  }
}

Future<void> until(bool Function() ok, {Duration timeout = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('H.264 Annex B becomes avcC + length-prefixed frames; ADTS becomes ASC + raw AAC', () {
    final sps = [0x67, 0x64, 0x00, 0x1F, 0xAC];
    final pps = [0x68, 0xEE, 0x3C];
    final idr = [0x65, 0x88, 0x84];
    final au = Uint8List.fromList([
      0, 0, 0, 1, 0x09, 0xF0, // AUD
      0, 0, 0, 1, ...sps, 0, 0, 1, ...pps, 0, 0, 1, ...idr,
    ]);
    Uint8List? cfg;
    (Uint8List, bool)? frame;
    H264Packer().add(au, onConfig: (c) => cfg = c, onFrame: (d, k) => frame = (d, k));
    expect(cfg, [1, 0x64, 0, 0x1F, 0xFF, 0xE1, 0, 5, ...sps, 1, 0, 3, ...pps]);
    expect(frame!.$1, [0, 0, 0, 3, ...idr]);
    expect(frame!.$2, isTrue);

    // ADTS: AAC-LC, 48 kHz (index 3), stereo, 2 payload bytes.
    final adts = Uint8List.fromList([0xFF, 0xF1, 0x4C, 0x80, 0x01, 0x3F, 0xFC, 0xAA, 0xBB]);
    final frames = AdtsReader.frames(adts).toList();
    expect(frames.single.$1, [0x11, 0x90]);
    expect(frames.single.$2, [0xAA, 0xBB]);
  });

  test('SRT: rejects encrypted callers and unknown stream ids at the handshake', () {
    final sent = <Uint8List>[];
    final l = SrtListener(send: (d, a, p) => sent.add(d), onConnect: (c) => c.streamId == 'cam1' ? null : 1404);
    Uint8List hs(int type, int cookie, {List<int> ext = const [], int enc = 0}) {
      final b = ByteData(64 + ext.length * 4)
        ..setUint32(0, 0x80000000)
        ..setUint32(16, type == 1 ? 4 : 5)
        ..setUint16(20, enc)
        ..setUint32(24, 1000)
        ..setUint32(28, 1500)
        ..setUint32(32, 8192)
        ..setUint32(36, type)
        ..setUint32(40, 77)
        ..setUint32(44, cookie);
      for (var i = 0; i < ext.length; i++) {
        b.setUint32(64 + i * 4, ext[i]);
      }
      return b.buffer.asUint8List();
    }

    l.onDatagram(hs(1, 0), '10.0.0.5', 5000);
    final induction = ByteData.sublistView(sent.last);
    expect(induction.getUint32(16), 5);
    expect(induction.getUint16(22), SrtHandshake.magic);
    final cookie = induction.getUint32(44);

    // Stream id "cam2": 4 bytes, reversed per word.
    final sid = [(SrtHandshake.streamId << 16) | 1, 0x326d6163];
    l.onDatagram(hs(0xFFFFFFFF, cookie, ext: sid), '10.0.0.5', 5000);
    expect(ByteData.sublistView(sent.last).getUint32(36), 1404);
    expect(l.connections, isEmpty);

    l.onDatagram(hs(0xFFFFFFFF, cookie, enc: 2), '10.0.0.5', 5000);
    expect(ByteData.sublistView(sent.last).getUint32(36), SrtHandshake.rejectBadSecret);

    final ok = [(SrtHandshake.streamId << 16) | 1, 0x316d6163]; // "cam1"
    l.onDatagram(hs(0xFFFFFFFF, cookie, ext: ok), '10.0.0.5', 5000);
    final answer = ByteData.sublistView(sent.last);
    expect(answer.getUint32(36), 0xFFFFFFFF);
    expect(answer.getUint16(64), SrtHandshake.hsRsp);
    expect(l.connections.single.streamId, 'cam1');
  });

  test('SRT: lost packets are asked for again and delivered in order', () {
    final sent = <Uint8List>[];
    final got = <int>[];
    late SrtConnection conn;
    final l = SrtListener(
      send: (d, a, p) => sent.add(d),
      onConnect: (c) {
        conn = c..onData = (p) => got.add(p[0]);
        return null;
      },
    );
    // Handshake quickly.
    Uint8List hs(int type, int cookie) =>
        (ByteData(64)
              ..setUint32(0, 0x80000000)
              ..setUint32(16, 5)
              ..setUint32(24, 100)
              ..setUint32(36, type)
              ..setUint32(40, 9)
              ..setUint32(44, cookie))
            .buffer
            .asUint8List();
    l.onDatagram(hs(1, 0), 'a', 1);
    final cookie = ByteData.sublistView(sent.last).getUint32(44);
    l.onDatagram(hs(0xFFFFFFFF, cookie), 'a', 1);
    Uint8List data(int seq) =>
        (ByteData(17)
              ..setUint32(0, seq)
              ..setUint32(12, conn.socketId)
              ..setUint8(16, seq - 100))
            .buffer
            .asUint8List();
    l.onDatagram(data(100), 'a', 1);
    l.onDatagram(data(101), 'a', 1);
    l.onDatagram(data(104), 'a', 1); // 102, 103 lost
    expect(got, [0, 1]);
    final nak = sent.lastWhere((p) => (ByteData.sublistView(p).getUint32(0) >> 16 & 0x7FFF) == SrtControl.nak);
    final nb = ByteData.sublistView(nak);
    expect((nb.getUint32(16), nb.getUint32(20)), (102 | 0x80000000, 103));
    l.onDatagram(data(103), 'a', 1);
    l.onDatagram(data(102), 'a', 1);
    expect(got, [0, 1, 2, 3, 4]);
  });

  for (final lossy in [false, true]) {
    test(
      'SRT: ffmpeg (libsrt) streams H.264 + AAC in MPEG-TS to the listener${lossy ? ' (3% packet loss)' : ''}',
      () async {
        SrtConnection? conn;
        final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = socket.port;
        final configs = <Uint8List>[];
        var keyframes = 0, frames = 0, audioFrames = 0;
        Uint8List? asc;
        final demux = TsDemuxer(
          onVideoConfig: configs.add,
          onVideo: (d, k) {
            frames++;
            if (k) keyframes++;
          },
          onAudioConfig: (a) => asc = a,
          onAudio: (_) => audioFrames++,
        );
        String? streamId;
        final listener = SrtListener(
          send: (d, a, p) => socket.send(d, InternetAddress(a), p),
          onConnect: (c) {
            streamId = c.streamId;
            conn = c;
            c.onData = demux.add;
            return null;
          },
        );
        var n = 0;
        socket.listen((e) {
          if (e != RawSocketEvent.read) return;
          final dg = socket.receive();
          if (dg == null) return;
          // Lossy network: drop 1 in 30 data packets on the way in.
          final isData = dg.data.length > 16 && (dg.data[0] & 0x80) == 0;
          if (lossy && isData && ++n % 30 == 0) return;
          listener.onDatagram(dg.data, dg.address.address, dg.port);
        });
        final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => listener.tick());
        final key = 'cam${Random().nextInt(99)}';
        final ff = await Process.start('ffmpeg', [
          '-hide_banner', '-loglevel', 'error', '-re', //
          '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=30',
          '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
          '-t', '3', '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency', '-g', '30',
          '-c:a', 'aac', '-b:a', '128k', '-f', 'mpegts',
          'srt://127.0.0.1:$port?mode=caller&streamid=$key&latency=200000',
        ]);
        final err = StringBuffer();
        ff.stderr.transform(const SystemEncoding().decoder).listen(err.write);
        final code = await ff.exitCode.timeout(const Duration(seconds: 30));
        await until(() => frames >= 60);
        timer.cancel();
        socket.close();
        expect(code, 0, reason: '$err');
        expect(streamId, key);
        expect(configs, isNotEmpty);
        expect(configs.first[0], 1); // avcC version
        expect(keyframes, greaterThanOrEqualTo(2));
        expect(frames, greaterThanOrEqualTo(60)); // ~3 s at 30 fps
        expect(asc, [0x11, 0x88]); // AAC-LC 48 kHz mono (ffmpeg's sine source is mono)
        expect(audioFrames, greaterThan(100)); // ~47 frames/s
        // Every dropped packet was asked for again and recovered in time.
        expect(conn!.packetsLost, 0);
      },
      skip: _ffmpegSrt ? false : 'ffmpeg with SRT not installed',
    );
  }

  test('SRT end to end: a source waiting on a stream key gets ffmpeg\'s video and sound', () async {
    final decoder = FakeDecoder();
    final srtPort = 30000 + Random().nextInt(20000);
    final service = RtmpInputService(decoder: decoder, port: srtPort + 1, srtPort: srtPort);
    service.sync({}, srt: {'s1': 'pulpit'});
    await until(() => service.feed('s1')?.textureId == 42);
    await Future<void>.delayed(const Duration(milliseconds: 200)); // UDP bound
    expect(service.srtUrl('pulpit'), endsWith(':$srtPort?streamid=pulpit'));
    final ff = await Process.start('ffmpeg', [
      '-hide_banner', '-loglevel', 'error', '-re', //
      '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25', '-f', 'lavfi', '-i', 'sine=sample_rate=44100',
      '-t', '2', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '25', '-c:a', 'aac', '-f', 'mpegts',
      'srt://127.0.0.1:$srtPort?streamid=pulpit&latency=200000',
    ]);
    expect(await ff.exitCode.timeout(const Duration(seconds: 30)), 0);
    await until(() => decoder.calls.where((c) => c.startsWith('video ')).length >= 40);
    expect(decoder.calls, contains(startsWith('videoConfig s1')));
    expect(decoder.calls, contains('audioConfig s1 18,8'));
    expect(decoder.calls, contains(startsWith('audio s1')));
    expect(service.feed('s1')!.hasVideo && service.feed('s1')!.hasAudio, isTrue);
    service.dispose();
  }, skip: _ffmpegSrt ? false : 'ffmpeg with SRT not installed');
}
