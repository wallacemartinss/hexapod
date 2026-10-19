import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/proto.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../brand/brand.dart';
import 'nav_texts.dart';

const _bg = Brand.navy;
const _fence = Color(0xFFFFB020);
const _route = Brand.cyan;
const _home = Color(0xFF7BD88F);
const _target = Color(0xFFFF5A5F);

/// Sends a GPS navigation request. A provider so tests can watch them.
final navRequestProvider = Provider<void Function(NavRequest)>((ref) => ref.watch(linkProvider).navRequest);

Future<void> showMapScreen(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MapScreen()));

enum _Draw { none, fence, route }

/// The robot on an OpenStreetMap: tap a point and Go here, Go home, Patrol
/// the route, draw the fence. Like follow me, the robot walks only while
/// this app keeps sending walk Commands with the sticks released (the
/// pilot screen stays alive underneath), so STOP is at hand here too.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key, this.tiles = true});

  /// Map tiles from openstreetmap.org (off in tests: no network).
  final bool tiles;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _map = MapController();
  _Draw _draw = _Draw.none;
  final _drawn = <LatLng>[];
  LatLng? _picked;
  bool _awaiting = false; // a request went out: its answer may be a refusal
  bool _centered = false;
  bool _loop = true; // patrol: start over after the last point

  void _send(NavRequest r) {
    _awaiting = true;
    ref.read(navRequestProvider)(r);
  }

  void _act(NavAction a, {List<LatLng> points = const [], bool loop = false}) => _send(
    NavRequest(
      action: a,
      loop: loop,
      points: [for (final p in points) GeoPoint(latitudeDeg: p.latitude, longitudeDeg: p.longitude)],
    ),
  );

  void _startDrawing(_Draw d, NavStatus? st) {
    setState(() {
      _draw = d;
      _picked = null;
      _drawn
        ..clear()
        ..addAll(_points(d == _Draw.fence ? st?.fence ?? [] : st?.route ?? []));
    });
  }

  void _saveDrawing() {
    _act(_draw == _Draw.fence ? NavAction.NAV_ACTION_SET_FENCE : NavAction.NAV_ACTION_SET_ROUTE, points: _drawn);
    setState(() => _draw = _Draw.none);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    ref.listen(navStatusProvider, (_, next) {
      final st = next.value;
      if (!_awaiting || st == null) return;
      _awaiting = false;
      final why = navRefusalText(l, st.refused);
      if (why != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
      }
    });
    final st = ref.watch(navStatusProvider).value;
    final pos = ref.watch(positionProvider).value?.position;
    final robot = pos != null && pos.fix ? LatLng(pos.latitudeDeg, pos.longitudeDeg) : null;
    if (robot != null && !_centered) {
      _centered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _map.move(robot, 19);
      });
    }
    final home = st != null && st.homeSet ? _latLng(st.home) : null;
    final target = st != null && navMissionOn(st) ? _latLng(st.target) : null;
    final fence = _draw == _Draw.fence ? _drawn : _points(st?.fence ?? []);
    final route = _draw == _Draw.route ? _drawn : _points(st?.route ?? []);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        title: Text(l.navTitle),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5383B), foregroundColor: Colors.white),
            onPressed: () {
              ref.read(controlProvider.notifier).stop();
              if (st != null && navMissionOn(st)) _act(NavAction.NAV_ACTION_STOP);
            },
            child: Text(l.dataStop, style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: robot ?? home ?? const LatLng(0, 0),
              initialZoom: robot != null || home != null ? 19 : 2,
              maxZoom: 21,
              onTap: (_, p) => setState(() {
                if (_draw != _Draw.none) {
                  _drawn.add(p);
                } else {
                  _picked = p;
                }
              }),
            ),
            children: [
              if (widget.tiles)
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.wallacemartinss.hexapod_app',
                  maxNativeZoom: 19,
                ),
              if (fence.length >= 3)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: fence,
                      color: _fence.withValues(alpha: 0.12),
                      borderColor: _fence,
                      borderStrokeWidth: 3,
                    ),
                  ],
                ),
              PolylineLayer(
                polylines: [
                  if (_draw == _Draw.fence && fence.length == 2) Polyline(points: fence, color: _fence, strokeWidth: 3),
                  if (route.length >= 2)
                    Polyline(
                      points: [...route, if (_loop && _draw == _Draw.none) route.first],
                      color: _route,
                      strokeWidth: 3,
                    ),
                  if (robot != null && target != null)
                    Polyline(
                      points: [robot, target],
                      color: _target,
                      strokeWidth: 2,
                      pattern: StrokePattern.dashed(segments: const [8, 6]),
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  for (final (i, p) in route.indexed) Marker(point: p, child: _Numbered(i + 1, _route)),
                  if (_draw == _Draw.fence)
                    for (final p in fence) Marker(point: p, width: 14, height: 14, child: _Dot(_fence)),
                  if (home != null)
                    Marker(
                      point: home,
                      child: const Icon(Icons.home_rounded, color: _home, size: 30),
                    ),
                  if (target != null)
                    Marker(
                      point: target,
                      child: const Icon(Icons.flag_rounded, color: _target, size: 30),
                    ),
                  if (_picked != null)
                    Marker(
                      point: _picked!,
                      child: const Icon(Icons.place_rounded, color: Colors.white, size: 34),
                    ),
                  if (robot != null)
                    Marker(
                      point: robot,
                      width: 44,
                      height: 44,
                      child: _Robot(heading: st?.headingDeg, headingOk: st?.headingOk ?? false),
                    ),
                ],
              ),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution(
                    'OpenStreetMap contributors',
                    onTap: () => launchUrl(Uri.parse('https://openstreetmap.org/copyright')),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            left: 12,
            top: 12,
            right: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Card(
                  child: Text(
                    _draw == _Draw.fence
                        ? l.navFenceHint
                        : _draw == _Draw.route
                        ? l.navRouteHint
                        : robot == null
                        ? l.navNoFix
                        : st == null
                        ? l.navStateIdle
                        : [navMissionText(l, st), navStateText(l, st)].where((s) => s.isNotEmpty).join(' · '),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
                if (st != null && !st.driveEnabled && navMissionOn(st)) ...[
                  const SizedBox(height: 6),
                  _Card(
                    child: Text(l.navDriveOff, style: const TextStyle(color: Colors.amber)),
                  ),
                ],
              ],
            ),
          ),
          if (robot != null)
            Positioned(
              right: 12,
              bottom: 96,
              child: FloatingActionButton.small(
                heroTag: 'nav-center',
                tooltip: l.navCenter,
                backgroundColor: Brand.card,
                foregroundColor: Colors.white,
                onPressed: () => _map.move(robot, math.max(_map.camera.zoom, 18)),
                child: const Icon(Icons.my_location_rounded),
              ),
            ),
          Positioned(left: 12, right: 12, bottom: 12, child: SafeArea(top: false, child: _actions(l, st, robot))),
        ],
      ),
    );
  }

  Widget _actions(AppLocalizations l, NavStatus? st, LatLng? robot) {
    if (_draw != _Draw.none) {
      final enough = _draw == _Draw.fence ? _drawn.length >= 3 : _drawn.length >= 2;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _Button(l.navSave, Icons.check_rounded, enough ? _saveDrawing : null, primary: true),
          _Button(l.navUndo, Icons.undo_rounded, _drawn.isEmpty ? null : () => setState(_drawn.removeLast)),
          _Button(l.navRemove, Icons.delete_outline_rounded, () {
            _drawn.clear();
            _saveDrawing();
          }),
          _Button(l.navCancel, Icons.close_rounded, () => setState(() => _draw = _Draw.none)),
        ],
      );
    }
    final mission = st != null && navMissionOn(st);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (_picked != null && !mission)
          _Button(l.navGoHere, Icons.flag_rounded, () {
            _act(NavAction.NAV_ACTION_GO_TO, points: [_picked!]);
            setState(() => _picked = null);
          }, primary: true),
        if (mission) _Button(l.navCancelMission, Icons.stop_circle_outlined, () => _act(NavAction.NAV_ACTION_STOP)),
        if (st != null && st.resumable && !mission)
          _Button(l.navResume, Icons.play_arrow_rounded, () => _act(NavAction.NAV_ACTION_RESUME), primary: true),
        if (!mission) ...[
          _Button(l.navGoHome, Icons.home_rounded, () => _act(NavAction.NAV_ACTION_GO_HOME)),
          _Button(
            l.navPatrol,
            Icons.route_rounded,
            (st?.route.length ?? 0) >= 2 ? () => _act(NavAction.NAV_ACTION_PATROL, loop: _loop) : null,
          ),
          _Button(
            l.navSetHome,
            Icons.add_home_rounded,
            robot == null ? null : () => _act(NavAction.NAV_ACTION_SET_HOME),
          ),
          _Button(l.navFence, Icons.fence_rounded, () => _startDrawing(_Draw.fence, st)),
          _Button(l.navRoute, Icons.timeline_rounded, () => _startDrawing(_Draw.route, st)),
          if ((st?.route.length ?? 0) >= 2)
            FilterChip(label: Text(l.navPatrolLoop), selected: _loop, onSelected: (on) => setState(() => _loop = on)),
        ],
      ],
    );
  }
}

