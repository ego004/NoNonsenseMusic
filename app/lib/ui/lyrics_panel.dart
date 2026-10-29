import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/player.dart';
import '../core/settings.dart';
import '../core/translation.dart';
import 'concept.dart';
import 'in_front.dart';
import 'layout.dart';
import 'lyric_layout.dart';
import 'scope.dart';

/// Shows the lyrics for the current track.
///
/// Timed lyrics light the line being sung and keep it centered, and tapping a line plays from it. The panel wakes
/// once per line (a timer until the next line is due), never per frame, and the list moves only on a line change:
/// Flutter draws the movement itself, so a line change costs a 0.6 s animation and nothing runs between. Untimed
/// lyrics scroll as a plain list. The panel shows "Finding lyrics…" while the lookup runs, "Couldn't reach the
/// server" when it fails, and "Couldn't find lyrics" when no source holds any.
class LyricsPanel extends StatelessWidget {
  const LyricsPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    // listen to the track id: as a const child the panel kept the first track's lyrics
    return ValueListenableBuilder<String?>(valueListenable: s.player.currentId, builder: (context, _, _) {
    final t = s.player.current;
    if (t == null) return const SizedBox.shrink();
    s.lyrics.fetch(t);
    return ListenableBuilder(
      listenable: Listenable.merge([s.lyrics, s.lyrics.translations, s.settings]),
      builder: (context, _) {
        final found = s.lyrics.of(t);
        Widget message(String text) => Center(child: Text(text, style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: NowPlayingInk.secondary))));
        if (found == null) return s.lyrics.unreachable.contains(t.id) ? message('Couldn\'t reach the server') : message('Finding lyrics…');
        if (found.lines.isEmpty) return message('Couldn\'t find lyrics');
        final genius = s.lyrics.notesOf(t);
        final notes = genius?.byLine(found.lines) ?? const <int, GeniusNote>{};
        final about = genius?.about;
        final translations = s.lyrics.translations;
        final already = translations.inReadersLanguage(t.id);
        final translating = s.settings.translateLyrics && !already;
        // the choice is kept: the next song in another language opens translated too
        if (translating) scheduleMicrotask(() => translations.translate(t.id, found.lines));
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
            child: Row(children: [
              Text('Lyrics', style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(found.synced ? 'from ${found.sourceName}' : 'from ${found.sourceName} · not timed',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                ),
              ),
              // Translate for any lyrics; with it on, the language menu always shows, saying "Already in …" when there
              // is nothing to translate into it, so another language is one pick away (English into Hindi, 20 Oct)
              _TranslateToggle(
                  on: s.settings.translateLyrics, onTap: () => s.settings.setTranslateLyrics(!s.settings.translateLyrics)),
              const SizedBox(width: 6),
              // the language, changeable here as well as in Settings › Lyrics (20 Oct, as on the Mac)
              if (s.settings.translateLyrics) _TranslateInto(settings: s.settings, already: already),
              if (about != null && !about.isEmpty)
                IconButton(
                  tooltip: 'About This Song',
                  icon: const Icon(Icons.info_outline, size: 18),
                  onPressed: () => showGeniusAbout(context, about, genius?.url),
                ),
            ]),
          ),
          Expanded(
            child: translating
                ? TranslatedLyrics(lyrics: found, track: t, translations: translations, notes: notes, notesUrl: genius?.url)
                : found.synced
                    ? _Timed(key: ValueKey(t.id), track: t, lyrics: found, notes: notes, notesUrl: genius?.url)
                    : _Plain(found, notes: notes, notesUrl: genius?.url),
          ),
        ]);
      },
    );
    });
  }
}

/// The lyrics with each line's translation under it. Asked for when the pane opens for a song: "Translating…"
/// meanwhile, "Couldn't translate these lyrics" with a way to try again when it fails.
class TranslatedLyrics extends StatelessWidget {
  final Lyrics lyrics;
  final Track track;
  final LyricsTranslations translations;
  final Map<int, GeniusNote> notes;
  final String? notesUrl;
  const TranslatedLyrics(
      {super.key, required this.lyrics, required this.track, required this.translations, this.notes = const {}, this.notesUrl});

