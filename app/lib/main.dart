import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

import 'core/api.dart';
import 'core/auth.dart';
import 'core/library.dart';
import 'core/lyrics.dart';
import 'core/media_controls.dart';
import 'core/player.dart';
import 'core/settings.dart';
import 'core/accent.dart';
import 'ui/in_front.dart';
import 'ui/theme.dart';
import 'ui/scope.dart';
import 'ui/shell.dart';
import 'ui/sign_in.dart';

/// NoNonsense Music for Windows (and, from the same code, Android; a Mac build is for previewing here).
/// The Mac app (mac/) is the reference: same layout, behaviour and rules; Windows' own materials, icons and font.
/// The playing cover's colour (Settings' "song" accent, as on the Mac).
final accent = Accent();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings();
  await settings.load();
  if (Platform.isWindows) {
    await Window.initialize();
    await MediaControls.initialize();
  }
  final player = Player();
  player.currentId.addListener(() => accent.follow(player.current?.image));
  final library = Library()..playlistChanged = player.playlistChanged;
  // a session that ends stops the music and empties the library: nothing of one account shows to the next
  final auth = Auth()..onEnded = () { player.stop(); library.clear(); };
  final started = auth.start(); // the stored token, checked with the server: the sign-in screen or the app
  MediaControls(player).start();
  settings.addListener(() => applyMaterial(settings.material));
  await applyMaterial(settings.material);
  watchInFront();
  if (const bool.fromEnvironment('BEHIND')) Timer(const Duration(seconds: 2), () => inFront.value = false); // measuring only
  runApp(NoNonsenseApp(player: player, library: library, lyrics: LyricsStore(), settings: settings, auth: auth));
  // measuring only (--dart-define=AUTOPLAY=<search>, NOW_PLAYING=lyrics|upNext): plays the first result, muted, so
  // CPU can be read while a song plays without anyone touching the app. Not in normal builds.
  const autoplay = String.fromEnvironment('AUTOPLAY');
  if (autoplay.isNotEmpty) {
    await started; // signed in already (a stored token): measuring never signs in by itself
    player.setVolume(0);
    var found = await Api.search(autoplay);
    const source = String.fromEnvironment('AUTOPLAY_SOURCE'); // a copy from this source only
    if (source.isNotEmpty) found = [for (final t in found.take(1)) t.playing(t.listings.firstWhere((l) => l.source == source, orElse: () => t.best))];
    player.play(found);
    // evidence that it plays: low CPU from a song that never started would mean nothing
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

/// The window's background (Windows): Acrylic, Mica or solid, drawn by Windows itself.
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
    lyrics.follow(player); // each song's lyrics asked for as it starts (once; later builds do nothing)
    return Scope(
        player: player,
        library: library,
        lyrics: lyrics,
        settings: settings,
        auth: auth,
        // the accent follows the playing cover: the theme is rebuilt once per song, never per second
        child: ValueListenableBuilder<Color?>(
          valueListenable: accent,
          builder: (context, song, _) => ListenableBuilder(listenable: settings, builder: (context, _) => MaterialApp(
            title: 'NoNonsense',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light, song),
            darkTheme: buildTheme(Brightness.dark, song),
            home: AuthGate(auth: auth, settings: settings, signedIn: (_) => const Shell()),
            // Settings › Appearance: light, dark or the system's; and the size of all text
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
