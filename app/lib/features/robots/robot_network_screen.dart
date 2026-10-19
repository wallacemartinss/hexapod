import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/link/discovery.dart';
import '../../core/link/robot_api.dart';
import '../../core/link/robot_wifi.dart';
import '../../core/providers.dart';
import '../../core/robots.dart';
import '../../l10n/l10n.dart';

const _bg = Color(0xFF0C1428);
const _card = Color(0xFF121C34);
const _ok = Color(0xFF3DDC97);
const _warn = Color(0xFFFFB547);
const _bad = Color(0xFFFF5A5F);

Future<void> showRobotNetworkScreen(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RobotNetworkScreen()));

/// The active robot's Wi-Fi and name: home network or its own network
/// (direct), join a network with the password typed here, forget networks.
class RobotNetworkScreen extends ConsumerStatefulWidget {
  const RobotNetworkScreen({super.key});

  @override
  ConsumerState<RobotNetworkScreen> createState() => _RobotNetworkScreenState();
}

class _RobotNetworkScreenState extends ConsumerState<RobotNetworkScreen> {
  WifiStatus? _status;
  String? _error; // the robot's reason; empty: out of reach (worded at build time)
  String? _busy; // what is going on, shown instead of the content
  Timer? _poll;

  Robot? get _robot => ref.read(robotsProvider).active;

