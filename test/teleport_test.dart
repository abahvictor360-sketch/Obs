@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/studio_controller.dart';
import 'package:obs_tablet/output/encoder_backend.dart';
import 'package:obs_tablet/output/output_engine.dart';
import 'package:obs_tablet/teleport/teleport_input.dart';
import 'package:obs_tablet/teleport/teleport_output.dart';
import 'package:obs_tablet/teleport/teleport_protocol.dart';

import 'widget_test.dart' show FakeEncoder;

/// A Teleport peer built from obs-teleport's own structs and discovery
/// library (Go), if this machine has one.
const _peer = String.fromEnvironment('TELEPORT_PEER',
    defaultValue: '/tmp/claude-0/-home-user-Obs/b7d5cdb3-fea0-58fa-8597-5f9b0b4220c8/scratchpad/teleport/peer/peer');
bool get _hasPeer => File(_peer).existsSync();

Future<void> until(bool Function() ok, {Duration timeout = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('announcement JSON uses Teleport\'s field names', () {
    final a = TeleportAnnounce(name: 'OBSpad', port: 43210);
    expect(jsonDecode(utf8.decode(a.encode())),
        {'Name': 'OBSpad', 'Port': 43210, 'AudioAndVideo': true, 'Version': kTeleportVersion});
    final back = TeleportAnnounce.decode(a.encode(), '192.168.1.20')!;
    expect((back.name, back.port, back.key), ('OBSpad', 43210, 'OBSpad:192.168.1.20'));
    expect(TeleportAnnounce.decode(utf8.encode('hi'), '1.2.3.4'), isNull); // peerdiscovery's default payload
  });

  test('packets: Go binary.Read layout, split across reads, 16-bit and float sound', () {
    final jpeg = Uint8List.fromList(List.generate(1000, (i) => i & 0xFF));
    final video = teleportJpegPacket(123456789, jpeg);
    expect(video.length, 16 + 88 + 1000);
    expect(String.fromCharCodes(video.sublist(0, 4)), 'JPEG');
    final hb = ByteData.sublistView(video);
    expect(hb.getUint64(4, Endian.little), 123456789);
    expect(hb.getInt32(12, Endian.little), 1000);
    expect(hb.getFloat32(16 + 8, Endian.little), closeTo(1.40752, 1e-5)); // Cr -> R
    expect(hb.getFloat32(16 + 76, Endian.little), 1.0); // range max

    final audio = teleportWavePacket(5, Float32List.fromList([0.5, -0.5, 0.25, -0.25]), 48000, 2);
    final ab = ByteData.sublistView(audio);
    expect((ab.getInt32(16, Endian.little), ab.getInt32(20, Endian.little), ab.getInt32(24, Endian.little),
        ab.getInt32(28, Endian.little)), (TeleportAudioFormat.float, 48000, 2, 2));

    // 16-bit stereo, as OBS often outputs.
    final s16 = ByteData(16 + 16 + 8)
      ..setUint8(0, 0x57)
      ..setUint8(1, 0x41)
      ..setUint8(2, 0x56)
      ..setUint8(3, 0x45)
      ..setInt32(12, 8, Endian.little)
      ..setInt32(16, TeleportAudioFormat.s16, Endian.little)
      ..setInt32(20, 44100, Endian.little)
      ..setInt32(24, 2, Endian.little)
      ..setInt32(28, 2, Endian.little)
      ..setInt16(32, 16384, Endian.little)
      ..setInt16(34, -32768, Endian.little);

    final all = Uint8List.fromList([...video, ...audio, ...s16.buffer.asUint8List()]);
    final r = TeleportReader();
    final got = <TeleportPacket>[];
    for (var i = 0; i < all.length; i += 37) {
      got.addAll(r.add(all.sublist(i, i + 37 > all.length ? all.length : i + 37)));
    }
    expect(got, hasLength(3));
    expect((got[0] as TeleportVideo).jpeg, jpeg);
    expect((got[1] as TeleportAudio).samples, [0.5, -0.5, 0.25, -0.25]);
    final t16 = got[2] as TeleportAudio;
    expect((t16.sampleRate, t16.channels, t16.samples.first, t16.samples[1]), (44100, 2, 0.5, -1.0));
    expect(() => TeleportReader().add(List.filled(16, 0xFF)), throwsFormatException);
  });

  test('OBS (obs-teleport\'s receiver) discovers OBSpad and gets its JPEG frames and sound', () async {
    final name = 'OBSpad-test-${pid % 10000}';
    final out = TeleportOutput();
    await out.start(name: name);
    final jpeg = File('test/fixtures/frame_a.jpg').readAsBytesSync();
    final pump = Timer.periodic(const Duration(milliseconds: 30), (_) {
      out.sendJpeg(jpeg);
      out.sendAudio(Float32List.fromList(List.filled(960 * 2, 0.125)), 48000, 2);
    });
    final r = await Process.run(_peer, ['receive', name]).timeout(const Duration(seconds: 30));
    pump.cancel();
    expect(out.receivers, anyOf(0, 1));
    await out.stop();
    final res = jsonDecode('${r.stdout}'.trim().split('\n').last) as Map;
    expect(res['error'], isNull, reason: '${r.stdout}${r.stderr}');
    expect(res['name'], name);
    expect(res['audioAndVideo'], true);
    expect(res['jpegs'], greaterThanOrEqualTo(3));
    expect((res['width'], res['height']), (160, 90));
    expect(res['ycbcr'], true);
    expect(res['waves'], greaterThanOrEqualTo(3));
    expect((res['format'], res['rate'], res['speakers'], res['frames']), (4, 48000, 2, 960));
    expect(res['firstSample'], 0.125);
  }, skip: _hasPeer ? false : 'Teleport test peer not built');

  testWidgets('OBSpad\'s Teleport source finds a Teleport sender and receives its picture and sound', (tester) async {
    await tester.runAsync(() async {
      final name = 'OBS-test-${pid % 10000}';
      final sound = <(String, int, int, int)>[];
      final service = TeleportInputService(onAudio: (id, pcm, rate, ch) => sound.add((id, pcm.length, rate, ch)));
      service.watch();
      final peer = await Process.start(_peer, ['send', name]);
      try {
        await until(() => service.senders.any((a) => a.name == name));
        final sender = service.senders.firstWhere((a) => a.name == name);
        expect(teleportDisplayName(sender.key), '$name (${sender.address})');
        service.sync({'src1': sender.key});
        await until(() => service.feed('src1')?.image != null && sound.isNotEmpty);
        final feed = service.feed('src1')!;
        expect((feed.width, feed.height, feed.state), (320, 180, TeleportInputState.connected));
        expect(sound.first, ('src1', 2048, 48000, 2));
        // The red frame came through.
        final bytes = (await feed.image!.toByteData())!;
        final mid = (90 * 320 + 160) * 4;
        expect(bytes.getUint8(mid), closeTo(200, 12));
        expect(bytes.getUint8(mid + 1), closeTo(30, 12));
        service.sync({});
        expect(service.feed('src1'), isNull);
      } finally {
        peer.kill();
        service.dispose();
      }
    });
  }, skip: !_hasPeer);

  testWidgets('Teleport output: frames are only made while a receiver is connected', (tester) async {
    final studio = StudioController(storage: MemoryStorage());
    final enc = FakeEncoder(supported: true);
    final output = OutputEngine(studio: studio, backend: enc);
    await output.init();
    await tester.runAsync(() async {
      await output.startTeleport(name: 'Pulpit', quality: 80);
      expect(output.teleportActive, isTrue);
      expect(enc.configs, hasLength(1)); // the encoder runs to make frames
      expect(enc.jpegQualities, isEmpty);

      final socket = await Socket.connect(InternetAddress.loopbackIPv4, output.teleport.port);
      final reader = TeleportReader();
      final got = <TeleportPacket>[];
      socket.listen((d) => got.addAll(reader.add(d)));
      await until(() => enc.jpegQualities.isNotEmpty);
      expect(enc.jpegQualities.last, 80);
      enc.jpegCtl.add(JpegFrame(File('test/fixtures/frame_a.jpg').readAsBytesSync(), 160, 90));
      await until(() => got.whereType<TeleportVideo>().isNotEmpty);

      await socket.close();
      socket.destroy();
      await until(() => enc.jpegQualities.last == 0);
      await output.stopTeleport();
      expect(output.teleportActive, isFalse);
    });
    output.dispose();
    studio.dispose();
  });
}
