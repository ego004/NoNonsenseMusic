import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Rewrites a fragmented MP4 as a plain one, for Windows.
///
/// YouTube's audio (itag 140) is a fragmented MP4: a `moov` with empty sample tables, then one `moof` + `mdat` pair per
/// few seconds of sound. Media Foundation, which just_audio_windows plays through, cannot play one that also has an
/// edit list (`edts`), as every YouTube Music copy does (its AAC priming, 1600 samples): it jumps to the end and
/// reports the song finished. A YouTube video's audio has none and plays either way. Measured 15 Oct (#30) on
/// Windows 11 with Windows.Media.Playback.MediaPlayer: "Regardless" from YouTube Music ended at once, the same song's
/// video played; with its `edts` blanked the YouTube Music file played, and the video's with that `edts` added ended
/// at once; both play as plain MP4s. So on Windows a YouTube Music copy plays only rewritten. The Mac's AVPlayer
/// plays them all.
///
/// The plain file has the same samples in the same order, one chunk per fragment's run, with the sample tables (stts,
/// stsc, stsz, stco) built from the fragments and the durations filled in; `mvex` and `sidx` are dropped. Single-track
/// files only, which every audio stream here is.
class Mp4Defrag {
  /// Rewrites [file] in place as a plain MP4 when it is a fragmented one; any other file is left as it is. Returns
  /// whether it rewrote the file; throws when it could not (the file is then as it was). Runs on another isolate: a
  /// song is a few MB, read and written whole.
  static Future<bool> ensurePlain(File file) async {
    // Most files are plain already (rewritten on an earlier play, or not YouTube's): their top-level box headers say so
    // in a few small reads, without reading the song.
    if (!isFragmented(file)) return false;
    final path = file.path;
    return Isolate.run(() => _ensurePlainSync(path));
  }

  /// Whether [file]'s top-level boxes include a `moof` before the first `mdat`: a fragmented MP4. Reads box headers
  /// only (ftyp, moov, … : usually four reads of 16 bytes). Synchronous on purpose: four small reads take a fraction of a
  /// millisecond, where each asynchronous read is a round trip to the I/O thread (slower than reading the whole file).
  static bool isFragmented(File file) {
    final raf = file.openSync();
    try {
      final length = raf.lengthSync();
      var at = 0;
      while (at + 8 <= length) {
        raf.setPositionSync(at);
        final header = ByteData.sublistView(raf.readSync(16));
        if (header.lengthInBytes < 8) return false;
        var size = header.getUint32(0);
        final type = String.fromCharCodes([for (var i = 4; i < 8; i++) header.getUint8(i)]);
        if (type == 'moof') return true;
        if (type == 'mdat') return false; // the samples came before any fragment: a plain file
        if (size == 1) {
          if (header.lengthInBytes < 16) return false;
          size = header.getUint64(8);
        } else if (size == 0) {
          return false; // the last box runs to the end of the file
        }
        if (size < 8) return false;
        at += size;
      }
      return false;
    } finally {
      raf.closeSync();
    }
  }

  static bool _ensurePlainSync(String path) {
    final plain = defragment(File(path).readAsBytesSync());
    if (plain == null) return false;
    final temp = File('$path.plain');
    temp.writeAsBytesSync(plain, flush: true);
    // Windows refuses to replace a file another program has open (a scanner or an indexer looking at the new file):
    // asked again for a moment, as AudioDownload._rename does. Given up, the fragmented file stays and this throws, so
    // the player is never given it: one played anyway ended at once, and the copy then stuck at 0:00 (15 Oct, #30)
    for (var attempt = 1;; attempt++) {
      try {
        temp.renameSync(path); // replaces the fragmented file
        return true;
      } on FileSystemException {
        if (attempt >= 5) {
          try {
            temp.deleteSync();
          } on FileSystemException {
            // left for AudioCache.open to remove
          }
          rethrow;
        }
        sleep(Duration(milliseconds: 50 * attempt));
      }
    }
  }

