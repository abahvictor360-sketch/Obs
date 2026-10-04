import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/update_service.dart';

Map<String, dynamic> release(String tag) => {
      'tag_name': tag,
      'html_url': 'https://github.com/abahvictor360-sketch/Obs/releases/tag/$tag',
      'published_at': '2026-10-04T12:00:00Z',
      'assets': [
        {'name': 'obspad-unsigned.ipa', 'browser_download_url': 'https://example.com/obspad-unsigned.ipa'},
        {'name': 'obspad.apk', 'browser_download_url': 'https://example.com/obspad.apk'},
      ],
    };

void main() {
  test('parses build releases and picks the right download', () {
    final u = UpdateInfo.fromRelease(release('build-22'))!;
    expect(u.build, 22);
    expect(u.downloadUrl(TargetPlatform.android), 'https://example.com/obspad.apk');
    expect(u.downloadUrl(TargetPlatform.iOS), contains('/releases/tag/build-22'));
    expect(UpdateInfo.fromRelease(release('v1.0')), isNull);
  });

  test('reports only newer builds, and Later hides that build', () async {
    var tag = 'build-21';
    final s = UpdateService(currentBuild: 21, fetch: () async => release(tag));
    expect(await s.check(), isNull);
    expect(s.shouldNotify, isFalse);

    tag = 'build-22';
    expect((await s.check())!.build, 22);
    expect(s.shouldNotify, isTrue);
    s.dismiss();
    expect(s.shouldNotify, isFalse);

    tag = 'build-23';
    await s.check();
    expect(s.shouldNotify, isTrue);
  });

  test('development builds never check on their own', () {
    var calls = 0;
    final s = UpdateService(currentBuild: null, fetch: () async {
      calls++;
      return release('build-99');
    });
    s.start(firstCheck: Duration.zero);
    expect(calls, 0);
  });
}
