import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/models.dart';
import '../core/play_queue.dart';
import 'cover.dart';
import 'scope.dart';
import 'song_row.dart';
import 'waiting.dart';

/// The floating bar: the song on the left, ⏮ ▶ ⏭ with the progress line in the centre, Up Next and volume on the
/// right. Hidden until a song plays. Click the cover or the title to open Now Playing.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final t = p.current;
        if (t == null) return const SizedBox.shrink();
        return Container(
          height: 72,
          constraints: const BoxConstraints(maxWidth: 900),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.08)),
            boxShadow: const [BoxShadow(blurRadius: 24, color: Color(0x33000000), offset: Offset(0, 8))],
          ),
          child: Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: () => p.setShowNowPlaying(true),
                child: Row(children: [
                  Cover(t.image, size: 48),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                        if (t.isExplicit) const Padding(padding: EdgeInsets.only(left: 4), child: ExplicitBadge()),
                      ]),
                      Text(t.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                    ]),
                  ),
                ]),
              ),
            ),
            SizedBox(
              width: 360,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Transport(size: 22, play: 30),
                Progress(key: ValueKey(t.id)),
              ]),
            ),
            // in a narrow window the volume slider folds away first, as on the Mac
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  IconButton(tooltip: 'Up Next', icon: const Icon(FluentIcons.text_bullet_list_ltr_24_regular), onPressed: () => p.setShowNowPlaying(true)),
                  if (box.maxWidth >= 180) ...[
                    const Icon(FluentIcons.speaker_2_24_regular, size: 18),
                    SizedBox(width: (box.maxWidth - 70).clamp(60, 110).toDouble(), child: Slider(value: p.volume, onChanged: p.setVolume)),
                  ],
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}

/// Shuffle ⏮ ▶ ⏭ Repeat, shared by the bar and Now Playing.
class Transport extends StatelessWidget {
  final double size, play;
  const Transport({super.key, required this.size, required this.play});
  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final accent = Theme.of(context).colorScheme.primary;
    final q = p.queue;
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      IconButton(iconSize: size * 0.8, tooltip: 'Shuffle', color: q.isShuffled ? accent : null, onPressed: p.toggleShuffle, icon: const Icon(FluentIcons.arrow_shuffle_24_regular)),
      IconButton(iconSize: size, tooltip: 'Previous', onPressed: p.previous, icon: const Icon(FluentIcons.previous_24_filled)),
      p.isBuffering
          ? SizedBox(width: play + 16, height: play + 16, child: Center(child: Waiting(size: play * 0.8, tooltip: 'Loading the song…')))
          : IconButton(iconSize: play, tooltip: p.isPlaying ? 'Pause' : 'Play', onPressed: p.togglePlayPause,
              icon: Icon(p.isPlaying ? FluentIcons.pause_24_filled : FluentIcons.play_24_filled)),
      IconButton(iconSize: size, tooltip: 'Next', onPressed: p.next, icon: const Icon(FluentIcons.next_24_filled)),
      IconButton(iconSize: size * 0.8, tooltip: 'Repeat', color: q.repeat == Repeat.off ? null : accent, onPressed: p.cycleRepeat,
          icon: Icon(q.repeat == Repeat.one ? FluentIcons.arrow_repeat_1_24_regular : FluentIcons.arrow_repeat_all_24_regular)),
    ]);
  }
}

/// The progress line and the times. Moves once a second, and only while a song plays: nothing animates per frame
/// (Flutter draws every frame itself, there is no render server to hand a line animation to, as on the Mac).
/// Click or drag to seek.
class Progress extends StatefulWidget {
  const Progress({super.key});
  @override
  State<Progress> createState() => _ProgressState();
}

class _ProgressState extends State<Progress> {
  Timer? _tick;
  double? _dragged;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  void _schedule() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && Scope.of(context).player.isPlaying && _dragged == null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final dur = p.duration;
    final pos = _dragged ?? p.position;
    final small = Theme.of(context).textTheme.labelSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    // its own layer: the tick each second repaints the line and the times, not the window around them
    return RepaintBoundary(child: Row(children: [
      SizedBox(width: 40, child: Text(formatTime(pos), textAlign: TextAlign.right, style: small)),
      Expanded(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5), overlayShape: SliderComponentShape.noOverlay),
          child: Slider(
            value: dur > 0 ? pos.clamp(0, dur) : 0,
            max: dur > 0 ? dur : 1,
            onChanged: (v) => setState(() => _dragged = v),
            onChangeEnd: (v) { p.seek(v); setState(() => _dragged = null); },
          ),
        ),
      ),
      SizedBox(width: 44, child: Text('-${formatTime(dur - pos)}', style: small)),
    ]));
  }
}
