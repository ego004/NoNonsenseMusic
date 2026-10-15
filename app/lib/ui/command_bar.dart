// UI v2 (15 Oct): the search box at the top of every page on a computer, and the keyboard's way into the whole app.
// Typing finds songs (Enter plays, Shift+Enter adds to Up Next) and the commands whose name starts that way: play,
// skip, like, lyrics, a jam, a playlist, a page. Ctrl+K or / from anywhere puts the keyboard in it; Esc leaves.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/download_store.dart';
import '../core/jam.dart';
import '../core/models.dart';
import '../core/play_queue.dart';
import '../core/reveal.dart';
import '../core/social.dart';
import 'browse_nav.dart';
import 'concept.dart';
import 'cover.dart';
import 'jam_panel.dart';
import 'playlist_screen.dart';
import 'popover.dart';
import 'redesign.dart';
import 'scope.dart';

/// The shell's places, for the commands that go to one.
class CommandPlaces {
  final VoidCallback home, library, friends, settings;
  final void Function(Collection) collection;
  final void Function(String id) playlist;
  /// The Search page, for every match of [query].
  final void Function(String query) search;
  const CommandPlaces({
    required this.home,
    required this.library,
    required this.friends,
    required this.settings,
    required this.collection,
    required this.playlist,
    required this.search,
  });
}

/// One thing the bar can do.
class Command {
  final String label;
  final IconData icon;
  final FutureOr<void> Function() run;
  /// What it acts on: the song, the artist.
  final String? detail;
  /// Its key outside the bar.
  final String? keys;
  /// Offered before anything is typed.
  final bool suggested;
  const Command(this.label, this.icon, this.run, {this.detail, this.keys, this.suggested = false});

  static final _gap = RegExp(r'[\s\-–—,.:()/&+]+');

  /// Whether each word typed begins a word of the label, in any order: "lyr", "go art" and "ball" find Lyrics, Go to
  /// Artist and a playlist named Ballin.
  bool matches(String query) {
    final words = label.toLowerCase().split(_gap);
    return query.toLowerCase().split(_gap).where((w) => w.isNotEmpty).every((q) => words.any((w) => w.startsWith(q)));
  }
}

/// A row of the list under the box: a command, a song found, or the full search.
class _Entry {
  final Command? command;
  final Track? song;
  final int index; // the song's place among those found
  final String? all; // the query, for "every result"
  const _Entry.command(Command this.command) : song = null, index = 0, all = null;
  const _Entry.song(Track this.song, this.index) : command = null, all = null;
  const _Entry.all(String this.all) : command = null, song = null, index = 0;
}

class CommandBar extends StatefulWidget {
  final CommandPlaces places;
  const CommandBar({super.key, required this.places});

  static _CommandBarState? _shown;

  /// Ctrl+K and /: the box takes the keyboard, what is in it selected. False with no box on screen (a phone, the
  /// Search page, which has its own).
  static bool summon() {
    final bar = _shown;
    if (bar == null || !bar.mounted) return false;
    bar._focus.requestFocus();
    bar._field.selection = TextSelection(baseOffset: 0, extentOffset: bar._field.text.length);
    return true;
  }

  @override
  State<CommandBar> createState() => _CommandBarState();
}

class _CommandBarState extends State<CommandBar> {
  final _field = TextEditingController();
  final _focus = FocusNode(debugLabel: 'command bar');
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _group = Object(); // the box and its list: a click in the list keeps the box's keyboard
  Timer? _wait;
  int _asked = 0; // the newest search: an older answer that comes late is dropped
  List<Track> _songs = [];
  bool _searching = false;
  int _chosen = 0;
  List<_Entry> _entries = [];
  double _width = 440;

  @override
  void initState() {
    super.initState();
    CommandBar._shown = this;
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    if (CommandBar._shown == this) CommandBar._shown = null;
    _wait?.cancel();
    _focus.dispose();
    _field.dispose();
    super.dispose();
  }

