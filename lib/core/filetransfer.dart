// Consent-based, SHA-256 verified file transfer (core/filetransfer.py).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'bytes.dart';
import 'errors.dart';
import 'network.dart';
import 'protocol.dart';

const int fileChunkSize = 256 * 1024;

const Set<String> _reserved = {
  'CON', 'PRN', 'AUX', 'NUL',
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// Same rules as safe_name() in the Python reference.
String safeName(String name) {
  var s = name.replaceAll('\\', '/');
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  final slash = s.lastIndexOf('/');
  var base = slash >= 0 ? s.substring(slash + 1) : s;
  base = base.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  base = base.replaceAll(RegExp(r'^[ .]+|[ .]+$'), '');
  if (base.length > 200) base = base.substring(0, 200);
  if (base.isEmpty) base = 'file';
  if (_reserved.contains(base.split('.').first.toUpperCase())) {
    base = '_$base';
  }
  return base;
}

File uniquePath(Directory dir, String name) {
  var stem = name;
  var suffix = '';
  final dot = name.lastIndexOf('.');
  if (dot > 0) {
    stem = name.substring(0, dot);
    suffix = name.substring(dot);
  }
  var p = File('${dir.path}/$name');
  var i = 1;
  while (p.existsSync() || File('${p.path}.part').existsSync()) {
    p = File('${dir.path}/$stem ($i)$suffix');
    i++;
  }
  return p;
}

String fmtSize(int n) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = n.toDouble();
  for (var i = 0; i < units.length; i++) {
    if (v < 1024 || i == units.length - 1) {
      return i == 0 ? '${v.toStringAsFixed(0)} B' : '${v.toStringAsFixed(1)} ${units[i]}';
    }
    v /= 1024;
  }
  return '$n B';
}

class FileServices {
  FileServices({
    this.ask,
    required this.notify,
    required this.destDir,
    this.maxFileBytes = 4 << 30,
  });

  /// null = accept everything.
  final Future<bool> Function(String title, String text)? ask;
  final void Function(String message) notify;
  final Future<Directory> Function() destDir;
  final int maxFileBytes;
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

class _Rx {
  _Rx(this.path, this.part, this.raf, this.size) {
    sink = crypto.sha256.startChunkedConversion(out);
  }
  final File path;
  final File part;
  final RandomAccessFile raf;
  final int size;
  int got = 0;
  final _DigestSink out = _DigestSink();
  late final ByteConversionSink sink;
}

class _Accept {
  _Accept(this.ok, this.reason);
  final bool ok;
  final String reason;
}

class _Tx {
  final Completer<_Accept> accepted = Completer<_Accept>();
  final Completer<void> ack = Completer<void>();
  bool result = false;
  bool aborted = false;
}

class FileTransfer {
  /// [parity]: host uses 0, viewer uses 1, so ids never collide.
  FileTransfer(this.conn, this.svc, this.parity);

  final MessageSink conn;
  final FileServices svc;
  final int parity;
  int _seq = 0;
  final Map<int, _Rx> _rx = {};
  final Map<int, _Tx> _tx = {};
  final Mutex _txLock = Mutex();

  int _newId() {
    _seq++;
    return _seq * 2 + parity;
  }

  // ------------------------------------------------------------ receiving
  Future<void> handle(int t, Uint8List body) async {
    switch (t) {
      case MsgType.fileOffer:
        unawaited(_onOffer(unpackJson(body))); // never block the recv loop
        break;
      case MsgType.fileAccept:
        final m = unpackJson(body);
        final tx = _tx[m['id']];
        if (tx != null && !tx.accepted.isCompleted) {
          tx.accepted.complete(
              _Accept(m['ok'] == true, (m['reason'] ?? '').toString()));
        }
        break;
      case MsgType.fileChunk:
        await _onChunk(body);
        break;
      case MsgType.fileDone:
        await _onDone(unpackJson(body));
        break;
      case MsgType.fileAbort:
        _onAbort(unpackJson(body));
        break;
    }
  }

  Future<void> _reply(int fid, bool ok, [String reason = '']) =>
      conn.send(MsgType.fileAccept,
          packJson({'id': fid, 'ok': ok, 'reason': reason}));

  Future<void> _onOffer(Map<String, dynamic> m) async {
    int fid;
    int size;
    String name;
    try {
      if (!m.containsKey('name')) return;
      fid = (m['id'] as num).toInt();
      size = (m['size'] as num).toInt();
      name = safeName(m['name'].toString());
      if (size < 0 || _rx.containsKey(fid)) return;
    } catch (_) {
      return;
    }
    try {
      var reason = '';
      if (size > svc.maxFileBytes) {
        reason = 'file too large';
      } else if (svc.ask != null) {
        bool ok;
        try {
          ok = await svc.ask!('فایل ورودی', 'دریافت «$name» (${fmtSize(size)})؟')
              .timeout(const Duration(seconds: 60));
        } on TimeoutException {
          ok = false;
        }
        if (!ok) reason = 'declined';
      }
      if (reason.isNotEmpty) {
        await _reply(fid, false, reason);
        return;
      }
      _Rx rx;
      try {
        final dir = await svc.destDir();
        await dir.create(recursive: true);
        final path = uniquePath(dir, name);
        final part = File('${path.path}.part');
        rx = _Rx(path, part, await part.open(mode: FileMode.write), size);
      } on FileSystemException catch (e) {
        await _reply(fid, false, e.message);
        return;
      }
      _rx[fid] = rx;
      await _reply(fid, true);
      svc.notify('در حال دریافت $name (${fmtSize(size)})...');
    } catch (_) {
      // ignore: connection may be gone
    }
  }

