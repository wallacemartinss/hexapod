import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/link/discovery.dart';
import '../../core/link/robot_api.dart';
import '../../core/link/robot_wifi.dart';
import '../../core/providers.dart';
import '../../core/robots.dart';

const _bg = Color(0xFF0E1013);
const _card = Color(0xFF171A1F);
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
  String? _error;
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
      setState(() => _error = 'Robô fora de alcance');
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
      if (mounted) setState(() => _error = e is RobotApiError ? e.message : 'Robô fora de alcance');
    }
  }

  Future<void> _run(String what, Future<void> Function(RobotApi api) action) async {
    final api = _api();
    if (api == null) return;
    try {
      await action(api);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what: $e')));
      }
    }
    await _refresh();
  }

  Future<void> _rename() async {
    final robot = _robot;
    if (robot == null) return;
    final controller = TextEditingController(text: robot.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nome do robô'),
        content: TextField(controller: controller, autofocus: true, maxLength: 32),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == robot.name) return;
    await _run('Renomear', (api) async {
      await api.rename(name);
      await ref.read(robotsProvider.notifier).rename(robot.id, name);
    });
  }

  /// Network list from the robot, then the password, then the move.
  Future<void> _chooseNetwork() async {
    final api = _api();
    if (api == null) return;
    setState(() => _busy = 'O robô está procurando redes…');
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
            const ListTile(
              title: Text('Redes que o robô enxerga', style: TextStyle(color: Colors.white)),
              subtitle: Text(
                'Só redes de 2,4 GHz aparecem (o Wi-Fi do Pi 3)',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            if (list.isEmpty)
              const ListTile(
                title: Text('Nenhuma rede encontrada', style: TextStyle(color: Colors.white70)),
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
    return showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text('Senha de "$ssid"'),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: hidden,
            decoration: InputDecoration(
              helperText: 'Fica gravada só no robô',
              suffixIcon: IconButton(
                icon: Icon(hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                onPressed: () => setLocal(() => hidden = !hidden),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                final p = controller.text;
                if (p.length < 8 || p.length > 63) return; // WPA: 8-63 characters
                Navigator.pop(c, p);
              },
              child: const Text('Conectar'),
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
    try {
      await api.join(ssid, password);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    setState(
      () => _busy = 'O robô está entrando na rede "$ssid".\nSeu celular deve voltar para ela sozinho.',
    );
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
      _snack('Pronto! ${robot.name} está na rede "$ssid".', _ok);
      await _refresh();
      return;
    }
    // Not at home: it went back to its own network. Read why from there.
    setState(() => _busy = 'Não achei o robô na rede "$ssid". Voltando para a rede dele…');
    final own = ownNetwork(robot.id, robot.token);
    String reason = 'O robô não entrou na rede "$ssid".';
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
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        title: Text(robot == null ? 'Rede do robô' : robot.name),
        actions: [
          if (robot != null)
            IconButton(tooltip: 'Renomear', icon: const Icon(Icons.edit_rounded), onPressed: _rename),
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
    final (IconData icon, Color color, String title, String text) = switch (s?.state) {
      _ when _error != null => (Icons.wifi_off_rounded, _bad, 'Sem contato', _error!),
      null => (Icons.wifi_find_rounded, Colors.white54, 'Lendo…', ''),
      'own' => (
        Icons.wifi_tethering_rounded,
        _ok,
        'Rede própria',
        '${s!.apSsid} · o celular fala direto com o robô',
      ),
      'home' => (Icons.wifi_rounded, _ok, 'Rede "${s!.ssid}"', 'IP ${s.ip ?? '—'}'),
      'connecting' => (Icons.wifi_find_rounded, _warn, 'Conectando…', s!.ssid ?? ''),
      _ => (
        Icons.portable_wifi_off_rounded,
        _bad,
        'Wi-Fi do robô indisponível',
        'O chip de Wi-Fi do Pi não respondeu. Confira a fonte de energia do robô.',
      ),
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
                  Text('Última tentativa: ${s!.error}', style: const TextStyle(color: _bad, fontSize: 13)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeCard(WifiStatus s) {
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Como o robô usa o Wi-Fi',
            style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'home', icon: Icon(Icons.home_rounded), label: Text('Rede de casa')),
              ButtonSegment(value: 'direct', icon: Icon(Icons.wifi_tethering_rounded), label: Text('Direto')),
            ],
            selected: {s.mode},
            onSelectionChanged: (v) => _run('Modo', (api) => api.setMode(v.first)),
          ),
          const SizedBox(height: 8),
          Text(
            s.mode == 'direct'
                ? 'O robô cria a rede ${s.apSsid} e o celular conecta nela. Funciona em qualquer lugar, sem roteador.'
                : 'O robô entra na sua rede. Se nenhuma funcionar, ele abre a rede ${s.apSsid} sozinho.',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          if (s.mode == 'home') ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _chooseNetwork,
              icon: const Icon(Icons.wifi_rounded),
              label: const Text('Conectar a uma rede'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _savedCard(WifiStatus s) {
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Redes salvas no robô',
            style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
          ),
          if (s.saved.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Nenhuma', style: TextStyle(color: Colors.white54)),
            ),
          for (final ssid in s.saved)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.wifi_rounded, color: Colors.white54),
              title: Text(ssid, style: const TextStyle(color: Colors.white)),
              trailing: IconButton(
                tooltip: 'Esquecer',
                icon: const Icon(Icons.delete_outline_rounded, color: Colors.white54),
                onPressed: () => _run('Esquecer', (api) => api.forget(ssid)),
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
