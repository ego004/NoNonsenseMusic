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
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
            child: Row(children: [
              Text('Lyrics', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text(found.synced ? 'from ${found.sourceName}' : 'from ${found.sourceName} · not timed', style: theme.textTheme.bodySmall),
            ]),
          ),
          Expanded(child: found.synced ? _Timed(key: ValueKey(t.id), track: t, lyrics: found) : _Plain(found)),
        ]);
      },
    );
    });
  }
}

class _Plain extends StatelessWidget {
  final Lyrics lyrics;
  const _Plain(this.lyrics);
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(6), children: [
        for (final l in lyrics.lines) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(l.text, style: Theme.of(context).textTheme.titleMedium)),
      ]);
}

class _Timed extends StatefulWidget {
  final Track track;
  final Lyrics lyrics;
  const _Timed({super.key, required this.track, required this.lyrics});
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
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: line.startMs == null ? null : () => p.seek(line.startMs! / 1000),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(line.text, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface.withValues(alpha: i == _lit ? 1 : 0.35))),
            ),
          ),
        );
      },
    ));
  }
}
