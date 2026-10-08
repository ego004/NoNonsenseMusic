import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'home.dart';
import 'now_playing.dart';
import 'player_bar.dart';
import 'playlist_screen.dart';
import 'scope.dart';
import 'screens.dart';
import 'settings_screen.dart';
import 'sidebar.dart';

enum Section { home, search, liked, recent, playlist, settings }

/// The window: the sidebar, the chosen screen, the floating player bar, and Now Playing over everything when open.
/// Space plays and pauses, ← → seek 5 s (not while typing), as on the Mac.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  Section section = Section.home;
  String? playlistId;

  void _open(Section sec, {String? playlist}) {
    setState(() { section = sec; playlistId = playlist; });
    if (sec == Section.liked || sec == Section.recent || sec == Section.home) Scope.of(context).library.refresh();
  }

  // once, when the window opens. It was in didChangeDependencies, which runs again whenever anything the shell reads
  // changes (the theme, once per song since the accent follows the cover; the window's size): 266 /playlists in an
  // evening (8 Oct)
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) Scope.of(context).library.refresh(); });
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
            Container(
              width: 232,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: Platform.isWindows ? 0.02 : 0.035),
                border: Border(right: BorderSide(color: theme.colorScheme.onSurface.withValues(alpha: 0.06))),
              ),
              padding: const EdgeInsets.fromLTRB(10, 44, 10, 12),
              child: ListenableBuilder(
                listenable: s.library,
                builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final (sec, icon, label) in [
                    (Section.home, FluentIcons.home_24_regular, 'Home'),
                    (Section.search, FluentIcons.search_24_regular, 'Search'),
                    (Section.liked, FluentIcons.heart_24_regular, 'Liked Songs'),
                    (Section.recent, FluentIcons.history_24_regular, 'Recently Played'),
                  ])
                    SideItem(icon: icon, label: label, selected: section == sec, onTap: () => _open(sec)),
                  const SideHeading('Playlists'),
                  Expanded(
                    child: ListView(children: [
                      for (final p in s.library.ownPlaylists)
                        SideItem(icon: FluentIcons.music_note_2_24_regular, label: p.name, selected: section == Section.playlist && playlistId == p.id,
                            onTap: () => _open(Section.playlist, playlist: p.id)),
                      SideItem(icon: FluentIcons.add_24_regular, label: 'New Playlist', selected: false, onTap: () async {
                        final name = await askName(context, title: 'New Playlist');
                        if (name != null) await s.library.createPlaylist(name);
                      }),
                      // shared with you, under your own (AUTH-3): someone else's, you a viewer or an editor
                      if (s.library.sharedPlaylists.isNotEmpty) const SideHeading('Shared with you'),
                      for (final p in s.library.sharedPlaylists)
                        SideItem(icon: FluentIcons.people_24_regular, label: p.name, selected: section == Section.playlist && playlistId == p.id,
                            onTap: () => _open(Section.playlist, playlist: p.id)),
                    ]),
                  ),
                  SideItem(icon: FluentIcons.settings_24_regular, label: 'Settings', selected: section == Section.settings, onTap: () => _open(Section.settings)),
                ]),
              ),
            ),
            Expanded(
              child: switch (section) {
                Section.home => Home(openPlaylist: (id) => _open(Section.playlist, playlist: id)),
                Section.search => const SearchScreen(),
                Section.liked => const SongListScreen(liked: true),
                Section.recent => const SongListScreen(liked: false),
                Section.playlist => PlaylistScreen(key: ValueKey(playlistId), id: playlistId!, onDeleted: () => _open(Section.home)),
                Section.settings => const SettingsScreen(),
              },
            ),
          ]),
          const Positioned(left: 256, right: 24, bottom: 18, child: Center(child: PlayerBar())),
          // the player's messages ("Couldn't play …"), just above the bar
          Positioned(
            left: 256, right: 24, bottom: 104,
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
