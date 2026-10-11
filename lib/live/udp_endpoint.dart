import 'dart:typed_data';

import 'udp_endpoint_stub.dart' if (dart.library.io) 'udp_endpoint_io.dart' as impl;

/// A UDP port for the SRT input.
abstract class UdpEndpoint {
  bool get supported;
  Future<void> bind(int port, void Function(Uint8List data, String address, int port) onDatagram);
  void send(Uint8List data, String address, int port);
  void close();
}

UdpEndpoint createUdpEndpoint() => impl.createUdpEndpoint();
