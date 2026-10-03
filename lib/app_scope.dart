import 'package:flutter/widgets.dart';

import 'core/studio_controller.dart';
import 'devices/device_service.dart';
import 'output/output_engine.dart';
import 'plugins/plugin_manager.dart';
import 'render/media_services.dart';

/// Gives every widget access to the app's long-lived services.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.studio,
    required this.output,
    required this.cameras,
    required this.media,
    required this.plugins,
    required this.devices,
    required super.child,
  });

  final StudioController studio;
  final OutputEngine output;
  final CameraService cameras;
  final MediaService media;
  final PluginManager plugins;
  final DeviceService devices;

  static AppScope of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(s != null, 'AppScope not found');
    return s!;
  }

  @override
  bool updateShouldNotify(AppScope old) =>
      studio != old.studio || output != old.output || cameras != old.cameras || media != old.media ||
      plugins != old.plugins ||
      devices != old.devices;
}
