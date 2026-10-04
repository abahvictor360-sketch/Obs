@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/plugins/plugin_manifest.dart';
import 'package:obs_tablet/plugins/plugin_package.dart';
import 'package:obs_tablet/plugins/plugin_store.dart';

Map<String, dynamic> _manifest({String id = 'com.example.clock', String version = '1.0.0'}) => {
      'id': id,
      'name': 'Clock',
      'version': version,
      'main': 'main.js',
      'permissions': ['network'],
      'sources': [
        {
          'type': 'clock',
          'name': 'Clock',
          'width': 800,
          'height': 200,
          'fps': 1,
          'settings': [
            {'key': 'format', 'label': 'Format', 'type': 'select', 'default': '24h', 'options': ['12h', '24h']},
          ],
        },
      ],
      'docks': [
        {'id': 'panel', 'name': 'Panel', 'page': 'dock.html'},
      ],
    };

Uint8List _zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    a.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(a));
}

Map<String, String> _pluginFiles(String prefix, {Map<String, dynamic>? manifest}) => {
      '$prefix$kManifestFile': jsonEncode(manifest ?? _manifest()),
      '${prefix}main.js': 'obstablet.registerSource("clock", {});',
      '${prefix}dock.html': '<p>dock</p>',
    };

void main() {
  group('GitHubRef.parse', () {
    test('accepts the forms people paste', () {
      var r = GitHubRef.parse('jane/obs-clock');
      expect((r.owner, r.repo, r.ref, r.subdir), ('jane', 'obs-clock', null, null));
      r = GitHubRef.parse('https://github.com/jane/obs-clock.git');
      expect(r.repo, 'obs-clock');
      r = GitHubRef.parse('github.com/jane/plugins/tree/main/plugins/clock');
      expect((r.ref, r.subdir), ('main', 'plugins/clock'));
      r = GitHubRef.parse('https://github.com/jane/plugins/blob/v2/clock/obspad-plugin.json');
      expect((r.ref, r.subdir), ('v2', 'clock'));
      r = GitHubRef.parse('https://github.com/jane/obs-clock/releases/tag/v1.2.0');
      expect(r.ref, 'v1.2.0');
      r = GitHubRef.parse('https://github.com/jane/obs-clock?tab=readme');
      expect(r.ref, isNull);
    });

    test('rejects nonsense', () {
      for (final bad in ['', 'jane', 'https://gitlab.com/a', 'a/b/issues', 'a/b/tree/main/../x', 'a b/c']) {
        expect(() => GitHubRef.parse(bad), throwsA(isA<PluginFormatException>()), reason: bad);
      }
    });
  });

  group('PluginManifest', () {
    test('parses a full manifest', () {
      final m = PluginManifest.fromJson(_manifest());
      expect(m.permissions, {PluginPermission.network});
      expect(m.sources.single.defaultSettings(), {'format': '24h'});
      expect(m.docks.single.page, 'dock.html');
      final again = PluginManifest.fromJson(jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
      expect(again.sources.single.settings.single.options, ['12h', '24h']);
    });

    test('validates fields', () {
      Map<String, dynamic> withField(String k, Object? v) => _manifest()..[k] = v;
      expect(() => PluginManifest.fromJson(withField('id', 'NoDots')), throwsA(isA<PluginFormatException>()));
      expect(() => PluginManifest.fromJson(withField('version', 'one')), throwsA(isA<PluginFormatException>()));
      expect(() => PluginManifest.fromJson(withField('permissions', ['root'])), throwsA(isA<PluginFormatException>()));
      expect(() => PluginManifest.fromJson(withField('main', '../evil.js')), throwsA(isA<PluginFormatException>()));
      expect(() => PluginManifest.fromJson(withField('main', null)), throwsA(isA<PluginFormatException>()));
      expect(() => PluginManifest.fromJson(withField('minAppVersion', '99.0.0')),
          throwsA(predicate((e) => '$e'.contains('Needs OBSpad'))));
    });

    test('version ordering', () {
      expect(Version.parse('1.10.0') > Version.parse('1.9.9'), isTrue);
      expect(Version.parse('v2.0') > Version.parse('1.99.99'), isTrue);
      expect(Version.parse('1.0.0') > Version.parse('1.0.0-beta'), isTrue);
      expect(Version.parse('1.0.0'), Version.parse('v1.0'));
    });
  });

  group('PluginPackageReader', () {
    test('finds the plugin inside a GitHub zip folder', () {
      final pkg = PluginPackageReader.read(_zip(_pluginFiles('obs-clock-main/')));
      expect(pkg.manifest.id, 'com.example.clock');
      expect(pkg.files.keys, containsAll([kManifestFile, 'main.js', 'dock.html']));
    });

    test('picks a subfolder in a monorepo', () {
      final files = {
        ..._pluginFiles('plugins-main/clock/'),
        ..._pluginFiles('plugins-main/timer/', manifest: _manifest(id: 'com.example.timer')),
        'plugins-main/README.md': '# plugins',
      };
      final pkg = PluginPackageReader.read(_zip(files), subdir: 'timer');
      expect(pkg.manifest.id, 'com.example.timer');
      expect(pkg.files.keys, isNot(contains('README.md')));
      expect(() => PluginPackageReader.read(_zip(files), subdir: 'nope'), throwsA(isA<PluginFormatException>()));
    });

    test('rejects zip-slip paths, missing files and non-plugins', () {
      expect(
        () => PluginPackageReader.read(_zip({..._pluginFiles(''), 'a/../../evil.sh': 'x'})),
        throwsA(predicate((e) => '$e'.contains('Unsafe'))),
      );
      expect(
        () => PluginPackageReader.read(_zip({kManifestFile: jsonEncode(_manifest())})),
        throwsA(predicate((e) => '$e'.contains('Missing file'))),
      );
      expect(() => PluginPackageReader.read(_zip({'README.md': 'hi'})), throwsA(isA<PluginFormatException>()));
      expect(() => PluginPackageReader.read([1, 2, 3]), throwsA(isA<PluginFormatException>()));
    });
  });

  group('PluginStore + GitHubClient', () {
    late Directory tmp;
    late HttpServer server;
    late GitHubClient gh;
    final requests = <String>[];
    var latestRelease = true;
    var version = '1.0.0';

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('plugins');
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final p = req.uri.path;
        requests.add(p);
        final res = req.response;
        if (p == '/api/repos/jane/obs-clock/releases/latest') {
          if (!latestRelease) {
            res.statusCode = 404;
          } else {
            res.write(jsonEncode({'tag_name': 'v$version', 'assets': []}));
          }
        } else if (p == '/api/repos/jane/obs-clock') {
          res.write(jsonEncode({'default_branch': 'trunk'}));
        } else if (p.startsWith('/codeload/jane/obs-clock/zip/')) {
          res.add(_zip(_pluginFiles('obs-clock-x/', manifest: _manifest(version: version))));
        } else {
          res.statusCode = 404;
        }
        await res.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      gh = GitHubClient(apiBase: '$base/api', codeloadBase: '$base/codeload');
    });

    tearDown(() async {
      gh.close();
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });

    test('installs the latest release, then updates in place', () async {
      final store = PluginStore(Directory('${tmp.path}/plugins'));
      final ref = GitHubRef.parse('jane/obs-clock');
      final (bytes, tag) = await gh.download(ref);
      expect(tag, 'v1.0.0');
      expect(requests.last, '/codeload/jane/obs-clock/zip/refs/tags/v1.0.0');
      final pkg = PluginPackageReader.read(bytes);
      await store.install(pkg, source: ref.url, ref: tag, zipBytes: bytes);

      var list = await store.list();
      expect(list.single.manifest.version, '1.0.0');
      expect(list.single.record.fromGitHub, isTrue);
      expect(list.single.record.sha256, hasLength(64));
      expect(await list.single.file('main.js').readAsString(), contains('registerSource'));

      version = '1.1.0';
      final update = await gh.fetchPackage(ref);
      expect(Version.parse(update.manifest.version) > Version.parse(list.single.manifest.version), isTrue);
      await store.install(update, source: ref.url);
      list = await store.list();
      expect(list.single.manifest.version, '1.1.0');
      expect(Directory('${tmp.path}/plugins').listSync().map((e) => e.path.split('/').last), ['com.example.clock']);

      await store.uninstall('com.example.clock');
      expect(await store.list(), isEmpty);
    });

    test('falls back to the default branch when there are no releases', () async {
      latestRelease = false;
      final (_, ref) = await gh.download(GitHubRef.parse('jane/obs-clock'));
      expect(ref, 'trunk');
      expect(requests.last, '/codeload/jane/obs-clock/zip/refs/heads/trunk');
      latestRelease = true;
    });

    test('reports missing repositories clearly', () async {
      await expectLater(gh.download(GitHubRef.parse('jane/missing')),
          throwsA(predicate((e) => '$e'.contains('not found'))));
    });
  });

  group('packages without obspad-plugin.json are converted', () {
    test('web overlays and docks from a GitHub repo', () {
      final pkg = PluginPackageReader.read(
        _zip({
          'obs-overlays-main/index.html': '<html><head><title>Scoreboard</title></head></html>',
          'obs-overlays-main/chat/index.html': '<script src="https://chat.example/x.js"></script>',
          'obs-overlays-main/control-panel.html': '<p>buttons</p>',
          'obs-overlays-main/style.css': 'body{}',
          'obs-overlays-main/node_modules/lib/index.html': '<p>skip</p>',
          'obs-overlays-main/README.md': '# Overlays',
        }),
        name: 'obs-overlays',
        id: 'github.Jane.obs-overlays',
        version: 'v2.1',
      );
      final m = pkg.manifest;
      expect(m.converted, isTrue);
      expect((m.id, m.name, m.version), ('github.jane.obs-overlays', 'Obs Overlays', '2.1.0'));
      expect(m.overlays.map((o) => (o.name, o.page)), [('Scoreboard', 'index.html'), ('Chat', 'chat/index.html')]);
      expect(m.docks.map((d) => (d.name, d.page)), [('Control Panel', 'control-panel.html')]);
      expect(m.permissions, {PluginPermission.network});
      expect(pkg.files.keys, isNot(contains('node_modules/lib/index.html')));
      expect(pkg.files.keys, containsAll(['style.css', kManifestFile]));
      // The written manifest reads back the same.
      final again = PluginManifest.fromJson(jsonDecode(utf8.decode(pkg.files[kManifestFile]!)) as Map<String, dynamic>);
      expect(again.overlays.map((o) => o.page), ['index.html', 'chat/index.html']);
    });

    test('LUT and overlay packs from a zip', () {
      final pkg = PluginPackageReader.read(
        _zip({'luts/Film Look.cube': 'LUT_3D_SIZE 2', 'stingers/swipe.webm': 'x', 'frame.png': 'x'}),
        name: 'My LUT pack',
      );
      expect(pkg.manifest.id, 'zip.my-lut-pack');
      expect(pkg.manifest.luts, ['luts/Film Look.cube']);
      expect(pkg.manifest.media, ['frame.png', 'stingers/swipe.webm']);
      expect(pkg.manifest.overlays, isEmpty);
    });

    test('native plugins and scripts are explained', () {
      expect(
        () => PluginPackageReader.read(_zip({'obs-move/CMakeLists.txt': '', 'obs-move/src/move.c': ''})),
        throwsA(predicate((e) => '$e'.contains('native OBS Studio plugin'))),
      );
      expect(
        () => PluginPackageReader.read(_zip({'timer.lua': 'obs = obslua'})),
        throwsA(predicate((e) => '$e'.contains('OBS Studio script'))),
      );
    });

    test('a release whose zip is a Windows build installs from the source', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final p = req.uri.path;
        final res = req.response;
        if (p == '/api/repos/jane/widgets/releases/latest') {
          res.write(jsonEncode({
            'tag_name': '1.4.0',
            'assets': [
              {'name': 'widgets-windows.zip', 'browser_download_url': '$base/asset.zip'},
            ],
          }));
        } else if (p == '/asset.zip') {
          res.add(_zip({'obs-plugins/64bit/widgets.dll': 'MZ'}));
        } else if (p == '/codeload/jane/widgets/zip/refs/tags/1.4.0') {
          res.add(_zip({'widgets-1.4.0/clock.html': '<title>Clock</title>'}));
        } else {
          res.statusCode = 404;
        }
        await res.close();
      });
      final gh = GitHubClient(apiBase: '$base/api', codeloadBase: '$base/codeload');
      try {
        final (pkg, _, ref) = await gh.fetch(GitHubRef.parse('jane/widgets'));
        expect(ref, '1.4.0');
        expect(pkg.manifest.id, 'github.jane.widgets');
        expect(pkg.manifest.overlays.single.name, 'Clock');
      } finally {
        gh.close();
        await server.close(force: true);
      }
    });
  });
}
