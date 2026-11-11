// In-place updates (core/update_check.dart): the feed read, and a download installed only when its length and its
// Ed25519 signature check out against the key the app trusts. The keys here are made in the test.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nononsense/core/update_check.dart';

void main() {
  test('versions compare number by number', () {
    expect(isNewer('0.3.0', '0.2.0'), isTrue);
    expect(isNewer('0.10.0', '0.9.1'), isTrue, reason: 'not as text: "0.10" sorts before "0.9"');
    expect(isNewer('0.2.0', '0.2.0'), isFalse);
    expect(isNewer('0.2', '0.2.0'), isFalse);
    expect(isNewer('0.1.9', '0.2.0'), isFalse);
  });

  late SimpleKeyPair key;
  late String publicKey;
  final payload = List<int>.generate(70000, (i) => (i * 31) % 256); // a setup or an APK
  late String signature;
  setUpAll(() async {
    key = await Ed25519().newKeyPair();
    publicKey = base64Encode((await key.extractPublicKey()).bytes);
    signature = base64Encode((await Ed25519().sign(payload, keyPair: key)).bytes);
  });

  // update.json as scripts/make-update-feeds.py writes it
  Map<String, dynamic> feed({String version = '0.4.1', int? length}) => {
        'version': version,
        'notes': "## What's new\n- In-place updates.",
        'files': {
          'NoNonsenseMusic-Setup.exe': {'url': 'https://dl.test/setup.exe', 'length': length ?? payload.length, 'ed_signature': signature},
        },
      };
  http.Client serving(Map<String, dynamic> feedJson, {List<int>? file, int status = 200}) => MockClient((r) async {
        if (r.url.path.endsWith('update.json')) return http.Response(jsonEncode(feedJson), status);
        return http.Response.bytes(file ?? payload, 200);
      });
  final updates = Directory.systemTemp.createTempSync('nn-update-test');
  tearDownAll(() => updates.deleteSync(recursive: true));

  test('a newer release is offered with its notes, its page and this platform\'s file; the same, a skipped one or none is not',
      () async {
    final update = await checkForUpdate(current: '0.4.0', client: serving(feed()), file: 'NoNonsenseMusic-Setup.exe');
    expect(update!.version, '0.4.1');
    expect(update.page.path, '/ego004/NoNonsenseMusic/releases/tag/v0.4.1');
    expect(update.notes, contains('In-place updates'));
    expect((update.file!.name, update.file!.length), ('NoNonsenseMusic-Setup.exe', payload.length));
    expect(await checkForUpdate(current: '0.4.1', client: serving(feed()), file: 'NoNonsenseMusic-Setup.exe'), isNull);
    expect(await checkForUpdate(current: '0.4.0', skipped: '0.4.1', client: serving(feed()), file: 'NoNonsenseMusic-Setup.exe'),
        isNull);
    expect(await checkForUpdate(current: '0.4.0', client: serving(feed(), status: 404), file: 'NoNonsenseMusic-Setup.exe'), isNull,
        reason: 'a release from before update.json has none');
    final noFile = await checkForUpdate(current: '0.4.0', client: serving(feed()), file: 'NoNonsenseMusic-Android.apk');
    expect(noFile!.file, isNull, reason: 'a platform the release has no file for: only its page');
  });

  test('a look says whether GitHub answered: up to date is not the same as not reached', () async {
    final upToDate = await lookUpUpdate(current: '0.4.1', client: serving(feed()), file: 'NoNonsenseMusic-Setup.exe');
    expect((upToDate.update, upToDate.reached), (null, true));
    final down = await lookUpUpdate(current: '0.4.0', client: serving(feed(), status: 503), file: 'NoNonsenseMusic-Setup.exe');
    expect((down.update, down.reached), (null, false));
    final newer = await lookUpUpdate(current: '0.4.0', client: serving(feed()), file: 'NoNonsenseMusic-Setup.exe');
    expect((newer.update?.version, newer.reached), ('0.4.1', true));
  });

  Future<UpdateFile> offered(Map<String, dynamic> j) async =>
      (await checkForUpdate(current: '0.4.0', client: serving(j), file: 'NoNonsenseMusic-Setup.exe'))!.file!;

  test('a download signed by the key is kept, with its progress told', () async {
    final shares = <double>[];
    final file = await downloadUpdate(await offered(feed()), updates,
        key: publicKey, client: serving(feed()), progress: shares.add);
    expect(await file.readAsBytes(), payload);
    expect(shares.last, 1.0);
  });

  test('a changed byte, another key, the wrong size or no key at all: refused, and nothing is left to install', () async {
    final changed = [...payload]..[500] ^= 1;
    Future<void> refused({List<int>? file, String? withKey, int? length}) async {
      final update = await offered(feed(length: length));
      await expectLater(downloadUpdate(update, updates, key: withKey ?? publicKey, client: serving(feed(length: length), file: file)),
          throwsA(isA<UpdateRefused>()));
      expect(File('${updates.path}${Platform.pathSeparator}NoNonsenseMusic-Setup.exe').existsSync(), isFalse);
    }

    final other = base64Encode((await (await Ed25519().newKeyPair()).extractPublicKey()).bytes);
    await refused(file: changed);
    await refused(withKey: other);
    await refused(file: payload.sublist(1000));
    await refused(length: payload.length + 1);
    await refused(withKey: 'RELEASE_KEY_PENDING');
  });

  test('a signature made by Sparkle\'s sign_update verifies here (the Mac signs every release file)', () async {
    // mac/UpdateTest's test key; signature of the bytes 0..255 made with sign_update 2.10.0 (25 Oct)
    final sparkleKey = File('../mac/UpdateTest/test-update-public.key').readAsStringSync().trim();
    final bytes = List<int>.generate(256, (i) => i);
    final signed = File('test/fixtures/sparkle_signature.txt').readAsStringSync().trim();
    final ok = await Ed25519().verify(bytes,
        signature: Signature(base64Decode(signed), publicKey: SimplePublicKey(base64Decode(sparkleKey), type: KeyPairType.ed25519)));
    expect(ok, isTrue);
  });
}
