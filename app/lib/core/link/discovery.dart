import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

/// A robot answering on the network.
typedef FoundRobot = ({String id, String name, String address, int port});

/// Asks a host which robot it is (GET /identity; never returns the key).
Future<FoundRobot?> identify(String address, {int port = 8080}) async {
  try {
    final r = await http
        .get(Uri(scheme: 'http', host: address, port: port, path: '/identity'))
        .timeout(const Duration(seconds: 2));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, Object?>;
    final id = j['id'] as String?;
    if (id == null) return null; // a hexd without pairing
    return (id: id, name: (j['name'] as String?) ?? id, address: address, port: port);
  } catch (_) {
    return null;
  }
}

/// Robots announcing `_hexapod._tcp` on the local network (DNS-SD), each
/// confirmed through /identity.
Future<List<FoundRobot>> discoverRobots({Duration listen = const Duration(seconds: 3)}) async {
  const service = '_hexapod._tcp.local';
  final targets = <({String host, int port})>{};
  final client = MDnsClient();
  try {
    await client.start();
    await for (final ptr
        in client
            .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(service))
            .timeout(listen, onTimeout: (s) => s.close())) {
      await for (final srv
          in client
              .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
              .timeout(const Duration(seconds: 2), onTimeout: (s) => s.close())) {
        await for (final a
            in client
                .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target))
                .timeout(const Duration(seconds: 2), onTimeout: (s) => s.close())) {
          targets.add((host: a.address.address, port: srv.port));
        }
      }
    }
  } catch (_) {
    // no multicast on this network: callers fall back to known addresses
  } finally {
    client.stop();
  }
  final found = await Future.wait([for (final t in targets) identify(t.host, port: t.port)]);
  return [for (final f in found) ?f];
}

/// Where robot [id] answers now: its last known address first, then the
/// network; null if not found.
Future<FoundRobot?> findRobot(String id, {String? lastAddress, int port = 8080}) async {
  if (lastAddress != null) {
    final there = await identify(lastAddress, port: port);
    if (there?.id == id) return there;
  }
  for (final r in await discoverRobots()) {
    if (r.id == id) return r;
  }
  return null;
}

/// True when [host] is a literal address (no lookup needed).
bool isAddress(String host) => InternetAddress.tryParse(host) != null;
