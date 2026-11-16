import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotelink/core/bytes.dart';
import 'package:remotelink/core/errors.dart';
import 'package:remotelink/core/protocol.dart';

import 'golden.dart';

void main() {
  final msgs = (golden['messages'] as List).cast<Map<String, dynamic>>();

  test('message packers produce the exact bytes of the Python reference', () {
    for (final m in msgs) {
      final Uint8List got;
      switch (m['kind']) {
        case 'mouse_move':
          got = packMouseMove((m['nx'] as num).toDouble(), (m['ny'] as num).toDouble());
          break;
        case 'mouse_button':
          got = packMouseButton(m['button'] as int, m['pressed'] as bool);
          break;
        case 'scroll':
          got = packScroll(m['dx'] as int, m['dy'] as int);
          break;
        case 'key':
          got = packKey(m['name'] as String, m['pressed'] as bool);
          break;
        case 'frame':
          got = FrameMsg(m['frame_id'] as int, m['ts'] as int, m['codec'] as int,
                  m['w'] as int, m['h'] as int, fromHex(m['data'] as String))
              .pack();
          break;
        case 'json':
          got = packJson(Map<String, dynamic>.from(m['args'] as Map));
          break;
        default:
          throw StateError('unknown vector kind ${m['kind']}');
      }
      expect(toHex(got), m['hex'], reason: '${m['kind']} $m');
    }
  });

  test('frame unpack round-trips Python frames', () {
    for (final m in msgs.where((m) => m['kind'] == 'frame')) {
      final f = FrameMsg.unpack(fromHex(m['hex'] as String));
      expect(f.frameId, m['frame_id']);
      expect(f.timestampMs, m['ts']);
      expect(f.width, m['w']);
      expect(f.height, m['h']);
      expect(toHex(f.data), m['data']);
    }
    expect(() => FrameMsg.unpack(Uint8List(5)), throwsA(isA<ProtocolError>()));
  });

  test('mouse/scroll/key decode', () {
    final mm = unpackMouseMove(packMouseMove(0.5, 0.25));
    expect(mm.$1, closeTo(0.5, 1e-3));
    expect(mm.$2, closeTo(0.25, 1e-3));
  });

  test('limits and message ids match the reference', () {
    final l = golden['limits'] as Map<String, dynamic>;
    expect(maxHandshakeSize, l['max_handshake_size']);
    expect(maxFrameSize, l['max_frame_size']);
    expect(protocolVersion, (golden['meta'] as Map)['protocol_version']);
    expect(MsgType.frame, 0x10);
    expect(MsgType.fileAbort, 0x44);
  });

  test('unpackJson rejects non-objects', () {
    expect(() => unpackJson(Uint8List.fromList([0x5b, 0x5d])),
        throwsA(isA<ProtocolError>()));
  });
}
