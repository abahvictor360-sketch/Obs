// The wire format of Teleport (github.com/fzwoch/obs-teleport), the OBS
// plugin that sends video and sound between OBS installs on a network:
//
// - Discovery: every second each sender multicasts a small JSON payload
//   ({"Name", "Port", "AudioAndVideo", "Version"}) to 239.255.255.250:9999
//   (schollz/peerdiscovery). Receivers take the address the packet came from.
// - Stream: the receiver connects over TCP to that address and port and
//   reads packets, all little-endian:
//     Header      Type[4] ("JPEG" | "WAVE"), Timestamp u64 (ns), Size i32
//     JPEG:       ImageHeader: ColorMatrix f32[16], RangeMin f32[3], RangeMax f32[3]
//     WAVE:       WaveHeader: Format i32, SampleRate i32, Speakers i32, Frames i32
//     then Size bytes: a JPEG image, or interleaved samples.

import 'dart:convert';
import 'dart:typed_data';

const kTeleportDiscoveryPort = 9999;
const kTeleportMulticastGroup = '239.255.255.250';

/// Sent as the Version; Teleport only logs a mismatch.
const kTeleportVersion = '0.8.0';

const _headerSize = 16;
const _imageHeaderSize = 88;
const _waveHeaderSize = 16;

/// libobs audio_format values Teleport sends.
class TeleportAudioFormat {
  static const u8 = 1;
  static const s16 = 2;
  static const s32 = 3;
  static const float = 4;
}

/// What a Teleport sender announces.
class TeleportAnnounce {
  const TeleportAnnounce({
    required this.name,
    required this.port,
    this.audioAndVideo = true,
    this.version = kTeleportVersion,
    this.address = '',
  });

  final String name;
  final int port;
  final bool audioAndVideo;
  final String version;

  /// Where the announcement came from (filled in by the receiver).
  final String address;

  /// The key Teleport uses for a sender: "Name:Address".
  String get key => '$name:$address';

  List<int> encode() =>
      utf8.encode(jsonEncode({'Name': name, 'Port': port, 'AudioAndVideo': audioAndVideo, 'Version': version}));

  static TeleportAnnounce? decode(List<int> bytes, String from) {
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map) return null;
      final name = j['Name'], port = j['Port'];
      if (name is! String || port is! int || port <= 0 || port > 65535) return null;
      return TeleportAnnounce(
        name: name,
        port: port,
        audioAndVideo: j['AudioAndVideo'] as bool? ?? true,
        version: j['Version'] as String? ?? '',
        address: from,
      );
    } catch (_) {
      return null;
    }
  }
}

/// YCbCr (BT.601, full range, as in every JPEG) to RGB, in the layout libobs
/// uses for video_format_get_parameters (VIDEO_CS_601, VIDEO_RANGE_FULL).
const kJpegColorMatrix = <double>[
  1.0, 0.0, 1.407520, -0.706520, //
  1.0, -0.345491, -0.716948, 0.533303,
  1.0, 1.778976, 0.0, -0.892976,
  0.0, 0.0, 0.0, 1.0,
];

ByteData _header(String type, int timestampNs, int size, int extra) {
  final b = ByteData(_headerSize + extra);
  for (var i = 0; i < 4; i++) {
    b.setUint8(i, type.codeUnitAt(i));
  }
  b.setUint64(4, timestampNs, Endian.little);
  b.setInt32(12, size, Endian.little);
  return b;
}

/// A video packet: [jpeg] shown at [timestampNs].
Uint8List teleportJpegPacket(int timestampNs, Uint8List jpeg) {
  final h = _header('JPEG', timestampNs, jpeg.length, _imageHeaderSize);
  for (var i = 0; i < 16; i++) {
    h.setFloat32(_headerSize + i * 4, kJpegColorMatrix[i], Endian.little);
  }
  // Range min 0,0,0 and max 1,1,1 (full range).
  for (var i = 0; i < 3; i++) {
    h.setFloat32(_headerSize + 64 + i * 4, 0, Endian.little);
    h.setFloat32(_headerSize + 76 + i * 4, 1, Endian.little);
  }
  return (BytesBuilder(copy: false)
        ..add(h.buffer.asUint8List())
        ..add(jpeg))
      .takeBytes();
}

