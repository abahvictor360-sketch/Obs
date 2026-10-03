import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'flv.dart';
import 'rtmp_client.dart';
import 'sinks.dart';

const bool sinksSupported = true;

PacketSink createRtmpSink(String url) => RtmpSink(RtmpUrl.parse(url));

PacketSink createFlvFileSink(String path) => FlvFileSink(path);

Future<String> recordingsDirectory() async {
  Directory? base;
  if (Platform.isAndroid) {
    // App-specific external storage: visible over USB / in Files, no
    // storage permission needed.
    final dirs = await getExternalStorageDirectories(type: StorageDirectory.movies);
    if (dirs != null && dirs.isNotEmpty) base = dirs.first;
  }
  base ??= await getApplicationDocumentsDirectory();
  final d = Directory('${base.path}/Recordings');
  await d.create(recursive: true);
  return d.path;
}

class RtmpSink implements PacketSink {
  RtmpSink(RtmpUrl url) : _pub = RtmpPublisher(url);

  final RtmpPublisher _pub;

  @override
  void Function(Object error)? onError;

  @override
  Future<void> open() async {
    _pub.onDisconnected = (e) => onError?.call(e);
    await _pub.connect();
  }

  @override
  Future<void> close() => _pub.close();

  @override
  int get bytesWritten => _pub.stats.bytesSent;

  @override
  int get droppedFrames => _pub.stats.droppedVideoFrames;

  @override
  void metadata(Map<String, Object?> meta) => _pub.sendMetadata(meta);

  @override
  void videoConfig(Uint8List rec) => _pub.sendVideoConfig(rec);

  @override
  void audioConfig(Uint8List asc) => _pub.sendAudioConfig(asc);

  @override
  bool video(Uint8List avcc, int ms, bool key) => _pub.sendVideo(avcc, ms, keyframe: key);

  @override
  void audio(Uint8List frame, int ms) => _pub.sendAudio(frame, ms);
}

/// Writes an .flv file. Works on every platform with dart:io; used when MP4
/// muxing isn't available natively (or when the user picks FLV, which, like
/// OBS's MKV, survives crashes better than MP4).
class FlvFileSink implements PacketSink {
  FlvFileSink(this.path);

  final String path;
  IOSink? _out;
  int _bytes = 0;

  @override
  void Function(Object error)? onError;

  @override
  Future<void> open() async {
    _out = File(path).openWrite();
    _write(Flv.fileHeader());
    _out!.done.catchError((Object e) => onError?.call(e));
  }

  void _write(Uint8List b) {
    _out?.add(b);
    _bytes += b.length;
  }

  @override
  Future<void> close() async {
    final o = _out;
    _out = null;
    await o?.flush();
    await o?.close();
  }

  @override
  int get bytesWritten => _bytes;

  @override
  int get droppedFrames => 0;

  @override
  void metadata(Map<String, Object?> meta) =>
      _write(Flv.fileTag(Flv.tagScript, 0, Flv.onMetaDataFileBody(meta)));

  @override
  void videoConfig(Uint8List rec) => _write(Flv.fileTag(Flv.tagVideo, 0, Flv.avcSequenceHeader(rec)));

  @override
  void audioConfig(Uint8List asc) => _write(Flv.fileTag(Flv.tagAudio, 0, Flv.aacSequenceHeader(asc)));

  @override
  bool video(Uint8List avcc, int ms, bool key) {
    _write(Flv.fileTag(Flv.tagVideo, ms, Flv.avcNalu(avcc, keyframe: key)));
    return true;
  }

  @override
  void audio(Uint8List frame, int ms) => _write(Flv.fileTag(Flv.tagAudio, ms, Flv.aacRaw(frame)));
}
