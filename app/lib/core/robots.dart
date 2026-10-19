import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A paired robot, as the app remembers it.
class Robot {
  const Robot({required this.id, required this.name, required this.token, this.address});

  /// Short id from the QR, e.g. "7F3A" (also names the robot's own Wi-Fi).
  final String id;
  final String name;

  /// Pairing key from the QR: sent with every connection.
  final String token;

  /// Where the robot was last found (IP or host name), tried first.
  final String? address;

  Robot copyWith({String? name, String? address}) =>
      Robot(id: id, name: name ?? this.name, token: token, address: address ?? this.address);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'token': token, 'address': address};

  static Robot fromJson(Map<String, Object?> j) => Robot(
    id: j['id']! as String,
    name: j['name']! as String,
    token: j['token']! as String,
    address: j['address'] as String?,
  );
}

/// What a pairing QR (or the code typed by hand) carries.
typedef PairingCode = ({String id, String token});

/// Reads "HXP1 7F3A ABCD..." (the robot's QR, also printed by
/// `hexd -pairing`). Tolerates extra spaces and lower case typed by hand.
PairingCode? parsePairingCode(String text) {
  final f = text.trim().toUpperCase().split(RegExp(r'\s+'));
  if (f.length != 3 || f[0] != 'HXP1') return null;
  final id = f[1], token = f[2];
  if (!RegExp(r'^[A-Z2-7]{4}$').hasMatch(id) || !RegExp(r'^[A-Z2-7]{16,}$').hasMatch(token)) return null;
  return (id: id, token: token);
}

/// The paired robots and which one the app drives.
class RobotsState {
  const RobotsState({this.robots = const [], this.activeId});

  final List<Robot> robots;
  final String? activeId;

  Robot? get active => robots.where((r) => r.id == activeId).firstOrNull;
}

final robotsProvider = NotifierProvider<RobotsNotifier, RobotsState>(RobotsNotifier.new);

class RobotsNotifier extends Notifier<RobotsState> {
  /// [initial]: what main.dart loaded from the phone.
  RobotsNotifier([this._initial]);

  final RobotsState? _initial;

  static const _key = 'robots';

  @override
  RobotsState build() => _initial ?? const RobotsState();

  static Future<RobotsState> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return const RobotsState();
    try {
      final j = jsonDecode(raw) as Map<String, Object?>;
      return RobotsState(
        robots: [for (final r in j['robots']! as List) Robot.fromJson((r as Map).cast())],
        activeId: j['active'] as String?,
      );
    } catch (_) {
      return const RobotsState(); // never block the app on a bad save
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode({
        'robots': [for (final r in state.robots) r.toJson()],
        'active': state.activeId,
      }),
    );
  }

  /// Adds (or re-pairs) a robot and drives it.
  Future<void> pair(Robot robot) async {
    state = RobotsState(robots: [...state.robots.where((r) => r.id != robot.id), robot], activeId: robot.id);
    await _save();
  }

  Future<void> select(String id) async {
    state = RobotsState(robots: state.robots, activeId: id);
    await _save();
  }

  Future<void> forget(String id) async {
    final rest = state.robots.where((r) => r.id != id).toList();
    state = RobotsState(robots: rest, activeId: state.activeId == id ? rest.firstOrNull?.id : state.activeId);
    await _save();
  }

  /// Remembers where the robot answered, to try there first next time.
  Future<void> seenAt(String id, String address) async {
    final r = state.robots.where((r) => r.id == id).firstOrNull;
    if (r == null || r.address == address) return;
    state = RobotsState(
      robots: [for (final x in state.robots) x.id == id ? x.copyWith(address: address) : x],
      activeId: state.activeId,
    );
    await _save();
  }
}
