// The Friends screen, the notifications list and the jam panel at phone and desktop sizes, with mock data: each must
// build without a layout overflow (the test fails on one), and the taps must reach the services.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/jam.dart';
import 'package:nononsense/core/links.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/social.dart';
import 'package:nononsense/ui/friends.dart';
import 'package:nononsense/ui/jam_panel.dart';
import 'package:nononsense/ui/notifications.dart';
import 'package:nononsense/ui/theme.dart';

import 'fake_http.dart';

const sizes = [(360.0, 740.0), (390.0, 844.0), (1280.0, 800.0)];

Map<String, dynamic> person(String id, String name) => {'user_id': id, 'username': name, 'since': '2026-10-01T08:00:00'};

Map<String, dynamic> note(String id, String type, Map<String, dynamic> payload, {bool read = false}) =>
    {'id': id, 'type': type, 'payload': payload, 'seq': 1, 'read': read, 'created_at': '2026-10-12T09:30:00+00:00'};

Listing listing(String id, String title) =>
    Listing(source: 'jiosaavn', id: id, title: title, artists: const ['Alex', 'Sam Kai'], duration: 200);

const longName = 'a-very-long-username-that-goes-on-and-on';

FakeServer serverWith({bool empty = false}) => FakeServer((method, path, body) async {
      switch ('$method $path') {
        case 'GET /friends':
          return (200, empty ? [] : [person('u1', 'sam'), person('u3', longName), person('u4', 'alex')]);
        case 'GET /friends/requests':
          return (200, {
            'incoming': empty ? [] : [person('u2', 'kai'), person('u5', longName)],
            'outgoing': empty ? [] : [person('u6', 'riley')],
          });
        case 'GET /notifications':
          return (200, {
            'notifications': empty
                ? []
                : [
                    note('n1', 'friend_request', {'from_username': 'kai'}),
                    note('n2', 'friend_accepted', {'by_username': 'sam'}, read: true),
                    note('n3', 'playlist_invite', {'playlist_id': 'p1', 'playlist_name': 'Road Trip', 'from_username': 'alex'}),
                    note('n4', 'jam_invite', {'room_id': 'r1', 'code': 'abc12', 'room_name': null, 'from_username': longName}),
                    note('n5', 'jam_invite', {'room_id': 'r1', 'code': 'zzz99', 'room_name': 'Friday', 'from_username': 'sam'}),
                  ],
            'unread_count': empty ? 0 : 3,
          });
        case 'POST /friends/respond' || 'POST /notifications/read-all' || 'POST /friends/request':
          return (204, null);
        case 'POST /jam/join' || 'GET /jam/r1':
          return (200, room());
        case 'POST /ws-ticket':
          return (200, {'ticket': 't', 'expires_in': 30});
      }
      return (404, {'detail': 'unexpected $method $path'});
    });

Map<String, dynamic> room({bool host = true, bool withSongs = true}) => {
      'room_id': 'r1',
      'code': 'abc12',
      'name': null,
      'host_id': host ? 'me' : 'u2',
      'members': [
        {'user_id': 'me', 'username': 'kai'},
        {'user_id': 'u2', 'username': longName},
        {'user_id': 'u3', 'username': 'riley'},
      ],
      'current': withSongs ? {'entry_id': 'e1', 'listing': listing('a', 'A song with a rather long title indeed').toJson()} : null,
      'is_playing': true,
      'position_seconds': 10,
      'queue': withSongs
          ? [for (var i = 0; i < 12; i++) {'entry_id': 'q$i', 'listing': listing('s$i', 'Queued song $i').toJson()}]
          : [],
    };

