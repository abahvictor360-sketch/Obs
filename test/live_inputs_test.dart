@TestOn('vm')
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/models.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/studio_controller.dart';
import 'package:obs_tablet/live/guest_camera.dart';
import 'package:obs_tablet/live/live_inputs.dart';
import 'package:obs_tablet/live/rtmp_ingest.dart';
import 'package:obs_tablet/live/rtmp_input_service.dart';
import 'package:obs_tablet/ndi/ndi_input.dart';
import 'package:obs_tablet/ndi/ndi_input_service.dart';
import 'package:obs_tablet/output/output_engine.dart';
import 'package:obs_tablet/output/rtmp_chunk.dart';
import 'package:obs_tablet/output/rtmp_client.dart';

import 'widget_test.dart' show FakeEncoder;

class FakeDecoder implements StreamInDecoder {
  final calls = <String>[];
  @override
  void Function(String id, int width, int height)? onSize;
  @override
  void Function(String id, String message)? onError;

  @override
  Future<int?> open(String id) async {
    calls.add('open $id');
    return 42;
  }

  @override
  void videoConfig(String id, Uint8List avcc) => calls.add('videoConfig $id ${avcc.length}');
  @override
  void video(String id, Uint8List data, {required bool keyframe}) =>
      calls.add('video $id ${data.length}${keyframe ? ' key' : ''}');
  @override
  void audioConfig(String id, Uint8List asc) => calls.add('audioConfig $id ${asc.join(',')}');
  @override
  void audio(String id, Uint8List data) => calls.add('audio $id ${data.length}');
  @override
  void close(String id) => calls.add('close $id');
}

class FakeNdi implements NdiReceiverBackend {
  final opened = <String>[];
  void Function(Uint8List, int, int)? video;
  void Function(Float32List, int, int)? audio;
  void Function(NdiReceiverState, String?)? state;
  int framesDone = 0;
  bool closed = false;

  @override
  bool get available => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<List<String>> discover({Duration wait = const Duration(seconds: 3)}) async =>
      ['STUDIO-PC (vMix - Output 1)', 'PTZ-1 (Camera)'];

  @override
  NdiReceiverHandle open(
    String name, {
    bool lowBandwidth = false,
    required void Function(Uint8List rgba, int width, int height) onVideo,
    required void Function(Float32List interleaved, int sampleRate, int channels) onAudio,
    required void Function(NdiReceiverState state, String? message) onState,
  }) {
    opened.add('$name${lowBandwidth ? ' low' : ''}');
    video = onVideo;
    audio = onAudio;
    state = onState;
    return _Handle(this);
  }
}

class _Handle implements NdiReceiverHandle {
  _Handle(this.fake);
  final FakeNdi fake;
  @override
  void frameDone() => fake.framesDone++;
  @override
  void close() => fake.closed = true;
}

