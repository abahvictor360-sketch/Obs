import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_scope.dart';
import 'core/storage.dart';
import 'core/studio_controller.dart';
import 'devices/device_service.dart';
import 'ndi/ndi_controller.dart';
import 'network_video/network_video_service.dart';
import 'output/external_display_output.dart';
import 'output/output_engine.dart';
import 'plugins/plugin_bridge.dart';
import 'plugins/plugin_manager.dart';
import 'render/media_services.dart';
import 'ui/studio_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final studio = await StudioController.load(StudioStorage.platformDefault());
  final output = OutputEngine(studio: studio);
  final cameras = CameraService();
  final media = MediaService();
  SourceActivityTracker(studio, cameras, media);
  await output.init();
  final plugins = PluginManager(createPlatformPluginBackend());
  await plugins.load();
  PluginBridge(studio, output, plugins);
  NdiController(plugins, output);
  final devices = DeviceService();
  await devices.init();
  DeviceActivityTracker(studio, devices);
  ExternalDisplayOutput(output: output, devices: devices);
  final networkVideo = NetworkVideoService();
  NetworkVideoTracker(studio, networkVideo);

  runApp(ObsTabletApp(studio: studio, output: output, cameras: cameras, media: media, plugins: plugins, devices: devices, networkVideo: networkVideo));
}

class ObsTabletApp extends StatefulWidget {
  const ObsTabletApp({
    super.key,
    required this.studio,
    required this.output,
    required this.cameras,
    required this.media,
    required this.plugins,
    required this.devices,
    required this.networkVideo,
  });

  final StudioController studio;
  final OutputEngine output;
  final CameraService cameras;
  final MediaService media;
  final PluginManager plugins;
  final DeviceService devices;
  final NetworkVideoService networkVideo;

  @override
  State<ObsTabletApp> createState() => _ObsTabletAppState();
}

class _ObsTabletAppState extends State<ObsTabletApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist immediately when the app goes to the background.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      widget.studio.save();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      studio: widget.studio,
      output: widget.output,
      cameras: widget.cameras,
      media: widget.media,
      plugins: widget.plugins,
      devices: widget.devices,
      networkVideo: widget.networkVideo,
      child: MaterialApp(
        title: 'ObsPad',
        debugShowCheckedModeBanner: false,
        theme: buildObsTheme(),
        home: const StudioScreen(),
      ),
    );
  }
}
