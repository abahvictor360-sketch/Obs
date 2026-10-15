import 'dart:typed_data';

import 'teleport_net_stub.dart' if (dart.library.io) 'teleport_net_io.dart' as impl;
import 'teleport_protocol.dart';

/// Multicasts a Teleport announcement every second.
abstract class TeleportAnnouncer {
  Future<void> start(TeleportAnnounce announce);
  void stop();
}

/// Listens for Teleport announcements on the network.
abstract class TeleportDiscoverer {
  /// Calls [onAnnounce] for every announcement received.
  Future<void> start(void Function(TeleportAnnounce a) onAnnounce);
  void stop();
}

/// The TCP side of a Teleport sender: receivers connect and get packets.
abstract class TeleportServer {
  /// Listens on [port] (0 = any free port); returns the port.
  Future<int> start(int port);
  int get connections;
  void Function(int connections)? onConnections;

  /// Sends [packet] to every receiver. Video ([droppable]) is skipped for a
  /// receiver that can't keep up, so its sound and picture stay current.
  void send(Uint8List packet, {bool droppable = false});
  Future<void> stop();
}

/// The TCP side of a Teleport receiver.
abstract class TeleportClient {
  Future<void> connect(String address, int port,
      {required void Function(List<int> data) onData, required void Function(Object? error) onDone});
  void close();
}

bool get teleportSupported => impl.supported;

/// This device's IPv4 addresses on its networks.
Future<List<String>> teleportLocalAddresses() => impl.localAddresses();
TeleportAnnouncer createTeleportAnnouncer() => impl.createAnnouncer();
TeleportDiscoverer createTeleportDiscoverer() => impl.createDiscoverer();
TeleportServer createTeleportServer() => impl.createServer();
TeleportClient createTeleportClient() => impl.createClient();
