import '../core/models.dart';
import '../core/studio_controller.dart';
import '../output/output_engine.dart';
import 'plugin_manager.dart';

/// Connects plugins to the studio:
///  * runs plugin source instances for what is on program/preview,
///  * forwards studio events (scene switch, stream/record state),
///  * performs control requests from plugins with the "control" permission.
class PluginBridge {
  PluginBridge(this.studio, this.output, this.plugins) {
    plugins.controlHandler = _control;
    studio.addListener(_onStudio);
    output.addListener(_onOutput);
    plugins.addListener(_sync);
    _lastProgram = studio.collection.programSceneId;
    _sync();
  }

  final StudioController studio;
  final OutputEngine output;
  final PluginManager plugins;

  String? _lastProgram;
  bool _lastStreaming = false;
  bool _lastRecording = false;

  void _onStudio() {
    final program = studio.collection.programSceneId;
    if (program != _lastProgram) {
      _lastProgram = program;
      plugins.emit('sceneChanged', {'name': studio.programScene.name});
    }
    _sync();
  }

  void _onOutput() {
    if (output.isStreaming != _lastStreaming) {
      _lastStreaming = output.isStreaming;
      plugins.emit('streamingChanged', {'active': _lastStreaming});
    }
    if (output.isRecording != _lastRecording) {
      _lastRecording = output.isRecording;
      plugins.emit('recordingChanged', {'active': _lastRecording});
    }
  }

  void _sync() {
    if (!plugins.supported) return;
    final wanted = <String, (String, String, Map<String, dynamic>)>{};
    for (final scene in {studio.programScene, studio.previewScene}) {
      for (final item in scene.items) {
        if (!item.visible) continue;
        final s = studio.sourceById(item.sourceId);
        if (s == null || s.type != SourceType.plugin) continue;
        wanted[s.id] = (
          s.settings['plugin'] as String? ?? '',
          s.settings['type'] as String? ?? '',
          ((s.settings['config'] as Map?) ?? const {}).cast<String, dynamic>(),
        );
      }
    }
    plugins.syncInstances(wanted);
  }

  Future<Object?> _control(String op, Map<String, dynamic> args) async {
    switch (op) {
      case 'getState':
        return {
          'scenes': studio.scenes.map((s) => s.name).toList(),
          'programScene': studio.programScene.name,
          'streaming': output.isStreaming,
          'recording': output.isRecording,
        };
      case 'switchScene':
        final scene = studio.scenes.where((s) => s.name == args['name']).firstOrNull;
        if (scene == null) throw ArgumentError('No scene named "${args['name']}"');
        if (studio.studioMode) {
          studio.selectScene(scene.id);
          studio.transitionToProgram();
        } else {
          studio.selectScene(scene.id);
        }
        return true;
      case 'setSourceVisible':
        final sceneName = args['scene'] as String?;
        final scene = sceneName == null
            ? studio.programScene
            : studio.scenes.where((s) => s.name == sceneName).firstOrNull;
        if (scene == null) throw ArgumentError('No scene named "$sceneName"');
        final item = scene.items.where((i) => studio.sourceById(i.sourceId)?.name == args['source']).firstOrNull;
        if (item == null) throw ArgumentError('No source "${args['source']}" in "${scene.name}"');
        item.visible = args['visible'] == true;
        studio.commitTransform(); // persist + notify
        return true;
      case 'startStreaming':
        await output.startStreaming();
        return output.isStreaming;
      case 'stopStreaming':
        await output.stopStreaming();
        return true;
      case 'startRecording':
        await output.startRecording();
        return output.isRecording;
      case 'stopRecording':
        await output.stopRecording();
        return true;
    }
    throw ArgumentError('Unknown action "$op"');
  }

  void dispose() {
    studio.removeListener(_onStudio);
    output.removeListener(_onOutput);
    plugins.removeListener(_sync);
    plugins.controlHandler = null;
  }
}
