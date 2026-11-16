import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:remotelink/core/bytes.dart';

/// Vectors produced by tool/gen_golden.py from the Python reference.
final Map<String, dynamic> golden =
    jsonDecode(File('test/vectors/golden.json').readAsStringSync())
        as Map<String, dynamic>;

/// Wire bytes of a plaintext handshake frame -> its JSON payload.
Map<String, dynamic> plainFrameJson(String frameHex) {
  final b = fromHex(frameHex);
  return jsonDecode(utf8.decode(Uint8List.sublistView(b, 4)))
      as Map<String, dynamic>;
}

/// Collects everything the code under test writes.
class CaptureSink implements StreamSink<List<int>> {
  final List<Uint8List> writes = [];
  final Completer<void> _done = Completer<void>();

  @override
  void add(List<int> data) => writes.add(Uint8List.fromList(data));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);
  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
