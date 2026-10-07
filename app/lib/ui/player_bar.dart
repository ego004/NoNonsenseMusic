import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/models.dart';
import '../core/play_queue.dart';
import 'cover.dart';
import 'in_front.dart';
import 'scope.dart';
import 'song_row.dart';
import 'waiting.dart';

/// The floating bar: the song on the left, the controls and the progress line in the centre, Lyrics / Up Next and
/// the volume on the right. Hidden until a song plays. Click the song to open Now Playing.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final t = p.current;
        if (t == null) return const SizedBox.shrink();
        return Container(
          height: 76,
          constraints: const BoxConstraints(maxWidth: 940),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: ink.withValues(alpha: 0.08)),
            boxShadow: [BoxShadow(blurRadius: 30, offset: const Offset(0, 10), color: Colors.black.withValues(alpha: theme.brightness == Brightness.dark ? 0.45 : 0.14))],
          ),
          child: Row(children: [
            // the song
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => p.setShowNowPlaying(true),
                  child: Row(children: [
                    Cover(t.image, size: 52, radius: 8),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Flexible(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                          if (t.isExplicit) const Padding(padding: EdgeInsets.only(left: 5), child: ExplicitBadge()),
                        ]),
                        const SizedBox(height: 2),
                        Text(t.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: ink.withValues(alpha: 0.58))),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 16),
            // the controls, and the line under them
            SizedBox(
              width: 380,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Transport(size: 18, play: 34),
                const SizedBox(height: 2),
                Progress(key: ValueKey(t.id)),
              ]),
            ),
            const SizedBox(width: 16),
            // panels and volume; in a narrow window the volume folds away first, as on the Mac
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  _Toggle(icon: FluentIcons.comment_quote_24_regular, tip: 'Lyrics', onTap: () { p.panel = 'lyrics'; p.setShowNowPlaying(true); }),
                  _Toggle(icon: FluentIcons.text_bullet_list_ltr_24_regular, tip: 'Up Next', onTap: () { p.panel = 'upNext'; p.setShowNowPlaying(true); }),
                  // two buttons (80) + the gap (6) + the speaker (40) + the slider
                  if (box.maxWidth >= 126 + 64) ...[const SizedBox(width: 6), Volume(width: (box.maxWidth - 126).clamp(64, 110).toDouble())],
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _Toggle extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  const _Toggle({required this.icon, required this.tip, required this.onTap});
  @override
  Widget build(BuildContext context) => IconButton(tooltip: tip, iconSize: 18, onPressed: onTap, icon: Icon(icon));
}

/// The speaker (click to mute) and a slider in the ink colour, not the accent: the progress line is the accent, so
/// the two never look like one control.
class Volume extends StatelessWidget {
  final double width;
  const Volume({super.key, required this.width});
  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final ink = Theme.of(context).colorScheme.onSurface;
    final icon = p.volume == 0 ? FluentIcons.speaker_mute_24_regular : p.volume < 0.5 ? FluentIcons.speaker_1_24_regular : FluentIcons.speaker_2_24_regular;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(tooltip: p.volume == 0 ? 'Unmute' : 'Mute', iconSize: 18, onPressed: p.toggleMute, icon: Icon(icon)),
      SizedBox(
        width: width,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: ink.withValues(alpha: 0.75),
            inactiveTrackColor: ink.withValues(alpha: 0.15),
            thumbColor: ink,
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 1),
          ),
          child: Slider(value: p.volume, onChanged: p.setVolume),
        ),
      ),
    ]);
  }
}

