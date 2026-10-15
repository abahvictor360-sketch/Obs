import 'dart:async';
import 'dart:typed_data';

import 'teleport_net.dart';
import 'teleport_protocol.dart';

/// Sends the program to Teleport receivers (OBS with the obs-teleport
/// plugin, or another OBSpad): announces itself on the network, accepts
/// receivers over TCP and sends them JPEG frames and the sound mix.
class TeleportOutput {
  TeleportOutput({TeleportServer? server, TeleportAnnouncer? announcer, this.onChanged})
      : _server = server ?? createTeleportServer(),
        _announcer = announcer ?? createTeleportAnnouncer();

  final TeleportServer _server;
  final TeleportAnnouncer _announcer;
  final void Function()? onChanged;

  /// Receivers connected; frames are only made while there is one.
  void Function(int receivers)? onReceivers;

  bool active = false;
  String name = '';
  int port = 0;
  int sentFrames = 0;

  /// This tablet's addresses, for Teleport's "Manual IP" (address:port).
  List<String> addresses = const [];

  /// Port used when none is set, so a Manual IP typed into OBS keeps working.
  static const defaultPort = 43210;
  final _clock = Stopwatch();

  int get receivers => _server.connections;
  bool get supported => teleportSupported;

  Future<void> start({required String name, int port = 0}) async {
    await stop();
    _server.onConnections = (n) {
      onReceivers?.call(n);
      onChanged?.call();
    };
    try {
      this.port = await _server.start(port == 0 ? defaultPort : port);
    } on Object {
      if (port != 0) rethrow;
      this.port = await _server.start(0); // the usual port is taken
    }
    addresses = await teleportLocalAddresses();
    this.name = name;
    _clock
      ..reset()
      ..start();
    sentFrames = 0;
    await _announcer.start(TeleportAnnounce(name: name, port: this.port));
    active = true;
    onChanged?.call();
  }

  int get _nowNs => _clock.elapsedMicroseconds * 1000;

  void sendJpeg(Uint8List jpeg) {
    if (!active || _server.connections == 0) return;
    _server.send(teleportJpegPacket(_nowNs, jpeg), droppable: true);
    sentFrames++;
  }

  void sendAudio(Float32List samples, int sampleRate, int channels) {
    if (!active || _server.connections == 0 || channels <= 0) return;
    // The chunk started this long ago.
    final durNs = samples.length ~/ channels * 1000000000 ~/ sampleRate;
    final ts = _nowNs - durNs;
    _server.send(teleportWavePacket(ts < 0 ? 0 : ts, samples, sampleRate, channels));
  }

  Future<void> stop() async {
    if (!active) return;
    active = false;
    _announcer.stop();
    await _server.stop();
    _clock.stop();
    onReceivers?.call(0);
    onChanged?.call();
  }
}
