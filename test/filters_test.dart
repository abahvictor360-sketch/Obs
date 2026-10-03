import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/core/models.dart';
import 'package:obs_tablet/core/storage.dart';
import 'package:obs_tablet/core/studio_controller.dart';
import 'package:obs_tablet/devices/device_service.dart';
import 'package:obs_tablet/main.dart';
import 'package:obs_tablet/network_video/network_video_service.dart';
import 'package:obs_tablet/output/output_engine.dart';
import 'package:obs_tablet/plugins/plugin_manager.dart';
import 'package:obs_tablet/render/media_services.dart';
import 'package:obs_tablet/ui/source_properties.dart';

import 'widget_test.dart' show FakeEncoder;

void main() {
  test('filter chains are saved, reordered and removed', () {
    final studio = StudioController(storage: MemoryStorage());
    final cam = studio.sources.firstWhere((s) => s.type == SourceType.camera);
    final cc = studio.addFilter(cam.id, FilterKind.colorCorrection);
    final key = studio.addFilter(cam.id, FilterKind.chromaKey);
    final cc2 = studio.addFilter(cam.id, FilterKind.colorCorrection);
    expect(cc2.name, 'Color Correction 2');
    studio.updateFilter(cam.id, key.id, values: {'similarity': 300}, enabled: false);
    studio.moveFilter(cam.id, key.id, 0);
    expect(cam.filters.map((f) => f.id), [key.id, cc.id, cc2.id]);
    studio.removeFilter(cam.id, cc2.id);

    final json = studio.collection.toJson();
    final restored = SceneCollection.fromJson(json).sources.firstWhere((s) => s.id == cam.id);
    expect(restored.filters.map((f) => f.kind), [FilterKind.chromaKey, FilterKind.colorCorrection]);
    expect(restored.filters.first.enabled, isFalse);
    expect(restored.filters.first.settings['similarity'], 300);
    expect(restored.filters.first.settings['smoothness'], 80, reason: 'defaults fill missing keys');

    // Unknown filter kinds from a newer version are skipped, not fatal.
    final raw = cam.toJson()
      ..['filters'] = [
        {'kind': 'warpDrive', 'name': 'x'},
        ...cam.filters.map((f) => f.toJson()),
      ];
    expect(Source.fromJson(raw).filters, hasLength(2));
  });

  test('a Gain filter changes what the mixer sends', () {
    final studio = StudioController(storage: MemoryStorage());
    final mic = studio.sources.firstWhere((s) => s.type == SourceType.audioInput);
    studio.setVolume(mic.id, 0.5);
    final gain = studio.addFilter(mic.id, FilterKind.gain);
    studio.updateFilter(mic.id, gain.id, values: {'db': 6.0206});
    expect(studio.micGain, closeTo(1.0, 0.001));
    studio.updateFilter(mic.id, gain.id, enabled: false);
    expect(studio.micGain, 0.5);
  });

  test('color correction matrix: neutral is identity, hue/multiply change it', () {
    final f = SourceFilter(id: 'f', kind: FilterKind.colorCorrection, name: 'cc');
    expect(f.colorMatrix(), [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0]);
    f.settings['multiply'] = 0xFFFF0000; // keep red only
    final m = f.colorMatrix();
    expect(m[6], 0); // green row
    expect(m[12], 0); // blue row
    f.settings
      ..['multiply'] = 0xFFFFFFFF
      ..['hue'] = 120.0;
    expect(f.colorMatrix()[0], isNot(1));
  });

  testWidgets('Filters panel: add, toggle and remove a filter; it shows on the canvas', (tester) async {
    tester.view.physicalSize = const Size(1366, 1024);
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
      plugins: PluginManager(createPlatformPluginBackend()),
      devices: DeviceService(),
      networkVideo: NetworkVideoService(),
    ));
    await tester.pump();
    final title = studio.programScene.items.firstWhere((i) => studio.sourceById(i.sourceId)!.type == SourceType.text);
    final source = studio.sourceById(title.sourceId)!;
    final ctx = tester.element(find.text('Sources').first);
    showSourceFilters(ctx, title.id);
    await tester.pumpAndSettle();
    expect(find.text('Effect Filters'), findsOneWidget);
    expect(find.textContaining('No filters'), findsOneWidget);
    final colorFiltersBefore = find.byType(ColorFiltered).evaluate().length;

    await tester.tap(find.byKey(const ValueKey('add-filter')));
    await tester.pumpAndSettle();
    // Shader filters need Impeller, which widget tests don't have.
    expect(find.text('Chroma Key (needs a newer device)'), findsOneWidget);
    await tester.tap(find.text('Color Correction').last);
    await tester.pumpAndSettle();
    expect(source.filters.single.kind, FilterKind.colorCorrection);
    expect(find.text('Hue shift'), findsOneWidget);
    studio.updateFilter(source.id, source.filters.single.id, values: {'saturation': -1.0});
    await tester.pump();
    expect(find.byType(ColorFiltered).evaluate().length, greaterThan(colorFiltersBefore));

    await tester.tap(find.byKey(ValueKey('filter-toggle-${source.filters.single.id}')));
    await tester.pump();
    expect(source.filters.single.enabled, isFalse);
    expect(find.byType(ColorFiltered).evaluate().length, colorFiltersBefore);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });
}
