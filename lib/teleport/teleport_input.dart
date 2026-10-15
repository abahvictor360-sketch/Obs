import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'teleport_net.dart';
import 'teleport_protocol.dart';

/// "Name:Address" shows as "Name (Address)"; "host:port" as is.
String teleportDisplayName(String target) {
  final i = target.lastIndexOf(':');
  if (i <= 0 || RegExp(r'^\d{1,5}$').hasMatch(target.substring(i + 1))) return target;
  return '${target.substring(0, i)} (${target.substring(i + 1)})';
}

enum TeleportInputState { searching, connecting, connected, lost }

/// Live state of one Teleport source.
class TeleportFeed extends ChangeNotifier {
  TeleportFeed(this.target);

  /// "Name:Address" of a discovered sender, or "host:port".
  final String target;
  ui.Image? image;
  TeleportInputState state = TeleportInputState.searching;
  String? message;
  int width = 0, height = 0;
  double fps = 0;

  int _frames = 0;
  DateTime _since = DateTime.now();

  void _set(ui.Image img) {
    final old = image;
    image = img;
    width = img.width;
    height = img.height;
    _frames++;
    final s = DateTime.now().difference(_since).inMilliseconds;
    if (s >= 1000) {
      fps = _frames * 1000 / s;
      _frames = 0;
      _since = DateTime.now();
    }
    if (state != TeleportInputState.connected) state = TeleportInputState.connected;
    notifyListeners();
    if (old != null) Timer(const Duration(milliseconds: 200), old.dispose);
  }

  void _state(TeleportInputState s, [String? msg]) {
    if (state == s && message == msg) return;
    state = s;
    message = msg;
    notifyListeners();
  }

  void _clear() {
    image?.dispose();
    image = null;
  }
}

class _Rx {
  _Rx(this.target, this.feed);
  final String target;
  final TeleportFeed feed;
  TeleportClient? client;
  TeleportReader reader = TeleportReader();
  bool decoding = false;
  bool closed = false;
  Timer? retry;
}

/// Receives the Teleport sources that are on Program or Preview: senders
/// are found by their announcements (OBS with obs-teleport, or OBSpad's
/// Teleport Output), video becomes an image for the canvas and sound goes to
/// [onAudio] (the stream mix).
class TeleportInputService extends ChangeNotifier {
  TeleportInputService({TeleportDiscoverer? discoverer, TeleportClient Function()? client, this.onAudio})
      : _discoverer = discoverer ?? createTeleportDiscoverer(),
        _newClient = client ?? createTeleportClient;

  final TeleportDiscoverer _discoverer;
  final TeleportClient Function() _newClient;

  /// Sound of source [id]: interleaved float PCM.
  void Function(String id, Float32List pcm, int sampleRate, int channels)? onAudio;

  /// Discovery started or stopped (Android needs a multicast lock).
  void Function(bool listening)? onDiscovery;

  bool get supported => teleportSupported;

  final Map<String, (TeleportAnnounce, DateTime)> _peers = {};
  final Map<String, _Rx> _rx = {};
  bool _listening = false;
  int _watchers = 0;
  Timer? _expire;
  String? discoveryError;