  List<LyricLine> get lines => lyrics.lines;
  String get songId => track.id;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: NowPlayingInk.secondary));
    Widget centered(List<Widget> children) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: children));
    final done = translations.linesOf(songId);
    if (done == null) {
      if (translations.failed(songId)) {
        return centered([
          Icon(FluentIcons.translate_24_regular, size: 34, color: muted.color),
          const SizedBox(height: 10),
          Text("Couldn't translate these lyrics", style: muted),
          TextButton(onPressed: () => translations.retry(songId), child: const Text('Try Again')),
        ]);
      }
      return centered([Text('Translating…', style: muted)]);
    }
    // timed lyrics stay timed once translated: the line being sung lit and followed, a tap plays from it, each line's
    // translation under it (20 Oct)
    if (lyrics.synced) {
      return _Timed(key: ValueKey(('translated', songId)), track: track, lyrics: lyrics, notes: notes, notesUrl: notesUrl,
          translations: done);
    }
    final shown = [for (final (i, l) in lines.indexed) if (l.text.isNotEmpty && i < done.length) i];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 12),
      itemCount: shown.length,
      itemBuilder: (_, k) {
        final i = shown[k];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(lines[i].text, style: theme.textTheme.bodyMedium?.copyWith(color: muted.color)),
            const SizedBox(height: 3),
            SelectableText(done[i], style: theme.textTheme.titleMedium?.merge(lyricsStyle)),
          ]),
        );
      },
    );
  }
}

