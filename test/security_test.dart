import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_test/flutter_test.dart';
import 'package:viunalink/core/bytes.dart';
import 'package:viunalink/core/errors.dart';
import 'package:viunalink/core/security.dart';

import 'golden.dart';

const _slow = Timeout(Duration(minutes: 5));

void main() {
  final prim = golden['primitives'] as Map<String, dynamic>;
  final hs = golden['handshake_ok'] as Map<String, dynamic>;

  test('scrypt matches Python (N=2^15, r=8, p=1)', () {
    final s = prim['scrypt'] as Map<String, dynamic>;
    final key = scryptKey(s['password'] as String, fromHex(s['salt'] as String));
    expect(toHex(key), s['key']);
  }, timeout: _slow);

  test('X25519 public keys and shared secret match Python', () async {
    final x = cg.X25519();
    final p = prim['x25519'] as Map<String, dynamic>;
    final c = await x.newKeyPairFromSeed(fromHex(p['client_seed'] as String));
    final h = await x.newKeyPairFromSeed(fromHex(p['host_seed'] as String));
    final cPub = await c.extractPublicKey();
    final hPub = await h.extractPublicKey();
    expect(toHex(cPub.bytes), p['client_pub']);
    expect(toHex(hPub.bytes), p['host_pub']);
    final shared = await x.sharedSecretKey(keyPair: c, remotePublicKey: hPub);
    expect(toHex(await shared.extractBytes()), p['shared']);
  });

  test('HKDF-SHA256 matches Python', () {
    final k = prim['hkdf'] as Map<String, dynamic>;
    final okm = hkdfSha256(fromHex(k['ikm'] as String), fromHex(k['salt'] as String),
        utf8.encode(k['info'] as String), 96);
    expect(toHex(okm), k['okm']);
  });

  test('deriveSession: keys, proofs and AES-GCM frames match Python', () async {
    final x = cg.X25519();
    final kp = await x.newKeyPairFromSeed(fromHex(hs['client_seed'] as String));
    final hostKp = await x.newKeyPairFromSeed(fromHex(hs['host_seed'] as String));
    final hostPub = Uint8List.fromList((await hostKp.extractPublicKey()).bytes);
    final keys = await deriveSession(
      private: kp,
      peerPub: hostPub,
      password: hs['password'] as String,
      salt: fromHex(hs['salt'] as String),
      transcript: fromHex(hs['transcript'] as String),
      isClient: true,
    );
    final k = hs['keys'] as Map<String, dynamic>;
    expect(toHex(keys.c2h), k['c2h']);
    expect(toHex(keys.h2c), k['h2c']);
    expect(toHex(keys.authKey), k['auth']);
    expect(toHex(keys.proof('client')),
        plainFrameJson((hs['client_to_host'] as List)[1] as String)['proof']);
    expect(toHex(keys.proof('host')),
        plainFrameJson((hs['host_to_client'] as List)[1] as String)['proof']);

    final frames = golden['session_frames'] as Map<String, dynamic>;
    // our outgoing frames, in order (counter 0..n)
    for (final f in (frames['client_to_host'] as List).cast<Map<String, dynamic>>()) {
      final plain = Uint8List.fromList([f['type'] as int, ...fromHex(f['body'] as String)]);
      final hdr = Uint8List(4)..buffer.asByteData().setUint32(0, plain.length + 16);
      final ct = await keys.cipher.encrypt(plain, hdr);
      expect(toHex(concat([hdr, ct])), f['wire']);
    }
    // incoming frames, in order
    for (final f in (frames['host_to_client'] as List).cast<Map<String, dynamic>>()) {
      final wire = fromHex(f['wire'] as String);
      final plain = await keys.cipher.decrypt(
          Uint8List.sublistView(wire, 4), Uint8List.sublistView(wire, 0, 4));
      expect(toHex(plain), toHex([f['type'] as int, ...fromHex(f['body'] as String)]));
    }
  }, timeout: _slow);

  test('tampered and replayed frames are rejected', () async {
    final k = hs['keys'] as Map<String, dynamic>;
    final cipher = SessionCipher(fromHex(k['c2h'] as String), fromHex(k['h2c'] as String));
    final f = ((golden['session_frames'] as Map)['host_to_client'] as List).first as Map;
    final wire = fromHex(f['wire'] as String);
    final hdr = Uint8List.sublistView(wire, 0, 4);
    final body = Uint8List.fromList(wire.sublist(4));
    final bad = Uint8List.fromList(body)..[0] ^= 0x01;
    await expectLater(cipher.decrypt(bad, hdr), throwsA(isA<AuthError>()));
    // counter did not advance on failure, so the genuine frame still verifies
    await cipher.decrypt(body, hdr);
    // replay of the same frame: counter moved on -> must fail
    await expectLater(cipher.decrypt(body, hdr), throwsA(isA<AuthError>()));
  });
}
