import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/link/robot_link.dart';
import '../../core/proto.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/robots.dart';
import '../../core/version.dart';
import '../robots/remote_access_screen.dart';
import '../robots/robot_network_screen.dart';
import '../robots/robots_sheet.dart';
import '../../l10n/l10n.dart';
import 'controller_sheet.dart';

Future<void> showSettingsSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: const Color(0xFF15181D),
  builder: (_) => const _SettingsSheet(),
);

class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet();

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet> {
  late Settings _s = ref.read(settingsProvider);
  late final _host = TextEditingController(text: _s.host);

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(settingsProvider.notifier).update(_s.copyWith(host: _host.text.trim()));
    if (mounted) Navigator.pop(context);
  }

  Widget _slider(String label, String help, double value, double min, double max, ValueChanged<double> f) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 170,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Colors.white)),
                  Text(help, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
            Expanded(
              child: Slider(value: value, min: min, max: max, onChanged: (v) => setState(() => f(v))),
            ),
            SizedBox(
              width: 44,
              child: Text('${(value * 100).round()}%', style: const TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      );

  /// The language applies (and is saved) right away, apart from the other
  /// edits, which wait for Save.
  void _setLanguage(String code) {
    setState(() => _s = _s.copyWith(language: code));
    final notifier = ref.read(settingsProvider.notifier);
    notifier.update(ref.read(settingsProvider).copyWith(language: code));
  }

  Widget _language(AppLocalizations l) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        SizedBox(
          width: 170,
          child: Text(l.settingsLanguage, style: const TextStyle(color: Colors.white)),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              // Each language is named in itself, whatever the app language.
              // No "phone language" choice: that is the default until one
              // is picked, and the language in use shows as selected.
              segments: const [
                ButtonSegment(value: 'en', label: Text('English')),
                ButtonSegment(value: 'pt', label: Text('Português')),
              ],
              selected: {Localizations.localeOf(context).languageCode},
              onSelectionChanged: (v) => _setLanguage(v.first),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final hello = ref.watch(helloProvider).value;
    final connected = ref.watch(linkStatusProvider).value == LinkStatus.connected;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 16, 24, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    l.settingsTitle,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  FilledButton(onPressed: _save, child: Text(l.settingsSave)),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _host,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(labelText: l.settingsHost, helperText: l.settingsHostHelp),
              ),
              const SizedBox(height: 12),
              _slider(
                l.settingsDeadzone,
                l.settingsDeadzoneHelp,
                _s.deadzone,
                0,
                0.3,
                (v) => _s = _s.copyWith(deadzone: v),
              ),
              _slider(l.settingsExpo, l.settingsExpoHelp, _s.expo, 0, 1, (v) => _s = _s.copyWith(expo: v)),
              _slider(
                l.settingsMaxSpeed,
                l.settingsMaxSpeedHelp,
                _s.maxSpeed,
                0.2,
                1,
                (v) => _s = _s.copyWith(maxSpeed: v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.settingsLeftHanded, style: const TextStyle(color: Colors.white)),
                subtitle: Text(l.settingsLeftHandedHelp, style: const TextStyle(color: Colors.white54)),
                value: _s.swapSticks,
                onChanged: (v) => setState(() => _s = _s.copyWith(swapSticks: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.settingsHaptics, style: const TextStyle(color: Colors.white)),
                value: _s.haptics,
                onChanged: (v) => setState(() => _s = _s.copyWith(haptics: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.settingsAutoHide, style: const TextStyle(color: Colors.white)),
                subtitle: Text(l.settingsAutoHideHelp, style: const TextStyle(color: Colors.white54)),
                value: _s.autoHideBars,
                onChanged: (v) => setState(() => _s = _s.copyWith(autoHideBars: v)),
              ),
              _language(l),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.smart_toy_rounded, color: Colors.white70),
                title: Text(l.robotsTitle, style: const TextStyle(color: Colors.white)),
                subtitle: Text(l.settingsRobotsHelp, style: const TextStyle(color: Colors.white54)),
                trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
                onTap: () {
                  final nav = Navigator.of(context)..pop();
                  showRobotsSheet(nav.context);
                },
              ),
              if (ref.watch(robotsProvider).active != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.wifi_rounded, color: Colors.white70),
                  title: Text(l.settingsNetwork, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(l.settingsNetworkHelp, style: const TextStyle(color: Colors.white54)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
                  onTap: () {
                    final nav = Navigator.of(context)..pop();
                    showRobotNetworkScreen(nav.context);
                  },
                ),
              if (ref.watch(robotsProvider).active != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.public_rounded, color: Colors.white70),
                  title: Text(l.settingsRemote, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(l.settingsRemoteHelp, style: const TextStyle(color: Colors.white54)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
                  onTap: () {
                    final nav = Navigator.of(context)..pop();
                    showRemoteAccessScreen(nav.context);
                  },
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.sports_esports_rounded, color: Colors.white70),
                title: Text(l.controllerTitle, style: const TextStyle(color: Colors.white)),
                subtitle: Text(l.settingsControllerHelp, style: const TextStyle(color: Colors.white54)),
                trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
                onTap: () {
                  // Close this sheet first (it holds unsaved edits of its own);
                  // the navigator's context outlives it.
                  final nav = Navigator.of(context)..pop();
                  showControllerSheet(nav.context);
                },
              ),
              const Divider(color: Colors.white12),
              Text(
                '${l.settingsAppVersion(appVersion)}\n${robotVersions(l, hello, connected: connected)}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Robot software line in the settings: ESP32 firmware, hexd (the bridge on
/// the Pi) and protocol versions.
String robotVersions(AppLocalizations l, Hello? hello, {required bool connected}) {
  if (!connected) return l.settingsRobotOffline;
  if (hello == null) return l.settingsRobotWaiting;
  final firmware = hello.firmwareVersion.isEmpty ? l.settingsFirmwareWaiting : hello.firmwareVersion;
  final bridge = hello.hexdVersion.isEmpty ? '' : l.settingsBridgeVersion(hello.hexdVersion);
  return l.settingsRobotVersions(firmware, bridge, hello.protocolVersion);
}
