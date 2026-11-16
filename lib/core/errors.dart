class ProtocolError implements Exception {
  ProtocolError(this.message);
  final String message;
  @override
  String toString() => 'ProtocolError: $message';
}

class AuthError implements Exception {
  AuthError(this.message);
  final String message;
  @override
  String toString() => 'AuthError: $message';
}

class ConnectionClosed implements Exception {
  ConnectionClosed([this.message = 'connection closed']);
  final String message;
  @override
  String toString() => 'ConnectionClosed: $message';
}
