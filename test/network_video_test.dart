@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/network_video/mjpeg.dart';
import 'package:obs_tablet/network_video/network_video_service.dart';
import 'package:obs_tablet/network_video/transport_io.dart' as transport;

final _a = File('test/fixtures/frame_a.jpg').readAsBytesSync();
final _b = File('test/fixtures/frame_b.jpg').readAsBytesSync();

Uint8List _part(List<int> jpeg, {bool withLength = true}) => Uint8List.fromList([
      ...latin1.encode('--myboundary\r\nContent-Type: image/jpeg\r\n'
          '${withLength ? 'Content-Length: ${jpeg.length}\r\n' : ''}\r\n'),
      ...jpeg,
      ...latin1.encode('\r\n'),
    ]);

void main() {
  group('networkVideoUrl', () {
    test('builds app URLs', () {
      expect(networkVideoUrl({'kind': 'droidcam', 'host': '192.168.1.23'}), 'http://192.168.1.23:4747/video');
      expect(networkVideoUrl({'kind': 'droidcam', 'host': '192.168.1.23', 'resolution': '1280x720'}),
          'http://192.168.1.23:4747/video?1280x720');
      expect(networkVideoUrl({'kind': 'droidcam', 'host': 'http://10.0.0.5:4848/'}), 'http://10.0.0.5:4848/video');
      expect(networkVideoUrl({'kind': 'ipWebcam', 'host': '10.0.0.9'}), 'http://10.0.0.9:8080/video');
      expect(networkVideoUrl({'kind': 'mjpeg', 'url': 'cam.local/mjpg'}), 'http://cam.local/mjpg');
      expect(networkVideoUrl({'kind': 'stream', 'url': 'https://x/y.m3u8'}), 'https://x/y.m3u8');
      expect(networkVideoUrl({'kind': 'droidcam', 'host': ''}), isNull);
    });
  });

  group('MjpegParser', () {
    test('splits multipart streams with and without Content-Length, in any chunking', () {
      final stream = BytesBuilder()
        ..add(latin1.encode('HTTP junk before the first part\r\n'))
        ..add(_part(_a))
        ..add(_part(_b, withLength: false))
        ..add(_part(_a));
      final bytes = stream.takeBytes();
      for (final chunk in [1, 7, 333, 4096, bytes.length]) {
        final frames = <Uint8List>[];
        final p = MjpegParser(frames.add);
        for (var i = 0; i < bytes.length; i += chunk) {
          p.add(bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk));
        }
        expect(frames.map((f) => f.length), [_a.length, _b.length, _a.length], reason: 'chunk $chunk');
        expect(frames[1], _b);
      }
    });

    test('handles raw back-to-back JPEGs', () {
      final frames = <Uint8List>[];
      MjpegParser(frames.add).add([..._b, ..._a, ..._b]);
      expect(frames.length, 3);
      expect(frames[1], _a);
    });
  });

  test('connects to a DroidCam-style server, decodes frames and reconnects', () async {
    var connections = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = <HttpResponse>[];
    server.listen((req) async {
      connections++;
      expect(req.uri.path, '/video');
      final res = req.response
        ..headers.contentType = ContentType('multipart', 'x-mixed-replace', parameters: {'boundary': 'myboundary'})
        ..bufferOutput = false;
      serving.add(res);
      for (var i = 0; i < 6 && serving.isNotEmpty; i++) {
        res.add(_part(i.isEven ? _a : _b));
        await res.flush();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      if (connections == 1) {
        await res.close(); // "phone app restarted"
      }
    });

    final service = NetworkVideoService(opener: transport.openHttpStream);
    service.sync({'src': (NetworkVideoKind.droidcam, 'http://127.0.0.1:${server.port}/video')});
    final feed = service.feed('src')!;

    Future<void> until(bool Function() cond) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!cond() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    await until(() => feed.frame.value != null);
    expect(feed.state, FeedState.live);
    expect((feed.width, feed.height), (160, 90));

    // The first connection ends; the service reconnects by itself.
    await until(() => connections >= 2);
    expect(connections, 2);

    service.sync({});
    expect(service.feed('src'), isNull);
    service.dispose();
    await server.close(force: true);
  });

  test('reports a refused connection in plain words', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final service = NetworkVideoService(opener: transport.openHttpStream);
    service.sync({'src': (NetworkVideoKind.ipWebcam, 'http://127.0.0.1:$port/video')});
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (service.feed('src')!.error == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(service.feed('src')!.error, contains('Connection refused'));
    expect(service.feed('src')!.state, FeedState.retrying);
    service.dispose();
  });
}
