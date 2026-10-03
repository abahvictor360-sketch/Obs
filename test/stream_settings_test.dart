import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/models.dart';

void main() {
  test('Facebook Live only needs the stream key', () {
    final s = OutputSettings(service: 'Facebook Live', server: 'stale-or-empty');
    expect(s.usesPresetServer, isTrue);
    expect(s.publishUrl, '', reason: 'no key yet: cannot stream');
    s.streamKey = 'FB-123-abc';
    expect(s.publishUrl, 'rtmps://live-api-s.facebook.com:443/rtmp/FB-123-abc');
  });

  test('a pasted full URL is reduced to the key', () {
    final s = OutputSettings(service: 'Facebook Live');
    expect(s.keyFromPasted('rtmps://live-api-s.facebook.com:443/rtmp/FB-9-xyz'), 'FB-9-xyz');
    expect(s.keyFromPasted('rtmps://live-api-s.facebook.com/rtmp/FB-9-xyz'), 'FB-9-xyz');
    expect(s.keyFromPasted('  live_123_abc  '), 'live_123_abc');
    expect(s.keyFromPasted('rtmp://live.twitch.tv/app/live_1'), 'live_1');
  });

  test('custom servers still use the server field', () {
    final s = OutputSettings(service: 'Custom', server: 'rtmp://192.168.1.5/live', streamKey: 'cam');
    expect(s.usesPresetServer, isFalse);
    expect(s.publishUrl, 'rtmp://192.168.1.5/live/cam');
    s.streamKey = '';
    expect(s.publishUrl, 'rtmp://192.168.1.5/live');
  });
}