/// A sound packet: interleaved float [samples] at [sampleRate].
Uint8List teleportWavePacket(int timestampNs, Float32List samples, int sampleRate, int channels) {
  final frames = channels <= 0 ? 0 : samples.length ~/ channels;
  final size = frames * channels * 4;
  final h = _header('WAVE', timestampNs, size, _waveHeaderSize)
    ..setInt32(_headerSize, TeleportAudioFormat.float, Endian.little)
    ..setInt32(_headerSize + 4, sampleRate, Endian.little)
    ..setInt32(_headerSize + 8, channels, Endian.little)
    ..setInt32(_headerSize + 12, frames, Endian.little);
  final data = ByteData(size);
  for (var i = 0; i < frames * channels; i++) {
    data.setFloat32(i * 4, samples[i], Endian.little);
  }
  return (BytesBuilder(copy: false)
        ..add(h.buffer.asUint8List())
        ..add(data.buffer.asUint8List()))
      .takeBytes();
}

sealed class TeleportPacket {
  const TeleportPacket(this.timestampNs);
  final int timestampNs;
}

class TeleportVideo extends TeleportPacket {
  const TeleportVideo(super.timestampNs, this.jpeg);
  final Uint8List jpeg;
}

class TeleportAudio extends TeleportPacket {
  const TeleportAudio(super.timestampNs, this.samples, this.sampleRate, this.channels);

  /// Interleaved float samples.
  final Float32List samples;
  final int sampleRate, channels;
}

/// Splits a Teleport TCP stream into packets.
class TeleportReader {
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  /// Feeds received bytes; returns the complete packets.
  List<TeleportPacket> add(List<int> data) {
    if (_pending.isNotEmpty) _buf.add(_pending);
    _buf.add(data);
    final bytes = _buf.takeBytes();
    final out = <TeleportPacket>[];
    var p = 0;
    while (bytes.length - p >= _headerSize) {
      final b = ByteData.sublistView(bytes, p);
      final type = String.fromCharCodes(bytes, p, p + 4);
      final ts = b.getUint64(4, Endian.little);
      final size = b.getInt32(12, Endian.little);
      if (size < 0 || size > 64 << 20) throw const FormatException('Not a Teleport stream');
      final extra = switch (type) {
        'JPEG' => _imageHeaderSize,
        'WAVE' => _waveHeaderSize,
        _ => 0,
      };
      final total = _headerSize + extra + size;
      if (bytes.length - p < total) break;
      final body = Uint8List.sublistView(bytes, p + _headerSize + extra, p + total);
      if (type == 'JPEG') {
        out.add(TeleportVideo(ts, Uint8List.fromList(body)));
      } else if (type == 'WAVE') {
        final w = ByteData.sublistView(bytes, p + _headerSize);
        final format = w.getInt32(0, Endian.little);
        final rate = w.getInt32(4, Endian.little);
        final ch = w.getInt32(8, Endian.little);
        final samples = _toFloat(body, format);
        if (samples != null && ch > 0) out.add(TeleportAudio(ts, samples, rate, ch));
      }
      p += total;
    }
    _pending = Uint8List.fromList(Uint8List.sublistView(bytes, p));
    return out;
  }

  static Float32List? _toFloat(Uint8List body, int format) {
    final d = ByteData.sublistView(body);
    switch (format) {
      case TeleportAudioFormat.float:
        final n = body.length ~/ 4;
        return Float32List(n)..setAll(0, [for (var i = 0; i < n; i++) d.getFloat32(i * 4, Endian.little)]);
      case TeleportAudioFormat.s16:
        final n = body.length ~/ 2;
        return Float32List(n)..setAll(0, [for (var i = 0; i < n; i++) d.getInt16(i * 2, Endian.little) / 32768]);
      case TeleportAudioFormat.s32:
        final n = body.length ~/ 4;
        return Float32List(n)..setAll(0, [for (var i = 0; i < n; i++) d.getInt32(i * 4, Endian.little) / 2147483648]);
      case TeleportAudioFormat.u8:
        return Float32List(body.length)..setAll(0, [for (final v in body) (v - 128) / 128]);
      default:
        return null;
    }
  }
}
