// LAN discovery by 9-digit ID over UDP broadcast (core/discovery.py).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int discoveryPort = 7071;
const String discoveryMagic = 'RLK1';

class HostInfo {
  HostInfo(this.id, this.name, this.port, this.host);
  final String id;
  final String name;
  final int port;
  final String host;
}

Uint8List discoveryQuery([String? machineId]) => Uint8List.fromList(
    ascii.encode('$discoveryMagic?${machineId ?? '*'}'));

/// Parses a reply datagram; returns null if it is not a valid reply.
HostInfo? parseDiscoveryReply(Uint8List data, String fromAddress) {
  const prefix = '$discoveryMagic!';
  try {
    final s = utf8.decode(data);
    if (!s.startsWith(prefix)) return null;
    final o = jsonDecode(s.substring(prefix.length));
    if (o is! Map<String, dynamic>) return null;
    return HostInfo('${o['id']}', '${o['name'] ?? ''}',
        (o['port'] as num).toInt(), fromAddress);
  } catch (_) {
    return null;
  }
}

Future<List<String>> _broadcastTargets() async {
  final targets = <String>['255.255.255.255'];
  try {
    for (final ni in await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false)) {
      for (final a in ni.addresses) {
        final p = a.address.split('.');
        if (p.length == 4) {
          final b = '${p[0]}.${p[1]}.${p[2]}.255'; // assumes /24
          if (!targets.contains(b)) targets.add(b);
        }
      }
    }
  } catch (_) {}
  return targets;
}

/// Broadcasts a query and collects answers. With [machineId], stops at the
/// first matching host.
Future<List<HostInfo>> discover({
  String? machineId,
  Duration timeout = const Duration(milliseconds: 1500),
  int port = discoveryPort,
  List<String>? targets,
}) async {
  final query = discoveryQuery(machineId);
  final tg = targets ?? await _broadcastTargets();
  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  sock.broadcastEnabled = true;
  final found = <String, HostInfo>{};
  final done = Completer<void>();

  void sendAll() {
    for (final t in tg) {
      try {
        sock.send(query, InternetAddress(t), port);
      } catch (_) {}
    }
  }

  final sub = sock.listen((ev) {
    if (ev != RawSocketEvent.read) return;
    final d = sock.receive();
    if (d == null) return;
    final info = parseDiscoveryReply(d.data, d.address.address);
    if (info == null) return;
    found[info.id] = info;
    if (machineId != null && !done.isCompleted) done.complete();
  });

  sendAll();
  final resend = Timer(timeout ~/ 2, sendAll); // UDP can drop
  await Future.any([done.future, Future<void>.delayed(timeout)]);
  resend.cancel();
  await sub.cancel();
  sock.close();
  return found.values.toList();
}
