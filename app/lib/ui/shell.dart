import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/jam.dart';
import '../core/links.dart';
import '../core/social.dart';
import '../core/update_check.dart';

import 'browse_nav.dart';
import 'friends.dart';
import 'glass.dart';
import 'home.dart';
import 'layout.dart';
import 'now_playing.dart';
import 'player_bar.dart';
import 'playlist_screen.dart';
import 'scope.dart';
import 'screens.dart';
import 'settings_screen.dart';
import 'sidebar.dart';
import 'top_bar.dart';

enum Section { home, search, liked, recent, downloads, friends, playlist, settings }

/// Composes the window: the sidebar, the selected screen, the floating player bar, and Now Playing over everything
/// when it is open.
///
/// Space plays and pauses and the left and right arrows seek five seconds, as on the Mac. Shortcuts do not fire
/// while the user is typing.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  Section section = Section.home;
  String? playlistId;

  /// The phone's floating bottom area, measured: lists end above it (BottomArea, bottomClearance).
  double _bottomArea = 0;

  void _open(Section sec, {String? playlist}) {
    BrowseNav.shared
        .clear(); // choosing a sidebar item starts afresh, as on the Mac
    setState(() {
      section = sec;
      playlistId = playlist;
    });
    if (sec == Section.liked || sec == Section.recent || sec == Section.home) {
      Scope.of(context).library.refresh();
    }
  }

  // Runs once, when the window opens. Reading these values in didChangeDependencies would run it again whenever
  // anything the shell reads changes (the theme, once per song since the accent follows the cover; the window's
  // size), which produces 266 /playlists requests in an evening.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Scope.of(context).library.refresh();
    });
    // A pending playlist link (PlaylistLinks) opens here, including one that arrived before the user signed in.
    PlaylistLinks.pending.addListener(_openLink);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openLink());
    WidgetsBinding.instance.addPostFrameCallback((_) => _goOnline());
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerUpdate());
  }

  /// "NoNonsenseMusic 0.3.0 is available": Download opens the release page; Skip This Version is not offered again.
  Future<void> _offerUpdate() async {
    final settings = Scope.of(context).settings;
    if (!settings.checkUpdates) return;
    final current = (await PackageInfo.fromPlatform()).version;
    final update = await checkForUpdate(
      current: current,
      skipped: settings.skippedUpdate,
    );
    if (update == null || !mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('NoNonsenseMusic ${update.version} is available'),
        content: Text(
          'You have $current. The release page has the download and what is new.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'skip'),
            child: const Text('Skip This Version'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Not Now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'download'),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (choice == 'download') {
      await launchUrl(update.page, mode: LaunchMode.externalApplication);
    }
    if (choice == 'skip') await settings.skipUpdate(update.version);
  }

  /// Friends, notifications and jams are live from sign-in on (main.dart stops them at sign-out).
  void _goOnline() {
    if (!mounted) return;
    final s = Scope.of(context);
    JamSession.shared
      ..player = s.player
      ..me = s.auth.user?.id
      ..addListener(_sayJamEnded);
    Social.shared.start();
  }

  /// A jam this device did not leave itself has ended for it: said once, wherever the user is.
  void _sayJamEnded() {
    final notice = JamSession.shared.ended;
    if (notice == null || !mounted) return;
    JamSession.shared.ended = null;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(notice)));
  }

  void _openLink() {
    final id = PlaylistLinks.pending.value;
    if (id == null || !mounted) return;
    PlaylistLinks.pending.value = null;
    Scope.of(context).player.setShowNowPlaying(false);
    _open(Section.playlist, playlist: id);
  }

  @override
  void dispose() {
    PlaylistLinks.pending.removeListener(_openLink);
    JamSession.shared.removeListener(_sayJamEnded);
    super.dispose();
  }

  /// Whether a text field has the keyboard. Its focus node belongs to the Focus widget inside the EditableText, not to
  /// the EditableText itself, so the field is looked for above the focused widget.
  bool _typing() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  /// Space plays or pauses, → and â† move 5 s, unless a text field has the keyboard: then the key is the field's. The
  /// key is left unhandled there (CallbackShortcuts would mark it handled even when it does nothing, and a handled key
  /// never reaches the field: a space typed into Search paused the song instead).
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    final keys = HardwareKeyboard.instance;
    if ((e is! KeyDownEvent && e is! KeyRepeatEvent) ||
        _typing() ||
        keys.isControlPressed ||
        keys.isAltPressed ||
        keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final p = Scope.of(context).player;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.space when e is KeyDownEvent:
        p.togglePlayPause();
      case LogicalKeyboardKey.arrowRight:
        p.seekBy(5);
      case LogicalKeyboardKey.arrowLeft:
        p.seekBy(-5);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    final phone = isPhone(context);
    // the phone's bottom bar steps aside while the keyboard is up, so the player bar sits just above the keyboard
    final showNav = phone && MediaQuery.viewInsetsOf(context).bottom == 0;
    // the player's messages ("Couldn't play …"), shown above the bar
    final message = ListenableBuilder(
      listenable: s.player,
      builder: (context, _) => s.player.message == null
          ? const SizedBox.shrink()
          : Center(
              child: Chip(
                avatar: const Icon(FluentIcons.warning_24_filled, size: 16),
                label: Text(s.player.message!),
              ),
            ),
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        // Transparent on Windows so Mica, drawn by the system at no cost to the app, shows behind everything
        backgroundColor: Platform.isWindows || phone
            ? Colors.transparent
            : theme.colorScheme.surface,
        body: BottomArea(
          height: phone ? _bottomArea : 0,
          child: Stack(
            children: [
              if (phone) const Positioned.fill(child: PhoneBackdrop()),
              Row(
                children: [
                  if (!phone)
                    Container(
                      width: 232,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: Platform.isWindows ? 0.02 : 0.035,
                        ),
                        border: Border(
                          right: BorderSide(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.06,
                            ),
                          ),
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(10, 44, 10, 12),
                      child: ListenableBuilder(
                        listenable: s.library,
                        builder: (context, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final (sec, icon, label) in [
                              (
                                Section.home,
                                FluentIcons.home_24_regular,
                                'Home',
                              ),
                              (
                                Section.search,
                                FluentIcons.search_24_regular,
                                'Search',
                              ),
                              (
                                Section.liked,
                                FluentIcons.heart_24_regular,
                                'Liked Songs',
                              ),
                              (
                                Section.recent,
                                FluentIcons.history_24_regular,
                                'Recently Played',
                              ),
                              // from this device: there with no server or internet (the phone's bar has no room;
                              // Settings › Storage counts them)
                              (
                                Section.downloads,
                                FluentIcons.arrow_download_24_regular,
                                'Downloads',
                              ),
                              (
                                Section.friends,
                                FluentIcons.people_24_regular,
                                'Friends',
                              ),
                            ])
                              SideItem(
                                icon: icon,
                                label: label,
                                selected: section == sec,
                                onTap: () => _open(sec),
                                trailing: sec == Section.friends
                                    ? RequestCount()
                                    : null,
                              ),
                            const SideHeading('Playlists'),
                            Expanded(
                              child: ListView(
                                children: [
                                  for (final p in s.library.ownPlaylists)
                                    SideItem(
                                      icon: p.isAlbum
                                          ? FluentIcons.album_24_regular
                                          : FluentIcons.music_note_2_24_regular,
                                      label: p.name,
                                      selected:
                                          section == Section.playlist &&
                                          playlistId == p.id,
                                      onTap: () => _open(
                                        Section.playlist,
                                        playlist: p.id,
                                      ),
                                    ),
                                  SideItem(
                                    icon: FluentIcons.add_24_regular,
                                    label: 'New Playlist',
                                    selected: false,
                                    onTap: () async {
                                      final name = await askName(
                                        context,
                                        title: 'New Playlist',
                                      );
                                      if (name != null) {
                                        await s.library.createPlaylist(name);
                                      }
                                    },
                                  ),
                                  // Shared playlists sit under the user's own: another owner's, with the user as viewer or editor
                                  if (s.library.sharedPlaylists.isNotEmpty)
                                    const SideHeading('Shared with you'),
                                  for (final p in s.library.sharedPlaylists)
                                    SideItem(
                                      icon: FluentIcons.people_24_regular,
                                      label: p.name,
                                      selected:
                                          section == Section.playlist &&
                                          playlistId == p.id,
                                      onTap: () => _open(
                                        Section.playlist,
                                        playlist: p.id,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            SideItem(
                              icon: FluentIcons.settings_24_regular,
                              label: 'Settings',
                              selected: section == Section.settings,
                              onTap: () => _open(Section.settings),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: TopBarFrame(
                      child: BrowseHost(
                        child: AnimatedSwitcher(
                          duration:
                              phone && !MediaQuery.disableAnimationsOf(context)
                              ? const Duration(milliseconds: 240)
                              : Duration.zero,
                          transitionBuilder: (child, animation) => phone
                              ? phoneRevealTransition(
                                  child,
                                  animation,
                                  dy: 0.025,
                                )
                              : child,
                          child: KeyedSubtree(
                            key: ValueKey('${section.name}/$playlistId'),
                            child: switch (section) {
                              Section.home => Home(
                                openPlaylist: (id) =>
                                    _open(Section.playlist, playlist: id),
                              ),
                              Section.search => const SearchScreen(),
                              Section.liked => const SongListScreen(
                                liked: true,
                              ),
                              Section.recent => const SongListScreen(
                                liked: false,
                              ),
                              Section.downloads => const SongListScreen.downloads(),
                              Section.friends => FriendsScreen(),
                              Section.playlist => PlaylistScreen(
                                key: ValueKey(playlistId),
                                id: playlistId!,
                                onDeleted: () => _open(Section.home),
                              ),
                              Section.settings => const SettingsScreen(),
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // a desktop window: the bar floats over the content, its messages above it
              if (!phone) ...[
                const Positioned(
                  left: 256,
                  right: 24,
                  bottom: 18,
                  child: Center(child: PlayerBar()),
                ),
                Positioned(left: 256, right: 24, bottom: 104, child: message),
              ],
              // a phone: the messages, the player bar and the bottom bar in one column, each on top of the next whatever
              // its real height (the system's gesture area, larger text). Placed by a fixed offset, the bar sat partly
              // under the bottom bar and its buttons took no taps
              if (phone)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: MeasureHeight(
                    onHeight: (h) {
                      if (mounted && h != _bottomArea) {
                        setState(() => _bottomArea = h);
                      }
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                          child: message,
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: AnimatedSize(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                            child: const Center(child: PlayerBar()),
                          ),
                        ),
                        if (showNav)
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              8,
                              0,
                              8,
                              MediaQuery.paddingOf(context).bottom + 6,
                            ),
                            child: GlassSurface(
                              radius: 28,
                              // the bar pads itself by the system's insets, top and bottom; the bottom one is already
                              // given above, and the status bar's stood as an empty band over the icons (13 Oct)
                              child: MediaQuery.removePadding(
                                context: context,
                                removeTop: true,
                                removeBottom: true,
                                child: NavigationBar(
                                selectedIndex: switch (section) {
                                  Section.home => 0,
                                  Section.search => 1,
                                  Section.liked => 2,
                                  Section.recent => 3,
                                  Section.friends => 4,
                                  _ => 5,
                                },
                                onDestinationSelected: (index) =>
                                    _open(switch (index) {
                                      0 => Section.home,
                                      1 => Section.search,
                                      2 => Section.liked,
                                      3 => Section.recent,
                                      4 => Section.friends,
                                      _ => Section.settings,
                                    }),
                                destinations: [
                                  const NavigationDestination(
                                    icon: Icon(FluentIcons.home_24_regular),
                                    label: 'Home',
                                  ),
                                  NavigationDestination(
                                    icon: Icon(FluentIcons.search_24_regular),
                                    label: 'Search',
                                  ),
                                  NavigationDestination(
                                    icon: Icon(FluentIcons.heart_24_regular),
                                    label: 'Liked',
                                  ),
                                  NavigationDestination(
                                    icon: Icon(FluentIcons.history_24_regular),
                                    label: 'Recent',
                                  ),
                                  NavigationDestination(
                                    icon: FriendsNavIcon(),
                                    label: 'Friends',
                                  ),
                                  const NavigationDestination(
                                    icon: Icon(FluentIcons.settings_24_regular),
                                    label: 'Settings',
                                  ),
                                ],
                              ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              // Now Playing last: over everything, the phone's bottom bar too (it covered Now Playing's controls). Back
              // closes it rather than the app: it is a layer of this screen, not a page of its own
              ListenableBuilder(
                listenable: s.player,
                builder: (context, _) => PopScope(
                  canPop: !s.player.showNowPlaying,
                  onPopInvokedWithResult: (didPop, _) {
                    if (!didPop) s.player.setShowNowPlaying(false);
                  },
                  child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : Duration(milliseconds: phone ? 340 : 180),
                  reverseDuration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : Duration(milliseconds: phone ? 280 : 180),
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, ?current],
                  ),
                  transitionBuilder: (child, animation) => phone
                      ? phoneRevealTransition(child, animation, dy: 0.12)
                      : FadeTransition(opacity: animation, child: child),
                  child: s.player.showNowPlaying
                      ? const NowPlaying(key: ValueKey('open-now-playing'))
                      : const SizedBox.shrink(
                          key: ValueKey('closed-now-playing'),
                        ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
