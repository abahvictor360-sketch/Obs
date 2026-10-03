import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/studio_controller.dart';
import 'package:obs_tablet/devices/device_service.dart';
import 'package:obs_tablet/main.dart';
import 'package:obs_tablet/network_video/network_video_service.dart';
import 'package:obs_tablet/output/external_display_output.dart';
import 'package:obs_tablet/output/output_engine.dart';
import 'package:obs_tablet/plugins/plugin_manager.dart';
import 'package:obs_tablet/render/multiview.dart';
import 'package:obs_tablet/render/media_services.dart';

import 'widget_test.dart' show FakeEncoder;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('obs_tablet/devices');
  const events = EventChannel('obs_tablet/device_events');
  const framesChannel = 'obs_tablet/display_frames';
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Map<String, Object?> dock;
  late List<(int, int, int)> frames;
  MockStreamHandlerEventSink? sink;

  const screen = {'name': 'HDMI', 'width': 1920, 'height': 1080, 'refreshRate': 60.0, 'presenting': true};

  setUp(() {
    calls = [];
    frames = [];
    dock = {'display': screen, 'ethernet': true, 'usbAudio': false, 'usbVideo': false, 'usbDevices': 1, 'charging': true};
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getNetwork':
          return {'transport': 'ethernet', 'wiredAvailable': true, 'preferWired': true, 'canPreferWired': true};
        case 'getDock':
          return dock;
        case 'setDisplayMode':
          final program = (call.arguments as Map)['mode'] != 'mirror';
          return {
            ...dock,
            'display': {...screen, 'presenting': program},
          };
        case 'listUsbCameras':
        case 'listAudioInputs':
          return const [];
      }
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (args, s) {
        sink = s;
      }, onCancel: (args) {
        sink = null;
      }),
    );
    messenger.setMockMessageHandler(framesChannel, (ByteData? msg) async {
      final w = msg!.getUint32(0, Endian.little);
      final h = msg.getUint32(4, Endian.little);
      frames.add((w, h, msg.lengthInBytes - 8));
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(events, null);
    messenger.setMockMessageHandler(framesChannel, null);
  });

  test('a dock is recognised from what comes through it', () {
    expect(const DockInfo().docked, isFalse);
    expect(const DockInfo(charging: true).docked, isFalse);
    expect(const DockInfo(usbDevices: 1).docked, isFalse);
    expect(const DockInfo(ethernet: true).docked, isTrue);
    expect(const DockInfo(usbDevices: 3).docked, isTrue);
    expect(const DockInfo(usbAudio: true, usbVideo: true).docked, isTrue);
    final d = DockInfo.fromMap({
      'display': {'name': 'DELL U2723', 'width': 2560, 'height': 1440, 'presenting': true},
      'charging': true,
    });
    expect(d.docked, isTrue);
    expect(d.display!.width, 2560);
    expect(d.features, ['Screen', 'Charging']);
  });

  test('dock state follows native events; the display mode setting is applied', () async {
    final devices = DeviceService();
    await devices.init();
    expect(devices.dock.docked, isTrue);
    expect(devices.dock.display!.presenting, isTrue);

    final studio = StudioController(storage: MemoryStorage());
    final tracker = DeviceActivityTracker(studio, devices);
    await pumpEventQueue();
    expect(calls.where((c) => c.method == 'setDisplayMode').map((c) => (c.arguments as Map)['mode']), ['program']);

    studio.updateSettings((s) => s.externalDisplay = 'mirror');
    await pumpEventQueue();
    expect(calls.last.method, 'setDisplayMode');
    expect((calls.last.arguments as Map)['mode'], 'mirror');
    expect(devices.dock.display!.presenting, isFalse);

    // Unplugging the dock.
    sink!.success({'type': 'dock', 'ethernet': false, 'usbDevices': 0});
    await pumpEventQueue();
    expect(devices.dock.docked, isFalse);
    expect(devices.dock.display, isNull);
    tracker.dispose();
  });

  testWidgets('program goes to the connected screen; dock chip and panel', (tester) async {
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final studio = StudioController(storage: MemoryStorage());
    final output = OutputEngine(studio: studio, backend: FakeEncoder());
    await output.init();
    final devices = DeviceService();
    await tester.runAsync(devices.init);
    final tracker = DeviceActivityTracker(studio, devices);
    final display = ExternalDisplayOutput(output: output, devices: devices);
    await tester.pumpWidget(ObsTabletApp(
      studio: studio,
      output: output,
      cameras: CameraService(),
      media: MediaService(),
      plugins: PluginManager(createPlatformPluginBackend()),
      devices: devices,
      networkVideo: NetworkVideoService(),
    ));
    await tester.pump();

    expect(find.text('Docked · Program'), findsOneWidget);

    // The encoder isn't running, so the display captures the program itself,
    // sized for the screen.
    expect(output.pumpingProgramFrames, isFalse);
    await tester.runAsync(display.debugTick);
    expect(frames, hasLength(1));
    expect(frames.single.$1, 1920);
    expect(frames.single.$2, 1080);
    expect(frames.single.$3, 1920 * 1080 * 4);

    // Panel: switch to Multiview, then to mirroring.
    expect(find.byType(Multiview), findsNothing);
    await tester.tap(find.byKey(const ValueKey('dock-chip')));
    await tester.pumpAndSettle();
    expect(find.text('Docking station connected'), findsOneWidget);
    expect(find.text('HDMI · 1920×1080'), findsOneWidget);
    await tester.tap(find.text('Multiview'));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(studio.settings.externalDisplay, 'multiview');
    expect(find.text('Docked · Multiview'), findsOneWidget);
    expect(find.byType(Multiview), findsOneWidget);
    expect(find.text('Program · ${studio.programScene.name}'), findsOneWidget);
    expect(find.text('Preview · ${studio.programScene.name}'), findsOneWidget);
    for (final (i, scene) in studio.scenes.take(8).indexed) {
      expect(find.text('${i + 1}. ${scene.name}'), findsOneWidget);
    }
    // The Multiview is captured instead of the program, even while the
    // encoder would provide program frames.
    final before = frames.length;
    await tester.runAsync(display.debugTick);
    expect(frames, hasLength(before + 1));
    expect((frames.last.$1, frames.last.$2), (1920, 1080));

    await tester.tap(find.text('Mirror tablet'));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(studio.settings.externalDisplay, 'mirror');
    expect(devices.dock.display!.presenting, isFalse);
    expect(find.text('Docked · Mirroring'), findsOneWidget);
    expect(find.text('The screen mirrors the tablet.'), findsOneWidget);

    expect(find.byType(Multiview), findsNothing);

    // No longer presenting: nothing is sent.
    final sent = frames.length;
    await tester.runAsync(display.debugTick);
    expect(frames, hasLength(sent));

    display.dispose();
    tracker.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
