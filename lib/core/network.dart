// Framed, encrypted connection + client-side handshake (core/network.py).
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;

import 'bytes.dart';
import 'errors.dart';
import 'protocol.dart';
import 'security.dart';

abstract class MessageSink {
  Future<void> send(int type, Uint8List body);
}

class IncomingMessage {
  IncomingMessage(this.type, this.body);
  final int type;
  final Uint8List body;
}

class Connection implements MessageSink {
  Connection(Stream<List<int>> input, this._out,
      {Future<void> Function()? flush, void Function()? onClose})
      : _flush = flush,
        _onClose = onClose {
    _sub = input.listen(_onData,
        onDone: _onDone, onError: _onError, cancelOnError: true);
  }

  factory Connection.fromSocket(Socket s) => Connection(s, s,
      flush: () => s.flush(), onClose: () => s.destroy());

  final StreamSink<List<int>> _out;
  final Future<void> Function()? _flush;
  final void Function()? _onClose;
  late final StreamSubscription<List<int>> _sub;
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _avail = 0;
  bool _closed = false;
  Completer<void>? _wait;
  final Mutex _sendLock = Mutex();

  SessionCipher? cipher;

  void _onData(List<int> d) {
    final u = d is Uint8List ? d : Uint8List.fromList(d);
    _chunks.add(u);
    _avail += u.length;
    _wake();
  }

  void _onDone() {
    _closed = true;
    _wake();
  }

  void _onError(Object e, [StackTrace? st]) {
    _closed = true;
    _wake();
  }

  void _wake() {
    final w = _wait;
    _wait = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<Uint8List> readExactly(int n) async {
    while (_avail < n) {
      if (_closed) throw ConnectionClosed();
      _wait = Completer<void>();
      await _wait!.future;
    }
    final out = Uint8List(n);
    var off = 0;
    while (off < n) {
      final c = _chunks.removeFirst();
      final take = (n - off) < c.length ? (n - off) : c.length;
      out.setRange(off, off + take, c);
      off += take;
      if (take < c.length) {
        _chunks.addFirst(Uint8List.sublistView(c, take));
      }
    }
    _avail -= n;
    return out;
  }

  // ---- plaintext frames (handshake only) ----
  Future<void> writePlain(Uint8List payload) {
    return _sendLock.run(() async {
      final hdr = Uint8List(4);
      ByteData.view(hdr.buffer).setUint32(0, payload.length);
      _out.add(concat([hdr, payload]));
      await _flush?.call();
    });
  }

  Future<Uint8List> readPlain() async {
    final hdr = await readExactly(4);
    final n = ByteData.sublistView(hdr).getUint32(0);
    if (n > maxHandshakeSize) throw ProtocolError('handshake frame too large');
    return readExactly(n);
  }

  // ---- encrypted frames ----
  @override
  Future<void> send(int type, Uint8List body) {
    final c = cipher;
    if (c == null) throw ProtocolError('not authenticated');
    final plain = Uint8List(1 + body.length);
    plain[0] = type;
    plain.setAll(1, body);
    // The lock covers encryption so counter order == wire order.
    return _sendLock.run(() async {
      final hdr = Uint8List(4);
      ByteData.view(hdr.buffer).setUint32(0, plain.length + tagLen);
      final ct = await c.encrypt(plain, hdr);
      _out.add(concat([hdr, ct]));
      await _flush?.call();
    });
  }

  Future<IncomingMessage> recv() async {
    final c = cipher;
    if (c == null) throw ProtocolError('not authenticated');
    final hdr = await readExactly(4);
    final n = ByteData.sublistView(hdr).getUint32(0);
    if (!(n > tagLen && n <= maxFrameSize)) {
      throw ProtocolError('bad frame length');
    }
    final ct = await readExactly(n);
    final plain = await c.decrypt(ct, hdr);
    if (plain.isEmpty || !MsgType.known.contains(plain[0])) {
      throw ProtocolError('unknown message type');
    }
    return IncomingMessage(plain[0], Uint8List.sublistView(plain, 1));
  }

  Future<void> close() async {
    try {
      await _sub.cancel();
    } catch (_) {}
    try {
      await _out.close();
    } catch (_) {}
    _onClose?.call();
    _closed = true;
    _wake();
  }
}

Map<String, dynamic> _parse(Uint8List raw) {
  try {
    final o = jsonDecode(utf8.decode(raw));
    if (o is Map<String, dynamic>) return o;
  } catch (_) {}
  throw ProtocolError('malformed handshake');
}

Uint8List _dump(Map<String, dynamic> o) =>
    Uint8List.fromList(utf8.encode(jsonEncode(o)));

/// hello -> ack -> proof -> ok. Throws AuthError on a wrong password.
/// [ephemeralSeed] is for deterministic tests only.
Future<void> clientHandshake(Connection conn, String password,
    {List<int>? ephemeralSeed, PasswordKdf kdf = scryptKeyAsync}) async {
  final x = cg.X25519();
  final kp = ephemeralSeed != null
      ? await x.newKeyPairFromSeed(ephemeralSeed)
      : await x.newKeyPair();
  final pub = (await kp.extractPublicKey()).bytes;
  final hello = _dump({'v': protocolVersion, 'pub': toHex(pub)});
  await conn.writePlain(hello);
  final ackRaw = await conn.readPlain();
  final ack = _parse(ackRaw);
  Uint8List hostPub;
  Uint8List salt;
  try {
    if (ack['v'] != protocolVersion) {
      throw ProtocolError('protocol version mismatch');
    }
    hostPub = fromHex(ack['pub'] as String);
    salt = fromHex(ack['salt'] as String);
    if (hostPub.length != 32) throw ProtocolError('bad host key');
  } on ProtocolError {
    rethrow;
  } catch (_) {
    throw ProtocolError('malformed handshake');
  }
  final transcript = sha256Bytes(concat([hello, ackRaw]));
  final keys = await deriveSession(
      private: kp,
      peerPub: hostPub,
      password: password,
      salt: salt,
      transcript: transcript,
      isClient: true,
      kdf: kdf);
  await conn.writePlain(_dump({'proof': toHex(keys.proof('client'))}));
  final resp = _parse(await conn.readPlain());
  if (resp['ok'] != true) throw AuthError('wrong password or ID');
  Uint8List hostProof;
  try {
    hostProof = fromHex(resp['proof'] as String);
  } catch (_) {
    throw ProtocolError('malformed handshake');
  }
  if (!constTimeEquals(hostProof, keys.proof('host'))) {
    throw AuthError('host failed to prove knowledge of password');
  }
  conn.cipher = keys.cipher;
}
