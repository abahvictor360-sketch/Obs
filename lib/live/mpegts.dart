// MPEG transport stream (what SRT carries) to H.264 and AAC in the forms
// the hardware decoders take: an avcC record + length-prefixed frames, and
// an AudioSpecificConfig + raw AAC frames. Pure Dart.

import 'dart:typed_data';

/// Splits a transport stream into H.264 access units and AAC frames.
class TsDemuxer {
  TsDemuxer({required this.onVideoConfig, required this.onVideo, required this.onAudioConfig, required this.onAudio,
      this.onUnsupported});

  final void Function(Uint8List avcc) onVideoConfig;
  final void Function(Uint8List data, bool keyframe) onVideo;
  final void Function(Uint8List asc) onAudioConfig;
  final void Function(Uint8List frame) onAudio;

  /// A stream OBSpad can't decode (HEVC video, MP3/Opus audio).
  final void Function(String message)? onUnsupported;

  final _carry = BytesBuilder(copy: false);
  int? _pmtPid;
  int? _videoPid;
  int? _audioPid;
  final Map<int, BytesBuilder> _pes = {};
  final _h264 = H264Packer();
  Uint8List? _lastAsc;
  bool _reportedVideo = false, _reportedAudio = false;

  void add(Uint8List data) {
    var buf = data;
    if (_carry.length > 0) {
      _carry.add(data);
      buf = _carry.takeBytes();
    }
    var p = 0;
    while (p + 188 <= buf.length) {
      if (buf[p] != 0x47) {
        // Lost sync: find the next sync byte.
        p++;
        continue;
      }
      _packet(Uint8List.sublistView(buf, p, p + 188));
      p += 188;
    }
    if (p < buf.length) _carry.add(Uint8List.sublistView(buf, p));
  }

  void _packet(Uint8List t) {
    final pusi = (t[1] & 0x40) != 0;
    final pid = ((t[1] & 0x1F) << 8) | t[2];
    final afc = (t[3] >> 4) & 3;
    var p = 4;
    if (afc == 2 || afc == 0) return; // adaptation only / reserved
    if (afc == 3) p += 1 + t[4];
    if (p >= 188) return;
    final payload = Uint8List.sublistView(t, p);
    if (pid == 0) {
      if (pusi) _pat(payload);
    } else if (pid == _pmtPid) {
      if (pusi) _pmt(payload);
    } else if (pid == _videoPid || pid == _audioPid) {
      if (pusi) {
        _flush(pid);
        _pes[pid] = BytesBuilder(copy: true)..add(payload);
      } else {
        _pes[pid]?.add(payload);
      }
      // Audio PES packets have a length: hand them over as soon as complete.
      if (pid == _audioPid) {
        final b = _pes[pid];
        if (b != null && b.length >= 6) {
          final bytes = b.toBytes();
          final len = (bytes[4] << 8) | bytes[5];
          if (len > 0 && bytes.length >= len + 6) _flush(pid);
        }
      }
    }
  }

  /// Section payload after the pointer field.
  static Uint8List? _section(Uint8List payload) {
    if (payload.isEmpty) return null;
    final start = 1 + payload[0];
    if (start + 3 > payload.length) return null;
    final s = Uint8List.sublistView(payload, start);
    final len = ((s[1] & 0x0F) << 8) | s[2];
    if (3 + len > s.length) return null;
    return Uint8List.sublistView(s, 0, 3 + len);
  }

  void _pat(Uint8List payload) {
    final s = _section(payload);
    if (s == null || s[0] != 0) return;
    // Programs from byte 8 to the CRC.
    for (var i = 8; i + 4 <= s.length - 4; i += 4) {
      final program = (s[i] << 8) | s[i + 1];
      final pid = ((s[i + 2] & 0x1F) << 8) | s[i + 3];
      if (program != 0) {
        _pmtPid = pid;
        return;
      }
    }
  }

  void _pmt(Uint8List payload) {
    final s = _section(payload);
    if (s == null || s[0] != 2 || s.length < 12) return;
    final infoLen = ((s[10] & 0x0F) << 8) | s[11];
    var i = 12 + infoLen;
    int? video, audio;
    while (i + 5 <= s.length - 4) {
      final type = s[i];
      final pid = ((s[i + 1] & 0x1F) << 8) | s[i + 2];
      final esLen = ((s[i + 3] & 0x0F) << 8) | s[i + 4];
      switch (type) {
        case 0x1B: // H.264
          video ??= pid;
        case 0x0F: // AAC (ADTS)
          audio ??= pid;
        case 0x24: // HEVC
        case 0x33: // VVC
          if (!_reportedVideo) {
            _reportedVideo = true;
            onUnsupported?.call('The stream is HEVC/H.265. Set the app or encoder to H.264 (AVC).');
          }
        case 0x03:
        case 0x04: // MPEG audio
        case 0x81: // AC-3
        case 0x06: // private (Opus)
          if (audio == null && !_reportedAudio) {
            _reportedAudio = true;
            onUnsupported?.call('The stream\'s sound isn\'t AAC. Set the app or encoder\'s audio to AAC.');
          }
      }
      i += 5 + esLen;
    }
    _videoPid = video;
    _audioPid = audio;
  }

