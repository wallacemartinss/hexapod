import 'dart:io';

/// Whether this phone is on a tailnet now: the Tailscale app is logged in
/// and its VPN is on (an interface holds a 100.64.0.0/10 address).
Future<bool> phoneOnTailnet() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return interfaces.any((i) => i.addresses.any((a) => isTailnetAddress(a.address)));
  } catch (_) {
    return false;
  }
}

/// 100.64.0.0/10, the range Tailscale hands out.
bool isTailnetAddress(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]), b = int.tryParse(parts[1]);
  return a == 100 && b != null && b >= 64 && b <= 127;
}
