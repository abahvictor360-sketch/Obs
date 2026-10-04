import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/models.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/studio_controller.dart';

StudioController _controller() => StudioController(storage: MemoryStorage());

void main() {
  group('SceneCollection', () {
    test('round-trips through JSON', () {
      final c = SceneCollection.starter();
      c.scenes.first.items.first.transform.rotation = 45;
      c.scenes.first.items.first.color.saturation = -1;
      final back = SceneCollection.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
      expect(back.scenes.length, c.scenes.length);
      expect(back.sources.map((s) => s.name), c.sources.map((s) => s.name));
      expect(back.scenes.first.items.first.transform.rotation, 45);
      expect(back.scenes.first.items.first.color.saturation, -1);
      expect(back.programSceneId, c.programSceneId);
    });

    test('drops items pointing at missing sources and fixes bad scene ids', () {
      final j = SceneCollection.starter().toJson();
      (j['sources'] as List).removeAt(0); // background color source
      j['programSceneId'] = 'nope';
      final c = SceneCollection.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      final ids = c.sources.map((s) => s.id).toSet();
      for (final s in c.scenes) {
        expect(s.items.every((i) => ids.contains(i.sourceId)), isTrue);
      }
      expect(c.programSceneId, c.scenes.first.id);
    });
  });

  group('StudioController', () {
    test('selecting a scene goes live outside studio mode', () {
      final s = _controller();
      final second = s.scenes[1];
      final serial = s.transitionSerial;
      s.selectScene(second.id);
      expect(s.programScene.id, second.id);
      expect(s.transitionSerial, serial + 1);
    });

    test('studio mode edits preview and swaps on transition', () {
      final s = _controller();
      final first = s.scenes[0], second = s.scenes[1];
      s.setStudioMode(true);
      s.selectScene(second.id);
      expect(s.programScene.id, first.id);
      expect(s.previewScene.id, second.id);
      expect(s.editingScene.id, second.id);
      s.transitionToProgram();
      expect(s.programScene.id, second.id);
      expect(s.previewScene.id, first.id);
    });

    test('adding a source creates a global source and a scene item', () {
      final s = _controller();
      final before = s.sources.length;
      final item = s.addNewSource(SourceType.text, name: 'Hello');
      expect(s.sources.length, before + 1);
      expect(s.editingScene.items.last.id, item.id);
      expect(s.selectedItemId, item.id);
      expect(s.sourceById(item.sourceId)!.name, 'Hello');
    });

    test('source names are made unique', () {
      final s = _controller();
      final a = s.addNewSource(SourceType.color, name: 'Box');
      final b = s.addNewSource(SourceType.color, name: 'Box');
      expect(s.sourceById(a.sourceId)!.name, 'Box');
      expect(s.sourceById(b.sourceId)!.name, 'Box 2');
    });

    test('removing the last item of a source deletes the source', () {
      final s = _controller();
      final item = s.addNewSource(SourceType.image);
      s.removeItem(item.id);
      expect(s.sourceById(item.sourceId), isNull);
    });

    test('a source shared by two scenes survives removing one item', () {
      final s = _controller();
      final item = s.addNewSource(SourceType.image);
      s.selectScene(s.scenes[1].id);
      s.addExistingSource(item.sourceId);
      expect(s.usageCount(item.sourceId), 2);
      s.selectScene(s.scenes[0].id);
      s.removeItem(item.id);
      expect(s.sourceById(item.sourceId), isNotNull);
      expect(s.usageCount(item.sourceId), 1);
    });

    test('the last scene cannot be removed', () {
      final s = _controller();
      expect(s.removeScene(s.scenes[0].id), isTrue);
      expect(s.scenes.length, 1);
      expect(s.removeScene(s.scenes[0].id), isFalse);
      expect(s.programScene, s.scenes.first);
    });

    test('moveItemDisplay works in top-most-first order', () {
      final s = _controller();
      final scene = s.editingScene;
      List<String> names() => scene.items.reversed.map((i) => s.sourceById(i.sourceId)!.name).toList();
      expect(names(), ['Title', 'Camera', 'Background']);
      s.moveItemDisplay(0, 2);
      expect(names(), ['Camera', 'Background', 'Title']);
      s.moveItemDisplay(2, 0);
      expect(names(), ['Title', 'Camera', 'Background']);
    });

    test('moveScene moves to the exact target index', () {
      final s = _controller();
      s.addScene('Third');
      List<String> names() => s.scenes.map((x) => x.name).toList();
      expect(names(), ['Scene', 'Be Right Back', 'Third']);
      s.moveScene(2, 0);
      expect(names(), ['Third', 'Scene', 'Be Right Back']);
      s.moveScene(0, 1);
      expect(names(), ['Scene', 'Third', 'Be Right Back']);
    });

    test('locked items ignore transform edits', () {
      final s = _controller();
      final bg = s.editingScene.items.first;
      expect(bg.locked, isTrue);
      s.updateTransform(bg.id, (t) => t.x = 100);
      expect(bg.transform.x, 0);
    });

    test('fit to screen keeps aspect ratio and centers', () {
      final s = _controller();
      final item = s.addNewSource(SourceType.image);
      s.updateTransform(item.id, (t) {
        t
          ..width = 400
          ..height = 400;
      });
      s.applyTransformPreset(item.id, TransformPreset.fitToScreen);
      final t = item.transform;
      expect(t.width, 1080);
      expect(t.height, 1080);
      expect(t.x, (1920 - 1080) / 2);
      expect(t.y, 0);
    });

    test('mic gain follows mixer volume and mute', () {
      final s = _controller();
      final mic = s.audioSources.firstWhere((a) => a.type == SourceType.audioInput);
      s.setVolume(mic.id, 0.5);
      expect(s.micGain, 0.5);
      s.setMuted(mic.id, true);
      expect(s.micGain, 0);
    });

    test('persists and reloads from storage', () async {
      final storage = MemoryStorage();
      final s = StudioController(storage: storage);
      s.addScene('Saved Scene');
      s.updateSettings((x) {
        x.server = 'rtmp://example.com/live';
        x.streamKey = 'abc';
      });
      await s.save();
      final again = await StudioController.load(storage);
      expect(again.scenes.map((x) => x.name), contains('Saved Scene'));
      expect(again.settings.publishUrl, 'rtmp://example.com/live/abc');
    });
  });

  test('ColorCorrection neutral matrix is identity', () {
    final m = ColorCorrection().toMatrix();
    expect(m, [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0].map((e) => closeTo(e, 1e-9)).toList());
  });
  test('Studio Mode: edits to the live scene stay in Preview until Transition', () {
    final c = StudioController(storage: MemoryStorage())..setStudioMode(true);
    expect(c.collection.previewSceneId, c.collection.programSceneId);
    final scene = c.previewScene;
    final item = scene.items.first;
    expect(c.canTransition, isFalse);

    // Hide an item and add a source in Preview: Program is unchanged.
    c.setItemVisible(item.id, false);
    final added = c.addNewSource(SourceType.color, name: 'Lower third');
    expect(c.previewScene.items.any((i) => i.id == added.id), isTrue);
    final program = c.programScene;
    expect(program.items.firstWhere((i) => i.id == item.id).visible, isTrue);
    expect(program.items.any((i) => i.id == added.id), isFalse);
    expect(c.activeSources.any((s) => s.id == added.sourceId), isTrue); // previewed, so it runs
    expect(c.previewHasPendingChanges, isTrue);
    expect(c.canTransition, isTrue);

    // Transition sends them live; Preview keeps the same scene.
    final serial = c.transitionSerial;
    c.transitionToProgram();
    expect(c.transitionSerial, serial + 1);
    expect(c.collection.previewSceneId, c.collection.programSceneId);
    expect(c.programScene.items.firstWhere((i) => i.id == item.id).visible, isFalse);
    expect(c.programScene.items.any((i) => i.id == added.id), isTrue);
    expect(c.previewHasPendingChanges, isFalse);
    expect(c.canTransition, isFalse);

    // Moving an item afterwards is again preview-only.
    c.updateTransform(added.id, (t) => t.x += 100, persist: true);
    expect(c.programScene.items.firstWhere((i) => i.id == added.id).transform.x,
        isNot(c.previewScene.items.firstWhere((i) => i.id == added.id).transform.x));
  });

  test('Without Studio Mode, edits go live at once', () {
    final c = StudioController(storage: MemoryStorage())..setStudioMode(false);
    final item = c.programScene.items.first;
    c.setItemVisible(item.id, false);
    expect(c.programScene.items.firstWhere((i) => i.id == item.id).visible, isFalse);
  });
  test('Studio Mode: removing a source in Preview keeps it live until Transition', () {
    final c = StudioController(storage: MemoryStorage())..setStudioMode(true);
    final added = c.addNewSource(SourceType.color, name: 'Backdrop');
    c.transitionToProgram(); // now live
    expect(c.programScene.items.any((i) => i.id == added.id), isTrue);
    c.removeItem(added.id);
    expect(c.sourceById(added.sourceId), isNotNull, reason: 'still on Program');
    expect(c.activeSources.any((s) => s.id == added.sourceId), isTrue);
    c.transitionToProgram();
    expect(c.sourceById(added.sourceId), isNull, reason: 'gone once nothing uses it');
    c.dispose();
  });

  test('Text font size resizes the text box around its centre', () {
    final c = StudioController(storage: MemoryStorage());
    final text = c.sources.firstWhere((s) => s.type == SourceType.text);
    final item = c.scenes.expand((s) => s.items).firstWhere((i) => i.sourceId == text.id);
    final before = (item.transform.width, item.transform.x + item.transform.width / 2);
    final old = (text.settings['fontSize'] as num?)?.toDouble() ?? 96;
    c.setTextFontSize(text.id, old * 2);
    expect(item.transform.width, closeTo(before.$1 * 2, 0.001));
    expect(item.transform.x + item.transform.width / 2, closeTo(before.$2, 0.001));
    expect(text.settings['fontSize'], old * 2);
  });
  test('Copy Filters / Paste Filters: copies that fit the target source', () {
    final c = StudioController(storage: MemoryStorage());
    final title = c.sources.firstWhere((s) => s.type == SourceType.text);
    final mic = c.sources.firstWhere((s) => s.type == SourceType.audioInput);
    final blur = c.addFilter(title.id, FilterKind.blur);
    c.updateFilter(title.id, blur.id, values: {'radius': 20.0});
    c.addFilter(mic.id, FilterKind.noiseGate);
    c.copyFilters(title.id);

    final bg = c.sources.firstWhere((s) => s.type == SourceType.color);
    expect(c.pasteFilters(bg.id), 1);
    expect(bg.filters.single.dbl('radius'), 20.0);
    expect(bg.filters.single.id, isNot(blur.id));
    expect(c.pasteFilters(mic.id), 0); // a video filter doesn't fit a mic

    c.copyFilters(mic.id);
    expect(c.pasteFilters(bg.id), 0); // a mic filter doesn't fit a color
  });
}