  /// The plain MP4 for the fragmented MP4 [bytes]; null when [bytes] is not fragmented. Throws FormatException for a
  /// file it cannot read (more than one track, a box past the end of the file).
  static Uint8List? defragment(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final top = _children(data, 0, bytes.length);
    final moov = top.where((b) => b.type == 'moov').firstOrNull;
    final moofs = top.where((b) => b.type == 'moof').toList();
    if (moov == null || moofs.isEmpty) return null;

    final inMoov = _children(data, moov.body, moov.end);
    final traks = inMoov.where((b) => b.type == 'trak').toList();
    if (traks.length != 1) throw FormatException('${traks.length} tracks; only single-track files are rewritten');
    final trex = _find(data, inMoov, ['mvex', 'trex']);
    // trex: version/flags, track_ID, default sample description index, duration, size, flags
    final defaultDuration = trex == null ? 0 : data.getUint32(trex.body + 12);
    final defaultSize = trex == null ? 0 : data.getUint32(trex.body + 16);

    // every run of samples, in file order: where its data starts, and each sample's size and duration
    final runs = <({int at, List<int> sizes, List<int> durations})>[];
    for (final moof in moofs) {
      for (final traf in _children(data, moof.body, moof.end).where((b) => b.type == 'traf')) {
        final inTraf = _children(data, traf.body, traf.end);
        final tfhd = inTraf.firstWhere((b) => b.type == 'tfhd', orElse: () => throw const FormatException('no tfhd'));
        final tfhdFlags = data.getUint32(tfhd.body) & 0xFFFFFF;
        var p = tfhd.body + 8; // past version/flags and track_ID
        var base = moof.start; // default-base-is-moof, and the base of a lone track fragment without one
        if (tfhdFlags & 0x1 != 0) {
          base = data.getUint64(p);
          p += 8;
        }
        if (tfhdFlags & 0x2 != 0) p += 4; // sample description index
        var trafDuration = defaultDuration, trafSize = defaultSize;
        if (tfhdFlags & 0x8 != 0) {
          trafDuration = data.getUint32(p);
          p += 4;
        }
        if (tfhdFlags & 0x10 != 0) trafSize = data.getUint32(p);
        int? next; // where a run without its own data offset starts: right after the previous run's data
        for (final trun in inTraf.where((b) => b.type == 'trun')) {
          final flags = data.getUint32(trun.body) & 0xFFFFFF;
          final count = data.getUint32(trun.body + 4);
          var q = trun.body + 8;
          var at = next ?? base;
          if (flags & 0x1 != 0) {
            at = base + data.getInt32(q);
            q += 4;
          }
          if (flags & 0x4 != 0) q += 4; // first sample's flags
          final sizes = <int>[], durations = <int>[];
          for (var i = 0; i < count; i++) {
            if (q > trun.end) throw const FormatException('trun is shorter than its sample count');
            var duration = trafDuration, size = trafSize;
            if (flags & 0x100 != 0) {
              duration = data.getUint32(q);
              q += 4;
            }
            if (flags & 0x200 != 0) {
              size = data.getUint32(q);
              q += 4;
            }
            if (flags & 0x400 != 0) q += 4; // sample flags
            if (flags & 0x800 != 0) q += 4; // composition time offset: none in audio
            sizes.add(size);
            durations.add(duration);
          }
          final length = sizes.fold(0, (a, b) => a + b);
          if (at < 0 || at + length > bytes.length) throw const FormatException('sample data past the end of the file');
          runs.add((at: at, sizes: sizes, durations: durations));
          next = at + length;
        }
      }
    }
    final sizes = [for (final r in runs) ...r.sizes];
    final durations = [for (final r in runs) ...r.durations];
    final mediaDuration = durations.fold(0, (a, b) => a + b);
    final dataLength = sizes.fold(0, (a, b) => a + b);

    final ftyp = _box('ftyp', [..._ascii('M4A '), ..._u32(0), ..._ascii('M4A isomiso2mp41')]);
    // moov's size does not depend on the chunk offsets' values: built once to measure, once with the real offsets
    var moovBytes = _plainMoov(bytes, data, moov, runs, durations, sizes, mediaDuration, const []);
    final dataStart = ftyp.length + moovBytes.length + 8;
    if (dataStart + dataLength > 0xFFFFFFFF) throw const FormatException('over 4 GB');
    final offsets = <int>[];
    var at = dataStart;
    for (final r in runs) {
      offsets.add(at);
      at += r.sizes.fold(0, (a, b) => a + b);
    }
    moovBytes = _plainMoov(bytes, data, moov, runs, durations, sizes, mediaDuration, offsets);

    final out = BytesBuilder(copy: false)
      ..add(ftyp)
      ..add(moovBytes)
      ..add(_u32(8 + dataLength))
      ..add(_ascii('mdat'));
    for (final r in runs) {
      out.add(Uint8List.sublistView(bytes, r.at, r.at + r.sizes.fold(0, (a, b) => a + b)));
    }
    return out.takeBytes();
  }

