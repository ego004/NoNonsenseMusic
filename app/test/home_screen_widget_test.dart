// Tests for the Android home-screen widget: the state it is sent, and the presses it sends back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/accent.dart';
import 'package:nononsense/core/home_screen_widget.dart';
import 'package:nononsense/core/models.dart';

Track song(String name, {String? image, String? album}) =>
    Track(Listing(source: 'jiosaavn', id: 'id-$name', title: name, artists: const ['Kai', 'Mo'], duration: 200, album: album), const [], image: image);

final song0 = song('Blue');

void main() {
  group('state', () {
    test('a playing song: its title, artists, album, cover, liked heart and the play state', () {
      final s = HomeWidgetState.of(signedIn: true, current: song('Blue', album: 'Sky'), playing: true, liked: true, recent: const [], coverPath: '/c.png');
      expect(s['signedIn'], isTrue);
      expect(s['title'], 'Blue');
      expect(s['artist'], 'Kai, Mo');
      expect(s['album'], 'Sky');
      expect(s['playing'], isTrue);
      expect(s['liked'], isTrue);
      expect(s['cover'], '/c.png');
      expect(s['resume'], isFalse);
    });

    test('a song with no album sends none', () {
      final s = HomeWidgetState.of(signedIn: true, current: song('Blue'), playing: true, liked: false, recent: const [], coverPath: null);
      expect(s['album'], isNull);
    });

    test('nothing loaded: the most recent play is offered to resume', () {
      final s = HomeWidgetState.of(signedIn: true, current: null, playing: false, liked: false, recent: [song('Old'), song('Older')], coverPath: null);
      expect(s['resume'], isTrue);
      expect(s['title'], 'Old', reason: 'the song that resume plays');
      expect(s['playing'], isFalse);
    });

    test('nothing loaded and nothing played: no song, no resume', () {
      final s = HomeWidgetState.of(signedIn: true, current: null, playing: false, liked: false, recent: const [], coverPath: null);
      expect(s['resume'], isFalse);
      expect(s['title'], isNull);
    });

    test('signed out: nothing of the account is sent', () {
      final s = HomeWidgetState.of(signedIn: false, current: song('Blue'), playing: true, liked: true, recent: [song('Old')], coverPath: '/c.png');
      expect(s, {'signedIn': false});
    });
  });

  group('accent', () {
    test("the playing cover's colour, made readable on each theme, as the app's own accent", () {
      const song = Color(0xFF2E7D32);
      final s = HomeWidgetState.of(signedIn: true, current: song0, playing: true, liked: false, recent: const [], coverPath: null, song: song);
      final a = s['accent'] as Map;
      expect(a['light'], Accent.readable(song, Brightness.light).toARGB32());
      expect(a['dark'], Accent.readable(song, Brightness.dark).toARGB32());
    });

    test('a grey cover, or none: no accent is sent, so the widget keeps its default blue', () {
      final s = HomeWidgetState.of(signedIn: true, current: song0, playing: true, liked: false, recent: const [], coverPath: null, song: null);
      expect(s.containsKey('accent'), isFalse);
    });
  });

  group('actions', () {
    test('each button press is read back', () {
      for (final k in ['toggle', 'next', 'previous', 'back10', 'forward10', 'like', 'resume']) {
        expect(WidgetAction.parse(k), WidgetAction(k));
      }
    });

    test('anything else is ignored', () {
      expect(WidgetAction.parse('format-disk'), isNull);
      expect(WidgetAction.parse('recent:1'), isNull, reason: 'the widget no longer shows recent plays');
      expect(WidgetAction.parse('tile:abc'), isNull, reason: 'nor playlist tiles');
    });

    test('a press that started the app arrives as a nononsense://widget link', () {
      expect(WidgetAction.fromUri(Uri.parse('nononsense://widget/next')), const WidgetAction('next'));
      expect(WidgetAction.fromUri(Uri.parse('nononsense://widget/forward10')), const WidgetAction('forward10'));
      expect(WidgetAction.fromUri(Uri.parse('nononsense://widget/next/1')), isNull);
      expect(WidgetAction.fromUri(Uri.parse('nononsense://playlist/abc')), isNull);
      expect(WidgetAction.fromUri(Uri.parse('https://example.com/widget/next')), isNull);
    });
  });
}
