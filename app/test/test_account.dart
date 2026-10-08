import 'dart:math';

import 'package:nononsense/core/auth.dart';

/// A fresh account on the TEST server, signed in, its token kept in memory only: every test that talks to the server
/// needs one (AUTH-1). Named `test-<random>` like the backend's own (tests/conftest.py), whose run deletes them.
Future<Auth> signUpTestAccount() async {
  final auth = Auth(store: MemoryTokenStore());
  final name = 'test-${Random().nextInt(1 << 32).toRadixString(16)}';
  final error = await auth.signIn(name, 'a test password', create: true);
  if (error != null) throw StateError('could not sign up $name: $error');
  return auth;
}
