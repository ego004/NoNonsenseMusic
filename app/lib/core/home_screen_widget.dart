// The Android home-screen widget: what it shows, and what its buttons do. The widget itself is native
// (android/app/src/main/kotlin/.../NowPlayingWidget.kt); this side tells it what to draw and runs its presses.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'accent.dart';
import 'auth.dart';
import 'cover_image.dart';
import 'download_store.dart';
import 'library.dart';
import 'links.dart';
import 'models.dart';
import 'player.dart';

/// A press on the widget: `toggle`, `next`, `previous`, `back10`, `forward10` (a seek of ten seconds), `like` or
/// `resume`.
@immutable
class WidgetAction {
  final String kind;
  const WidgetAction(this.kind);

  static const _kinds = {'toggle', 'next', 'previous', 'back10', 'forward10', 'like', 'resume'};

  /// Reads `next`, as the native widget sends it; null for anything else.
  static WidgetAction? parse(String s) => _kinds.contains(s) ? WidgetAction(s) : null;

  /// A press that started the app: `nononsense://widget/next`.
  static WidgetAction? fromUri(Uri uri) {
    if (!uri.scheme.startsWith('nononsense') || uri.host != 'widget') return null;
    final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    return parts.length == 1 ? parse(parts.single) : null;
  }

  @override
  bool operator ==(Object other) => other is WidgetAction && other.kind == kind;
  @override
  int get hashCode => kind.hashCode;
  @override
  String toString() => kind;
}

/// What the widget draws, as the plain map it is stored as.
abstract final class HomeWidgetState {
  /// Nothing loaded: the song shown is the latest play, which Play resumes (no queue is kept between launches).
  /// Signed out, nothing of the account is sent.
  ///
  /// [song] is the playing cover's colour ([Accent]): the widget's heart takes it, made readable on each theme as the
  /// app's own accent is (buildTheme). Null (a grey cover, or none) leaves the widget's default blue.
  static Map<String, Object?> of({
    required bool signedIn,
    required Track? current,
    required bool playing,
    required bool liked,
    required List<Track> recent,
    required String? coverPath,
    Color? song,
  }) {
    if (!signedIn) return {'signedIn': false};
    final shown = current ?? recent.firstOrNull;
    return {
      if (song != null)
        'accent': {'light': Accent.readable(song, Brightness.light).toARGB32(), 'dark': Accent.readable(song, Brightness.dark).toARGB32()},
      'signedIn': true,
      'title': shown?.title,
      'artist': shown?.artistLine,
      'album': shown?.albumTitle,
      'cover': coverPath,
      'playing': current != null && playing,
      'liked': current != null && liked,
      'resume': current == null && shown != null,
    };
  }
}

/// Keeps the widget in step with the player and the library, and runs its presses. Android only: a no-op elsewhere.
///
/// Presses arrive on the `nononsense/widget` channel while the app runs (WidgetActionReceiver.kt), or as a
/// `nononsense://widget/...` link that started it ([PlaylistLinks.widgetPress]), run once signed in.
class HomeScreenWidget {
  final Player player;
  final Library library;
  final Auth auth;
  final ValueListenable<Color?> accent; // the playing cover's colour (main.dart's accent)
  HomeScreenWidget(this.player, this.library, this.auth, this.accent);

  static const _channel = MethodChannel('nononsense/widget');
  static const _provider = 'dev.nononsense.nononsense.NowPlayingWidget';

  Timer? _soon;
  String? _sent; // the state last stored: an unchanged one is not written again
  String? _coverUrl; // the cover the stored file holds
  String? _coverPath;
  final _http = http.Client();

  void start() {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'press') return;
      final a = WidgetAction.parse(call.arguments as String);
      if (a != null) await run(a);
    });
    for (final l in _followed) {
      l.addListener(_changed);
    }
    _changed();
  }

  List<Listenable> get _followed => [player, library, auth, accent, PlaylistLinks.widgetPress];

  void dispose() {
    _soon?.cancel();
    for (final l in _followed) {
      l.removeListener(_changed);
    }
    _http.close();
  }

  void _changed() {
    _runPending();
    // The player tells of every queue, panel and buffering change: one write after a burst of them is enough.
    _soon ??= Timer(const Duration(milliseconds: 250), () {
      _soon = null;
      unawaited(_write());
    });
  }

  /// A press that started the app waits for the account, and a resume for the library to load.
  void _runPending() {
    final a = PlaylistLinks.widgetPress.value;
    if (a == null || auth.user == null) return;
    if ((a.kind == 'resume' || a.kind == 'toggle') && library.recent.isEmpty) return;
    PlaylistLinks.widgetPress.value = null;
    unawaited(run(a));
  }

  Future<void> run(WidgetAction a) async {
    switch (a.kind) {
      case 'toggle':
        player.current == null ? _resume() : player.togglePlayPause();
      case 'next':
        await player.next();
      case 'previous':
        await player.previous();
      case 'back10':
        if (player.current != null) await player.seekBy(-10);
      case 'forward10':
        if (player.current != null) await player.seekBy(10);
      case 'like':
        final t = player.current;
        if (t != null) await library.toggleLike(t);
      case 'resume':
        _resume();
    }
  }

  void _resume() {
    final recent = library.recent.map((s) => s.track).toList();
    if (recent.isNotEmpty) player.play(recent);
  }

  Future<void> _write() async {
    final signedIn = auth.user != null;
    final recent = library.recent.map((s) => s.track).toList();
    final current = player.current;
    final cover = signedIn ? await _cover((current ?? recent.firstOrNull)?.image) : null;
    final state = jsonEncode(HomeWidgetState.of(
      signedIn: signedIn,
      current: current,
      playing: player.isPlaying,
      liked: current != null && library.isLiked(current),
      recent: recent,
      coverPath: cover,
      song: accent.value,
    ));
    if (state == _sent) return;
    _sent = state;
    try {
      await HomeWidget.saveWidgetData<String>('state', state);
      await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
    } catch (e) {
      debugPrint('widget not updated: $e');
    }
  }

  /// The cover as a file the widget can read: a download's kept cover, else fetched once per song.
  Future<String?> _cover(String? url) async {
    if (url == null || url.isEmpty) return null;
    if (url == _coverUrl) return _coverPath;
    final kept = DownloadStore.shared.keptCover(url);
    if (kept != null) return _remember(url, kept.path);
    try {
      // the widget's cover is at most ~100 dp: 300 px, not the 1200 px the server names (#27)
      final r = await _http.get(Uri.parse(sizedImage(url, 300))).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/widget');
      await dir.create(recursive: true);
      // A new name for each cover: the widget may still be drawing the old file while this one is written.
      final f = File('${dir.path}/cover-${DateTime.now().millisecondsSinceEpoch}');
      await f.writeAsBytes(r.bodyBytes);
      for (final old in dir.listSync().whereType<File>().where((o) => o.path != f.path)) {
        try { old.deleteSync(); } catch (_) {}
      }
      return _remember(url, f.path);
    } catch (_) {
      return null; // offline: the widget shows no cover
    }
  }

  String _remember(String url, String path) {
    _coverUrl = url;
    return _coverPath = path;
  }
}
