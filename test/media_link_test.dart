@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/ui/media_import.dart';
import 'package:obs_tablet/ui/media_link.dart';
import 'package:obs_tablet/ui/media_link_io.dart';

void main() {
  test('share links become direct downloads; streaming sites are explained', () {
    expect(MediaLink.parse('https://drive.google.com/file/d/1AbCdEfGhIjKlMnOp/view?usp=sharing').url.toString(),
        'https://drive.usercontent.google.com/download?id=1AbCdEfGhIjKlMnOp&export=download&confirm=t');
    expect(MediaLink.parse('https://drive.google.com/open?id=1AbCdEfGhIjKlMnOp').url!.queryParameters['id'],
        '1AbCdEfGhIjKlMnOp');
    expect(MediaLink.parse('https://www.dropbox.com/scl/fi/x/intro.mp4?rlkey=k&dl=0').url!.queryParameters,
        {'rlkey': 'k', 'dl': '1'});
    expect(MediaLink.parse('example.com/clip.mp4').url.toString(), 'https://example.com/clip.mp4');
    expect(MediaLink.parse('https://www.youtube.com/watch?v=abc').problem, contains('YouTube'));
    expect(MediaLink.parse('https://youtu.be/abc').url, isNull);
    expect(MediaLink.parse('ftp://x/y').problem, isNotNull);
  });

  test('downloads the file with its name; a web page instead of a file is refused', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/file') {
        res.headers
          ..contentType = ContentType('video', 'mp4')
          ..set('content-disposition', 'attachment; filename="Sunday intro.mp4"');
        res.contentLength = 100000;
        res.add(List.filled(100000, 7));
      } else {
        res.headers.contentType = ContentType.html;
        res.write('<html>sign in</html>');
      }
      await res.close();
    });
    final dir = await Directory.systemTemp.createTemp('media');
    final base = 'http://127.0.0.1:${server.port}';
    try {
      final steps = <double?>[];
      final path = await downloadMedia(Uri.parse('$base/file'), MediaKind.video,
          progress: steps.add, cancel: CancelToken(), directory: dir.path);
      expect(path, '${dir.path}/Sunday intro.mp4');
      expect(File(path!).lengthSync(), 100000);
      expect(steps.last, 1.0);
      // Same name again: kept unique.
      final again = await downloadMedia(Uri.parse('$base/file'), MediaKind.video,
          progress: (_) {}, cancel: CancelToken(), directory: dir.path);
      expect(again, '${dir.path}/Sunday intro (2).mp4');

      await expectLater(
        downloadMedia(Uri.parse('$base/page'), MediaKind.video,
            progress: (_) {}, cancel: CancelToken(), directory: dir.path),
        throwsA(predicate((e) => '$e'.contains('web page'))),
      );
    } finally {
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });
}
