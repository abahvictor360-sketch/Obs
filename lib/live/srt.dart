// SRT (Secure Reliable Transport) receiving end, listener mode, as phone
// apps (Larix), OBS, vMix, hardware encoders and ffmpeg send it:
// srt://<tablet>:9000?streamid=<key>. Live mode, unencrypted, handshake v5.
// Reliable delivery: ACKs every 10 ms, NAKs for lost packets, in-order
// delivery with a latency window after which a lost packet is skipped.
// Pure Dart: datagrams in, datagrams out; the UDP socket is outside.
// Protocol: https://datatracker.ietf.org/doc/html/draft-sharabayko-srt

import 'dart:math';
import 'dart:typed_data';

/// Sends a datagram to an address.
typedef SrtSend = void Function(Uint8List data, String address, int port);

class SrtControl {
  static const handshake = 0;
  static const keepalive = 1;
  static const ack = 2;
  static const nak = 3;
  static const shutdown = 5;
  static const ackAck = 6;
  static const dropReq = 7;
}

class SrtHandshake {
  static const induction = 1;
  static const conclusion = 0xFFFFFFFF;
  static const magic = 0x4A17;

  // Extension types.
  static const hsReq = 1;
  static const hsRsp = 2;
  static const kmReq = 3;
  static const streamId = 5;

  // Rejection reasons (sent as the handshake type).
  static const rejectBadSecret = 1010;
  static const rejectNotFound = 1404;
  static const rejectVersion = 1008;
}

/// One caller (a phone or encoder) streaming to the tablet.
class SrtConnection {
  SrtConnection._(this._listener, this.address, this.port, this.peerSocketId, this.socketId, this.streamId,
      int initialSeq, this.latencyMs)
      : _expected = initialSeq,
        _start = DateTime.now();

  final SrtListener _listener;
  final String address;
  final int port;
  final int peerSocketId;
  final int socketId;

  /// What the caller asked for (?streamid=...), '' if none.
  final String streamId;
  final int latencyMs;

  final DateTime _start;
  DateTime _lastHeard = DateTime.now();
  int _expected; // next sequence number to deliver
  final Map<int, Uint8List> _buffer = {};
  final Map<int, DateTime> _lost = {}; // missing seq -> when first noticed
  DateTime _lastNak = DateTime.fromMillisecondsSinceEpoch(0);
  int _ackNo = 1;
  int _highest = -1;
  bool closed = false;

  /// Payloads (MPEG-TS) in order.
  void Function(Uint8List payload)? onData;
  void Function(String reason)? onClose;

  int bytesReceived = 0;
  int packetsLost = 0;

  // Echoed in handshake answers.
  int _mtu = 1500;
  int _window = 8192;
  int _cookie = 0;

  int get _now => DateTime.now().difference(_start).inMicroseconds & 0xFFFFFFFF;

  static int _seqDiff(int a, int b) {
    // a - b with 31-bit wrap.
    var d = (a - b) & 0x7FFFFFFF;
    if (d >= 0x40000000) d -= 0x80000000;
    return d;
  }

  static int _seqAdd(int a, int n) => (a + n) & 0x7FFFFFFF;

  void _control(int type, int typeInfo, [List<int> cif = const []]) {
    final b = ByteData(16 + cif.length * 4);
    b.setUint32(0, 0x80000000 | (type << 16));
    b.setUint32(4, typeInfo);
    b.setUint32(8, _now);
    b.setUint32(12, peerSocketId);
    for (var i = 0; i < cif.length; i++) {
      b.setUint32(16 + i * 4, cif[i] & 0xFFFFFFFF);
    }
    _listener.send(b.buffer.asUint8List(), address, port);
  }

  void _onData(int seq, Uint8List packet) {
    _lastHeard = DateTime.now();
    final payload = Uint8List.sublistView(packet, 16);
    bytesReceived += payload.length;
    final ahead = _seqDiff(seq, _expected);
    if (ahead < 0) return; // already delivered (a retransmission we no longer need)
    if (_highest < 0 || _seqDiff(seq, _highest) > 0) {
      // Everything between the previous highest and this one is missing.
      if (_highest >= 0) {
        for (var s = _seqAdd(_highest, 1); _seqDiff(seq, s) > 0; s = _seqAdd(s, 1)) {
          _lost[s] = DateTime.now();
        }
      }
      _highest = seq;
    }
    _lost.remove(seq);
    _buffer[seq] = Uint8List.fromList(payload);
    _deliver();
    if (_lost.isNotEmpty) _sendNak();
  }

  void _deliver() {
    while (true) {
      final p = _buffer.remove(_expected);
      if (p != null) {
        onData?.call(p);
        _expected = _seqAdd(_expected, 1);
        continue;
      }
      // The next packet is missing: wait for it within the latency window,
      // then skip it (like SRT's "too late to play" drop).
      final since = _lost[_expected];
      if (since != null && DateTime.now().difference(since).inMilliseconds > latencyMs) {
        _lost.remove(_expected);
        packetsLost++;
        _expected = _seqAdd(_expected, 1);
        continue;
      }
      break;
    }
  }

