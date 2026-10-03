// Core data model, mirroring the concepts of libobs:
//
//  * A [Source] is a global object (camera, image, text, ...). The same
//    source can appear in several scenes, exactly like in OBS Studio.
//  * A [Scene] is an ordered list of [SceneItem]s. Each item references a
//    source and carries its own transform (position, size, rotation, crop,
//    visibility, lock) and per-item color correction.
//  * A [SceneCollection] holds all sources and scenes plus which scene is
//    on program / preview.
//
// Everything here is plain Dart so it can be unit tested and serialized to
// JSON without Flutter.

import 'dart:math' as math;

int _idCounter = 0;

/// Generates a reasonably unique id without extra dependencies.
String newId(String prefix) {
  _idCounter = (_idCounter + 1) & 0xFFFFFF;
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final r = math.Random().nextInt(1 << 30).toRadixString(36);
  return '$prefix-$t-${_idCounter.toRadixString(36)}$r';
}

enum SourceType {
  camera('Video Capture Device'),
  screen('Screen Capture'),

  /// HDMI capture card or webcam on USB OTG / USB-C (UVC).
  usbVideo('USB Video Capture'),

  /// Phone camera / IP camera over Wi-Fi (DroidCam, IP Webcam, MJPEG, HLS).
  networkVideo('Network Video (phone / IP camera)'),
  image('Image'),
  media('Media Source'),
  text('Text'),
  color('Color Source'),
  audioInput('Audio Input Capture'),

  /// A source type provided by an installed script plugin.
  plugin('Plugin Source');

  const SourceType(this.label);
  final String label;

  /// Whether the source produces pixels on the canvas.
  bool get isVisual => this != SourceType.audioInput;

  /// Whether the source shows up in the audio mixer.
  /// Screen Capture carries the audio of other apps (games, videos).
  bool get hasAudio => this == SourceType.audioInput || this == SourceType.media || this == SourceType.screen;

  static SourceType fromName(String name) =>
      SourceType.values.firstWhere((t) => t.name == name, orElse: () => SourceType.color);
}

/// A global source. [settings] is a free-form JSON map whose keys depend on
/// [type] (see [SourceDefaults]).
class Source {
  Source({
    required this.id,
    required this.name,
    required this.type,
    Map<String, dynamic>? settings,
    this.volume = 1.0,
    this.muted = false,
  }) : settings = settings ?? SourceDefaults.forType(type);

  final String id;
  String name;
  final SourceType type;
  Map<String, dynamic> settings;

  /// Linear gain 0..1 used by the audio mixer.
  double volume;
  bool muted;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'settings': settings,
        'volume': volume,
        'muted': muted,
      };

  factory Source.fromJson(Map<String, dynamic> j) {
    final type = SourceType.fromName(j['type'] as String);
    return Source(
      id: j['id'] as String,
      name: j['name'] as String,
      type: type,
      settings: {
        ...SourceDefaults.forType(type),
        ...(j['settings'] as Map? ?? const {}).cast<String, dynamic>(),
      },
      volume: (j['volume'] as num?)?.toDouble() ?? 1.0,
      muted: j['muted'] as bool? ?? false,
    );
  }

  Source copyWith({String? id, String? name}) => Source(
        id: id ?? this.id,
        name: name ?? this.name,
        type: type,
        settings: Map<String, dynamic>.from(settings),
        volume: volume,
        muted: muted,
      );
}

/// Default settings for every source type. Keys documented inline.
class SourceDefaults {
  static Map<String, dynamic> forType(SourceType type) {
    switch (type) {
      case SourceType.camera:
        return {
          'resolution': 'high', // medium 480p | high 720p | veryHigh 1080p | ultraHigh 4K | max
          'zoom': 1.0,
          'torch': false,
          'exposure': 0.0, // EV offset
          'focusLocked': false,
          'lens': 'front', // front | back | external
          // Off by default like OBS: a mirrored feed shows text backwards to viewers.
          'mirror': false,
        };
      case SourceType.screen:
        // Captures the whole device screen (other apps, games...). Pixels
        // come from the native side, see ScreenCaptureState.
        return {};
      case SourceType.usbVideo:
        return {
          'device': '', // native device id; empty = first connected
        };
      case SourceType.networkVideo:
        return {
          'kind': 'droidcam', // droidcam | ipWebcam | mjpeg | stream
          'host': '', // phone IP shown in the DroidCam / IP Webcam app
          'url': '', // for the URL kinds
          'resolution': 'auto', // DroidCam only, e.g. 1280x720
        };
      case SourceType.image:
        return {
          'path': '', // local file path
        };
      case SourceType.media:
        return {
          'path': '',
          'loop': true,
          'muted': false,
        };
      case SourceType.text:
        return {
          'text': 'Your text here',
          'fontSize': 96.0,
          'color': 0xFFFFFFFF,
          'bold': true,
          'italic': false,
          'outline': true,
          'outlineColor': 0xFF000000,
          'background': 0x00000000,
          'align': 'center', // left | center | right
        };
      case SourceType.color:
        return {
          'color': 0xFF476BD7,
          'width': 1920.0,
          'height': 1080.0,
        };
      case SourceType.audioInput:
        return {
          'device': 'default',
        };
      case SourceType.plugin:
        return {
          'plugin': '', // plugin id
          'type': '', // source type within the plugin
          'config': <String, dynamic>{}, // values for the plugin's settings
        };
    }
  }
}

