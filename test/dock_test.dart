import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/models.dart';
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
  String? castOpens;
  MockStreamHandlerEventSink? sink;

  const screen = {'id': '2', 'name': 'HDMI', 'width': 1920, 'height': 1080, 'refreshRate': 60.0, 'presenting': true};
  const tv = {'id': '7', 'name': 'Living room TV', 'width': 3840, 'height': 2160, 'refreshRate': 60.0, 'presenting': false};

  setUp(() {
    calls = [];
    frames = [];
    castOpens = 'cast';
    dock = {'display': screen, 'ethernet': true, 'usbAudio': false, 'usbVideo': false, 'usbDevices': 1, 'charging': true};
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getNetwork':
          return {'transport': 'ethernet', 'wiredAvailable': true, 'preferWired': true, 'canPreferWired': true};
        case 'getDock':
          return dock;
        case 'setDisplayMode':
          final args = call.arguments as Map;
          final program = args['mode'] != 'mirror';
          final second = args['displayId'] == '7';
          return {
            ...dock,
            'display': second
                ? {...tv, 'presenting': program}
                : {...screen, 'presenting': program},
            if (dock['displays'] != null) 'displays': dock['displays'],
          };
        case 'listUsbCameras':
        case 'listAudioInputs':
          return const [];
        case 'openScreenCast':
          return castOpens;
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
    // A USB device while charging only works through a hub or dock.
    expect(const DockInfo(usbDevices: 1, charging: true).docked, isTrue);
    // A dock whose video the tablet refused (USB-C Billboard device).
    final refused = DockInfo.fromMap({
      'billboard': true,
      'seen': ['USB: Dock Billboard'],
    });
    expect(refused.docked, isTrue);
    expect(refused.display, isNull);
    expect(refused.seen, ['USB: Dock Billboard']);
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

  testWidgets('long-press Program: send it to the screen of your choice or fullscreen on the tablet', (tester) async {
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    dock = {
      ...dock,
      'displays': [screen, tv],
    };
    final studio = StudioController(storage: MemoryStorage())..setStudioMode(true);
    final output = OutputEngine(studio: studio, backend: FakeEncoder());
    await output.init();
    final devices = DeviceService();
    await tester.runAsync(devices.init);
    expect(devices.dock.displays.map((d) => d.name), ['HDMI', 'Living room TV']);
    final tracker = DeviceActivityTracker(studio, devices);
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

    await tester.longPress(find.text('Program'));
    await tester.pumpAndSettle();
    expect(find.text('Send Program to…'), findsOneWidget);
    expect(find.text('This tablet (fullscreen)'), findsOneWidget);
    expect(find.text('HDMI'), findsOneWidget);
    expect(find.text('Living room TV'), findsOneWidget);
    expect(find.text('Program · 3840×2160'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('projector-7-program')));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(studio.settings.externalDisplayId, '7');
    expect(studio.settings.externalDisplay, 'program');
    final call = calls.lastWhere((c) => c.method == 'setDisplayMode');
    expect(call.arguments, {'mode': 'program', 'displayId': '7'});
    expect(devices.dock.display!.name, 'Living room TV');

    // The cast button opens the same menu; "This tablet" is a fullscreen projector.
    await tester.tap(find.byKey(const ValueKey('send-program')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('projector-tablet')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('projector-screen')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('projector-screen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('projector-screen')), findsNothing);
    expect(tester.takeException(), isNull);

    tracker.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
  testWidgets('View › Multiview (Fullscreen): pick the screen it goes to', (tester) async {
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    dock = {
      ...dock,
      'displays': [screen, tv],
    };
    final studio = StudioController(storage: MemoryStorage());
    final output = OutputEngine(studio: studio, backend: FakeEncoder());
    await output.init();
    final devices = DeviceService();
    await tester.runAsync(devices.init);
    final tracker = DeviceActivityTracker(studio, devices);
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

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-multiview')));
    await tester.pumpAndSettle();
    expect(find.text('HDMI  1920×1080'), findsOneWidget);
    expect(find.text('Living room TV  3840×2160'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-multiview-7')));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(studio.settings.externalDisplay, 'multiview');
    expect(studio.settings.externalDisplayId, '7');
    expect(calls.lastWhere((c) => c.method == 'setDisplayMode').arguments, {'mode': 'multiview', 'displayId': '7'});

    // The Program projector can go to the other screen the same way.
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-projector')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-projector-tablet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-program-2')));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect((studio.settings.externalDisplay, studio.settings.externalDisplayId), ('program', '2'));
    expect(tester.takeException(), isNull);

    tracker.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
  testWidgets('Cast to a wireless screen opens the system casting and sends the program there', (tester) async {
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final studio = StudioController(storage: MemoryStorage())..setStudioMode(true);
    studio.updateSettings((s) {
      s.externalDisplay = 'mirror';
      s.externalDisplayId = '2';
    });
    final output = OutputEngine(studio: studio, backend: FakeEncoder());
    await output.init();
    final devices = DeviceService();
    await tester.runAsync(devices.init);
    final tracker = DeviceActivityTracker(studio, devices);
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

    await tester.longPress(find.text('Program'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('projector-cast')));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'openScreenCast'), hasLength(1));
    // The next screen to connect (the TV) shows the program.
    expect((studio.settings.externalDisplay, studio.settings.externalDisplayId), ('program', null));
    expect(find.textContaining('Pick your TV'), findsOneWidget);

    // No casting screen on this tablet: explain where to find it.
    castOpens = null;
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-multiview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-multiview-cast')));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(studio.settings.externalDisplay, 'multiview');
    expect(find.byKey(const ValueKey('screen-cast-help')), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    tracker.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
  testWidgets('View › Multiview (Fullscreen) › This tablet: tap a scene to preview it', (tester) async {
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final studio = StudioController(storage: MemoryStorage())..setStudioMode(true);
    final second = studio.addScene('Worship');
    final output = OutputEngine(studio: studio, backend: FakeEncoder());
    await output.init();
    final devices = DeviceService();
    await tester.runAsync(devices.init);
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
    final program = studio.programScene.id;

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-multiview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-multiview-tablet')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('multiview-projector')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('multiview-scene-${second.id}')));
    await tester.pumpAndSettle();
    expect(studio.previewScene.id, second.id);
    expect(studio.programScene.id, program);

    expect(find.text('Back to OBSpad'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('multiview-projector-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('multiview-projector')), findsNothing);
    // Back on the studio, not an exit prompt.
    expect(find.text('Program'), findsWidgets);

    // The back gesture and Esc close it too.
    Future<void> reopen() async {
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-multiview')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-multiview-tablet')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('multiview-projector')), findsOneWidget);
    }

    await reopen();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('multiview-projector')), findsNothing);
    expect(find.text('Exit OBSpad?'), findsNothing);

    await reopen();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('multiview-projector')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
  testWidgets('Multiview layout: 4, 6, 8 or 16 scenes, from the View menu or the fullscreen Multiview',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final studio = StudioController(storage: MemoryStorage())..setStudioMode(true);
    while (studio.scenes.length < 12) {
      studio.addScene();
    }
    final output = OutputEngine(studio: studio, backend: FakeEncoder());
    await output.init();
    final devices = DeviceService();
    await tester.runAsync(devices.init);
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
    int tiles() => find.byWidgetPredicate((w) => '${w.key}'.contains('multiview-scene-')).evaluate().length;

    // View › Multiview (Fullscreen) › Layout › 4 scenes.
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-multiview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-multiview-layout')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-multiview-layout-4')).first);
    await tester.pumpAndSettle();
    expect(studio.settings.multiviewScenes, 4);

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-multiview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-multiview-tablet')));
    await tester.pumpAndSettle();
    expect(tiles(), 4);

    // From the fullscreen Multiview itself.
    for (final (n, shown) in [(16, 12), (6, 6), (8, 8)]) {
      await tester.tap(find.byKey(const ValueKey('multiview-layout')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('multiview-layout-$n')));
      await tester.pumpAndSettle();
      expect(studio.settings.multiviewScenes, n);
      expect(tiles(), shown, reason: '$n-scene layout with 12 scenes');
    }
    expect(tester.takeException(), isNull);

    // Saved with the settings.
    expect(OutputSettings.fromJson({...studio.settings.toJson(), 'multiviewScenes': 16}).multiviewScenes, 16);
    expect(OutputSettings.fromJson({...studio.settings.toJson(), 'multiviewScenes': 5}).multiviewScenes, 8);

    await tester.tap(find.byKey(const ValueKey('multiview-projector-close')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
