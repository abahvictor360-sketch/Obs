// Minimal AMF0 encoder/decoder: enough for RTMP command messages
// (connect, createStream, publish, onStatus, @setDataFrame).

import 'dart:convert';
import 'dart:typed_data';

/// Marker type so `null` and AMF0 "undefined" can be distinguished.
class Amf0Undefined {
  const Amf0Undefined();
}

/// Wraps a map that must be encoded as an AMF0 ECMA array instead of an
/// object (used by onMetaData).
class Amf0EcmaArray {
  const Amf0EcmaArray(this.values);
  final Map<String, Object?> values;
}

class Amf0 {
  static const _number = 0x00;
  static const _boolean = 0x01;
  static const _string = 0x02;
  static const _object = 0x03;
  static const _null = 0x05;
  static const _undefined = 0x06;
  static const _ecmaArray = 0x08;
  static const _objectEnd = 0x09;
  static const _strictArray = 0x0A;
  static const _date = 0x0B;
  static const _longString = 0x0C;

  static Uint8List encodeAll(List<Object?> values) {
    final b = BytesBuilder();
    for (final v in values) {
      _encode(b, v);
    }
    return b.takeBytes();
  }

  static void _encode(BytesBuilder b, Object? v) {
    if (v == null) {
      b.addByte(_null);
    } else if (v is Amf0Undefined) {
      b.addByte(_undefined);
    } else if (v is num) {
      b.addByte(_number);
      final d = ByteData(8)..setFloat64(0, v.toDouble());
      b.add(d.buffer.asUint8List());
    } else if (v is bool) {
      b
        ..addByte(_boolean)
        ..addByte(v ? 1 : 0);
    } else if (v is String) {
      final bytes = utf8.encode(v);
      if (bytes.length > 0xFFFF) {
        b.addByte(_longString);
        b.add(_u32(bytes.length));
      } else {
        b.addByte(_string);
        b.add(_u16(bytes.length));
      }
      b.add(bytes);
    } else if (v is Amf0EcmaArray) {
      b.addByte(_ecmaArray);
      b.add(_u32(v.values.length));
      _encodeProps(b, v.values);
    } else if (v is Map) {
      b.addByte(_object);
      _encodeProps(b, v.cast<String, Object?>());
    } else if (v is List) {
      b.addByte(_strictArray);
      b.add(_u32(v.length));
      for (final e in v) {
        _encode(b, e);
      }
    } else {
      throw ArgumentError('Unsupported AMF0 value: ${v.runtimeType}');
    }
  }

  static void _encodeProps(BytesBuilder b, Map<String, Object?> m) {
    m.forEach((k, val) {
      final kb = utf8.encode(k);
      b.add(_u16(kb.length));
      b.add(kb);
      _encode(b, val);
    });
    b.add(const [0, 0, _objectEnd]);
  }

  static List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
  static List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

  /// Decodes all values in [data].
  static List<Object?> decodeAll(Uint8List data) {
    final r = _Reader(data);
    final out = <Object?>[];
    while (r.pos < data.length) {
      out.add(r.value());
    }
    return out;
  }
}

class _Reader {
  _Reader(this.data) : bd = ByteData.sublistView(data);
  final Uint8List data;
  final ByteData bd;
  int pos = 0;

  int u8() => data[pos++];
  int u16() {
    final v = bd.getUint16(pos);
    pos += 2;
    return v;
  }

  int u32() {
    final v = bd.getUint32(pos);
    pos += 4;
    return v;
  }

  String str(int len) {
    final s = utf8.decode(data.sublist(pos, pos + len), allowMalformed: true);
    pos += len;
    return s;
  }

  Map<String, Object?> props() {
    final m = <String, Object?>{};
    while (true) {
      final len = u16();
      if (len == 0 && data[pos] == Amf0._objectEnd) {
        pos++;
        return m;
      }
      final k = str(len);
      m[k] = value();
    }
  }

  Object? value() {
    final t = u8();
    switch (t) {
      case Amf0._number:
        final v = bd.getFloat64(pos);
        pos += 8;
        return v;
      case Amf0._boolean:
        return u8() != 0;
      case Amf0._string:
        return str(u16());
      case Amf0._longString:
        return str(u32());
      case Amf0._object:
        return props();
      case Amf0._null:
        return null;
      case Amf0._undefined:
        return const Amf0Undefined();
      case Amf0._ecmaArray:
        u32();
        return props();
      case Amf0._strictArray:
        final n = u32();
        return [for (var i = 0; i < n; i++) value()];
      case Amf0._date:
        final ms = bd.getFloat64(pos);
        pos += 10; // 8 byte double + 2 byte timezone
        return DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true);
      default:
        throw FormatException('Unsupported AMF0 marker 0x${t.toRadixString(16)} at ${pos - 1}');
    }
  }
}