enum FitMode { stretch, contain, cover }

/// Per-item transform in canvas pixel coordinates. [x]/[y] are the top-left
/// corner of the *unrotated* box; rotation happens around the box center.
class ItemTransform {
  ItemTransform({
    this.x = 0,
    this.y = 0,
    this.width = 640,
    this.height = 360,
    this.rotation = 0,
    this.cropLeft = 0,
    this.cropTop = 0,
    this.cropRight = 0,
    this.cropBottom = 0,
    this.flipH = false,
    this.flipV = false,
    this.fit = FitMode.stretch,
  });

  double x, y, width, height;

  /// Degrees, clockwise.
  double rotation;

  /// Crop as a fraction (0..1) of the source on each side.
  double cropLeft, cropTop, cropRight, cropBottom;
  bool flipH, flipV;
  FitMode fit;

  double get centerX => x + width / 2;
  double get centerY => y + height / 2;

  ItemTransform copy() => ItemTransform.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'rotation': rotation,
        'cropLeft': cropLeft,
        'cropTop': cropTop,
        'cropRight': cropRight,
        'cropBottom': cropBottom,
        'flipH': flipH,
        'flipV': flipV,
        'fit': fit.name,
      };

  factory ItemTransform.fromJson(Map<String, dynamic> j) {
    double d(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    return ItemTransform(
      x: d('x', 0),
      y: d('y', 0),
      width: d('width', 640),
      height: d('height', 360),
      rotation: d('rotation', 0),
      cropLeft: d('cropLeft', 0),
      cropTop: d('cropTop', 0),
      cropRight: d('cropRight', 0),
      cropBottom: d('cropBottom', 0),
      flipH: j['flipH'] as bool? ?? false,
      flipV: j['flipV'] as bool? ?? false,
      fit: FitMode.values.firstWhere((f) => f.name == j['fit'], orElse: () => FitMode.stretch),
    );
  }
}

/// Simple per-item color correction, similar to OBS's "Color Correction"
/// filter. All values neutral by default.
class ColorCorrection {
  ColorCorrection({
    this.opacity = 1,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
  });

  /// 0..1
  double opacity;

  /// -1..1
  double brightness;

  /// -1..1
  double contrast;

  /// -1..1 (-1 is grayscale)
  double saturation;

  bool get isNeutral => opacity == 1 && brightness == 0 && contrast == 0 && saturation == 0;

  /// 5x4 color matrix suitable for `ColorFilter.matrix`.
  List<double> toMatrix() {
    final c = contrast + 1; // 0..2
    final s = saturation + 1; // 0..2
    final b = brightness * 255;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
    final t = (1 - c) * 128 + b;
    return [
      c * (sr + s), c * sg, c * sb, 0, t, //
      c * sr, c * (sg + s), c * sb, 0, t, //
      c * sr, c * sg, c * (sb + s), 0, t, //
      0, 0, 0, opacity, 0, //
    ];
  }

  Map<String, dynamic> toJson() => {
        'opacity': opacity,
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
      };

  factory ColorCorrection.fromJson(Map<String, dynamic>? j) {
    if (j == null) return ColorCorrection();
    double d(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    return ColorCorrection(
      opacity: d('opacity', 1),
      brightness: d('brightness', 0),
      contrast: d('contrast', 0),
      saturation: d('saturation', 0),
    );
  }
}

class SceneItem {
  SceneItem({
    required this.id,
    required this.sourceId,
    ItemTransform? transform,
    ColorCorrection? color,
    this.visible = true,
    this.locked = false,
  })  : transform = transform ?? ItemTransform(),
        color = color ?? ColorCorrection();

  final String id;
  final String sourceId;
  ItemTransform transform;
  ColorCorrection color;
  bool visible;
  bool locked;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceId': sourceId,
        'transform': transform.toJson(),
        'color': color.toJson(),
        'visible': visible,
        'locked': locked,
      };

  factory SceneItem.fromJson(Map<String, dynamic> j) => SceneItem(
        id: j['id'] as String,
        sourceId: j['sourceId'] as String,
        transform: ItemTransform.fromJson((j['transform'] as Map).cast<String, dynamic>()),
        color: ColorCorrection.fromJson((j['color'] as Map?)?.cast<String, dynamic>()),
        visible: j['visible'] as bool? ?? true,
        locked: j['locked'] as bool? ?? false,
      );

