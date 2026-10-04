import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/models.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/studio_controller.dart';
import 'package:obs_tablet/devices/device_service.dart';
import 'package:obs_tablet/main.dart';
import 'package:obs_tablet/network_video/network_video_service.dart';
import 'package:obs_tablet/output/encoder_backend.dart';
import 'package:obs_tablet/output/output_engine.dart';
import 'package:obs_tablet/plugins/plugin_manager.dart';
import 'package:obs_tablet/render/media_services.dart';
import 'package:obs_tablet/core/update_service.dart';
import 'package:obs_tablet/ui/exit.dart';

class FakeEncoder implements EncoderBackend {
  FakeEncoder({this.supported = false});

  final bool supported;
  final frames = <(int, int)>[];
  final overlays = <Map<String, Object?>>[];
  final screen = StreamController<ScreenCaptureState>.broadcast();
  int screenStarts = 0;

  @override
  Future<bool> isSupported() async => supported;
  @override
  Stream<EncodedPacket> get packets => const Stream.empty();
  @override
  Stream<AudioLevel> get levels => levelCtl.stream;
  final levelCtl = StreamController<AudioLevel>.broadcast(sync: true);
  final metering = <bool>[];
  @override
  Future<void> setMetering(bool enabled) async => metering.add(enabled);
  final outputCtl = StreamController<AudioLevel>.broadcast(sync: true);
  final outputMetering = <bool>[];
  @override
  Future<void> setOutputMetering(bool enabled) async => outputMetering.add(enabled);
  @override
  Stream<AudioLevel> get outputLevels => outputCtl.stream;
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Future<void> start(EncoderConfig config) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> pushFrame(Uint8List rgba, int width, int height) async => frames.add((width, height));
  @override
  Future<void> requestKeyframe() async {}
  @override
  Future<void> setMicGain(double gain) async {}
  @override
  Future<void> setScreenAudioGain(double gain) async {}
  @override
  Future<void> setPcmTap(bool enabled) async {}
  @override
  Stream<PcmChunk> get pcm => const Stream.empty();
  @override
  Future<String?> startMp4Recording() async => null;
  @override
  Future<String?> stopMp4Recording() async => null;
  @override
  Future<bool> isScreenCaptureSupported() async => supported;
  @override
  Stream<ScreenCaptureState> get screenStates => screen.stream;
  @override
  Future<void> startScreenCapture() async {
    screenStarts++;
    screen.add(const ScreenCaptureState(active: true, width: 1280, height: 960));
  }

  @override
  Future<void> stopScreenCapture() async => screen.add(const ScreenCaptureState());
  @override
  Future<void> pushOverlays({
    Uint8List? under,
    Uint8List? over,
    bool clearOver = false,
    required int width,
    required int height,
    required ScreenPlacement placement,
  }) async =>
      overlays.add({
        'under': under?.length,
        'over': over?.length,
        'clearOver': clearOver,
        'width': width,
        'height': height,
        'placement': placement,
      });
}

Future<(StudioController, OutputEngine)> _pump(WidgetTester tester, Size size, {EncoderBackend? backend}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final studio = StudioController(storage: MemoryStorage());
  final output = OutputEngine(studio: studio, backend: backend ?? FakeEncoder());
  await output.init();
  await tester.pumpWidget(ObsTabletApp(
    studio: studio,
    output: output,
    cameras: CameraService(),
    media: MediaService(),
    plugins: PluginManager(createPlatformPluginBackend()),
    devices: DeviceService(),
    networkVideo: NetworkVideoService(),
  ));
  await tester.pump();
  return (studio, output);
}

