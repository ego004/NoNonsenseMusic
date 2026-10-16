// Friends, notifications and a jam against a test server, over the real WebSocket:
//   flutter test test/social_server_test.dart --dart-define=SERVER=http://127.0.0.1:8768
// Skipped without SERVER. Never against port 8000, which serves the user's own library.
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/jam.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/social.dart';

import 'test_account.dart';

const server = String.fromEnvironment('SERVER');

/// Waits until [done] is true, up to [seconds]; fails with [what] otherwise.
Future<void> until(bool Function() done, String what, {int seconds = 8}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  final skip = server.isEmpty || server.contains(':8000') ? 'needs --dart-define=SERVER=<a test server>' : null;

  test('a friend request reaches the other account over the socket, is accepted, and a jam is joined', () async {
    Api.base = server;
    final a = await signUpTestAccount();
    final tokenA = Api.token!;
    final b = await signUpTestAccount();
    final tokenB = Api.token!;
    final nameA = a.user!.username, nameB = b.user!.username;

    // A is signed in and listening
    Api.token = tokenA;
    final social = Social(catchUpAfter: const Duration(milliseconds: 200))..start();
    await until(() => social.isRunning, 'the service to start');
    await Future<void>.delayed(const Duration(milliseconds: 600)); // the socket's first message ("connected")

    // B asks A to be friends
    Api.token = tokenB;
    await Api.sendJson('POST', 'friends/request', {'username': nameA});
    Api.token = tokenA;
    await until(() => social.notifications.any((n) => n.type == 'friend_request'), 'the friend_request notification');
    final request = social.notifications.firstWhere((n) => n.type == 'friend_request');
    expect(request.from, nameB);
    expect(social.unread, 1);
    await until(() => social.incoming.any((f) => f.username == nameB), 'the request in the incoming list');
    await Future<void>.delayed(const Duration(milliseconds: 500)); // the confirming load must keep it
    expect(social.incoming.map((f) => f.username), [nameB]);

    // A accepts at once, and the server agrees
    expect(await social.respond(nameB, accept: true), isNull);
    expect(social.incoming, isEmpty);
    expect(social.friends.map((f) => f.username), [nameB]);
    final held = [for (final f in await Api.getJson('friends') as List) (f as Map)['username']];
    expect(held, [nameB]);

    // B hears of it
    Api.token = tokenB;
    final other = Social();
    await other.refresh();
    expect(other.friends.map((f) => f.username), [nameA]);
    expect(other.notifications.any((n) => n.type == 'friend_accepted' && n.from == nameA), isTrue);

    // reading them: the server's count follows
    Api.token = tokenA;
    await social.markAllRead();
    await social.refresh();
    expect(social.unread, 0);

    // A starts a jam, B joins it by the code, A hears about B over the room's socket and adds a song
    final jam = JamSession()..me = a.user!.id;
    expect(await jam.start(name: 'Live test'), isNull);
    expect(jam.isHost, isTrue);
    await until(() => jam.inJam, 'the room');
    await Future<void>.delayed(const Duration(milliseconds: 600)); // the room's socket opens
    Api.token = tokenB;
    final joined = await Api.sendJson('POST', 'jam/join', {'code': jam.state!.code}) as Map<String, dynamic>;
    expect((joined['members'] as List).length, 2);
    Api.token = tokenA;
    await until(() => jam.state!.members.length == 2, 'B in the room (pushed over the socket)');

    const song = Listing(source: 'jiosaavn', id: 'live-test-song', title: 'Live Test Song', artists: ['Alex'], duration: 180);
    jam.add([Track(song, [song])]);
    await until(() => jam.state!.current?.listing.id == 'live-test-song', 'the added song to become current');
    jam.setPlaying(false);
    await until(() => jam.state!.isPlaying != true, 'the pause to reach the room');

    await jam.leave();
    expect(jam.inJam, isFalse);
    social.stop();
    expect(social.isRunning, isFalse);
    expect(social.friends, isEmpty);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));
}
