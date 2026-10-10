import 'rtmp_listener.dart';

RtmpListener createRtmpListener() => _NoListener();

class _NoListener implements RtmpListener {
  @override
  bool get supported => false;
  @override
  Future<void> start(int port, void Function(RtmpConnection connection) onConnection) async =>
      throw UnsupportedError('RTMP input works in the Android and iPad apps');
  @override
  Future<void> stop() async {}
  @override
  Future<List<String>> localAddresses() async => const [];
}