/// Translate into, in the Lyrics pane while a translation shows: the language's name, a menu of the others.
/// Translate, switched on or off: a pill with its name and icon, tinted while on, as the language pill beside it. The
/// icon alone said nothing about what it did (29 Oct).
class _TranslateToggle extends StatelessWidget {
  final bool on;
  final VoidCallback onTap;
  const _TranslateToggle({required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final ink = on ? accent : theme.colorScheme.onSurface;
    return Tooltip(
      message: on ? 'Show the original lyrics' : 'Translate the lyrics',
      child: Semantics(
        button: true,
        toggled: on,
        label: 'Translate',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: on ? accent.withValues(alpha: 0.16) : null,
              border: Border.all(color: on ? accent.withValues(alpha: 0.6) : theme.colorScheme.onSurface.withValues(alpha: 0.22)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(on ? FluentIcons.translate_24_filled : FluentIcons.translate_24_regular, size: 16, color: ink),
              const SizedBox(width: 5),
              Text('Translate', style: theme.textTheme.bodySmall?.copyWith(color: ink)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _TranslateInto extends StatelessWidget {
  final Settings settings;
  final bool already; // the lyrics are in the language chosen: "Already in …"
  const _TranslateInto({required this.settings, this.already = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = settings.translateInto;
    final language = LyricsTranslations.languages[chosen];
    final name = already ? 'Already in ${language ?? 'your language'}' : language ?? 'System language';
    return PopupMenuButton<String>(
      tooltip: 'Translate into',
      initialValue: chosen,
      onSelected: settings.setTranslateInto,
      itemBuilder: (_) => [
        const PopupMenuItem(value: '', child: Text('System language')),
        const PopupMenuDivider(),
        for (final MapEntry(key: code, value: language) in LyricsTranslations.languages.entries)
          PopupMenuItem(value: code, child: Text(language)),
      ],
      // a pill with an edge, so it reads as something to click: as plain text beside "from LRCLIB" it did not (21 Oct)
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.22)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(name, style: theme.textTheme.bodySmall),
          const SizedBox(width: 2),
          const Icon(Icons.expand_more, size: 16),
        ]),
      ),
    );
  }
}

/// Untimed lyrics as a scrolling list of lines.
class _Plain extends StatelessWidget {
  final Lyrics lyrics;
  final Map<int, GeniusNote> notes;
  final String? notesUrl;
  const _Plain(this.lyrics, {this.notes = const {}, this.notesUrl});
  @override
  Widget build(BuildContext context) => ListView.builder(
        padding: const EdgeInsets.all(6),
        itemCount: lyrics.lines.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: NotedLyricLine(text: lyrics.lines[i].text, style: Theme.of(context).textTheme.titleMedium?.merge(lyricsStyle), note: notes[i], url: notesUrl),
        ),
      );
}

/// Timed lyrics: the line being sung is lit and the list keeps it centered.
class _Timed extends StatefulWidget {
  final Track track;
  final Lyrics lyrics;
  final Map<int, GeniusNote> notes;
  final String? notesUrl;
  final List<String>? translations; // translated: each line's translation, shown under the line as sung
  const _Timed({super.key, required this.track, required this.lyrics, this.notes = const {}, this.notesUrl, this.translations});
  @override
  State<_Timed> createState() => _TimedState();
}

class _TimedState extends State<_Timed> {
  late final ScrollController _scroll;
  LyricLayout? _layout; // the lines' heights at the width last built
  Object? _layoutKey; // what they were measured for: measured again only when it changes
  Timer? _next;
  int _lit = -1;
  Player? _player; // held so dispose can drop the listener without a context lookup

  @override
  void initState() {
    super.initState();
    // start at the line being sung: the first follow jumps rather than animating
    _scroll = ScrollController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Scope.of(context).player;
    _player?.removeListener(_follow);
    _player = p;
    p.addListener(_follow); // play, pause or seek: the wait starts again
    inFront.removeListener(_follow);
    inFront.addListener(_follow); // no timers while behind other windows; on return the right line lights at once
    _follow(jump: true);
  }

  Future<void> _follow({bool jump = false}) async {
    final p = _player;
    if (!mounted || p == null) return;
    if (p.current?.id != widget.track.id) return;
    final at = await p.readPosition();
    if (!mounted) return;
    final line = widget.lyrics.lineAt(at + 0.1);
    if (line != _lit) {
      setState(() => _lit = line);
      _center(line, jump: jump);
    }
    _next?.cancel();
    if (!p.isPlaying || !inFront.value) return;
    // schedule the wake for when the next line starts
    final upcoming = widget.lyrics.lines.skip(line + 1).map((l) => l.startMs).whereType<int>().firstOrNull;
    if (upcoming == null) return;
    final wait = Duration(milliseconds: (upcoming - at * 1000).round().clamp(30, 60000));
    _next = Timer(wait, _follow);
  }

  void _center(int line, {required bool jump}) {
    if (!_scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _center(line, jump: true));
      return;
    }
    final layout = _layout;
    if (layout == null) return;
    final view = _scroll.position.viewportDimension;
    final target = (layout.centerOf(line) - view / 2).clamp(0.0, _scroll.position.maxScrollExtent);
    jump ? _scroll.jumpTo(target) : _scroll.animateTo(target, duration: Duration(milliseconds: (Scope.of(context).settings.lyricsMotion * 1000).round()), curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _next?.cancel();
    _player?.removeListener(_follow);
    inFront.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = Scope.of(context).player;
    final base = DefaultTextStyle.of(context).style.merge(theme.textTheme.titleMedium?.merge(lyricsStyle));
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final translated = widget.translations;
    String translation(int i) => translated != null && i < translated.length && widget.lyrics.lines[i].text.isNotEmpty ? translated[i] : '';
    final original = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: NowPlayingInk.secondary));
    // separate paint layer: a line change repaints the lyrics only, not the page
    return RepaintBoundary(child: LayoutBuilder(builder: (context, box) {
      // each line wraps at the width it is drawn at (the list's width less the 6 px either side)
      final width = (box.maxWidth - 12).clamp(40.0, double.infinity);
      final key = (width, base, direction, scaler, translated);
      final first = _layout == null;
      if (key != _layoutKey) {
        _layoutKey = key;
        final lines = widget.lyrics.lines;
        _layout = translated == null
            ? LyricLayout.measure([for (final l in lines) l.text], style: base, width: width, direction: direction, scaler: scaler)
            : LyricLayout.measure([for (final (i, l) in lines.indexed) translation(i).isEmpty ? l.text : translation(i)],
                style: base, width: width, direction: direction, scaler: scaler,
                above: [for (final (i, l) in lines.indexed) translation(i).isEmpty ? '' : l.text], aboveStyle: original);
      }
      final layout = _layout!;
      if (first) WidgetsBinding.instance.addPostFrameCallback((_) => _center(_lit, jump: true));
      return ListView.builder(
        controller: _scroll,
        itemExtentBuilder: (i, _) => layout.extents[i],
        itemCount: widget.lyrics.lines.length,
        itemBuilder: (_, i) {
          final line = widget.lyrics.lines[i];
          final play = line.startMs == null ? null : () => p.seek(line.startMs! / 1000);
          return Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              // a line with a note opens it rather than playing from it: "Play from here" lives inside the note
              child: () {
                final lit = base.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: i == _lit ? 1 : NowPlayingInk.unlit));
                final over = translation(i);
                final shown = NotedLyricLine(text: over.isEmpty ? line.text : over, note: widget.notes[i], url: widget.notesUrl,
                    onTap: play, onPlay: play, style: lit);
                if (over.isEmpty) return shown;
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(line.text, style: original),
                  const SizedBox(height: LyricLayout.aboveGap),
                  shown,
                ]);
              }(),
            ),
          );
        },
      );
    }));
  }
}

