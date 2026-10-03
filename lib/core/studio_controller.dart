import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'storage.dart';

/// Central state for the studio: the scene collection, selection, studio
/// mode and settings. UI widgets listen to this; every mutation goes through
/// a method here so changes are persisted and listeners notified.
class StudioController extends ChangeNotifier {
  StudioController({required this.storage, SceneCollection? collection, OutputSettings? settings})
      : collection = collection ?? SceneCollection.starter(),
        settings = settings ?? OutputSettings();

  final StudioStorage storage;
  SceneCollection collection;
  OutputSettings settings;

  /// Studio Mode: edit the preview scene, then transition it to program.
  bool studioMode = false;

  /// Selected scene item (in the scene being edited).
  String? selectedItemId;

  /// Bumped every time a transition to program starts; the program view
  /// uses it to animate between scenes.
  int transitionSerial = 0;

  Timer? _saveTimer;

  static const _collectionKey = 'scene_collection.json';
  static const _settingsKey = 'settings.json';

  /// Loads persisted state, falling back to a starter collection.
  static Future<StudioController> load(StudioStorage storage) async {
    SceneCollection? collection;
    OutputSettings? settings;
    try {
      final raw = await storage.read(_collectionKey);
      if (raw != null) {
        collection = SceneCollection.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('Failed to load scene collection: $e');
    }
    try {
      final raw = await storage.read(_settingsKey);
      if (raw != null) {
        settings = OutputSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('Failed to load settings: $e');
    }
    return StudioController(storage: storage, collection: collection, settings: settings);
  }

  // ---------------------------------------------------------------------------
  // Lookups

  List<Scene> get scenes => collection.scenes;
  List<Source> get sources => collection.sources;

  Scene get programScene => sceneById(collection.programSceneId)!;
  Scene get previewScene => sceneById(collection.previewSceneId)!;

  /// The scene the Sources panel and canvas editing act on. In studio mode
  /// that is the preview; otherwise it's what is live.
  Scene get editingScene => studioMode ? previewScene : programScene;

  Scene? sceneById(String id) {
    for (final s in collection.scenes) {
      if (s.id == id) return s;
    }
    return null;
  }

  Source? sourceById(String id) {
    for (final s in collection.sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  SceneItem? get selectedItem {
    final id = selectedItemId;
    if (id == null) return null;
    for (final i in editingScene.items) {
      if (i.id == id) return i;
    }
    return null;
  }

  SceneItem? itemById(String id) {
    for (final i in editingScene.items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// Index of the first visible Screen Capture item in [scene], or -1. The
  /// output composites that item natively (see OutputEngine).
  int screenItemIndex(Scene scene) {
    for (var i = 0; i < scene.items.length; i++) {
      final it = scene.items[i];
      if (it.visible && sourceById(it.sourceId)?.type == SourceType.screen) return i;
    }
    return -1;
  }

  /// Audio-capable sources, in the order they appear in the mixer.
  List<Source> get audioSources => collection.sources.where((s) => s.type.hasAudio).toList();

  /// Number of scene items across all scenes that reference [sourceId].
  int usageCount(String sourceId) =>
      collection.scenes.fold(0, (n, s) => n + s.items.where((i) => i.sourceId == sourceId).length);

  // ---------------------------------------------------------------------------
  // Scenes

  /// Clicking a scene: in normal mode it goes live immediately (using the
  /// current transition); in studio mode it only changes the preview.
  void selectScene(String sceneId) {
    if (sceneById(sceneId) == null) return;
    selectedItemId = null;
    if (studioMode) {
      collection.previewSceneId = sceneId;
    } else {
      if (collection.programSceneId != sceneId) {
        collection.programSceneId = sceneId;
        collection.previewSceneId = sceneId;
        transitionSerial++;
      }
    }
    _changed();
  }

  /// Studio mode "Transition" button: preview -> program. Like OBS, the old
  /// program scene becomes the new preview (swap).
  void transitionToProgram() {
    if (!studioMode) return;
    final oldProgram = collection.programSceneId;
    if (oldProgram == collection.previewSceneId) return;
    collection.programSceneId = collection.previewSceneId;
    collection.previewSceneId = oldProgram;
    selectedItemId = null;
    transitionSerial++;
    _changed();
  }

  void setStudioMode(bool enabled) {
    if (studioMode == enabled) return;
    studioMode = enabled;
    // Entering studio mode starts with preview == program.
    collection.previewSceneId = collection.programSceneId;
    selectedItemId = null;
    notifyListeners();
  }

  Scene addScene([String? name]) {
    final scene = Scene(id: newId('scene'), name: _uniqueSceneName(name ?? 'Scene'));
    collection.scenes.add(scene);
    selectScene(scene.id);
    return scene;
  }

  Scene duplicateScene(String sceneId) {
    final src = sceneById(sceneId)!;
    final copy = Scene(
      id: newId('scene'),
      name: _uniqueSceneName(src.name),
      items: src.items.map((i) => i.duplicate()).toList(),
    );
    collection.scenes.insert(collection.scenes.indexOf(src) + 1, copy);
    _changed();
    return copy;
  }

  void renameScene(String sceneId, String name) {
    final s = sceneById(sceneId);
    if (s == null || name.trim().isEmpty) return;
    s.name = name.trim();
    _changed();
  }

  /// Removes a scene. The last remaining scene can't be removed.
  bool removeScene(String sceneId) {
    if (collection.scenes.length <= 1) return false;
    final idx = collection.scenes.indexWhere((s) => s.id == sceneId);
    if (idx < 0) return false;
    collection.scenes.removeAt(idx);
    final fallback = collection.scenes[math.min(idx, collection.scenes.length - 1)].id;
    if (collection.programSceneId == sceneId) collection.programSceneId = fallback;
    if (collection.previewSceneId == sceneId) collection.previewSceneId = fallback;
    selectedItemId = null;
    _changed();
    return true;
  }

  /// Moves the scene at [from] so it ends up at index [to].
  void moveScene(int from, int to) {
    final s = collection.scenes.removeAt(from);
    collection.scenes.insert(to.clamp(0, collection.scenes.length), s);
    _changed();
  }

  String _uniqueSceneName(String base) {
    final names = collection.scenes.map((s) => s.name).toSet();
    if (!names.contains(base)) return base;
    var n = 2;
    while (names.contains('$base $n')) {
      n++;
    }
    return '$base $n';
  }

  String uniqueSourceName(String base) {
    final names = collection.sources.map((s) => s.name).toSet();
    if (!names.contains(base)) return base;
    var n = 2;
    while (names.contains('$base $n')) {
      n++;
    }
    return '$base $n';
  }

  // ---------------------------------------------------------------------------
  // Sources & scene items

  /// Creates a new source and adds it to the editing scene, sized to fit the
  /// canvas like OBS does for new sources.
  SceneItem addNewSource(SourceType type, {String? name, Map<String, dynamic>? settings}) {
    final source = Source(
      id: newId('src'),
      name: uniqueSourceName(name ?? type.label),
      type: type,
    );
    if (settings != null) source.settings.addAll(settings);
    collection.sources.add(source);
    return addExistingSource(source.id);
  }

  /// Adds another item for an existing (global) source to the editing scene.
  SceneItem addExistingSource(String sourceId) {
    final source = sourceById(sourceId)!;
    final cw = settings.canvasWidth.toDouble();
    final ch = settings.canvasHeight.toDouble();
    final t = _defaultTransformFor(source, cw, ch);
    final item = SceneItem(id: newId('item'), sourceId: sourceId, transform: t);
    editingScene.items.add(item);
    selectedItemId = source.type.isVisual ? item.id : null;
    _changed();
    return item;
  }

  ItemTransform _defaultTransformFor(Source s, double cw, double ch) {
    switch (s.type) {
      case SourceType.color:
        return ItemTransform(width: cw, height: ch);
      case SourceType.text:
        final w = cw * 0.6, h = ch * 0.12;
        return ItemTransform(x: (cw - w) / 2, y: (ch - h) / 2, width: w, height: h);
      case SourceType.camera:
      case SourceType.media:
        return ItemTransform(width: cw, height: ch, fit: FitMode.cover);
      case SourceType.screen:
      case SourceType.usbVideo:
      case SourceType.networkVideo:
        return ItemTransform(width: cw, height: ch, fit: FitMode.contain);
      case SourceType.image:
        final w = cw / 2, h = ch / 2;
        return ItemTransform(x: (cw - w) / 2, y: (ch - h) / 2, width: w, height: h, fit: FitMode.contain);
      case SourceType.audioInput:
        return ItemTransform(width: 0, height: 0);
      case SourceType.plugin:
        final w = (s.settings['width'] as num?)?.toDouble() ?? cw / 2;
        final h = (s.settings['height'] as num?)?.toDouble() ?? ch / 2;
        final k = math.min(1.0, math.min(cw / w, ch / h));
        return ItemTransform(x: (cw - w * k) / 2, y: (ch - h * k) / 2, width: w * k, height: h * k);
    }
  }

  void renameSource(String sourceId, String name) {
    final s = sourceById(sourceId);
    if (s == null || name.trim().isEmpty) return;
    s.name = name.trim();
    _changed();
  }

  void updateSourceSettings(String sourceId, Map<String, dynamic> values) {
    final s = sourceById(sourceId);
    if (s == null) return;
    s.settings.addAll(values);
    _changed();
  }

  /// Removes a scene item. If no other scene uses the source, the source is
  /// deleted too (OBS keeps orphaned sources only while referenced).
  void removeItem(String itemId) {
    final scene = editingScene;
    final idx = scene.items.indexWhere((i) => i.id == itemId);
    if (idx < 0) return;
    final item = scene.items.removeAt(idx);
    if (selectedItemId == itemId) selectedItemId = null;
    if (usageCount(item.sourceId) == 0) {
      final src = sourceById(item.sourceId);
      // Audio input sources live in the mixer even without scene items.
      if (src != null && src.type != SourceType.audioInput) {
        collection.sources.remove(src);
      }
    }
    _changed();
  }

  /// Deletes a source everywhere (all scenes).
  void removeSource(String sourceId) {
    for (final s in collection.scenes) {
      s.items.removeWhere((i) => i.sourceId == sourceId);
    }
    collection.sources.removeWhere((s) => s.id == sourceId);
    if (selectedItem == null) selectedItemId = null;
    _changed();
  }

  void duplicateItem(String itemId) {
    final scene = editingScene;
    final idx = scene.items.indexWhere((i) => i.id == itemId);
    if (idx < 0) return;
    final copy = scene.items[idx].duplicate()
      ..transform.x += 40
      ..transform.y += 40;
    scene.items.insert(idx + 1, copy);
    selectedItemId = copy.id;
    _changed();
  }

  void selectItem(String? itemId) {
    if (selectedItemId == itemId) return;
    selectedItemId = itemId;
    notifyListeners();
  }

  void setItemVisible(String itemId, bool visible) {
    final item = itemById(itemId);
    if (item == null) return;
    item.visible = visible;
    _changed();
  }

  void setItemLocked(String itemId, bool locked) {
    final item = itemById(itemId);
    if (item == null) return;
    item.locked = locked;
    _changed();
  }

  /// Moves an item using the *display* order of the Sources panel (top-most
  /// first): the item at display index [from] ends up at display index [to].
  void moveItemDisplay(int from, int to) {
    final items = editingScene.items;
    final n = items.length;
    final it = items.removeAt(n - 1 - from);
    items.insert((n - 1 - to).clamp(0, items.length), it);
    _changed();
  }

  void moveItem(String itemId, OrderMove move) {
    final items = editingScene.items;
    final idx = items.indexWhere((i) => i.id == itemId);
    if (idx < 0) return;
    final it = items.removeAt(idx);
    switch (move) {
      case OrderMove.up:
        items.insert(math.min(idx + 1, items.length), it);
      case OrderMove.down:
        items.insert(math.max(idx - 1, 0), it);
      case OrderMove.top:
        items.add(it);
      case OrderMove.bottom:
        items.insert(0, it);
    }
    _changed();
  }

  /// Applies an in-progress gesture transform. Call [commitTransform] when the
  /// gesture ends to persist.
  void updateTransform(String itemId, void Function(ItemTransform t) edit, {bool persist = false}) {
    final item = itemById(itemId);
    if (item == null || item.locked) return;
    edit(item.transform);
    if (persist) {
      _changed();
    } else {
      notifyListeners();
    }
  }

  void commitTransform() => _changed();

  void updateColor(String itemId, void Function(ColorCorrection c) edit) {
    final item = itemById(itemId);
    if (item == null) return;
    edit(item.color);
    _changed();
  }

  /// Transform presets from OBS's right-click > Transform menu.
  void applyTransformPreset(String itemId, TransformPreset preset) {
    final item = itemById(itemId);
    if (item == null) return;
    final t = item.transform;
    final cw = settings.canvasWidth.toDouble();
    final ch = settings.canvasHeight.toDouble();
    switch (preset) {
      case TransformPreset.reset:
        item.transform = ItemTransform(width: cw, height: ch, fit: t.fit);
      case TransformPreset.fitToScreen:
        final aspect = t.width / math.max(t.height, 1);
        var w = cw, h = cw / aspect;
        if (h > ch) {
          h = ch;
          w = ch * aspect;
        }
        t
          ..width = w
          ..height = h
          ..x = (cw - w) / 2
          ..y = (ch - h) / 2
          ..rotation = 0;
      case TransformPreset.stretchToScreen:
        t
          ..x = 0
          ..y = 0
          ..width = cw
          ..height = ch
          ..rotation = 0;
      case TransformPreset.centerToScreen:
        t
          ..x = (cw - t.width) / 2
          ..y = (ch - t.height) / 2;
      case TransformPreset.centerHorizontally:
        t.x = (cw - t.width) / 2;
      case TransformPreset.centerVertically:
        t.y = (ch - t.height) / 2;
      case TransformPreset.rotate90cw:
        t.rotation = (t.rotation + 90) % 360;
      case TransformPreset.rotate90ccw:
        t.rotation = (t.rotation - 90) % 360;
      case TransformPreset.flipHorizontal:
        t.flipH = !t.flipH;
      case TransformPreset.flipVertical:
        t.flipV = !t.flipV;
    }
    _changed();
  }

  // ---------------------------------------------------------------------------
  // Audio mixer

  void setVolume(String sourceId, double volume) {
    final s = sourceById(sourceId);
    if (s == null) return;
    s.volume = volume.clamp(0.0, 1.0);
    _changed();
  }

  void setMuted(String sourceId, bool muted) {
    final s = sourceById(sourceId);
    if (s == null) return;
    s.muted = muted;
    _changed();
  }

  /// Effective microphone gain sent to the native audio pipeline.
  double get micGain {
    final mics = collection.sources.where((s) => s.type == SourceType.audioInput);
    if (mics.isEmpty) return 0;
    final m = mics.first;
    return m.muted ? 0 : m.volume;
  }

  /// Gain for other apps' audio captured with the screen (first Screen
  /// Capture source's fader).
  double get screenAudioGain {
    for (final s in collection.sources) {
      if (s.type == SourceType.screen) return s.muted ? 0 : s.volume;
    }
    return 1;
  }

  // ---------------------------------------------------------------------------
  // Transitions & settings

  void setTransition(TransitionType type) {
    collection.transition = type;
    _changed();
  }

  void setTransitionDuration(int ms) {
    collection.transitionMs = ms.clamp(50, 5000);
    _changed();
  }

  void updateSettings(void Function(OutputSettings s) edit) {
    edit(settings);
    _changed();
  }

  void replaceCollection(SceneCollection c) {
    collection = c;
    selectedItemId = null;
    transitionSerial++;
    _changed();
  }

  // ---------------------------------------------------------------------------
  // Persistence

  void _changed() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), save);
  }

  Future<void> save() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      await storage.write(_collectionKey, jsonEncode(collection.toJson()));
      await storage.write(_settingsKey, jsonEncode(settings.toJson()));
    } catch (e) {
      debugPrint('Failed to save: $e');
    }
  }

  String exportCollection() => const JsonEncoder.withIndent('  ').convert(collection.toJson());

  @override
  void dispose() {
    if (_saveTimer != null) {
      save();
    }
    super.dispose();
  }
}

enum OrderMove { up, down, top, bottom }

enum TransformPreset {
  reset('Reset Transform'),
  fitToScreen('Fit to Screen'),
  stretchToScreen('Stretch to Screen'),
  centerToScreen('Center to Screen'),
  centerHorizontally('Center Horizontally'),
  centerVertically('Center Vertically'),
  rotate90cw('Rotate 90° CW'),
  rotate90ccw('Rotate 90° CCW'),
  flipHorizontal('Flip Horizontal'),
  flipVertical('Flip Vertical');

  const TransformPreset(this.label);
  final String label;
}
