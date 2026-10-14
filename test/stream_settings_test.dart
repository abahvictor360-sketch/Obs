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

  test('Telegram and Instagram ask for their own server and key', () {
    for (final service in ['Telegram', 'Instagram Live']) {
      final s = OutputSettings(service: service, server: 'rtmps://dc4-1.rtmp.t.me/s/', streamKey: '123:abc');
      expect(s.usesPresetServer, isFalse);
      expect(s.publishUrl, 'rtmps://dc4-1.rtmp.t.me/s/123:abc');
    }
  });

  test('automatic recording bitrate follows the output size and never drops below the stream', () {
    expect(OutputSettings(outputHeight: 720, fps: 30).effectiveRecordingKbps, 8000);
    expect(OutputSettings(outputWidth: 1920, outputHeight: 1080, fps: 60).effectiveRecordingKbps, 22500);
    expect(OutputSettings(videoBitrateKbps: 12000).effectiveRecordingKbps, 12000);
    expect(OutputSettings(recordingBitrateKbps: 25000).effectiveRecordingKbps, 25000);
    expect(OutputSettings(recordingBitrateKbps: -1, videoBitrateKbps: 3000).effectiveRecordingKbps, 3000);
    expect(OutputSettings.fromJson(OutputSettings(recordingBitrateKbps: 15000).toJson()).recordingBitrateKbps, 15000);
  });
}
