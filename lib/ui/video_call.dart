import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../core/studio_controller.dart';
import '../output/output_engine.dart';
import '../render/program_view.dart';
import 'feedback.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// Video-call apps OBSpad's Program can be sent into.
enum CallApp {
  zoom('Zoom'),
  meet('Google Meet'),
  whatsapp('WhatsApp'),
  telegram('Telegram');

  const CallApp(this.label);
  final String label;
}

/// How to start sharing the screen in [app] (Android or iPad).
String screenShareSteps(CallApp app, {required bool ios}) => switch (app) {
  CallApp.zoom =>
    ios
        ? 'Join the meeting in the Zoom app, tap Share › Screen, then Start Broadcast.'
        : 'Join the meeting in the Zoom app, tap Share › Screen, then Start now. Turn on Share audio to send '
              'video and music sound too.',
  CallApp.meet =>
    ios
        ? 'Join the call in the Google Meet app, tap ⋯ More › Share screen, then Start Broadcast.'
        : 'Join the call in the Google Meet app, tap ⋮ More › Share screen, then Start sharing.',
  CallApp.whatsapp =>
    ios
        ? 'Start a WhatsApp video call, tap the share-screen button (a phone with an arrow), then Start '
              'Broadcast.'
        : 'Start a WhatsApp video call, tap the share-screen button (a phone with an arrow), then Start now.',
  CallApp.telegram =>
    ios
        ? 'In a Telegram video call or group video chat, tap Screen (or ⋯ › Share Screen), then Start '
              'Broadcast.'
        : 'In a Telegram video call or group video chat, tap ⋮ › Share Screen, then Start now.',
};

/// Tools › Send to a Video Call: the ways to get the Program into Zoom,
/// Google Meet, WhatsApp or Telegram.
Future<void> showVideoCallSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const VideoCallSheet(),
);

class VideoCallSheet extends StatefulWidget {
  const VideoCallSheet({super.key});

  @override
  State<VideoCallSheet> createState() => _VideoCallSheetState();
}

class _VideoCallSheetState extends State<VideoCallSheet> {
  CallApp _app = CallApp.zoom;

  @override
  Widget build(BuildContext context) {
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: SingleChildScrollView(
          key: const ValueKey('video-call-sheet'),
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Send Program to a video call', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text(
                'Everyone in the call sees your Program: scenes, overlays and all.',
                style: TextStyle(color: ObsColors.textDim),
              ),
              const SizedBox(height: 16),
              SegmentedButton<CallApp>(
                key: const ValueKey('video-call-app'),
                segments: [for (final a in CallApp.values) ButtonSegment(value: a, label: Text(a.label))],
                selected: {_app},
                onSelectionChanged: (v) => setState(() => _app = v.first),
              ),
              const SizedBox(height: 16),
              _Way(
                icon: Icons.screen_share_outlined,
                title: 'From this tablet: share your screen',
                subtitle: 'No extra equipment',
                steps: [
                  screenShareSteps(_app, ios: ios),
                  if (!ios) 'Android 14 and newer: choose "A single app" › OBSpad, so only OBSpad is shared.',
                  'Come back to OBSpad and tap Open Call Feed: the Program fills the screen with no buttons. Tap it to '
                      'switch scenes or go back.',
                  'Turn your camera off in the call, so OBSpad can use the tablet camera (only one app can use it).',
                ],
                note:
                    'Callers hear the call\'s own microphone. Videos and music in OBSpad only reach them if the call '
                    'app offers "Share audio".',
                action: FilledButton.icon(
                  key: const ValueKey('open-call-feed'),
                  icon: const Icon(Icons.fit_screen),
                  label: const Text('Open Call Feed'),
                  onPressed: () {
                    Navigator.pop(context);
                    openCallFeed(context);
                  },
                ),
              ),
              if (_app == CallApp.telegram)
                _Way(
                  icon: Icons.live_tv_outlined,
                  title: 'Telegram group or channel: live stream',
                  subtitle: 'Best quality, with OBSpad\'s sound',
                  steps: const [
                    'In the group or channel, start a Live stream (in groups: Video chat) and choose Stream with… to '
                        'see the Server URL and Stream key.',
                    'Paste them in Settings › Stream › Telegram, then tap Start Streaming.',
                  ],
                  action: OutlinedButton.icon(
                    key: const ValueKey('video-call-telegram-stream'),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Set up Telegram streaming'),
                    onPressed: () {
                      final studio = AppScope.of(context).studio;
                      studio.updateSettings((s) {
                        if (s.service != 'Telegram' && kStreamingServices.values.contains(s.server)) s.server = '';
                        s.service = 'Telegram';
                      });
                      Navigator.pop(context);
                      openSettings(context);
                    },
                  ),
                ),
              _Way(
                icon: Icons.laptop_outlined,
                title: 'On a laptop: OBSpad as the webcam',
                subtitle: 'Zoom, Meet, WhatsApp and Telegram desktop apps, Teams',
                steps: [
                  'HDMI: connect the tablet\'s HDMI out (USB-C to HDMI) to a USB HDMI capture card plugged into the '
                      'laptop. In the call, choose the capture card as the camera and the microphone.',
                  'Wi-Fi: turn on NDI Output in Tools › Plugins. On the laptop, NDI Tools\' Virtual Input (or OBS '
                      'with DistroAV and Virtual Camera) turns it into a webcam for the ${_app.label} app.',
                ],
                action: TextButton.icon(
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Step-by-step guide'),
                  onPressed: openVideoCallGuide,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Way extends StatelessWidget {
  const _Way({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.steps,
    this.note,
    this.action,
  });

  final IconData icon;
  final String title, subtitle;
  final List<String> steps;
  final String? note;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: ObsColors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      Text(subtitle, style: const TextStyle(color: ObsColors.textDim, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${i + 1}. ${steps[i]}', style: const TextStyle(fontSize: 14)),
              ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Text(note!, style: const TextStyle(color: ObsColors.textDim, fontSize: 13)),
              ),
            if (action != null) Padding(padding: const EdgeInsets.only(top: 4), child: action),
          ],
        ),
      ),
    );
  }
}

