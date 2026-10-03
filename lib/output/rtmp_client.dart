// RTMP / RTMPS publisher written in pure Dart (dart:io sockets).
//
// Implements what OBS's rtmp-output needs to publish to Twitch, YouTube,
// Facebook, Kick, nginx-rtmp, etc.: handshake, connect, releaseStream,
// FCPublish, createStream, publish, @setDataFrame, and audio/video messages,
// plus ping/ack handling and congestion-based frame dropping.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'amf0.dart';
import 'flv.dart';
import 'rtmp_chunk.dart';

class RtmpUrl {
  RtmpUrl({
    required this.secure,
    required this.host,
    required this.port,
    required this.app,
    required this.streamKey,
  });

  final bool secure;
  final String host;
  final int port;
  final String app;
  final String streamKey;

  String get tcUrl => '${secure ? 'rtmps' : 'rtmp'}://$host:$port/$app';

  /// Parses `rtmp[s]://host[:port]/app[/...]/streamKey[?query]`. The last path
  /// segment (with any query string) is the stream key; everything before it
  /// is the application name.
  static RtmpUrl parse(String url) {
    final m = RegExp(r'^(rtmps?)://([^/:]+)(?::(\d+))?/(.+)$', caseSensitive: false).firstMatch(url.trim());
    if (m == null) {
      throw const FormatException('Server must look like rtmp://host/app or rtmps://host/app');
    }
    final secure = m.group(1)!.toLowerCase() == 'rtmps';
    final port = m.group(3) != null ? int.parse(m.group(3)!) : (secure ? 443 : 1935);
    final path = m.group(4)!;
    // Split path from query so a '/' inside the query isn't treated as a segment.
    final q = path.indexOf('?');
    final pathOnly = q >= 0 ? path.substring(0, q) : path;
    final query = q >= 0 ? path.substring(q) : '';
    final slash = pathOnly.lastIndexOf('/');
    if (slash <= 0) {
      throw const FormatException('Missing stream key');
    }
    final key = pathOnly.substring(slash + 1) + query;
    if (key.isEmpty) throw const FormatException('Missing stream key');
    return RtmpUrl(
      secure: secure,
      host: m.group(2)!,
      port: port,
      app: pathOnly.substring(0, slash),
      streamKey: key,
    );
  }
}

class RtmpException implements Exception {
  RtmpException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RtmpStats {
  int bytesSent = 0;
  int droppedVideoFrames = 0;
  int sentVideoFrames = 0;
  int queuedBytes = 0;
}

typedef SocketConnector = Future<Socket> Function(String host, int port, bool secure, Duration timeout);

Future<Socket> _defaultConnector(String host, int port, bool secure, Duration timeout) async {
  if (secure) {
    return SecureSocket.connect(host, port, timeout: timeout);
  }
  return Socket.connect(host, port, timeout: timeout);
}

class RtmpPublisher {
  RtmpPublisher(this.url, {SocketConnector? connector, this.maxQueueBytes = 1 << 20})
      : _connector = connector ?? _defaultConnector;

  final RtmpUrl url;
  final SocketConnector _connector;

  /// When more than this many bytes are waiting to be written, non-key video
  /// frames are dropped until the next keyframe (like OBS's "drop frames"
  /// congestion handling).
  int maxQueueBytes;

  final stats = RtmpStats();

  /// Called once if the connection breaks after publishing started.
  void Function(Object error)? onDisconnected;

  Socket? _socket;
  final _writer = RtmpChunkWriter();
  late final RtmpChunkReader _reader = RtmpChunkReader(_onMessage);

  // Handshake state.
  final _handshakeBuf = BytesBuilder();
  Completer<void>? _handshakeDone;
  bool _handshaking = true;

  int _txn = 1;
  final Map<int, Completer<List<Object?>>> _pending = {};
  Completer<void>? _publishStarted;
  int _streamId = 0;

  int _windowAckSize = 2500000;
  int _bytesReceived = 0;
  int _lastAck = 0;

  final _outQueue = ListQueue<Uint8List>();
  bool _writing = false;
  bool _waitForKeyframe = false;
  bool _closed = false;
  bool _published = false;

  bool get isPublishing => _published && !_closed;

  static const _csControl = 2;
  static const _csCommand = 3;
  static const _csAudio = 4;
  static const _csData = 5;
  static const _csVideo = 6;

