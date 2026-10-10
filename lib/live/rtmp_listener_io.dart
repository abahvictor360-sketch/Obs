import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'rtmp_listener.dart';

RtmpListener createRtmpListener() => _IoListener();

class _IoListener implements RtmpListener {
  ServerSocket? _server;

  @override
  bool get supported => true;

  @override
  Future<void> start(int port, void Function(RtmpConnection connection) onConnection) async {
    if (_server != null) return;
    final s = await ServerSocket.bind(InternetAddress.anyIPv4, port, shared: true);
    _server = s;
    s.listen((socket) {
      socket.setOption(SocketOption.tcpNoDelay, true);
      onConnection(_IoConnection(socket));
    });
  }

  @override
  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close();
  }

  @override
  Future<List<String>> localAddresses() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      // Wi-Fi and Ethernet first; mobile data and VPN interfaces last.
      int rank(NetworkInterface i) {
        final n = i.name.toLowerCase();
        if (n.startsWith('wlan') || n.startsWith('en') || n.startsWith('eth')) return 0;
        if (n.startsWith('rmnet') || n.startsWith('pdp') || n.startsWith('tun') || n.startsWith('utun')) return 2;
        return 1;
      }

      list.sort((a, b) => rank(a).compareTo(rank(b)));
      return [
        for (final i in list)
          for (final a in i.addresses)
            if (!a.isLinkLocal) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }
}

class _IoConnection implements RtmpConnection {
  _IoConnection(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get data => _socket;

  @override
  String get remoteAddress {
    try {
      return _socket.remoteAddress.address;
    } catch (_) {
      return '';
    }
  }

  @override
  void write(Uint8List bytes) {
    try {
      _socket.add(bytes);
    } catch (_) {}
  }

  @override
  void close() {
    try {
      _socket.destroy();
    } catch (_) {}
  }
}