/// The Call Feed: the Program edge to edge with nothing else on screen, for
/// sharing the tablet's screen in a call. Tapping shows the scenes and a way
/// back for a few seconds.
void openCallFeed(BuildContext context) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (_, _, _) => const CallFeedScreen(),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ),
  );
}

class CallFeedScreen extends StatefulWidget {
  const CallFeedScreen({super.key});

  /// How long the controls stay up after a tap.
  static const controlsTimeout = Duration(seconds: 4);

  @override
  State<CallFeedScreen> createState() => _CallFeedScreenState();
}

class _CallFeedScreenState extends State<CallFeedScreen> {
  bool _controls = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable().catchError((_) {});
    _show();
  }

  OutputEngine? _output;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _output = AppScope.of(context).output;
  }

  @override
  void dispose() {
    _hide?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Leave the screen-on lock to the output engine while it streams or records.
    final out = _output;
    if (out == null || (!out.isStreaming && !out.isRecording)) WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  void _show() {
    _hide?.cancel();
    if (!_controls) setState(() => _controls = true);
    _hide = Timer(CallFeedScreen.controlsTimeout, () {
      if (mounted) setState(() => _controls = false);
    });
  }

  void _close() => Navigator.of(context).maybePop();

  void _goTo(StudioController studio, Scene scene) {
    if (studio.studioMode) {
      studio.sendSceneToProgram(scene.id);
    } else {
      studio.selectScene(scene.id);
    }
    _show();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final studio = scope.studio;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        for (var i = 0; i < 9; i++)
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i)): () {
            if (i < studio.scenes.length) _goTo(studio, studio.scenes[i]);
          },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const ValueKey('call-feed'),
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _controls ? setState(() => _controls = false) : _show(),
            child: Stack(
              children: [
                Center(
                  child: AspectRatio(
                    aspectRatio: studio.settings.canvasWidth / studio.settings.canvasHeight,
                    child: const ProgramView(capture: false),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  left: 0,
                  right: 0,
                  bottom: _controls ? 0 : -140,
                  child: _CallFeedBar(onScene: (s) => _goTo(studio, s), onClose: _close, onTouch: _show),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CallFeedBar extends StatelessWidget {
  const _CallFeedBar({required this.onScene, required this.onClose, required this.onTouch});

  final void Function(Scene) onScene;
  final VoidCallback onClose, onTouch;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    return SafeArea(
      top: false,
      child: Listener(
        onPointerDown: (_) => onTouch(),
        child: Container(
          key: const ValueKey('call-feed-controls'),
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xCC111318), borderRadius: BorderRadius.circular(16)),
          child: Row(
            children: [
              FilledButton.icon(
                key: const ValueKey('call-feed-close'),
                style: FilledButton.styleFrom(backgroundColor: ObsColors.accent, foregroundColor: Colors.white),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to OBSpad'),
                onPressed: onClose,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ListenableBuilder(
                  listenable: studio,
                  builder: (context, _) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final s in studio.scenes)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              key: ValueKey('call-feed-scene-${s.id}'),
                              label: Text(s.name),
                              selected: s.id == studio.collection.programSceneId,
                              onSelected: (_) => onScene(s),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
