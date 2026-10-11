import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mpegts.dart';
import 'rtmp_ingest.dart';
import 'rtmp_listener.dart';
import 'srt.dart';
import 'udp_endpoint.dart';

/// Native H.264 / AAC decoders for RTMP input (StreamInPlugin.kt/.swift).
abstract class StreamInDecoder {
  /// Starts a decoder for [id]; returns its Flutter texture id.
  Future<int?> open(String id);
  void videoConfig(String id, Uint8List avcc);
  void video(String id, Uint8List data, {required bool keyframe});
  void audioConfig(String id, Uint8List asc);
  void audio(String id, Uint8List data);
  void close(String id);

  /// Decoded picture size of [id] (from the native side).
  void Function(String id, int width, int height)? onSize;
  void Function(String id, String message)? onError;
}

class MethodChannelStreamIn implements StreamInDecoder {
  MethodChannelStreamIn() {
    _ch.setMethodCallHandler((call) async {
      final a = (call.arguments as Map?) ?? const {};
      final id = a['id'] as String? ?? '';
      switch (call.method) {
        case 'videoSize':
          onSize?.call(id, (a['width'] as num?)?.toInt() ?? 0, (a['height'] as num?)?.toInt() ?? 0);
        case 'error':
          onError?.call(id, '${a['message']}');
      }
      return null;
    });
  }

  static const _ch = MethodChannel('obs_tablet/stream_in');

  @override
  void Function(String id, int width, int height)? onSize;
  @override
  void Function(String id, String message)? onError;

  void _call(String method, Map<String, Object> args) => _ch.invokeMethod(method, args).catchError((_) => null);

