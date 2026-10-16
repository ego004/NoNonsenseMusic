import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/models.dart';
import '../core/play_queue.dart';
import 'browse_widgets.dart';
import 'concept.dart';
import 'cover.dart';
import 'glass.dart';
import 'in_front.dart';
import 'layout.dart';
import 'redesign.dart';
import 'scope.dart';
import 'song_row.dart';
import 'waiting.dart';

/// The floating player bar: the current song on the left, the transport controls and the progress line in the
/// centre, and the Lyrics / Up Next panels and the volume on the right. Hidden while no song plays. Tapping
/// the song opens Now Playing.
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
        final phone = MediaQuery.sizeOf(context).width < 700;
        // the concept (13 Oct): on a computer a pill that rises a little under the pointer
        final bar = Container(
          // taller as the text grows (Android's font size, Windows' text size): at 200% the song's title and artists
          // overflowed the bar by 34 points (#20)
          height: (phone ? 64 : 74) + textGrowth(context, 14 + 12.5),
          constraints: const BoxConstraints(maxWidth: 940),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: phone
              ? null
              : BoxDecoration(
                  // UI v2 (15 Oct): the frosted glass's tint (the blur is under it, below; the shadow outside it)
                  color: floatingFill(context),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: ink.withValues(alpha: 0.1)),
                ),
          child: phone
              // the phone's bar: swipe sideways for the next or previous song, swipe down to close it (the song stops;
              // not in a jam, where it would leave the room's playback without leaving the room), tap to open,
              // long-press for the song's menu (Add to Playlist…)
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => p.setShowNowPlaying(true),
                  onLongPressStart: (d) => showSongMenu(context, d.globalPosition, t),
                  onHorizontalDragEnd: (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -250) p.next();
                    if (v > 250) p.previous();
                  },
                  onVerticalDragEnd: (d) {
                    if ((d.primaryVelocity ?? 0) > 250 && p.jam == null) {
                      p.stop();
                    }
                  },
                  child: Row(
                    children: [
                      Cover(t.image, size: 44, radius: 7),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => p.setShowNowPlaying(true),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              ArtistLinks(
                                artists: t.artists,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ink.withValues(alpha: 0.58),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Previous',
                        icon: const Icon(FluentIcons.previous_24_filled),
                        onPressed: p.previous,
                      ),
                      SizedBox(
                        width: 48, // a finger's target, as the buttons beside it are
                        height: 48,
                        child: Material(
                          color: ink,
                          shape: const CircleBorder(),
                          child: IconButton(
                            tooltip: p.isPlaying ? 'Pause' : 'Play',
                            color: theme.colorScheme.surface,
                            icon: Icon(
                              p.isPlaying
                                  ? FluentIcons.pause_24_filled
                                  : FluentIcons.play_24_filled,
                            ),
                            onPressed: p.togglePlayPause,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Next',
                        icon: const Icon(FluentIcons.next_24_filled),
                        onPressed: p.next,
                      ),
                    ],
                  ),
                )
              : Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => p.setShowNowPlaying(true),
                          child: Row(
                            children: [
                              Cover(t.image, size: 52, radius: 14),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            t.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        if (t.isExplicit)
                                          const Padding(
                                            padding: EdgeInsets.only(left: 5),
                                            child: ExplicitBadge(),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    ArtistLinks(
                                      artists: t.artists,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: ink.withValues(alpha: 0.58),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 320,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const ConceptTransport(play: 38, compact: true),
                          const SizedBox(height: 2),
                          AppleScrubber(key: ValueKey('bar${t.id}'), inBar: true, compact: true),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    // In a narrow window the volume folds away before the panels, as on the Mac.
                    Expanded(
                      flex: 7,
                      child: LayoutBuilder(
                        // The controls the room has, kept in order of need: like, the volume, Up Next, Lyrics, then the
                        // full-screen button (the cover opens Now Playing too).
                        // Measured: like and each button 48, the volume 122 after a gap of 6. The volume used to fold
                        // away first, at a guessed 245 when the four take 272: between the two the row overflowed (15 Oct)
                        builder: (context, box) {
                          var room = box.maxWidth;
                          bool fits(double width) {
                            if (width > room) return false;
                            room -= width;
                            return true;
                          }
                          final like = fits(48), volume = fits(6 + 122), upNext = fits(48), lyrics = fits(48), full = fits(48);
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (like) LikeButton(track: t),
                              if (lyrics)
                                _Toggle(
                                  icon: FluentIcons.comment_quote_24_regular,
                                  tip: 'Lyrics',
                                  onTap: () {
                                    p.panel = 'lyrics';
                                    p.setShowNowPlaying(true);
                                  },
                                ),
                              if (upNext)
                                _Toggle(
                                  icon: FluentIcons.text_bullet_list_ltr_24_regular,
                                  tip: 'Up Next',
                                  onTap: () {
                                    p.panel = 'upNext';
                                    p.setShowNowPlaying(true);
                                  },
                                ),
                              if (volume) ...[
                                const SizedBox(width: 6),
                                const AppleVolume(compact: true),
                              ],
                              // Now Playing over the whole window, as the design's full-screen button
                              if (full)
                                _Toggle(
                                  icon: FluentIcons.arrow_maximize_24_regular,
                                  tip: 'Now Playing',
                                  onTap: () {
                                    p.panel = 'none';
                                    p.setShowNowPlaying(true);
                                  },
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
        );
        // UI v2 (15 Oct): a computer's bar floats over the lists, so it is frosted glass: a blur of what scrolls under
        // it below a strong tint (a see-through fill alone let the songs' text read through it). The blur is drawn when
        // the bar is: once a second while a song plays
        return phone
            ? GlassSurface(radius: 22, child: bar)
            : HoverLift(
                builder: (_) => DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: [
                      BoxShadow(blurRadius: 30, offset: const Offset(0, 10), color: Colors.black.withValues(alpha: theme.brightness == Brightness.dark ? 0.45 : 0.14)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30), child: bar),
                  ),
                ),
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
  Widget build(BuildContext context) => IconButton(
    tooltip: tip,
    iconSize: 18,
    onPressed: onTap,
    icon: Icon(icon),
  );
}

/// A mute button and a volume slider. The slider uses the ink colour rather than the accent: the progress line
/// uses the accent, and the two controls must not read as one.
class Volume extends StatelessWidget {
  final double width;
  const Volume({super.key, required this.width});
  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final ink = Theme.of(context).colorScheme.onSurface;
    final icon = p.volume == 0
        ? FluentIcons.speaker_mute_24_regular
        : p.volume < 0.5
        ? FluentIcons.speaker_1_24_regular
        : FluentIcons.speaker_2_24_regular;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: p.volume == 0 ? 'Unmute' : 'Mute',
          iconSize: 18,
          onPressed: p.toggleMute,
          icon: Icon(icon),
        ),
        SizedBox(
          width: width,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: ink.withValues(alpha: 0.75),
              inactiveTrackColor: ink.withValues(alpha: 0.15),
              thumbColor: ink,
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 6,
                elevation: 1,
              ),
            ),
            child: Slider(value: p.volume, onChanged: p.setVolume),
          ),
        ),
      ],
    );
  }
}

