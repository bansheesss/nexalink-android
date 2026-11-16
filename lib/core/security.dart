// X25519 + scrypt(password) -> HKDF -> AES-256-GCM. Mirrors core/security.py.
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as cg;
import 'package:pointycastle/export.dart' as pc;

import 'bytes.dart';
import 'errors.dart';

const String hkdfInfo = 'remotelink/v1';

/// scrypt(N=2^15, r=8, p=1, 32 bytes). CPU/memory heavy: use scryptKeyAsync.
Uint8List scryptKey(String password, Uint8List salt) {
  final s = pc.Scrypt();
  s.init(pc.ScryptParameters(32768, 8, 1, 32, salt));
  return s.process(Uint8List.fromList(utf8.encode(password)));
}

Future<Uint8List> scryptKeyAsync(String password, Uint8List salt) =>
    Isolate.run(() => scryptKey(password, salt));

typedef PasswordKdf = Future<Uint8List> Function(String password, Uint8List salt);

Uint8List hmacSha256(List<int> key, List<int> data) => Uint8List.fromList(
    crypto.Hmac(crypto.sha256, key).convert(data).bytes);

Uint8List sha256Bytes(List<int> data) =>
    Uint8List.fromList(crypto.sha256.convert(data).bytes);

/// RFC 5869 HKDF-SHA256.
Uint8List hkdfSha256(
    List<int> ikm, List<int> salt, List<int> info, int length) {
  final prk = hmacSha256(salt, ikm);
  final out = <int>[];
  var t = <int>[];
  var i = 1;
  while (out.length < length) {
    t = hmacSha256(prk, [...t, ...info, i]);
    out.addAll(t);
    i++;
  }
  return Uint8List.fromList(out.sublist(0, length));
}

/// AES-256-GCM with implicit counter nonces (4 zero bytes + u64 BE counter).
class SessionCipher {
  SessionCipher(List<int> sendKey, List<int> recvKey)
      : _send = cg.SecretKey(sendKey),
        _recv = cg.SecretKey(recvKey);

  final cg.SecretKey _send;
  final cg.SecretKey _recv;
  final cg.AesGcm _aes = cg.AesGcm.with256bits();
  int _sendCtr = 0;
  int _recvCtr = 0;

  static Uint8List _nonce(int counter) {
    final b = Uint8List(12);
    ByteData.view(b.buffer).setUint64(4, counter);
    return b;
  }

  /// Returns ciphertext || 16-byte tag.
  Future<Uint8List> encrypt(Uint8List plain, Uint8List aad) async {
    final box = await _aes.encrypt(plain,
        secretKey: _send, nonce: _nonce(_sendCtr), aad: aad);
    _sendCtr++;
    return concat([box.cipherText, box.mac.bytes]);
  }

  Future<Uint8List> decrypt(Uint8List data, Uint8List aad) async {
    if (data.length < 16) throw AuthError('frame authentication failed');
    final ct = Uint8List.sublistView(data, 0, data.length - 16);
    final tag = Uint8List.sublistView(data, data.length - 16);
    try {
      final pt = await _aes.decrypt(
          cg.SecretBox(ct, nonce: _nonce(_recvCtr), mac: cg.Mac(tag)),
          secretKey: _recv,
          aad: aad);
      _recvCtr++;
      return Uint8List.fromList(pt);
    } on cg.SecretBoxAuthenticationError {
      throw AuthError('frame authentication failed');
    }
  }
}

class SessionKeys {
  SessionKeys(this.c2h, this.h2c, this.authKey, this.cipher);
  final Uint8List c2h;
  final Uint8List h2c;
  final Uint8List authKey;
  final SessionCipher cipher;

  Uint8List proof(String label) => hmacSha256(authKey, utf8.encode(label));
}

Future<SessionKeys> deriveSession({
  required cg.SimpleKeyPair private,
  required Uint8List peerPub,
  required String password,
  required Uint8List salt,
  required Uint8List transcript,
  required bool isClient,
  PasswordKdf kdf = scryptKeyAsync,
}) async {
  final secret = await cg.X25519().sharedSecretKey(
      keyPair: private,
      remotePublicKey:
          cg.SimplePublicKey(peerPub, type: cg.KeyPairType.x25519));
  final shared = Uint8List.fromList(await secret.extractBytes());
  final pwKey = await kdf(password, salt);
  final okm = hkdfSha256(concat([shared, pwKey]), transcript,
      utf8.encode(hkdfInfo), 96);
  final c2h = Uint8List.sublistView(okm, 0, 32);
  final h2c = Uint8List.sublistView(okm, 32, 64);
  final auth = Uint8List.sublistView(okm, 64, 96);
  final cipher =
      isClient ? SessionCipher(c2h, h2c) : SessionCipher(h2c, c2h);
  return SessionKeys(c2h, h2c, auth, cipher);
}
