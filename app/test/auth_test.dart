// Sign-in (AUTH-1) without a server: the requests are answered here. The same behaviour against the real server:
// test/auth_server_test.dart.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/sign_in.dart';

/// Answers every request with `answer`, and keeps the requests as they were sent (redirect flag included).
class FakeServer extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest r, String body) answer;
  final asked = <http.BaseRequest>[];
  FakeServer(this.answer);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    asked.add(request);
    final body = request is http.Request ? request.body : '';
    final r = await answer(request, body);
    return http.StreamedResponse(Stream.value(r.bodyBytes), r.statusCode, headers: r.headers, request: request);
  }
}

http.Response json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

final session = {'token': 'new-token', 'user': {'id': 'u1', 'username': 'kai'}};

void main() {
  setUp(() => Api.base = 'http://server.test');
  tearDown(() {
    Api.client = http.Client();
    Api.token = null;
  });

  test('the player gets the audio address, never the token: /play is asked with it and its redirect not followed', () async {
    final server = FakeServer((r, _) async => http.Response('', 307, headers: {'location': 'https://audio.example/a.m4a?x=1'}));
    Api.client = server;
    Api.token = 'secret-token';
    final url = await Api.audioUrl(const Listing(source: 'jiosaavn', id: 'abc', title: 'T', artists: ['A'], duration: 200));
    final asked = server.asked.single;
    expect(asked.url.path, '/play/jiosaavn/abc');
    expect(asked.headers['authorization'], 'Bearer secret-token');
    expect(asked.followRedirects, isFalse, reason: 'followed, the redirect could carry the token to the audio host');
    expect(url, 'https://audio.example/a.m4a?x=1');
  });

  test('a 401 to the token in use signs you out; a wrong password, or an older request answering late, does not', () async {
    final store = MemoryTokenStore();
    final auth = Auth(store: store);
    var ended = 0;
    auth.onEnded = () => ended++;
    Api.client = FakeServer((r, body) async => switch (r.url.path) {
          '/auth/signin' => jsonDecode(body)['password'] == 'right password'
              ? json(session, 200)
              : json({'detail': 'Wrong username or password'}, 401),
          _ => json({'detail': 'Sign in first'}, 401),
        });

    expect(await auth.signIn('kai', 'wrong password'), 'Wrong username or password');
    expect(ended, 0, reason: "sign-in's own 401 is a wrong password, not a session that ended");
    expect(await auth.signIn('kai', 'right password'), isNull);
    expect((auth.state, store.values['token'], Api.token), (AuthState.signedIn, 'new-token', 'new-token'));

    Api.token = 'older-token';
    final older = Api.liked(); // sent with an older session's token...
    Api.token = 'new-token'; // ...answered after signing in again
    await expectLater(older, throwsA(isA<ApiError>()));
    expect(auth.state, AuthState.signedIn, reason: "an older token's 401 says nothing about this session");

    await expectLater(Api.liked(), throwsA(isA<ApiError>()));
    expect((auth.state, ended, Api.token), (AuthState.signedOut, 1, null));
    expect(store.values, isEmpty, reason: 'the stored token is deleted');
    expect(auth.notice, contains('signed out'));
  });

  testWidgets("the sign-in screen shows the server's reason, then the app once signed in", (tester) async {
    Api.client = FakeServer((r, body) async => r.url.path == '/auth/signup'
        ? json({'detail': [{'type': 'string_too_short', 'loc': ['body', 'password'], 'msg': 'String should have at least 8 characters'}]}, 422)
        : json(session, 200));
    final auth = Auth(store: MemoryTokenStore())..state = AuthState.signedOut;
    await tester.pumpWidget(MaterialApp(home: AuthGate(auth: auth, settings: Settings(), signedIn: (_) => const Text('the app'))));

    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'kai');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'short');
    await tester.tap(find.text('Create Account…'));                       // switch to creating
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create Account'));
    await tester.pumpAndSettle();
    expect(find.text('Password should have at least 8 characters'), findsOneWidget);

    await tester.tap(find.text('Sign In Instead'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
    await tester.pumpAndSettle();
    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets("the device name starts as the computer's name, and the one you type is what is sent", (tester) async {
    final sent = <String>[];
    Api.client = FakeServer((r, body) async {
      sent.add((jsonDecode(body) as Map)['device_name'] as String);
      return json(session, 200);
    });
    final auth = Auth(store: MemoryTokenStore())..state = AuthState.signedOut;
    final settings = Settings();
    await tester.pumpWidget(MaterialApp(home: AuthGate(auth: auth, settings: settings, signedIn: (_) => const Text('the app'))));

    expect(find.widgetWithText(TextField, Auth.computerName), findsOneWidget);    // shown before anything is sent
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'kai');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'a password');
    await tester.enterText(find.widgetWithText(TextField, Auth.computerName), 'Work laptop');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
    await tester.pumpAndSettle();
    expect(sent, ['Work laptop']);
    expect(settings.deviceName, 'Work laptop');                                    // offered next time
  });
}
