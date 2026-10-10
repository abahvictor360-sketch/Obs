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
        settings = settings ?? OutputSettings() {
    _undoBaseline = _undoState();
  }

  final StudioStorage storage;
  SceneCollection collection;
  OutputSettings settings;

  /// Studio Mode: edit the preview scene, then transition it to program.
  bool studioMode = false;

  /// The source whose properties are open. Its camera, page or stream runs
  /// even while the source is hidden, so it can be previewed before it goes
  /// into the scene.
  String? inspectedSourceId;

  void setInspectedSource(String? id) {
    if (inspectedSourceId == id) return;
    inspectedSourceId = id;
    notifyListeners();
  }

  /// Sources that need to run: visible in program or preview, plus the one
  /// being inspected. Unique, bottom-most first.
  List<Source> get activeSources {
    final out = <String, Source>{};
    final seenScenes = <String>{};
    void add(Scene scene) {
      for (final item in scene.items) {
        if (!item.visible) continue;
        final s = sourceById(item.sourceId);
        if (s == null) continue;
        out[s.id] = s;
        // A nested scene's sources run too.
        if (s.type == SourceType.scene) {
          final inner = sceneById(s.settings['sceneId'] as String? ?? '');
          if (inner != null && seenScenes.add(inner.id)) add(inner);
        }
      }
    }

    for (final scene in {programScene, previewScene, ?_outgoing}) {
      add(scene);
    }
    final inspected = inspectedSourceId == null ? null : sourceById(inspectedSourceId!);
    if (inspected != null) out[inspected.id] = inspected;
    return out.values.toList();
  }

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
    final collection = await _read(storage, _collectionKey, SceneCollection.fromJson);
    final settings = await _read(storage, _settingsKey, OutputSettings.fromJson);
    final c = StudioController(storage: storage, collection: collection, settings: settings);
    // A fresh install starts in Studio Mode, so changes are previewed before
    // they go live; after that the last choice is kept, with the preview
    // scene the app was closed with.
    if (c.settings.studioMode) {
      final preview = c.collection.previewSceneId;
      c.studioMode = true;
      if (c.sceneById(preview) != null) c.collection.previewSceneId = preview;
    }
    return c;
  }

  /// Reads [key], falling back to the previous version (`<key>.bak`) when
  /// the file is missing its end or can't be parsed.
  static Future<T?> _read<T>(StudioStorage storage, String key, T Function(Map<String, dynamic>) parse) async {
    for (final k in [key, '$key.bak']) {
      try {
        final raw = await storage.read(k);
        if (raw != null) return parse(jsonDecode(raw) as Map<String, dynamic>);
      } catch (e) {
        debugPrint('Failed to load $k: $e');
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Lookups

  List<Scene> get scenes => collection.scenes;
  List<Source> get sources => collection.sources;

  /// What is live. In Studio Mode it's a copy of the scene taken when it was
  /// transitioned to program (like OBS's "Duplicate Scene"), so editing that
  /// scene in Preview — adding, hiding or moving sources — stays off air
  /// until the next Transition. Sources themselves (camera, text, filters)
  /// are shared, as in OBS.
  Scene get programScene {
    final live = sceneById(collection.programSceneId)!;
    if (!studioMode) return live;
    var snap = _programSnapshot;
    if (snap == null || snap.id != live.id) snap = _programSnapshot = _copyScene(live);
    snap.name = live.name;
    return snap;
  }

  Scene? _programSnapshot;
  int _revision = 0;
  (int, bool)? _pendingCache;

  static Scene _copyScene(Scene s) => Scene.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);

  /// Preview shows the program scene but with changes that aren't live yet.
  bool get previewHasPendingChanges {
    if (!studioMode || collection.previewSceneId != collection.programSceneId) return false;
    final cached = _pendingCache;
    if (cached != null && cached.$1 == _revision) return cached.$2;
    final pending = jsonEncode(programScene.toJson()) != jsonEncode(previewScene.toJson());
    _pendingCache = (_revision, pending);
    return pending;
  }

  /// Whether Transition (or the T-bar) has something to send to program.
  bool get canTransition =>
      studioMode && (collection.programSceneId != collection.previewSceneId || previewHasPendingChanges);

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
  /// Scene items that show [sourceId] (editing scene first).
  List<SceneItem> itemsOf(String sourceId) => [
        for (final scene in {editingScene, ...collection.scenes})
          for (final i in scene.items)
            if (i.sourceId == sourceId) i,
      ];

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
      if (collection.previewSceneId != sceneId) tBar = 0;
      collection.previewSceneId = sceneId;
    } else {
      if (collection.programSceneId != sceneId) {
        final outgoing = programScene;
        collection.programSceneId = sceneId;
        collection.previewSceneId = sceneId;
        _active = null;
        transitionSerial++;
        _holdOutgoing(outgoing);
      }
    }
    _changed();
  }

  // ---------------------------------------------------------------------------
  // Filters

  /// Copy Filters / Paste Filters, like OBS (not saved).
  List<SourceFilter>? filterClipboard;

  void copyFilters(String sourceId) {
    final s = sourceById(sourceId);
    if (s == null) return;
    filterClipboard = [for (final f in s.filters) f.copy()];
    notifyListeners();
  }

  /// Adds copies of the copied filters that suit [sourceId] (video filters
  /// to video sources, audio filters to audio ones). Returns how many.
  int pasteFilters(String sourceId) {
    final s = sourceById(sourceId);
    final clip = filterClipboard;
    if (s == null || clip == null) return 0;
    var n = 0;
    for (final f in clip) {
      final fits = f.kind.isAudio
          ? (f.kind.micOnly ? s.type == SourceType.audioInput : s.type.hasAudio)
          : s.type.isVisual;
      if (!fits) continue;
      s.filters.add(SourceFilter(
        id: newId('filter'),
        kind: f.kind,
        name: f.name,
        enabled: f.enabled,
        settings: Map.of(f.settings),
      ));
      n++;
    }
    if (n > 0) _changed();
    return n;
  }

  SourceFilter addFilter(String sourceId, FilterKind kind) {
    final s = sourceById(sourceId)!;
    var name = kind.label;
    for (var n = 2; s.filters.any((f) => f.name == name); n++) {
      name = '${kind.label} $n';
    }
    final f = SourceFilter(id: newId('filter'), kind: kind, name: name);
    s.filters.add(f);
    _changed();
    return f;
  }

  void removeFilter(String sourceId, String filterId) {
    sourceById(sourceId)?.filters.removeWhere((f) => f.id == filterId);
    _changed();
  }

  /// Moves a filter to [index] in the chain.
  void moveFilter(String sourceId, String filterId, int index) {
    final list = sourceById(sourceId)?.filters;
    if (list == null) return;
    final i = list.indexWhere((f) => f.id == filterId);
    if (i < 0) return;
    list.insert(index.clamp(0, list.length - 1), list.removeAt(i));
    _changed();
  }

  void updateFilter(String sourceId, String filterId, {bool? enabled, String? name, Map<String, dynamic>? values}) {
    final f = sourceById(sourceId)?.filters.where((f) => f.id == filterId).firstOrNull;
    if (f == null) return;
    if (enabled != null) f.enabled = enabled;
    if (name != null && name.trim().isNotEmpty) f.name = name.trim();
    if (values != null) f.settings.addAll(values);
    _changed();
  }

  /// The transition used for the latest scene change ([transitionSerial]):
  /// the selected one, or a quick transition's.
  TransitionType get activeTransition => _active?.type ?? collection.transition;
  int get activeTransitionMs => _active?.ms ?? collection.transitionMs;
  QuickTransition? _active;

  /// Studio mode "Transition" button: preview -> program. Like OBS, the old
  /// program scene becomes the new preview (swap). [using] is a quick
  /// transition; otherwise the selected transition is used.
  void transitionToProgram({QuickTransition? using}) {
    if (!canTransition) return;
    final outgoing = programScene;
    final oldProgram = collection.programSceneId;
    if (oldProgram == collection.previewSceneId) {
      // Same scene: send the Preview's edits live; Preview keeps the scene.
      _programSnapshot = _copyScene(previewScene);
    } else {
      collection.programSceneId = collection.previewSceneId;
      collection.previewSceneId = oldProgram;
      _programSnapshot = _copyScene(sceneById(collection.programSceneId)!);
      selectedItemId = null;
    }
    _active = using;
    tBar = 0;
    transitionSerial++;
    _holdOutgoing(outgoing);
    _pruneOrphans();
    _changed();
  }

  /// Puts [sceneId] live straight away with the current transition (Multiview
  /// double-tap / hold). In Studio Mode it goes through Preview, so the old
  /// program scene ends up in Preview, like OBS.
  void sendSceneToProgram(String sceneId) {
    if (sceneById(sceneId) == null) return;
    if (!studioMode) {
      selectScene(sceneId);
      return;
    }
    if (collection.programSceneId == sceneId) return;
    selectScene(sceneId);
    transitionToProgram();
  }

  /// The scene leaving program during a transition keeps its sources running
  /// (cameras, videos, pages) until the transition has finished drawing it.
  Scene? _outgoing;
  Timer? _outgoingTimer;

  void _holdOutgoing(Scene? scene) {
    _outgoingTimer?.cancel();
    if (scene == null || activeTransition == TransitionType.cut) {
      _outgoing = null;
      return;
    }
    _outgoing = scene;
    _outgoingTimer = Timer(Duration(milliseconds: activeTransitionMs + 150), () {
      _outgoing = null;
      notifyListeners();
    });
  }

  /// Studio mode T-bar position (0 = program, 1 = preview fully in). Not
  /// saved. While it's between 0 and 1 the program shows the mix.
  double tBar = 0;

  void setTBar(double v) {
    if (!canTransition) {
      if (tBar != 0) {
        tBar = 0;
        notifyListeners();
      }
      return;
    }
    tBar = v.clamp(0.0, 1.0);
    notifyListeners();
  }

  /// Letting go of the T-bar: at the end it completes the transition (no
  /// further animation); anywhere else it stays put, like OBS.
  void releaseTBar() {
    if (tBar >= 0.97) transitionToProgram(using: const QuickTransition(TransitionType.cut, 0));
  }

  void addQuickTransition(QuickTransition q) {
    if (collection.quickTransitions.contains(q)) return;
    collection.quickTransitions.add(q);
    _changed();
  }

  void removeQuickTransition(QuickTransition q) {
    collection.quickTransitions.remove(q);
    _changed();
  }

  void setStudioMode(bool enabled) {
    if (studioMode == enabled) return;
    studioMode = enabled;
    settings.studioMode = enabled;
    tBar = 0;
    _programSnapshot = null; // taken from the current program on first use
    // Entering studio mode starts with preview == program.
    collection.previewSceneId = collection.programSceneId;
    selectedItemId = null;
    _changed();
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
    if (type == SourceType.scene && (source.settings['sceneId'] as String? ?? '').isEmpty) {
      // Start with another scene that can be nested here without a loop.
      final pick = nestableScenes(editingScene.id).firstOrNull;
      if (pick != null) source.settings['sceneId'] = pick.id;
    }
    collection.sources.add(source);
    return addExistingSource(source.id);
  }

  /// Scenes that [sceneId] uses as Scene sources, directly or deeper.
  Set<String> _nestedIn(String sceneId, [Set<String>? seen]) {
    seen ??= {};
    final scene = sceneById(sceneId);
    if (scene == null || !seen.add(sceneId)) return seen;
    for (final it in scene.items) {
      final s = sourceById(it.sourceId);
      if (s?.type == SourceType.scene) _nestedIn(s!.settings['sceneId'] as String? ?? '', seen);
    }
    return seen;
  }

  /// Scenes that can be shown inside [hostSceneId] without a loop.
  List<Scene> nestableScenes(String hostSceneId) => [
        for (final s in collection.scenes)
          if (s.id != hostSceneId && !_nestedIn(s.id).contains(hostSceneId)) s,
      ];

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
      case SourceType.ndiInput:
      case SourceType.rtmpInput:
        return ItemTransform(width: cw, height: ch, fit: FitMode.contain);
      case SourceType.image:
        final w = cw / 2, h = ch / 2;
        return ItemTransform(x: (cw - w) / 2, y: (ch - h) / 2, width: w, height: h, fit: FitMode.contain);
      case SourceType.imageSlideShow:
        return ItemTransform(width: cw, height: ch, fit: FitMode.contain);
      case SourceType.browser:
        final w = (s.settings['width'] as num?)?.toDouble() ?? cw;
        final h = (s.settings['height'] as num?)?.toDouble() ?? ch;
        final k = math.min(cw / w, ch / h);
        return ItemTransform(x: (cw - w * k) / 2, y: (ch - h * k) / 2, width: w * k, height: h * k);
      case SourceType.audioInput:
      case SourceType.audioOutput:
        return ItemTransform(width: 0, height: 0);
      case SourceType.scene:
        return ItemTransform(width: cw, height: ch, fit: FitMode.stretch);
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

  /// Text font size: the text is drawn to fill its box, so the box grows or
  /// shrinks with the size (keeping its centre), like OBS's text source.
  void setTextFontSize(String sourceId, double size) {
    final src = sourceById(sourceId);
    if (src == null) return;
    final old = (src.settings['fontSize'] as num?)?.toDouble() ?? 96;
    src.settings['fontSize'] = size;
    if (old > 0 && size > 0) {
      final k = size / old;
      for (final scene in collection.scenes) {
        for (final it in scene.items.where((i) => i.sourceId == sourceId)) {
          final t = it.transform;
          final cx = t.x + t.width / 2, cy = t.y + t.height / 2;
          t.width *= k;
          t.height *= k;
          t.x = cx - t.width / 2;
          t.y = cy - t.height / 2;
        }
      }
    }
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
    scene.items.removeAt(idx);
    if (selectedItemId == itemId) selectedItemId = null;
    _pruneOrphans();
    _changed();
  }

  /// Deletes sources no scene uses any more. Sources still live in the
  /// Studio Mode program copy wait until the next Transition, so removing
  /// an item in Preview doesn't take it off air early. Audio input sources
  /// live in the mixer even without scene items.
  void _pruneOrphans() {
    final live = studioMode ? _programSnapshot : null;
    collection.sources.removeWhere((src) =>
        src.type != SourceType.audioInput &&
        usageCount(src.id) == 0 &&
        !(live?.items.any((i) => i.sourceId == src.id) ?? false));
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
  /// The microphones for the native audio path: every Mic/Aux source takes
  /// a channel of the audio device ('mix', 'left' = input 1, 'right' =
  /// input 2), with its filter chain and fader:
  /// `{noiseSuppression, inputs: [{id, channel, gain, chain: [...]}]}`.
  Map<String, Object> get micProcessing {
    var ns = false;
    final inputs = <Map<String, Object>>[];
    for (final mic in collection.sources.where((s) => s.type == SourceType.audioInput)) {
      final chain = <Map<String, Object>>[];
      for (final f in mic.filters) {
        if (!f.enabled) continue;
        switch (f.kind) {
          case FilterKind.noiseSuppression:
            ns = true; // applies to the device
          case FilterKind.gain:
            chain.add({'type': 'gain', 'db': f.dbl('db')});
          case FilterKind.noiseGate:
            chain.add({
              'type': 'gate',
              for (final k in ['closeDb', 'openDb', 'attackMs', 'holdMs', 'releaseMs'])
                k: f.dbl(k, f.kind.defaults[k] as double),
            });
          case FilterKind.compressor:
            chain.add({
              'type': 'compressor',
              for (final k in ['ratio', 'thresholdDb', 'attackMs', 'releaseMs', 'outputDb'])
                k: f.dbl(k, f.kind.defaults[k] as double),
            });
          case FilterKind.limiter:
            chain.add({
              'type': 'limiter',
              'thresholdDb': f.dbl('thresholdDb', -6),
              'releaseMs': f.dbl('releaseMs', 60),
            });
          default:
            break;
        }
      }
      inputs.add({
        'id': mic.id,
        'channel': mic.settings['channel'] as String? ?? 'mix',
        'gain': mic.muted ? 0.0 : mic.volume,
        'chain': chain,
        'delayMs': mic.syncOffsetMs,
      });
    }
    return {'noiseSuppression': ns, 'inputs': inputs};
  }

  /// Audio sync offset for a source's sound, 0–2000 ms.
  void setSyncOffset(String sourceId, int ms) =>
      updateSourceSettings(sourceId, {'syncOffsetMs': ms.clamp(0, 2000)});

  double get micGain {
    final mics = collection.sources.where((s) => s.type == SourceType.audioInput);
    if (mics.isEmpty) return 0;
    final m = mics.first;
    // The mic's Gain filter runs natively in the filter chain (micProcessing);
    // this is the fader, applied after the filters like OBS.
    return m.muted ? 0 : m.volume;
  }

  /// Gain for other apps' audio captured with the screen: the Audio Output
  /// Capture fader if there is one, otherwise the first Screen Capture's.
  double get screenAudioGain {
    for (final type in [SourceType.audioOutput, SourceType.screen]) {
      for (final s in collection.sources) {
        if (s.type == type) return s.muted ? 0 : s.volume * s.filterGain;
      }
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
    inspectedSourceId = null;
    _programSnapshot = null; // the new program, not the old copy
    transitionSerial++;
    _changed();
  }

  // ---------------------------------------------------------------------------
  // Persistence

  // ---------------------------------------------------------------------------
  // Undo / Redo (Edit menu, Ctrl+Z): the scenes, sources, filters and
  // layout. Switching scenes isn't undone, so Undo never changes what's live.

  final List<String> _undo = [];
  final List<String> _redo = [];
  String? _undoBaseline;
  DateTime _lastUndoPush = DateTime.fromMillisecondsSinceEpoch(0);
  bool _restoring = false;

  String _undoState() {
    final j = collection.toJson()
      ..remove('programSceneId')
      ..remove('previewSceneId');
    return jsonEncode(j);
  }

  bool get canUndo => _undo.isNotEmpty;

  /// Ends the current group of edits (tests; edits further apart than
  /// 0.7 s are separate steps anyway).
  @visibleForTesting
  void breakUndoGroup() => _lastUndoPush = DateTime.fromMillisecondsSinceEpoch(0);
  bool get canRedo => _redo.isNotEmpty;

  void _recordUndo() {
    if (_restoring) return;
    final now = _undoState();
    final before = _undoBaseline;
    _undoBaseline = now;
    if (before == null || before == now) return;
    // A burst of edits (dragging, typing) is one step.
    final t = DateTime.now();
    if (t.difference(_lastUndoPush) > const Duration(milliseconds: 700) || _undo.isEmpty) {
      _undo.add(before);
      if (_undo.length > 50) _undo.removeAt(0);
    }
    _lastUndoPush = t;
    _redo.clear();
  }

  void undo() => _step(_undo, _redo);
  void redo() => _step(_redo, _undo);

  void _step(List<String> from, List<String> to) {
    if (from.isEmpty) return;
    to.add(_undoState());
    final j = jsonDecode(from.removeLast()) as Map<String, dynamic>;
    final keepProgram = collection.programSceneId, keepPreview = collection.previewSceneId;
    final restored = SceneCollection.fromJson(j);
    if (restored.scenes.any((s) => s.id == keepProgram)) restored.programSceneId = keepProgram;
    if (restored.scenes.any((s) => s.id == keepPreview)) restored.previewSceneId = keepPreview;
    _restoring = true;
    collection = restored;
    selectedItemId = null;
    _undoBaseline = _undoState();
    _lastUndoPush = DateTime.fromMillisecondsSinceEpoch(0);
    _changed();
    _restoring = false;
  }

  void _changed() {
    _revision++;
    _recordUndo();
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), save);
  }

  Future<void> _saving = Future.value();

  /// Writes everything to the device. Saves run one after another (never two
  /// writing the same file at once), each with the latest state.
  Future<void> save() {
    _saveTimer?.cancel();
    _saveTimer = null;
    return _saving = _saving.then((_) async {
      final collectionJson = jsonEncode(collection.toJson());
      final settingsJson = jsonEncode(settings.toJson());
      try {
        await storage.write(_collectionKey, collectionJson);
      } catch (e) {
        debugPrint('Failed to save scenes: $e');
      }
      try {
        await storage.write(_settingsKey, settingsJson);
      } catch (e) {
        debugPrint('Failed to save settings: $e');
      }
    });
  }

  String exportCollection() => const JsonEncoder.withIndent('  ').convert(collection.toJson());

  @override
  void dispose() {
    _outgoingTimer?.cancel();
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
