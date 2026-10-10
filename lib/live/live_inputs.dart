import 'dart:convert';
import 'dart:typed_data';

import '../core/models.dart';
import '../core/studio_controller.dart';
import '../ndi/ndi_input_service.dart';
import '../output/output_engine.dart';
import 'rtmp_input_service.dart';

/// Video and sound arriving over the network: NDI® Sources and phones or
/// encoders streaming RTMP to the tablet.
class LiveInputs {
  LiveInputs({NdiInputService? ndi, RtmpInputService? rtmp})
      : ndi = ndi ?? NdiInputService(),
        rtmp = rtmp ?? RtmpInputService();

  final NdiInputService ndi;
  final RtmpInputService rtmp;

  void dispose() {
    ndi.dispose();
    rtmp.dispose();
  }
}

/// Connects the network sources that are on Program or Preview, and puts
/// the sound of those on Program into the stream mix (with each source's
/// fader, mute, Gain filters and audio sync offset).
class LiveInputsTracker {
  LiveInputsTracker(this.studio, this.inputs, {this.output}) {
    inputs.ndi.onAudio = _onNdiAudio;
    studio.addListener(_sync);
    _sync();
  }

  final StudioController studio;
  final LiveInputs inputs;
  final OutputEngine? output;
  String _lastAudio = '';

  /// Sources whose sound is mixed: {id, gain, delayMs}.
  List<Map<String, Object>> liveAudio() {
    final out = <Map<String, Object>>[];
    final seen = <String>{};
    for (final item in studio.programScene.items) {
      if (!item.visible || !seen.add(item.sourceId)) continue;
      final s = studio.sourceById(item.sourceId);
      if (s == null || (s.type != SourceType.ndiInput && s.type != SourceType.rtmpInput)) continue;
      out.add({'id': s.id, 'gain': s.muted ? 0.0 : s.volume * s.filterGain, 'delayMs': s.syncOffsetMs});
    }
    return out;
  }

  void _sync() {
    final ndi = <String, (String, bool)>{};
    final rtmp = <String, String>{};
    for (final s in studio.activeSources) {
      if (s.type == SourceType.ndiInput) {
        final name = s.settings['ndiName'] as String? ?? '';
        if (name.isNotEmpty) ndi[s.id] = (name, s.settings['lowBandwidth'] as bool? ?? false);
      } else if (s.type == SourceType.rtmpInput) {
        final key = (s.settings['streamKey'] as String? ?? '').trim();
        if (key.isNotEmpty) rtmp[s.id] = key;
      }
    }
    inputs.ndi.sync(ndi);
    inputs.rtmp.sync(rtmp);

    final out = output;
    if (out == null || !out.encoderSupported) return;
    final list = liveAudio();
    final key = jsonEncode(list);
    if (key != _lastAudio) {
      _lastAudio = key;
      out.backend.setLiveAudio(list).catchError((_) {});
    }
  }

  void _onNdiAudio(String id, Float32List pcm, int rate, int channels) {
    final out = output;
    if (out == null || !out.encoderSupported) return;
    out.backend.pushLiveAudio(id, pcm, channels, rate).catchError((_) {});
  }

  void dispose() {
    studio.removeListener(_sync);
    inputs.ndi.onAudio = null;
  }
}
