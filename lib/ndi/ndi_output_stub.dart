import 'dart:typed_data';

import 'ndi_output.dart';

NdiOutputSink createNdiOutput({void Function()? onChanged}) => _NoNdi();

class _NoNdi implements NdiOutputSink {
  @override
  bool get available => false;
  @override
  String? get unavailableReason => 'NDI is available in the Android and iPad apps';
  @override
  Future<void> start({required String name, String? groups}) async {}
  @override
  void sendVideo(Uint8List rgba, int width, int height, int fps) {}
  @override
  void sendAudio(Float32List samples, int sampleRate, int channels) {}
  @override
  int get connections => 0;
  @override
  Future<void> stop() async {}
}
