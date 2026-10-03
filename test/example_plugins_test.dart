@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obs_tablet/plugins/plugin_manifest.dart';
import 'package:obs_tablet/plugins/plugin_package.dart';

void main() {
  // The bundled examples must install exactly as a GitHub source zip would.
  final dirs = Directory('plugins').listSync().whereType<Directory>().toList();

  test('there are example plugins', () => expect(dirs.length, greaterThanOrEqualTo(3)));

  for (final dir in dirs) {
    test('example plugin ${dir.path} installs', () {
      final archive = Archive();
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        final bytes = f.readAsBytesSync();
        archive.addFile(ArchiveFile('Obs-main/${f.path}', bytes.length, bytes));
      }
      final zip = Uint8List.fromList(ZipEncoder().encode(archive));
      final sub = dir.path; // e.g. plugins/clock
      final pkg = PluginPackageReader.read(zip, subdir: sub);
      expect(pkg.manifest.id, startsWith('org.obstablet.'));
    });
  }

  test('catalog points at the example plugins', () {
    final catalog = jsonDecode(File('plugins/catalog.json').readAsStringSync()) as Map<String, dynamic>;
    final urls = (catalog['plugins'] as List).map((e) => (e as Map)['url'] as String).toList();
    expect(urls.length, dirs.length);
    for (final u in urls) {
      final ref = GitHubRef.parse(u);
      expect(Directory(ref.subdir!).existsSync(), isTrue, reason: u);
      expect(File('${ref.subdir}/$kManifestFile').existsSync(), isTrue);
    }
  });
}