  void _focusChanged() {
    _focus.hasFocus ? _portal.show() : _portal.hide();
    setState(() => _chosen = 0);
  }

  void _typed(String text) {
    _wait?.cancel();
    final q = text.trim();
    final asked = ++_asked;
    setState(() {
      _chosen = 0;
      if (q.length < 2) _songs = [];
      _searching = q.length >= 2;
    });
    if (q.length < 2) return;
    _wait = Timer(const Duration(milliseconds: 250), () async {
      List<Track> found;
      try {
        found = (await Api.search(q)).take(5).toList();
      } catch (_) {
        found = []; // no server now: the commands still work
      }
      if (!mounted || asked != _asked) return;
      setState(() {
        _songs = found;
        _searching = false;
      });
    });
  }

  void _close() {
    _field.clear();
    _typed('');
    _focus.unfocus();
  }

  /// Everything the bar can do now, for the song playing (if any) and the user's playlists.
  List<Command> _commands() {
    final s = Scope.of(context);
    final p = s.player;
    final t = p.current;
    final places = widget.places;
    final downloads = DownloadStore.shared;
    void show(String panel) {
      p.panel = panel;
      p.setShowNowPlaying(true);
    }
    final liked = t != null && s.library.isLiked(t);
    return [
      if (t != null) ...[
        Command(p.isPlaying ? 'Pause' : 'Play', p.isPlaying ? FluentIcons.pause_24_regular : FluentIcons.play_24_regular,
            p.togglePlayPause, detail: t.title, keys: 'Space', suggested: true),
        Command('Next Song', FluentIcons.next_24_regular, p.next, keys: 'Ctrl →', suggested: true),
        Command('Previous Song', FluentIcons.previous_24_regular, p.previous, keys: 'Ctrl ←'),
        Command(liked ? 'Remove from Liked Songs' : 'Like', liked ? FluentIcons.heart_24_filled : FluentIcons.heart_24_regular,
            () => s.library.toggleLike(t), detail: t.title, keys: 'L', suggested: true),
        Command('Lyrics', FluentIcons.comment_quote_24_regular, () => show('lyrics'), suggested: true),
        Command('Up Next', FluentIcons.text_bullet_list_ltr_24_regular, () => show('upNext'), suggested: true),
        Command('Now Playing', FluentIcons.arrow_maximize_24_regular, () => show('none')),
        Command(p.queue.isShuffled ? 'Shuffle Off' : 'Shuffle On', FluentIcons.arrow_shuffle_24_regular, p.toggleShuffle),
        Command('Repeat ${switch (p.queue.repeat.next) { Repeat.off => 'Off', Repeat.all => 'All', Repeat.one => 'One' }}',
            FluentIcons.arrow_repeat_all_24_regular, p.cycleRepeat),
        Command(p.volume == 0 ? 'Unmute' : 'Mute', p.volume == 0 ? FluentIcons.speaker_mute_24_regular : FluentIcons.speaker_2_24_regular,
            p.toggleMute, keys: 'M'),
        if (t.artists.isNotEmpty)
          Command('Go to Artist', FluentIcons.person_24_regular, () => openBrowse(context, ArtistNamed(t.artists.first)), detail: t.artists.first),
        if (t.albumTitle != null)
          Command('Go to Album', FluentIcons.album_24_regular,
              () => openBrowse(context, AlbumNamed(t.albumTitle!, t.artists.firstOrNull ?? '')), detail: t.albumTitle),
        if (downloads.folder != null)
          downloads.isDownloaded(t)
              ? Command('Show in Folder', FluentIcons.folder_open_24_regular, () => showInFolder(downloads.fileFor(t)!), detail: t.title)
              : Command('Download', FluentIcons.arrow_download_24_regular, () => downloads.download(t), detail: t.title),
      ],
      Command(JamSession.shared.inJam ? 'Jam' : 'Start or Join a Jam', FluentIcons.people_team_24_regular,
          () => showPanel(context, builder: (_) => JamPanel(jam: JamSession.shared, social: Social.shared)), suggested: true),
      Command('New Playlist…', FluentIcons.add_24_regular, () async {
        final name = await askName(context, title: 'New Playlist');
        if (name != null) await s.library.createPlaylist(name);
      }, suggested: t == null),
      Command('Home', FluentIcons.home_24_regular, places.home),
      Command('Library', FluentIcons.library_24_regular, places.library, suggested: t == null),
      Command('Liked Songs', FluentIcons.heart_24_regular, () => places.collection(Collection.liked), suggested: t == null),
      Command('Recently Played', FluentIcons.history_24_regular, () => places.collection(Collection.recent)),
      if (downloads.folder != null) Command('Downloads', FluentIcons.arrow_download_24_regular, () => places.collection(Collection.downloads)),
      Command('Friends', FluentIcons.people_24_regular, places.friends),
      Command('Settings', FluentIcons.settings_24_regular, places.settings),
      for (final pl in s.library.playlists) Command(pl.name, FluentIcons.music_note_2_24_regular, () => places.playlist(pl.id), detail: 'Playlist'),
    ];
  }