LatLng _latLng(GeoPoint p) => LatLng(p.latitudeDeg, p.longitudeDeg);

List<LatLng> _points(List<GeoPoint> ps) => [for (final p in ps) _latLng(p)];

class _Robot extends StatelessWidget {
  const _Robot({required this.heading, required this.headingOk});

  final double? heading;
  final bool headingOk;

  @override
  Widget build(BuildContext context) {
    final dot = DecoratedBox(
      decoration: BoxDecoration(
        color: Brand.cyan,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
      ),
      child: const SizedBox(width: 22, height: 22),
    );
    if (heading == null || !headingOk) return Center(child: dot);
    // The map is north-up: the arrow turns with the robot's heading.
    return Transform.rotate(
      angle: heading! * math.pi / 180,
      child: const Icon(Icons.navigation_rounded, color: Brand.cyan, size: 40, shadows: [Shadow(blurRadius: 6)]),
    );
  }
}

class _Numbered extends StatelessWidget {
  const _Numbered(this.n, this.color);

  final int n;
  final Color color;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        '$n',
        style: const TextStyle(color: Brand.navy, fontWeight: FontWeight.w800, fontSize: 12),
      ),
    ),
  );
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: Brand.card.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(12)),
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: child),
  );
}

class _Button extends StatelessWidget {
  const _Button(this.label, this.icon, this.onPressed, {this.primary = false});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    style: FilledButton.styleFrom(
      backgroundColor: primary ? Brand.cyan : Brand.card,
      foregroundColor: primary ? Brand.navy : Colors.white,
      disabledBackgroundColor: Brand.card.withValues(alpha: 0.5),
    ),
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    label: Text(label),
  );
}
