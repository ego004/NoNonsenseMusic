import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library.dart';
import 'models.dart';
import 'player.dart';

/// Discord's local RPC protocol (8 Oct), as the Mac app speaks it (mac/NoNonsense/Services/Presence.swift): over the
/// pipe `\\.\pipe\discord-ipc-0` on Windows, the socket `discord-ipc-0` in the temporary folder elsewhere. Every
/// message is a frame: [opcode: uint32 LE][length: uint32 LE][JSON]. Opcode 0 handshake, 1 command or reply, 2 close
/// (Discord refused us, with a reason).
class DiscordIpc {
  DiscordIpc({List<String>? socketDirs}) : _dirs = socketDirs;
  final List<String>? _dirs; // tests: a fake Discord's folder

  _Transport? _open;
  String? _connectedId;

  static Uint8List frame(int opcode, Map<String, Object?> json) {
    final body = utf8.encode(jsonEncode(json));
    final head = ByteData(8)..setUint32(0, opcode, Endian.little)..setUint32(4, body.length, Endian.little);
    return Uint8List.fromList([...head.buffer.asUint8List(), ...body]);
  }

  /// Sends the status (null clears it). A kept connection can be dead (Discord restarts to update itself): a closed
  /// one is dropped and tried once more on a fresh one. A timeout is not retried at once: handshakes in quick
  /// succession are what makes Discord stop answering (measured on the Mac, 5 Oct).
  Future<void> setActivity(Map<String, Object?>? activity, String clientId) async {
    try {
      await _setOnce(activity, clientId);
    } on DiscordClosed {
      await disconnect();
      await _setOnce(activity, clientId);
    }
  }

  Future<void> _setOnce(Map<String, Object?>? activity, String clientId) async {
    final t = await _connect(clientId);
    await t.write(frame(1, {
      'cmd': 'SET_ACTIVITY',
      'args': {'pid': pid, 'activity': ?activity}, // no activity: the status is cleared
      'nonce': '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}',
    }));
    final (_, reply) = await _receive(t);
    if (reply['evt'] == 'ERROR') throw DiscordError(((reply['data'] as Map?)?['message'] as String?) ?? 'unknown error');
  }

  Future<void> disconnect() async {
    final t = _open;
    _open = null;
    _connectedId = null;
    await t?.close();
  }

  Future<_Transport> _connect(String clientId) async {
    final kept = _open;
    if (kept != null && _connectedId == clientId) return kept;
    await disconnect();
    final t = await _Transport.open(_dirs);
    if (t == null) throw const DiscordNotRunning();
    _open = t;
    await t.write(frame(0, {'v': 1, 'client_id': clientId}));
    final (opcode, reply) = await _receive(t);
    if (opcode != 1) {
      await disconnect();
      throw DiscordRefused((reply['message'] as String?) ?? 'refused');
    }
    _connectedId = clientId;
    return t;
  }

  Future<(int, Map<String, Object?>)> _receive(_Transport t) async {
    try {
      final head = ByteData.sublistView(await t.read(8));
      final body = await t.read(head.getUint32(4, Endian.little));
      return (head.getUint32(0, Endian.little), (body.isEmpty ? <String, Object?>{} : jsonDecode(utf8.decode(body)) as Map<String, Object?>));
    } on TimeoutException {
      await disconnect();
      throw const DiscordTimeout();
    } on Object catch (e) {
      if (e is DiscordFailure) rethrow;
      await disconnect();
      throw const DiscordClosed();
    }
  }
}

sealed class DiscordFailure implements Exception { const DiscordFailure(); }
class DiscordNotRunning extends DiscordFailure { const DiscordNotRunning(); }
class DiscordClosed extends DiscordFailure { const DiscordClosed(); }
class DiscordTimeout extends DiscordFailure { const DiscordTimeout(); }
class DiscordRefused extends DiscordFailure { final String reason; const DiscordRefused(this.reason); }
class DiscordError extends DiscordFailure { final String message; const DiscordError(this.message); }

/// Windows: the named pipe, as a file. Elsewhere: the Unix socket. Reads wait at most 10 s: Discord can take seconds
/// to answer a handshake (0.4 s, then 4.5 s, measured on the Mac).
abstract class _Transport {
  static const timeout = Duration(seconds: 10);