  /// With nothing typed, what is most likely wanted; else the matching commands, the songs found, and every result.
  List<_Entry> _list() {
    final q = _field.text.trim();
    final commands = _commands();
    if (q.isEmpty) return [for (final c in commands.where((c) => c.suggested).take(7)) _Entry.command(c)];
    return [
      for (final c in commands.where((c) => c.matches(q)).take(5)) _Entry.command(c),
      for (var i = 0; i < _songs.length; i++) _Entry.song(_songs[i], i),
      _Entry.all(q),
    ];
  }

  Future<void> _run(_Entry e, {bool toUpNext = false}) async {
    final p = Scope.of(context).player;
    final songs = _songs;
    _close();
    if (e.command != null) {
      await e.command!.run();
    } else if (e.song != null) {
      toUpNext ? p.addToQueue(e.song!) : p.play(songs, startAt: e.index);
    } else {
      widget.places.search(e.all!);
    }
  }

  /// ↑ and ↓ choose, Enter runs (Shift+Enter: a song goes to Up Next), Esc leaves. Heard before the field, which would
  /// take ↑ and ↓ to its own ends.
  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final n = _entries.length;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown when n > 0:
        setState(() => _chosen = (_chosen + 1) % n);
      case LogicalKeyboardKey.arrowUp when n > 0:
        setState(() => _chosen = (_chosen - 1 + n) % n);
      case LogicalKeyboardKey.escape:
        _close();
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter when e is KeyDownEvent:
        if (n > 0) _run(_entries[_chosen.clamp(0, n - 1)], toUpNext: HardwareKeyboard.instance.isShiftPressed);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    return ListenableBuilder(
      // the commands follow the song: Play becomes Pause, Like becomes Remove from Liked Songs
      listenable: Listenable.merge([s.player, s.library, JamSession.shared]),
      builder: (context, _) {
        _entries = _list();
        if (_chosen >= _entries.length) _chosen = 0;
        return LayoutBuilder(builder: (context, box) {
          _width = math.max(box.maxWidth, 440);
          return OverlayPortal(
            controller: _portal,
            overlayChildBuilder: _dropdown,
            child: CompositedTransformTarget(
              link: _link,
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: _key,
                child: SizedBox(
                  height: 44,
                  child: TextField(
                    controller: _field,
                    focusNode: _focus,
                    groupId: _group,
                    onTapOutside: (_) => _focus.unfocus(),
                    onChanged: _typed,
                    style: const TextStyle(fontSize: 14),
                    cursorWidth: 1.5,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Search, or type a command',
                      hintStyle: TextStyle(fontSize: 14, color: ink.withValues(alpha: 0.5)),
                      prefixIcon: Icon(FluentIcons.search_24_regular, size: 18, color: ink.withValues(alpha: 0.6)),
                      suffixIcon: _focus.hasFocus
                          ? null
                          : Padding(padding: const EdgeInsets.only(right: 12), child: Center(widthFactor: 1, child: _Keys('Ctrl K'))),
                      filled: true,
                      fillColor: panelFill(context),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide(color: ink.withValues(alpha: 0.1))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide(color: ink.withValues(alpha: 0.1))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5)),
                    ),
                  ),
                ),
              ),
            ),
          );
        });
      },
    );
  }

  Widget _dropdown(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    final entries = _entries;
    final typed = _field.text.trim().isNotEmpty;
    Widget heading(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Text(t, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: ink.withValues(alpha: 0.5))),
        );
    final rows = <Widget>[];
    var songsShown = false;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (i == 0 && e.command != null) rows.add(heading(typed ? 'ACTIONS' : 'SUGGESTED'));
      if (e.song != null && !songsShown) {
        songsShown = true;
        rows.add(heading('SONGS'));
      }
      if (e.all != null && _searching && _songs.isEmpty) {
        rows.add(heading('SONGS'));
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: Text('Searching…', style: TextStyle(fontSize: 13, color: ink.withValues(alpha: 0.55))),
        ));
      }
      rows.add(_Row(
        entry: e,
        chosen: i == _chosen,
        onHover: () {
          if (_chosen != i) setState(() => _chosen = i);
        },
        onTap: () => _run(e),
      ));
    }
    final hint = typed && _songs.isNotEmpty
        ? '↑ ↓ choose · Enter play · Shift+Enter add to Up Next · Esc close'
        : typed
            ? '↑ ↓ choose · Enter run · Esc close'
            : 'Space play or pause · ← → seek · Ctrl ← → skip · L like · M mute';
    final height = MediaQuery.sizeOf(context).height;
    return Positioned(
      width: _width,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        offset: const Offset(0, 8),
        child: TapRegion(
          groupId: _group,
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            radius: 16,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: math.max(200, math.min(560, height - 140))),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Flexible(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                  child: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: ink.withValues(alpha: 0.45))),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A key or two, as the keyboard shows them.
class _Keys extends StatelessWidget {
  final String keys;
  const _Keys(this.keys);
  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: ink.withValues(alpha: 0.16))),
      child: Text(keys, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ink.withValues(alpha: 0.55))),
    );
  }
}