  RobotApi? _api() {
    final robot = _robot;
    final address = ref.read(robotAddressProvider).value;
    if (robot == null || address == null) return null;
    return RobotApi(address, robot.token);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _busy == null ? _refresh() : null);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final api = _api();
    if (api == null) {
      setState(() => _error = '');
      return;
    }
    try {
      final s = await api.wifi();
      if (mounted) {
        setState(() {
          _status = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is RobotApiError ? e.message : '');
    }
  }

  Future<void> _run(String what, Future<void> Function(RobotApi api) action) async {
    final api = _api();
    if (api == null) return;
    try {
      await action(api);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.networkActionFailed(what, '$e'))));
      }
    }
    await _refresh();
  }

  Future<void> _rename() async {
    final robot = _robot;
    if (robot == null) return;
    final controller = TextEditingController(text: robot.name);
    final l = context.l10n;
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.networkRobotName),
        content: TextField(controller: controller, autofocus: true, maxLength: 32),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(l.networkCancel)),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: Text(l.networkSave)),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == robot.name) return;
    await _run(l.networkRename, (api) async {
      await api.rename(name);
      await ref.read(robotsProvider.notifier).rename(robot.id, name);
    });
  }

  /// Network list from the robot, then the password, then the move.
  Future<void> _chooseNetwork() async {
    final api = _api();
    if (api == null) return;
    final l = context.l10n;
    setState(() => _busy = l.networkScanning);
    List<WifiNetwork> list;
    try {
      list = await api.scan();
    } catch (e) {
      setState(() => _busy = null);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted) return;
    setState(() => _busy = null);
    final picked = await showModalBottomSheet<WifiNetwork>(
      context: context,
      backgroundColor: const Color(0xFF15181D),
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(l.networkVisible, style: const TextStyle(color: Colors.white)),
              subtitle: Text(l.networkOnly24, style: const TextStyle(color: Colors.white54)),
            ),
            if (list.isEmpty)
              ListTile(
                title: Text(l.networkNoneFound, style: const TextStyle(color: Colors.white70)),
              ),
            for (final n in list)
              ListTile(
                leading: Icon(_signalIcon(n.signal), color: Colors.white70),
                title: Text(n.ssid, style: const TextStyle(color: Colors.white)),
                trailing: n.secure ? const Icon(Icons.lock_rounded, size: 16, color: Colors.white38) : null,
                onTap: () => Navigator.pop(c, n),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    String password = '';
    if (picked.secure) {
      final typed = await _askPassword(picked.ssid);
      if (typed == null) return;
      password = typed;
    }
    await _join(api, picked.ssid, password);
  }

  Future<String?> _askPassword(String ssid) {
    final controller = TextEditingController();
    var hidden = true;
    final l = context.l10n;
    return showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(l.networkPassword(ssid)),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: hidden,
            decoration: InputDecoration(
              helperText: l.networkPasswordHelp,
              suffixIcon: IconButton(
                icon: Icon(hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                onPressed: () => setLocal(() => hidden = !hidden),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(l.networkCancel)),
            FilledButton(
              onPressed: () {
                final p = controller.text;
                if (p.length < 8 || p.length > 63) return; // WPA: 8-63 characters
                Navigator.pop(c, p);
              },
              child: Text(l.networkConnect),
            ),
          ],
        ),
      ),
    );
  }

  /// The robot leaves its own network for [ssid]: find it there, or read
  /// why it came back.
  Future<void> _join(RobotApi api, String ssid, String password) async {
    final robot = _robot!;
    final wifi = ref.read(robotWifiProvider);
    final l = context.l10n;
    try {
      await api.join(ssid, password);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    setState(() => _busy = l.networkJoining(ssid));
    await wifi?.release(); // leave the robot's network; the phone goes back home
    final deadline = DateTime.now().add(const Duration(seconds: 75));
    FoundRobot? found;
    while (found == null && DateTime.now().isBefore(deadline) && mounted) {
      await Future<void>.delayed(const Duration(seconds: 3));
      found = await findRobot(robot.id);
    }
    if (!mounted) return;
    if (found != null) {
      await ref.read(robotsProvider.notifier).seenAt(robot.id, found.address);
      ref.invalidate(robotAddressProvider);
      setState(() => _busy = null);
      _snack(l.networkJoined(robot.name, ssid), _ok);
      await _refresh();
      return;
    }
    // Not at home: it went back to its own network. Read why from there.
    setState(() => _busy = l.networkNotThere(ssid));
    final own = ownNetwork(robot.id, robot.token);
    String reason = l.networkDidNotJoin(ssid);
    if (wifi != null && await wifi.join(own.ssid, own.password)) {
      ref.invalidate(robotAddressProvider);
      try {
        final s = await RobotApi(ownNetworkAddress, robot.token).wifi();
        if (s.error != null) reason = s.error!;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _busy = null);
    _snack(reason, _bad);
    await _refresh();
  }

  void _snack(String text, Color color) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(text), backgroundColor: color.withValues(alpha: 0.9)));

  @override
  Widget build(BuildContext context) {
    final robot = ref.watch(robotsProvider).active;
    final s = _status;
    final l = context.l10n;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        title: Text(robot == null ? l.networkTitle : robot.name),
        actions: [
          if (robot != null)
            IconButton(tooltip: l.networkRename, icon: const Icon(Icons.edit_rounded), onPressed: _rename),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _busy != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        _busy!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _stateCard(s),
                  const SizedBox(height: 12),
                  if (s != null) ...[_modeCard(s), const SizedBox(height: 12), _savedCard(s)],
                ],
              ),
      ),
    );
  }

  Widget _box({required Widget child}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white10),
    ),
    child: child,
  );

  Widget _stateCard(WifiStatus? s) {
    final l = context.l10n;
    final (IconData icon, Color color, String title, String text) = switch (s?.state) {
      _ when _error != null => (
        Icons.wifi_off_rounded,
        _bad,
        l.networkNoContact,
        _error!.isEmpty ? l.networkOutOfReach : _error!,
      ),
      null => (Icons.wifi_find_rounded, Colors.white54, l.networkReading, ''),
      'own' => (Icons.wifi_tethering_rounded, _ok, l.networkOwn, l.networkOwnDetail(s!.apSsid)),
      'home' => (Icons.wifi_rounded, _ok, l.networkHome(s!.ssid ?? ''), 'IP ${s.ip ?? '—'}'),
      'connecting' => (Icons.wifi_find_rounded, _warn, l.networkConnecting, s!.ssid ?? ''),
      _ => (Icons.portable_wifi_off_rounded, _bad, l.networkUnavailable, l.networkUnavailableDetail),
    };
    return _box(
      child: Row(
        children: [
          Icon(icon, size: 36, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                ),
                if (text.isNotEmpty) Text(text, style: const TextStyle(color: Colors.white60, fontSize: 13)),
                if (s?.error != null) ...[
                  const SizedBox(height: 6),
                  Text(l.networkLastError(s!.error!), style: const TextStyle(color: _bad, fontSize: 13)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeCard(WifiStatus s) {
    final l = context.l10n;
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.networkHowTitle,
            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: 'home',
                icon: const Icon(Icons.home_rounded),
                label: Text(l.networkModeHome),
              ),
              ButtonSegment(
                value: 'direct',
                icon: const Icon(Icons.wifi_tethering_rounded),
                label: Text(l.networkModeDirect),
              ),
            ],
            selected: {s.mode},
            onSelectionChanged: (v) => _run(l.networkMode, (api) => api.setMode(v.first)),
          ),
          const SizedBox(height: 8),
          Text(
            s.mode == 'direct' ? l.networkDirectHelp(s.apSsid) : l.networkHomeHelp(s.apSsid),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          if (s.mode == 'home') ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _chooseNetwork,
              icon: const Icon(Icons.wifi_rounded),
              label: Text(l.networkJoinButton),
            ),
          ],
        ],
      ),
    );
  }

  Widget _savedCard(WifiStatus s) {
    final l = context.l10n;
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.networkSaved,
            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
          ),
          if (s.saved.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(l.networkSavedNone, style: const TextStyle(color: Colors.white54)),
            ),
          for (final ssid in s.saved)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.wifi_rounded, color: Colors.white54),
              title: Text(ssid, style: const TextStyle(color: Colors.white)),
              trailing: IconButton(
                tooltip: l.networkForget,
                icon: const Icon(Icons.delete_outline_rounded, color: Colors.white54),
                onPressed: () => _run(l.networkForget, (api) => api.forget(ssid)),
              ),
            ),
        ],
      ),
    );
  }
}

IconData _signalIcon(int signal) => signal >= 70
    ? Icons.network_wifi_rounded
    : signal >= 40
    ? Icons.network_wifi_3_bar_rounded
    : Icons.network_wifi_1_bar_rounded;
