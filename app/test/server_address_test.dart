// Tests for the server address: Api joins "$base/$path", so a trailing "/" asked for "//search" and every request failed;
// an address pasted without a scheme had no host, so every request failed as "Can't connect" (#23).
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an address typed with trailing slashes is kept, and used, without them', () async {
    SharedPreferences.setMockInitialValues({});
    final s = Settings();
    await s.load();
    await s.setServer('  https://music.example.com//  ');
    expect(s.server, 'https://music.example.com');
    expect(Api.base, 'https://music.example.com');
    expect((await SharedPreferences.getInstance()).getString('server'), 'https://music.example.com');
  });

  test('an address saved with a trailing slash before this fix is mended when settings load', () async {
    SharedPreferences.setMockInitialValues({'server': 'https://music.example.com/'});
    final s = Settings();
    await s.load();
    expect(s.server, 'https://music.example.com');
    expect(Api.base, 'https://music.example.com');
  });

  test('an address typed without a scheme gets https, or http for a server on this device or network', () async {
    SharedPreferences.setMockInitialValues({});
    final s = Settings();
    await s.load();
    const cases = {
      'music.example.com': 'https://music.example.com',
      '  music.example.com/  ': 'https://music.example.com',
      'https://music.example.com': 'https://music.example.com',
      'http://music.example.com:8000/': 'http://music.example.com:8000',
      '127.0.0.1:8000': 'http://127.0.0.1:8000',
      'localhost:8000': 'http://localhost:8000',
      '192.168.1.5:8000': 'http://192.168.1.5:8000',
      '[::1]:8000': 'http://[::1]:8000',
      'studio.local:8000': 'http://studio.local:8000',
      '1.2.3.4.example.com': 'https://1.2.3.4.example.com',
      '999.1.1.1': 'https://999.1.1.1',
    };
    for (final MapEntry(key: typed, value: want) in cases.entries) {
      await s.setServer(typed);
      expect(s.server, want, reason: typed);
      expect(Uri.parse('${Api.base}/search').host, isNotEmpty, reason: typed);
    }
    await s.setServer('   ');
    expect(s.server, Api.defaultServer);
  });

  test('an address saved without a scheme before this fix is mended when settings load', () async {
    SharedPreferences.setMockInitialValues({'server': 'music.example.com'});
    final s = Settings();
    await s.load();
    expect(Api.base, 'https://music.example.com');
  });
}
