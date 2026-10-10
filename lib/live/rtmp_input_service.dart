import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'rtmp_ingest.dart';
import 'rtmp_listener.dart';

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
  RtmpInputFeed(this.key);

  final String key;
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
  int _bytes = 0;
  DateTime _since = DateTime.now();

  void _changed() => notifyListeners();
}

/// Runs the RTMP server for the "Phone / Encoder (RTMP)" sources on Program
/// or Preview: `rtmp://<tablet>:1935/live/<stream key>`. Video is decoded
/// natively onto a texture; sound goes straight into the stream mix.
class RtmpInputService extends ChangeNotifier {
  RtmpInputService({StreamInDecoder? decoder, RtmpListener? listener, this.port = defaultPort})
      : _decoder = decoder ?? MethodChannelStreamIn(),
        _listener = listener ?? createRtmpListener() {
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
  static const app = 'live';

  final StreamInDecoder _decoder;
  final RtmpListener _listener;
  final int port;

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

  /// Keeps exactly [wanted] (sourceId -> stream key) receiving.
  void sync(Map<String, String> wanted) {
    var changed = false;
    for (final id in _feeds.keys.toList()) {
      if (wanted[id] != _feeds[id]!.key) {
        _remove(id);
        changed = true;
      }
    }
    for (final e in wanted.entries) {
      if (_feeds.containsKey(e.key) || e.value.isEmpty) continue;
      final f = RtmpInputFeed(e.value);
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
    if (_feeds.isNotEmpty && !_listening) _startServer();
    if (_feeds.isEmpty && _listening) _stopServer();
    if (changed) notifyListeners();
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
    super.dispose();
  }
}