  void _sendNak() {
    final now = DateTime.now();
    if (now.difference(_lastNak).inMilliseconds < 20) return;
    _lastNak = now;
    final seqs = _lost.keys.toList()..sort((a, b) => _seqDiff(a, b));
    final cif = <int>[];
    var i = 0;
    while (i < seqs.length && cif.length < 300) {
      var j = i;
      while (j + 1 < seqs.length && _seqDiff(seqs[j + 1], seqs[j]) == 1) {
        j++;
      }
      if (j == i) {
        cif.add(seqs[i]);
      } else {
        cif
          ..add(seqs[i] | 0x80000000)
          ..add(seqs[j]);
      }
      i = j + 1;
    }
    if (cif.isNotEmpty) _control(SrtControl.nak, 0, cif);
  }

  /// Every 10 ms: acknowledge, re-ask for losses, drop what's too late.
  void _tick() {
    if (closed) return;
    if (DateTime.now().difference(_lastHeard) > const Duration(seconds: 5)) {
      close('The phone stopped sending');
      return;
    }
    _deliver();
    // Full ACK: next expected sequence, RTT, RTT var, free buffer, rates.
    _control(SrtControl.ack, _ackNo++, [_expected, 100000, 50000, 8192, 0, 0, 0]);
    if (_lost.isNotEmpty) _sendNak();
  }

  void _onControl(int type, ByteData b, Uint8List packet) {
    _lastHeard = DateTime.now();
    switch (type) {
      case SrtControl.keepalive:
        _control(SrtControl.keepalive, 0);
      case SrtControl.shutdown:
        close('The phone stopped streaming');
      case SrtControl.dropReq:
        // The sender gave up on a range: skip it.
        if (packet.length >= 24) {
          final last = b.getUint32(20) & 0x7FFFFFFF;
          for (final s in _lost.keys.toList()) {
            if (_seqDiff(s, last) <= 0) _lost.remove(s);
          }
          if (_seqDiff(_seqAdd(last, 1), _expected) > 0) {
            for (var s = _expected; _seqDiff(last, s) >= 0; s = _seqAdd(s, 1)) {
              _buffer.remove(s);
            }
            _expected = _seqAdd(last, 1);
          }
          _deliver();
        }
      case SrtControl.handshake:
        // A repeated conclusion (our answer was lost): answer again.
        _listener._answerConclusion(this);
    }
  }

  void close([String reason = 'Closed']) {
    if (closed) return;
    closed = true;
    _control(SrtControl.shutdown, 0, [0]);
    _listener._remove(this);
    onClose?.call(reason);
  }
}

/// Accepts SRT callers on one UDP port.
class SrtListener {
  SrtListener({required this.send, required this.onConnect, this.latencyMs = 120});

  final SrtSend send;

  /// A caller finished the handshake asking for [SrtConnection.streamId];
  /// return null to accept, or a rejection code (see [SrtHandshake]).
  final int? Function(SrtConnection connection) onConnect;

  /// Receiver latency (ms); the larger of this and the caller's is used.
  final int latencyMs;

  final _rnd = Random.secure();
  late final int _secret = _rnd.nextInt(1 << 32);
  final Map<int, SrtConnection> _bySocket = {}; // our socket id -> connection
  final Map<String, SrtConnection> _byPeer = {}; // "addr:port:peerId" -> connection

  Iterable<SrtConnection> get connections => _bySocket.values;

  int _cookie(String address, int port) {
    final minute = DateTime.now().millisecondsSinceEpoch ~/ 60000;
    return Object.hash(address, port, minute, _secret) & 0x7FFFFFFF;
  }

  /// Call every 10 ms.
  void tick() {
    for (final c in _bySocket.values.toList()) {
      c._tick();
    }
  }

  void onDatagram(Uint8List packet, String address, int port) {
    if (packet.length < 16) return;
    final b = ByteData.sublistView(packet);
    final w0 = b.getUint32(0);
    final dest = b.getUint32(12);
    if ((w0 & 0x80000000) == 0) {
      _bySocket[dest]?._onData(w0 & 0x7FFFFFFF, packet);
      return;
    }
    final type = (w0 >> 16) & 0x7FFF;
    if (type == SrtControl.handshake && dest == 0) {
      _handshake(b, packet, address, port);
      return;
    }
    _bySocket[dest]?._onControl(type, b, packet);
  }

