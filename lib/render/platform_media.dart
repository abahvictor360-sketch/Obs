import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'platform_media_stub.dart' if (dart.library.io) 'platform_media_io.dart' as impl;

/// Image from a picked file (file path on mobile, blob URL on web).
Widget imageFromPath(String path, {BoxFit fit = BoxFit.fill}) => impl.imageFromPath(path, fit: fit);

VideoPlayerController videoControllerFromPath(String path) => impl.videoControllerFromPath(path);