  static Future<_Transport?> open(List<String>? dirs) async {
    if (Platform.isWindows && dirs == null) {
      for (var i = 0; i < 10; i++) {
        try {
          return _PipeTransport(await File('\\\\.\\pipe\\discord-ipc-$i').open(mode: FileMode.append));
        } on FileSystemException {
          continue;
        }
      }
      return null;
    }
    final env = Platform.environment;
    final folders = dirs ?? [env['XDG_RUNTIME_DIR'], env['TMPDIR'], '/tmp'].whereType<String>().toList();
    for (final dir in folders) {
      for (var i = 0; i < 10; i++) {
        final path = '$dir/discord-ipc-$i';
        if (!File(path).existsSync() && FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) continue;
        try {
          return _SocketTransport(await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0));
        } on SocketException {
          continue;
        }
      }
    }
    return null;
  }

  Future<void> write(List<int> bytes);
  Future<Uint8List> read(int count);
  Future<void> close();
}

class _PipeTransport extends _Transport {
  _PipeTransport(this._file);
  final RandomAccessFile _file;
  @override
  Future<void> write(List<int> bytes) async => _file.writeFrom(bytes);
  @override
  Future<Uint8List> read(int count) async {
    final out = BytesBuilder(copy: false);
    while (out.length < count) {
      final chunk = await _file.read(count - out.length).timeout(_Transport.timeout);
      if (chunk.isEmpty) throw const DiscordClosed();
      out.add(chunk);
    }
    return out.takeBytes();
  }
  @override
  Future<void> close() => _file.close();
}

class _SocketTransport extends _Transport {
  _SocketTransport(this._socket) {
    _socket.listen((data) { _buffer.add(data); _wake(); }, onDone: () { _done = true; _wake(); }, onError: (_) { _done = true; _wake(); });
  }
  final Socket _socket;
  final _buffer = BytesBuilder(copy: false);
  bool _done = false;
  Completer<void>? _waiting;

  void _wake() { _waiting?.complete(); _waiting = null; }

  @override
  Future<void> write(List<int> bytes) async { _socket.add(bytes); await _socket.flush(); }
  @override
  Future<Uint8List> read(int count) async {
    final end = DateTime.now().add(_Transport.timeout);
    while (_buffer.length < count) {
      if (_done) throw const DiscordClosed();
      final left = end.difference(DateTime.now());
      if (left.isNegative) throw TimeoutException('Discord did not answer');
      await (_waiting = Completer<void>()).future.timeout(left);
    }
    final all = _buffer.takeBytes();
    _buffer.add(all.sublist(count));
    return Uint8List.sublistView(all, 0, count);
  }
  @override
  Future<void> close() async => _socket.destroy();
}

/// Discord status (8 Oct): the Settings switches, as the Mac app's, and the status sent whenever playback changes.
/// Off by default. Only what changes Discord's picture is sent: the song, play or pause, a seek (the time bar), the
/// playlist; never a position report while playing.
class Presence extends ChangeNotifier {
  Presence._();
  static final shared = Presence._();

  /// NoNonsense's own Discord application, built in as in the Mac app: public by design, named "NoNonsenseMusic".
  static const applicationId = '1556695358023803031';
  static const logoAsset = 'nononsense';

  DiscordIpc ipc = DiscordIpc();
  SharedPreferences? _p;
  bool enabled = false;
  String status = 'Off';
  int statusLine = 2; // what the member list shows: 0 the app's name, 1 the artist line, 2 the song
  bool shareSong = true, shareArtist = true, shareArt = true, shareTime = true, shareLogo = true, sharePlaylist = false;
  String whenPaused = 'message'; // message (your text), keep (the song, no time bar), clear (nothing)
  String pausedMessage = 'Nothing playing';

  Player? _player;
  Library? _library;
  Object? _sent; // what was last sent: the same again is not
  int _attempts = 0;

  Future<void> load() async {
    final p = _p = await SharedPreferences.getInstance();
    enabled = p.getBool('discordEnabled') ?? false;
    statusLine = p.getInt('discordStatusLine') ?? 2;
    shareSong = p.getBool('discordShareSong') ?? true;
    shareArtist = p.getBool('discordShareArtist') ?? true;
    shareArt = p.getBool('discordShareArt') ?? true;
    shareTime = p.getBool('discordShareTime') ?? true;
    shareLogo = p.getBool('discordShareLogo') ?? true;
    sharePlaylist = p.getBool('discordSharePlaylist') ?? false;
    whenPaused = p.getString('discordWhenPaused') ?? 'message';
    pausedMessage = p.getString('discordPausedMessage') ?? 'Nothing playing';
    status = enabled ? 'Shows up when a song plays' : 'Off';
  }

  /// One setter for every switch: kept, then sent at once.
  Future<void> set(String key, Object value, void Function() assign) async {
    assign();
    final p = _p;
    switch (value) {
      case final bool b: await p?.setBool(key, b);
      case final int i: await p?.setInt(key, i);
      case final String s: await p?.setString(key, s);
    }
    notifyListeners();
    _sent = null;
    update();
  }