  void _flush(int pid) {
    final b = _pes.remove(pid);
    if (b == null || b.length < 9) return;
    final pes = b.takeBytes();
    if (pes[0] != 0 || pes[1] != 0 || pes[2] != 1) return;
    final headerLen = pes[8];
    final start = 9 + headerLen;
    if (start > pes.length) return;
    var end = pes.length;
    final len = (pes[4] << 8) | pes[5];
    if (len > 0 && 6 + len < end) end = 6 + len;
    final es = Uint8List.sublistView(pes, start, end);
    if (pid == _videoPid) {
      _h264.add(es, onConfig: onVideoConfig, onFrame: onVideo);
    } else {
      for (final (asc, frame) in AdtsReader.frames(es)) {
        if (_lastAsc == null || !_equal(asc, _lastAsc!)) {
          _lastAsc = asc;
          onAudioConfig(asc);
        }
        onAudio(frame);
      }
    }
  }

  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// H.264 Annex B (start codes) to an avcC record and AVCC (4-byte length
/// prefixed) frames.
class H264Packer {
  Uint8List? _sps, _pps;
  Uint8List? _sentConfig;

  /// NAL units of an Annex B buffer (without start codes).
  static List<Uint8List> nalUnits(Uint8List b) {
    final out = <Uint8List>[];
    var i = 0;
    int? start;
    while (i + 3 <= b.length) {
      if (b[i] == 0 && b[i + 1] == 0 && (b[i + 2] == 1 || (i + 3 < b.length && b[i + 2] == 0 && b[i + 3] == 1))) {
        final sc = b[i + 2] == 1 ? 3 : 4;
        if (start != null) {
          var end = i;
          while (end > start && b[end - 1] == 0) {
            end--; // trailing zero bytes belong to the next start code
          }
          if (end > start) out.add(Uint8List.sublistView(b, start, end));
        }
        i += sc;
        start = i;
      } else {
        i++;
      }
    }
    if (start != null && start < b.length) out.add(Uint8List.sublistView(b, start));
    return out;
  }

  static Uint8List avcC(Uint8List sps, Uint8List pps) => Uint8List.fromList([
        1, sps[1], sps[2], sps[3], 0xFF, 0xE1, //
        sps.length >> 8, sps.length & 0xFF, ...sps,
        1, pps.length >> 8, pps.length & 0xFF, ...pps,
      ]);

  void add(Uint8List annexB,
      {required void Function(Uint8List avcc) onConfig, required void Function(Uint8List data, bool key) onFrame}) {
    final frame = BytesBuilder(copy: false);
    var key = false;
    for (final nal in nalUnits(annexB)) {
      final type = nal[0] & 0x1F;
      if (type == 7 && nal.length >= 4) {
        _sps = Uint8List.fromList(nal);
        continue;
      }
      if (type == 8) {
        _pps = Uint8List.fromList(nal);
        continue;
      }
      if (type == 9) continue; // access unit delimiter
      if (type == 5) key = true;
      frame
        ..add([nal.length >> 24, (nal.length >> 16) & 0xFF, (nal.length >> 8) & 0xFF, nal.length & 0xFF])
        ..add(nal);
    }
    final sps = _sps, pps = _pps;
    if (sps != null && pps != null) {
      final cfg = avcC(sps, pps);
      if (_sentConfig == null || !TsDemuxer._equal(cfg, _sentConfig!)) {
        _sentConfig = cfg;
        onConfig(cfg);
      }
    }
    if (frame.length > 0 && _sentConfig != null) onFrame(frame.takeBytes(), key);
  }
}

/// AAC in ADTS frames: the AudioSpecificConfig and the raw frame of each.
class AdtsReader {
  static Iterable<(Uint8List, Uint8List)> frames(Uint8List b) sync* {
    var p = 0;
    while (p + 7 <= b.length) {
      if (b[p] != 0xFF || (b[p + 1] & 0xF0) != 0xF0) {
        p++;
        continue;
      }
      final protectionAbsent = b[p + 1] & 1;
      final profile = (b[p + 2] >> 6) & 3;
      final rateIdx = (b[p + 2] >> 2) & 0x0F;
      final channels = ((b[p + 2] & 1) << 2) | (b[p + 3] >> 6);
      final length = ((b[p + 3] & 3) << 11) | (b[p + 4] << 3) | (b[p + 5] >> 5);
      final header = protectionAbsent == 1 ? 7 : 9;
      if (length < header || p + length > b.length) return;
      final objectType = profile + 1;
      final asc = Uint8List.fromList([(objectType << 3) | (rateIdx >> 1), ((rateIdx & 1) << 7) | (channels << 3)]);
      yield (asc, Uint8List.sublistView(b, p + header, p + length));
      p += length;
    }
  }
}