class _Row extends StatelessWidget {
  final _Entry entry;
  final bool chosen;
  final VoidCallback onHover, onTap;
  const _Row({required this.entry, required this.chosen, required this.onHover, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final c = entry.command, song = entry.song;
    final Widget picture = song != null
        ? Cover(song.image, size: 34, radius: 6)
        : Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: ink.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(8)),
            child: Icon(c?.icon ?? FluentIcons.search_24_regular, size: 18, color: ink.withValues(alpha: 0.8)),
          );
    final title = c?.label ?? song?.title ?? 'All results for “${entry.all}”';
    final detail = c?.detail ?? song?.artistLine;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onHover: (_) => onHover(),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(color: chosen ? ink.withValues(alpha: 0.08) : null, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            picture,
            const SizedBox(width: 12),
            Expanded(
              child: song != null
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ink)),
                      Text(detail ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: ink.withValues(alpha: 0.55))),
                    ])
                  : Text.rich(
                      TextSpan(children: [
                        TextSpan(text: title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ink)),
                        if (detail != null) TextSpan(text: '   $detail', style: TextStyle(fontSize: 12.5, color: ink.withValues(alpha: 0.55))),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            if (c?.keys != null) ...[const SizedBox(width: 10), _Keys(c!.keys!)],
            if (entry.all != null) Icon(FluentIcons.arrow_right_24_regular, size: 16, color: ink.withValues(alpha: 0.5)),
          ]),
        ),
      ),
    );
  }
}
