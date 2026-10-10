import 'dart:typed_data';

import 'ndi_input.dart';

NdiReceiverBackend createNdiReceiverBackend() => _NoNdiInput();

class _NoNdiInput implements NdiReceiverBackend {
  @override
  bool get available => false;
  @override
  String? get unavailableReason => 'NDI is available in the Android and iPad apps';
  @override
  Future<List<String>> discover({Duration wait = const Duration(seconds: 3)}) async => const [];
  @override
  NdiReceiverHandle open(
    String name, {
    bool lowBandwidth = false,
    required void Function(Uint8List rgba, int width, int height) onVideo,
    required void Function(Float32List interleaved, int sampleRate, int channels) onAudio,
    required void Function(NdiReceiverState state, String? message) onState,
  }) {
    onState(NdiReceiverState.error, unavailableReason);
    return _Closed();
  }
}

class _Closed implements NdiReceiverHandle {
  @override
  void frameDone() {}
  @override
  void close() {}
}
