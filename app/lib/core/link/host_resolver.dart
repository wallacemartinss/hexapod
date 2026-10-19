import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

/// Resolves the robot's host to an IPv4 address.
///
/// Not every Android resolves `*.local` (mDNS) through the system DNS, so for
/// those names this falls back to asking on the LAN directly. Anything else
/// (an IP, a Tailscale name) goes through the system resolver.
Future<String> resolveHost(String host) async {
  if (InternetAddress.tryParse(host) != null) return host;
  try {
    final found = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 2));
    if (found.isNotEmpty) return found.first.address;
  } catch (_) {
    // fall through to mDNS
  }
  if (!host.endsWith('.local')) return host;
  final client = MDnsClient();
  try {
    await client.start();
    await for (final record
        in client
            .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(host))
            .timeout(const Duration(seconds: 3))) {
      return record.address.address;
    }
  } catch (_) {
    // not found: let the connection fail and retry
  } finally {
    client.stop();
  }
  return host;
}
