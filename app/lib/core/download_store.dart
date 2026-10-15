import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'audio_cache.dart';
import 'audio_download.dart';
import 'models.dart';
import 'range_fetcher.dart';

/// A downloaded song: the copy that was fetched, and the song as the app showed it, so the list works with no server.
class DownloadItem {
  DownloadItem({required this.key, required this.file, required this.best, required this.listings, this.image,
      required this.bytes, required this.added});

  final String key; // the downloaded copy: "source:id"
  /// Its name in the folder: the song's title ("source-id.m4a" before 15 Oct). A move to another folder may change it.
  String file;
  final Listing best;
  final List<Listing> listings;
  /// The song's cover as shown when it was downloaded.
  final String? image;
  final int bytes;
  final DateTime added;

  Track get track => Track(best, listings, image: image, choosingVersion: false);

  Map<String, dynamic> toJson() => {
        'key': key, 'file': file, 'best': best.toJson(), 'listings': [for (final l in listings) l.toJson()],
        'image': image, 'bytes': bytes, 'added': added.toIso8601String(),
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        key: j['key'] as String,
        file: j['file'] as String,
        best: Listing.fromJson(j['best'] as Map<String, dynamic>),
        listings: [for (final l in j['listings'] as List) Listing.fromJson(l as Map<String, dynamic>)],
        image: j['image'] as String?,
        bytes: (j['bytes'] as num).toInt(),
        added: DateTime.parse(j['added'] as String),
      );
}

/// Songs kept on this device to play with no server and no internet. The folder ([folder]: the user's choice in
/// Settings › Storage, else the app's own) holds only their audio, each file named after its song. The list of them and
/// their kept covers and lyrics are the app's own, in [data]: before 15 Oct they lay beside the music. A download is
/// never evicted, unlike the audio cache: only the user removes it.
class DownloadStore extends ChangeNotifier {
  DownloadStore({AudioCache? cache, AudioDownloads? fetches, RangeFetcher? fetcher, Future<Uri> Function(Listing)? linkFor,
      http.Client? client})
      : cache = cache ?? AudioCache.shared,
        _http = client ?? http.Client(),
        fetches = fetches ?? AudioDownloads.shared,
        fetcher = fetcher ?? RangeFetcher(http.Client()),
        linkFor = linkFor ?? _serverLink;

  static final shared = DownloadStore();

  final AudioCache cache;
  final AudioDownloads fetches;
  final RangeFetcher fetcher;
  final Future<Uri> Function(Listing) linkFor;
  final http.Client _http; // covers

  static Future<Uri> _serverLink(Listing l) async => Uri.parse(await Api.audioUrl(l));

  /// Where the songs' audio is. Null when downloads are off: storage unavailable, or the chosen folder not there.
  Directory? folder;

  /// The chosen folder when it was not there at the start (a drive unplugged): downloads are off until it is back or
  /// another is chosen, and the list stays as it was. Dropping its songs as removed by hand would lose them all.
  Directory? missingFolder;

  /// The app's own folder for the list of downloads and their kept covers and lyrics.
  Directory? data;

  /// Newest first.
  List<DownloadItem> items = [];

  /// Songs being downloaded now (by Track.id).
  final inProgress = <String>{};

  /// File names given to downloads in progress (lower case), so two songs of one title never share one.
  final _naming = <String>{};

  /// Called after each song is downloaded: the app keeps its lyrics beside it (LyricsStore.keep).
  Future<void> Function(Track)? onDownloaded;

  /// Kept covers by cover address: a downloaded song's cover shows from its file, also offline (coverProvider).
  /// Before 12 Oct no cover was kept, and Image.network keeps none on disk: offline, downloads had none.
  final _covers = <String, File>{};

  int get totalBytes => items.fold(0, (sum, i) => sum + i.bytes);

  /// The app's own folder: on Windows beside the cache in the local profile, not the roaming one, which a managed PC
  /// copies to a server at every sign-out.
  static Future<Directory> _base() async =>
      Platform.isWindows ? await getApplicationCacheDirectory() : await getApplicationSupportDirectory();

