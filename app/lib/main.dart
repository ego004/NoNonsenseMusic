// NoNonsense Music for Windows, and from the same code Android; a Mac build exists for previewing.
// The Mac app (mac/) is the reference: same layout, behaviour and rules, with Windows' own materials, icons and
// font.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

import 'core/api.dart';
import 'core/audio_cache.dart';
import 'core/auth.dart';
import 'core/download_store.dart';
import 'core/home_screen_widget.dart';
import 'core/discord.dart';
import 'core/library.dart';
import 'core/links.dart';
import 'core/lyrics.dart';
import 'core/media_controls.dart';
import 'core/player.dart';
import 'core/jam.dart';
import 'core/settings.dart';
import 'core/social.dart';
import 'core/accent.dart';
import 'ui/in_front.dart';
import 'ui/theme.dart';
import 'ui/scope.dart';
import 'ui/shell.dart';
import 'ui/sign_in.dart';

/// The accent colour, following the cover of the playing song (Settings' "song" accent, as on the Mac).
final accent = Accent();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PlaylistLinks.start(); // Started early: the link that opened the app is not missed.
  final settings = Settings();
  await settings.load();
  try {
    await AudioCache.shared.open();
    AudioCache.shared.limitMB = settings.audioCacheMB;
    await DownloadStore.shared.load();
  } catch (e) {
    debugPrint('audio storage unavailable, songs play from the network: $e'); // the cache and downloads stay off
  }
  if (Platform.isWindows) await Window.initialize();
  await MediaControls.initialize(); // Windows' media keys, Android's media session: each platform's own, nothing elsewhere
  final player = Player();
  player.currentId.addListener(() => accent.follow(player.current?.image));
  final library = Library()..playlistChanged = player.playlistChanged;
  await Presence.shared.load(); // The Discord status is off by default; it follows the player from here.
  Presence.shared.follow(player, library);
  // A session that ends stops the music and empties the library: nothing of one account shows to the next.
  final auth = Auth()..onEnded = () { JamSession.shared.leaveLocally(); Social.shared.stop(); player.stop(); library.clear(); };
  final started = auth.start(); // The stored token, checked with the server: the sign-in screen or the app.
  MediaControls(player).start();
  HomeScreenWidget(player, library, auth, accent).start(); // Android's home-screen widget
  settings.addListener(() => applyMaterial(settings.material));
  await applyMaterial(settings.material);
  watchInFront();
  // Measurement only: the window reports itself as behind after two seconds; BEHIND is unset in a normal build.
  if (const bool.fromEnvironment('BEHIND')) Timer(const Duration(seconds: 2), () => inFront.value = false);
  final lyrics = LyricsStore();
  DownloadStore.shared.onDownloaded = lyrics.keep; // offline lyrics, as the Mac keeps them
  unawaited(DownloadStore.shared.keepMissingCovers()); // covers of downloads made before covers were kept
  runApp(NoNonsenseApp(player: player, library: library, lyrics: lyrics, settings: settings, auth: auth));
  // Measurement only (--dart-define=AUTOPLAY=<search>, NOW_PLAYING=lyrics|upNext): plays the first result, muted,
  // so CPU can be read while a song plays without the user touching it. Not set in a normal build.
  const autoplay = String.fromEnvironment('AUTOPLAY');
  if (autoplay.isNotEmpty) {
    await started; // Signed in already, from a stored token: measurement never signs in for the user.
    player.setVolume(0);
    var found = await Api.search(autoplay);
    // The source of the copy to play; the track's best copy is used when this source has none.
    const source = String.fromEnvironment('AUTOPLAY_SOURCE');
    if (source.isNotEmpty) found = [for (final t in found.take(1)) t.playing(t.listings.firstWhere((l) => l.source == source, orElse: () => t.best))];
    player.play(found);
    // Evidence that it plays: a low reading from a song that never started would mean nothing.
    for (final at in [8, 20, 38]) {
      Timer(Duration(seconds: at), () => stdout.writeln('AUTOPLAY ${at}s: playing ${player.isPlaying}, buffering ${player.isBuffering}, at ${player.position.toStringAsFixed(1)} of ${player.duration.toStringAsFixed(0)} s, ${player.current?.title}, window in front ${inFront.value}, message ${player.message}'));
    }
    const panel = String.fromEnvironment('NOW_PLAYING');
    if (panel.isNotEmpty) {
      player.panel = panel;
      player.setShowNowPlaying(true);
    }
  }
}

/// Sets the window's background to the material [m]: Acrylic, Mica or solid, drawn by Windows itself.
///
/// Platforms other than Windows return unchanged. The platform's brightness picks the tint.
Future<void> applyMaterial(WindowMaterial m) async {
  if (!Platform.isWindows) return;
  final dark = SchedulerBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  final effect = switch (m) { WindowMaterial.acrylic => WindowEffect.acrylic, WindowMaterial.mica => WindowEffect.mica, WindowMaterial.solid => WindowEffect.solid };
  await Window.setEffect(effect: effect, dark: dark, color: m == WindowMaterial.acrylic ? (dark ? const Color(0xAA1C1C1C) : const Color(0xAAF3F3F3)) : Colors.transparent);
}

class NoNonsenseApp extends StatelessWidget {
  final Player player;
  final Library library;
  final LyricsStore lyrics;
  final Settings settings;
  final Auth auth;
  const NoNonsenseApp({super.key, required this.player, required this.library, required this.lyrics, required this.settings, required this.auth});

  @override
  Widget build(BuildContext context) {
    lyrics.follow(player); // Asks for each song's lyrics as it starts; a second call for the same player returns.
    return Scope(
        player: player,
        library: library,
        lyrics: lyrics,
        settings: settings,
        auth: auth,
        // The accent follows the playing cover: the theme is rebuilt once per song, never per second.
        child: ValueListenableBuilder<Color?>(
          valueListenable: accent,
          builder: (context, song, _) => ListenableBuilder(listenable: settings, builder: (context, _) => MaterialApp(
            title: 'NoNonsenseMusic',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light, song),
            darkTheme: buildTheme(Brightness.dark, song),
            home: AuthGate(auth: auth, settings: settings, signedIn: (_) => const Shell()),
            // Settings › Appearance: light, dark or the system's theme, and the size of all the text.
            themeMode: settings.theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(settings.textScale)),
              child: child!,
            ),
          )),
        ),
      );
  }
}
