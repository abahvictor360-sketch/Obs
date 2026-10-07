// MJPEG over HTTP: what DroidCam, IP Webcam and most IP cameras serve.
// Pure Dart, no I/O, so it can be unit tested.

import 'dart:convert';
import 'dart:typed_data';

/// Which app/camera a Network Video source talks to.
enum NetworkVideoKind {
  droidcam('DroidCam (phone app)', 4747),
  ipWebcam('IP Webcam (Android app)', 8080),
  mjpeg('MJPEG URL (IP camera, ESP32-CAM…)', 0),
  stream('Stream URL (HLS / HTTP video)', 0);

  const NetworkVideoKind(this.label, this.defaultPort);
  final String label;
  final int defaultPort;

  bool get usesHost => defaultPort != 0;
  bool get isMjpeg => this != NetworkVideoKind.stream;

  static NetworkVideoKind fromName(String? n) =>
      NetworkVideoKind.values.where((k) => k.name == n).firstOrNull ?? NetworkVideoKind.droidcam;
}

/// http://host:port of a phone app source, or null if it has no IP yet.
String? _phoneBase(Map<String, dynamic> s, NetworkVideoKind kind) {
  var host = (s['host'] as String? ?? '').trim();
  if (host.isEmpty) return null;
  host = host.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'/.*$'), '');
  final hasPort = RegExp(r':\d+$').hasMatch(host);
  final port = (s['port'] as num?)?.toInt() ?? kind.defaultPort;
  return 'http://$host${hasPort ? '' : ':$port'}';
}

/// The request that turns the phone's front or back camera on, for the
/// source's "phoneCamera" setting ('front' / 'back'; 'app' or unset leaves
/// it as chosen in the phone app). Only IP Webcam can be switched remotely:
/// DroidCam's camera is chosen in the DroidCam app.
String? phoneCameraUrl(Map<String, dynamic> s) {
  final kind = NetworkVideoKind.fromName(s['kind'] as String?);
  final cam = s['phoneCamera'] as String?;
  if (kind != NetworkVideoKind.ipWebcam || (cam != 'front' && cam != 'back')) return null;
  final base = _phoneBase(s, kind);
  return base == null ? null : '$base/settings/ffc?set=${cam == 'front' ? 'on' : 'off'}';
}

/// Builds the URL to open from a Network Video source's settings, or null
/// if it isn't configured yet.
String? networkVideoUrl(Map<String, dynamic> s) {
  final kind = NetworkVideoKind.fromName(s['kind'] as String?);
  if (!kind.usesHost) {
    final url = (s['url'] as String? ?? '').trim();
    if (url.isEmpty) return null;
    return url.contains('://') ? url : 'http://$url';
  }
  final base = _phoneBase(s, kind);
  if (base == null) return null;
  switch (kind) {
    case NetworkVideoKind.droidcam:
      // DroidCam picks the size from the query, e.g. /video?1280x720.
      final res = (s['resolution'] as String? ?? '').trim();
      return res.isEmpty || res == 'auto' ? '$base/video' : '$base/video?$res';
    case NetworkVideoKind.ipWebcam:
      return '$base/video';
    case NetworkVideoKind.mjpeg:
    case NetworkVideoKind.stream:
      return null; // unreachable: URL kinds handled above
  }
}

/// Splits an MJPEG byte stream into JPEG frames. Understands
/// multipart/x-mixed-replace (using Content-Length when the server sends it)
/// and plain back-to-back JPEGs.
class MjpegParser {
  MjpegParser(this.onFrame, {this.maxBuffer = 16 << 20});

  final void Function(Uint8List jpeg) onFrame;
  final int maxBuffer;

  Uint8List _buf = Uint8List(64 * 1024);
  int _start = 0; // first unconsumed byte
  int _end = 0; // end of data

  static final _contentLength = RegExp(r'content-length:\s*(\d+)', caseSensitive: false);

  void add(List<int> chunk) {
    _ensure(chunk.length);
    _buf.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
    while (_next()) {}
    if (_end - _start > maxBuffer) {
      // Garbage or a frame bigger than we accept: resync.
      _start = _end;
    }
  }

  void _ensure(int extra) {
    if (_start > 0 && (_end + extra > _buf.length || _start > _buf.length ~/ 2)) {
      _buf.setRange(0, _end - _start, _buf, _start);
      _end -= _start;
      _start = 0;
    }
    if (_end + extra > _buf.length) {
      var size = _buf.length * 2;
      while (size < _end + extra) {
        size *= 2;
      }
      final nb = Uint8List(size)..setRange(0, _end, _buf);
      _buf = nb;
    }
  }

  int _indexOf2(int a, int b, int from) {
    for (var i = from; i + 1 < _end; i++) {
      if (_buf[i] == a && _buf[i + 1] == b) return i;
    }
    return -1;
  }

  /// Emits one frame if a complete one is buffered.
  bool _next() {
    final soi = _indexOf2(0xFF, 0xD8, _start);
    if (soi < 0) {
      // Keep the last byte in case it's the first half of a marker.
      if (_end - _start > 1) _start = _end - 1;
      return false;
    }
    // Multipart headers (if any) sit between the last frame and this one.
    int? length;
    if (soi > _start) {
      final headers = latin1.decode(Uint8List.sublistView(_buf, _start, soi), allowInvalid: true);
      final m = _contentLength.allMatches(headers).lastOrNull;
      if (m != null) length = int.tryParse(m.group(1)!);
    }
    if (length != null && length > 0) {
      if (soi + length > _end) return false;
      final jpeg = Uint8List.fromList(Uint8List.sublistView(_buf, soi, soi + length));
      _start = soi + length;
      onFrame(jpeg);
      return true;
    }
    final eoi = _indexOf2(0xFF, 0xD9, soi + 2);
    if (eoi < 0) {
      _start = soi;
      return false;
    }
    final jpeg = Uint8List.fromList(Uint8List.sublistView(_buf, soi, eoi + 2));
    _start = eoi + 2;
    onFrame(jpeg);
    return true;
  }
}