  /// Connects, handshakes and publishes. Throws [RtmpException] on failure.
  Future<void> connect({Duration timeout = const Duration(seconds: 10)}) async {
    try {
      final socket = await _connector(url.host, url.port, url.secure, timeout);
      _socket = socket;
      socket.setOption(SocketOption.tcpNoDelay, true);
      _handshakeDone = Completer<void>();
      socket.listen(_onData, onError: _onSocketError, onDone: _onSocketDone, cancelOnError: true);

      // C0 + C1
      final c1 = Uint8List(1536);
      final rnd = math.Random();
      for (var i = 8; i < c1.length; i++) {
        c1[i] = rnd.nextInt(256);
      }
      _rawWrite(Uint8List.fromList([3, ...c1]));
      await _handshakeDone!.future.timeout(timeout);

      // Larger outgoing chunks = far less header overhead for video.
      _sendControl(RtmpType.setChunkSize, _u32(4096));
      _writer.chunkSize = 4096;

      final connectResult = await _command('connect', [
        {
          'app': url.app,
          'type': 'nonprivate',
          'flashVer': 'FMLE/3.0 (compatible; ObsPad)',
          'swfUrl': url.tcUrl,
          'tcUrl': url.tcUrl,
        },
      ]).timeout(timeout);
      _checkResult('connect', connectResult);

      _commandNoReply('releaseStream', [null, url.streamKey]);
      _commandNoReply('FCPublish', [null, url.streamKey]);
      final cs = await _command('createStream', [null]).timeout(timeout);
      _checkResult('createStream', cs);
      final sid = cs.length > 3 ? cs[3] : null;
      _streamId = sid is num ? sid.toInt() : 1;

      _publishStarted = Completer<void>();
      _send(_csCommand, RtmpType.commandAmf0, 0, _streamId,
          Amf0.encodeAll(['publish', (_txn++).toDouble(), null, url.streamKey, 'live']));
      await _publishStarted!.future.timeout(timeout);
      _published = true;
    } on RtmpException {
      await close();
      rethrow;
    } on TimeoutException {
      await close();
      throw RtmpException('Timed out connecting to ${url.host}');
    } on SocketException catch (e) {
      await close();
      throw RtmpException('Could not connect to ${url.host}: ${e.message}');
    } on HandshakeException catch (e) {
      await close();
      throw RtmpException('TLS error with ${url.host}: ${e.message}');
    }
  }

  void sendMetadata(Map<String, Object?> meta) {
    _send(_csData, RtmpType.dataAmf0, 0, _streamId, Flv.setDataFrameBody(meta));
  }

  void sendVideoConfig(Uint8List decoderConfigRecord) {
    _send(_csVideo, RtmpType.video, 0, _streamId, Flv.avcSequenceHeader(decoderConfigRecord));
  }

  void sendAudioConfig(Uint8List asc) {
    _send(_csAudio, RtmpType.audio, 0, _streamId, Flv.aacSequenceHeader(asc));
  }

  /// Sends one access unit in AVCC form. Returns false if it was dropped due
  /// to congestion.
  bool sendVideo(Uint8List avcc, int timestampMs, {required bool keyframe, int ctsMs = 0}) {
    if (_closed) return false;
    if (_waitForKeyframe || stats.queuedBytes > maxQueueBytes) {
      if (!keyframe || stats.queuedBytes > maxQueueBytes) {
        _waitForKeyframe = true;
        stats.droppedVideoFrames++;
        return false;
      }
      _waitForKeyframe = false;
    }
    _send(_csVideo, RtmpType.video, timestampMs, _streamId,
        Flv.avcNalu(avcc, keyframe: keyframe, compositionTimeMs: ctsMs));
    stats.sentVideoFrames++;
    return true;
  }

