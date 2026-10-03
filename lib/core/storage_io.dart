import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'storage.dart';

StudioStorage createStorage() => FileStorage();

class FileStorage implements StudioStorage {
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
    // Write to a temp file then rename, so a crash never leaves half a file.
    final tmp = File('${dir.path}/$key.tmp');
    await tmp.writeAsString(value, flush: true);
    await tmp.rename('${dir.path}/$key');
  }
}