Future<void> until(bool Function() ok, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('RTMP input', () {
    test('a phone (the app\'s own RTMP publisher) streams to the tablet: video and sound reach the decoders',
        () async {
      final decoder = FakeDecoder();
      final port = 20000 + Random().nextInt(20000);
      final service = RtmpInputService(decoder: decoder, port: port);
      service.sync({'src1': 'cam1'});
      await until(() => service.feed('src1')?.textureId == 42);

      final phone = RtmpPublisher(RtmpUrl.parse('rtmp://127.0.0.1:$port/live/cam1'));
      await phone.connect(timeout: const Duration(seconds: 5));
      await until(() => service.feed('src1')!.state == RtmpInputState.live);
      expect(service.feed('src1')!.from, '127.0.0.1');

      phone.sendMetadata({'width': 1280, 'height': 720});
      phone.sendVideoConfig(Uint8List.fromList([1, 0x64, 0, 0x1f, 0xff, 0xe1, 0, 2, 0x67, 0x64, 1, 0, 2, 0x68, 0xee]));
      phone.sendAudioConfig(Uint8List.fromList([0x12, 0x10]));
      // 6000 bytes: larger than the chunk size, split across chunks.
      phone.sendVideo(Uint8List(6000), 0, keyframe: true);
      phone.sendAudio(Uint8List(300), 10);
      phone.sendVideo(Uint8List(900), 33, keyframe: false);
      await until(() => decoder.calls.where((c) => c.startsWith('video ')).length == 2);
      await until(() => decoder.calls.any((c) => c.startsWith('audio ')));

      expect(decoder.calls, containsAll(['open src1', 'videoConfig src1 15', 'audioConfig src1 18,16']));
      expect(decoder.calls.where((c) => c.startsWith('video ')), ['video src1 6000 key', 'video src1 900']);
      expect(decoder.calls.where((c) => c.startsWith('audio ')), ['audio src1 300']);
      expect(service.feed('src1')!.hasVideo, isTrue);
      expect(service.feed('src1')!.hasAudio, isTrue);

      // The phone stops: the source waits for the next stream.
      await phone.close();
      await until(() => service.feed('src1')!.state == RtmpInputState.waiting);

      // Removing the source closes its decoder; no source left stops the server.
      service.sync({});
      expect(decoder.calls.last, 'close src1');
      service.dispose();
    });

    test('an unknown stream key is refused with a clear reason', () async {
      final port = 20000 + Random().nextInt(20000);
      final service = RtmpInputService(decoder: FakeDecoder(), port: port);
      service.sync({'src1': 'cam1'});
      await until(() => service.feed('src1')?.textureId != null);
      final phone = RtmpPublisher(RtmpUrl.parse('rtmp://127.0.0.1:$port/live/wrong'));
      await expectLater(phone.connect(timeout: const Duration(seconds: 3)), throwsA(anything));
      expect(service.feed('src1')!.state, RtmpInputState.waiting);
      service.dispose();
    });

    test('FLV bodies: H.264 and AAC are understood, other codecs are explained', () {
      RtmpMessage msg(int type, List<int> b) =>
          RtmpMessage(chunkStreamId: 4, typeId: type, timestamp: 0, streamId: 1, payload: Uint8List.fromList(b));
      expect(FlvPacket.parse(msg(9, [0x17, 0, 0, 0, 0, 1, 2])), isA<AvcConfig>());
      final f = FlvPacket.parse(msg(9, [0x27, 1, 0, 0, 0, 9, 9])) as AvcFrame;
      expect((f.keyframe, f.data.length), (false, 2));
      expect(FlvPacket.parse(msg(8, [0xAF, 0, 0x12, 0x10])), isA<AacConfig>());
      expect(FlvPacket.parse(msg(8, [0xAF, 1, 5, 5, 5])), isA<AacFrame>());
      // Enhanced RTMP HEVC, MP3 audio.
      expect((FlvPacket.parse(msg(9, [0x90, 0x68, 0x76, 0x63, 0x31])) as UnsupportedCodec).message,
          contains('H.264'));
      expect((FlvPacket.parse(msg(8, [0x2F, 1, 2])) as UnsupportedCodec).message, contains('AAC'));
    });
  });

  group('NDI Source', () {
    testWidgets('received frames become the picture; sound goes to the mix', (tester) async {
      final fake = FakeNdi();
      final service = NdiInputService(backend: fake);
      final sound = <(String, int, int, int)>[];
      service.onAudio = (id, pcm, rate, ch) => sound.add((id, pcm.length, rate, ch));
      service.sync({'n1': ('PTZ-1 (Camera)', true)});
      expect(fake.opened, ['PTZ-1 (Camera) low']);

      fake.state!(NdiReceiverState.connected, null);
      await tester.runAsync(() async {
        fake.video!(Uint8List(4 * 4 * 4), 4, 4);
        await until(() => service.feed('n1')!.image != null);
      });
      expect(service.feed('n1')!.width, 4);
      expect(fake.framesDone, 1);
      fake.audio!(Float32List(960), 48000, 2);
      expect(sound, [('n1', 960, 48000, 2)]);

      // Another source name reconnects; nothing wanted closes it.
      service.sync({'n1': ('STUDIO-PC (vMix - Output 1)', false)});
      expect(fake.opened.last, 'STUDIO-PC (vMix - Output 1)');
      service.sync({});
      expect(fake.closed, isTrue);
      expect(service.feed('n1'), isNull);
      service.dispose();
    });
  });

  group('network sources in the mix', () {
    test('sound of NDI and RTMP sources on Program is mixed with fader, mute and sync offset', () async {
      final studio = StudioController(storage: MemoryStorage());
      final enc = FakeEncoder(supported: true);
      final output = OutputEngine(studio: studio, backend: enc);
      await output.init();
      final fake = FakeNdi();
      final inputs = LiveInputs(
        ndi: NdiInputService(backend: fake),
        rtmp: RtmpInputService(decoder: FakeDecoder(), port: 20000 + Random().nextInt(20000)),
      );
      final tracker = LiveInputsTracker(studio, inputs, output: output);

      final ndiItem = studio.addNewSource(SourceType.ndiInput, name: 'PTZ', settings: {'ndiName': 'PTZ-1 (Camera)'});
      final ndi = studio.sourceById(ndiItem.sourceId)!;
      studio.addNewSource(SourceType.rtmpInput, name: 'Phone', settings: {'streamKey': 'cam1'});
      expect(fake.opened, ['PTZ-1 (Camera)']);
      expect(enc.liveAudio.last.map((m) => m['id']), hasLength(2));

      studio.setSyncOffset(ndi.id, 250);
      studio.setVolume(ndi.id, 0.5);
      final m = enc.liveAudio.last.firstWhere((m) => m['id'] == ndi.id);
      expect((m['gain'], m['delayMs']), (0.5, 250));
      studio.setMuted(ndi.id, true);
      expect(enc.liveAudio.last.firstWhere((m) => m['id'] == ndi.id)['gain'], 0.0);

      // NDI sound is pushed to the native mixer.
      fake.audio!(Float32List(480), 48000, 2);
      expect(enc.livePushes.single, (ndi.id, 480, 2, 48000));

      tracker.dispose();
      inputs.dispose();
      studio.dispose();
    });

    test('audio sync offset reaches mics and videos, clamped to 0-2000 ms', () {
      final studio = StudioController(storage: MemoryStorage());
      final mic = studio.sourceById(studio.addNewSource(SourceType.audioInput, name: 'Mic').sourceId)!;
      studio.setSyncOffset(mic.id, 120);
      final inputs = studio.micProcessing['inputs'] as List;
      expect((inputs.firstWhere((i) => (i as Map)['id'] == mic.id) as Map)['delayMs'], 120);
      studio.setSyncOffset(mic.id, 5000);
      expect(studio.sourceById(mic.id)!.syncOffsetMs, 2000);
      expect(SourceType.media.hasSyncOffset && SourceType.rtmpInput.hasSyncOffset, isTrue);
      expect(SourceType.camera.hasSyncOffset, isFalse);
      studio.dispose();
    });
  });

  test('guest camera: a private link for the guest, a clean view for the Browser source', () {
    final room = GuestCamera.newRoom(Random(1));
    expect(room, matches(RegExp(r'^obspad[a-z2-9]{10}$')));
    expect(GuestCamera.newRoom(), isNot(room));
    expect(GuestCamera.pushUrl(room), startsWith('https://vdo.ninja/?push=$room&webcam'));
    final s = GuestCamera.sourceSettings(room);
    expect(s['url'], 'https://vdo.ninja/?view=$room&cleanoutput&noaudio');
    expect((s['guestRoom'], s['shutdown']), (room, false));
  });
}