  SceneItem duplicate() => SceneItem(
        id: newId('item'),
        sourceId: sourceId,
        transform: transform.copy(),
        color: ColorCorrection.fromJson(color.toJson()),
        visible: visible,
        locked: locked,
      );
}

class Scene {
  Scene({required this.id, required this.name, List<SceneItem>? items}) : items = items ?? [];

  final String id;
  String name;

  /// Bottom-most first; the last item is drawn on top (OBS shows the list
  /// reversed, top-most first).
  final List<SceneItem> items;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'items': items.map((i) => i.toJson()).toList(),
      };

  factory Scene.fromJson(Map<String, dynamic> j) => Scene(
        id: j['id'] as String,
        name: j['name'] as String,
        items: (j['items'] as List? ?? const [])
            .map((e) => SceneItem.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

enum TransitionType {
  cut('Cut'),
  fade('Fade'),
  slide('Slide'),
  swipe('Swipe'),
  fadeToBlack('Fade to Black');

  const TransitionType(this.label);
  final String label;
}

class SceneCollection {
  SceneCollection({
    required this.name,
    required this.sources,
    required this.scenes,
    required this.programSceneId,
    String? previewSceneId,
    this.transition = TransitionType.fade,
    this.transitionMs = 300,
  }) : previewSceneId = previewSceneId ?? programSceneId;

  String name;
  final List<Source> sources;
  final List<Scene> scenes;
  String programSceneId;
  String previewSceneId;
  TransitionType transition;
  int transitionMs;

  /// A fresh collection similar to what OBS Studio creates on first launch,
  /// with a bit of starter content so the canvas isn't empty.
  factory SceneCollection.starter() {
    final bg = Source(id: newId('src'), name: 'Background', type: SourceType.color)
      ..settings['color'] = 0xFF1E2230;
    final cam = Source(id: newId('src'), name: 'Camera', type: SourceType.camera);
    final title = Source(id: newId('src'), name: 'Title', type: SourceType.text)
      ..settings['text'] = 'Live from my tablet'
      ..settings['fontSize'] = 72.0;
    final mic = Source(id: newId('src'), name: 'Mic/Aux', type: SourceType.audioInput);
    final brb = Source(id: newId('src'), name: 'BRB Text', type: SourceType.text)
      ..settings['text'] = 'Be right back'
      ..settings['fontSize'] = 140.0;

    final main = Scene(id: newId('scene'), name: 'Scene', items: [
      SceneItem(
        id: newId('item'),
        sourceId: bg.id,
        transform: ItemTransform(width: 1920, height: 1080),
        locked: true,
      ),
      SceneItem(
        id: newId('item'),
        sourceId: cam.id,
        transform: ItemTransform(x: 240, y: 120, width: 1440, height: 810, fit: FitMode.cover),
      ),
      SceneItem(
        id: newId('item'),
        sourceId: title.id,
        transform: ItemTransform(x: 360, y: 940, width: 1200, height: 110),
      ),
    ]);
    final brbScene = Scene(id: newId('scene'), name: 'Be Right Back', items: [
      SceneItem(
        id: newId('item'),
        sourceId: bg.id,
        transform: ItemTransform(width: 1920, height: 1080),
        locked: true,
      ),
      SceneItem(
        id: newId('item'),
        sourceId: brb.id,
        transform: ItemTransform(x: 260, y: 440, width: 1400, height: 200),
      ),
    ]);
    return SceneCollection(
      name: 'Untitled',
      sources: [bg, cam, title, mic, brb],
      scenes: [main, brbScene],
      programSceneId: main.id,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'name': name,
        'sources': sources.map((s) => s.toJson()).toList(),
        'scenes': scenes.map((s) => s.toJson()).toList(),
        'programSceneId': programSceneId,
        'previewSceneId': previewSceneId,
        'transition': transition.name,
        'transitionMs': transitionMs,
      };

  factory SceneCollection.fromJson(Map<String, dynamic> j) {
    final scenes = (j['scenes'] as List)
        .map((e) => Scene.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    final sources = (j['sources'] as List)
        .map((e) => Source.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    // Drop items that point at missing sources so a damaged file still loads.
    final ids = sources.map((s) => s.id).toSet();
    for (final s in scenes) {
      s.items.removeWhere((i) => !ids.contains(i.sourceId));
    }
    if (scenes.isEmpty) {
      scenes.add(Scene(id: newId('scene'), name: 'Scene'));
    }
    String validScene(String? id) =>
        scenes.any((s) => s.id == id) ? id! : scenes.first.id;
    return SceneCollection(
      name: j['name'] as String? ?? 'Untitled',
      sources: sources,
      scenes: scenes,
      programSceneId: validScene(j['programSceneId'] as String?),
      previewSceneId: validScene(j['previewSceneId'] as String?),
      transition: TransitionType.values.firstWhere(
        (t) => t.name == j['transition'],
        orElse: () => TransitionType.fade,
      ),
      transitionMs: (j['transitionMs'] as num?)?.toInt() ?? 300,
    );
  }
}

/// Settings > Stream / Output / Video, like OBS's settings dialog.
class OutputSettings {
  OutputSettings({
    this.service = 'Custom',
    this.server = '',
    this.streamKey = '',
    this.canvasWidth = 1920,
    this.canvasHeight = 1080,
    this.outputWidth = 1280,
    this.outputHeight = 720,
    this.fps = 30,
    this.videoBitrateKbps = 2500,
    this.audioBitrateKbps = 160,
    this.keyframeIntervalSec = 2,
    this.recordingFormat = 'mp4',
    this.keepScreenOn = true,
    this.confirmStartStop = true,
    this.preferWired = true,
    this.externalDisplay = 'program',
  });

  String service;
  String server;
  String streamKey;
  int canvasWidth, canvasHeight;
  int outputWidth, outputHeight;
  int fps;
  int videoBitrateKbps;
  int audioBitrateKbps;
  int keyframeIntervalSec;
  String recordingFormat;
  bool keepScreenOn;
  bool confirmStartStop;

  /// Send traffic over a USB Ethernet adapter when one is connected (Android;
  /// iPadOS does this by itself).
  bool preferWired;

  /// What a screen connected through a docking station / USB-C / HDMI shows:
  /// 'program' (full-screen program output, like OBS's fullscreen projector)
  /// or 'mirror' (the tablet's own screen).
  String externalDisplay;

  /// Full publish URL: server + '/' + key (key may be empty for servers that
  /// embed it in the URL).
  String get publishUrl {
    final s = server.trim();
    final k = streamKey.trim();
    if (k.isEmpty) return s;
    return s.endsWith('/') ? '$s$k' : '$s/$k';
  }

  Map<String, dynamic> toJson() => {
        'service': service,
        'server': server,
        'streamKey': streamKey,
        'canvasWidth': canvasWidth,
        'canvasHeight': canvasHeight,
        'outputWidth': outputWidth,
        'outputHeight': outputHeight,
        'fps': fps,
        'videoBitrateKbps': videoBitrateKbps,
        'audioBitrateKbps': audioBitrateKbps,
        'keyframeIntervalSec': keyframeIntervalSec,
        'recordingFormat': recordingFormat,
        'keepScreenOn': keepScreenOn,
        'confirmStartStop': confirmStartStop,
        'preferWired': preferWired,
        'externalDisplay': externalDisplay,
      };

  factory OutputSettings.fromJson(Map<String, dynamic> j) {
    final d = OutputSettings();
    int i(String k, int def) => (j[k] as num?)?.toInt() ?? def;
    return OutputSettings(
      service: j['service'] as String? ?? d.service,
      server: j['server'] as String? ?? d.server,
      streamKey: j['streamKey'] as String? ?? d.streamKey,
      canvasWidth: i('canvasWidth', d.canvasWidth),
      canvasHeight: i('canvasHeight', d.canvasHeight),
      outputWidth: i('outputWidth', d.outputWidth),
      outputHeight: i('outputHeight', d.outputHeight),
      fps: i('fps', d.fps),
      videoBitrateKbps: i('videoBitrateKbps', d.videoBitrateKbps),
      audioBitrateKbps: i('audioBitrateKbps', d.audioBitrateKbps),
      keyframeIntervalSec: i('keyframeIntervalSec', d.keyframeIntervalSec),
      recordingFormat: j['recordingFormat'] as String? ?? d.recordingFormat,
      keepScreenOn: j['keepScreenOn'] as bool? ?? d.keepScreenOn,
      confirmStartStop: j['confirmStartStop'] as bool? ?? d.confirmStartStop,
      preferWired: j['preferWired'] as bool? ?? d.preferWired,
      externalDisplay: j['externalDisplay'] == 'mirror' ? 'mirror' : d.externalDisplay,
    );
  }
}

/// Well known ingest servers (like OBS's service list). Users can always pick
/// "Custom" and paste any rtmp:// or rtmps:// URL.
const Map<String, String> kStreamingServices = {
  'Custom': '',
  'Twitch': 'rtmp://live.twitch.tv/app',
  'YouTube (RTMPS)': 'rtmps://a.rtmps.youtube.com:443/live2',
  'YouTube (RTMP)': 'rtmp://a.rtmp.youtube.com/live2',
  'Facebook Live': 'rtmps://live-api-s.facebook.com:443/rtmp',
  'Kick': 'rtmps://fa723fc1b171.global-contribute.live-video.net:443/app',
};
