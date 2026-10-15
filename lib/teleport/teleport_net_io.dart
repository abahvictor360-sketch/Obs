import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'teleport_net.dart';
import 'teleport_protocol.dart';

const supported = true;
Future<List<String>> localAddresses() async => [for (final a in await _interfaceAddresses()) a.address];
TeleportAnnouncer createAnnouncer() => _Announcer();
TeleportDiscoverer createDiscoverer() => _Discoverer();
TeleportServer createServer() => _Server();
TeleportClient createClient() => _Client();

final _group = InternetAddress(kTeleportMulticastGroup);

/// IPv4 addresses of the network interfaces (Wi-Fi, Ethernet, USB tethering).
Future<List<InternetAddress>> _interfaceAddresses() async {
  try {
    final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final i in list)
        for (final a in i.addresses)
          if (!a.isLoopback) a,
    ];
  } catch (_) {
    return const [];
  }
}

class _Announcer implements TeleportAnnouncer {
  final _sockets = <RawDatagramSocket>[];
  Timer? _timer;

  @override
  Future<void> start(TeleportAnnounce announce) async {
    stop();
    final payload = announce.encode();
    // One socket per interface so the announcement reaches every network the
    // tablet is on (like peerdiscovery, which sends on each interface).
    for (final a in await _interfaceAddresses()) {
      try {
        final s = await RawDatagramSocket.bind(a, 0);
        s.multicastHops = 2;
        try {
          s.setRawOption(RawSocketOption(
              RawSocketOption.levelIPv4, RawSocketOption.IPv4MulticastInterface, Uint8List.fromList(a.rawAddress)));
        } catch (_) {}
        _sockets.add(s);
      } catch (_) {}
    }
    if (_sockets.isEmpty) {
      try {
        _sockets.add(await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)..multicastHops = 2);
      } catch (_) {}
    }
    void send() {
      for (final s in _sockets) {
        try {
          s.send(payload, _group, kTeleportDiscoveryPort);
        } catch (_) {}
      }
    }

    send();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => send());
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    for (final s in _sockets) {
      s.close();
    }
    _sockets.clear();
  }
}

class _Discoverer implements TeleportDiscoverer {
  RawDatagramSocket? _socket;

  @override
  Future<void> start(void Function(TeleportAnnounce a) onAnnounce) async {
    if (_socket != null) return;
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kTeleportDiscoveryPort,
        reuseAddress: true, reusePort: !Platform.isWindows && !Platform.isAndroid);
    s.multicastLoopback = true;
    var joined = false;
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4).catchError((_) => <NetworkInterface>[])) {
      try {
        s.joinMulticast(_group, i);
        joined = true;
      } catch (_) {}
    }
    if (!joined) s.joinMulticast(_group);
    _socket = s;
    s.listen((e) {
      if (e != RawSocketEvent.read) return;
      while (true) {
        final dg = s.receive();
        if (dg == null) break;
        final a = TeleportAnnounce.decode(dg.data, dg.address.address);
        if (a != null) onAnnounce(a);
      }
    });
  }

  @override
  void stop() {
    _socket?.close();
    _socket = null;
  }
}

class _Receiver {
  _Receiver(this.socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    done = socket.addStream(_out.stream).catchError((_) {});
  }

  final Socket socket;
  final _out = StreamController<List<int>>();
  late final Future<void> done;

  /// The socket can't take more right now (its send buffer is full).
  bool get busy => _out.isPaused;

  void add(Uint8List b) => _out.add(b);

  Future<void> close() async {
    await _out.close();
    socket.destroy();
  }
}

class _Server implements TeleportServer {
  ServerSocket? _server;
  final _receivers = <_Receiver>[];

  @override
  void Function(int connections)? onConnections;

  @override
  int get connections => _receivers.length;

  @override
  Future<int> start(int port) async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, port, shared: true);
    _server = server;
    server.listen((socket) {
      final r = _Receiver(socket);
      _receivers.add(r);
      onConnections?.call(_receivers.length);
      // Receivers never send anything; their stream ends when they leave.
      socket.listen((_) {}, onError: (_) => _drop(r), onDone: () => _drop(r), cancelOnError: true);
      r.done.whenComplete(() => _drop(r));
    });
    return server.port;
  }

  void _drop(_Receiver r) {
    if (!_receivers.remove(r)) return;
    r.close();
    onConnections?.call(_receivers.length);
  }

  @override
  void send(Uint8List packet, {bool droppable = false}) {
    for (final r in List.of(_receivers)) {
      if (droppable && r.busy) continue;
      r.add(packet);
    }
  }

  @override
  Future<void> stop() async {
    for (final r in List.of(_receivers)) {
      await r.close();
    }
    _receivers.clear();
    await _server?.close();
    _server = null;
  }
}

class _Client implements TeleportClient {
  Socket? _socket;
  StreamSubscription<List<int>>? _sub;

  @override
  Future<void> connect(String address, int port,
      {required void Function(List<int> data) onData, required void Function(Object? error) onDone}) async {
    close();
    final s = await Socket.connect(address, port, timeout: const Duration(seconds: 3));
    _socket = s;
    _sub = s.listen(onData, onError: (Object e) => onDone(e), onDone: () => onDone(null), cancelOnError: true);
  }

  @override
  void close() {
    _sub?.cancel();
    _sub = null;
    _socket?.destroy();
    _socket = null;
  }
}