  @override
  Future<int?> open(String id) async {
    try {
      final r = await _ch.invokeMethod<Map>('open', {'id': id});
      return (r?['textureId'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  @override
  void videoConfig(String id, Uint8List avcc) => _call('videoConfig', {'id': id, 'avcc': avcc});
  @override
  void video(String id, Uint8List data, {required bool keyframe}) =>
      _call('video', {'id': id, 'data': data, 'key': keyframe});
  @override
  void audioConfig(String id, Uint8List asc) => _call('audioConfig', {'id': id, 'asc': asc});
  @override
  void audio(String id, Uint8List data) => _call('audio', {'id': id, 'data': data});
  @override
  void close(String id) => _call('close', {'id': id});
}

enum RtmpInputState { waiting, live, error }

/// Live state of one "Phone / Encoder (RTMP)" source.
class RtmpInputFeed extends ChangeNotifier {
  RtmpInputFeed(this.key, {this.protocol = 'rtmp'});

  final String key;

  /// 'rtmp' or 'srt'.
  final String protocol;
  int? textureId;
  RtmpInputState state = RtmpInputState.waiting;
  String? message;

  /// Who is streaming (their IP address).
  String? from;
  int width = 0, height = 0;
  double kbps = 0;
  bool hasVideo = false;
  bool hasAudio = false;

  RtmpIngestSession? _session;
  RtmpConnection? _connection;
  SrtConnection? _srt;
  int _bytes = 0;
  DateTime _since = DateTime.now();

  void _changed() => notifyListeners();
}

/// Runs the servers for the "Phone / Encoder" sources on Program or
/// Preview: RTMP (`rtmp://<tablet>:1935/live/<stream key>`) and SRT
/// (`srt://<tablet>:9000?streamid=<stream key>`). Video is decoded natively
/// onto a texture; sound goes straight into the stream mix.
class RtmpInputService extends ChangeNotifier {
  RtmpInputService({
    StreamInDecoder? decoder,
    RtmpListener? listener,
    UdpEndpoint? udp,
    this.port = defaultPort,
    this.srtPort = defaultSrtPort,
  })  : _decoder = decoder ?? MethodChannelStreamIn(),
        _listener = listener ?? createRtmpListener(),
        _udp = udp ?? createUdpEndpoint() {
    _decoder.onSize = (id, w, h) {
      final f = _feeds[id];
      if (f == null) return;
      f
        ..width = w
        ..height = h;
      f._changed();
    };
    _decoder.onError = (id, message) {
      final f = _feeds[id];
      if (f == null) return;
      f.message = message;
      f._changed();
    };
  }

  static const defaultPort = 1935;
  static const defaultSrtPort = 9000;
  static const app = 'live';

  final StreamInDecoder _decoder;
  final RtmpListener _listener;
  final UdpEndpoint _udp;
  final int port;
  final int srtPort;
  SrtListener? _srt;
  Timer? _srtTimer;
  bool _srtStarting = false;
  String? srtError;

  final Map<String, RtmpInputFeed> _feeds = {};
  bool _listening = false;
  bool _disposed = false;
  String? serverError;
  List<String> addresses = const [];
  Timer? _rate;

  bool get supported => _listener.supported;

  RtmpInputFeed? feed(String sourceId) => _feeds[sourceId];

  /// The address to type into the phone app, e.g. rtmp://192.168.1.20:1935/live
  String get serverUrl => 'rtmp://${addresses.isEmpty ? '<tablet IP>' : addresses.first}:$port/$app';

  /// The SRT address for stream [key], e.g. srt://192.168.1.20:9000?streamid=cam1
  String srtUrl(String key) =>
      'srt://${addresses.isEmpty ? '<tablet IP>' : addresses.first}:$srtPort?streamid=${Uri.encodeQueryComponent(key)}';

  /// Keeps exactly [wanted] (sourceId -> stream key) receiving over RTMP,
  /// and [srt] (sourceId -> stream key) over SRT.
  void sync(Map<String, String> wanted, {Map<String, String> srt = const {}}) {
    final all = <String, (String, String)>{
      for (final e in wanted.entries) e.key: ('rtmp', e.value),
      for (final e in srt.entries) e.key: ('srt', e.value),
    };
    var changed = false;
    for (final id in _feeds.keys.toList()) {
      final f = _feeds[id]!;
      if (all[id] != (f.protocol, f.key)) {
        _remove(id);
        changed = true;
      }
    }
    for (final e in all.entries) {
      if (_feeds.containsKey(e.key) || e.value.$2.isEmpty) continue;
      final f = RtmpInputFeed(e.value.$2, protocol: e.value.$1);
      _feeds[e.key] = f;
      _decoder.open(e.key).then((tid) {
        if (_disposed || _feeds[e.key] != f) {
          if (tid != null) _decoder.close(e.key);
          return;
        }
        f.textureId = tid;
        f._changed();
        notifyListeners();
      });
      changed = true;
    }
    final rtmpWanted = _feeds.values.any((f) => f.protocol == 'rtmp');
    final srtWanted = _feeds.values.any((f) => f.protocol == 'srt');
    if (rtmpWanted && !_listening) _startServer();
    if (!rtmpWanted && _listening) _stopServer();
    if (srtWanted && _srt == null && !_srtStarting) _startSrt();
    if (!srtWanted && _srt != null) _stopSrt();
    if (changed) notifyListeners();
  }

  Future<void> _startSrt() async {
    _srtStarting = true;
    srtError = null;
    unawaited(refreshAddresses());
    final listener = SrtListener(send: _udp.send, onConnect: _onSrtConnect, latencyMs: 200);
    try {
      await _udp.bind(srtPort, listener.onDatagram);
      _srtStarting = false;
      if (_disposed || !_feeds.values.any((f) => f.protocol == 'srt')) {
        _udp.close();
        return;
      }
      _srt = listener;
      _srtTimer = Timer.periodic(const Duration(milliseconds: 10), (_) => listener.tick());
      _rate ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } catch (e) {
      _srtStarting = false;
      if (_disposed) return;
      srtError = 'Could not open SRT port $srtPort: $e';
    }
    notifyListeners();
  }

  void _stopSrt() {
    _srtTimer?.cancel();
    _srtTimer = null;
    _srt?.closeAll();
    _srt = null;
    _udp.close();
  }

  /// A phone or encoder connected over SRT: route it by its stream id.
  int? _onSrtConnect(SrtConnection c) {
    final srtFeeds = _feeds.entries.where((e) => e.value.protocol == 'srt').toList();
    var match = srtFeeds.where((e) => e.value.key == c.streamId).firstOrNull;
    // Apps that can't set a stream id: the only SRT source takes it.
    if (match == null && c.streamId.isEmpty && srtFeeds.length == 1) match = srtFeeds.single;
    if (match == null) return SrtHandshake.rejectNotFound;
    if (match.value._srt != null && !match.value._srt!.closed) return SrtHandshake.rejectNotFound;
    final id = match.key;
    final f = match.value
      .._srt = c
      ..from = c.address
      ..state = RtmpInputState.live
      ..message = null
      ..hasVideo = false
      ..hasAudio = false;
    final demux = TsDemuxer(
      onVideoConfig: (avcc) => _decoder.videoConfig(id, avcc),
      onVideo: (data, key) {
        if (!f.hasVideo) {
          f.hasVideo = true;
          f._changed();
        }
        _decoder.video(id, data, keyframe: key);
      },
      onAudioConfig: (asc) => _decoder.audioConfig(id, asc),
      onAudio: (frame) {
        if (!f.hasAudio) {
          f.hasAudio = true;
          f._changed();
        }
        _decoder.audio(id, frame);
      },
      onUnsupported: (message) {
        f.message = message;
        f._changed();
      },
    );
    c.onData = (payload) {
      if (_feeds[id] != f || f._srt != c) return;
      f._bytes += payload.length;
      demux.add(payload);
    };
    c.onClose = (reason) {
      if (f._srt != c) return;
      f
        .._srt = null
        ..state = RtmpInputState.waiting
        ..message = reason
        ..kbps = 0;
      f._changed();
      notifyListeners();
    };
    f._changed();
    notifyListeners();
    return null;
  }

  Future<void> refreshAddresses() async {
    final list = await _listener.localAddresses();
    if (_disposed) return;
    addresses = list;
    notifyListeners();
  }

  Future<void> _startServer() async {
    _listening = true;
    serverError = null;
    unawaited(refreshAddresses());
    try {
      await _listener.start(port, _onConnection);
      if (_disposed || !_listening) {
        await _listener.stop();
        return;
      }
      _rate ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } catch (e) {
      if (_disposed) return;
      _listening = false;
      serverError = 'Could not open port $port: $e';
    }
    notifyListeners();
  }

  Future<void> _stopServer() async {
    _listening = false;
    _rate?.cancel();
    _rate = null;
    await _listener.stop();
  }

  void _tick() {
    for (final f in _feeds.values) {
      final s = DateTime.now().difference(f._since).inMilliseconds;
      if (s <= 0) continue;
      final kbps = f._bytes * 8 / s;
      f._bytes = 0;
      f._since = DateTime.now();
      if (kbps != f.kbps) {
        f.kbps = kbps;
        f._changed();
      }
    }
  }

  void _onConnection(RtmpConnection c) {
    String? sourceId;
    late final RtmpIngestSession session;
    session = RtmpIngestSession(
      send: c.write,
      onPublish: (app, key) {
        final match = _feeds.entries.where((e) => e.value.key == key).firstOrNull;
        if (match == null) return 'No OBSpad source is waiting for stream key "$key"';
        if (match.value._session?.publishing ?? false) return 'Stream key "$key" is already receiving';
        sourceId = match.key;
        final f = match.value
          .._session = session
          .._connection = c
          ..from = c.remoteAddress
          ..state = RtmpInputState.live
          ..message = null
          ..hasVideo = false
          ..hasAudio = false;
        f._changed();
        notifyListeners();
        return null;
      },
      onMedia: (m) {
        final id = sourceId;
        if (id == null) return;
        final f = _feeds[id];
        if (f == null || f._session != session) return;
        f._bytes += m.payload.length;
        final p = FlvPacket.parse(m);
        switch (p) {
          case AvcConfig(:final record):
            _decoder.videoConfig(id, record);
          case AvcFrame(:final data, :final keyframe):
            if (!f.hasVideo) {
              f.hasVideo = true;
              f._changed();
            }
            _decoder.video(id, data, keyframe: keyframe);
          case AacConfig(:final asc):
            _decoder.audioConfig(id, asc);
          case AacFrame(:final data):
            if (!f.hasAudio) {
              f.hasAudio = true;
              f._changed();
            }
            _decoder.audio(id, data);
          case UnsupportedCodec():
            if (f.message != p.message) {
              f.message = p.message;
              f._changed();
            }
          case null:
            break;
        }
      },
      onEnd: (reason) {
        final f = sourceId == null ? null : _feeds[sourceId];
        if (f != null && f._session == session) {
          f
            .._session = null
            .._connection = null
            ..state = RtmpInputState.waiting
            ..message = reason
            ..kbps = 0;
          f._changed();
          notifyListeners();
        }
        c.close();
      },
    );
    c.data.listen(session.add, onDone: () => session.end('The phone disconnected'), onError: (_) {
      session.end('The connection dropped');
    }, cancelOnError: true);
  }

  void _remove(String id) {
    final f = _feeds.remove(id);
    if (f == null) return;
    f._session?.end();
    f._connection?.close();
    f._srt?.close('Removed');
    if (f.textureId != null) _decoder.close(id);
  }

  @override
  void dispose() {
    _disposed = true;
    _listening = false;
    for (final id in _feeds.keys.toList()) {
      _remove(id);
    }
    _rate?.cancel();
    _listener.stop();
    _stopSrt();
    super.dispose();
  }
}
