import 'dart:async';
import 'dart:typed_data';

String toHex(List<int> b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List fromHex(String s) {
  if (s.length.isOdd) throw const FormatException('odd-length hex');
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

Uint8List concat(List<List<int>> parts) {
  var n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final out = Uint8List(n);
  var o = 0;
  for (final p in parts) {
    out.setAll(o, p);
    o += p.length;
  }
  return out;
}

bool constTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

/// Runs async functions one at a time, in call order.
class Mutex {
  Future<void> _last = Future<void>.value();

  Future<T> run<T>(Future<T> Function() fn) {
    final prev = _last;
    final gate = Completer<void>();
    _last = gate.future;
    return prev.then((_) => fn()).whenComplete(gate.complete);
  }
}
