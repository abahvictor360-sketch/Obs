import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ndi_bindings.dart';
import 'ndi_output.dart';

NdiOutputSink createNdiOutput({void Function()? onChanged}) => FfiNdiOutput(onChanged: onChanged);

/// Sends frames from a dedicated isolate: NDI compresses (SpeedHQ) inside
/// the send call, which would otherwise stall the UI thread.
class FfiNdiOutput implements NdiOutputSink {
  FfiNdiOutput({this.onChanged});

  final void Function()? onChanged;

  Isolate? _isolate;
  SendPort? _port;
  ReceivePort? _inbox;
  bool _busyVideo = false;
  int _connections = 0;
  bool? _available;

  @override
  bool get available => _available ??= Ndi.load() != null;

  @override
  String? get unavailableReason => available ? null : Ndi.loadError;

  @override
  int get connections => _connections;

  @override
  Future<void> start({required String name, String? groups}) async {
    if (!available) throw StateError(unavailableReason ?? 'NDI unavailable');
    await stop();
    final inbox = ReceivePort();
    _inbox = inbox;
    final ready = Completer<SendPort>();
    inbox.listen((m) {
      if (m is SendPort) {
        ready.complete(m);
      } else if (m is List && m.isNotEmpty) {
        switch (m[0]) {
          case 'videoDone':
            _busyVideo = false;
          case 'connections':
            if (_connections != m[1]) {
              _connections = m[1] as int;
              onChanged?.call();
            }
          case 'error':
            if (!ready.isCompleted) ready.completeError(StateError('${m[1]}'));
        }
      }
    });
    _isolate = await Isolate.spawn(_ndiIsolate, [inbox.sendPort, name, groups, Ndi.libraryPath], debugName: 'ndi-output');
    _port = await ready.future.timeout(const Duration(seconds: 10));
  }

  @override
  void sendVideo(Uint8List rgba, int width, int height, int fps) {
    final p = _port;
    // Drop frames rather than queueing them if the sender falls behind.
    if (p == null || _busyVideo) return;
    _busyVideo = true;
    p.send(['video', TransferableTypedData.fromList([rgba]), width, height, fps]);
  }

  @override
  void sendAudio(Float32List samples, int sampleRate, int channels) {
    _port?.send(['audio', TransferableTypedData.fromList([samples]), sampleRate, channels]);
  }

  @override
  Future<void> stop() async {
    final p = _port;
    _port = null;
    if (p != null) {
      p.send(['stop']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _inbox?.close();
    _inbox = null;
    _busyVideo = false;
    if (_connections != 0) {
      _connections = 0;
      onChanged?.call();
    }
  }
}

/// Runs in the NDI isolate.
void _ndiIsolate(List<Object?> args) {
  final out = args[0] as SendPort;
  final name = args[1] as String;
  final groups = args[2] as String?;
  Ndi.libraryPath = args[3] as String?;
  final ndi = Ndi.load();
  if (ndi == null) {
    out.send(['error', Ndi.loadError ?? 'NDI unavailable']);
    return;
  }

  final create = calloc<NdiSendCreate>();
  create.ref
    ..pNdiName = name.toNativeUtf8()
    ..pGroups = (groups == null || groups.isEmpty) ? nullptr : groups.toNativeUtf8()
    ..clockVideo = false
    ..clockAudio = false;
  final sender = ndi.sendCreate(create);
  if (sender == nullptr) {
    out.send(['error', 'Could not create the NDI sender']);
    return;
  }

  final video = calloc<NdiVideoFrameV2>();
  final audio = calloc<NdiAudioFrameV2>();
  Pointer<Uint8> vbuf = nullptr;
  var vcap = 0;
  Pointer<Float> abuf = nullptr;
  var acap = 0;

  final inbox = ReceivePort();
  out.send(inbox.sendPort);

  var lastCount = -1;
  final poll = Timer.periodic(const Duration(seconds: 2), (_) {
    final n = ndi.sendGetNoConnections(sender, 0);
    if (n != lastCount) {
      lastCount = n;
      out.send(['connections', n]);
    }
  });

  inbox.listen((m) {
    final msg = m as List;
    switch (msg[0]) {
      case 'video':
        final data = (msg[1] as TransferableTypedData).materialize().asUint8List();
        final w = msg[2] as int, h = msg[3] as int, fps = msg[4] as int;
        if (data.length >= w * h * 4) {
          if (vcap < data.length) {
            if (vbuf != nullptr) calloc.free(vbuf);
            vbuf = calloc<Uint8>(data.length);
            vcap = data.length;
          }
          vbuf.asTypedList(data.length).setAll(0, data);
          video.ref
            ..xres = w
            ..yres = h
            ..fourCC = Ndi.fourCCRgba
            ..frameRateN = fps * 1000
            ..frameRateD = 1000
            ..pictureAspectRatio = w / h
            ..frameFormatType = Ndi.frameFormatProgressive
            ..timecode = Ndi.timecodeSynthesize
            ..pData = vbuf
            ..lineStrideInBytes = w * 4
            ..pMetadata = nullptr
            ..timestamp = 0;
          ndi.sendVideoV2(sender, video);
        }
        out.send(['videoDone']);
      case 'audio':
        final interleaved = (msg[1] as TransferableTypedData).materialize().asFloat32List();
        final rate = msg[2] as int, ch = (msg[3] as int).clamp(1, 8);
        final n = interleaved.length ~/ ch;
        if (n == 0) return;
        if (acap < interleaved.length) {
          if (abuf != nullptr) calloc.free(abuf);
          abuf = calloc<Float>(interleaved.length);
          acap = interleaved.length;
        }
        // NDI v2 audio is planar: de-interleave.
        final planar = abuf.asTypedList(interleaved.length);
        for (var c = 0; c < ch; c++) {
          for (var i = 0; i < n; i++) {
            planar[c * n + i] = interleaved[i * ch + c];
          }
        }
        audio.ref
          ..sampleRate = rate
          ..noChannels = ch
          ..noSamples = n
          ..timecode = Ndi.timecodeSynthesize
          ..pData = abuf
          ..channelStrideInBytes = n * 4
          ..pMetadata = nullptr
          ..timestamp = 0;
        ndi.sendAudioV2(sender, audio);
      case 'stop':
        poll.cancel();
        ndi.sendDestroy(sender);
        if (vbuf != nullptr) calloc.free(vbuf);
        if (abuf != nullptr) calloc.free(abuf);
        calloc.free(video);
        calloc.free(audio);
        calloc.free(create.ref.pNdiName);
        if (create.ref.pGroups != nullptr) calloc.free(create.ref.pGroups);
        calloc.free(create);
        inbox.close();
    }
  });
}
