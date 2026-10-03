// Minimal dart:ffi bindings for the NDI® SDK (Processing.NDI.Lib.h, v5/v6).
//
// The library is loaded at runtime, so the app builds without the SDK; NDI
// output is offered only when the runtime is present:
//   Android: libndi.so packaged in jniLibs (scripts/fetch_ndi_sdk.sh)
//   iOS:     libndi_ios linked into the app (scripts/fetch_ndi_sdk.sh)
//   Desktop/tests: path in the NDI_LIB environment variable.
//
// NDI® is a registered trademark of Vizrt NDI AB. https://ndi.video

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// NDIlib_send_create_t
final class NdiSendCreate extends Struct {
  external Pointer<Utf8> pNdiName;
  external Pointer<Utf8> pGroups;
  @Bool()
  external bool clockVideo;
  @Bool()
  external bool clockAudio;
}

/// NDIlib_video_frame_v2_t
final class NdiVideoFrameV2 extends Struct {
  @Int32()
  external int xres;
  @Int32()
  external int yres;
  @Int32()
  external int fourCC;
  @Int32()
  external int frameRateN;
  @Int32()
  external int frameRateD;
  @Float()
  external double pictureAspectRatio;
  @Int32()
  external int frameFormatType;
  @Int64()
  external int timecode;
  external Pointer<Uint8> pData;

  /// Union with data_size_in_bytes.
  @Int32()
  external int lineStrideInBytes;
  external Pointer<Utf8> pMetadata;
  @Int64()
  external int timestamp;
}

/// NDIlib_audio_frame_v2_t (32-bit float, planar).
final class NdiAudioFrameV2 extends Struct {
  @Int32()
  external int sampleRate;
  @Int32()
  external int noChannels;
  @Int32()
  external int noSamples;
  @Int64()
  external int timecode;
  external Pointer<Float> pData;
  @Int32()
  external int channelStrideInBytes;
  external Pointer<Utf8> pMetadata;
  @Int64()
  external int timestamp;
}

/// NDIlib_source_t
final class NdiSource extends Struct {
  external Pointer<Utf8> pNdiName;

  /// Union with p_ip_address.
  external Pointer<Utf8> pUrlAddress;
}

/// NDIlib_find_create_t
final class NdiFindCreate extends Struct {
  @Bool()
  external bool showLocalSources;
  external Pointer<Utf8> pGroups;
  external Pointer<Utf8> pExtraIps;
}

/// NDIlib_recv_create_v3_t
final class NdiRecvCreateV3 extends Struct {
  external NdiSource sourceToConnectTo;
  @Int32()
  external int colorFormat;
  @Int32()
  external int bandwidth;
  @Bool()
  external bool allowVideoFields;
  external Pointer<Utf8> pNdiRecvName;
}

int ndiFourCC(String s) =>
    s.codeUnitAt(0) | (s.codeUnitAt(1) << 8) | (s.codeUnitAt(2) << 16) | (s.codeUnitAt(3) << 24);

class Ndi {
  static final fourCCRgba = ndiFourCC('RGBA');
  static const frameFormatProgressive = 1;
  static const timecodeSynthesize = 0x7fffffffffffffff;
  static const recvColorRgbxRgba = 2;
  static const recvBandwidthHighest = 100;
  static const frameTypeVideo = 1;

