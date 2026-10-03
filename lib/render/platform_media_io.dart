import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

Widget imageFromPath(String path, {BoxFit fit = BoxFit.fill}) =>
    Image.file(File(path), fit: fit, gaplessPlayback: true, filterQuality: FilterQuality.medium);

VideoPlayerController videoControllerFromPath(String path) => VideoPlayerController.file(File(path));
