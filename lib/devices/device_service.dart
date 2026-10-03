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

/// A screen connected over USB-C (DisplayPort alt mode), HDMI, a docking
/// station or wirelessly (Miracast / AirPlay).
class ExternalDisplayInfo {
  const ExternalDisplayInfo({
    this.id = '',
    required this.name,
    required this.width,
    required this.height,
    this.refreshRate = 60,
    this.presenting = false,
    this.needsReconnect = false,
  });

  /// Native display id ('' if unknown).
  final String id;
  final String name;
  final int width, height;
  final double refreshRate;

  /// The app is showing the program on it (otherwise the system mirrors
  /// the tablet).
  final bool presenting;

  /// iPad: the screen is mirroring or used by Stage Manager; reconnecting it
  /// (or turning off Stage Manager's extended display) lets the app show
  /// the program.
  final bool needsReconnect;

  static ExternalDisplayInfo? fromMap(dynamic m) {
    if (m is! Map) return null;
    return ExternalDisplayInfo(
      id: '${m['id'] ?? ''}',
      name: '${m['name'] ?? 'External display'}',
      width: (m['width'] as num?)?.toInt() ?? 1920,
      height: (m['height'] as num?)?.toInt() ?? 1080,
      refreshRate: (m['refreshRate'] as num?)?.toDouble() ?? 60,
      presenting: m['presenting'] == true,
      needsReconnect: m['needsReconnect'] == true,
    );
  }
}

/// What a USB-C docking station (or hub) brings: a screen, wired network,
/// USB audio, capture cards and power. The tablet doesn't report "a dock"
/// as such, so it's recognised from what's plugged in through it.
class DockInfo {
  const DockInfo({
    this.display,
    this.displays = const [],
    this.ethernet = false,
    this.usbAudio = false,
    this.usbVideo = false,
    this.usbDevices = 0,
    this.charging = false,
  });

  /// The screen the app uses (the chosen one, or the first).
  final ExternalDisplayInfo? display;

  /// Every connected screen the program can be sent to.
  final List<ExternalDisplayInfo> displays;
  final bool ethernet, usbAudio, usbVideo, charging;

  /// USB devices attached (Android only; 0 on iPad).
  final int usbDevices;

  /// A dock or hub is connected: a wired screen, a wired network, or several
  /// USB devices at once.
  bool get docked => display != null || ethernet || usbDevices >= 2 || (usbAudio && usbVideo);

  /// What the dock provides, for display ("Screen", "Ethernet", ...).
  List<String> get features => [
        if (display != null) 'Screen',
        if (ethernet) 'Ethernet',
        if (usbAudio) 'USB audio',
        if (usbVideo) 'Capture/USB camera',
        if (charging) 'Charging',
      ];

  factory DockInfo.fromMap(Map m) {
    final display = ExternalDisplayInfo.fromMap(m['display']);
    final list = [
      for (final d in (m['displays'] as List? ?? const [])) ?ExternalDisplayInfo.fromMap(d),
    ];
    return DockInfo(
        display: display,
        displays: list.isEmpty && display != null ? [display] : list,
        ethernet: m['ethernet'] == true,
        usbAudio: m['usbAudio'] == true,
        usbVideo: m['usbVideo'] == true,
        usbDevices: (m['usbDevices'] as num?)?.toInt() ?? 0,
        charging: m['charging'] == true,
      );
  }
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
  DockInfo dock = const DockInfo();
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
    try {
      dock = DockInfo.fromMap(await _method.invokeMethod<Map>('getDock') ?? {});
    } catch (_) {}
    _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
    await Future.wait([refreshUsbCameras(), refreshAudioInputs()]);
    notifyListeners();
  }

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    switch (e['type']) {
      case 'network':
        network = NetworkInfo.fromMap(e);
      case 'dock':
        dock = DockInfo.fromMap(e);
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

  /// USB microphones, sound cards and audio interfaces (direct, through a
  /// hub or a docking station).
  List<AudioInput> get usbAudioInputs => audioInputs.where((i) => i.type == 'usb').toList();

  /// The input a Mic/Aux source with device [setting] actually records from.
  /// 'default' is automatic: a USB sound card when one is plugged in,
  /// otherwise the system's choice (null). A device that was unplugged also
  /// falls back to automatic.
  AudioInput? resolveAudioInput(String? setting) {
    if (setting != null && setting != 'default') {
      final picked = audioInputs.where((i) => i.id == setting).firstOrNull;
      if (picked != null) return picked;
    }
    return usbAudioInputs.firstOrNull;
  }

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

  /// 'program' shows the program full screen on the connected screen,
  /// 'mirror' leaves it to the system (mirrors the tablet).
  /// [displayId]: which connected screen (null = the first one).
  Future<void> setDisplayMode(String mode, {String? displayId}) async {
    if (!supported) return;
    try {
      final m = await _method.invokeMethod<Map>('setDisplayMode', {'mode': mode, 'displayId': displayId});
      if (m != null) dock = DockInfo.fromMap(m);
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
  String? _lastDisplayMode;
  int _lastCameraCount = -1;

  void _onDevices() {
    // A capture card was just plugged in: try again if a source wants one.
    if (devices.usbCameras.length != _lastCameraCount) {
      _lastCameraCount = devices.usbCameras.length;
      _sync();
      return;
    }
    // A sound card was plugged in or out: re-route the microphone.
    final inputs = devices.audioInputs.map((i) => i.id).join(',');
    if (inputs != _lastInputs) {
      _lastInputs = inputs;
      _sync();
    }
  }

  String _lastInputs = '';

  void _sync() {
    if (!devices.supported) return;
    String? wanted;
    var wantUsb = false;
    for (final s in studio.activeSources) {
      if (s.type == SourceType.usbVideo) {
        wantUsb = true;
        wanted ??= s.settings['device'] as String?;
      }
    }
    if (wantUsb) {
      if (devices.usbCameras.isNotEmpty) devices.openUsbVideo(wanted);
    } else {
      devices.closeUsbVideo();
    }

    final mic = studio.sources.where((s) => s.type == SourceType.audioInput).firstOrNull;
    final input = devices.resolveAudioInput(mic?.settings['device'] as String?)?.id ?? 'default';
    if (input != _lastInput) {
      _lastInput = input;
      devices.setAudioInput(input);
    }
    final pw = studio.settings.preferWired;
    if (pw != _lastPreferWired) {
      _lastPreferWired = pw;
      devices.setPreferWired(pw);
    }
    final dm = '${studio.settings.externalDisplay}@${studio.settings.externalDisplayId ?? ''}';
    if (dm != _lastDisplayMode) {
      _lastDisplayMode = dm;
      devices.setDisplayMode(studio.settings.externalDisplay, displayId: studio.settings.externalDisplayId);
    }
  }

  @visibleForTesting
  void sync() => _sync();

  void dispose() {
    studio.removeListener(_sync);
    devices.removeListener(_onDevices);
  }
}
