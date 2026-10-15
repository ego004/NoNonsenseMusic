import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/jam.dart';
import '../core/links.dart';
import '../core/social.dart';
import '../core/settings.dart';
import '../core/update_check.dart';

import 'browse_nav.dart';
import 'command_bar.dart';
import 'friends.dart';
import 'glass.dart';
import 'home.dart';
import 'layout.dart';
import 'now_playing.dart';
import 'player_bar.dart';
import 'playlist_screen.dart';
import 'redesign.dart';
import 'scope.dart';
import 'screens.dart';
import 'settings_screen.dart';
import 'top_bar.dart';
import 'glass_menu.dart';

enum Section { home, search, library, liked, recent, downloads, friends, playlist, settings }

/// UI v2: the floating sidebar's width; the player bar is centred over what is beside it.
const sidebarWidth = 252.0;

/// UI v2 (15 Oct): the widest the page beside the sidebar grows, centred in a wider window (1440 inside its margins):
/// at 1920 a line ran 1350 pixels and the shelves to the window's edge.
const maxPageWidth = 1504.0;

/// Composes the window: the sidebar, the selected screen, the floating player bar, and Now Playing over everything
/// when it is open.
///
/// Space plays and pauses and the left and right arrows seek five seconds, as on the Mac; with Ctrl, the arrows skip
/// songs (← →) and set the volume (↑ ↓); L likes the song playing, M mutes, and Ctrl+K or / opens the command bar.
/// Shortcuts do not fire while the user is typing.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  Section section = Section.home;
  String? playlistId;

  /// What the command bar's "All results" asked the Search page for.
  String _query = '';

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
    HardwareKeyboard.instance.addHandler(_keyHeard);
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
    final choice = await showGlassDialog<String>(
      context: context,
      builder: (c) => GlassDialog(
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
    HardwareKeyboard.instance.removeHandler(_keyHeard);
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

  /// The app's keys, heard by the keyboard itself rather than a focused widget: they work from the moment the window
  /// opens, whatever was clicked last (15 Oct: heard by a Focus around the window, Space did nothing until something in
  /// it had the keyboard). Space plays or pauses, ← → move 5 s, Ctrl+← → skip, Ctrl+↑ ↓ set the volume, L likes, M mutes,
  /// / opens the command bar. Not while a text field has the keyboard (the key is the field's; a space typed into
  /// Search once paused the song) nor while a dialog or menu is open over the window. Ctrl+K works while typing too: the
  /// command bar takes the keyboard, or on the Search page, which has no bar, Search opens.
  bool _keyHeard(KeyEvent e) {
    if (!mounted || (e is! KeyDownEvent && e is! KeyRepeatEvent)) return false;
    final keys = HardwareKeyboard.instance;
    if (keys.isAltPressed || keys.isMetaPressed || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final ctrl = keys.isControlPressed;
    final down = e is KeyDownEvent;
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyK) {
      if (!down || isPhone(context)) return false;
      if (!CommandBar.summon()) _open(Section.search);
      return true;
    }
    if (_typing()) return false;
    final s = Scope.of(context);
    final p = s.player;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.space when down && !ctrl:
        p.togglePlayPause();
      case LogicalKeyboardKey.arrowRight when ctrl:
        if (down) p.next();
      case LogicalKeyboardKey.arrowLeft when ctrl:
        if (down) p.previous();
      case LogicalKeyboardKey.arrowRight:
        p.seekBy(5);
      case LogicalKeyboardKey.arrowLeft:
        p.seekBy(-5);
      case LogicalKeyboardKey.arrowUp when ctrl:
        p.setVolume(p.volume + 0.05);
      case LogicalKeyboardKey.arrowDown when ctrl:
        p.setVolume(p.volume - 0.05);
      case LogicalKeyboardKey.keyL when down && !ctrl && p.current != null:
        s.library.toggleLike(p.current!);
      case LogicalKeyboardKey.keyM when down && !ctrl:
        p.toggleMute();
      case LogicalKeyboardKey.slash when down && !ctrl && !isPhone(context) && CommandBar.summon():
        break;
      default:
        return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    final phone = isPhone(context);
    // the phone's bottom bar steps aside while the keyboard is up, so the player bar sits just above the keyboard
    final showNav = phone && MediaQuery.viewInsetsOf(context).bottom == 0;
    void openCollection(Collection c) => _open(switch (c) {
          Collection.liked => Section.liked,
          Collection.recent => Section.recent,
          Collection.downloads => Section.downloads,
        });
    final places = CommandPlaces(
      home: () => _open(Section.home),
      library: () => _open(Section.library),
      friends: () => _open(Section.friends),
      settings: () => _open(Section.settings),
      collection: openCollection,
      playlist: (id) => _open(Section.playlist, playlist: id),
      search: (q) {
        _query = q;
        _open(Section.search);
      },
    );
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
    return Scaffold(
        // Transparent on Windows so Mica, drawn by the system at no cost to the app, shows behind everything
        backgroundColor: Platform.isWindows || phone
            ? Colors.transparent
            : theme.colorScheme.surface,
        body: BottomArea(
          height: phone ? _bottomArea : 0,
          child: Stack(
            children: [
              if (phone) const Positioned.fill(child: PhoneBackdrop()),
              // Clear has no blur behind it: a light veil keeps the text on the window readable over a busy desktop
              if (!phone && s.settings.material == WindowMaterial.clear)
                Positioned.fill(
                  child: ColoredBox(color: theme.colorScheme.surface.withValues(alpha: theme.brightness == Brightness.dark ? 0.35 : 0.45)),
                ),
              // UI v2 (15 Oct): the window lit by the playing cover, under everything (redesign.dart)
              if (!phone) const Positioned.fill(child: CoverGlow()),
              Row(
                children: [
                  if (!phone)
                    // UI v2 (15 Oct): the sidebar floats as a glass panel over the window's background (redesign.dart)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
                      child: SizedBox(
                        width: sidebarWidth,
                        child: DesktopSidebar(
                          shown: SidebarPlaces(
                            home: section == Section.home,
                            library: section == Section.library,
                            friends: section == Section.friends,
                            settings: section == Section.settings,
                            collection: switch (section) {
                              Section.liked => Collection.liked,
                              Section.recent => Collection.recent,
                              Section.downloads => Collection.downloads,
                              _ => null,
                            },
                            playlistId: section == Section.playlist ? playlistId : null,
                          ),
                          openHome: () => _open(Section.home),
                          openLibrary: () => _open(Section.library),
                          openFriends: () => _open(Section.friends),
                          openSettings: () => _open(Section.settings),
                          newPlaylist: () async {
                            final name = await askName(context, title: 'New Playlist');
                            if (name != null) await s.library.createPlaylist(name);
                          },
                          openCollection: (c) => _open(switch (c) {
                            Collection.liked => Section.liked,
                            Collection.recent => Section.recent,
                            Collection.downloads => Section.downloads,
                          }),
                          openPlaylist: (id) => _open(Section.playlist, playlist: id),
                        ),
                      ),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) => Center(
                        child: SizedBox(
                          width: math.min(box.maxWidth, maxPageWidth),
                          child: TopBarFrame(
                      places: section == Section.search ? null : places,
                      child: BrowseHost(
                        // the concept (13 Oct): on a computer too, one screen gives way to the next with a short fade
                        // and rise (one-shot)
                        child: AnimatedSwitcher(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : Duration(milliseconds: phone ? 240 : 260),
                          switchInCurve: phone ? Curves.linear : Curves.easeOutCubic,
                          switchOutCurve: phone ? Curves.linear : Curves.easeInCubic,
                          transitionBuilder: (child, animation) => phone
                              ? phoneRevealTransition(
                                  child,
                                  animation,
                                  dy: 0.025,
                                )
                              : FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(animation),
                                    child: child,
                                  ),
                                ),
                          child: KeyedSubtree(
                            key: ValueKey('${section.name}/$playlistId/${section == Section.search ? _query : ''}'),
                            child: switch (section) {
                              Section.home => Home(
                                openPlaylist: (id) =>
                                    _open(Section.playlist, playlist: id),
                                openRecent: () => _open(Section.recent),
                                openLibrary: () => _open(Section.library),
                                openCollection: openCollection,
                              ),
                              Section.search => SearchScreen(initial: _query),
                              Section.library => LibraryScreen(
                                openPlaylist: (id) => _open(Section.playlist, playlist: id),
                                openCollection: (c) => _open(switch (c) {
                                  Collection.liked => Section.liked,
                                  Collection.recent => Section.recent,
                                  Collection.downloads => Section.downloads,
                                }),
                              ),
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
                      ),
                    ),
                  ),
                ],
              ),
              // a desktop window: the bar floats over the content, its messages above it
              if (!phone) ...[
                const Positioned(
                  left: sidebarWidth + 24,
                  right: 24,
                  bottom: 18,
                  child: Center(child: PlayerBar()),
                ),
                Positioned(left: sidebarWidth + 24, right: 24, bottom: 104, child: message),
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
    );
  }
}
