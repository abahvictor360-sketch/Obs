import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/browser/browser_page.dart';
import 'package:obs_tablet/browser/browser_source.dart';
import 'package:obs_tablet/core/models.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/studio_controller.dart';
import 'package:obs_tablet/render/slideshow.dart';

class FakePage implements BrowserPage {
  FakePage(this.url, this.width, this.height, this.css);
  final String url, css;
  final int width, height;
  bool started = false, disposed = false;
  int reloads = 0;

  @override
  Future<void> start() async => started = true;
  @override
  Future<Uint8List?> snapshot() async => File('test/fixtures/frame_a.jpg').readAsBytesSync();
  @override
  Future<void> reload() async => reloads++;
  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Image Slide Show clock', () {
    late DateTime now;
    setUp(() {
      now = DateTime(2026);
      SlideShowClock.now = () => now;
    });
    tearDown(() => SlideShowClock.now = DateTime.now);

    Source show({bool loop = true, String transition = 'fade', bool random = false}) => Source(
          id: 'show-$loop-$transition-$random',
          name: 'Slides',
          type: SourceType.imageSlideShow,
          settings: {
            ...SourceDefaults.forType(SourceType.imageSlideShow),
            'paths': ['a.png', 'b.png', 'c.png'],
            'slideMs': 1000,
            'transitionMs': 200,
            'loop': loop,
            'transition': transition,
            'random': random,
          },
        );

    test('advances, fades into the next image, loops', () {
      final s = show();
      var p = SlideShowClock.position(s); // starts the clock
      expect((p.index, p.progress), (0, null));
      now = now.add(const Duration(milliseconds: 900));
      p = SlideShowClock.position(s);
      expect(p.index, 0);
      expect(p.next, 1);
      expect(p.progress, closeTo(0.5, 0.01));
      now = now.add(const Duration(milliseconds: 150));
      expect(SlideShowClock.position(s).index, 1);
      now = now.add(const Duration(milliseconds: 2000)); // 3050 ms
      expect(SlideShowClock.position(s).index, 0, reason: 'loops back to the first image');
      SlideShowClock.skip(s.id, 1);
      expect(SlideShowClock.position(s).index, 1);
      SlideShowClock.restart(s.id);
      expect(SlideShowClock.position(s).index, 0);
    });

    test('cut has no transition; without loop it stops on the last image', () {
      final cut = show(transition: 'cut');
      SlideShowClock.position(cut);
      now = now.add(const Duration(milliseconds: 950));
      expect(SlideShowClock.position(cut).progress, isNull);

      final once = show(loop: false);
      SlideShowClock.position(once);
      now = now.add(const Duration(seconds: 10));
      final p = SlideShowClock.position(once);
      expect((p.index, p.progress), (2, null));
    });

    test('random order is a stable shuffle of every image', () {
      final s = show(random: true);
      final seen = <int>[];
      SlideShowClock.position(s);
      for (var i = 0; i < 3; i++) {
        seen.add(SlideShowClock.position(s).index);
        now = now.add(const Duration(milliseconds: 1000));
      }
      expect(seen.toSet(), {0, 1, 2});
    });
  });

  group('Browser source', () {
    test('pages run while visible in program/preview and are snapshotted', () async {
      final pages = <FakePage>[];
      final service = BrowserSourceService(
        factory: ({required url, required width, required height, required css}) {
          final p = FakePage(url, width, height, css);
          pages.add(p);
          return p;
        },
      );
      final studio = StudioController(storage: MemoryStorage());
      final tracker = BrowserSourceTracker(studio, service);
      final item = studio.addNewSource(SourceType.browser, name: 'Alerts');
      final source = studio.sourceById(item.sourceId)!;
      await pumpEventQueue();
      final page = pages.last;
      expect(page.started, isTrue);
      expect((page.width, page.height), (1280, 720));
      expect(page.css, contains('rgba(0, 0, 0, 0)'));
      expect(service.runningCount, 1);

      await service.debugGrab(source.id);
      final feed = service.feed(source.id)!;
      expect(feed.image, isNotNull);
      expect(feed.image!.width, greaterThan(0));

      // Changing the URL restarts the page; hiding the item shuts it down.
      studio.updateSourceSettings(source.id, {'url': 'https://example.com/chat'});
      await pumpEventQueue();
      expect(page.disposed, isTrue);
      expect(pages.last.url, 'https://example.com/chat');
      studio.setItemVisible(item.id, false);
      await pumpEventQueue();
      expect(service.runningCount, 0);
      expect(pages.last.disposed, isTrue);

      // "Shut down when not visible" off: keeps running while hidden.
      studio.updateSourceSettings(source.id, {'shutdown': false});
      await pumpEventQueue();
      expect(service.runningCount, 1);
      tracker.dispose();
      service.dispose();
    });
  });

  test('audio output capture drives the app-audio gain and is not visual', () {
    final studio = StudioController(storage: MemoryStorage());
    final item = studio.addNewSource(SourceType.audioOutput);
    final s = studio.sourceById(item.sourceId)!;
    expect(SourceType.audioOutput.isVisual, isFalse);
    expect(SourceType.audioOutput.hasAudio, isTrue);
    studio.setVolume(s.id, 0.25);
    expect(studio.screenAudioGain, 0.25);
  });
}
