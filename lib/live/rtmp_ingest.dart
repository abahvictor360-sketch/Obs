// The receiving end of RTMP: a phone app (Larix, Prism), an encoder (OBS,
// vMix, GoPro, ATEM Mini) or another OBSpad streams to this tablet.
// Pure Dart (no I/O) so it can be tested against the app's own publisher.

import 'dart:math';
import 'dart:typed_data';

import '../output/amf0.dart';
import '../output/rtmp_chunk.dart';

/// One incoming RTMP connection: handshake, connect/createStream/publish,
/// then audio, video and metadata messages.
class RtmpIngestSession {
  RtmpIngestSession({
    required this.send,
    required this.onPublish,
    required this.onMedia,
    required this.onEnd,
  });

  /// Writes bytes to the connection.
  final void Function(Uint8List bytes) send;

  /// A publisher wants stream [key] (from rtmp://host/[app]/[key]); returns
  /// null to accept, or the reason it's refused.
  final String? Function(String app, String key) onPublish;

  /// Audio (8), video (9) and data (18) messages after publishing started.
  final void Function(RtmpMessage message) onMedia;

  /// The publisher stopped (or was refused). Called once.
  final void Function(String? reason) onEnd;

  static const _windowAck = 2500000;
  static const _chunkSize = 4096;
  static const _csControl = 2;
  static const _csCommand = 3;
  static const _csStatus = 5;

  final _writer = RtmpChunkWriter();
  late final RtmpChunkReader _reader = RtmpChunkReader(_onMessage);
  final _hs = BytesBuilder();
  int _stage = 0; // 0: waiting for C0+C1, 1: waiting for C2, 2: chunks
  String _app = '';
  String? key;
  bool _publishing = false;
  bool _ended = false;
  int _bytesIn = 0;
  int _lastAck = 0;
  int _peerWindow = _windowAck;

  bool get publishing => _publishing && !_ended;

  void add(List<int> data) {
    if (_ended) return;
    _bytesIn += data.length;
    if (_stage < 2) {
      _hs.add(data);
      if (_stage == 0) {
        if (_hs.length < 1 + 1536) return;
        final all = _hs.takeBytes();
        if (all[0] != 3) {
          end('Not an RTMP connection');
          return;
        }
        final c1 = Uint8List.sublistView(all, 1, 1537);
        final s1 = Uint8List(1536);
        final rnd = Random();
        for (var i = 8; i < 1536; i++) {
          s1[i] = rnd.nextInt(256);
        }
        send(Uint8List.fromList([3, ...s1, ...c1])); // S0 + S1 + S2 (echo of C1)
        _stage = 1;
        _hs.add(Uint8List.sublistView(all, 1537));
      }
      if (_stage == 1) {
        if (_hs.length < 1536) return;
        final all = _hs.takeBytes();
        _stage = 2;
        if (all.length > 1536) _reader.add(Uint8List.sublistView(all, 1536));
      }
      return;
    }
    _reader.add(data);
    if (_bytesIn - _lastAck >= _peerWindow) {
      _lastAck = _bytesIn;
      _control(RtmpType.ack, _u32(_bytesIn & 0xFFFFFFFF));
    }
  }

  void _control(int type, List<int> payload) => send(_writer.encode(RtmpMessage(
        chunkStreamId: _csControl,
        typeId: type,
        timestamp: 0,
        streamId: 0,
        payload: Uint8List.fromList(payload),
      )));

  void _command(List<Object?> values, {int streamId = 0, int cs = _csCommand}) =>
      send(_writer.encode(RtmpMessage(
        chunkStreamId: cs,
        typeId: RtmpType.commandAmf0,
        timestamp: 0,
        streamId: streamId,
        payload: Amf0.encodeAll(values),
      )));

  static List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

  void _onMessage(RtmpMessage m) {
    if (_ended) return;
    switch (m.typeId) {
      case RtmpType.windowAckSize:
        if (m.payload.length >= 4) _peerWindow = ByteData.sublistView(m.payload).getUint32(0);
      case RtmpType.commandAmf0:
        _onCommand(m);
      case RtmpType.audio:
      case RtmpType.video:
      case RtmpType.dataAmf0:
        if (_publishing) onMedia(m);
    }
  }

