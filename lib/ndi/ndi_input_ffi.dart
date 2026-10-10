import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ndi_bindings.dart';
import 'ndi_input.dart';

NdiReceiverBackend createNdiReceiverBackend() => _FfiNdiInput();

class _FfiNdiInput implements NdiReceiverBackend {
  @override
  bool get available => Ndi.load() != null;

  @override
  String? get unavailableReason => available ? null : Ndi.loadError;

  @override
  Future<List<String>> discover({Duration wait = const Duration(seconds: 3)}) async {
    if (!available) return const [];
    final path = Ndi.libraryPath;
    final ms = wait.inMilliseconds;
    return Isolate.run(() => _discover(path, ms), debugName: 'ndi-find');
  }

  @override
  NdiReceiverHandle open(
    String name, {
    bool lowBandwidth = false,
    required void Function(Uint8List rgba, int width, int height) onVideo,
    required void Function(Float32List interleaved, int sampleRate, int channels) onAudio,
    required void Function(NdiReceiverState state, String? message) onState,
  }) =>
      _FfiReceiver(name, lowBandwidth, onVideo, onAudio, onState).._start();
}

List<String> _discover(String? libPath, int waitMs) {
  Ndi.libraryPath = libPath;
  final ndi = Ndi.load();
  if (ndi == null) return const [];
  final create = calloc<NdiFindCreate>();
  create.ref
    ..showLocalSources = true
    ..pGroups = nullptr
    ..pExtraIps = nullptr;
  final finder = ndi.findCreateV2(create);
  calloc.free(create);
  if (finder == nullptr) return const [];
  final count = calloc<Uint32>();
  try {
    final until = DateTime.now().add(Duration(milliseconds: waitMs));
    while (DateTime.now().isBefore(until)) {
      ndi.findWaitForSources(finder, 500);
    }
    final list = ndi.findGetCurrentSources(finder, count);
    return [for (var i = 0; i < count.value; i++) list[i].pNdiName.toDartString()];
  } finally {
    calloc.free(count);
    ndi.findDestroy(finder);
  }
}

class _FfiReceiver implements NdiReceiverHandle {
  _FfiReceiver(this.name, this.lowBandwidth, this.onVideo, this.onAudio, this.onState);

  final String name;
  final bool lowBandwidth;
  final void Function(Uint8List rgba, int width, int height) onVideo;
  final void Function(Float32List interleaved, int sampleRate, int channels) onAudio;
  final void Function(NdiReceiverState state, String? message) onState;

  final _inbox = ReceivePort();
  SendPort? _port;
  Isolate? _isolate;
  bool _closed = false;

  Future<void> _start() async {
    _inbox.listen((m) {
      if (_closed) return;
      final msg = m as List;
      switch (msg[0]) {
        case 'port':
          _port = msg[1] as SendPort;
        case 'video':
          onVideo((msg[1] as TransferableTypedData).materialize().asUint8List(), msg[2] as int, msg[3] as int);
        case 'audio':
          onAudio((msg[1] as TransferableTypedData).materialize().asFloat32List(), msg[2] as int, msg[3] as int);
        case 'state':
          onState(NdiReceiverState.values.byName(msg[1] as String), msg[2] as String?);
      }
    });
    onState(NdiReceiverState.searching, null);
    try {
      _isolate = await Isolate.spawn(
        _receiveIsolate,
        [_inbox.sendPort, name, lowBandwidth, Ndi.libraryPath],
        debugName: 'ndi-receive',
      );
      if (_closed) _isolate?.kill(priority: Isolate.immediate);
    } catch (e) {
      onState(NdiReceiverState.error, 'Could not start NDI: $e');
    }
  }

  @override
  void frameDone() => _port?.send(const ['done']);

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final p = _port;
    if (p != null) {
      p.send(const ['stop']);
    } else {
      _isolate?.kill(priority: Isolate.immediate);
    }
    _inbox.close();
  }
}

