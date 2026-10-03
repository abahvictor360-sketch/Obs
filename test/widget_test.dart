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
import 'package:obs_tablet/render/media_services.dart';

class FakeEncoder implements EncoderBackend {
  @override
  Future<bool> isSupported() async => false;
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
  Future<void> pushFrame(Uint8List rgba, int width, int height) async {}
  @override
  Future<void> requestKeyframe() async {}
  @override
  Future<void> setMicGain(double gain) async {}
  @override
  Future<String?> startMp4Recording() async => null;
  @override
  Future<String?> stopMp4Recording() async => null;
}

Future<(StudioController, OutputEngine)> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final studio = StudioController(storage: MemoryStorage());
  final output = OutputEngine(studio: studio, backend: FakeEncoder());
  await output.init();
  await tester.pumpWidget(ObsTabletApp(
    studio: studio,
    output: output,
    cameras: CameraService(),
    media: MediaService(),
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
}
