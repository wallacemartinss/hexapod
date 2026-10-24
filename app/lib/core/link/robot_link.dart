import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../proto.dart';

enum LinkStatus {
  disconnected,
  connecting,
  connected,

  /// The robot refused the pairing key (HTTP 401): pair again.
  unauthorized,
}

/// WebSocket to hexd (`ws://<host>:8080/ws`), one Envelope per binary message.
/// Reconnects by itself with backoff until [close].
class RobotLink {
  /// [token] is the pairing key from the robot's QR (null: robot without
  /// pairing, e.g. hexsim in development).
  RobotLink(this.uri, {String? token, WebSocketChannel Function(Uri)? connector})
    : _connect =
          connector ??
          ((u) => IOWebSocketChannel.connect(
            u,
            headers: token == null ? null : {'Authorization': 'Bearer $token'},
          ));

  final Uri uri;
  final WebSocketChannel Function(Uri) _connect;

  final _status = StreamController<LinkStatus>.broadcast();
  final _telemetry = StreamController<Telemetry>.broadcast();
  final _hello = StreamController<Hello>.broadcast();
  final _position = StreamController<Position>.broadcast();
  final _piStatus = StreamController<PiStatus>.broadcast();
  final _targets = StreamController<Targets>.broadcast();
  final _follow = StreamController<FollowStatus>.broadcast();
  final _nav = StreamController<NavStatus>.broadcast();

  WebSocketChannel? _channel;
  LinkStatus _current = LinkStatus.disconnected;
  Duration _backoff = const Duration(milliseconds: 250);
  Timer? _retry;
  bool _closed = false;
  Hello? _lastHello;
  Position? _lastPosition;
  PiStatus? _lastPiStatus;
  FollowStatus? _lastFollow;
  NavStatus? _lastNav;

  Stream<LinkStatus> get status => _status.stream;
  Stream<Telemetry> get telemetry => _telemetry.stream;
  Stream<Hello> get hello => _hello.stream;

  /// GPS positions from hexd, about 1 Hz; none at all without a GPS.
  Stream<Position> get position => _position.stream;
  Position? get lastPosition => _lastPosition;

  /// The Raspberry Pi's own health from hexd, every 2 s.
  Stream<PiStatus> get piStatus => _piStatus.stream;
  PiStatus? get lastPiStatus => _lastPiStatus;

  /// Follow-me targets the robot's camera sees, once per processed frame;
  /// none without camera vision.
  Stream<Targets> get targets => _targets.stream;

  /// Which target is followed; one on connecting and on every change.
  Stream<FollowStatus> get follow => _follow.stream;
  FollowStatus? get lastFollow => _lastFollow;

  /// GPS navigation (missions, home, fence, route); one on connecting and
  /// on every change. None at all without a GPS.
  Stream<NavStatus> get nav => _nav.stream;
  NavStatus? get lastNav => _lastNav;

  /// The last Hello received: it arrives once per connection, so whoever
  /// starts listening later (the settings sheet) still gets the versions.
  Hello? get lastHello => _lastHello;
  LinkStatus get current => _current;

  void _set(LinkStatus s) {
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }

  /// Starts connecting; safe to call once.
  Future<void> start() => _open();

  Future<void> _open() async {
    if (_closed) return;
    _set(LinkStatus.connecting);
    final channel = _connect(uri);
    _channel = channel;
    try {
      await channel.ready.timeout(const Duration(seconds: 3));
    } catch (e) {
      // dart:io: "... not upgraded to websocket, HTTP status code: 401"
      _scheduleRetry(refused: e.toString().contains('status code: 401'));
      return;
    }
    if (_closed) {
      await channel.sink.close();
      return;
    }
    _backoff = const Duration(milliseconds: 250);
    _set(LinkStatus.connected);
    channel.stream.listen(
      (data) {
        if (data is! List<int>) return;
        final Envelope env;
        try {
          env = Envelope.fromBuffer(data);
        } catch (_) {
          return; // never crash on a bad frame
        }
        if (env.hasTelemetry()) _telemetry.add(env.telemetry);
        if (env.hasHello()) _hello.add(_lastHello = env.hello);
        if (env.hasPosition()) _position.add(_lastPosition = env.position);
        if (env.hasPiStatus()) _piStatus.add(_lastPiStatus = env.piStatus);
        if (env.hasTargets()) _targets.add(env.targets);
        if (env.hasFollowStatus()) _follow.add(_lastFollow = env.followStatus);
        if (env.hasNavStatus()) _nav.add(_lastNav = env.navStatus);
      },
      onDone: _scheduleRetry,
      onError: (_) => _scheduleRetry(),
      cancelOnError: true,
    );
  }

  void _scheduleRetry({bool refused = false}) {
    _channel = null;
    if (_closed) return;
    _set(refused ? LinkStatus.unauthorized : LinkStatus.disconnected);
    _retry?.cancel();
    _retry = Timer(_backoff, _open);
    _backoff = Duration(milliseconds: (_backoff.inMilliseconds * 2).clamp(250, 3000));
  }

  /// Sends a command if connected; dropped otherwise (the robot's failsafe
  /// covers the gap).
  void send(Command command) {
    final channel = _channel;
    if (_current != LinkStatus.connected || channel == null) return;
    channel.sink.add((Envelope()..command = command).writeToBuffer());
  }

  /// Asks the robot to follow a target (0: stop following).
  void followTarget(int trackId) {
    final channel = _channel;
    if (_current != LinkStatus.connected || channel == null) return;
    channel.sink.add((Envelope()..followRequest = (FollowRequest()..trackId = trackId)).writeToBuffer());
  }

  /// Turns follow me on or off (off: the robot stops looking for targets).
  void followMode(bool on) {
    final channel = _channel;
    if (_current != LinkStatus.connected || channel == null) return;
    channel.sink.add((Envelope()..followMode = (FollowMode()..on = on)).writeToBuffer());
  }

  /// Sends a GPS navigation request; the answer comes in the next NavStatus.
  void navRequest(NavRequest request) {
    final channel = _channel;
    if (_current != LinkStatus.connected || channel == null) return;
    channel.sink.add((Envelope()..navRequest = request).writeToBuffer());
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _channel?.sink.close();
    _set(LinkStatus.disconnected);
    await _status.close();
    await _telemetry.close();
    await _hello.close();
    await _position.close();
    await _piStatus.close();
    await _targets.close();
    await _follow.close();
    await _nav.close();
  }
}