/// Shuffle ⏮ ▶ ⏭ Repeat, shared by the bar and Now Playing. Listens to the player itself: a `const` copy inside the
/// bar was never rebuilt, so ▶ stayed ▶ after a press and shuffle and repeat never showed their state (8 Oct).
/// On: the accent, with a dot under it. The play button is a solid disc.
class Transport extends StatelessWidget {
  final double size, play;
  const Transport({super.key, required this.size, required this.play});
  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    final accent = theme.colorScheme.primary;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final q = p.queue;
        Widget mode(IconData icon, String tip, bool on, VoidCallback tap) => Tooltip(
              message: tip,
              child: InkResponse(
                onTap: tap,
                radius: size,
                child: SizedBox(
                  width: size * 2.2,
                  height: size * 2.2,
                  child: Stack(alignment: Alignment.center, children: [
                    Icon(icon, size: size * 0.95, color: on ? accent : ink.withValues(alpha: 0.5)),
                    if (on) Positioned(bottom: size * 0.12, child: Container(width: 4, height: 4, decoration: BoxDecoration(color: accent, shape: BoxShape.circle))),
                  ]),
                ),
              ),
            );
        Widget skip(IconData icon, String tip, VoidCallback tap) =>
            IconButton(tooltip: tip, iconSize: size * 1.2, onPressed: tap, icon: Icon(icon), color: ink.withValues(alpha: 0.9));
        return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          mode(FluentIcons.arrow_shuffle_24_regular, q.isShuffled ? 'Shuffle is on' : 'Shuffle', q.isShuffled, p.toggleShuffle),
          SizedBox(width: size * 0.4),
          skip(FluentIcons.previous_24_filled, 'Previous', p.previous),
          SizedBox(width: size * 0.4),
          // the solid disc: the one control you look for
          SizedBox(
            width: play,
            height: play,
            child: p.isBuffering
                ? Center(child: Waiting(size: play * 0.55, tooltip: 'Loading the song…'))
                : Material(
                    color: ink,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: p.togglePlayPause,
                      child: Tooltip(
                        message: p.isPlaying ? 'Pause' : 'Play',
                        child: Icon(p.isPlaying ? FluentIcons.pause_24_filled : FluentIcons.play_24_filled, size: play * 0.5, color: theme.colorScheme.surface),
                      ),
                    ),
                  ),
          ),
          SizedBox(width: size * 0.4),
          skip(FluentIcons.next_24_filled, 'Next', p.next),
          SizedBox(width: size * 0.4),
          mode(q.repeat == Repeat.one ? FluentIcons.arrow_repeat_1_24_regular : FluentIcons.arrow_repeat_all_24_regular,
              switch (q.repeat) { Repeat.off => 'Repeat', Repeat.all => 'Repeating the queue', Repeat.one => 'Repeating this song' },
              q.repeat != Repeat.off, p.cycleRepeat),
        ]);
      },
    );
  }
}

/// The progress line and the times. Moves once a second, only while a song plays and the window is in front
/// (`inFront`). Click or drag to seek.
class Progress extends StatefulWidget {
  const Progress({super.key});
  @override
  State<Progress> createState() => _ProgressState();
}

class _ProgressState extends State<Progress> {
  Timer? _tick;
  double? _dragged;

  @override
  void initState() {
    super.initState();
    inFront.addListener(_frontChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  void _frontChanged() {
    _schedule();
    if (inFront.value && mounted) setState(() {}); // the right time at once
  }

  void _schedule() {
    _tick?.cancel();
    if (!inFront.value) return; // behind other windows: no ticks; back in front, it starts again at once
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final p = Scope.of(context).player;
      if (p.isPlaying && _dragged == null) setState(() {});
    });
  }

  @override
  void dispose() {
    inFront.removeListener(_frontChanged);
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final ink = Theme.of(context).colorScheme.onSurface;
    final dur = p.duration;
    final pos = _dragged ?? p.position;
    final small = TextStyle(fontSize: 11, color: ink.withValues(alpha: 0.55), fontFeatures: const [FontFeature.tabularFigures()]);
    return RepaintBoundary(
      child: Row(children: [
        SizedBox(width: 38, child: Text(formatTime(pos), textAlign: TextAlign.right, style: small)),
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: 14,
            child: Slider(
              value: dur > 0 ? pos.clamp(0, dur) : 0,
              max: dur > 0 ? dur : 1,
              onChanged: (v) => setState(() => _dragged = v),
              onChangeEnd: (v) {
                p.seek(v);
                setState(() => _dragged = null);
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(width: 42, child: Text('-${formatTime(dur - pos)}', style: small)),
      ]),
    );
  }
}
