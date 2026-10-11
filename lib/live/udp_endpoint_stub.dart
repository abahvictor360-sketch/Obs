import 'dart:typed_data';

import 'udp_endpoint.dart';

UdpEndpoint createUdpEndpoint() => _NoUdp();

class _NoUdp implements UdpEndpoint {
  @override
  bool get supported => false;
  @override
  Future<void> bind(int port, void Function(Uint8List data, String address, int port) onDatagram) async =>
      throw UnsupportedError('SRT input works in the Android and iPad apps');
  @override
  void send(Uint8List data, String address, int port) {}
  @override
  void close() {}
}
