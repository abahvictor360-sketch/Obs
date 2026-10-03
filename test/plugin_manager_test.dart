@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/models.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/studio_controller.dart';
import 'package:obs_tablet/output/output_engine.dart';
import 'package:obs_tablet/plugins/plugin_bridge.dart';
import 'package:obs_tablet/plugins/plugin_manager.dart';
import 'package:obs_tablet/plugins/plugin_manifest.dart';
import 'package:obs_tablet/plugins/plugin_platform_io.dart';

import 'widget_test.dart' show FakeEncoder;

class FakeHost implements PluginHost {
  FakeHost(this.plugin, this.callbacks);

  final PluginEntry plugin;
  final PluginHostCallbacks callbacks;
  final calls = <String>[];
  bool started = false;
  bool disposed = false;

  @override
  Future<void> start() async => started = true;
  @override
  void createInstance(String id, String type, Map<String, dynamic> settings, int width, int height, int fps) =>
      calls.add('create $id $type ${jsonEncode(settings)} ${width}x$height@$fps');
  @override
  void updateInstance(String id, Map<String, dynamic> settings) => calls.add('update $id ${jsonEncode(settings)}');
  @override
  void destroyInstance(String id) => calls.add('destroy $id');
  @override
  void emit(String event, Object? data) => calls.add('emit $event ${jsonEncode(data)}');
  @override
  Future<void> dispose() async => disposed = true;
}

Uint8List _pluginZip({List<String> permissions = const []}) {
  final files = {
    kManifestFile: jsonEncode({
      'id': 'com.example.ticker',
      'name': 'Ticker',
      'version': '1.0.0',
      'main': 'main.js',
      'permissions': permissions,
      'sources': [
        {
          'type': 'ticker',
          'name': 'Ticker',
          'width': 1000,
          'height': 100,
          'fps': 5,
          'settings': [
            {'key': 'text', 'label': 'Text', 'type': 'text', 'default': 'Hello'},
          ],
        },
      ],
    }),
    'main.js': '// plugin',
  };
  final a = Archive();
  files.forEach((n, c) {
    final b = utf8.encode(c);
    a.addFile(ArchiveFile(n, b.length, b));
  });
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  late Directory tmp;
  late PluginManager plugins;
  late StudioController studio;
  late OutputEngine output;
  final hosts = <FakeHost>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pm');
    hosts.clear();
    plugins = PluginManager(IoPluginBackend(
      base: Directory('${tmp.path}/plugins'),
      hostFactory: (p, cb) {
        final h = FakeHost(p, cb);
        hosts.add(h);
        return h;
      },
    ));
    await plugins.load();
    studio = StudioController(storage: MemoryStorage());
    output = OutputEngine(studio: studio, backend: FakeEncoder());
  });

  tearDown(() async {
    studio.dispose();
    await tmp.delete(recursive: true);
  });

  Future<Source> addTicker() async {
    final st = plugins.sourceTypes.single.$2;
    final item = studio.addNewSource(SourceType.plugin, name: 'News', settings: {
      'plugin': 'com.example.ticker',
      'type': st.type,
      'config': {'text': 'Breaking'},
      'width': 1000.0,
      'height': 100.0,
    });
    await Future<void>.delayed(Duration.zero);
    return studio.sourceById(item.sourceId)!;
  }

  test('plugin source instances follow what is on program/preview', () async {
    await plugins.install(plugins.readZip(_pluginZip(), 'ticker.zip'));
    expect(plugins.plugins.single.source, 'file:ticker.zip');
    final bridge = PluginBridge(studio, output, plugins);

    final src = await addTicker();
    final item = studio.editingScene.items.last;
    expect(item.transform.width, 1000);
    expect(hosts.single.started, isTrue);
    expect(hosts.single.calls.last, 'create ${src.id} ticker {"text":"Breaking"} 1000x100@5');

    studio.updateSourceSettings(src.id, {'config': {'text': 'Update'}});
    await Future<void>.delayed(Duration.zero);
    expect(hosts.single.calls.last, 'update ${src.id} {"text":"Update"}');

    // Switching to a scene without it destroys the instance and emits.
    studio.selectScene(studio.scenes[1].id);
    await Future<void>.delayed(Duration.zero);
    expect(hosts.single.calls, contains('destroy ${src.id}'));
    expect(hosts.single.calls, contains('emit sceneChanged {"name":"Be Right Back"}'));
    expect(plugins.liveInstances, isEmpty);

    // Disabling stops the sandbox.
    studio.selectScene(studio.scenes[0].id);
    await Future<void>.delayed(Duration.zero);
    expect(plugins.liveInstances, {src.id});
    await plugins.setEnabled('com.example.ticker', false);
    expect(hosts.single.disposed, isTrue);
    expect(plugins.liveInstances, isEmpty);
    bridge.dispose();
  });

  test('control requests need the "control" permission', () async {
    await plugins.install(plugins.readZip(_pluginZip(), 'ticker.zip'));
    final bridge = PluginBridge(studio, output, plugins);
    final p = plugins.plugins.single;
    final state = await plugins.control(p, 'getState', {}) as Map;
    expect(state['programScene'], 'Scene');
    await expectLater(plugins.control(p, 'switchScene', {'name': 'Be Right Back'}),
        throwsA(predicate((e) => '$e'.contains('permission'))));

    await plugins.install(plugins.readZip(_pluginZip(permissions: ['control']), 'ticker.zip'));
    final p2 = plugins.plugins.single;
    await plugins.control(p2, 'switchScene', {'name': 'Be Right Back'});
    expect(studio.programScene.name, 'Be Right Back');
    await plugins.control(p2, 'setSourceVisible', {'source': 'BRB Text', 'visible': false});
    final brb = studio.programScene.items.firstWhere((i) => studio.sourceById(i.sourceId)!.name == 'BRB Text');
    expect(brb.visible, isFalse);
    await expectLater(plugins.control(p2, 'switchScene', {'name': 'Nope'}), throwsArgumentError);
    bridge.dispose();
  });

  test('frames from the sandbox become images for the source', () async {
    await plugins.install(plugins.readZip(_pluginZip(), 'ticker.zip'));
    final bridge = PluginBridge(studio, output, plugins);
    final src = await addTicker();

    // A 2x1 PNG made with dart:ui.
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 1), ui.Paint()..color = const ui.Color(0xFFFF0000));
    final img = await recorder.endRecording().toImage(2, 1);
    final png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();

    hosts.single.callbacks.onFrame(src.id, png);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final frame = plugins.frameFor(src.id).value;
    expect(frame, isNotNull);
    expect((frame!.width, frame.height), (2, 1));

    hosts.single.callbacks.onError(src.id, 'boom');
    expect(plugins.instanceErrors[src.id], 'boom');
    expect(plugins.logs['com.example.ticker']!.last, contains('ERROR: boom'));
    bridge.dispose();
  });

  test('enabled flags and built-in settings persist', () async {
    await plugins.setEnabled(ndiBuiltin.id, true);
    await plugins.setBuiltinSettings(ndiBuiltin.id, {'name': 'Stage Left'});
    final again = PluginManager(IoPluginBackend(base: Directory('${tmp.path}/plugins')));
    await again.load();
    expect(again.isEnabled(ndiBuiltin.id), isTrue);
    expect(again.builtinSettings(ndiBuiltin.id)['name'], 'Stage Left');
  });
}