  /// Senders seen in the last 5 seconds (like Teleport), by "Name:Address".
  List<TeleportAnnounce> get senders {
    final now = DateTime.now();
    return [
      for (final e in _peers.values)
        if (now.difference(e.$2) < const Duration(seconds: 5)) e.$1,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  TeleportFeed? feed(String sourceId) => _rx[sourceId]?.feed;

  /// Keeps listening for senders while a properties sheet shows the list.
  void watch() {
    _watchers++;
    _updateDiscovery();
  }

  void unwatch() {
    _watchers = (_watchers - 1).clamp(0, 1 << 30);
    _updateDiscovery();
  }

  void _updateDiscovery() {
    final want = _watchers > 0 || _rx.values.any((r) => _isName(r.target));
    if (want == _listening) return;
    _listening = want;
    onDiscovery?.call(want);
    if (want) {
      discoveryError = null;
      _discoverer.start(_onAnnounce).catchError((Object e) {
        discoveryError = 'Can\'t listen for Teleport senders: $e';
        notifyListeners();
      });
      _expire = Timer.periodic(const Duration(seconds: 2), (_) => notifyListeners());
    } else {
      _discoverer.stop();
      _expire?.cancel();
      _expire = null;
    }
  }

  /// A target is a discovered sender ("Name:Address") unless it parses as
  /// host:port and no sender has that key.
  bool _isName(String target) => _peers.containsKey(target) || !RegExp(r'^[^:\s]+:\d{1,5}$').hasMatch(target);

  void _onAnnounce(TeleportAnnounce a) {
    final isNew = !_peers.containsKey(a.key);
    _peers[a.key] = (a, DateTime.now());
    if (isNew) notifyListeners();
    // Sources waiting for this sender connect now.
    for (final e in _rx.entries) {
      final r = e.value;
      if (r.target == a.key && r.client == null && r.retry == null) _connect(e.key, r);
    }
  }

  /// Keeps exactly [wanted] (sourceId -> target) connected.
  void sync(Map<String, String> wanted) {
    var changed = false;
    for (final id in _rx.keys.toList()) {
      if (wanted[id] != _rx[id]!.target) {
        _close(id);
        changed = true;
      }
    }
    for (final e in wanted.entries) {
      if (_rx.containsKey(e.key) || e.value.isEmpty) continue;
      final r = _Rx(e.value, TeleportFeed(e.value));
      _rx[e.key] = r;
      _connect(e.key, r);
      changed = true;
    }
    _updateDiscovery();
    if (changed) notifyListeners();
  }

  (String, int)? _address(String target) {
    final peer = _peers[target]?.$1;
    if (peer != null) return (peer.address, peer.port);
    final m = RegExp(r'^([^:\s]+):(\d{1,5})$').firstMatch(target.trim());
    if (m != null) return (m.group(1)!, int.parse(m.group(2)!));
    return null;
  }

  void _connect(String id, _Rx r) {
    r.retry?.cancel();
    r.retry = null;
    if (r.closed) return;
    final addr = _address(r.target);
    if (addr == null) {
      r.feed._state(TeleportInputState.searching);
      return; // connects when the sender is announced
    }
    r.feed._state(TeleportInputState.connecting);
    final client = _newClient();
    r.client = client;
    r.reader = TeleportReader();
    client.connect(addr.$1, addr.$2, onData: (data) => _onData(id, r, data), onDone: (e) {
      if (r.closed || r.client != client) return;
      r.client = null;
      r.feed._state(TeleportInputState.lost, e == null ? 'The sender stopped' : '$e');
      _scheduleRetry(id, r);
    }).catchError((Object e) {
      if (r.closed || r.client != client) return;
      r.client = null;
      r.feed._state(TeleportInputState.lost, 'Could not connect: $e');
      _scheduleRetry(id, r);
    });
  }

  void _scheduleRetry(String id, _Rx r) {
    r.retry?.cancel();
    r.retry = Timer(const Duration(seconds: 2), () {
      r.retry = null;
      _connect(id, r);
    });
  }

  void _onData(String id, _Rx r, List<int> data) {
    if (r.closed) return;
    final List<TeleportPacket> packets;
    try {
      packets = r.reader.add(data);
    } catch (e) {
      r.client?.close();
      r.client = null;
      r.feed._state(TeleportInputState.lost, 'Not a Teleport sender');
      _scheduleRetry(id, r);
      return;
    }
    for (final p in packets) {
      switch (p) {
        case TeleportAudio(:final samples, :final sampleRate, :final channels):
          onAudio?.call(id, samples, sampleRate, channels);
        case TeleportVideo(:final jpeg):
          // Decode one frame at a time; newer frames replace waiting ones.
          if (r.decoding) continue;
          r.decoding = true;
          _decode(jpeg).then((img) {
            r.decoding = false;
            if (img == null) return;
            if (r.closed) {
              img.dispose();
              return;
            }
            r.feed._set(img);
          });
      }
    }
  }

  static Future<ui.Image?> _decode(Uint8List jpeg) async {
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  void _close(String id) {
    final r = _rx.remove(id);
    if (r == null) return;
    r.closed = true;
    r.retry?.cancel();
    r.client?.close();
    r.feed._clear();
  }

  @override
  void dispose() {
    for (final id in _rx.keys.toList()) {
      _close(id);
    }
    _watchers = 0;
    _updateDiscovery();
    super.dispose();
  }
}
