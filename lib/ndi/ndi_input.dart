import 'dart:typed_data';

import 'ndi_input_stub.dart' if (dart.library.ffi) 'ndi_input_ffi.dart' as impl;

/// Receiving NDI® sources (the NDI Source input). The FFI implementation
/// runs the NDI receiver in its own isolate.
abstract class NdiReceiverBackend {
  /// Whether the NDI runtime is available on this device/build.
  bool get available;

  /// Why NDI isn't available, if it isn't.
  String? get unavailableReason;

  /// Names of the NDI senders seen on the network within [wait]
  /// ("MACHINE (Source)").
  Future<List<String>> discover({Duration wait = const Duration(seconds: 3)});

  /// Connects to the sender called [name]. Video arrives as RGBA; call
  /// [NdiReceiverHandle.frameDone] after each frame to get the next one
  /// (frames in between are dropped). Audio arrives as interleaved float.
  NdiReceiverHandle open(
    String name, {
    bool lowBandwidth = false,
    required void Function(Uint8List rgba, int width, int height) onVideo,
    required void Function(Float32List interleaved, int sampleRate, int channels) onAudio,
    required void Function(NdiReceiverState state, String? message) onState,
  });
}

enum NdiReceiverState { searching, connected, lost, error }

abstract class NdiReceiverHandle {
  void frameDone();
  void close();
}

NdiReceiverBackend createNdiReceiverBackend() => impl.createNdiReceiverBackend();
