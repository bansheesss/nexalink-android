import 'package:flutter_test/flutter_test.dart';
import 'package:viunalink/core/bytes.dart';
import 'package:viunalink/core/discovery.dart';

import 'golden.dart';

void main() {
  final d = golden['discovery'] as Map<String, dynamic>;

  test('query packets match the Python viewer', () {
    expect(discoveryPort, d['port']);
    expect(discoveryMagic, d['magic']);
    expect(toHex(discoveryQuery('987654321')), d['query_for_id']);
    expect(toHex(discoveryQuery()), d['query_any']);
  });

  test('replies produced by the Python responder are parsed', () {
    for (final c in (d['responder_cases'] as List).cast<Map<String, dynamic>>()) {
      final reply = c['reply'] as String?;
      if (reply == null) continue; // the host stays silent for these queries
      final info = parseDiscoveryReply(fromHex(reply), '10.0.0.5');
      expect(info, isNotNull);
      expect(info!.id, '987654321');
      expect(info.name, 'box');
      expect(info.port, 7070);
      expect(info.host, '10.0.0.5');
    }
  });

  test('junk datagrams are ignored', () {
    expect(parseDiscoveryReply(fromHex(toHex('RLK1?x'.codeUnits)), '1.1.1.1'), isNull);
    expect(parseDiscoveryReply(fromHex(toHex('hello'.codeUnits)), '1.1.1.1'), isNull);
  });
}
