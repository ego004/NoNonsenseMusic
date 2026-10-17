// #26: a search lists the songs you have that match first. The server's word rule as this app has it (the outputs below
// are the server's: backend services/matching.py, 18 Oct), the server's marking read, and a search without the server
// finding your songs on the Search page and in the command bar.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/catalog.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/matching.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/search_model.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/command_bar.dart';
import 'package:nononsense/ui/concept.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/screens.dart';
import 'package:nononsense/ui/shell.dart';
import 'package:nononsense/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'redesign_shell_test.dart' show close;

Listing copy(String id, String title, List<String> artists, {String source = 'jiosaavn'}) =>
    Listing(source: source, id: id, title: title, artists: artists, duration: 200);

Track track(String id, String title, List<String> artists) => Track(copy(id, title, artists), const []);

Map<String, dynamic> songJson(Track t, {bool yours = false}) => {
      'title': t.title, 'artists': t.artists, 'duration': t.duration, 'score': 0, 'image': null,
      'best': t.best.toJson(), 'listings': [for (final l in t.listings) l.toJson()],
      if (yours) 'in_library': true,
    };

void main() {
  group("the server's rule", () {
    test('normalise reads text as the server does', () {
      const server = {
        'Bésame Mucho': 'besame mucho',
        'ROSÉ & Bruno Mars - APT.': 'rose bruno mars apt',
        "Don't Stop": 'don t stop',
        'Beyoncé – Halo': 'beyonce halo',
        'Straße': 'straße',
        'Łódź': 'łodz',
        'İstanbul': 'istanbul',
        'हिंदी गाना': 'ह द ग न', // a vowel sign is no letter there, and the virama goes
        'हुआ': 'ह आ',
        'Đà Lạt': 'đa lat',
        '사랑해': '사랑해', // Hangul in its letters, as NFKD has it
        'Ǆemal': 'dzemal',
        'ﬁne': 'fine',
        'Café́ Olé': 'cafe ole', // marks written apart
        'Ελλάδα': 'ελλαδα',
        'Йод ёлка': 'иод елка',
        '😀 smile': 'smile',
        'Tum Hi Ho (From "Aashiqui 2")': 'tum hi ho from aashiqui 2',
        'Ñandú': 'nandu',
      };
      server.forEach((text, expected) => expect(normalise(text), expected, reason: text));
    });

    test('a word of 4 letters or more matches one 85% alike; a shorter one only as typed', () {
      const server = [
        ('tadipar', 'tadipaar', true), ('kesriya', 'kesariya', true), ('light', 'lights', true), ('shap', 'shape', true),
        ('black', 'block', false), ('money', 'honey', false), ('hi', 'ho', false), ('sha', 'shap', false),
        ('abcdefghijklmnopqrst', 'abcdefghijklmnopqxyz', true), // exactly 85: alike
        ('abcdefghijklmnopqr', 'abcdefghijklmnoxyz', false), ('arjit', 'arijit', true), ('singh', 'sing', true),
      ];
      for (final (typed, word, alike) in server) {
        expect(found(typed, {word}), alike, reason: '$typed and $word');
      }
    });

    test('a song is found when one of its copies holds every typed word; each song once, in the order given', () {
      final kesariya = track('k', 'Kesariya', ['Pritam', 'Arijit Singh']);
      final tumHiHo = track('t', 'Tum Hi Ho', ['Arijit Singh']);
      final both = Track(copy('b1', 'Kesariya Rang', ['Someone']), [copy('b2', 'Other Name', ['Arijit Singh'])]);
      final mine = [kesariya, tumHiHo, both, Track(kesariya.best, const [])]; // the last: Kesariya again, downloaded
      expect(matchingSongs('kesriya', mine), [kesariya, both]);
      expect(matchingSongs('arijit singh', mine).map((t) => t.title), ['Kesariya', 'Tum Hi Ho', 'Kesariya Rang']);
      expect(matchingSongs('kesariya arijit', mine), [kesariya], reason: 'every word in one copy, not across copies');
      expect(matchingSongs('ho', mine), [tumHiHo]);
      expect(matchingSongs('h', mine), isEmpty);
      expect(matchingSongs('!!!', mine), isEmpty, reason: 'no words: nothing');
    });
  });

  test("the server's own songs come first, marked: their number is read", () {
    final mine = track('k', 'Kesariya', ['Arijit Singh']), theirs = track('j', 'Kesariya Lofi', ['Someone']);
    final result = SearchResult.fromJson({
      'songs': [songJson(mine, yours: true), songJson(theirs)],
    });
    expect((result.songs.length, result.yours), (2, 1));
    expect(SearchResult.fromJson({'songs': [songJson(theirs)]}).yours, 0, reason: 'an older server marks none');
  });

  testWidgets('with no server, Search finds the songs you have, and only songs', (tester) async {
    final held = [track('k', 'Kesariya', ['Arijit Singh']), track('t', 'Tum Hi Ho', ['Arijit Singh'])];
    final m = SearchModel(ask: (q, f) async => throw Exception('down'), onSongs: (_) {}, held: () => held);
    m.typed('kesriya');
    await tester.pump(const Duration(seconds: 1));
    expect((m.failed, m.songs.single, m.yours), (true, held[0], 1));
    m.setFilter(SearchFilter.artists);
    await tester.pump();
    expect(m.songs, isEmpty);
  });

  group('on screen', () {
    tearDown(() => Api.client = http.Client());

    Future<Library> open(WidgetTester tester, Widget home, {required bool server}) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final settings = Settings();
      await settings.load();
      final player = Player();
      addTearDown(player.dispose);
      final library = Library()..liked = [LibrarySong('song-k', track('k', 'Kesariya', ['Arijit Singh']))];
      Api.client = MockClient((r) async {
        if (!server || r.url.path != '/search') throw http.ClientException('no server');
        return http.Response(
            jsonEncode({
              'query': r.url.queryParameters['q'],
              'sources': [],
              'songs': [songJson(library.liked.first.track, yours: true), songJson(track('j', 'Kesariya Lofi', ['Someone']))],
            }),
            200,
            headers: {'content-type': 'application/json'});
      });
      await tester.pumpWidget(Scope(
        player: player,
        library: library,
        lyrics: LyricsStore(),
        settings: settings,
        auth: Auth(store: MemoryTokenStore()),
        child: MaterialApp(theme: buildTheme(Brightness.dark, null), home: home),
      ));
      await tester.pump(const Duration(seconds: 1));
      return library;
    }

    testWidgets('Search: your songs under In Your Library, then the rest under Songs', (tester) async {
      await open(tester, const Scaffold(body: SearchScreen(initial: 'kesariya')), server: true);
      await tester.pump(const Duration(seconds: 1));
      // .last: the Songs filter capsule is above, the heading below
      final order = ['In Your Library', 'Kesariya', 'Songs', 'Kesariya Lofi'].map((t) => tester.getTopLeft(find.text(t).last).dy).toList();
      expect(order, [...order]..sort(), reason: 'In Your Library, its song, Songs, the sources\' song: top to bottom');
      await close(tester);
    });

    testWidgets("Search with no server: your songs that match, and a line saying why only those", (tester) async {
      await open(tester, const Scaffold(body: SearchScreen(initial: 'kesriya')), server: false);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text("Can't reach your server, so only your own songs are shown."), findsOneWidget);
      expect(find.text('In Your Library'), findsOneWidget);
      expect(find.text('Kesariya'), findsOneWidget);
      expect(find.text('Is the backend running?'), findsNothing);
      await close(tester);
    });

    for (final server in [true, false]) {
      testWidgets('the command bar ${server ? '' : 'with no server '}lists your songs under IN YOUR LIBRARY', (tester) async {
        await open(tester, const Shell(), server: server);
        final box = find.descendant(of: find.byType(CommandBar), matching: find.byType(TextField));
        await tester.tap(box);
        await tester.enterText(box, 'kesariya');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        // the list's lines, top to bottom (Home lists the liked song too: only the list's own are read)
        final lines = find.descendant(of: find.byType(GlassCard), matching: find.byType(Text)).evaluate()
            .map((e) => ((e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText() ?? '', tester.getTopLeft(find.byWidget(e.widget)).dy))
            .toList()
          ..sort((a, b) => a.$2.compareTo(b.$2));
        final texts = [for (final (text, _) in lines) text];
        final songs = texts.sublist(texts.indexOf('IN YOUR LIBRARY'), texts.indexWhere((t) => t.startsWith('All results')));
        expect(songs, server
            ? ['IN YOUR LIBRARY', 'Kesariya', 'Arijit Singh', 'SONGS', 'Kesariya Lofi', 'Someone']
            : ['IN YOUR LIBRARY', 'Kesariya', 'Arijit Singh']);
        await close(tester);
      });
    }
  });
}
