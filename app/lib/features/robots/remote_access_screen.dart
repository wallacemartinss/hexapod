import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/link/robot_api.dart';
import '../../core/link/tailnet.dart';
import '../../core/providers.dart';
import '../../core/robots.dart';
import '../../l10n/l10n.dart';

const _bg = Color(0xFF0C1428);
const _card = Color(0xFF121C34);
const _ok = Color(0xFF3DDC97);
const _warn = Color(0xFFFFB547);

/// The Tailscale app on Google Play.
final tailscaleStoreUri = Uri.parse('https://play.google.com/store/apps/details?id=com.tailscale.ipn');

Future<void> showRemoteAccessScreen(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemoteAccessScreen()));

Future<bool> _openExternal(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

/// Remote access (Tailscale) without a terminal: the robot logs in through
/// a link opened in the phone's browser, the phone joins with the Tailscale
/// app, and from then on the app reaches the robot from anywhere.
class RemoteAccessScreen extends ConsumerStatefulWidget {
  const RemoteAccessScreen({super.key, this.api, this.onTailnet = phoneOnTailnet, this.open = _openExternal});

  /// The robot's setup API (tests replace it; default: the active robot).
  final RobotApi? Function()? api;
  final Future<bool> Function() onTailnet;
  final Future<bool> Function(Uri) open;

  @override
  ConsumerState<RemoteAccessScreen> createState() => _RemoteAccessScreenState();
}

class _RemoteAccessScreenState extends ConsumerState<RemoteAccessScreen> {
  TailscaleStatus? _status;
  bool _unreachable = false;
  bool _phoneIn = false;
  bool _busy = false;
  String? _link; // login link handed by the robot, while waiting
  Timer? _poll;

  Robot? get _robot => ref.read(robotsProvider).active;

  RobotApi? _api() {
    if (widget.api != null) return widget.api!();
    final robot = _robot;
    final address = ref.read(robotAddressProvider).value;
    if (robot == null || address == null) return null;
    return RobotApi(address, robot.token);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _busy ? null : _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final phoneIn = await widget.onTailnet();
    final api = _api();
    TailscaleStatus? status;
    var unreachable = api == null;
    if (api != null) {
      try {
        status = await api.tailscale();
      } catch (_) {
        unreachable = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _phoneIn = phoneIn;
      _unreachable = unreachable;
      if (status != null) _status = status;
      if (status?.running ?? false) _link = null;
    });
    final robot = _robot;
    if (robot != null && status != null && status.running && status.ip != null) {
      await ref.read(robotsProvider.notifier).setRemote(robot.id, status.ip);
    }
  }

  Future<void> _connect() async {
    final api = _api();
    if (api == null) return;
    setState(() => _busy = true);
    try {
      final s = await api.tailscaleLogin();
      if (!mounted) return;
      setState(() {
        _status = s;
        _link = s.authUrl;
      });
      if (s.authUrl != null) await widget.open(Uri.parse(s.authUrl!));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is RobotApiError ? e.describe(context.l10n) : context.l10n.remoteFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final l = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.remoteDisconnectTitle),
        content: Text(l.remoteDisconnectBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.remoteCancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.remoteDisconnect)),
        ],
      ),
    );
    if (ok != true) return;
    final api = _api();
    final robot = _robot;
    if (api == null || robot == null) return;
    setState(() => _busy = true);
    try {
      await api.tailscaleLogout();
      await ref.read(robotsProvider.notifier).setRemote(robot.id, null);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.remoteFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final s = _status;
    final robotReady = s?.running ?? false;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(backgroundColor: _bg, foregroundColor: Colors.white, title: Text(l.remoteTitle)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l.remoteIntro, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            _Step(number: 1, done: robotReady, title: l.remoteRobotStep, child: _robotStep(l, s)),
            const SizedBox(height: 12),
            _Step(
              number: 2,
              done: _phoneIn,
              title: l.remotePhoneStep,
              child: _phoneIn
                  ? Text(l.remotePhoneIn, style: const TextStyle(color: Colors.white70))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.remotePhoneHow, style: const TextStyle(color: Colors.white70)),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () => widget.open(tailscaleStoreUri),
                          icon: const Icon(Icons.download_rounded),
                          label: Text(l.remoteInstallApp),
                        ),
                      ],
                    ),
            ),
            if (robotReady && _phoneIn) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _ok.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _ok.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.public_rounded, color: _ok),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(l.remoteReady, style: const TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _robotStep(AppLocalizations l, TailscaleStatus? s) {
    const text = TextStyle(color: Colors.white70);
    if (_unreachable && s == null) return Text(l.remoteUnreachable, style: text);
    if (s == null) return const LinearProgressIndicator();
    if (s.state == 'absent') return Text(l.remoteAbsent, style: text);
    if (s.running) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.remoteRobotIn(s.name ?? '—'), style: const TextStyle(color: Colors.white)),
          if (s.account != null) Text(l.remoteAccount(s.account!), style: text),
          if (s.ip != null) Text('IP ${s.ip}', style: text),
          const SizedBox(height: 10),
          TextButton(
            onPressed: _busy ? null : _disconnect,
            style: TextButton.styleFrom(foregroundColor: _warn, padding: EdgeInsets.zero),
            child: Text(l.remoteDisconnect),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_link == null ? l.remoteRobotHow : l.remoteWaiting, style: text),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _connect,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.login_rounded),
              label: Text(_link == null ? l.remoteConnect : l.remoteOpenAgain),
            ),
          ],
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.done, required this.title, required this.child});

  final int number;
  final bool done;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: done ? _ok : Colors.white12,
            child: done
                ? const Icon(Icons.check_rounded, size: 18, color: Colors.black)
                : Text(
                    '$number',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                ),
                const SizedBox(height: 6),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