  void _handshake(ByteData b, Uint8List packet, String address, int port) {
    if (packet.length < 16 + 48) return;
    const h = 16; // CIF offset
    final version = b.getUint32(h);
    final encryption = b.getUint16(h + 4);
    final initialSeq = b.getUint32(h + 8) & 0x7FFFFFFF;
    final mtu = b.getUint32(h + 12);
    final window = b.getUint32(h + 16);
    final hsType = b.getUint32(h + 20);
    final peerId = b.getUint32(h + 24);
    final cookie = b.getUint32(h + 28);

    if (hsType == SrtHandshake.induction) {
      // Answer with HSv5, the magic extension field and a cookie.
      _sendHandshake(address, port, peerId,
          version: 5,
          encryption: 0,
          extension: SrtHandshake.magic,
          initialSeq: initialSeq,
          mtu: mtu,
          window: window,
          type: SrtHandshake.induction,
          socketId: 0,
          cookie: _cookie(address, port));
      return;
    }
    if (hsType != SrtHandshake.conclusion) return;
    final key = '$address:$port:$peerId';
    final existing = _byPeer[key];
    if (existing != null) {
      _answerConclusion(existing);
      return;
    }
    if (cookie != _cookie(address, port)) return; // stale or forged
    if (version != 5) {
      _reject(address, port, peerId, cookie, SrtHandshake.rejectVersion);
      return;
    }

    // Extensions: HSREQ (latency), KMREQ (encryption), SID (stream id).
    var peerSendLatency = 0;
    var streamId = '';
    var encrypted = encryption != 0;
    var p = h + 48;
    while (p + 4 <= packet.length) {
      final extType = b.getUint16(p);
      final words = b.getUint16(p + 2);
      final start = p + 4;
      final end = start + words * 4;
      if (end > packet.length) break;
      switch (extType) {
        case SrtHandshake.hsReq:
          if (words >= 3) peerSendLatency = b.getUint32(start + 8) & 0xFFFF;
        case SrtHandshake.kmReq:
          encrypted = true;
        case SrtHandshake.streamId:
          // Stored as 32-bit words with each word's bytes reversed.
          final bytes = <int>[];
          for (var i = start; i < end; i += 4) {
            bytes.addAll([packet[i + 3], packet[i + 2], packet[i + 1], packet[i]]);
          }
          while (bytes.isNotEmpty && bytes.last == 0) {
            bytes.removeLast();
          }
          streamId = String.fromCharCodes(bytes);
      }
      p = end;
    }
    if (encrypted) {
      _reject(address, port, peerId, cookie, SrtHandshake.rejectBadSecret);
      return;
    }
    int ourId;
    do {
      ourId = 1 + _rnd.nextInt(0x3FFFFFFE);
    } while (_bySocket.containsKey(ourId));
    final c = SrtConnection._(
        this, address, port, peerId, ourId, streamId, initialSeq, max(latencyMs, peerSendLatency));
    c._mtu = mtu;
    c._window = window;
    c._cookie = cookie;
    final refused = onConnect(c);
    if (refused != null) {
      _reject(address, port, peerId, cookie, refused);
      return;
    }
    _bySocket[ourId] = c;
    _byPeer[key] = c;
    _answerConclusion(c);
  }

  void _answerConclusion(SrtConnection c) {
    final ext = ByteData(16)
      ..setUint16(0, SrtHandshake.hsRsp)
      ..setUint16(2, 3)
      ..setUint32(4, 0x010500) // SRT 1.5.0
      // TSBPD send+receive, crypt capable, too-late drop, periodic NAK, rexmit flag.
      ..setUint32(8, 0x3F)
      ..setUint32(12, (c.latencyMs << 16) | c.latencyMs);
    _sendHandshake(c.address, c.port, c.peerSocketId,
        version: 5,
        encryption: 0,
        extension: 1, // HSRSP
        initialSeq: c._expected,
        mtu: c._mtu,
        window: c._window,
        type: SrtHandshake.conclusion,
        socketId: c.socketId,
        cookie: c._cookie,
        extensions: ext.buffer.asUint8List());
  }

  void _reject(String address, int port, int peerId, int cookie, int code) => _sendHandshake(address, port, peerId,
      version: 5,
      encryption: 0,
      extension: 0,
      initialSeq: 0,
      mtu: 1500,
      window: 8192,
      type: code,
      socketId: 0,
      cookie: cookie);

  void _sendHandshake(String address, int port, int destId,
      {required int version,
      required int encryption,
      required int extension,
      required int initialSeq,
      required int mtu,
      required int window,
      required int type,
      required int socketId,
      required int cookie,
      Uint8List? extensions}) {
    final b = ByteData(16 + 48 + (extensions?.length ?? 0));
    b.setUint32(0, 0x80000000);
    b.setUint32(4, 0);
    b.setUint32(8, 0);
    b.setUint32(12, destId);
    b.setUint32(16, version);
    b.setUint16(20, encryption);
    b.setUint16(22, extension);
    b.setUint32(24, initialSeq);
    b.setUint32(28, mtu);
    b.setUint32(32, window);
    b.setUint32(36, type);
    b.setUint32(40, socketId);
    b.setUint32(44, cookie);
    // Peer IP (bytes 48..63) left zero.
    final out = b.buffer.asUint8List();
    if (extensions != null) out.setRange(64, 64 + extensions.length, extensions);
    send(out, address, port);
  }

  void _remove(SrtConnection c) {
    _bySocket.remove(c.socketId);
    _byPeer.removeWhere((_, v) => v == c);
  }

  void closeAll() {
    for (final c in _bySocket.values.toList()) {
      c.close('Stopped');
    }
  }
}
