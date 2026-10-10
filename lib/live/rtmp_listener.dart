import 'dart:typed_data';

import 'rtmp_listener_stub.dart' if (dart.library.io) 'rtmp_listener_io.dart' as impl;

/// One TCP connection to the RTMP input server.
abstract class RtmpConnection {
  Stream<Uint8List> get data;
  String get remoteAddress;
  void write(Uint8List bytes);
  void close();
}

/// Listens for phones and encoders streaming to this tablet.
abstract class RtmpListener {
  bool get supported;

  /// Starts listening on [port] on every network interface.
  Future<void> start(int port, void Function(RtmpConnection connection) onConnection);
  Future<void> stop();

  /// This tablet's IPv4 addresses on Wi-Fi / Ethernet, for the RTMP URL.
  Future<List<String>> localAddresses();
}

RtmpListener createRtmpListener() => impl.createRtmpListener();
