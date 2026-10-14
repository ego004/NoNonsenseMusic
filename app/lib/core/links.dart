// Playlist links: opening a playlist from a shared web address or a nononsense:// URL.
import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'home_screen_widget.dart';

/// Handle playlist links in the form used by the Swift app (mac/NoNonsense/Services/PlaylistLink.swift).
///
/// What is shared is the web address `<server>/p/<id>`; the server's page there hands over to
/// `nononsense://playlist/<id>`, which opens here. The schemes are registered in macOS Info.plist (as
/// `nononsense-flutter`, since `nononsense` is the Swift app's), Android's manifest, and the Windows registry
/// (`registerOnWindows`, at launch). The app opens the playlist named in `pending` once signed in; a link to a
/// playlist the user may not see is closed with a message.
class PlaylistLinks {
  /// The playlist a link asked for, not yet shown.
  static final pending = ValueNotifier<String?>(null);

  /// A home-screen widget press that started the app (`nononsense://widget/...`), not yet run (HomeScreenWidget).
  static final widgetPress = ValueNotifier<WidgetAction?>(null);
  static StreamSubscription<Uri>? _listening;

  static final _id = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  /// The playlist a link names: `nononsense://playlist/<id>`, or the web address `.../p/<id>`; null for anything else.
  static String? playlistId(Uri uri) {
    // Accept nononsense: as well as nononsense-flutter:, the scheme of this app's macOS build, since nononsense: is
    // left to the Swift app.
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
      final press = WidgetAction.fromUri(uri);
      if (press != null) widgetPress.value = press;
    });
    if (Platform.isWindows) unawaited(registerOnWindows());
  }

  /// Record in the registry which app opens `nononsense://` on Windows.
  ///
  /// The key is under HKCU, so only the user's account is affected and no administrator rights are needed. It is
  /// written when the stored command differs from the running executable (the first launch, or after the app moved);
  /// otherwise each launch would run one `reg query` to find that out.
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
