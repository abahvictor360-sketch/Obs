import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'media_import_stub.dart' if (dart.library.io) 'media_import_io.dart' as impl;

enum MediaKind { image, video, html }

/// Opens the tablet's file manager (Android Files / iPad Files app) and
/// copies the picked file into the app's storage, so the source keeps
/// working after a restart even if the original was on a USB drive, SD card
/// or cloud provider. Returns the local path, or null if cancelled.
Future<String?> pickMediaFile(BuildContext context, MediaKind kind) async =>
    (await pickMediaFiles(context, kind, multiple: false)).firstOrNull;

/// Like [pickMediaFile], several files at once (Image Slide Show).
Future<List<String>> pickMediaFiles(BuildContext context, MediaKind kind, {bool multiple = true}) async {
  final List<PlatformFile> files;
  final type = switch (kind) {
    MediaKind.image => FileType.image,
    MediaKind.video => FileType.video,
    MediaKind.html => FileType.custom,
  };
  final ext = kind == MediaKind.html ? const ['html', 'htm'] : null;
  try {
    if (multiple) {
      files = await FilePicker.pickFiles(type: type, allowedExtensions: ext);
    } else {
      final f = await FilePicker.pickFile(type: type, allowedExtensions: ext);
      files = [?f];
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open files: $e')));
    }
    return const [];
  }
  if (files.isEmpty || !context.mounted) return const [];
  final messenger = ScaffoldMessenger.of(context);
  final big = files.fold<int>(0, (n, f) => n + (f.lengthSync() ?? 0)) > (50 << 20);
  if (big) {
    final what = files.length == 1 ? files.single.name : '${files.length} files';
    messenger.showSnackBar(SnackBar(content: Text('Copying $what…')));
  }
  final out = <String>[];
  for (final f in files) {
    try {
      final p = await impl.importPickedFile(f);
      if (p != null) out.add(p);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not import ${f.name}: $e')));
    }
  }
  return out;
}
