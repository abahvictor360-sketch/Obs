import 'dart:typed_data';

import 'ndi_output_stub.dart' if (dart.library.ffi) 'ndi_output_ffi.dart' as impl;

/// Program output to NDI® (what DistroAV calls "Main Output").
abstract class NdiOutputSink {
  /// Whether the NDI runtime is available on this device/build.
  bool get available;

  /// Why NDI isn't available, if it isn't.
  String? get unavailableReason;

  /// Starts sending as [name] (shown in NDI receivers as "DEVICE (name)").
  Future<void> start({required String name, String? groups});

  /// RGBA (premultiplied is fine for opaque frames) at [fps].
  void sendVideo(Uint8List rgba, int width, int height, int fps);

  /// Mono/interleaved float PCM.
  void sendAudio(Float32List samples, int sampleRate, int channels);

  /// Receivers currently connected (refreshed every couple of seconds).
  int get connections;

  Future<void> stop();
}

NdiOutputSink createNdiOutput({void Function()? onChanged}) => impl.createNdiOutput(onChanged: onChanged);
