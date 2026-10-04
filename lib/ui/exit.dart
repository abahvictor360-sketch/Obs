import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import 'dialogs.dart';

/// Test hook: replaces closing the app.
@visibleForTesting
Future<void> Function()? debugExitOverride;

/// File › Exit and the Exit button: stops any stream or recording (after
/// asking), saves the scenes and closes OBSpad.
Future<void> exitApp(BuildContext context) async {
  final scope = AppScope.of(context);
  final out = scope.output;
  final busy = out.isStreaming || out.isRecording || out.ndiActive;
  final ok = await confirm(
    context,
    title: 'Exit OBSpad?',
    message: busy
        ? 'You are ${[
            if (out.isStreaming) 'streaming',
            if (out.isRecording) 'recording',
            if (out.ndiActive) 'sending NDI',
          ].join(' and ')}. Exiting stops it and saves the recording.'
        : 'Your scenes and settings are saved.',
    ok: 'Exit',
  );
  if (!ok) return;
  if (out.isStreaming) await out.stopStreaming();
  if (out.isRecording) await out.stopRecording();
  if (out.ndiActive) await out.stopNdi();
  await scope.studio.save();
  if (debugExitOverride != null) return debugExitOverride!();
  if (kIsWeb) return;
  if (Platform.isIOS) {
    // iPadOS has no "close app" call; this ends the process like swiping it away.
    exit(0);
  }
  await SystemNavigator.pop();
}
