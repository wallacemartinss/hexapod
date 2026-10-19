import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:web_socket_channel/io.dart';

import '../../core/link/discovery.dart';
import '../../core/link/robot_wifi.dart';
import '../../core/robots.dart';
import '../../l10n/l10n.dart';

const _bg = Color(0xFF0C1428);
const _ok = Color(0xFF3DDC97);
const _accent = Color(0xFF3FCDF5);
const _bad = Color(0xFFFF5A5F);

Future<void> showPairScreen(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairScreen()));

/// Robots that may be the one being paired (tests replace it): the one at
/// [address], or robot [id] on the network, or every robot found.
typedef RobotSearch = Future<List<FoundRobot>> Function(String? id, String? address);

Future<List<FoundRobot>> _search(String? id, String? address) async {
  if (address != null) {
    final r = await identify(address.trim());
    return [if (r != null && (id == null || r.id == id)) r];
  }
  if (id != null) {
    final r = await findRobot(id);
    return [?r];
  }
  return discoverRobots();
}

/// Trades the short code for the key (POST /pair); null when refused.
typedef CodeTrade = Future<String?> Function(String address, int port, String code);

Future<String?> _trade(String address, int port, String code) async {
  try {
    final r = await http
        .post(
          Uri(scheme: 'http', host: address, port: port, path: '/pair'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'code': code}),
        )
        .timeout(const Duration(seconds: 5));
    if (r.statusCode != 200) return null;
    return (jsonDecode(r.body) as Map)['token'] as String?;
  } catch (_) {
    return null;
  }
}

/// Checks a key opens the WebSocket (maker path, key typed directly).
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

/// The "New robot" screen: scan the QR on the robot's screen or type the 5-character
/// code shown next to it; the app finds the robot (on this network, or on
/// the robot's own Wi-Fi), trades the code for the key and saves it.
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({
    super.key,
    this.search = _search,
    this.trade = _trade,
    this.keyCheck = _checkKey,
    this.camera,
    this.wifi,
    this.scanner,
  });

  final RobotSearch search;
  final CodeTrade trade;
  final KeyCheck keyCheck;

  /// Show the camera (default: on Android only).
  final bool? camera;

  /// Joins the robot's own network (default: robotWifiProvider; null on the PC).
  final RobotWifi? wifi;

  /// Stands in for the camera view (screenshots; default: the real scanner).
  final Widget? scanner;

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

enum _Step { scan, searching, joiningOwn, notFound, refused, done }

class _PairScreenState extends ConsumerState<PairScreen> {
  _Step _step = _Step.scan;
  PairingInput? _input;
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

  Future<void> _start(PairingInput input, {String? address}) async {
    if (_step == _Step.searching || _step == _Step.joiningOwn) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _input = input;
      _step = _Step.searching;
    });
    final wifi = widget.wifi ?? ref.read(robotWifiProvider);
    // The robot may still be booting: keep looking for a little while. With
    // its own network at hand, look less: a new robot is usually there.
    var robots = <FoundRobot>[];
    final look = wifi != null && address == null ? 6 : 15;
    final deadline = DateTime.now().add(Duration(seconds: look));
    while (robots.isEmpty && DateTime.now().isBefore(deadline) && mounted) {
      robots = await widget.search(input.id, address);
      if (robots.isEmpty && address != null) break; // a typed address answers or not
      if (robots.isEmpty) await Future<void>.delayed(const Duration(seconds: 1)); // no busy loop
    }
    if (!mounted) return;
    if (robots.isEmpty && wifi != null && address == null) {
      // First boot (or no home network): the robot's own Wi-Fi, open until
      // its first pairing. Without the id, Android lists "Hexapode-..." to pick.
      setState(() => _step = _Step.joiningOwn);
      final id = input.id;
      final joined = id == null
          ? await wifi.joinPrefix('Hexapode-')
          : await wifi.join('Hexapode-$id', input.token == null ? '' : ownNetwork(id, input.token!).password);
      if (joined) {
        robots = await widget.search(input.id, ownNetworkAddress);
        if (robots.isEmpty) await wifi.release();
      }
      if (!mounted) return;
    }
    if (robots.isEmpty) {
      setState(() => _step = _Step.notFound);
      return;
    }
    for (final r in robots) {
      final token = input.token != null
          ? (await widget.keyCheck(r.address, r.port, input.token!) ? input.token : null)
          : await widget.trade(r.address, r.port, input.code!);
      if (token == null) continue;
      await ref
          .read(robotsProvider.notifier)
          .pair(Robot(id: r.id, name: r.name, token: token, address: r.address));
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _name = r.name;
        _step = _Step.done;
      });
      return;
    }
    if (mounted) setState(() => _step = _Step.refused);
  }

  void _submitTyped() {
    final input = parsePairingInput(_typed.text);
    if (input == null) {
      setState(() => _typedError = context.l10n.pairCodeError);
      return;
    }
    setState(() => _typedError = null);
    _start(input);
  }

  @override
  Widget build(BuildContext context) {
    final id = _input?.id;
    final l = context.l10n;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(backgroundColor: _bg, foregroundColor: Colors.white, title: Text(l.pairTitle)),
      body: SafeArea(
        top: false,
        child: switch (_step) {
          _Step.scan => _scanView(),
          _Step.searching => _message(
            const SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 3)),
            id == null ? l.pairSearching : l.pairSearchingId(id),
            l.pairSameWifi,
          ),
          _Step.joiningOwn => _message(
            const SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 3)),
            l.pairJoiningOwn,
            id == null ? l.pairPickNetwork : l.pairJoinNetwork(id),
          ),
          _Step.notFound => _notFound(),
          _Step.refused => _message(
            const Icon(Icons.key_off_rounded, size: 48, color: _bad),
            _input?.token != null ? l.pairKeyRefused : l.pairCodeWrong,
            l.pairCodeHelp,
            action: (l.pairRetry, () => setState(() => _step = _Step.scan)),
          ),
          _Step.done => _message(
            const Icon(Icons.check_circle_rounded, size: 56, color: _ok),
            l.pairDone,
            l.pairReady(_name ?? ''),
            action: (l.pairDrive, () => Navigator.of(context).pop()),
          ),
        },
      ),
    );
  }

  Widget _scanView() {
    final l = context.l10n;
    final typed = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.pairIntro, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          TextField(
            controller: _typed,
            style: const TextStyle(color: Colors.white, fontSize: 22, letterSpacing: 6),
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: l.pairCodeLabel,
              hintText: 'K7F2Q',
              errorText: _typedError,
            ),
            onSubmitted: (_) => _submitTyped(),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _submitTyped, child: Text(l.pairButton)),
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
              widget.scanner ??
                  MobileScanner(
                    onDetect: (capture) {
                      for (final b in capture.barcodes) {
                        final input = b.rawValue == null ? null : parsePairingInput(b.rawValue!);
                        if (input != null) {
                          _start(input);
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
    final id = _input?.id;
    final l = context.l10n;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.wifi_find_rounded, size: 48, color: Color(0xFFFFB547)),
          const SizedBox(height: 12),
          Text(
            id == null ? l.pairNotFound : l.pairNotFoundId(id),
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(l.pairNotFoundTips, style: const TextStyle(color: Colors.white70, height: 1.5)),
          const SizedBox(height: 16),
          SizedBox(
            width: 320,
            child: TextField(
              controller: _address,
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: l.pairAddressLabel, hintText: '10.0.0.86'),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final address = _address.text.trim();
              setState(() => _step = _Step.scan);
              _start(_input!, address: address.isEmpty ? null : address);
            },
            child: Text(l.pairRetry),
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