/// Runs in the receive isolate: finds the sender, connects, and passes
/// frames back until told to stop.
Future<void> _receiveIsolate(List<Object?> args) async {
  final out = args[0] as SendPort;
  final name = args[1] as String;
  final lowBandwidth = args[2] as bool;
  Ndi.libraryPath = args[3] as String?;
  final ndi = Ndi.load();
  if (ndi == null) {
    out.send(['state', 'error', Ndi.loadError ?? 'NDI unavailable']);
    return;
  }
  var running = true;
  var ready = true; // main isolate is ready for a video frame
  final inbox = ReceivePort();
  inbox.listen((m) {
    switch ((m as List)[0]) {
      case 'done':
        ready = true;
      case 'stop':
        running = false;
    }
  });
  out.send(['port', inbox.sendPort]);

  // Find the sender.
  final fc = calloc<NdiFindCreate>();
  fc.ref
    ..showLocalSources = true
    ..pGroups = nullptr
    ..pExtraIps = nullptr;
  final finder = ndi.findCreateV2(fc);
  calloc.free(fc);
  final count = calloc<Uint32>();
  Pointer<Void> recv = nullptr;
  while (running && recv == nullptr && finder != nullptr) {
    ndi.findWaitForSources(finder, 300);
    final list = ndi.findGetCurrentSources(finder, count);
    for (var i = 0; i < count.value; i++) {
      if (list[i].pNdiName.toDartString() != name) continue;
      final rc = calloc<NdiRecvCreateV3>();
      rc.ref
        ..sourceToConnectTo.pNdiName = list[i].pNdiName
        ..sourceToConnectTo.pUrlAddress = list[i].pUrlAddress
        ..colorFormat = Ndi.recvColorRgbxRgba
        ..bandwidth = lowBandwidth ? Ndi.recvBandwidthLowest : Ndi.recvBandwidthHighest
        ..allowVideoFields = false
        ..pNdiRecvName = 'OBSpad'.toNativeUtf8();
      recv = ndi.recvCreateV3(rc);
      calloc.free(rc.ref.pNdiRecvName);
      calloc.free(rc);
      break;
    }
    // Let 'stop' messages in.
    await Future<void>.delayed(Duration.zero);
  }
  calloc.free(count);
  if (finder != nullptr) ndi.findDestroy(finder);
  if (recv == nullptr) {
    if (running) out.send(['state', 'error', 'Could not connect to $name']);
    inbox.close();
    return;
  }

  final video = calloc<NdiVideoFrameV2>();
  final audio = calloc<NdiAudioFrameV2>();
  final rgbx = ndiFourCC('RGBX');
  var connected = false;
  var lastFrame = DateTime.now();
  while (running) {
    final type = ndi.recvCaptureV2(recv, video, audio, nullptr, 100);
    if (type == Ndi.frameTypeVideo) {
      lastFrame = DateTime.now();
      if (!connected) {
        connected = true;
        out.send(['state', 'connected', null]);
      }
      if (ready) {
        final v = video.ref;
        final w = v.xres, h = v.yres, stride = v.lineStrideInBytes;
        if (w > 0 && h > 0 && v.pData != nullptr) {
          final src = v.pData.asTypedList(stride * h);
          final buf = Uint8List(w * h * 4);
          if (stride == w * 4) {
            buf.setRange(0, buf.length, src);
          } else {
            for (var y = 0; y < h; y++) {
              buf.setRange(y * w * 4, (y + 1) * w * 4, src, y * stride);
            }
          }
          // RGBX: the fourth byte isn't alpha; make it opaque.
          if (v.fourCC == rgbx) {
            for (var i = 3; i < buf.length; i += 4) {
              buf[i] = 255;
            }
          }
          ready = false;
          out.send(['video', TransferableTypedData.fromList([buf]), w, h]);
        }
      }
      ndi.recvFreeVideoV2(recv, video);
    } else if (type == Ndi.frameTypeAudio) {
      final a = audio.ref;
      final n = a.noSamples, ch = a.noChannels;
      if (n > 0 && ch > 0 && a.pData != nullptr) {
        final outCh = ch >= 2 ? 2 : 1;
        final strideFloats = a.channelStrideInBytes ~/ 4;
        final planar = a.pData.asTypedList(strideFloats * ch);
        final inter = Float32List(n * outCh);
        for (var c = 0; c < outCh; c++) {
          final base = c * strideFloats;
          for (var i = 0; i < n; i++) {
            inter[i * outCh + c] = planar[base + i];
          }
        }
        out.send(['audio', TransferableTypedData.fromList([inter]), a.sampleRate, outCh]);
      }
      ndi.recvFreeAudioV2(recv, audio);
    } else if (type == Ndi.frameTypeError ||
        (connected && DateTime.now().difference(lastFrame) > const Duration(seconds: 3))) {
      if (connected) {
        connected = false;
        out.send(['state', 'lost', 'The NDI sender stopped sending']);
      }
    }
    // Let 'done' / 'stop' messages in.
    await Future<void>.delayed(Duration.zero);
  }
  ndi.recvDestroy(recv);
  calloc.free(video);
  calloc.free(audio);
  inbox.close();
}