  Ndi._(this.lib)
      : initialize = lib.lookupFunction<Bool Function(), bool Function()>('NDIlib_initialize'),
        version = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('NDIlib_version'),
        sendCreate = lib.lookupFunction<Pointer<Void> Function(Pointer<NdiSendCreate>),
            Pointer<Void> Function(Pointer<NdiSendCreate>)>('NDIlib_send_create'),
        sendDestroy = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
            'NDIlib_send_destroy'),
        sendVideoV2 = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<NdiVideoFrameV2>),
            void Function(Pointer<Void>, Pointer<NdiVideoFrameV2>)>('NDIlib_send_send_video_v2'),
        sendAudioV2 = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<NdiAudioFrameV2>),
            void Function(Pointer<Void>, Pointer<NdiAudioFrameV2>)>('NDIlib_send_send_audio_v2'),
        sendGetNoConnections = lib.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
            int Function(Pointer<Void>, int)>('NDIlib_send_get_no_connections');

  final DynamicLibrary lib;
  final bool Function() initialize;
  final Pointer<Utf8> Function() version;
  final Pointer<Void> Function(Pointer<NdiSendCreate>) sendCreate;
  final void Function(Pointer<Void>) sendDestroy;
  final void Function(Pointer<Void>, Pointer<NdiVideoFrameV2>) sendVideoV2;
  final void Function(Pointer<Void>, Pointer<NdiAudioFrameV2>) sendAudioV2;
  final int Function(Pointer<Void>, int) sendGetNoConnections;

  // Receiving (used by tests to check what we send).
  late final findCreateV2 = lib.lookupFunction<Pointer<Void> Function(Pointer<NdiFindCreate>),
      Pointer<Void> Function(Pointer<NdiFindCreate>)>('NDIlib_find_create_v2');
  late final findDestroy =
      lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('NDIlib_find_destroy');
  late final findWaitForSources = lib.lookupFunction<Bool Function(Pointer<Void>, Uint32),
      bool Function(Pointer<Void>, int)>('NDIlib_find_wait_for_sources');
  late final findGetCurrentSources = lib.lookupFunction<Pointer<NdiSource> Function(Pointer<Void>, Pointer<Uint32>),
      Pointer<NdiSource> Function(Pointer<Void>, Pointer<Uint32>)>('NDIlib_find_get_current_sources');
  late final recvCreateV3 = lib.lookupFunction<Pointer<Void> Function(Pointer<NdiRecvCreateV3>),
      Pointer<Void> Function(Pointer<NdiRecvCreateV3>)>('NDIlib_recv_create_v3');
  late final recvDestroy =
      lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('NDIlib_recv_destroy');
  late final recvCaptureV2 = lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<NdiVideoFrameV2>, Pointer<NdiAudioFrameV2>, Pointer<Void>, Uint32),
      int Function(Pointer<Void>, Pointer<NdiVideoFrameV2>, Pointer<NdiAudioFrameV2>, Pointer<Void>, int)>(
      'NDIlib_recv_capture_v2');
  late final recvFreeVideoV2 = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<NdiVideoFrameV2>),
      void Function(Pointer<Void>, Pointer<NdiVideoFrameV2>)>('NDIlib_recv_free_video_v2');

  static Ndi? _instance;
  static String? loadError;

  /// Explicit library path (tests); also passed to the sender isolate.
  static String? libraryPath;

  /// Loads the NDI runtime, or returns null (see [loadError]).
  static Ndi? load() {
    if (_instance != null) return _instance;
    try {
      final DynamicLibrary lib;
      final override = libraryPath ?? Platform.environment['NDI_LIB'];
      if (override != null && override.isNotEmpty) {
        lib = DynamicLibrary.open(override);
      } else if (Platform.isAndroid) {
        lib = DynamicLibrary.open('libndi.so');
      } else if (Platform.isIOS) {
        lib = DynamicLibrary.process(); // linked statically
      } else if (Platform.isMacOS) {
        lib = DynamicLibrary.open('libndi.dylib');
      } else {
        lib = DynamicLibrary.open('libndi.so.6');
      }
      final ndi = Ndi._(lib);
      if (!ndi.initialize()) {
        loadError = 'This device\'s CPU is not supported by NDI';
        return null;
      }
      return _instance = ndi;
    } on ArgumentError catch (e) {
      loadError = 'NDI runtime not included in this build ($e)';
      return null;
    } catch (e) {
      loadError = 'NDI runtime failed to load: $e';
      return null;
    }
  }
}
