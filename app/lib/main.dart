import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;

import 'core/api.dart';
import 'core/library.dart';
import 'core/lyrics.dart';
import 'core/media_controls.dart';
import 'core/player.dart';
import 'core/settings.dart';
import 'ui/scope.dart';
import 'ui/shell.dart';

/// NoNonsense Music for Windows (and, from the same code, Android; a Mac build is for previewing here).
/// The Mac app (mac/) is the reference: same layout, behaviour and rules; Windows' own materials, icons and font.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final settings = Settings();
  await settings.load();
  if (Platform.isWindows) {
    await Window.initialize();
    await MediaControls.initialize();
  }
  final player = Player();
  final library = Library()..playlistChanged = player.playlistChanged;
  MediaControls(player).start();
  settings.addListener(() => applyMaterial(settings.material));
  await applyMaterial(settings.material);
  runApp(NoNonsenseApp(player: player, library: library, lyrics: LyricsStore(), settings: settings));
  // measuring only (--dart-define=AUTOPLAY=<search>, NOW_PLAYING=lyrics|upNext): plays the first result, muted, so
  // CPU can be read while a song plays without anyone touching the app. Not in normal builds.
  const autoplay = String.fromEnvironment('AUTOPLAY');
  if (autoplay.isNotEmpty) {
    player.setVolume(0);
    player.play(await Api.search(autoplay));
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
  const NoNonsenseApp({super.key, required this.player, required this.library, required this.lyrics, required this.settings});

  ThemeData _theme(Brightness b) => ThemeData(
        brightness: b,
        colorSchemeSeed: const Color(0xFF6E6AE8),
        // Segoe UI Variable on Windows (SF Pro is for Apple's platforms only); the system's own font elsewhere
        fontFamily: Platform.isWindows ? 'Segoe UI Variable Text' : null,
        visualDensity: VisualDensity.compact,
      );

  @override
  Widget build(BuildContext context) => Scope(
        player: player,
        library: library,
        lyrics: lyrics,
        settings: settings,
        child: MaterialApp(
          title: 'NoNonsense',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: const Shell(),
        ),
      );
}
