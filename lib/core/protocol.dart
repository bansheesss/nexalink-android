// Wire protocol, mirrors core/protocol.py of the Python reference.
import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

const int protocolVersion = 1;
const int maxHandshakeSize = 64 * 1024;
const int maxFrameSize = 32 * 1024 * 1024;
const int tagLen = 16;

class MsgType {
  static const int ping = 0x01;
  static const int pong = 0x02;
  static const int bye = 0x03;
  static const int error = 0x04;
  static const int sessionInfo = 0x05;
  static const int frame = 0x10;
  static const int frameRequest = 0x11;
  static const int mouseMove = 0x20;
  static const int mouseButton = 0x21;
  static const int mouseScroll = 0x22;
  static const int key = 0x23;
  static const int clipboard = 0x30;
  static const int fileOffer = 0x40;
  static const int fileAccept = 0x41;
  static const int fileChunk = 0x42;
  static const int fileDone = 0x43;
  static const int fileAbort = 0x44;

  static const Set<int> known = {
    ping, pong, bye, error, sessionInfo, frame, frameRequest, mouseMove,
    mouseButton, mouseScroll, key, clipboard, fileOffer, fileAccept,
    fileChunk, fileDone, fileAbort,
  };

  static bool isFile(int t) => t >= fileOffer && t <= fileAbort;
}

class Codec {
  static const int jpeg = 1;
  static const int webp = 2;
}

class FrameMsg {
  FrameMsg(this.frameId, this.timestampMs, this.codec, this.width,
      this.height, this.data);

  static const int headerSize = 13; // !IIBHH

  final int frameId;
  final int timestampMs;
  final int codec;
  final int width;
  final int height;
  final Uint8List data;

  Uint8List pack() {
    final out = Uint8List(headerSize + data.length);
    final bd = ByteData.view(out.buffer);
    bd.setUint32(0, frameId);
    bd.setUint32(4, timestampMs & 0xFFFFFFFF);
    bd.setUint8(8, codec);
    bd.setUint16(9, width);
    bd.setUint16(11, height);
    out.setAll(headerSize, data);
    return out;
  }

  static FrameMsg unpack(Uint8List body) {
    if (body.length < headerSize) throw ProtocolError('short frame');
    final bd = ByteData.sublistView(body);
    final codec = bd.getUint8(8);
    if (codec != Codec.jpeg && codec != Codec.webp) {
      throw ProtocolError('unknown codec');
    }
    return FrameMsg(bd.getUint32(0), bd.getUint32(4), codec, bd.getUint16(9),
        bd.getUint16(11), Uint8List.sublistView(body, headerSize));
  }
}

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// Normalised mouse position, 0..1 -> 0..65535 (truncating, like Python int()).
Uint8List packMouseMove(double nx, double ny) {
  final out = Uint8List(4);
  final bd = ByteData.view(out.buffer);
  bd.setUint16(0, _clampInt((nx * 65535).truncate(), 0, 65535));
  bd.setUint16(2, _clampInt((ny * 65535).truncate(), 0, 65535));
  return out;
}

(double, double) unpackMouseMove(Uint8List b) {
  final bd = ByteData.sublistView(b);
  return (bd.getUint16(0) / 65535, bd.getUint16(2) / 65535);
}

Uint8List packMouseButton(int button, bool pressed) =>
    Uint8List.fromList([button, pressed ? 1 : 0]);

Uint8List packScroll(int dx, int dy) {
  final out = Uint8List(4);
  final bd = ByteData.view(out.buffer);
  bd.setInt16(0, _clampInt(dx, -32768, 32767));
  bd.setInt16(2, _clampInt(dy, -32768, 32767));
  return out;
}

/// Keys travel as platform-neutral names matching pynput.keyboard.Key.
Uint8List packKey(String name, bool pressed) =>
    Uint8List.fromList([pressed ? 1 : 0, ...utf8.encode(name)]);

Uint8List packJson(Map<String, dynamic> obj) =>
    Uint8List.fromList(utf8.encode(jsonEncode(obj)));

Map<String, dynamic> unpackJson(Uint8List body) {
  try {
    final obj = jsonDecode(utf8.decode(body));
    if (obj is Map<String, dynamic>) return obj;
  } catch (_) {
    // fall through
  }
  throw ProtocolError('bad json');
}
