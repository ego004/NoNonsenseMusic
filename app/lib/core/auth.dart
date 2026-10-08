import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';

/// Where the session's token is kept between launches.
abstract class TokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The platform's secure store, not preferences: the Keychain on Apple, DPAPI-encrypted on Windows, the Keystore on
/// Android (flutter_secure_storage). A token in preferences would be a plain file anyone with the disk could read.
class SecureTokenStore implements TokenStore {
  // macOS: the ordinary (login) keychain. The data-protection keychain, the package's default there, needs a
  // keychain-access-groups entitlement and a provisioning profile, which the Mac preview build has not (8 Oct)
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// The Mac: a file only your account can read, not the Keychain (8 Oct, the owner's choice). The app is signed ad hoc,
/// so to the Keychain every build is a new app, and it asked for the login password after each one. A stable signature
/// (an Apple Developer ID) would end that; without one, a file readable by you alone is what open-source apps do.
/// One file per key in `folder` (`token`, `user`), mode 0600, written whole or not at all (a temporary file renamed).
/// `movedFrom`: where the values were before; whatever is there moves here, once, and is deleted there.
class FileTokenStore implements TokenStore {
  FileTokenStore(this.folder, {this.movedFrom});
  final Directory folder;
  final TokenStore? movedFrom;

  File _file(String key) => File('${folder.path}/$key');
  File get _moved => File('${folder.path}/.moved');

  /// The Mac app's own folder: in its sandbox container, `HOME` is the container (`~/Library/Containers/<id>/Data`).
  static Directory get macFolder =>
      Directory('${Platform.environment['HOME']}/Library/Application Support/dev.nononsense.nononsense');

  @override
  Future<String?> read(String key) async {
    final file = _file(key);
    if (await file.exists()) return file.readAsString();
    final old = movedFrom;
    // once only: the Keychain may ask for the password to read the old item, and must not ask at every launch
    if (old == null || await _moved.exists()) return null;
    final values = {for (final k in const ['token', 'user']) k: await old.read(k)};
    for (final e in values.entries) {
      if (e.value != null) await write(e.key, e.value!);
      await old.delete(e.key);
    }
    await _write(_moved, '');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) => _write(_file(key), value);

  @override
  Future<void> delete(String key) async {
    final file = _file(key);
    if (await file.exists()) await file.delete();
  }

  Future<void> _write(File file, String value) async {
    await folder.create(recursive: true);
    await _chmod('700', folder.path);
    // the whole value or nothing: a temporary file, made readable by you alone, then renamed over the old one
    final temp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await temp.writeAsString(value, flush: true);
    await _chmod('600', temp.path);
    await temp.rename(file.path);
  }

  // Dart cannot set a file's mode; chmod can. Only when a value is written: at sign-in, once
  static Future<void> _chmod(String mode, String path) async {
    final r = await Process.run('/bin/chmod', [mode, path]);
    if (r.exitCode != 0) throw FileSystemException('chmod $mode failed: ${r.stderr}', path);
  }
}

/// For tests: kept in memory only.
class MemoryTokenStore implements TokenStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

enum AuthState { checking, signedOut, signedIn }

/// Who is signed in (AUTH-1), and the token every request carries (`Api.token`). The app shows the sign-in screen
/// until this says signedIn; any 401 to a request with the token (the session expired, or was signed out on another
/// device) brings it back. Not "server unreachable": the server answered.
class Auth extends ChangeNotifier {
  Auth({TokenStore? store}) : _store = store ?? defaultStore() {
    Api.onSignedOut = _ended;
  }

  final TokenStore _store;

  /// The Mac: a file (FileTokenStore), taking over a token the Keychain held. Windows (DPAPI) and Android (Keystore):
  /// the secure store, which never asks for a password.
  static TokenStore defaultStore() =>
      Platform.isMacOS ? FileTokenStore(FileTokenStore.macFolder, movedFrom: SecureTokenStore()) : SecureTokenStore();

  AuthState state = AuthState.checking;
  AuthUser? user;

  /// Why the sign-in screen shows when you did not choose it ("You were signed out…"), or null.
  String? notice;
  /// The last sign-in could not reach the server: the screen then offers the server's address.
  bool unreachable = false;

