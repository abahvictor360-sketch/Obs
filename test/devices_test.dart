import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/models.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/studio_controller.dart';
import 'package:obs_tablet/devices/device_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('obs_tablet/devices');
  const events = EventChannel('obs_tablet/device_events');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late List<Map<String, Object>> cameras;
  MockStreamHandlerEventSink? sink;

  setUp(() {
    calls = [];
    cameras = [];
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getNetwork':
          return {'transport': 'wifi', 'wiredAvailable': false, 'preferWired': false, 'canPreferWired': true};
        case 'setPreferWired':
          final on = (call.arguments as Map)['enabled'] == true;
          return {'transport': on ? 'ethernet' : 'wifi', 'wiredAvailable': true, 'preferWired': on, 'canPreferWired': true};
        case 'listUsbCameras':
          return cameras;
        case 'listAudioInputs':
          return [
            {'id': '1', 'name': 'Built-in mic', 'type': 'builtin'},
            {'id': '7', 'name': 'RØDE NT-USB', 'type': 'usb'},
          ];
        case 'openUsbCamera':
          return {'id': 'usb-1', 'textureId': 42, 'width': 1920, 'height': 1080};
      }
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (args, s) => sink = s, onCancel: (args) => sink = null),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('USB capture card: opens when a visible source needs it, closes when hidden', () async {
    final devices = DeviceService();
    await devices.init();
    expect(devices.supported, isTrue);
    expect(devices.audioInputs.map((i) => i.type), ['builtin', 'usb']);
    expect(devices.network.transport, 'wifi');

    final studio = StudioController(storage: MemoryStorage());
    final tracker = DeviceActivityTracker(studio, devices);
    final item = studio.addNewSource(SourceType.usbVideo, name: 'Capture card');
    await Future<void>.delayed(Duration.zero);
    // Nothing plugged in yet: don't try to open.
    expect(calls.where((c) => c.method == 'openUsbCamera'), isEmpty);

    // Plug it in.
    cameras = [
      {'id': 'usb-1', 'name': 'MACROSILICON USB Video'},
    ];
    sink!.success({'type': 'usbVideo', 'state': 'attached', 'id': 'usb-1', 'name': 'MACROSILICON USB Video'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(devices.usbCameras.single.name, 'MACROSILICON USB Video');
    expect(calls.where((c) => c.method == 'openUsbCamera'), hasLength(1));
    expect(devices.usbVideo?.textureId, 42);
    expect((devices.usbVideo!.width, devices.usbVideo!.height), (1920, 1080));

    // Hide the source: device is released.
    studio.setItemVisible(item.id, false);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'closeUsbCamera');
    expect(devices.usbVideo, isNull);

    // Unplugged while open.
    studio.setItemVisible(item.id, true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(devices.usbVideo, isNotNull);
    cameras = [];
    sink!.success({'type': 'usbVideo', 'state': 'detached', 'id': 'usb-1'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(devices.usbVideo, isNull);
    tracker.dispose();
    studio.dispose();
  });

  test('USB microphone choice and prefer-wired are applied', () async {
    final devices = DeviceService();
    await devices.init();
    final studio = StudioController(storage: MemoryStorage());
    final tracker = DeviceActivityTracker(studio, devices);
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.method == 'setPreferWired').single.arguments, {'enabled': true});
    expect(devices.network.transport, 'ethernet');

    final mic = studio.sources.firstWhere((s) => s.type == SourceType.audioInput);
    studio.updateSourceSettings(mic.id, {'device': '7'});
    await Future<void>.delayed(Duration.zero);
    expect(calls.lastWhere((c) => c.method == 'setAudioInput').arguments, {'id': '7'});

    studio.updateSettings((s) => s.preferWired = false);
    await Future<void>.delayed(Duration.zero);
    expect(calls.lastWhere((c) => c.method == 'setPreferWired').arguments, {'enabled': false});
    expect(devices.network.transport, 'wifi');

    sink!.success({'type': 'network', 'transport': 'cellular', 'wiredAvailable': false, 'canPreferWired': true});
    await Future<void>.delayed(Duration.zero);
    expect(devices.network.transport, 'cellular');
    tracker.dispose();
    studio.dispose();
  });

  test('a USB sound card (direct, hub or dock) is used automatically and follows plug/unplug', () async {
    final devices = DeviceService();
    await devices.init();
    final studio = StudioController(storage: MemoryStorage());
    final tracker = DeviceActivityTracker(studio, devices);
    await Future<void>.delayed(Duration.zero);
    // Mic/Aux is on Automatic and a USB mic is connected: it records from it.
    expect(calls.lastWhere((c) => c.method == 'setAudioInput').arguments, {'id': '7'});
    expect(devices.resolveAudioInput('default')?.name, 'RØDE NT-USB');

    // Unplugged: back to the system default.
    sink!.success({
      'type': 'audioInputs',
      'inputs': [
        {'id': '1', 'name': 'Built-in mic', 'type': 'builtin'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(calls.lastWhere((c) => c.method == 'setAudioInput').arguments, {'id': null});

    // A sound card on the docking station.
    sink!.success({
      'type': 'audioInputs',
      'inputs': [
        {'id': '1', 'name': 'Built-in mic', 'type': 'builtin'},
        {'id': '12', 'name': 'USB Audio Device', 'type': 'usb'},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(calls.lastWhere((c) => c.method == 'setAudioInput').arguments, {'id': '12'});

    // A device picked by hand wins over Automatic.
    final mic = studio.sources.firstWhere((s) => s.type == SourceType.audioInput);
    studio.updateSourceSettings(mic.id, {'device': '1'});
    await Future<void>.delayed(Duration.zero);
    expect(calls.lastWhere((c) => c.method == 'setAudioInput').arguments, {'id': '1'});
    tracker.dispose();
    studio.dispose();
  });

  test('without the native side everything stays off', () async {
    messenger.setMockMethodCallHandler(method, null);
    final devices = DeviceService();
    await devices.init();
    expect(devices.supported, isFalse);
    await devices.openUsbVideo(null);
    expect(devices.usbVideo, isNull);
  });
}
