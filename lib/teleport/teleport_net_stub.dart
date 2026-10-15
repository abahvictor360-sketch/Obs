import 'dart:typed_data';

import 'teleport_net.dart';
import 'teleport_protocol.dart';

const supported = false;
Future<List<String>> localAddresses() async => const [];
TeleportAnnouncer createAnnouncer() => _NoAnnouncer();
TeleportDiscoverer createDiscoverer() => _NoDiscoverer();
TeleportServer createServer() => _NoServer();
TeleportClient createClient() => _NoClient();

class _NoAnnouncer implements TeleportAnnouncer {
  @override
  Future<void> start(TeleportAnnounce announce) async {}
  @override
  void stop() {}
}

class _NoDiscoverer implements TeleportDiscoverer {
  @override
  Future<void> start(void Function(TeleportAnnounce a) onAnnounce) async {}
  @override
  void stop() {}
}

class _NoServer implements TeleportServer {
  @override
  Future<int> start(int port) => Future.error(UnsupportedError('Teleport needs the Android or iPad app'));
  @override
  int get connections => 0;
  @override
  void Function(int connections)? onConnections;
  @override
  void send(Uint8List packet, {bool droppable = false}) {}
  @override
  Future<void> stop() async {}
}

class _NoClient implements TeleportClient {
  @override
  Future<void> connect(String address, int port,
          {required void Function(List<int> data) onData, required void Function(Object? error) onDone}) =>
      Future.error(UnsupportedError('Teleport needs the Android or iPad app'));
  @override
  void close() {}
}
