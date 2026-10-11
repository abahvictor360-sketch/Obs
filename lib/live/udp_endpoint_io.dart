import 'dart:io';
import 'dart:typed_data';

import 'udp_endpoint.dart';

UdpEndpoint createUdpEndpoint() => _IoUdp();

class _IoUdp implements UdpEndpoint {
  RawDatagramSocket? _socket;

  @override
  bool get supported => true;

  @override
  Future<void> bind(int port, void Function(Uint8List data, String address, int port) onDatagram) async {
    if (_socket != null) return;
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    // Bursts of video: a bigger receive buffer avoids drops before we read.
    try {
      s.setRawOption(RawSocketOption.fromInt(RawSocketOption.levelSocket,
          Platform.isAndroid ? 8 : 0x1002 /* SO_RCVBUF */, 4 << 20));
    } catch (_) {}
    _socket = s;
    s.listen((e) {
      if (e != RawSocketEvent.read) return;
      while (true) {
        final dg = s.receive();
        if (dg == null) break;
        onDatagram(dg.data, dg.address.address, dg.port);
      }
    });
  }

  @override
  void send(Uint8List data, String address, int port) {
    try {
      _socket?.send(data, InternetAddress(address), port);
    } catch (_) {}
  }

  @override
  void close() {
    _socket?.close();
    _socket = null;
  }
}
