import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/models.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/studio_controller.dart';
import 'package:obs_tablet/main.dart';
import 'package:obs_tablet/output/encoder_backend.dart';
import 'package:obs_tablet/output/output_engine.dart';
import 'package:obs_tablet/plugins/plugin_manager.dart';
import 'package:obs_tablet/render/media_services.dart';

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
  Stream<AudioLevel> get levels => const Stream.empty();
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
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);

    await tester.tap(find.text('Scene').first);
    await tester.pump();
    expect(studio.previewScene.name, 'Scene');
    expect(studio.programScene.name, 'Be Right Back');
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pump(const Duration(seconds: 1));
    expect(studio.programScene.name, 'Scene');
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
