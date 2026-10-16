import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'api.dart';

/// One open connection to the server: text messages in and out.
abstract class SocketLink {
  /// The messages the server sends; the stream ends when the connection closes.
  Stream<String> get messages;
  void send(String text);
  void close();
}

/// Opens a connection to [url]. Tests replace it with an in-memory link.
typedef SocketConnector = Future<SocketLink> Function(Uri url);

class _IoSocketLink implements SocketLink {
  _IoSocketLink(this._socket);
  final WebSocket _socket;

  @override
  Stream<String> get messages => _socket.where((m) => m is String).cast<String>();
  @override
  void send(String text) => _socket.add(text);
  @override
  void close() => _socket.close();
}

Future<SocketLink> _connectIo(Uri url) async =>
    _IoSocketLink(await WebSocket.connect(url.toString()).timeout(const Duration(seconds: 15)));

/// A WebSocket to the server that stays open while it is wanted: a feature starts it after sign-in and stops it when
/// done, and the socket does the rest.
///
/// Each connection needs a single-use ticket (`POST /ws-ticket`), so the session token never goes into a URL. The
/// server closes a silent socket after 30 s, so the socket sends the text "ping" once it has sent nothing for 25 s: a
/// jam host's position reports, every 15 s, keep it open on their own (docs/jam.md). Between messages it waits, which
/// costs no CPU. A dropped connection is retried after 1 s, then after twice as long each time it fails
/// to connect, up to 60 s while the server is away.
class LiveSocket {
  LiveSocket({
    required this.path,
    required this.onMessage,
    this.query = const {},
    this.onDropped,
    SocketConnector? connect,
    this.pingEvery = const Duration(seconds: 25),
    this.firstWait = const Duration(seconds: 1),
    this.longestWait = const Duration(seconds: 60),
  }) : _connect = connect ?? _connectIo;

  /// The path under the server's address, for example `ws/notifications`.
  final String path;
  final Map<String, String> query;

  /// Called with each text message the server sends.
  final void Function(String text) onMessage;

  /// Awaited each time a connection ends, before the wait for the next one. A feature that finds it no longer
  /// belongs in the room calls [stop] from here.
  final Future<void> Function()? onDropped;

  final Duration pingEvery, firstWait, longestWait;
  final SocketConnector _connect;

  int _run = 0;
  bool _running = false;
  SocketLink? _link;
  Completer<void>? _nap;
  Timer? _pinger;

  bool get isRunning => _running;

  /// Whether a connection is open at this moment.
  bool get isOpen => _link != null;

  /// Starts connecting, and reconnecting whenever the connection drops. Calling it while running does nothing.
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop(++_run));
  }

  /// Closes the connection and stops reconnecting. A message that arrives afterwards is not delivered.
  void stop() {
    _running = false;
    _run++;
    _pinger?.cancel();
    _link?.close();
    _link = null;
    final nap = _nap;
    if (nap != null && !nap.isCompleted) nap.complete();
  }

  /// Sends [text]; false when no connection is open.
  bool send(String text) {
    final link = _link;
    if (link == null) return false;
    try {
      link.send(text);
    } catch (_) {
      return false;
    }
    _quiet(link);
    return true;
  }

  /// "ping" once [link] has sent nothing for [pingEvery]: one timer, set again by every message sent.
  void _quiet(SocketLink link) {
    _pinger?.cancel();
    _pinger = Timer(pingEvery, () {
      if (identical(_link, link) && !send('ping')) link.close(); // a link that cannot send is gone: connect again
    });
  }

  /// The WebSocket address for [path] on the server: ws:// for http, wss:// for https.
  static Uri urlFor(String path, Map<String, String> query) {
    final base = Uri.parse(Api.base);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      pathSegments: [...base.pathSegments.where((s) => s.isNotEmpty), ...path.split('/')],
      queryParameters: query,
    );
  }

  Future<void> _loop(int me) async {
    var wait = firstWait;
    while (me == _run) {
      if (await _once(me)) wait = firstWait;
      if (me != _run) return;
      try {
        await onDropped?.call();
      } catch (e) {
        debugPrint('socket $path: after-drop check failed: $e');
      }
      if (me != _run) return;
      await _sleep(wait);
      wait = Duration(milliseconds: math.min(wait.inMilliseconds * 2, longestWait.inMilliseconds));
    }
  }

  Future<void> _sleep(Duration d) async {
    final nap = _nap = Completer<void>();
    final timer = Timer(d, () {
      if (!nap.isCompleted) nap.complete();
    });
    await nap.future;
    timer.cancel();
  }

  /// One connection, until it drops. True when the server said something, so the next retry is quick.
  Future<bool> _once(int me) async {
    final String ticket;
    try {
      ticket = (await Api.sendJson('POST', 'ws-ticket') as Map<String, dynamic>)['ticket'] as String;
    } catch (_) {
      return false;
    }
    if (me != _run) return false;
    final SocketLink link;
    try {
      link = await _connect(urlFor(path, {...query, 'ticket': ticket}));
    } catch (_) {
      return false;
    }
    if (me != _run) {
      link.close();
      return false;
    }
    _link = link;
    _quiet(link);
    var heard = false;
    final ended = Completer<void>();
    void end() {
      if (!ended.isCompleted) ended.complete();
    }

    final subscription = link.messages.listen((text) {
      heard = true;
      if (me != _run) return;
      try {
        onMessage(text);
      } catch (e, s) {
        debugPrint('socket $path: could not handle a message: $e\n$s');
      }
    }, onError: (Object _) => end(), onDone: end);
    await ended.future;
    await subscription.cancel();
    link.close();
    if (identical(_link, link)) {
      _link = null;
      _pinger?.cancel();
    }
    return heard;
  }
}