  /// Where songs download to when the user has chosen no folder.
  static Future<Directory> defaultFolder() async => Directory('${(await _base()).path}${Platform.pathSeparator}Downloads');

  /// Opens the downloads folder ([at], the user's choice, else the app's own) and reads the list from [data].
  Future<void> load({Directory? at, Directory? data}) async {
    final details = data ?? Directory('${(await _base()).path}${Platform.pathSeparator}DownloadData');
    await details.create(recursive: true);
    this.data = details;
    final audio = at ?? await defaultFolder();
    try {
      await audio.create(recursive: true);
    } on FileSystemException {
      folder = null;
      missingFolder = audio;
      items = [];
      notifyListeners();
      return;
    }
    folder = audio;
    missingFolder = null;
    await _moveDetailsOut();
    try {
      final saved = (jsonDecode(await _index.readAsString()) as List)
          .map((j) => DownloadItem.fromJson(j as Map<String, dynamic>))
          .toList();
      // a file removed by hand is no longer a download, and its kept cover and lyrics go
      items = [];
      for (final i in saved) {
        if (_audio(i).existsSync()) {
          items.add(i);
        } else {
          for (final f in [_coverFile(i), _lyricsFile(i)]) {
            if (f.existsSync()) f.deleteSync();
          }
        }
      }
    } catch (_) {
      items = [];
    }
    for (final i in items) {
      final f = _coverFile(i);
      if (i.image != null && f.existsSync()) _covers[i.image!] = f;
    }
    notifyListeners();
  }

  /// Downloads from before 15 Oct: the list, covers and lyrics lay in the folder beside the audio, and each file was
  /// named "source-id.m4a". The details move to [data] and the files take their songs' names, once: after it the
  /// folder holds no list. A file that cannot be renamed now (open in another program) keeps its old name.
  Future<void> _moveDetailsOut() async {
    final old = File('${folder!.path}/index.json');
    if (!old.existsSync() || _index.existsSync()) return;
    final List<DownloadItem> found;
    try {
      found = [for (final j in jsonDecode(await old.readAsString()) as List) DownloadItem.fromJson(j as Map<String, dynamic>)];
    } catch (_) {
      return;
    }
    for (final i in found) {
      for (final (from, to) in [
        (File('${folder!.path}/${i.file}.cover'), _coverFile(i)),
        (File('${folder!.path}/${i.file}.lyrics.json'), _lyricsFile(i)),
      ]) {
        try {
          if (from.existsSync()) await _move(from, to);
        } catch (_) {}
      }
      if (!_audio(i).existsSync()) continue;
      final name = _freeName(i.track, folder!, {});
      try {
        await _move(_audio(i), File('${folder!.path}/$name'));
        i.file = name;
      } catch (_) {}
    }
    // the details of songs no longer in the list (their audio removed by hand): nothing else in the folder is the app's
    for (final f in folder!.listSync().whereType<File>()) {
      if (RegExp(r'\.m4a\.(cover|lyrics\.json)$').hasMatch(f.path)) await f.delete();
    }
    await _write(found);
    await old.delete();
    final temp = File('${old.path}.tmp');
    if (temp.existsSync()) await temp.delete();
  }

  /// [title] as a file name every system takes: the characters Windows forbids become their full-width look-alikes
  /// ("Why？", as yt-dlp names them), and a name Windows keeps for a device ("CON") or ending in a dot is mended.
  static String fileTitle(String title) {
    const lookalike = {'<': '＜', '>': '＞', ':': '：', '"': '＂', '/': '⧸', '\\': '⧹', '|': '｜', '?': '？', '*': '＊'};
    var s = title
        .replaceAllMapped(RegExp(r'[<>:"/\\|?*]'), (m) => lookalike[m[0]]!)
        .replaceAll(RegExp(r'[\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.length > 120) {
      s = s.substring(0, 120);
      if (s.codeUnitAt(119) >= 0xD800 && s.codeUnitAt(119) <= 0xDBFF) s = s.substring(0, 119); // half a character
    }
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty) return 'Song';
    final device = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$', caseSensitive: false);
    return device.hasMatch(s.split('.').first.trim()) ? '$s (song)' : s;
  }

