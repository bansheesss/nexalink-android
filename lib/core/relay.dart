// Viewer-side client for the NexaLink/RemoteLink relay control protocol.
// The relay only pairs sockets; the normal end-to-end encrypted handshake
// still runs over the returned Connection.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'errors.dart';
import 'network.dart';

class RelaySettings {
  const RelaySettings({
    required this.server,
    this.port = 7072,
    this.token = '',
    this.tls = false,
  });

  final String server;
  final int port;
  final String token;
  final bool tls;

  bool get enabled => server.trim().isNotEmpty;
}

class RelayConnectionException implements Exception {
  RelayConnectionException(this.code);
  final String code;

  @override
  String toString() => 'Relay: $code';
}

Future<Connection> connectViaRelay(
  RelaySettings settings,
  String targetId, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (!RegExp(r'^\d{9}$').hasMatch(targetId)) {
    throw RelayConnectionException('شناسه باید ۹ رقم باشد');
  }
  final server = settings.server.trim();
  if (server.isEmpty || settings.port < 1 || settings.port > 65535) {
    throw RelayConnectionException('تنظیمات سرور ریلی معتبر نیست');
  }

  Socket? socket;
  Connection? connection;
  try {
    socket = settings.tls
        ? await SecureSocket.connect(server, settings.port, timeout: timeout)
        : await Socket.connect(server, settings.port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    connection = Connection.fromSocket(socket);

    await connection.writePlain(Uint8List.fromList(utf8.encode(jsonEncode({
      't': 'connect',
      'v': 1,
      'id': targetId,
      'token': settings.token,
    }))));

    final raw = await connection.readPlain().timeout(timeout);
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map<String, dynamic>) {
      throw RelayConnectionException('پاسخ نامعتبر از سرور ریلی');
    }
    if (decoded['t'] != 'ready') {
      throw RelayConnectionException(
          (decoded['code'] ?? 'اتصال از طریق ریلی ناموفق بود').toString());
    }
    return connection;
  } catch (e) {
    if (connection != null) {
      await connection.close();
    } else {
      socket?.destroy();
    }
    if (e is RelayConnectionException) rethrow;
    rethrow;
  }
}
