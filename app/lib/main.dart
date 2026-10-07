import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;

import 'core/library.dart';
import 'core/player.dart';
import 'ui/scope.dart';
import 'ui/shell.dart';

/// NoNonsense Music for Windows (and, from the same code, Android; a Mac build is for previewing here).
/// The Mac app (mac/) is the reference: same layout, behaviour and rules; Windows' own materials, icons and font.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (Platform.isWindows) {
    await Window.initialize();
    final dark = SchedulerBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    await Window.setEffect(effect: WindowEffect.mica, dark: dark);
  }
  runApp(NoNonsenseApp(player: Player(), library: Library()));
}

class NoNonsenseApp extends StatelessWidget {
  final Player player;
  final Library library;
  const NoNonsenseApp({super.key, required this.player, required this.library});

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
        child: MaterialApp(
          title: 'NoNonsense',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: const Shell(),
        ),
      );
}
