// The token's store on the real platform (AUTH-1): flutter_secure_storage through the Keychain on macOS (the login
// keychain, from the sandboxed app), DPAPI on Windows. The other tests use MemoryTokenStore; only this one reaches it.
//   flutter test integration_test/secure_store_test.dart -d macos
// Its own key, never 'token': run on your Mac, it leaves your signed-in session alone.
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
}