Future<void> sizeTo(WidgetTester tester, (double, double) size) async {
  tester.view.physicalSize = Size(size.$1, size.$2);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget app(Widget home, {List<Widget> actions = const []}) => MaterialApp(
      theme: buildTheme(Brightness.light, null),
      home: Scaffold(appBar: AppBar(actions: actions, toolbarHeight: 44), body: home),
    );

void main() {
  tearDown(() {
    Api.client = http.Client();
    Api.token = null;
  });

  for (final size in sizes) {
    final label = '${size.$1.toInt()}x${size.$2.toInt()}';

    testWidgets('Friends screen builds at $label with every section, and empty', (tester) async {
      await sizeTo(tester, size);
      useServer(serverWith());
      final social = Social();
      await tester.pumpWidget(app(FriendsScreen(social: social)));
      await tester.pumpAndSettle();
      for (final text in ['Requests', 'Wants to be friends', 'Accept', 'Decline', 'Sent', 'Your Friends', 'sam', 'riley']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      await tester.scrollUntilVisible(find.text('alex'), 100, scrollable: find.byType(Scrollable).first);

      useServer(serverWith(empty: true));
      final none = Social();
      await tester.pumpWidget(app(FriendsScreen(social: none)));
      await tester.pumpAndSettle();
      expect(find.text('No Friends Yet'), findsOneWidget);
      expect(find.text('Add Friend'), findsOneWidget);
    });

    testWidgets('notifications open from the bell at $label and every kind has its action', (tester) async {
      await sizeTo(tester, size);
      useServer(serverWith());
      final social = Social();
      await social.refresh();
      final jam = JamSession();
      await tester.pumpWidget(app(const SizedBox(), actions: [NotificationsButton(social: social, jam: jam)]));
      expect(find.text('3'), findsOneWidget, reason: 'the unread count on the bell');
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.textContaining('wants to be friends.', findRichText: true), findsOneWidget);
      expect(find.textContaining('accepted your friend request.', findRichText: true), findsOneWidget);
      expect(find.textContaining('shared “Road Trip” with you.', findRichText: true), findsOneWidget);
      expect(find.textContaining('invited you to a jam.', findRichText: true), findsOneWidget);
      expect(find.textContaining('invited you to “Friday”.', findRichText: true), findsOneWidget);
      for (final action in ['Accept', 'Decline', 'Open Playlist']) {
        expect(find.text(action), findsOneWidget, reason: action);
      }
      expect(find.text('Join Jam'), findsNWidgets(2));

      await tester.pump(const Duration(seconds: 2)); // the moment after which they count as read
      expect(social.unread, 0);
      expect(social.notifications.every((n) => n.read), isTrue);

      PlaylistLinks.pending.value = null;
      await tester.tap(find.text('Open Playlist'));
      await tester.pumpAndSettle();
      expect(PlaylistLinks.pending.value, 'p1', reason: 'the shell opens the playlist');
      PlaylistLinks.pending.value = null;
      expect(find.text('Notifications'), findsNothing, reason: 'the panel closed');
    });

    testWidgets('the jam panel at $label: start or join when out, the room when in', (tester) async {
      await sizeTo(tester, size);
      useServer(serverWith());
      final social = Social();
      await social.refresh();
      final jam = JamSession(connect: (_) async => FakeLink())..me = 'me';
      await tester.pumpWidget(app(const SizedBox(), actions: [JamButton(jam: jam, social: social)]));
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.text('Start a Jam'), findsOneWidget);
      expect(find.text('Start a Jam'), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);

      // joining with a code: the panel turns into the room
      await tester.enterText(find.byType(TextField), 'ABC-12');
      await tester.pump();
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(jam.inJam, isTrue);
      expect(find.text('ABC12'), findsOneWidget);
      expect(find.text('Playing on every device'), findsOneWidget);
      expect(find.text('Up Next'), findsOneWidget);
      expect(find.text('Invite'), findsOneWidget);
      expect(find.text('Speakers'), findsOneWidget);
      expect(find.text('Leave Jam'), findsOneWidget);
      expect(find.textContaining("kai's Jam"), findsOneWidget);

      // the host chooses where the jam plays, in the Speakers menu
      await tester.tap(find.text('Speakers'));
      await tester.pumpAndSettle();
      expect(find.text('Only this device plays'), findsOneWidget);
      await tester.tap(find.text('Only this device plays'));
      await tester.pumpAndSettle();
      expect(find.text('Only this device plays'), findsNothing, reason: 'choosing closes the menu');

      jam.leaveLocally();
      await tester.pumpAndSettle();
      expect(find.text('Start a Jam'), findsOneWidget);
      await tester.tapAt(const Offset(2, 2)); // outside the panel
      await tester.pumpAndSettle();
      jam.dispose();
    });

    testWidgets('a member who is not the host sees no host controls, at $label', (tester) async {
      await sizeTo(tester, size);
      useServer(serverWith());
      final jam = JamSession(connect: (_) async => FakeLink())..me = 'me';
      jam.handle(jsonEncode({'type': 'state', 'data': room(host: false, withSongs: false)}));
      expect(jam.inJam, isTrue);
      await tester.pumpWidget(app(JamPanel(jam: jam, social: Social())));
      await tester.pumpAndSettle();
      expect(find.text('Playing on every device'), findsOneWidget);
      expect(find.text('Play here'), findsOneWidget, reason: 'a member can turn this device\'s sound off');
      expect(find.text('Invite'), findsNothing);
      expect(find.text('Speakers'), findsNothing);
      expect(find.text('Nothing playing. Play any song to start the jam.'), findsOneWidget);
      expect(find.byTooltip('Remove riley'), findsNothing);

      // the host plays the room alone: this device follows silently, and says where the sound is
      jam.handle(jsonEncode({'type': 'state', 'data': room(host: false, withSongs: false)..['host_only'] = true}));
      await tester.pumpAndSettle();
      expect(find.text("Playing on $longName's device"), findsOneWidget);
      expect(find.text('Play here'), findsNothing);
    });
  }

  testWidgets('Now Playing shows the room queue with a Jam label while in a jam, and the player queue otherwise', (tester) async {
    await sizeTo(tester, sizes.last);
    final jam = JamSession(connect: (_) async => FakeLink())..me = 'me';
    await tester.pumpWidget(app(SizedBox(height: 500, child: JamUpNext(jam: jam, child: const Text('the local queue')))));
    expect(find.text('the local queue'), findsOneWidget);
    jam.handle(jsonEncode({'type': 'state', 'data': room()}));
    await tester.pumpAndSettle();
    expect(find.text('the local queue'), findsNothing);
    expect(find.text('Jam'), findsOneWidget);
    expect(find.text('Queued song 0'), findsOneWidget);
    jam.dispose();
  });

  testWidgets('a friend pick is one tap: the username, ready to share', (tester) async {
    useServer(serverWith());
    final social = Social();
    await social.refresh();
    String? picked;
    await tester.pumpWidget(app(FriendPicks(social: social, exclude: const {'sam'}, onPick: (u) => picked = u)));
    expect(find.text('sam'), findsNothing, reason: 'already on the playlist');
    await tester.tap(find.text('alex'));
    expect(picked, 'alex');
  });
}
