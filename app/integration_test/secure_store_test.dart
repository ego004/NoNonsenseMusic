// The token's store on the real platform (AUTH-1). The Mac: a file only your account can read, written from the
// sandboxed app (8 Oct). The Keychain (flutter_secure_storage) still works there: a token kept before moves out of it.
// Windows: DPAPI. The other tests use MemoryTokenStore; only this one reaches the platform.
//   flutter test integration_test/secure_store_test.dart -d macos
// Its own key and folder, never 'token' or your session's folder: run on your Mac, it leaves your session alone.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nononsense/core/auth.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a token written to the secure store reads back, and is gone once deleted', (tester) async {
    final store = SecureTokenStore();
    const key = 'integration-test-token';
    await store.write(key, 'a test token');
    expect(await store.read(key), 'a test token');
    await store.delete(key);
    expect(await store.read(key), isNull);
  });

  testWidgets('the Mac: the session is a file only you can read, written from inside the sandbox', (tester) async {
    expect(Auth.defaultStore(), isA<FileTokenStore>());
    final folder = Directory('${FileTokenStore.macFolder.path}/integration-test');
    final store = FileTokenStore(folder);
    await store.write('token', 'a test token');
    expect(File('${folder.path}/token').statSync().modeString(), 'rw-------');
    expect(await FileTokenStore(folder).read('token'), 'a test token');
    await folder.delete(recursive: true);
  }, skip: !Platform.isMacOS);
}