void main() {
  testWidgets('landscape tablet shows all OBS docks', (tester) async {
    await _pump(tester, const Size(1366, 1024));
    for (final t in ['Scenes', 'Sources', 'Audio Mixer', 'Scene Transitions', 'Controls']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Start Streaming'), findsOneWidget);
    expect(find.text('Be Right Back'), findsOneWidget);
    expect(find.text('Mic/Aux'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait tablet uses tabs', (tester) async {
    await _pump(tester, const Size(834, 1194));
    expect(find.widgetWithText(Tab, 'Scenes'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Mixer'), findsOneWidget);
    expect(find.text('Start Recording'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a scene switches program; studio mode shows preview + program', (tester) async {
    final (studio, output) = await _pump(tester, const Size(1366, 1024));
    await tester.tap(find.text('Be Right Back'));
    await tester.pump();
    expect(studio.programScene.name, 'Be Right Back');
    await tester.pump(const Duration(seconds: 1)); // finish transition

    await tester.tap(find.text('Studio Mode'));
    await tester.pump();
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Program'), findsOneWidget);
    expect(find.byKey(const ValueKey('transition-button')), findsOneWidget);
    expect(find.text('Quick Transitions'), findsOneWidget);
    for (final q in ['Cut', 'Fade (300ms)', 'Fade to Black (300ms)']) {
      expect(find.text(q), findsOneWidget, reason: q);
    }

    await tester.tap(find.text('Scene').first);
    await tester.pump();
    expect(studio.previewScene.name, 'Scene');
    expect(studio.programScene.name, 'Be Right Back');
    await tester.tap(find.byKey(const ValueKey('transition-button')));
    await tester.pump(const Duration(seconds: 1));
    expect(studio.programScene.name, 'Scene');

    // Quick transition: Cut swaps right away.
    await tester.tap(find.text('Cut'));
    await tester.pump();
    expect(studio.programScene.name, 'Be Right Back');
    expect(studio.activeTransition, TransitionType.cut);

    // T-bar: half way shows the mix and stays; all the way completes.
    final bar = find.byKey(const ValueKey('t-bar'));
    final box = tester.getRect(bar);
    final gesture = await tester.startGesture(box.centerLeft + const Offset(4, 0));
    await gesture.moveTo(box.center);
    await tester.pump();
    expect(studio.tBar, closeTo(0.5, 0.1));
    expect(studio.programScene.name, 'Be Right Back');
    await gesture.moveTo(box.centerRight + const Offset(20, 0));
    await gesture.up();
    await tester.pump();
    expect(studio.programScene.name, 'Scene');
    expect(studio.tBar, 0);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3)); // autosave
  });

  testWidgets('docks close, reopen from the Docks menu, and resize', (tester) async {
    final (studio, output) = await _pump(tester, const Size(1366, 1024));
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Docks'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('close-dock-sources')));
    await tester.pump();
    expect(studio.settings.hiddenDocks, ['sources']);
    expect(find.byKey(const ValueKey('dock-sources')), findsNothing);

    await tester.tap(find.text('Docks'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-dock-sources')).first);
    await tester.pumpAndSettle();
    expect(studio.settings.hiddenDocks, isEmpty);
    expect(find.byKey(const ValueKey('dock-sources')), findsOneWidget);

    // Drag the gap after Scenes to the right: Scenes gets wider.
    final before = tester.getSize(find.byKey(const ValueKey('dock-scenes'))).width;
    await tester.drag(find.byKey(const ValueKey('dock-gap-scenes')), const Offset(80, 0));
    await tester.pump();
    final after = tester.getSize(find.byKey(const ValueKey('dock-scenes'))).width;
    expect(after, greaterThan(before + 40));

    // Drag the handle above the docks up: the dock row gets taller.
    final h0 = tester.getSize(find.byKey(const ValueKey('dock-scenes'))).height;
    await tester.drag(find.byKey(const ValueKey('dock-height-handle')), const Offset(0, -60));
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('dock-scenes'))).height, greaterThan(h0 + 30));

    // Reset Docks restores the defaults.
    await tester.tap(find.text('Docks'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-reset-docks')).first);
    await tester.pumpAndSettle();
    expect(studio.settings.dockWeights, isEmpty);
    expect(studio.settings.dockHeight, 0);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('new sources are previewed in their properties before they go into the scene', (tester) async {
    final (studio, output) = await _pump(tester, const Size(1366, 1024));
    final itemsBefore = studio.programScene.items.length;
    final sourcesBefore = studio.sources.length;
    for (final label in ['Image Slide Show', 'Browser', 'Audio Output Capture', 'Color Source', 'Audio Input Capture']) {
      await tester.tap(find.byTooltip('Add source'));
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget, reason: label);
      await tester.tapAt(const Offset(5, 5)); // close the sheet
      await tester.pumpAndSettle();
    }

    Future<void> addColor() async {
      await tester.tap(find.byTooltip('Add source'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Color Source'));
      await tester.pumpAndSettle();
      if (find.text('Create new').evaluate().isNotEmpty) {
        await tester.tap(find.text('Create new'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }

    // Cancel: the source never reaches the scene.
    await addColor();
    expect(find.byKey(const ValueKey('source-preview')), findsOneWidget);
    expect(find.textContaining('nothing goes live'), findsOneWidget);
    final staged = studio.programScene.items.last;
    expect(staged.visible, isFalse);
    expect(studio.inspectedSourceId, staged.sourceId);
    await tester.tap(find.byKey(const ValueKey('properties-cancel')));
    await tester.pumpAndSettle();
    expect(studio.programScene.items, hasLength(itemsBefore));
    expect(studio.sources, hasLength(sourcesBefore));
    expect(studio.inspectedSourceId, isNull);

    // Add: it shows up.
    await addColor();
    await tester.tap(find.byKey(const ValueKey('properties-add')));
    await tester.pumpAndSettle();
    expect(studio.programScene.items, hasLength(itemsBefore + 1));
    expect(studio.programScene.items.last.visible, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the Mic/Aux meter is live while idle, not only when streaming', (tester) async {
    final enc = FakeEncoder(supported: true);
    final (studio, output) = await _pump(tester, const Size(1366, 1024), backend: enc);
    expect(studio.collection.sources.any((s) => s.type == SourceType.audioInput), isTrue);
    expect(enc.metering, [true]);
    expect(output.isStreaming || output.isRecording, isFalse);

    enc.levelCtl.add(const AudioLevel(0.3, 0.7));
    await tester.pump();
    expect(output.micLevel.rms, 0.3);
    expect(output.micLevel.peak, 0.7);

    // Off in the background, back on when the app returns.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(enc.metering.last, isFalse);
    expect(output.micLevel.rms, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(enc.metering.last, isTrue);

    // Desktop audio / video sources: the meter follows what the tablet plays.
    final had = studio.collection.sources.any((s) =>
        s.type == SourceType.media || s.type == SourceType.audioOutput || s.type == SourceType.screen);
    if (!had) expect(enc.outputMetering, isEmpty);
    studio.addNewSource(SourceType.audioOutput);
    await tester.pump();
    expect(enc.outputMetering.last, isTrue);
    enc.outputCtl.add(const AudioLevel(0.2, 0.5));
    await tester.pump();
    expect(output.outputLevel.peak, 0.5);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('A newer build shows an update banner until Later', (tester) async {
    final saved = UpdateService.instance;
    final updates = UpdateService(
      currentBuild: 21,
      fetch: () async => {
        'tag_name': 'build-22',
        'html_url': 'https://github.com/abahvictor360-sketch/Obs/releases/tag/build-22',
        'assets': [
          {'name': 'obspad.apk', 'browser_download_url': 'https://example.com/obspad.apk'},
        ],
      },
    );
    UpdateService.instance = updates;
    addTearDown(() => UpdateService.instance = saved);

    await _pump(tester, const Size(1366, 1024));
    expect(find.byKey(const ValueKey('update-banner')), findsNothing);
    await tester.runAsync(updates.check);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('update-banner')), findsOneWidget);
    expect(find.textContaining('build 22'), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('update-banner')), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Exit asks first, then saves and closes; About names the developer', (tester) async {
    await _pump(tester, const Size(1366, 1024));
    var exited = 0;
    debugExitOverride = () async => exited++;
    addTearDown(() => debugExitOverride = null);

    await tester.ensureVisible(find.byKey(const ValueKey('exit-button')));
    await tester.tap(find.byKey(const ValueKey('exit-button')));
    await tester.pumpAndSettle();
    expect(find.text('Exit OBSpad?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'No'));
    await tester.pumpAndSettle();
    expect(exited, 0);

    await tester.ensureVisible(find.byKey(const ValueKey('exit-button')));
    await tester.tap(find.byKey(const ValueKey('exit-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Exit')));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(exited, 1);

    // File › Exit opens the same confirmation.
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-exit')).first);
    await tester.pumpAndSettle();
    expect(find.text('Exit OBSpad?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'No'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Help'));
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    if (find.text('About OBSpad').evaluate().isEmpty) {
      // The first tap only closed the File menu.
      await tester.tap(find.text('Help'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('About OBSpad'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('about-dialog')), findsOneWidget);
    expect(find.text('Victor Abah'), findsOneWidget);
    expect(find.text('www.victorabah.com'), findsOneWidget);
    expect(find.textContaining('Version 1.0.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('dragging on the canvas moves the selected item', (tester) async {
    final (studio, output) = await _pump(tester, const Size(1366, 1024));
    final title = studio.editingScene.items.firstWhere((i) => studio.sourceById(i.sourceId)!.type == SourceType.text);
    studio.selectItem(title.id);
    await tester.pump();
    final x0 = title.transform.x;

    // The program view's RepaintBoundary covers exactly the displayed canvas.
    final ro = output.programKey.currentContext!.findRenderObject()! as RenderBox;
    final canvasBox = ro.localToGlobal(Offset.zero) & ro.size;
    final scale = canvasBox.width / 1920;
    final start = canvasBox.topLeft + Offset(title.transform.centerX * scale, title.transform.centerY * scale);
    await tester.dragFrom(start, const Offset(80, 0));
    await tester.pump();
    expect(title.transform.x, greaterThan(x0 + 40 / scale));
    await tester.pump(const Duration(seconds: 1)); // flush autosave timer
  });

  testWidgets('starting a stream without a server explains what to do', (tester) async {
    await _pump(tester, const Size(1366, 1024));
    await tester.tap(find.text('Start Streaming'));
    await tester.pump();
    expect(find.text('Add your stream server and key first.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('settings screen opens and edits the server', (tester) async {
    final (studio, output) = await _pump(tester, const Size(1366, 1024));
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Stream Key'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Server'), 'rtmp://example.com/live');
    await tester.enterText(find.widgetWithText(TextField, 'Stream Key'), 'secret');
    expect(studio.settings.publishUrl, 'rtmp://example.com/live/secret');
    unawaited(studio.save());
  });

  testWidgets('picking Facebook Live in Settings leaves only the stream key', (tester) async {
    final (studio, output) = await _pump(tester, const Size(1366, 1024));
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Server'), findsOneWidget);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Facebook Live').last);
    await tester.pumpAndSettle();
    expect(studio.settings.service, 'Facebook Live');
    expect(find.widgetWithText(TextField, 'Server'), findsNothing);
    expect(find.byKey(const ValueKey('preset-server-note')), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Stream Key'), 'rtmps://live-api-s.facebook.com:443/rtmp/FB-42-x');
    await tester.pump();
    expect(studio.settings.streamKey, 'FB-42-x');
    expect(studio.settings.publishUrl, 'rtmps://live-api-s.facebook.com:443/rtmp/FB-42-x');
    unawaited(studio.save());
  });

  testWidgets('screen capture source switches the output to native compositing', (tester) async {
    final enc = FakeEncoder(supported: true);
    final (studio, output) = await _pump(tester, const Size(1366, 1024), backend: enc);

    // Put a Screen Capture source under the title (index 2 of 4).
    final screen = studio.addNewSource(SourceType.screen);
    studio.moveItem(screen.id, OrderMove.down);
    await tester.pump(const Duration(seconds: 1));
    expect(studio.screenItemIndex(studio.programScene), 2);
    expect(find.textContaining('Screen capture is off'), findsOneWidget);

    await tester.runAsync(() async {
      await output.debugStartEncoder();
      await output.debugCaptureFrame();
    });
    expect(enc.frames, isEmpty);
    expect(enc.overlays, hasLength(1));
    final first = enc.overlays.single;
    expect(first['under'], 1280 * 720 * 4);
    expect(first['over'], 1280 * 720 * 4);
    expect(first['clearOver'], false);
    expect(first['placement'], const ScreenPlacement(x: 0, y: 0, width: 1280, height: 720));

    // The under layer holds the live camera, so it refreshes at ~15 fps; the
    // static title layer above is not read back again.
    await tester.runAsync(output.debugCaptureFrame);
    expect(enc.overlays, hasLength(2));
    expect(enc.overlays.last['under'], isNotNull);
    expect(enc.overlays.last['over'], isNull);
    expect(enc.overlays.last['clearOver'], false);

    // With the camera hidden, an unchanged scene needs no readback at all.
    final camera = studio.programScene.items.firstWhere((i) => studio.sourceById(i.sourceId)!.type == SourceType.camera);
    studio.setItemVisible(camera.id, false);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(output.debugCaptureFrame); // picks up the change
    final n = enc.overlays.length;
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(output.debugCaptureFrame);
    }
    expect(enc.overlays, hasLength(n));

    // Moving the screen item sends the new placement.
    studio.updateTransform(screen.id, (t) => t.x = 960, persist: true);
    await tester.pump();
    await tester.runAsync(output.debugCaptureFrame);
    expect(enc.overlays, hasLength(n + 1));
    expect((enc.overlays.last['placement']! as ScreenPlacement).x, 640);

    // Starting capture updates the on-canvas status card.
    await tester.tap(find.byTooltip('Start screen capture'));
    await tester.pump();
    expect(enc.screenStarts, 1);
    expect(find.textContaining('Capturing your screen'), findsOneWidget);

    // Hiding the screen source goes back to plain frames.
    studio.setItemVisible(screen.id, false);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(output.debugCaptureFrame);
    expect(enc.frames, hasLength(1));
  });
}
