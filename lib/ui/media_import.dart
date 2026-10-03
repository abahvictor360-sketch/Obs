import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'media_import_stub.dart' if (dart.library.io) 'media_import_io.dart' as impl;

enum MediaKind { image, video }

/// Opens the tablet's file manager (Android Files / iPad Files app) and
/// copies the picked file into the app's storage, so the source keeps
/// working after a restart even if the original was on a USB drive, SD card
/// or cloud provider. Returns the local path, or null if cancelled.
Future<String?> pickMediaFile(BuildContext context, MediaKind kind) async {
  final List<PlatformFile> files;
  try {
    files = await FilePicker.pickFiles(type: kind == MediaKind.image ? FileType.image : FileType.video);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open files: $e')));
    }
    return null;
  }
  if (files.isEmpty) return null;
  final f = files.single;
  if (!context.mounted) return null;
  final messenger = ScaffoldMessenger.of(context);
  final big = (f.lengthSync() ?? 0) > (50 << 20);
  if (big) messenger.showSnackBar(SnackBar(content: Text('Copying ${f.name}…')));
  try {
    return await impl.importPickedFile(f);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not import ${f.name}: $e')));
    return null;
  }
}