  Future<void> _onChunk(Uint8List body) async {
    if (body.length < 4) throw ProtocolError('short chunk');
    final fid = ByteData.sublistView(body).getUint32(0);
    final rx = _rx[fid];
    if (rx == null) return;
    final data = Uint8List.sublistView(body, 4);
    rx.got += data.length;
    if (rx.got > rx.size) {
      _drop(fid);
      await conn.send(MsgType.fileAbort,
          packJson({'id': fid, 'reason': 'too much data'}));
      return;
    }
    await rx.raf.writeFrom(data);
    rx.sink.add(data);
  }

  Future<void> _onDone(Map<String, dynamic> m) async {
    final fid = m['id'];
    if (_rx.containsKey(fid)) {
      final rx = _rx.remove(fid)!;
      rx.sink.close();
      await rx.raf.close();
      final digest = rx.out.value.toString();
      final ok = rx.got == rx.size &&
          constTimeEquals(
              utf8.encode(digest), utf8.encode((m['sha256'] ?? '').toString()));
      if (ok) {
        await rx.part.rename(rx.path.path);
        svc.notify('دریافت شد: ${rx.path.uri.pathSegments.last}');
      } else {
        try {
          await rx.part.delete();
        } catch (_) {}
        svc.notify('${rx.path.uri.pathSegments.last}: بررسی SHA-256 ناموفق بود');
      }
      await conn.send(MsgType.fileDone, packJson({'id': fid, 'ok': ok}));
    } else if (_tx.containsKey(fid)) {
      final tx = _tx[fid]!;
      tx.result = m['ok'] == true;
      if (!tx.ack.isCompleted) tx.ack.complete();
    }
  }

  void _onAbort(Map<String, dynamic> m) {
    final fid = m['id'];
    if (_rx.containsKey(fid)) {
      _drop(fid as int);
      svc.notify('انتقال توسط طرف مقابل لغو شد');
    }
    final tx = _tx[fid];
    if (tx != null) {
      tx.aborted = true;
      if (!tx.accepted.isCompleted) {
        tx.accepted.complete(_Accept(false, (m['reason'] ?? 'aborted').toString()));
      }
      if (!tx.ack.isCompleted) tx.ack.complete();
    }
  }

  void _drop(int fid) {
    final rx = _rx.remove(fid);
    if (rx == null) return;
    try {
      rx.raf.closeSync();
      rx.part.deleteSync();
    } catch (_) {}
  }

  // -------------------------------------------------------------- sending
  Future<bool> sendFile(String path) async {
    final file = File(path);
    final name = path.split(RegExp(r'[\\/]')).last;
    int size;
    RandomAccessFile raf;
    try {
      size = await file.length();
      raf = await file.open();
    } on FileSystemException catch (e) {
      svc.notify('خواندن $name ممکن نیست: ${e.message}');
      return false;
    }
    return _txLock.run<bool>(() async {
      final fid = _newId();
      final tx = _tx[fid] = _Tx();
      try {
        await conn.send(MsgType.fileOffer,
            packJson({'id': fid, 'name': name, 'size': size}));
        svc.notify('منتظر پذیرش $name توسط طرف مقابل...');
        final acc =
            await tx.accepted.future.timeout(const Duration(seconds: 120));
        if (!acc.ok) {
          svc.notify('$name پذیرفته نشد (${acc.reason})');
          return false;
        }
        final out = _DigestSink();
        final sink = crypto.sha256.startChunkedConversion(out);
        var sent = 0;
        var last = DateTime.now();
        while (true) {
          final chunk = await raf.read(fileChunkSize);
          if (chunk.isEmpty) break;
          if (tx.aborted) {
            svc.notify('$name: لغو شد');
            return false;
          }
          sink.add(chunk);
          final body = Uint8List(4 + chunk.length);
          ByteData.view(body.buffer).setUint32(0, fid);
          body.setAll(4, chunk);
          await conn.send(MsgType.fileChunk, body);
          sent += chunk.length;
          if (DateTime.now().difference(last).inSeconds >= 1) {
            svc.notify('ارسال $name: ${sent * 100 ~/ (size == 0 ? 1 : size)}٪');
            last = DateTime.now();
          }
        }
        sink.close();
        await conn.send(MsgType.fileDone,
            packJson({'id': fid, 'sha256': out.value.toString()}));
        await tx.ack.future.timeout(const Duration(seconds: 120));
        svc.notify(tx.result ? '$name ارسال شد' : '$name: انتقال ناموفق بود');
        return tx.result;
      } on TimeoutException {
        svc.notify('$name: زمان انتظار تمام شد');
        return false;
      } on ConnectionClosed {
        svc.notify('$name: ارتباط قطع شد');
        return false;
      } on SocketException {
        svc.notify('$name: ارتباط قطع شد');
        return false;
      } finally {
        await raf.close();
        _tx.remove(fid);
      }
    });
  }

  void close() {
    for (final fid in _rx.keys.toList()) {
      _drop(fid);
    }
    for (final tx in _tx.values) {
      tx.aborted = true;
      if (!tx.accepted.isCompleted) {
        tx.accepted.complete(_Accept(false, 'disconnected'));
      }
      if (!tx.ack.isCompleted) tx.ack.complete();
    }
  }
}