  /// A name for [t]'s file that no file in [dir] has: the song's title; when another song of that title is there,
  /// with its artists too; then numbered. [taken] (lower case) holds names given but not yet written.
  static String _freeName(Track t, Directory dir, Set<String> taken) {
    bool free(String name) =>
        !taken.contains(name.toLowerCase()) && !File('${dir.path}/$name').existsSync() && !File('${dir.path}/$name.part').existsSync();
    final title = fileTitle(t.title);
    final named = t.artists.isEmpty ? title : fileTitle('${t.title} - ${t.artists.join(', ')}');
    for (var n = 1;; n++) {
      for (final base in n == 1 ? {title, named} : {'$named ($n)'}) {
        if (free('$base.m4a')) {
          taken.add('$base.m4a'.toLowerCase());
          return '$base.m4a';
        }
      }
    }
  }

  /// Moves a file, also to another drive (where a rename cannot): copied, then the original removed. When that fails,
  /// the copy is removed instead, and the file stays where it was.
  static Future<void> _move(File from, File to) async {
    try {
      await from.rename(to.path);
      return;
    } on FileSystemException {
      // another drive
    }
    await from.copy(to.path);
    try {
      await from.delete();
    } catch (_) {
      await to.delete();
      rethrow;
    }
  }

  /// Whether a move is under way (moveTo).
  bool moving = false;

  /// Moves every download to [to], the folder the user chose (Settings › Storage), where new downloads then go. Each
  /// file keeps its song's name unless a file of that name is there already. On a failure the files moved so far go
  /// back, and it throws.
  Future<void> moveTo(Directory to) async {
    if (inProgress.isNotEmpty || moving) throw StateError('downloads are in progress');
    await to.create(recursive: true);
    final from = folder;
    // the chosen folder was not there at the start: the list is read again for the new one
    if (from == null) return load(at: to, data: data);
    if (FileSystemEntity.identicalSync(from.path, to.path)) return;
    moving = true;
    notifyListeners();
    final moved = <(DownloadItem, String)>[]; // with each one's name before
    try {
      final taken = <String>{};
      for (final i in items) {
        final name = _freeName(i.track, to, taken);
        await _move(File('${from.path}/${i.file}'), File('${to.path}/$name'));
        moved.add((i, i.file));
        i.file = name;
      }
      folder = to;
      await _save();
    } catch (_) {
      for (final (i, before) in moved.reversed) {
        try {
          await _move(File('${to.path}/${i.file}'), File('${from.path}/$before'));
          i.file = before;
        } catch (_) {}
      }
      folder = from;
      rethrow;
    } finally {
      moving = false;
      notifyListeners();
    }
  }

  /// The downloaded item for this song, if any of its copies is downloaded.
  DownloadItem? item(Track t) {
    for (final i in items) {
      if (t.listings.any((l) => l.key == i.key)) return i;
    }
    return null;
  }

  bool isDownloaded(Track t) => item(t) != null;
  bool isDownloading(Track t) => inProgress.contains(t.id);

  /// The file to play for this song: of any copy, or only of [copy] when the user chose one.
  File? fileFor(Track t, {Listing? copy}) {
    final i = item(t);
    if (i == null || (copy != null && copy.key != i.key)) return null;
    return _audio(i);
  }

  /// Downloads the song: its playing copy, else its other copies in turn. Copies from the cache when the song is
  /// there, otherwise fetches in bounded ranges. Returns whether the song is downloaded.
  Future<bool> download(Track t) async {
    if (folder == null || moving) return false;
    if (isDownloaded(t)) return true;
    if (!inProgress.add(t.id)) return true;
    notifyListeners();
    final name = _freeName(t, folder!, _naming);
    try {
      for (final l in [t.best, ...t.listings.where((l) => l.key != t.best.key)]) {
        try {
          final target = File('${folder!.path}/$name');
          if (!await _copyFromCache(l.key, target) && !await _fetch(l, target)) continue;
          items.insert(0, DownloadItem(key: l.key, file: name, best: t.best, listings: t.listings, image: t.image,
              bytes: await target.length(), added: DateTime.now()));
          await _save();
          await _keepCover(items.first);
          await onDownloaded?.call(t);
          return true;
        } catch (_) {
          continue;
        }
      }
      return false;
    } finally {
      _naming.remove(name.toLowerCase());
      inProgress.remove(t.id);
      notifyListeners();
    }
  }