  /// moov without mvex, its one track's stbl holding the built tables, and mvhd, tkhd and mdhd carrying the duration.
  static Uint8List _plainMoov(Uint8List bytes, ByteData data, _Box moov,
      List<({int at, List<int> sizes, List<int> durations})> runs, List<int> durations, List<int> sizes,
      int mediaDuration, List<int> offsets) {
    final inMoov = _children(data, moov.body, moov.end);
    final mdhd = _find(data, inMoov, ['trak', 'mdia', 'mdhd'])!;
    final mvhd = inMoov.firstWhere((b) => b.type == 'mvhd');
    final mediaScale = _timescale(data, mdhd), movieScale = _timescale(data, mvhd);
    final movieDuration = mediaScale == 0 ? 0 : mediaDuration * movieScale ~/ mediaScale;

    // stts: runs of equal durations
    final stts = <int>[];
    var entries = 0;
    for (var i = 0; i < durations.length;) {
      var j = i;
      while (j < durations.length && durations[j] == durations[i]) {
        j++;
      }
      stts.addAll([..._u32(j - i), ..._u32(durations[i])]);
      entries++;
      i = j;
    }
    // stsc: one chunk per run, an entry wherever the samples per chunk change
    final stsc = <int>[];
    var stscEntries = 0;
    for (var i = 0; i < runs.length; i++) {
      if (i == 0 || runs[i].sizes.length != runs[i - 1].sizes.length) {
        stsc.addAll([..._u32(i + 1), ..._u32(runs[i].sizes.length), ..._u32(1)]);
        stscEntries++;
      }
    }
    final sameSize = sizes.every((s) => s == sizes.first);
    final tables = [
      _full('stts', [..._u32(entries), ...stts]),
      _full('stsc', [..._u32(stscEntries), ...stsc]),
      _full('stsz', [..._u32(sameSize ? sizes.first : 0), ..._u32(sizes.length), if (!sameSize) for (final s in sizes) ..._u32(s)]),
      _full('stco', [..._u32(runs.length), for (var i = 0; i < runs.length; i++) ..._u32(i < offsets.length ? offsets[i] : 0)]),
    ];
    const rebuilt = {'stts', 'stsc', 'stsz', 'stz2', 'stco', 'co64', 'ctts', 'stss'};

    Uint8List rebuild(_Box box) {
      final kids = _children(data, box.body, box.end);
      final body = BytesBuilder(copy: false);
      for (final kid in kids) {
        switch (kid.type) {
          case 'mvex':
            continue; // the fragments' defaults: no fragments any more
          case 'trak' || 'mdia' || 'minf':
            body.add(rebuild(kid));
          case 'stbl':
            final inner = BytesBuilder(copy: false);
            for (final k in _children(data, kid.body, kid.end).where((k) => !rebuilt.contains(k.type))) {
              inner.add(Uint8List.sublistView(bytes, k.start, k.end));
            }
            for (final t in tables) {
              inner.add(t);
            }
            body.add(_box('stbl', inner.takeBytes()));
          case 'mvhd' || 'mdhd' || 'tkhd':
            final copy = Uint8List.fromList(Uint8List.sublistView(bytes, kid.start, kid.end));
            _setDuration(ByteData.sublistView(copy), kid.type, kid.body - kid.start,
                kid.type == 'mdhd' ? mediaDuration : movieDuration);
            body.add(copy);
          default:
            body.add(Uint8List.sublistView(bytes, kid.start, kid.end));
        }
      }
      return _box(box.type, body.takeBytes());
    }

    return rebuild(moov);
  }

  /// mvhd's or mdhd's timescale: after version/flags and the creation and modification times (4 or 8 bytes each).
  static int _timescale(ByteData data, _Box b) => data.getUint32(b.body + (data.getUint8(b.body) == 1 ? 20 : 12));

  /// Writes [duration] into an mvhd, mdhd or tkhd whose body starts at [body] in [box].
  static void _setDuration(ByteData box, String type, int body, int duration) {
    final v1 = box.getUint8(body) == 1;
    // mvhd/mdhd: times, then timescale, then duration; tkhd: times, track_ID and a reserved word, then duration
    final at = body + 4 + (v1 ? 16 : 8) + 4 + (type == 'tkhd' ? 4 : 0);
    if (v1) {
      box.setUint64(at, duration);
    } else {
      box.setUint32(at, duration.clamp(0, 0xFFFFFFFF));
    }
  }

  /// The boxes between [from] and [to].
  static List<_Box> _children(ByteData data, int from, int to) {
    final boxes = <_Box>[];
    var at = from;
    while (at + 8 <= to) {
      var size = data.getUint32(at);
      var header = 8;
      if (size == 1) {
        if (at + 16 > to) throw const FormatException('box header past its parent');
        size = data.getUint64(at + 8);
        header = 16;
      } else if (size == 0) {
        size = to - at; // to the end of the file
      }
      if (size < header || at + size > to) throw const FormatException('box past the end of its parent');
      final type = String.fromCharCodes([for (var i = 4; i < 8; i++) data.getUint8(at + i)]);
      boxes.add(_Box(type, at, at + header, at + size));
      at += size;
    }
    return boxes;
  }

  /// The box at [path] below [boxes], or null.
  static _Box? _find(ByteData data, List<_Box> boxes, List<String> path) {
    final hit = boxes.where((b) => b.type == path.first).firstOrNull;
    if (hit == null || path.length == 1) return hit;
    return _find(data, _children(data, hit.body, hit.end), path.sublist(1));
  }

  static Uint8List _box(String type, List<int> body) =>
      Uint8List.fromList([..._u32(8 + body.length), ..._ascii(type), ...body]);

  /// A full box: version 0, no flags.
  static Uint8List _full(String type, List<int> body) => _box(type, [0, 0, 0, 0, ...body]);

  static List<int> _u32(int v) => [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];

  static List<int> _ascii(String s) => s.codeUnits;
}

class _Box {
  const _Box(this.type, this.start, this.body, this.end);
  final String type;
  final int start, body, end;
}
