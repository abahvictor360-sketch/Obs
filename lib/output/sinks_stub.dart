import 'sinks.dart';

const bool sinksSupported = false;

PacketSink createRtmpSink(String url) =>
    throw UnsupportedError('Streaming is not available on this platform');

PacketSink createFlvFileSink(String path) =>
    throw UnsupportedError('Recording is not available on this platform');

Future<String> recordingsDirectory() async =>
    throw UnsupportedError('Recording is not available on this platform');
