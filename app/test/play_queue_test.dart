// The queue rules, the same ones the Mac app checks (NN_SELFTEST_QUEUE in mac/NoNonsense/Debug/SelfTest.swift):
// both apps provably behave alike.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/play_queue.dart';

Track song(String name, {String artist = ''}) => Track(
    Listing(source: 'jiosaavn', id: 'test-$name', title: name, artists: [artist.isEmpty ? 'Artist $name' : artist], duration: 200),
    const []);

final abcde = ['a', 'b', 'c', 'd', 'e'].map(song).toList();
const keys = ['k-a', 'k-b', 'k-c', 'k-d', 'k-e'];
String names(PlayQueue q) => q.tracks.map((t) => t.title).join();
(String, Track) item(String k) => (k, abcde[keys.indexOf(k)]);

void main() {
  group('repeat', () {
    test('off: the end stops; all: starts over; one: plays again, ⏭ still moves on', () {
      final q = PlayQueue()..load(abcde, 0, shuffled: false)..moveTo(4);
      expect(q.indexAfterEnd(), isNull);
      expect(q.indexAfterNext(), isNull);
      q.repeat = Repeat.all;
      expect(q.indexAfterEnd(), 0);
      expect(q.indexAfterNext(), 0);
      q.repeat = Repeat.one;
      expect(q.indexAfterEnd(), 4);
      expect(q.indexAfterNext(), 0);
    });
    test('⏮ on the first song: nowhere with repeat off, the last with repeat all', () {
      final q = PlayQueue()..load(abcde, 0, shuffled: false);
      expect(q.indexAfterPrevious(), isNull);
      q.repeat = Repeat.all;
      expect(q.indexAfterPrevious(), 4);
    });
    test('steps off → all → one → off', () {
      expect([Repeat.off.next, Repeat.all.next, Repeat.one.next], [Repeat.all, Repeat.one, Repeat.off]);
    });
  });

  group('shuffle', () {
    test('on: played songs and the current one stay, the rest are the same songs; off: your order, same song', () {
      final q = PlayQueue()..load(abcde, 2, shuffled: false)..setShuffle(true);
      expect(names(q).substring(0, 3), 'abc');
      expect(q.index, 2);
      expect(names(q).substring(3).split('').toSet(), {'d', 'e'});
      q.setShuffle(false);
      expect(names(q), 'abcde');
      expect(q.current?.title, 'c');
    });
    test('a new queue with shuffle on: your song first, every other song after', () {
      final q = PlayQueue()..load(abcde, 3, shuffled: true);
      expect(q.current?.title, 'd');
      expect(q.index, 0);
      expect(names(q).split('').toSet(), 'abcde'.split('').toSet());
    });
    test('spreads each artist out (random would put ~4 of 9 neighbours together)', () {
      final two = [for (var i = 0; i < 10; i++) song('x$i', artist: i < 5 ? 'One' : 'Two')];
      final rng = Random(1);
      var clumped = 0;
      for (var r = 0; r < 200; r++) {
        final q = PlayQueue()..load(two, 0, shuffled: true, rng: rng);
        final a = q.tracks.map((t) => t.artists.first).toList();
        for (var i = 1; i < a.length; i++) {
          if (a[i] == a[i - 1]) clumped++;
        }
      }
      expect(clumped / 200, lessThan(3));
    });
  });

  group('Play Next', () {
    test('right after the current song, still there once shuffle is off again', () {
      final q = PlayQueue()..load(abcde, 1, shuffled: false)..insertNext(song('X'));
      expect(names(q), 'abXcde');
      q..setShuffle(true)..setShuffle(false);
      expect(names(q), 'abXcde');
    });
    test('survives the playlist being opened again, and reordered, and shuffle on and off', () {
      final q = PlayQueue()..load(abcde, 0, keys: keys, source: 'playlist:4', shuffled: false)..insertNext(song('X'));
      q.sync('playlist:4', keys.map(item).toList());
      expect(names(q), 'aXbcde');
      expect(q.upNext.first.title, 'X');
      q.sync('playlist:4', ['k-a', 'k-c', 'k-b', 'k-d', 'k-e'].map(item).toList());
      expect(names(q), 'aXcbde');
      q..setShuffle(true)..setShuffle(false);
      expect(names(q), 'aXcbde');
    });
  });

  group('Add to Queue', () {
    test('after everything queued; kept last by a sync and by shuffle off', () {
      final q = PlayQueue()..load(abcde, 1, keys: keys, source: 'playlist:5', shuffled: false)..append(song('Y'));
      expect(names(q), 'abcdeY');
      q.sync('playlist:5', keys.map(item).toList());
      expect(names(q), 'abcdeY');
      q..setShuffle(true)..setShuffle(false);
      expect(names(q), 'abcdeY');
    });
  });

  group('a playlist being edited', () {
    test('the queue follows: reorder, move the playing song, remove, add; another playlist changes nothing', () {
      final q = PlayQueue()..load(abcde, 0, keys: keys, source: 'playlist:1', shuffled: false);
      q.sync('playlist:1', ['k-a', 'k-d', 'k-b', 'k-c', 'k-e'].map(item).toList());
      expect(names(q), 'adbce');
      expect(q.upNext.first.title, 'd');
      q.sync('playlist:1', ['k-d', 'k-b', 'k-a', 'k-c', 'k-e'].map(item).toList());
      expect(names(q), 'dbace');
      expect(q.current?.title, 'a');
      expect(q.upNext.first.title, 'c');
      q.sync('playlist:1', ['k-d', 'k-b', 'k-a', 'k-e'].map(item).toList());
      expect(names(q), 'dbae');
      q.sync('playlist:1', ['k-d', 'k-b', 'k-e'].map(item).toList());
      expect(names(q), 'dbae', reason: 'the playing song plays on');
      q.sync('playlist:1', [...['k-d', 'k-b', 'k-e'].map(item), ('k-f', song('f'))]);
      expect(names(q), contains('f'));
      final before = names(q);
      q.sync('playlist:2', [item('k-e')]);
      expect(names(q), before);
    });
    test('a song in twice: removing one copy keeps the other', () {
      final t = song('t');
      final q = PlayQueue()..load([abcde[0], t, abcde[1], t], 0, keys: ['i1', 'i2', 'i3', 'i4'], source: 'playlist:3', shuffled: false);
      q.sync('playlist:3', [('i1', abcde[0]), ('i3', abcde[1]), ('i4', t)]);
      expect(names(q), 'abt');
    });
  });

  group('Up Next by hand', () {
    test('drag, remove, clear; afterwards the queue is yours, and still says where it came from', () {
      final q = PlayQueue()..load(abcde, 0, keys: keys, source: 'playlist:9', shuffled: false);
      q.moveUpcoming(3, 0);
      expect(names(q), 'aebcd');
      q.moveUpcoming(0, 3);
      expect(names(q), 'abcde');
      q.moveUpcoming(2, 0);
      q.sync('playlist:9', keys.map(item).toList());
      expect(names(q), 'adbce', reason: 'a playlist sync no longer reorders it');
      expect(q.origin, 'playlist:9');
      q..setShuffle(true)..setShuffle(false);
      expect(names(q), 'adbce');
      q.removeUpcoming(1);
      expect(names(q), 'adce');
      q.clearUpcoming();
      expect(names(q), 'a');
    });
  });
}
