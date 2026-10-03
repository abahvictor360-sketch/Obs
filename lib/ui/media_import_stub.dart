import 'package:file_picker/file_picker.dart';

/// Web: use the blob URL directly.
Future<String?> importPickedFile(PlatformFile f) async => f.uri.toString();
