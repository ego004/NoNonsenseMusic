import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'now_playing.dart';
import 'player_bar.dart';
import 'scope.dart';
import 'screens.dart';

enum Section { search, liked, recent }

/// The window: the sidebar, the chosen screen, the floating player bar, and Now Playing over everything when open.
/// Space plays and pauses, ← → seek 5 s (not while typing), as on the Mac.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  Section section = Section.search;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Scope.of(context).library.refresh();
  }

  bool _typing() => FocusManager.instance.primaryFocus?.context?.widget is EditableText;

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () { if (!_typing()) s.player.togglePlayPause(); },
        const SingleActivator(LogicalKeyboardKey.arrowRight): () { if (!_typing()) s.player.seekBy(5); },
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () { if (!_typing()) s.player.seekBy(-5); },
      },
      child: Scaffold(
        // Windows: see-through, so Mica (drawn by Windows itself, at no cost to the app) shows behind everything
        backgroundColor: Platform.isWindows ? Colors.transparent : theme.colorScheme.surface,
        body: Stack(children: [
          Row(children: [
            // a Material, not a coloured box: list rows draw their highlight on the Material under them
            Material(
              color: theme.colorScheme.onSurface.withValues(alpha: Platform.isWindows ? 0.03 : 0.05),
              child: Container(
              width: 220,
              padding: const EdgeInsets.fromLTRB(10, 40, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final (sec, icon, label) in [
                  (Section.search, FluentIcons.search_24_regular, 'Search'),
                  (Section.liked, FluentIcons.heart_24_regular, 'Liked Songs'),
                  (Section.recent, FluentIcons.history_24_regular, 'Recently Played'),
                ])
                  ListTile(
                    dense: true,
                    selected: section == sec,
                    selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    leading: Icon(icon, size: 20),
                    title: Text(label),
                    onTap: () { setState(() => section = sec); if (sec != Section.search) s.library.refresh(); },
                  ),
              ]),
            ),
            ),
            Expanded(
              child: switch (section) {
                Section.search => const SearchScreen(),
                Section.liked => const SongListScreen(liked: true),
                Section.recent => const SongListScreen(liked: false),
              },
            ),
          ]),
          const Positioned(left: 244, right: 24, bottom: 18, child: Center(child: PlayerBar())),
          // the player's messages ("Couldn't play …"), just above the bar
          Positioned(
            left: 244, right: 24, bottom: 100,
            child: ListenableBuilder(
              listenable: s.player,
              builder: (context, _) => s.player.message == null
                  ? const SizedBox.shrink()
                  : Center(child: Chip(avatar: const Icon(FluentIcons.warning_24_filled, size: 16), label: Text(s.player.message!))),
            ),
          ),
          ListenableBuilder(
            listenable: s.player,
            builder: (context, _) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: s.player.showNowPlaying ? const NowPlaying() : const SizedBox.shrink(),
            ),
          ),
        ]),
      ),
    );
  }
}