/// The shuffle, skip, play and repeat controls, shared by the player bar and Now Playing. Listens to the player
/// directly: a `const` copy nested in the bar is not rebuilt when player state changes, so the play icon and the
/// shuffle and repeat indicators would go stale. An active mode uses the accent colour with a dot beneath it.
/// The play button is a solid disc.
class Transport extends StatelessWidget {
  final double size, play;
  const Transport({super.key, required this.size, required this.play});
  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    final accent = theme.colorScheme.primary;
    // Under a finger no control is smaller than 48: the compact row's shuffle and repeat were 40, its disc 44
    final touch = theme.platform == TargetPlatform.android || theme.platform == TargetPlatform.iOS;
    final modeBox = touch && size * 2.2 < 48 ? 48.0 : size * 2.2;
    final disc = touch && play < 48 ? 48.0 : play;
    // what the larger targets add comes out of the four gaps: the row is no wider, and still fits a narrow phone
    final gap = (size * 0.4 - ((modeBox - size * 2.2) * 2 + (disc - play)) / 4).clamp(0.0, size);
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final q = p.queue;
        Widget mode(IconData icon, String tip, bool on, VoidCallback tap) =>
            Tooltip(
              message: tip,
              child: InkResponse(
                onTap: tap,
                radius: size,
                child: SizedBox(
                  width: modeBox,
                  height: modeBox,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        icon,
                        size: size * 0.95,
                        color: on ? accent : ink.withValues(alpha: 0.5),
                      ),
                      if (on)
                        Positioned(
                          bottom: size * 0.12,
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                              color: accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
        Widget skip(IconData icon, String tip, VoidCallback tap) => IconButton(
          tooltip: tip,
          iconSize: size * 1.2,
          onPressed: tap,
          icon: Icon(icon),
          color: ink.withValues(alpha: 0.9),
        );
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            mode(
              FluentIcons.arrow_shuffle_24_regular,
              q.isShuffled ? 'Shuffle is on' : 'Shuffle',
              q.isShuffled,
              p.toggleShuffle,
            ),
            SizedBox(width: gap),
            skip(FluentIcons.previous_24_filled, 'Previous', p.previous),
            SizedBox(width: gap),
            // The solid disc is the control the eye finds first.
            SizedBox(
              width: disc,
              height: disc,
              child: p.isBuffering
                  ? Center(
                      child: Waiting(
                        size: disc * 0.55,
                        tooltip: 'Loading the song…',
                      ),
                    )
                  : Material(
                      color: ink,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: p.togglePlayPause,
                        child: Tooltip(
                          message: p.isPlaying ? 'Pause' : 'Play',
                          child: Icon(
                            p.isPlaying
                                ? FluentIcons.pause_24_filled
                                : FluentIcons.play_24_filled,
                            size: disc * 0.5,
                            color: theme.colorScheme.surface,
                          ),
                        ),
                      ),
                    ),
            ),
            SizedBox(width: gap),
            skip(FluentIcons.next_24_filled, 'Next', p.next),
            SizedBox(width: gap),
            mode(
              q.repeat == Repeat.one
                  ? FluentIcons.arrow_repeat_1_24_regular
                  : FluentIcons.arrow_repeat_all_24_regular,
              switch (q.repeat) {
                Repeat.off => 'Repeat',
                Repeat.all => 'Repeating the queue',
                Repeat.one => 'Repeating this song',
              },
              q.repeat != Repeat.off,
              p.cycleRepeat,
            ),
          ],
        );
      },
    );
  }
}

