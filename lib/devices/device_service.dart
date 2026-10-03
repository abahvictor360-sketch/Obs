import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/studio_controller.dart';

class UsbCamera {
  const UsbCamera(this.id, this.name);
  final String id, name;
}

class AudioInput {
  const AudioInput(this.id, this.name, this.type);
  final String id, name;

  /// usb | bluetooth | headset | builtin | other
  final String type;
}

class OpenUsbVideo {
  const OpenUsbVideo({required this.id, required this.textureId, required this.width, required this.height});
  final String id;
  final int textureId, width, height;
}

class NetworkInfo {
  const NetworkInfo({
    this.transport = 'unknown',
    this.wiredAvailable = false,
    this.preferWired = false,
    this.canPreferWired = false,
  });

  /// ethernet | wifi | cellular | other | none | unknown
  final String transport;
  final bool wiredAvailable;
  final bool preferWired;
  final bool canPreferWired;

  factory NetworkInfo.fromMap(Map m) => NetworkInfo(
        transport: m['transport'] as String? ?? 'unknown',
        wiredAvailable: m['wiredAvailable'] == true,
        preferWired: m['preferWired'] == true,
        canPreferWired: m['canPreferWired'] == true,
      );
}

/// Hardware plugged in over USB OTG / USB-C and the network type:
/// capture cards & webcams (UVC), USB microphones, USB Ethernet.
class DeviceService extends ChangeNotifier {
  DeviceService({MethodChannel? method, EventChannel? events})
      : _method = method ?? const MethodChannel('obs_tablet/devices'),
        _events = events ?? const EventChannel('obs_tablet/device_events');

  final MethodChannel _method;
  final EventChannel _events;
  StreamSubscription<dynamic>? _sub;

  bool supported = false;
  NetworkInfo network = const NetworkInfo();
  List<UsbCamera> usbCameras = [];
  List<AudioInput> audioInputs = [];
  OpenUsbVideo? usbVideo;
  String? usbError;
  bool usbOpening = false;

  Future<void> init() async {
    try {
      network = NetworkInfo.fromMap(await _method.invokeMethod<Map>('getNetwork') ?? {});
      supported = true;
    } on MissingPluginException {
      supported = false;
      return;
    } catch (_) {
      supported = false;
      return;
    }
    _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
    await Future.wait([refreshUsbCameras(), refreshAudioInputs()]);
    notifyListeners();
  }

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    switch (e['type']) {
      case 'network':
        network = NetworkInfo.fromMap(e);
      case 'audioInputs':
        audioInputs = _parseInputs(e['inputs']);
      case 'usbVideo':
        switch (e['state']) {
          case 'attached':
            usbError = null;
            refreshUsbCameras();
          case 'detached':
            if (usbVideo?.id == e['id']) usbVideo = null;
            refreshUsbCameras();
          case 'opened':
            usbVideo = _parseOpen(e);
            usbError = null;
          case 'closed':
            if (usbVideo?.id == e['id']) usbVideo = null;
          case 'error':
            usbError = '${e['message']}';
        }
    }
    notifyListeners();
  }

  static OpenUsbVideo _parseOpen(Map m) => OpenUsbVideo(
        id: '${m['id']}',
        textureId: (m['textureId'] as num).toInt(),
        width: (m['width'] as num?)?.toInt() ?? 1280,
        height: (m['height'] as num?)?.toInt() ?? 720,
      );

  static List<AudioInput> _parseInputs(dynamic list) => [
        for (final m in (list as List? ?? const []).cast<Map>())
          AudioInput('${m['id']}', '${m['name']}', '${m['type']}'),
      ];

  Future<void> refreshUsbCameras() async {
    if (!supported) return;
    try {
      final list = await _method.invokeMethod<List>('listUsbCameras') ?? const [];
      usbCameras = [for (final m in list.cast<Map>()) UsbCamera('${m['id']}', '${m['name']}')];
    } catch (_) {
      usbCameras = [];
    }
    notifyListeners();
  }

  Future<void> refreshAudioInputs() async {
    if (!supported) return;
    try {
      audioInputs = _parseInputs(await _method.invokeMethod<List>('listAudioInputs'));
    } catch (_) {}
    notifyListeners();
  }

  /// Opens a USB video device ([id] null = first one). Android asks for USB
  /// permission the first time.
  Future<void> openUsbVideo(String? id) async {
    if (!supported || usbOpening) return;
    if (usbVideo != null && (id == null || id.isEmpty || usbVideo!.id == id)) return;
    usbOpening = true;
    usbError = null;
    notifyListeners();
    try {
      final m = await _method.invokeMethod<Map>('openUsbCamera', {'id': (id == null || id.isEmpty) ? null : id});
      if (m != null) usbVideo = _parseOpen(m);
    } on PlatformException catch (e) {
      usbError = e.message ?? e.code;
    } finally {
      usbOpening = false;
      notifyListeners();
    }
  }

  Future<void> closeUsbVideo() async {
    if (usbVideo == null) return;
    usbVideo = null;
    notifyListeners();
    try {
      await _method.invokeMethod('closeUsbCamera');
    } catch (_) {}
  }

  Future<void> setAudioInput(String? id) async {
    if (!supported) return;
    try {
      await _method.invokeMethod('setAudioInput', {'id': (id == null || id == 'default') ? null : id});
    } catch (_) {}
  }

  Future<void> setPreferWired(bool enabled) async {
    if (!supported) return;
    try {
      network = NetworkInfo.fromMap(await _method.invokeMethod<Map>('setPreferWired', {'enabled': enabled}) ?? {});
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// Opens/closes the USB video device for visible USB Video sources, applies
/// the Mic/Aux source's chosen input, and the "prefer wired" setting.
class DeviceActivityTracker {
  DeviceActivityTracker(this.studio, this.devices) {
    studio.addListener(_sync);
    devices.addListener(_onDevices);
    _sync();
  }

  final StudioController studio;
  final DeviceService devices;
  String? _lastInput;
  bool? _lastPreferWired;
  int _lastCameraCount = -1;

  void _onDevices() {
    // A capture card was just plugged in: try again if a source wants one.
    if (devices.usbCameras.length != _lastCameraCount) {
      _lastCameraCount = devices.usbCameras.length;
      _sync();
    }
  }

  void _sync() {
    if (!devices.supported) return;
    String? wanted;
    var wantUsb = false;
    for (final scene in {studio.programScene, studio.previewScene}) {
      for (final item in scene.items) {
        if (!item.visible) continue;
        final s = studio.sourceById(item.sourceId);
        if (s?.type == SourceType.usbVideo) {
          wantUsb = true;
          wanted ??= s!.settings['device'] as String?;
        }
      }
    }
    if (wantUsb) {
      if (devices.usbCameras.isNotEmpty) devices.openUsbVideo(wanted);
    } else {
      devices.closeUsbVideo();
    }

    final mic = studio.sources.where((s) => s.type == SourceType.audioInput).firstOrNull;
    final input = mic?.settings['device'] as String? ?? 'default';
    if (input != _lastInput) {
      _lastInput = input;
      devices.setAudioInput(input);
    }
    final pw = studio.settings.preferWired;
    if (pw != _lastPreferWired) {
      _lastPreferWired = pw;
      devices.setPreferWired(pw);
    }
  }

  @visibleForTesting
  void sync() => _sync();

  void dispose() {
    studio.removeListener(_sync);
    devices.removeListener(_onDevices);
  }
}
