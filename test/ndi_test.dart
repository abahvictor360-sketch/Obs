// Sends program frames over NDI and receives them back.
//
// Uses the real NDI runtime when NDI_LIB points at it (CI downloads the SDK),
// otherwise a stand-in library built from test/ndi/ndi_stub.c with the same
// struct layouts.

@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/ndi/ndi_bindings.dart';
import 'package:obs_tablet/ndi/ndi_output_ffi.dart';

String? _prepareLibrary() {
  final real = Platform.environment['NDI_LIB'];
  if (real != null && real.isNotEmpty) return real;
  final out = '${Directory.systemTemp.path}/libndi_stub_$pid.so';
  final r = Process.runSync('clang', ['-shared', '-fPIC', '-O1', '-o', out, 'test/ndi/ndi_stub.c']);
  if (r.exitCode != 0) return null;
  return out;
}

void main() {
  final lib = _prepareLibrary();
  final usingRealSdk = (Platform.environment['NDI_LIB'] ?? '').isNotEmpty;

  test('NDI output sends frames a receiver can pick up${usingRealSdk ? ' (real NDI SDK)' : ' (stub)'}', () async {
    Ndi.libraryPath = lib;
    final ndi = Ndi.load();
    expect(ndi, isNotNull, reason: Ndi.loadError);
    expect(ndi!.version().toDartString(), isNotEmpty);

    final out = FfiNdiOutput();
    expect(out.available, isTrue);
    const name = 'OBSpad Test';
    await out.start(name: name);

    // 64x36, opaque mid-grey with a red band: survives NDI's lossy codec.
    const w = 64, h = 36;
    final frame = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      final red = (i ~/ w) < 12;
      frame[i * 4] = red ? 220 : 128;
      frame[i * 4 + 1] = red ? 20 : 128;
      frame[i * 4 + 2] = red ? 20 : 128;
      frame[i * 4 + 3] = 255;
    }
    var sending = true;
    Future<void> pump() async {
      while (sending) {
        out.sendVideo(frame, w, h, 30);
        out.sendAudio(Float32List(1024), 44100, 1);
        await Future<void>.delayed(const Duration(milliseconds: 33));
      }
    }

    final pumping = pump();

    // Find our source.
    final fc = calloc<NdiFindCreate>()
      ..ref.showLocalSources = true
      ..ref.pGroups = nullptr
      ..ref.pExtraIps = nullptr;
    final find = ndi.findCreateV2(fc);
    final count = calloc<Uint32>();
    Pointer<NdiSource> source = nullptr;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (source == nullptr && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      ndi.findWaitForSources(find, 0);
      final list = ndi.findGetCurrentSources(find, count);
      for (var i = 0; i < count.value; i++) {
        if (list[i].pNdiName.toDartString().contains(name)) source = list + i;
      }
    }
    expect(source, isNot(nullptr), reason: 'NDI source "$name" was not discovered');

    final rc = calloc<NdiRecvCreateV3>();
    rc.ref
      ..sourceToConnectTo.pNdiName = source.ref.pNdiName
      ..sourceToConnectTo.pUrlAddress = source.ref.pUrlAddress
      ..colorFormat = Ndi.recvColorRgbxRgba
      ..bandwidth = Ndi.recvBandwidthHighest
      ..allowVideoFields = false
      ..pNdiRecvName = nullptr;
    final recv = ndi.recvCreateV3(rc);
    expect(recv, isNot(nullptr));

    final v = calloc<NdiVideoFrameV2>();
    var got = false;
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (!got && DateTime.now().isBefore(until)) {
      if (ndi.recvCaptureV2(recv, v, nullptr, nullptr, 0) == Ndi.frameTypeVideo) {
        got = true;
        expect((v.ref.xres, v.ref.yres), (w, h));
        final px = v.ref.pData.asTypedList(v.ref.lineStrideInBytes * h);
        int at(int x, int y, int c) => px[y * v.ref.lineStrideInBytes + x * 4 + c];
        // Red band on top, grey below (with codec tolerance).
        expect(at(32, 4, 0), greaterThan(170));
        expect(at(32, 4, 1), lessThan(70));
        expect(at(32, 30, 0), closeTo(128, 30));
        expect(at(32, 30, 2), closeTo(128, 30));
        ndi.recvFreeVideoV2(recv, v);
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    expect(got, isTrue, reason: 'No video frame received over NDI');

    sending = false;
    await pumping;
    ndi.recvDestroy(recv);
    ndi.findDestroy(find);
    await out.stop();
  }, skip: lib == null ? 'No NDI runtime and no C compiler for the stub' : false, timeout: const Timeout(Duration(seconds: 60)));
}
