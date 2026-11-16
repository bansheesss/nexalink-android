import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotelink/core/bytes.dart';
import 'package:remotelink/core/filetransfer.dart';
import 'package:remotelink/core/network.dart';
import 'package:remotelink/core/protocol.dart';
import 'package:remotelink/core/security.dart';

import 'golden.dart';

class _Rec implements MessageSink {
  final List<(int, Uint8List)> sent = [];
  void Function(int, Uint8List)? hook;
  @override
  Future<void> send(int type, Uint8List body) async {
    sent.add((type, body));
    hook?.call(type, body);
  }
}

List<Map<String, dynamic>> _summarize(List<(int, Uint8List)> sent) => [
      for (final (t, b) in sent)
        if (t == MsgType.fileChunk)
          {
            'type': t,
            'id': ByteData.sublistView(b).getUint32(0),
            'len': b.length - 4,
            'sha256': toHex(sha256Bytes(Uint8List.sublistView(b, 4))),
          }
        else
          {'type': t, 'body': toHex(b)}
    ];

void main() {
  test('safeName matches the Python reference for all vectors', () {
    for (final v in (golden['safe_names'] as List).cast<Map<String, dynamic>>()) {
      expect(safeName(v['in'] as String), v['out'], reason: 'input ${v['in']}');
    }
  });

  test('sender produces the same message sequence as the Python sender', () async {
    final v = golden['filetransfer_sender'] as Map<String, dynamic>;
    final dir = await Directory.systemTemp.createTemp('rl_send');
    addTearDown(() => dir.delete(recursive: true));
    final n = v['size'] as int;
    final file = File('${dir.path}/${v['filename']}');
    await file.writeAsBytes(Uint8List.fromList([for (var i = 0; i < n; i++) (i * 7 + 3) % 256]));
    final rec = _Rec();
    late FileTransfer ft;
    ft = FileTransfer(rec, FileServices(notify: (_) {}, destDir: () async => dir),
        v['id_parity'] as int);
    rec.hook = (t, b) {
      if (t == MsgType.fileOffer) {
        final id = unpackJson(b)['id'];
        scheduleMicrotask(() => ft.handle(MsgType.fileAccept,
            packJson({'id': id, 'ok': true, 'reason': ''})));
      } else if (t == MsgType.fileDone) {
        final id = unpackJson(b)['id'];
        scheduleMicrotask(
            () => ft.handle(MsgType.fileDone, packJson({'id': id, 'ok': true})));
      }
    };
    expect(await ft.sendFile(file.path), isTrue);
    expect(_summarize(rec.sent), equals(v['sent']));
  });

  final scenarios =
      (golden['filetransfer_receiver'] as List).cast<Map<String, dynamic>>();
  for (final s in scenarios) {
    test('receiver "${s['name']}" replies exactly like the Python receiver', () async {
      final dir = await Directory.systemTemp.createTemp('rl_recv');
      addTearDown(() => dir.delete(recursive: true));
      final rec = _Rec();
      final ask = s['ask'] as bool?;
      final ft = FileTransfer(
          rec,
          FileServices(
            ask: ask == null ? null : (t, x) async => ask,
            notify: (_) {},
            destDir: () async => Directory('${dir.path}/in'),
            maxFileBytes: (s['max'] as int?) ?? (4 << 30),
          ),
          1);
      for (final m in (s['incoming'] as List).cast<Map<String, dynamic>>()) {
        await ft.handle(m['type'] as int, fromHex(m['body'] as String));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      expect(_summarize(rec.sent), equals(s['expected_sent']));
      final inDir = Directory('${dir.path}/in');
      final saved = inDir.existsSync()
          ? (inDir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort())
          : <String>[];
      expect(saved, equals(s['saved']));
      if (s['name'] == 'ok') {
        expect(await File('${inDir.path}/evil_.txt').readAsString(), 'hello');
      }
    });
  }
}
