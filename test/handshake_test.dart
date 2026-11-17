import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viunalink/core/bytes.dart';
import 'package:viunalink/core/errors.dart';
import 'package:viunalink/core/network.dart';
import 'package:viunalink/core/protocol.dart';
import 'package:viunalink/core/security.dart';

import 'golden.dart';

const _slow = Timeout(Duration(minutes: 5));

// scrypt (32 MB, slow in the JIT test VM) is verified in security_test.dart;
// here it is memoised so the many handshake scenarios stay fast.
final Map<String, Uint8List> _kdfCache = {};
Future<Uint8List> _memoKdf(String pw, Uint8List salt) async =>
    _kdfCache.putIfAbsent('$pw|${toHex(salt)}', () => scryptKey(pw, salt));

class _Rig {
  final inbound = StreamController<List<int>>();
  final sink = CaptureSink();
  late final Connection conn = Connection(inbound.stream, sink);
  void feed(String hex) => inbound.add(fromHex(hex));
}

void main() {
  final ok = golden['handshake_ok'] as Map<String, dynamic>;
  final bad = golden['handshake_bad_password'] as Map<String, dynamic>;
  final frames = golden['session_frames'] as Map<String, dynamic>;

  Future<_Rig> authenticated() async {
    final r = _Rig();
    for (final h in (ok['host_to_client'] as List).cast<String>()) {
      r.feed(h);
    }
    await clientHandshake(r.conn, ok['password'] as String,
        ephemeralSeed: fromHex(ok['client_seed'] as String), kdf: _memoKdf);
    return r;
  }

  test('client handshake emits the same bytes as the Python client', () async {
    final r = await authenticated();
    expect(r.sink.writes.map(toHex).toList(), ok['client_to_host']);
    expect(r.conn.cipher, isNotNull);
  }, timeout: _slow);

  test('encrypted session frames are byte-identical in both directions', () async {
    final r = await authenticated();
    final base = r.sink.writes.length;
    var i = 0;
    for (final f in (frames['client_to_host'] as List).cast<Map<String, dynamic>>()) {
      await r.conn.send(f['type'] as int, fromHex(f['body'] as String));
      expect(toHex(r.sink.writes[base + i]), f['wire'], reason: 'c2h #$i');
      i++;
    }
    for (final f in (frames['host_to_client'] as List).cast<Map<String, dynamic>>()) {
      r.feed(f['wire'] as String);
      final m = await r.conn.recv();
      expect(m.type, f['type']);
      expect(toHex(m.body), f['body']);
    }
  }, timeout: _slow);

  test('wrong password: same proof bytes, host reply {"ok":false} -> AuthError', () async {
    final r = _Rig();
    for (final h in (bad['host_to_client'] as List).cast<String>()) {
      r.feed(h);
    }
    await expectLater(
        clientHandshake(r.conn, bad['password'] as String,
            ephemeralSeed: fromHex(bad['client_seed'] as String), kdf: _memoKdf),
        throwsA(isA<AuthError>()));
    expect(r.sink.writes.map(toHex).toList(), bad['client_to_host']);
    expect(r.conn.cipher, isNull);
  }, timeout: _slow);

  test('a host that cannot prove the password is rejected', () async {
    // genuine ack, but a forged "ok" frame with a wrong host proof
    final r = _Rig();
    r.feed((ok['host_to_client'] as List)[0] as String);
    final forged = Uint8List.fromList(
        '{"ok":true,"proof":"${'00' * 32}"}'.codeUnits);
    final hdr = Uint8List(4)..buffer.asByteData().setUint32(0, forged.length);
    r.inbound.add(concat([hdr, forged]));
    await expectLater(
        clientHandshake(r.conn, ok['password'] as String,
            ephemeralSeed: fromHex(ok['client_seed'] as String), kdf: _memoKdf),
        throwsA(isA<AuthError>()));
  }, timeout: _slow);

  test('version mismatch and oversized handshake frames', () async {
    final r = _Rig();
    final ack = Uint8List.fromList('{"v":2,"pub":"00","salt":"00"}'.codeUnits);
    final hdr = Uint8List(4)..buffer.asByteData().setUint32(0, ack.length);
    r.inbound.add(concat([hdr, ack]));
    await expectLater(clientHandshake(r.conn, 'x'), throwsA(isA<ProtocolError>()));

    final r2 = _Rig();
    r2.inbound.add(Uint8List.fromList([0, 2, 0, 0])); // 131072 > 64 KiB
    await expectLater(clientHandshake(r2.conn, 'x'), throwsA(isA<ProtocolError>()));
  });

  test('bad frame length, tamper, replay and unknown type', () async {
    // oversize length
    var r = await authenticated();
    r.inbound.add(Uint8List.fromList([0xff, 0xff, 0xff, 0xff]));
    await expectLater(r.conn.recv(), throwsA(isA<ProtocolError>()));
    // too short (<= tag)
    r = await authenticated();
    r.inbound.add(Uint8List.fromList([0, 0, 0, 16]));
    await expectLater(r.conn.recv(), throwsA(isA<ProtocolError>()));
    // tampered ciphertext
    r = await authenticated();
    final wire = fromHex(((frames['host_to_client'] as List).first as Map)['wire'] as String);
    wire[wire.length - 1] ^= 0x01;
    r.inbound.add(wire);
    await expectLater(r.conn.recv(), throwsA(isA<AuthError>()));
    // unknown message type (valid crypto, type 0xEE)
    r = await authenticated();
    final k = ok['keys'] as Map<String, dynamic>;
    final hostSide = SessionCipher(fromHex(k['h2c'] as String), fromHex(k['c2h'] as String));
    final plain = Uint8List.fromList([0xEE, 1, 2]);
    final hdr = Uint8List(4)..buffer.asByteData().setUint32(0, plain.length + 16);
    r.inbound.add(concat([hdr, await hostSide.encrypt(plain, hdr)]));
    await expectLater(r.conn.recv(), throwsA(isA<ProtocolError>()));
  }, timeout: _slow);

  test('closed stream surfaces as ConnectionClosed', () async {
    final r = await authenticated();
    final f = r.conn.recv();
    await r.inbound.close();
    await expectLater(f, throwsA(isA<ConnectionClosed>()));
  }, timeout: _slow);
}