  Future<void> setEnabled(bool on) async {
    await set('discordEnabled', on, () => enabled = on);
    if (!on) {
      _status('Off');
      try { await ipc.setActivity(null, applicationId); } catch (_) {}
      await ipc.disconnect();
    }
  }

  void follow(Player player, Library library) {
    _player = player;
    _library = library;
    player.addListener(update);
  }

  /// What Discord should show now; sent only when it changed.
  void update() {
    final p = _player;
    if (!enabled || p == null) return;
    final t = p.current;
    final origin = p.queue.origin;
    final playlist = origin != null && origin.startsWith('playlist:')
        ? _library?.playlists.where((x) => x.id == origin.substring(9)).firstOrNull?.name : null;
    final now = t == null ? null : activity(t, isPlaying: p.isPlaying, position: p.position, playlist: playlist);
    // the same picture is not sent again. The time bar's start, worked out from the position, may differ by a second
    // between two updates while playing: only a move of more than 2 s (a seek) counts
    final start = (now?['timestamps'] as Map?)?['start'] as int?;
    final key = jsonEncode({...?now, 'timestamps': null});
    if (_sent != null && key == _sentKey && (start == null) == (_sentStart == null) && ((start ?? 0) - (_sentStart ?? 0)).abs() <= 2) return;
    _sent = now ?? const {};
    _sentKey = key;
    _sentStart = start;
    _send(now, t?.title);
  }
  String? _sentKey;
  int? _sentStart;

  /// Settings' "Send a test status": the last song, or a sample.
  void sendTest() {
    final sample = _player?.current ?? Track(const Listing(source: 'jiosaavn', id: 'test', title: 'Test from NoNonsenseMusic',
        artists: ['NoNonsenseMusic'], duration: 200), const []);
    _send(activity(sample, isPlaying: true, position: 0), sample.title);
  }

  /// What Discord gets for a song, following the share switches (the Mac app's rules). null clears the status.
  Map<String, Object?>? activity(Track t, {required bool isPlaying, required double position, String? playlist, DateTime? now}) {
    String padded(String s) => s.length >= 2 ? (s.length > 128 ? s.substring(0, 128) : s) : '$s  '; // Discord: 2..128
    if (!isPlaying) {
      if (whenPaused == 'clear') return null;
      if (whenPaused == 'message') {
        final text = pausedMessage.trim().isEmpty ? 'Nothing playing' : pausedMessage.trim();
        return {
          'type': 2, 'status_display_type': 2, 'details': padded(text),
          if (shareLogo) 'assets': {'large_image': logoAsset, 'large_text': 'NoNonsenseMusic'},
        };
      }
    }
    final start = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 - position.round();
    final timed = shareTime && isPlaying;
    final cover = shareArt ? t.best.image : null;
    final badge = cover != null && shareLogo;
    final state = [if (shareArtist) 'by ${t.artists.join(', ')}', if (sharePlaylist && playlist != null) 'from “$playlist”'].join(' · ');
    final assets = {
      if (cover != null || shareLogo) 'large_image': cover ?? logoAsset,
      if (cover != null && t.best.album != null) 'large_text': padded(t.best.album!) else if (cover == null && shareLogo) 'large_text': 'NoNonsenseMusic',
      if (badge) 'small_image': logoAsset,
      if (badge) 'small_text': 'NoNonsenseMusic',
    };
    return {
      'type': 2, // "Listening to"
      'status_display_type': statusLine,
      if (shareSong) 'details': padded(t.title),
      if (state.isNotEmpty) 'state': padded(state),
      if (timed) 'timestamps': {'start': start, 'end': start + t.duration},
      if (assets.isNotEmpty) 'assets': assets,
      // deliberately no buttons or links: nothing here points at anyone's profile
    };
  }

  void _send(Map<String, Object?>? activity, String? title) {
    final attempt = ++_attempts;
    () async {
      String result;
      try {
        await ipc.setActivity(activity, applicationId);
        result = activity == null ? 'Connected, nothing playing' : 'Showing “${title ?? ''}”';
      } on DiscordNotRunning {
        result = "Discord isn't open";
      } on DiscordRefused catch (e) {
        result = 'Discord refused the ID: ${e.reason}';
      } on DiscordClosed {
        result = 'Discord closed the connection; it retries on the next song';
      } on DiscordTimeout {
        result = "Discord didn't answer in 10 s; it tries again on the next song";
      } on DiscordError catch (e) {
        result = 'Discord said: ${e.message}';
      } catch (e) {
        result = "Couldn't reach Discord: $e";
      }
      if (attempt == _attempts) _status(result); // an older, slower answer never overwrites a newer one
    }();
  }

  void _status(String s) {
    status = s;
    notifyListeners();
  }
}
