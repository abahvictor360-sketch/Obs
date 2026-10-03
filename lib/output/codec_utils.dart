// H.264 and AAC bitstream helpers used to package encoder output for
// RTMP/FLV. Native encoders (Android MediaCodec, iOS VideoToolbox) emit
// H.264 in Annex-B form; FLV/RTMP needs AVCC (length-prefixed) NAL units
// and an AVCDecoderConfigurationRecord.

import 'dart:typed_data';

class H264 {
  static const nalSlice = 1;
  static const nalIdr = 5;
  static const nalSei = 6;
  static const nalSps = 7;
  static const nalPps = 8;
  static const nalAud = 9;

  static int nalType(Uint8List nal) => nal.isEmpty ? 0 : nal[0] & 0x1F;

  /// Splits an Annex-B byte stream (00 00 01 / 00 00 00 01 start codes) into
  /// NAL units without start codes. If [data] has no start code it is assumed
  /// to already be a single NAL unit.
  static List<Uint8List> splitAnnexB(Uint8List data) {
    final nals = <Uint8List>[];
    final n = data.length;
    var i = 0;
    var start = -1;
    while (i + 2 < n) {
      if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
        if (start >= 0) {
          var end = i;
          // A 4-byte start code's leading zero belongs to the code, not the NAL.
          if (end > start && data[end - 1] == 0) end--;
          if (end > start) nals.add(Uint8List.sublistView(data, start, end));
        }
        i += 3;
        start = i;
      } else {
        i++;
      }
    }
    if (start >= 0) {
      if (start < n) nals.add(Uint8List.sublistView(data, start, n));
    } else if (n > 0) {
      nals.add(data);
    }
    return nals;
  }

  /// Converts NAL units to AVCC form (4 byte big-endian length prefixes).
  static Uint8List toAvcc(Iterable<Uint8List> nals) {
    final b = BytesBuilder(copy: false);
    for (final nal in nals) {
      final len = nal.length;
      b.add([(len >> 24) & 0xFF, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF]);
      b.add(nal);
    }
    return b.takeBytes();
  }

  /// Builds an AVCDecoderConfigurationRecord (ISO 14496-15 5.2.4.1).
  static Uint8List decoderConfigRecord(Uint8List sps, Uint8List pps) {
    if (sps.length < 4) throw ArgumentError('SPS too short');
    final b = BytesBuilder();
    b.add([
      1, // configurationVersion
      sps[1], // AVCProfileIndication
      sps[2], // profile_compatibility
      sps[3], // AVCLevelIndication
      0xFF, // 6 bits reserved + lengthSizeMinusOne = 3
      0xE1, // 3 bits reserved + numOfSequenceParameterSets = 1
      (sps.length >> 8) & 0xFF,
      sps.length & 0xFF,
    ]);
    b.add(sps);
    b.add([1, (pps.length >> 8) & 0xFF, pps.length & 0xFF]);
    b.add(pps);
    return b.takeBytes();
  }
}

class Aac {
  static const sampleRates = [
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
  ];

  /// AudioSpecificConfig for AAC-LC.
  static Uint8List audioSpecificConfig({required int sampleRate, required int channels}) {
    final idx = sampleRates.indexOf(sampleRate);
    if (idx < 0) throw ArgumentError('Unsupported AAC sample rate $sampleRate');
    const objectType = 2; // AAC LC
    return Uint8List.fromList([
      (objectType << 3) | (idx >> 1),
      ((idx & 1) << 7) | (channels << 3),
    ]);
  }

  /// Reads (sampleRate, channels) from an AudioSpecificConfig.
  static (int, int) parseAudioSpecificConfig(Uint8List asc) {
    final idx = ((asc[0] & 0x07) << 1) | (asc[1] >> 7);
    final ch = (asc[1] >> 3) & 0x0F;
    return (idx < sampleRates.length ? sampleRates[idx] : 44100, ch);
  }

  /// Splits an ADTS stream into raw AAC frames; also returns the
  /// AudioSpecificConfig derived from the first header.
  static (Uint8List asc, List<Uint8List> frames) parseAdts(Uint8List data) {
    final frames = <Uint8List>[];
    Uint8List? asc;
    var i = 0;
    while (i + 7 <= data.length) {
      if (data[i] != 0xFF || (data[i + 1] & 0xF0) != 0xF0) {
        throw FormatException('Bad ADTS sync at $i');
      }
      final protectionAbsent = data[i + 1] & 1;
      final profile = (data[i + 2] >> 6) + 1;
      final srIdx = (data[i + 2] >> 2) & 0x0F;
      final ch = ((data[i + 2] & 1) << 2) | (data[i + 3] >> 6);
      final frameLen = ((data[i + 3] & 0x03) << 11) | (data[i + 4] << 3) | (data[i + 5] >> 5);
      final headerLen = protectionAbsent == 1 ? 7 : 9;
      asc ??= Uint8List.fromList([
        (profile << 3) | (srIdx >> 1),
        ((srIdx & 1) << 7) | (ch << 3),
      ]);
      frames.add(Uint8List.sublistView(data, i + headerLen, i + frameLen));
      i += frameLen;
    }
    return (asc ?? Uint8List(2), frames);
  }
}
