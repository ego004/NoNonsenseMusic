// Tests for Mp4Defrag: a fragmented MP4 like YouTube's becomes a plain one with the same samples, which Windows plays.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/mp4_defrag.dart';

List<int> u32(int v) => [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];
List<int> box(String type, List<int> body) => [...u32(8 + body.length), ...type.codeUnits, ...body];
List<int> full(String type, List<int> body, {int flags = 0}) => box(type, [0, ...u32(flags).sublist(1), ...body]);

/// A YouTube-shaped file: empty tables in moov, defaults in trex, then one moof + mdat per fragment, each fragment's
/// samples given as their bytes. tfhd and trun use YouTube's flags (0x2002a: base is the moof, a default duration;
/// 0x201: a data offset and each sample's size).
Uint8List fragmented(List<List<List<int>>> fragments, {int sampleDuration = 1024}) {
  final stbl = box('stbl', [
    ...full('stsd', u32(0)),
    ...full('stts', u32(0)),
    ...full('stsc', u32(0)),
    ...full('stco', u32(0)),
    ...full('stsz', [...u32(0), ...u32(0)]),
  ]);
  final moov = box('moov', [
    ...full('mvhd', [...u32(0), ...u32(0), ...u32(44100), ...u32(0), ...List.filled(80, 0)]),
    ...box('mvex', full('trex', [...u32(1), ...u32(1), ...u32(0), ...u32(0), ...u32(0)])),
    ...box('trak', [
      ...full('tkhd', [...u32(0), ...u32(0), ...u32(1), ...u32(0), ...u32(0), ...List.filled(60, 0)]),
      ...box('mdia', [
        ...full('mdhd', [...u32(0), ...u32(0), ...u32(44100), ...u32(0), ...u32(0)]),
        ...box('minf', stbl),
      ]),
    ]),
  ]);
  final out = <int>[...box('ftyp', [...'dash'.codeUnits, ...u32(0), ...'iso6mp41'.codeUnits]), ...moov];
  for (final samples in fragments) {
    final tfhd = full('tfhd', [...u32(1), ...u32(1), ...u32(sampleDuration), ...u32(0)], flags: 0x2002a);
    List<int> moof(int dataOffset) => box('moof', [
          ...full('mfhd', u32(1)),
          ...box('traf', [
            ...tfhd,
            ...full('trun', [...u32(samples.length), ...u32(dataOffset), for (final s in samples) ...u32(s.length)],
                flags: 0x201),
          ]),
        ]);
    final size = moof(0).length; // the data starts after the moof and the mdat's header
    out
      ..addAll(moof(size + 8))
      ..addAll(box('mdat', [for (final s in samples) ...s]));
  }
  return Uint8List.fromList(out);
}

/// The boxes of [bytes] from [from] to [to], as type -> (start of body, end).
Map<String, (int, int)> boxes(Uint8List bytes, int from, int to) {
  final data = ByteData.sublistView(bytes);
  final found = <String, (int, int)>{};
  for (var at = from; at + 8 <= to;) {
    final size = data.getUint32(at);
    found[String.fromCharCodes(bytes.sublist(at + 4, at + 8))] = (at + 8, at + size);
    at += size;
  }
  return found;
}

void main() {
  test('the samples keep their order and bytes, and the tables say where each one is', () {
    final a = [
      [1, 1, 1],
      [2, 2]
    ];
    final b = [
      [3, 3, 3, 3],
      [4],
      [5, 5]
    ];
    final plain = Mp4Defrag.defragment(fragmented([a, b]))!;
    final top = boxes(plain, 0, plain.length);
    expect(top.keys, ['ftyp', 'moov', 'mdat'], reason: 'no moof, sidx or mvex left: a plain file');
    final (mdatAt, mdatEnd) = top['mdat']!;
    expect(plain.sublist(mdatAt, mdatEnd), [1, 1, 1, 2, 2, 3, 3, 3, 3, 4, 5, 5]);

    final data = ByteData.sublistView(plain);
    final (moovAt, moovEnd) = top['moov']!;
    expect(boxes(plain, moovAt, moovEnd).keys, isNot(contains('mvex')));
    final (trakAt, trakEnd) = boxes(plain, moovAt, moovEnd)['trak']!;
    final (mdiaAt, mdiaEnd) = boxes(plain, trakAt, trakEnd)['mdia']!;
    final mdia = boxes(plain, mdiaAt, mdiaEnd);
    final (minfAt, minfEnd) = mdia['minf']!;
    final (stblAt, stblEnd) = boxes(plain, minfAt, minfEnd)['stbl']!;
    final stbl = boxes(plain, stblAt, stblEnd);
    int word(String type, int index) => data.getUint32(stbl[type]!.$1 + 4 + 4 * index);

    expect([word('stts', 0), word('stts', 1), word('stts', 2)], [1, 5, 1024], reason: 'one run: 5 samples of 1024');
    expect([word('stsz', 0), word('stsz', 1)], [0, 5], reason: 'sizes differ: a table of 5');
    expect([for (var i = 2; i < 7; i++) word('stsz', i)], [3, 2, 4, 1, 2]);
    expect(word('stsc', 0), 2, reason: 'the chunks hold 2 then 3 samples: two entries');
    expect([word('stsc', 1), word('stsc', 2), word('stsc', 4), word('stsc', 5)], [1, 2, 2, 3]);
    expect([word('stco', 0), word('stco', 1), word('stco', 2)], [2, mdatAt, mdatAt + 5], reason: 'one chunk per fragment');
    expect(data.getUint32(mdia['mdhd']!.$1 + 16), 5 * 1024, reason: "the track's length, in its own timescale");
  });

  test('a file on disk is rewritten once; its headers alone show it is plain afterwards', () async {
    final dir = await Directory.systemTemp.createTemp('defrag');
    final file = File('${dir.path}/song.m4a')..writeAsBytesSync(fragmented([
          [
            [1, 2, 3]
          ],
          [
            [4]
          ]
        ]));
    expect(Mp4Defrag.isFragmented(file), isTrue);
    expect(await Mp4Defrag.ensurePlain(file), isTrue, reason: 'rewritten');
    expect(Mp4Defrag.isFragmented(file), isFalse);
    expect(await Mp4Defrag.ensurePlain(file), isFalse, reason: 'plain already: left as it is');
    await dir.delete(recursive: true);
  });

  test('a plain file is left as it is', () {
    final plain = Mp4Defrag.defragment(fragmented([
      [
        [7, 7]
      ]
    ]))!;
    expect(Mp4Defrag.defragment(plain), isNull);
  });

  test('a file whose samples run past its end is refused, not half rewritten', () {
    final file = fragmented([
      [
        [1, 2, 3, 4]
      ]
    ]);
    expect(() => Mp4Defrag.defragment(Uint8List.sublistView(file, 0, file.length - 2)), throwsFormatException);
  });
}