/// The seek bar with the elapsed and remaining times. Repaints once a second while a song plays and the window
/// is in front ([inFront]). Tap or drag to seek.
class Progress extends StatefulWidget {
  /// The player bar's line, which Now Playing covers when it is open: it does not tick then.
  final bool inBar;
  const Progress({super.key, this.inBar = false});
  @override
  State<Progress> createState() => _ProgressState();
}

class _ProgressState extends State<Progress> {
  double? _dragged;

  @override
  void initState() {
    super.initState();
    inFront.addListener(_frontChanged);
    secondTick.addListener(_ticked);
  }

  void _frontChanged() {
    if (inFront.value && mounted) {
      setState(() {}); // Show the correct time at once, not on the next tick.
    }
  }

  /// The app's one tick a second (in_front.dart): it stops while the window is behind others, and every time line on
  /// screen is drawn in the same frame.
  void _ticked() {
    if (!mounted) return;
    final p = Scope.of(context).player;
    // Under Now Playing the bar's line is hidden, but its tick still drew a frame each second, besides Now Playing's
    // own: two frames a second instead of one (about 8 ms each, see in_front.dart)
    if (widget.inBar && p.showNowPlaying) return;
    if (p.isPlaying && _dragged == null) setState(() {});
  }

  @override
  void dispose() {
    inFront.removeListener(_frontChanged);
    secondTick.removeListener(_ticked);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final ink = Theme.of(context).colorScheme.onSurface;
    final dur = p.duration;
    final pos = _dragged ?? p.position;
    final small = TextStyle(
      fontSize: 11,
      color: ink.withValues(alpha: 0.55),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return RepaintBoundary(
      child: Row(
        children: [
          SizedBox(
            width: textWidth(context, 38, 11),
            child: Text(
              formatTime(pos),
              maxLines: 1,
              textAlign: TextAlign.right,
              style: small,
            ),
          ),
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
          SizedBox(
            width: textWidth(context, 42, 11),
            child: Text('-${formatTime(dur - pos)}', maxLines: 1, style: small),
          ),
        ],
      ),
    );
  }
}
