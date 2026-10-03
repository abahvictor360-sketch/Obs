import 'av_packager.dart';
import 'sinks_stub.dart' if (dart.library.io) 'sinks_io.dart' as impl;

/// An output that consumes FLV packets: a live RTMP connection or a local
/// .flv recording.
abstract class PacketSink implements FlvTarget {
  Future<void> open();
  Future<void> close();
  int get bytesWritten;
  int get droppedFrames;

  /// Set by the engine; invoked if the sink fails after [open] succeeded.
  void Function(Object error)? onError;
}

PacketSink createRtmpSink(String url) => impl.createRtmpSink(url);

PacketSink createFlvFileSink(String path) => impl.createFlvFileSink(path);

Future<String> recordingsDirectory() => impl.recordingsDirectory();

bool get sinksSupported => impl.sinksSupported;