  /// The session ended (you signed out, or the server said so): the player stops and the library empties, so nothing
  /// of this account stays on screen for the next one.
  VoidCallback? onEnded;

  /// At launch: a stored token is checked with the server (`GET /auth/me`). 200: in. 401: the sign-in screen. No answer
  /// (offline, server stopped): still in, with the last known user; the first request the server answers decides.
  Future<void> start() async {
    final token = await _store.read('token');
    if (token == null) return _set(AuthState.signedOut);
    Api.token = token;
    final saved = await _store.read('user');
    user = saved == null ? null : AuthUser.fromJson(jsonDecode(saved) as Map<String, dynamic>);
    try {
      user = await Api.me();
      await _store.write('user', jsonEncode(user!.toJson()));
      _set(AuthState.signedIn);
    } on ApiError catch (e) {
      if (e.status != 401) _set(AuthState.signedIn); // 401 already ended it (_ended, through Api.onSignedOut)
    } catch (_) {
      _set(AuthState.signedIn);
    }
  }

  /// Signs in, or makes the account and signs in (`create`). null when it worked; else the server's reason, to show
  /// as it is ("Wrong username or password", "That username is taken", "Password should have at least 8 characters").
  Future<String?> signIn(String username, String password, {bool create = false, String? device}) async {
    // an empty name would show as nothing in your device list: the computer's name instead
    var name = (device ?? '').trim();
    if (name.isEmpty) name = computerName;
    if (name.length > 64) name = name.substring(0, 64); // the server's limit
    try {
      final (token, who) = create
          ? await Api.signUp(username, password, name)
          : await Api.signIn(username, password, name);
      unreachable = false;
      await _store.write('token', token);
      await _store.write('user', jsonEncode(who.toJson()));
      Api.token = token;
      user = who;
      notice = null;
      _set(AuthState.signedIn);
      return null;
    } on ApiError catch (e) {
      unreachable = false;
      return e.toString();
    } catch (_) {
      unreachable = true;
      return "Can't connect to the server.";
    }
  }

  /// Settings › Sign Out: this device's session ends on the server, and the token is deleted here. If the server
  /// cannot be reached, you are signed out here anyway (the session then ends on its own after 30 days unused).
  /// Settings › Account › Device Name: renames this device on the server. null when it worked; else why not. The
  /// caller remembers the name (Settings.setDeviceName) for the next sign-in.
  Future<String?> renameDevice(String name) async {
    var typed = name.trim();
    if (typed.isEmpty) return 'A device needs a name.';
    if (typed.length > 64) typed = typed.substring(0, 64);
    try {
      await Api.renameDevice(typed);
      return null;
    } on ApiError catch (e) {
      return e.toString();
    } catch (_) {
      return "Can't connect to the server.";
    }
  }

  Future<void> signOut() async {
    try {
      await Api.signOut();
    } catch (_) {}
    notice = null;
    await _forget();
  }

  /// The server answered 401 to the token in use.
  void _ended() {
    if (state == AuthState.signedOut) return;
    notice = "You've been signed out.";
    _forget();
  }

  Future<void> _forget() async {
    Api.token = null; // no request carries it from here on
    user = null;
    // both deletions start now, before anyone is told: the username was left behind for a moment otherwise (8 Oct)
    final deleted = Future.wait([_store.delete('token'), _store.delete('user')]);
    _set(AuthState.signedOut);
    onEnded?.call();
    await deleted;
  }

  void _set(AuthState s) {
    state = s;
    notifyListeners();
  }

  /// The computer's name, the device name's starting value: usually made from its owner's name ("Kais-MacBook-Air"),
  /// so the sign-in screen shows it before it is sent and you can change it (8 Oct). Android has none ("localhost").
  static String get computerName {
    var name = '';
    try {
      name = Platform.localHostname;
    } catch (_) {}
    if (name.endsWith('.local')) name = name.substring(0, name.length - '.local'.length);
    if (name.isEmpty || name == 'localhost') {
      name = switch (Platform.operatingSystem) { 'macos' => 'Mac', 'windows' => 'Windows PC', 'android' => 'Android', _ => 'Computer' };
    }
    return name.length > 64 ? name.substring(0, 64) : name;
  }
}
