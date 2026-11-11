// Add to Playlist, the Spotify way: a check where a playlist already has the song, a plus where it does not; a song already
// there is not added a second time without asking (it was, silently). 11 Nov.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/add_to_playlist.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'zz_concept_settle_test.dart' show song;

Library libraryWith(Track inGym) {
  final library = Library();
  library.playlists = [
    PlaylistSummary('gym', 'Gym', 1, 180),
    PlaylistSummary('chill', 'Chill', 0, 0),
    PlaylistSummary('theirs', 'Theirs', 3, 500, role: 'viewer'),
  ];
  library.details['gym'] = PlaylistDetail(library.playlists[0], [('row1', inGym)]);
  library.details['chill'] = PlaylistDetail(library.playlists[1], const []);
  return library;
}

void main() {
  test('entriesOf finds the song in a playlist by any of its copies, and says nothing while the rows are not loaded', () {
    final track = song(1);
    final library = libraryWith(track);
    expect(library.entriesOf(track, 'gym'), ['row1']);
    expect(library.entriesOf(track, 'chill'), isEmpty);
    expect(library.entriesOf(track, 'theirs'), isNull, reason: 'not loaded: unknown, not "absent"');
  });

  test('adding a song a playlist already has says so and adds nothing', () async {
    final track = song(1);
    final library = libraryWith(track);
    String? said;
    library.problem = (m) => said = m;
    final added = await library.add(track, 'gym');
    expect(added, isFalse);
    expect(said, '“${track.title}” is already in “Gym”');
    expect(library.details['gym']!.items.length, 1, reason: 'no second row');
  });

  Future<Library> show(WidgetTester tester, Track track) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final settings = Settings();
    await settings.load();
    final library = libraryWith(track);
    await tester.pumpWidget(Scope(
      player: Player(),
      library: library,
      lyrics: LyricsStore(),
      settings: settings,
      auth: Auth(store: MemoryTokenStore()),
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, null, look: Look.phone),
        home: Scaffold(body: AddToPlaylistSheet(track: track)),
      ),
    ));
    await tester.pump();
    return library;
  }

  testWidgets('the sheet shows a check on a playlist that has the song, a plus on one that has not, and no viewer playlists', (tester) async {
    final track = song(1);
    await show(tester, track);
    expect(find.text('Gym'), findsOneWidget);
    expect(find.text('Chill'), findsOneWidget);
    expect(find.text('Theirs'), findsNothing, reason: 'a viewer cannot add songs');
    expect(find.text('Already added'), findsOneWidget, reason: 'Gym');
    expect(find.byIcon(Icons.check), findsNothing);
    final gym = find.ancestor(of: find.text('Gym'), matching: find.byType(ListTile));
    final chill = find.ancestor(of: find.text('Chill'), matching: find.byType(ListTile));
    expect(tester.widget<ListTile>(gym).subtitle.toString(), contains('Already added'));
    expect(tester.widget<ListTile>(chill).subtitle.toString(), contains('0 songs'));
  });

  testWidgets('tapping a playlist that has the song asks: Add Again or Remove', (tester) async {
    final track = song(1);
    await show(tester, track);
    await tester.tap(find.text('Gym'));
    await tester.pumpAndSettle();
    expect(find.text('Already in “Gym”'), findsOneWidget);
    expect(find.text('Add Again'), findsOneWidget);
    expect(find.text('Remove from Playlist'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Already in “Gym”'), findsNothing);
  });
}
