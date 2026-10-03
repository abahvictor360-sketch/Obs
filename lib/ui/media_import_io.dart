import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Streams the picked file (it may be a content:// URI on Android) into
/// `<documents>/obs_tablet/media/`, keeping its name unique.
Future<String?> importPickedFile(PlatformFile f) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/obs_tablet/media');
  await dir.create(recursive: true);
  final safe = f.name.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
  final dot = safe.lastIndexOf('.');
  final stem = dot > 0 ? safe.substring(0, dot) : safe;
  final ext = dot > 0 ? safe.substring(dot) : '';
  var target = File('${dir.path}/$safe');
  for (var n = 2; await target.exists(); n++) {
    target = File('${dir.path}/$stem ($n)$ext');
  }
  final sink = target.openWrite();
  try {
    await sink.addStream(f.readAsByteStream());
  } finally {
    await sink.close();
  }
  return target.path;
}
