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
  Auth({TokenStore? store}) : _store = store ?? SecureTokenStore() {
    Api.onSignedOut = _ended;
  }

  final TokenStore _store;
  AuthState state = AuthState.checking;
  AuthUser? user;

  /// Why the sign-in screen shows when you did not choose it ("You were signed out…"), or null.
  String? notice;

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
  Future<String?> signIn(String username, String password, {bool create = false}) async {
    try {
      final (token, who) = create
          ? await Api.signUp(username, password, deviceName)
          : await Api.signIn(username, password, deviceName);
      await _store.write('token', token);
      await _store.write('user', jsonEncode(who.toJson()));
      Api.token = token;
      user = who;
      notice = null;
      _set(AuthState.signedIn);
      return null;
    } on ApiError catch (e) {
      return e.toString();
    } catch (_) {
      return "Couldn't reach the server. Check its address below.";
    }
  }

  /// Settings › Sign Out: this device's session ends on the server, and the token is deleted here. If the server
  /// cannot be reached, you are signed out here anyway (the session then ends on its own after 30 days unused).
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
    notice = 'You were signed out. Sign in again.';
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

  /// This computer's name, for your list of signed-in devices (AUTH-4). At most 64 characters (the server's limit).
  static String get deviceName {
    var name = '';
    try {
      name = Platform.localHostname;
    } catch (_) {}
    if (name.isEmpty || name == 'localhost') name = Platform.isAndroid ? 'Android' : Platform.operatingSystem;
    return name.length > 64 ? name.substring(0, 64) : name;
  }
}