  /// Downloads every song not downloaded yet, one at a time. Returns how many were downloaded.
  Future<int> downloadAll(List<Track> tracks) async {
    var done = 0;
    for (final t in tracks.where((t) => !isDownloaded(t))) {
      if (await download(t)) done++;
    }
    return done;
  }

  Future<void> remove(Track t) async {
    final i = item(t);
    if (i == null) return;
    await _delete(i);
    items.remove(i);
    await _save();
    notifyListeners();
  }

  Future<void> removeAll() async {
    for (final i in items) {
      await _delete(i);
    }
    items = [];
    await _save();
    notifyListeners();
  }

  /// A downloaded file that would not play is dropped from the list.
  Future<void> dropFile(File f) async {
    final gone = items.where((i) => _audio(i).path == f.path).toList();
    if (gone.isEmpty) return;
    for (final i in gone) {
      await _delete(i);
      items.remove(i);
    }
    await _save();
    notifyListeners();
  }

  Future<bool> _copyFromCache(String key, File target) async {
    // the song may be playing or queued next right now: its fetch is waited for, then it is in the cache
    await fetches.finished(key);
    final cached = cache.peek(key);
    if (cached == null) return false;
    await cached.copy(target.path);
    return true;
  }

  Future<bool> _fetch(Listing l, File target) async {
    final link = await linkFor(l);
    final download = AudioDownload(key: l.key, link: link, target: target, fetcher: fetcher);
    await fetches.background(download.whole);
    return download.isComplete;
  }

  Future<void> _delete(DownloadItem i) async {
    for (final f in [_audio(i), _coverFile(i), _lyricsFile(i)]) {
      if (await f.exists()) await f.delete();
    }
    _covers.remove(i.image);
  }

  File _audio(DownloadItem i) => File('${folder!.path}/${i.file}');
  File get _index => File('${data!.path}/index.json');
  // by the downloaded copy, which a rename or a move leaves as it was
  String _detailsName(DownloadItem i) => i.key.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_');
  File _coverFile(DownloadItem i) => File('${data!.path}/${_detailsName(i)}.cover');
  File _lyricsFile(DownloadItem i) => File('${data!.path}/${_detailsName(i)}.lyrics.json');

  /// The kept cover for this cover address, if a download has one.
  File? keptCover(String url) => _covers[url];

  Future<void> _keepCover(DownloadItem i) async {
    final address = i.image;
    if (address == null || _covers.containsKey(address)) return;
    try {
      final r = await _http.get(Uri.parse(address)).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return;
      final f = _coverFile(i);
      await f.writeAsBytes(r.bodyBytes, flush: true);
      _covers[address] = f;
      notifyListeners();
    } catch (_) {} // offline now: keepMissingCovers tries again at the next start
  }

  /// Downloads made before covers were kept: each gets its cover once, while there is internet.
  Future<void> keepMissingCovers() async {
    for (final i in [...items]) {
      await _keepCover(i);
    }
  }

  /// The lyrics kept with a downloaded song, so they show offline.
  Future<Lyrics?> keptLyrics(Track t) async {
    final i = item(t);
    if (i == null || data == null) return null;
    try {
      return Lyrics.fromJson(jsonDecode(await _lyricsFile(i).readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> keepLyrics(Track t, Lyrics lyrics) async {
    final i = item(t);
    if (i == null || data == null || lyrics.lines.isEmpty) return;
    await _lyricsFile(i).writeAsString(jsonEncode(lyrics.toJson()));
  }

  Future<void> _save() => _write(items);

  Future<void> _write(List<DownloadItem> list) async {
    final temp = File('${_index.path}.tmp');
    await temp.writeAsString(jsonEncode([for (final i in list) i.toJson()]));
    await temp.rename(_index.path);
  }
}
