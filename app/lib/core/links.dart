import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Playlist links (8 Oct), as in the Mac app (mac/NoNonsense/Services/PlaylistLink.swift). What you share is the web
/// address, `<server>/p/<id>`; the server's page there hands over to `nononsense://playlist/<id>`, which opens here.
/// Registered: macOS Info.plist (as `nononsense-flutter`: on a Mac, `nononsense` is the Swift app's), Android's
/// manifest, Windows' registry (`registerOnWindows`, at launch).
/// The app opens the playlist named in `pending` (Shell), once signed in; one you may not see closes, saying so.
class PlaylistLinks {
  /// The playlist a link asked for, not yet shown.
  static final pending = ValueNotifier<String?>(null);
  static StreamSubscription<Uri>? _listening;

  static final _id = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  /// The playlist a link names: `nononsense://playlist/<id>`, or the web address `.../p/<id>`; null for anything else.
  static String? playlistId(Uri uri) {
    // nononsense:, or nononsense-flutter: (this app's macOS build, which leaves nononsense: to the Swift app)
    final parts = [if (uri.scheme.startsWith('nononsense')) uri.host, ...uri.pathSegments].where((p) => p.isNotEmpty).toList();
    final i = parts.indexWhere((p) => p == 'playlist' || p == 'p');
    if (i < 0 || i + 1 >= parts.length || !_id.hasMatch(parts[i + 1])) return null;
    return parts[i + 1].toLowerCase();
  }

  /// Listens for links: the one that started the app, and any while it runs (app_links).
  static void start() {
    if (_listening != null) return;
    _listening = AppLinks().uriLinkStream.listen((uri) {
      final id = playlistId(uri);
      if (id != null) pending.value = id;
    });
    if (Platform.isWindows) unawaited(registerOnWindows());
  }

  /// Windows learns which app opens `nononsense://` from the registry (HKCU: your account only, no administrator).
  /// Written when the app's path differs from what is there (the first launch, or the app moved): one `reg query` per
  /// launch otherwise.
  static Future<void> registerOnWindows() async {
    const key = r'HKCU\Software\Classes\nononsense';
    final command = '"${Platform.resolvedExecutable}" "%1"';
    final now = await Process.run('reg', ['query', '$key\\shell\\open\\command', '/ve']);
    if (now.exitCode == 0 && (now.stdout as String).contains(Platform.resolvedExecutable)) return;
    for (final args in [
      ['add', key, '/ve', '/d', 'URL:NoNonsenseMusic', '/f'],
      ['add', key, '/v', 'URL Protocol', '/d', '', '/f'],
      ['add', '$key\\shell\\open\\command', '/ve', '/d', command, '/f'],
    ]) {
      await Process.run('reg', args);
    }
  }
}
