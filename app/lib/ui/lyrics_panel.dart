import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/player.dart';
import 'in_front.dart';
import 'scope.dart';

/// Now Playing's lyrics. Timed: the line being sung is lit and kept in the middle; click a line to play from it.
/// The app wakes once per line (a timer until the next line is due), never per frame, and the list moves only on a
/// line change: Flutter draws the movement itself, so a line change costs a short animation (0.6 s), nothing between.
/// Plain lyrics simply scroll. "Couldn't find lyrics" when nobody has them.
class LyricsPanel extends StatelessWidget {
  const LyricsPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    // listens to the song itself: as a const child it kept the first song's lyrics
    return ValueListenableBuilder<String?>(valueListenable: s.player.currentId, builder: (context, _, _) {
    final t = s.player.current;
    if (t == null) return const SizedBox.shrink();
    s.lyrics.fetch(t);
    return ListenableBuilder(
      listenable: s.lyrics,
      builder: (context, _) {
        final found = s.lyrics.of(t);
        Widget message(String text) => Center(child: Text(text, style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6))));
        if (found == null) return s.lyrics.unreachable.contains(t.id) ? message('Couldn\'t reach the server') : message('Finding lyrics…');
        if (found.lines.isEmpty) return message('Couldn\'t find lyrics');
        final genius = s.lyrics.notesOf(t);
        final notes = genius?.byLine(found.lines) ?? const <int, GeniusNote>{};
        final about = genius?.about;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
            child: Row(children: [
              Text('Lyrics', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text(found.synced ? 'from ${found.sourceName}' : 'from ${found.sourceName} · not timed', style: theme.textTheme.bodySmall),
              if (about != null && !about.isEmpty)
                IconButton(
                  tooltip: 'About This Song',
                  icon: const Icon(Icons.info_outline, size: 18),
                  onPressed: () => showGeniusAbout(context, about, genius?.url),
                ),
            ]),
          ),
          Expanded(child: found.synced
              ? _Timed(key: ValueKey(t.id), track: t, lyrics: found, notes: notes, notesUrl: genius?.url)
              : _Plain(found, notes: notes, notesUrl: genius?.url)),
        ]);
      },
    );
    });
  }
}

class _Plain extends StatelessWidget {
  final Lyrics lyrics;
  final Map<int, GeniusNote> notes;
  final String? notesUrl;
  const _Plain(this.lyrics, {this.notes = const {}, this.notesUrl});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(6), children: [
        for (final (i, l) in lyrics.lines.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: NotedLyricLine(text: l.text, style: Theme.of(context).textTheme.titleMedium, note: notes[i], url: notesUrl),
          ),
      ]);
}

class _Timed extends StatefulWidget {
  final Track track;
  final Lyrics lyrics;
  final Map<int, GeniusNote> notes;
  final String? notesUrl;
  const _Timed({super.key, required this.track, required this.lyrics, this.notes = const {}, this.notesUrl});
  @override
  State<_Timed> createState() => _TimedState();
}

class _TimedState extends State<_Timed> {
  static const lineHeight = 44.0;
  late final ScrollController _scroll;
  Timer? _next;
  int _lit = -1;
  Player? _player; // kept: dispose may not look the scope up

  @override
  void initState() {
    super.initState();
    // opens at the line being sung, not scrolling to it
    _scroll = ScrollController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Scope.of(context).player;
    _player?.removeListener(_follow);
    _player = p;
    p.addListener(_follow); // play, pause, a seek: the wait starts again
    inFront.removeListener(_follow);
    inFront.addListener(_follow); // behind other windows: no waking; back in front, the right line at once
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
    // sleep until the next line is due
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
    final view = _scroll.position.viewportDimension;
    final target = (line.clamp(0, widget.lyrics.lines.length) * lineHeight - view / 2 + lineHeight / 2).clamp(0.0, _scroll.position.maxScrollExtent);
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
    // its own layer: a line change repaints the lyrics only
    return RepaintBoundary(child: ListView.builder(
      controller: _scroll,
      itemExtent: lineHeight,
      itemCount: widget.lyrics.lines.length,
      itemBuilder: (_, i) {
        final line = widget.lyrics.lines[i];
        final play = line.startMs == null ? null : () => p.seek(line.startMs! / 1000);
        return Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            // a line with a Genius note opens it instead of playing from it: Play from here is in the note
            child: NotedLyricLine(text: line.text, note: widget.notes[i], url: widget.notesUrl, onTap: play, onPlay: play,
                style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface.withValues(alpha: i == _lit ? 1 : 0.35))),
          ),
        );
      },
    ));
  }
}

// ---- Genius notes (experimental, 8 Oct) ----

/// One lyric line. With a Genius note: a faint accent underline, and a click opens the note (not `onTap`).
class NotedLyricLine extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final GeniusNote? note;
  final String? url;
  final VoidCallback? onTap; // a line without a note: play from it (timed lyrics)
  final VoidCallback? onPlay; // in the note: Play from here
  const NotedLyricLine({super.key, required this.text, this.style, this.note, this.url, this.onTap, this.onPlay});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final shown = Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: note == null ? style : (style ?? const TextStyle()).copyWith(decoration: TextDecoration.underline, decorationColor: accent.withValues(alpha: 0.6)));
    final tap = note == null ? onTap : () => showGeniusNote(context, note!, url, onPlay: onPlay);
    return InkWell(borderRadius: BorderRadius.circular(8), onTap: tap, child: shown);
  }
}

/// The note, in a dialog over the lyrics: its text, credited "Genius", and Play from here when the line has a time.
Future<void> showGeniusNote(BuildContext context, GeniusNote note, String? url, {VoidCallback? onPlay}) => showDialog(
      context: context,
      builder: (c) => AlertDialog(
        content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: SelectableText(note.text)),
        actions: [
          _GeniusCredit(url: url, verified: note.verified),
          if (onPlay != null) TextButton(onPressed: () { Navigator.pop(c); onPlay(); }, child: const Text('Play from here')),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
        ],
      ),
    );

/// Genius's About this song: its description, who produced it, what it samples.
Future<void> showGeniusAbout(BuildContext context, GeniusAbout about, String? url) => showDialog(
      context: context,
      builder: (c) {
        final theme = Theme.of(c);
        Widget fact(String title, String value) => Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Text(value),
              ]),
            );
        return AlertDialog(
          title: const Text('About This Song'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (about.description != null) SelectableText(about.description!),
              if (about.producedBy.isNotEmpty) fact('Produced by', about.producedBy.join(', ')),
              if (about.samples.isNotEmpty) fact('Samples', about.samples.join('\n')),
            ])),
          ),
          actions: [_GeniusCredit(url: url, verified: false), TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        );
      },
    );

/// "Genius" (and whether the artist verified it): the notes are theirs. The song's page address shows on hover.
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
