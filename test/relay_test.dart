import 'package:flutter_test/flutter_test.dart';
import 'package:viunalink/core/relay.dart';

void main() {
  test('relay viewer rejects non-nine-digit IDs before connecting', () async {
    const settings = RelaySettings(server: 'relay.example.test');
    await expectLater(
      connectViaRelay(settings, '12345'),
      throwsA(isA<RelayConnectionException>()),
    );
  });

  test('relay settings are disabled when no server is configured', () {
    const settings = RelaySettings(server: '  ');
    expect(settings.enabled, isFalse);
  });
}
