import 'storage_stub.dart' if (dart.library.io) 'storage_io.dart' as impl;

/// Tiny key/value file store for the scene collection and settings.
abstract class StudioStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);

  /// Platform default: JSON files in the app documents directory on
  /// Android/iOS, in-memory on the web preview.
  static StudioStorage platformDefault() => impl.createStorage();
}

class MemoryStorage implements StudioStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;
}