// ---- Genius notes (experimental) ----

/// A single lyric line, in the accent colour when a Genius note is attached (15 Oct: it was underlined).
///
/// With a mouse, resting on a noted line shows the note in a glass card beside it; a click (or a tap) opens the whole
/// note in a glass window. Lines without a note play from their own time.
class NotedLyricLine extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final GeniusNote? note;
  final String? url;
  final VoidCallback? onTap; // no note on the line: play from it (timed lyrics)
  final VoidCallback? onPlay; // "Play from here" inside the note's window
  const NotedLyricLine({super.key, required this.text, this.style, this.note, this.url, this.onTap, this.onPlay});

  @override
  State<NotedLyricLine> createState() => _NotedLyricLineState();
}

class _NotedLyricLineState extends State<NotedLyricLine> {
  final _card = OverlayPortalController();
  final _link = LayerLink();
  Timer? _wait, _closing;
  bool _inCard = false; // the pointer is in the card: it stays open
  bool _below = true; // the card opens under the line, or over it when there is no room under it
  static const _cardRoom = 300.0; // the tallest card: the note, scrolling past this, and its credit

  void _enter() {
    if (widget.note == null || isTouchDevice) return;
    _closing?.cancel();
    if (_card.isShowing) return;
    _wait?.cancel();
    // a short rest first: moving the pointer across the lyrics does not flash a card on every line it passes
    _wait = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        // under the line when the card fits there, else over it: by halves, the lines under the lit one (in the
        // middle) all opened theirs over them, up on the pane's header (20 Oct)
        final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
        _below = bottom + 8 + _cardRoom <= MediaQuery.sizeOf(context).height;
      }
      _card.show();
    });
  }

  /// Off the line, or out of the card: it closes a moment later, unless the pointer went into the card (or back) by
  /// then. Time to move from the line into the card, which you can scroll (21 Oct, as on the Mac).
  void _leave() {
    _wait?.cancel();
    _closing?.cancel();
    _closing = Timer(const Duration(milliseconds: 250), () {
      if (mounted && !_inCard && _card.isShowing) _card.hide();
    });
  }

  void _close() {
    _wait?.cancel();
    _closing?.cancel();
    _inCard = false;
    if (_card.isShowing) _card.hide();
  }

  @override
  void dispose() {
    _wait?.cancel();
    _closing?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final accent = Theme.of(context).colorScheme.primary;
    final style = widget.style ?? const TextStyle();
    // a long line wraps in every script; the panel's line heights are measured for that (LyricLayout). The colour keeps
    // the line's own brightness (the line being sung is the brightest), never fainter than can be read
    final shown = Text(widget.text,
        style: note == null ? widget.style : style.copyWith(color: accent.withValues(alpha: (style.color?.a ?? 1).clamp(0.6, 1.0))));
    // with a mouse, resting on a noted line shows its note and a click plays from the line like any other (21 Oct);
    // on a touch screen there is no resting, and untimed lyrics have nothing to play from: a tap opens the note
    final play = widget.onTap;
    final tap = note == null
        ? play
        : (play != null && !isTouchDevice)
            ? () {
                _close();
                play();
              }
            : () {
                _close();
                showGeniusNote(context, note, widget.url, onPlay: widget.onPlay);
              };
    // a hand over a noted line, as over a link (Flutter gives a tappable widget the arrow on a computer)
    final line = InkWell(borderRadius: BorderRadius.circular(8), mouseCursor: note == null ? null : SystemMouseCursors.click, onTap: tap, child: shown);
    if (note == null) return line;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _card,
        overlayChildBuilder: (_) => Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: _below ? Alignment.bottomLeft : Alignment.topLeft,
            followerAnchor: _below ? Alignment.topLeft : Alignment.bottomLeft,
            offset: Offset(0, _below ? 8 : -8),
            // the pointer can move into the card and scroll it; it stays open while the pointer is in it
            child: MouseRegion(
              onEnter: (_) {
                _inCard = true;
                _closing?.cancel();
              },
              onExit: (_) {
                _inCard = false;
                _leave();
              },
              child: _NoteCard(note: note),
            ),
          ),
        ),
        child: MouseRegion(onEnter: (_) => _enter(), onExit: (_) => _leave(), child: line),
      ),
    );
  }
}

