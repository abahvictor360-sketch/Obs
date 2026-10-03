// RTMP chunk stream encoding/decoding (Adobe RTMP spec, section 5.3).
// Pure Dart with no I/O so it can be unit tested.

import 'dart:typed_data';

class RtmpMessage {
  RtmpMessage({
    required this.chunkStreamId,
    required this.typeId,
    required this.timestamp,
    required this.streamId,
    required this.payload,
  });

  final int chunkStreamId;
  final int typeId;
  final int timestamp;
  final int streamId;
  final Uint8List payload;
}

/// Message type ids.
class RtmpType {
  static const setChunkSize = 1;
  static const abort = 2;
  static const ack = 3;
  static const userControl = 4;
  static const windowAckSize = 5;
  static const setPeerBandwidth = 6;
  static const audio = 8;
  static const video = 9;
  static const dataAmf0 = 18;
  static const commandAmf0 = 20;
}

/// Serializes messages into chunks. Every message starts with a type-0 header
/// (simple and always valid); continuation chunks use type-3 headers.
class RtmpChunkWriter {
  int chunkSize = 128;

  Uint8List encode(RtmpMessage m) {
    final csid = m.chunkStreamId;
    if (csid < 2 || csid > 65599) throw ArgumentError('Invalid chunk stream id $csid');
    final payload = m.payload;
    final ts = m.timestamp & 0xFFFFFFFF;
    final extended = ts >= 0xFFFFFF;
    final b = BytesBuilder(copy: false);

    void basicHeader(int fmt) {
      if (csid < 64) {
        b.addByte((fmt << 6) | csid);
      } else if (csid < 320) {
        b.add([(fmt << 6), csid - 64]);
      } else {
        final v = csid - 64;
        b.add([(fmt << 6) | 1, v & 0xFF, (v >> 8) & 0xFF]);
      }
    }

    void extTs() {
      if (extended) b.add([(ts >> 24) & 0xFF, (ts >> 16) & 0xFF, (ts >> 8) & 0xFF, ts & 0xFF]);
    }

    basicHeader(0);
    final t3 = extended ? 0xFFFFFF : ts;
    final len = payload.length;
    final sid = m.streamId;
    b.add([
      (t3 >> 16) & 0xFF, (t3 >> 8) & 0xFF, t3 & 0xFF,
      (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF,
      m.typeId,
      // Message stream id is little-endian.
      sid & 0xFF, (sid >> 8) & 0xFF, (sid >> 16) & 0xFF, (sid >> 24) & 0xFF,
    ]);
    extTs();

    var off = 0;
    while (true) {
      final n = (len - off) < chunkSize ? len - off : chunkSize;
      b.add(Uint8List.sublistView(payload, off, off + n));
      off += n;
      if (off >= len) break;
      basicHeader(3);
      extTs();
    }
    return b.takeBytes();
  }
}

class _ChunkStreamState {
  int timestamp = 0;
  int delta = 0;
  int length = 0;
  int typeId = 0;
  int streamId = 0;
  bool extended = false;
  BytesBuilder? partial;
  int received = 0;
}

/// Incremental chunk parser: feed it bytes as they arrive and it emits whole
/// messages. Handles all four header formats and extended timestamps.
class RtmpChunkReader {
  RtmpChunkReader(this.onMessage);

  final void Function(RtmpMessage) onMessage;
  int chunkSize = 128;

  final Map<int, _ChunkStreamState> _streams = {};
  Uint8List _buf = Uint8List(0);
  int _pos = 0;

  void add(List<int> data) {
    if (_pos >= _buf.length) {
      _buf = data is Uint8List ? data : Uint8List.fromList(data);
    } else {
      final rest = _buf.length - _pos;
      final nb = Uint8List(rest + data.length)
        ..setRange(0, rest, _buf, _pos)
        ..setRange(rest, rest + data.length, data);
      _buf = nb;
    }
    _pos = 0;
    while (_tryChunk()) {}
  }

  bool _tryChunk() {
    final start = _pos;
    final avail = _buf.length - _pos;
    if (avail < 1) return false;
    var p = _pos;
    final b0 = _buf[p++];
    final fmt = b0 >> 6;
    var csid = b0 & 0x3F;
    if (csid == 0) {
      if (avail < 2) return false;
      csid = _buf[p++] + 64;
    } else if (csid == 1) {
      if (avail < 3) return false;
      csid = _buf[p] + (_buf[p + 1] << 8) + 64;
      p += 2;
    }
    const headerSizes = [11, 7, 3, 0];
    final hs = headerSizes[fmt];
    if (_buf.length - p < hs) return false;
    final st = _streams.putIfAbsent(csid, _ChunkStreamState.new);
    final startsMessage = st.partial == null;

    int ts3 = 0;
    int len = st.length, type = st.typeId, sid = st.streamId;
    if (fmt <= 2) {
      ts3 = (_buf[p] << 16) | (_buf[p + 1] << 8) | _buf[p + 2];
    }
    if (fmt <= 1) {
      len = (_buf[p + 3] << 16) | (_buf[p + 4] << 8) | _buf[p + 5];
      type = _buf[p + 6];
    }
    if (fmt == 0) {
      sid = _buf[p + 7] | (_buf[p + 8] << 8) | (_buf[p + 9] << 16) | (_buf[p + 10] << 24);
    }
    p += hs;

    final hasExt = fmt <= 2 ? ts3 == 0xFFFFFF : st.extended;
    int ext = 0;
    if (hasExt) {
      if (_buf.length - p < 4) return false;
      ext = (_buf[p] << 24) | (_buf[p + 1] << 16) | (_buf[p + 2] << 8) | _buf[p + 3];
      p += 4;
    }

    final remaining = startsMessage ? len : st.length - st.received;
    final n = remaining < chunkSize ? remaining : chunkSize;
    if (_buf.length - p < n) {
      _pos = start;
      return false;
    }

    // Commit header state.
    if (startsMessage) {
      final tsField = hasExt ? ext : ts3;
      switch (fmt) {
        case 0:
          st.timestamp = tsField;
          st.delta = 0;
        case 1:
        case 2:
          st.delta = tsField;
          st.timestamp += tsField;
        case 3:
          st.timestamp += st.delta;
      }
      st.extended = fmt <= 2 ? hasExt : st.extended;
      st.length = len;
      st.typeId = type;
      st.streamId = sid;
      st.partial = BytesBuilder(copy: true);
      st.received = 0;
    }

    st.partial!.add(Uint8List.sublistView(_buf, p, p + n));
    st.received += n;
    p += n;
    _pos = p;

    if (st.received >= st.length) {
      final payload = st.partial!.takeBytes();
      st.partial = null;
      st.received = 0;
      final msg = RtmpMessage(
        chunkStreamId: csid,
        typeId: st.typeId,
        timestamp: st.timestamp,
        streamId: st.streamId,
        payload: payload,
      );
      if (msg.typeId == RtmpType.setChunkSize && payload.length >= 4) {
        chunkSize = ByteData.sublistView(payload).getUint32(0) & 0x7FFFFFFF;
      }
      onMessage(msg);
    }
    return true;
  }
}
