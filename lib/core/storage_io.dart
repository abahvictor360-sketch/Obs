import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'storage.dart';

StudioStorage createStorage() => FileStorage();

class FileStorage implements StudioStorage {
  FileStorage();

  /// Stores in [dir] instead of the app documents directory (tests).
  FileStorage.at(Directory dir) : _dir = dir;

  Directory? _dir;

  Future<Directory> _base() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/obs_tablet');
    await d.create(recursive: true);
    return _dir = d;
  }

  @override
  Future<String?> read(String key) async {
    final f = File('${(await _base()).path}/$key');
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  @override
  Future<void> write(String key, String value) async {
    final dir = await _base();
    final target = File('${dir.path}/$key');
    // Write to a temp file then rename, so a crash never leaves half a file.
    final tmp = File('${dir.path}/$key.tmp');
    await tmp.writeAsString(value, flush: true);
    // Keep the previous version as `<key>.bak`, read if the file is damaged.
    if (await target.exists()) {
      try {
        await target.copy('${dir.path}/$key.bak');
      } catch (_) {}
    }
    await tmp.rename(target.path);
  }
}