  void sendAudio(Uint8List aacFrame, int timestampMs) {
    if (_closed) return;
    // Audio is tiny; only drop it if the link is badly backed up.
    if (stats.queuedBytes > maxQueueBytes * 4) return;
    _send(_csAudio, RtmpType.audio, timestampMs, _streamId, Flv.aacRaw(aacFrame));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final s = _socket;
    if (s != null && _published) {
      try {
        _commandNoReply('FCUnpublish', [null, url.streamKey]);
        _commandNoReply('deleteStream', [null, _streamId.toDouble()]);
        await _drain().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(RtmpException('Connection closed'));
    }
    _pending.clear();
    try {
      await s?.close();
    } catch (_) {}
    s?.destroy();
  }

  // ---------------------------------------------------------------------------

  Future<void> _drain() async {
    while (_writing || _outQueue.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void _checkResult(String cmd, List<Object?> r) {
    if (r.isEmpty || r[0] != '_result') {
      final info = r.length > 3 ? r[3] : null;
      String desc = '';
      if (info is Map) desc = '${info['code'] ?? ''} ${info['description'] ?? ''}'.trim();
      throw RtmpException('Server rejected $cmd${desc.isEmpty ? '' : ': $desc'}');
    }
  }

  Future<List<Object?>> _command(String name, List<Object?> args) {
    final id = _txn++;
    final c = Completer<List<Object?>>();
    _pending[id] = c;
    _send(_csCommand, RtmpType.commandAmf0, 0, 0, Amf0.encodeAll([name, id.toDouble(), ...args]));
    return c.future;
  }

  void _commandNoReply(String name, List<Object?> args) {
    _send(_csCommand, RtmpType.commandAmf0, 0, 0, Amf0.encodeAll([name, (_txn++).toDouble(), ...args]));
  }

  void _sendControl(int type, Uint8List payload) => _send(_csControl, type, 0, 0, payload);

  void _send(int csid, int type, int ts, int streamId, Uint8List payload) {
    _rawWrite(_writer.encode(RtmpMessage(
      chunkStreamId: csid,
      typeId: type,
      timestamp: ts,
      streamId: streamId,
      payload: payload,
    )));
  }

  void _rawWrite(Uint8List bytes) {
    if (_socket == null) return;
    _outQueue.add(bytes);
    stats.queuedBytes += bytes.length;
    _pump();
  }

  // IOSink forbids add() while a flush is in flight, so writes are queued and
  // coalesced here. The queue length doubles as the congestion signal.
  Future<void> _pump() async {
    if (_writing) return;
    _writing = true;
    try {
      while (_outQueue.isNotEmpty && _socket != null) {
        final b = BytesBuilder(copy: false);
        while (_outQueue.isNotEmpty) {
          b.add(_outQueue.removeFirst());
        }
        final data = b.takeBytes();
        _socket!.add(data);
        await _socket!.flush();
        stats.queuedBytes -= data.length;
        stats.bytesSent += data.length;
      }
    } catch (e) {
      _fail(e);
    } finally {
      _writing = false;
    }
  }

  void _onData(Uint8List data) {
    _bytesReceived += data.length;
    if (_handshaking) {
      _handshakeBuf.add(data);
      if (_handshakeBuf.length < 1 + 1536 + 1536) return;
      final all = _handshakeBuf.takeBytes();
      final s1 = Uint8List.sublistView(all, 1, 1537);
      _handshaking = false;
      _rawWrite(Uint8List.fromList(s1)); // C2 echoes S1
      _handshakeDone?.complete();
      final rest = all.length - 3073;
      if (rest > 0) _reader.add(Uint8List.sublistView(all, 3073));
    } else {
      _reader.add(data);
    }
    if (_bytesReceived - _lastAck >= _windowAckSize) {
      _lastAck = _bytesReceived;
      _sendControl(RtmpType.ack, _u32(_bytesReceived & 0xFFFFFFFF));
    }
  }

  void _onMessage(RtmpMessage m) {
    switch (m.typeId) {
      case RtmpType.windowAckSize:
        if (m.payload.length >= 4) _windowAckSize = ByteData.sublistView(m.payload).getUint32(0);
      case RtmpType.setPeerBandwidth:
        _sendControl(RtmpType.windowAckSize, _u32(_windowAckSize));
      case RtmpType.userControl:
        if (m.payload.length >= 6 && m.payload[1] == 6) {
          // PingRequest -> PingResponse with the same timestamp.
          _sendControl(RtmpType.userControl, Uint8List.fromList([0, 7, ...m.payload.sublist(2, 6)]));
        }
      case RtmpType.commandAmf0:
        _onCommand(m.payload);
    }
  }

  void _onCommand(Uint8List payload) {
    List<Object?> v;
    try {
      v = Amf0.decodeAll(payload);
    } catch (_) {
      return;
    }
    if (v.isEmpty) return;
    final name = v[0];
    if (name == '_result' || name == '_error') {
      final id = (v.length > 1 && v[1] is num) ? (v[1] as num).toInt() : -1;
      _pending.remove(id)?.complete(v);
    } else if (name == 'onStatus') {
      final info = v.length > 3 ? v[3] : null;
      if (info is! Map) return;
      final code = '${info['code']}';
      final level = '${info['level']}';
      final pub = _publishStarted;
      if (code == 'NetStream.Publish.Start') {
        if (pub != null && !pub.isCompleted) pub.complete();
      } else if (level == 'error' || code.contains('BadName') || code.contains('Rejected')) {
        final err = RtmpException('Server refused stream: $code ${info['description'] ?? ''}'.trim());
        if (pub != null && !pub.isCompleted) {
          pub.completeError(err);
        } else {
          _fail(err);
        }
      }
    }
  }

  void _onSocketError(Object e) => _fail(e);

  void _onSocketDone() => _fail(RtmpException('Server closed the connection'));

  void _fail(Object e) {
    if (_closed) return;
    final wasPublished = _published;
    final hs = _handshakeDone;
    if (hs != null && !hs.isCompleted) hs.completeError(RtmpException('Handshake failed: $e'));
    final pub = _publishStarted;
    if (pub != null && !pub.isCompleted) pub.completeError(RtmpException('$e'));
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(RtmpException('$e'));
    }
    _pending.clear();
    _closed = true;
    _socket?.destroy();
    if (wasPublished) onDisconnected?.call(e);
  }

  static Uint8List _u32(int v) =>
      Uint8List.fromList([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
}