/// The note shown on hover, on glass, coming in once: all of it, scrolling when long.
class _NoteCard extends StatelessWidget {
  final GeniusNote note;
  const _NoteCard({required this.note});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // the glass comes in by itself (GlassCard.appear): faded from outside, it showed black until the fade ended
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (_, t, content) => Transform.scale(
        scale: 0.96 + 0.04 * t,
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: GlassCard(appear: t, padding: const EdgeInsets.fromLTRB(14, 12, 14, 12), child: content!),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
                child: Text(note.text, style: theme.textTheme.bodyMedium?.copyWith(height: 1.4))),
          ),
          const SizedBox(height: 8),
          Text(note.verified ? 'Genius · verified by the artist' : 'Genius',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: NowPlayingInk.secondary))),
        ]),
      ),
    );
  }
}

/// A window in the player's glass, over the player: a title, what it holds (scrolling when long), and its buttons.
Future<void> _showGlassWindow(BuildContext context,
        {String? title, required Widget body, required Widget credit, required List<Widget> Function(BuildContext) buttons}) =>
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.18),
      transitionDuration: const Duration(milliseconds: 320),
      // the window brings its own glass in (GlassCard.appear) and grows to its size with a small overshoot, as a Mac
      // window opens; it is never faded from outside, which showed black until the fade ended (15 Oct)
      transitionBuilder: (_, _, _, child) => child,
      pageBuilder: (c, animation, _) {
        final theme = Theme.of(c);
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460, maxHeight: MediaQuery.sizeOf(c).height * 0.75),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: AnimatedBuilder(
                animation: animation,
                builder: (_, content) {
                  // opening: the glass comes up and the window grows past its size and settles; closing: both go quickly
                  final opening = animation.status != AnimationStatus.reverse;
                  final appear = (opening ? Curves.easeOutCubic : Curves.easeInCubic).transform(animation.value);
                  final grow = (opening ? Curves.easeOutBack : Curves.easeInCubic).transform(animation.value);
                  return Transform.scale(
                    scale: 0.94 + 0.06 * grow,
                    child: GlassCard(appear: appear, radius: 22, padding: const EdgeInsets.fromLTRB(22, 20, 14, 12), child: content!),
                  );
                },
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (title != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12, right: 8),
                        child: Text(title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    Flexible(child: SingleChildScrollView(padding: const EdgeInsets.only(right: 8), child: body)),
                    const SizedBox(height: 12),
                    credit,
                    // the buttons on the right, one above the other when a narrow window has no room for them in a row
                    Align(
                      alignment: Alignment.centerRight,
                      child: OverflowBar(spacing: 4, overflowAlignment: OverflowBarAlignment.end, children: buttons(c)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    );

/// Shows a Genius note in a glass window over the lyrics.
///
/// The window holds the note text, credits Genius and, when the line carries a time, offers "Play from here".
Future<void> showGeniusNote(BuildContext context, GeniusNote note, String? url, {VoidCallback? onPlay}) => _showGlassWindow(
      context,
      body: SelectableText(note.text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.45)),
      credit: _GeniusCredit(url: url, verified: note.verified),
      buttons: (c) => [
        if (onPlay != null) TextButton(onPressed: () { Navigator.pop(c); onPlay(); }, child: const Text('Play from here')),
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
      ],
    );

/// Shows Genius's "About this song" in a glass window: its description, who produced it and what it samples.
Future<void> showGeniusAbout(BuildContext context, GeniusAbout about, String? url) {
  final theme = Theme.of(context);
  Widget fact(String title, String value) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Text(value),
        ]),
      );
  return _showGlassWindow(
    context,
    title: 'About This Song',
    body: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (about.description != null) SelectableText(about.description!, style: theme.textTheme.bodyLarge?.copyWith(height: 1.45)),
      if (about.producedBy.isNotEmpty) fact('Produced by', about.producedBy.join(', ')),
      if (about.samples.isNotEmpty) fact('Samples', about.samples.join('\n')),
    ]),
    credit: _GeniusCredit(url: url, verified: false),
    buttons: (c) => [
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
    ],
  );
}

/// Credits Genius as the source of the notes, marked "verified by the artist" when the artist confirmed them.
///
/// The tooltip carries the song's page address when one exists.
class _GeniusCredit extends StatelessWidget {
  final String? url;
  final bool verified;
  const _GeniusCredit({required this.url, required this.verified});
  @override
  Widget build(BuildContext context) => Tooltip(
        message: url ?? '',
        child: Text(verified ? 'Genius · verified by the artist' : 'Genius', style: Theme.of(context).textTheme.bodySmall),
      );
}
