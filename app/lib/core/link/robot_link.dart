import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../proto.dart';

enum LinkStatus { disconnected, connecting, connected }

/// WebSocket to hexd (`ws://<host>:8080/ws`), one Envelope per binary message.
/// Reconnects by itself with backoff until [close].
class RobotLink {
  RobotLink(this.uri, {WebSocketChannel Function(Uri)? connector})
    : _connect = connector ?? WebSocketChannel.connect;

  final Uri uri;
  final WebSocketChannel Function(Uri) _connect;

  final _status = StreamController<LinkStatus>.broadcast();
  final _telemetry = StreamController<Telemetry>.broadcast();
  final _hello = StreamController<Hello>.broadcast();

  WebSocketChannel? _channel;
  LinkStatus _current = LinkStatus.disconnected;
  Duration _backoff = const Duration(milliseconds: 250);
  Timer? _retry;
  bool _closed = false;

  Stream<LinkStatus> get status => _status.stream;
  Stream<Telemetry> get telemetry => _telemetry.stream;
  Stream<Hello> get hello => _hello.stream;
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
    } catch (_) {
      _scheduleRetry();
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
        if (env.hasHello()) _hello.add(env.hello);
      },
      onDone: _scheduleRetry,
      onError: (_) => _scheduleRetry(),
      cancelOnError: true,
    );
  }

  void _scheduleRetry() {
    _channel = null;
    if (_closed) return;
    _set(LinkStatus.disconnected);
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

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _channel?.sink.close();
    _set(LinkStatus.disconnected);
    await _status.close();
    await _telemetry.close();
    await _hello.close();
  }
}
