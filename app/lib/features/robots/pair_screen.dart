import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:web_socket_channel/io.dart';

import '../../core/link/discovery.dart';
import '../../core/link/robot_wifi.dart';
import '../../core/robots.dart';

const _bg = Color(0xFF0E1013);
const _ok = Color(0xFF3DDC97);
const _accent = Color(0xFF4FD1FF);

Future<void> showPairScreen(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairScreen()));

/// Checks a found robot accepts the key (the WebSocket opens), so the app
/// never saves a pairing that would not work.
typedef KeyCheck = Future<bool> Function(String address, int port, String token);

Future<bool> _checkKey(String address, int port, String token) async {
  final channel = IOWebSocketChannel.connect(
    Uri(scheme: 'ws', host: address, port: port, path: '/ws'),
    headers: {'Authorization': 'Bearer $token'},
  );
  try {
    await channel.ready.timeout(const Duration(seconds: 3));
    return true;
  } catch (_) {
    return false;
  } finally {
    unawaited(channel.sink.close());
  }
}

/// Finds a robot by id (tests replace it).
typedef RobotFinder = Future<FoundRobot?> Function(String id, String? address);

Future<FoundRobot?> _find(String id, String? address) async {
  if (address != null) {
    final r = await identify(address.trim());
    return r?.id == id ? r : null;
  }
  return findRobot(id);
}

/// "Novo robô": scan the QR on the robot's screen (or type the code), find
/// the robot on the network, check the key, save.
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key, this.finder = _find, this.keyCheck = _checkKey, this.camera, this.wifi});

  final RobotFinder finder;
  final KeyCheck keyCheck;

  /// Joins the robot's own network (default: robotWifiProvider; null on the PC).
  final RobotWifi? wifi;

  /// Show the camera (default: on Android only).
  final bool? camera;

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

enum _Step { scan, searching, joiningOwn, notFound, badKey, done }

class _PairScreenState extends ConsumerState<PairScreen> {
  _Step _step = _Step.scan;
  PairingCode? _code;
  String? _name;
  final _typed = TextEditingController();
  final _address = TextEditingController();
  String? _typedError;

  bool get _camera => widget.camera ?? Platform.isAndroid;

  @override
  void dispose() {
    _typed.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _start(PairingCode code, {String? address}) async {
    if (_step == _Step.searching) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _code = code;
      _step = _Step.searching;
    });
    final wifi = widget.wifi ?? ref.read(robotWifiProvider);
    // The robot may still be booting: keep looking for a little while. With
    // its own network at hand, look less: a new robot is usually there.
    FoundRobot? found;
    final look = wifi != null && address == null ? 6 : 15;
    final deadline = DateTime.now().add(Duration(seconds: look));
    while (found == null && DateTime.now().isBefore(deadline) && mounted) {
      found = await widget.finder(code.id, address);
      if (found == null && address != null) break; // a typed address answers or not
      if (found == null) await Future<void>.delayed(const Duration(seconds: 1)); // no busy loop
    }
    if (!mounted) return;
    if (found == null && wifi != null && address == null) {
      // First boot (or no home network): join "Hexapode-<id>" from here.
      setState(() => _step = _Step.joiningOwn);
      final own = ownNetwork(code.id, code.token);
      if (await wifi.join(own.ssid, own.password)) {
        found = await widget.finder(code.id, ownNetworkAddress);
        if (found == null) await wifi.release();
      }
      if (!mounted) return;
    }
    if (found == null) {
      setState(() => _step = _Step.notFound);
      return;
    }
    if (!await widget.keyCheck(found.address, found.port, code.token)) {
      if (mounted) setState(() => _step = _Step.badKey);
      return;
    }
    await ref
        .read(robotsProvider.notifier)
        .pair(Robot(id: code.id, name: found.name, token: code.token, address: found.address));
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _name = found!.name;
      _step = _Step.done;
    });
  }

  void _submitTyped() {
    final code = parsePairingCode(_typed.text);
    if (code == null) {
      setState(() => _typedError = 'Código inválido: começa com HXP1, depois o ID e a chave');
      return;
    }
    setState(() => _typedError = null);
    _start(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(backgroundColor: _bg, foregroundColor: Colors.white, title: const Text('Novo robô')),
      body: SafeArea(
        top: false,
        child: switch (_step) {
          _Step.scan => _scanView(),
          _Step.searching => _message(
            const SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 3)),
            'Procurando o robô ${_code!.id}…',
            'O celular precisa estar na mesma rede Wi-Fi que o robô.',
          ),
          _Step.joiningOwn => _message(
            const SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 3)),
            'Conectando na rede do robô…',
            'Rede Hexapode-${_code!.id}. Se o Android perguntar, toque em "Conectar".',
          ),
          _Step.notFound => _notFound(),
          _Step.badKey => _message(
            const Icon(Icons.key_off_rounded, size: 48, color: Color(0xFFFF5A5F)),
            'O robô recusou a chave',
            'O QR é de outro robô, ou a chave foi trocada. Escaneie de novo o QR que está na tela do robô.',
            action: ('Escanear de novo', () => setState(() => _step = _Step.scan)),
          ),
          _Step.done => _message(
            const Icon(Icons.check_circle_rounded, size: 56, color: _ok),
            'Pareado!',
            '$_name está pronto para pilotar.',
            action: ('Pilotar', () => Navigator.of(context).pop()),
          ),
        },
      ),
    );
  }

  Widget _scanView() {
    final typed = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Na tela do robô aparece um QR quando nenhum app está conectado.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _typed,
            style: const TextStyle(color: Colors.white, letterSpacing: 1),
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'Ou digite o código',
              hintText: 'HXP1 7F3A ABCD…',
              helperText: 'No modo maker: sudo -u hexapod hexd -pairing',
              errorText: _typedError,
            ),
            onSubmitted: (_) => _submitTyped(),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _submitTyped, child: const Text('Parear')),
        ],
      ),
    );
    if (!_camera) return SingleChildScrollView(child: typed);
    return Row(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                onDetect: (capture) {
                  for (final b in capture.barcodes) {
                    final code = b.rawValue == null ? null : parsePairingCode(b.rawValue!);
                    if (code != null) {
                      _start(code);
                      return;
                    }
                  }
                },
              ),
              Center(
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    border: Border.all(color: _accent, width: 3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: 360, child: SingleChildScrollView(child: typed)),
      ],
    );
  }

  Widget _notFound() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.wifi_find_rounded, size: 48, color: Color(0xFFFFB547)),
          const SizedBox(height: 12),
          Text(
            'Não achei o robô ${_code!.id} na rede',
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text(
            '• O robô está ligado e a tela mostra o QR?\n'
            '• O celular está no mesmo Wi-Fi que o robô?\n'
            '• Algumas redes bloqueiam a busca: informe o endereço (IP) que aparece na tela do robô.',
            style: TextStyle(color: Colors.white70, height: 1.5),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 320,
            child: TextField(
              controller: _address,
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Endereço do robô (opcional)',
                hintText: '10.0.0.86',
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final address = _address.text.trim();
              setState(() => _step = _Step.scan);
              _start(_code!, address: address.isEmpty ? null : address);
            },
            child: const Text('Tentar de novo'),
          ),
        ],
      ),
    );
  }

  Widget _message(Widget icon, String title, String text, {(String, VoidCallback)? action}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            if (action != null) ...[
              const SizedBox(height: 20),
              FilledButton(onPressed: action.$2, child: Text(action.$1)),
            ],
          ],
        ),
      ),
    );
  }
}
