import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Songs' audio kept on this device: a song played before starts from its file, with no link lookup and no network.
/// On by default at 500 MB; the least recently played files go first past the limit. The files live in the system's
/// cache directory, which the system may empty when the disk is full. A file is only ever a whole song: a fetch in
/// progress writes to a `.part` file that is renamed when it is complete.
class AudioCache {
  AudioCache([this.folder]);

  static final shared = AudioCache();
  static const defaultLimitMB = 500;
  static const limitChoicesMB = [0, 250, 500, 1000, 2000];

  Directory? folder;

  /// The limit in megabytes (decimal, as disk sizes are sold); 0 is off.
  int limitMB = defaultLimitMB;

  int get limit => limitMB * 1000000;
  bool get enabled => folder != null && limitMB > 0;

  /// Finds the directory and removes fetches a crash left half done.
  Future<void> open() async {
    final dir = Directory('${(await getApplicationCacheDirectory()).path}/Audio');
    await dir.create(recursive: true);
    folder = dir;
    for (final f in dir.listSync().whereType<File>()) {
      if (f.path.endsWith('.part')) f.deleteSync();
    }
  }

  /// "ytmusic:J7p4bzqLvCw" becomes ".../ytmusic_J7p4bzqLvCw.m4a": the extension tells the player what the file is.
  File path(String key) =>
      File('${folder!.path}/${key.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_')}.m4a');

  /// The song's file if it is here, without marking it as played.
  File? peek(String key) {
    if (!enabled) return null;
    final f = path(key);
    return f.existsSync() ? f : null;
  }

  /// The song's file if it is here, marked as just played: eviction goes by that time.
  File? file(String key) {
    final f = peek(key);
    f?.setLastModifiedSync(DateTime.now());
    return f;
  }

  /// A cached file that would not play: gone, so the next play fetches it again.
  void remove(String key) {
    final f = path(key);
    if (f.existsSync()) f.deleteSync();
  }

  /// Bytes on disk.
  int size() => _files().fold(0, (sum, f) => sum + f.lengthSync());

  void clear() {
    for (final f in _files()) {
      _delete(f);
    }
  }

  /// Removes the least recently played files until the rest fit the limit. A file the player still has open may
  /// refuse to be deleted on Windows; it is left and goes at the next pass.
  ///
  /// It runs after every fetch, on the UI isolate: each file is looked at once (one stat), and a cache under its limit
  /// stops there. Sorting with lastModifiedSync in the comparison asked the disk 2·n·log n times.
  void evict() {
    final all = [for (final f in _files()) (file: f, stat: f.statSync())];
    var total = all.fold(0, (sum, e) => sum + e.stat.size);
    if (total <= limit) return;
    all.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    for (final e in all) {
      if (total <= limit) break;
      total -= e.stat.size;
      _delete(e.file);
    }
  }

  void _delete(File f) {
    try {
      f.deleteSync();
    } on FileSystemException {
      // in use; kept until the next pass
    }
  }

  List<File> _files() {
    final dir = folder;
    if (dir == null || !dir.existsSync()) return [];
    return dir.listSync().whereType<File>().where((f) => f.path.endsWith('.m4a')).toList();
  }
}
