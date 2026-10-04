import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/models.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/storage_io.dart';
import 'package:obs_tablet/core/studio_controller.dart';

void main() {
  test('closing and reopening the app restores everything as it was left', () async {
    final storage = MemoryStorage();
    final a = await StudioController.load(storage);
    final s2 = a.addScene('Sermon');
    a.renameScene(s2.id, 'Sermon (wide)');
    a.selectScene(s2.id); // studio mode: preview
    final mic = a.sources.firstWhere((s) => s.type == SourceType.audioInput);
    a.setVolume(mic.id, 0.42);
    a.setMuted(mic.id, true);
    a.addFilter(mic.id, FilterKind.values.first);
    a.setTransitionDuration(750);
    a.updateSettings((s) {
      s.service = 'Facebook Live';
      s.streamKey = 'FB-123';
      s.hiddenDocks.add('transitions');
      s.dockWeights['mixer'] = 7;
      s.dockHeight = 260;
      s.externalDisplay = 'multiview';
      s.externalDisplayId = '7';
      s.browserDocks.add(BrowserDockConfig(id: '1', title: 'Chat', url: 'https://example.com/chat'));
    });
    await a.save();

    final b = await StudioController.load(storage);
    expect(b.studioMode, isTrue);
    expect(b.scenes.map((s) => s.name), contains('Sermon (wide)'));
    expect(b.previewScene.id, s2.id);
    expect(b.programScene.id, a.programScene.id);
    final mic2 = b.sourceById(mic.id)!;
    expect((mic2.volume, mic2.muted, mic2.filters.length), (0.42, true, 1));
    expect(b.collection.transitionMs, 750);
    final st = b.settings;
    expect((st.service, st.streamKey), ('Facebook Live', 'FB-123'));
    expect(st.hiddenDocks, contains('transitions'));
    expect((st.dockWeights['mixer'], st.dockHeight), (7, 260));
    expect((st.externalDisplay, st.externalDisplayId), ('multiview', '7'));
    expect(st.browserDocks.single.title, 'Chat');

    // Studio Mode off is remembered too.
    b.setStudioMode(false);
    await b.save();
    expect((await StudioController.load(storage)).studioMode, isFalse);
  });

  test('a damaged file falls back to the previous save', () async {
    final storage = MemoryStorage();
    final a = await StudioController.load(storage);
    a.updateSettings((s) => s.streamKey = 'KEY-1');
    await a.save();
    storage.data['settings.json.bak'] = storage.data['settings.json']!;
    storage.data['settings.json'] = '{"service": "Twi'; // cut off mid-write
    final b = await StudioController.load(storage);
    expect(b.settings.streamKey, 'KEY-1');
  });

  test('saves never overlap, and the last change wins', () async {
    final dir = await Directory.systemTemp.createTemp('obspad');
    addTearDown(() => dir.delete(recursive: true));
    final storage = FileStorage.at(dir);
    final a = await StudioController.load(storage);
    for (var i = 0; i < 20; i++) {
      a.updateSettings((s) => s.streamKey = 'k$i');
      a.save();
    }
    await a.save();
    final b = await StudioController.load(FileStorage.at(dir));
    expect(b.settings.streamKey, 'k19');
    expect(File('${dir.path}/settings.json.bak').existsSync(), isTrue);
  });
}