  void _onCommand(RtmpMessage m) {
    final List<Object?> v;
    try {
      v = Amf0.decodeAll(m.payload);
    } catch (_) {
      return;
    }
    if (v.isEmpty || v[0] is! String) return;
    final name = v[0] as String;
    final txn = v.length > 1 && v[1] is num ? v[1] as num : 0;
    switch (name) {
      case 'connect':
        final obj = v.length > 2 && v[2] is Map ? v[2] as Map : const {};
        _app = '${obj['app'] ?? ''}';
        _control(RtmpType.windowAckSize, _u32(_windowAck));
        _control(RtmpType.setPeerBandwidth, [..._u32(_windowAck), 2]);
        _control(RtmpType.setChunkSize, _u32(_chunkSize));
        _writer.chunkSize = _chunkSize;
        _command([
          '_result',
          txn,
          {'fmsVer': 'FMS/3,0,1,123', 'capabilities': 31},
          {
            'level': 'status',
            'code': 'NetConnection.Connect.Success',
            'description': 'Connection succeeded.',
            'objectEncoding': 0,
          },
        ]);
      case 'releaseStream':
      case 'FCPublish':
        _command(['_result', txn, null, const Amf0Undefined()]);
      case 'createStream':
        _command(['_result', txn, null, 1]);
      case 'publish':
        var k = v.length > 3 && v[3] is String ? v[3] as String : '';
        final q = k.indexOf('?');
        if (q >= 0) k = k.substring(0, q);
        key = k;
        final refused = onPublish(_app, k);
        if (refused != null) {
          _command([
            'onStatus',
            0,
            null,
            {'level': 'error', 'code': 'NetStream.Publish.BadName', 'description': refused},
          ], streamId: 1, cs: _csStatus);
          end(refused);
          return;
        }
        _control(RtmpType.userControl, [0, 0, 0, 0, 0, 1]); // StreamBegin, stream 1
        _command([
          'onStatus',
          0,
          null,
          {'level': 'status', 'code': 'NetStream.Publish.Start', 'description': 'Publishing $k'},
        ], streamId: 1, cs: _csStatus);
        _publishing = true;
      case 'FCUnpublish':
      case 'deleteStream':
      case 'closeStream':
        end('The phone stopped streaming');
    }
  }

  /// Ends the session (also called when the connection closes).
  void end([String? reason]) {
    if (_ended) return;
    _ended = true;
    _publishing = false;
    onEnd(reason);
  }
}

/// What an FLV video or audio tag body (an RTMP media message) carries.
sealed class FlvPacket {
  const FlvPacket();

  static FlvPacket? parse(RtmpMessage m) {
    final b = m.payload;
    if (b.isEmpty) return null;
    if (m.typeId == RtmpType.video) {
      // Enhanced RTMP (HEVC, AV1, VP9): ExHeader bit set.
      if ((b[0] & 0x80) != 0) return const UnsupportedCodec(video: true);
      final frameType = b[0] >> 4;
      final codec = b[0] & 0x0F;
      if (codec != 7) return const UnsupportedCodec(video: true);
      if (b.length < 5) return null;
      final type = b[1];
      final data = Uint8List.sublistView(b, 5);
      if (type == 0) return AvcConfig(data);
      if (type == 1) return AvcFrame(data, keyframe: frameType == 1, timestampMs: m.timestamp);
      return null;
    }
    if (m.typeId == RtmpType.audio) {
      final format = b[0] >> 4;
      if (format != 10) return const UnsupportedCodec(video: false);
      if (b.length < 2) return null;
      final data = Uint8List.sublistView(b, 2);
      return b[1] == 0 ? AacConfig(data) : AacFrame(data, timestampMs: m.timestamp);
    }
    return null;
  }
}

class AvcConfig extends FlvPacket {
  const AvcConfig(this.record);
  final Uint8List record;
}

class AvcFrame extends FlvPacket {
  const AvcFrame(this.data, {required this.keyframe, required this.timestampMs});
  final Uint8List data;
  final bool keyframe;
  final int timestampMs;
}

class AacConfig extends FlvPacket {
  const AacConfig(this.asc);
  final Uint8List asc;
}

class AacFrame extends FlvPacket {
  const AacFrame(this.data, {required this.timestampMs});
  final Uint8List data;
  final int timestampMs;
}

class UnsupportedCodec extends FlvPacket {
  const UnsupportedCodec({required this.video});
  final bool video;

  String get message => video
      ? 'The phone sends a video format OBSpad can\'t decode. Set its video codec to H.264 (AVC).'
      : 'The phone sends a sound format OBSpad can\'t decode. Set its audio codec to AAC.';
}
