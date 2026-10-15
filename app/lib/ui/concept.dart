// UI concept (13 Oct): Apple-style pieces for Now Playing and the player bar. Every animation here is one-shot: it
// runs when something changes (a press, a hover, a song, play/pause, a view opening) and stops, so an idle or playing
// window draws no extra frames. Nothing blurs live (a blur redraws every frame); the colour behind Now Playing is the
// cover, blurred once per song (CoverBackdrop).
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/cover_image.dart';
import '../core/play_queue.dart';
import 'cover.dart';
import 'in_front.dart';
import 'scope.dart';
import '../core/models.dart' show formatTime;
import 'waiting.dart';

/// Apple's spring: quick out, a small overshoot, settles. Used for presses, the cover and the volume swell.
const spring = Curves.easeOutBack;

/// The display face for big titles: Segoe UI Variable Display, Windows 11's optical size for headings.
const displayFont = 'Segoe UI Variable Display';

/// The lyrics' face: Figtree (bundled, assets/fonts), an open geometric font in the manner of Spotify's own, set as
/// Spotify sets its lyrics: extra bold, large, tightly spaced.
const lyricsFont = 'Figtree';
const lyricsStyle = TextStyle(fontFamily: lyricsFont, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6, height: 1.2);

/// Fades and lifts its child in once, [order] steps after its parent appears: Now Playing's elements arrive one after
/// another. Later rebuilds keep it still (the tween's end never changes).
class Stagger extends StatelessWidget {
  final int order;
  final Widget child;
  const Stagger({super.key, required this.order, required this.child});

  @override
  Widget build(BuildContext context) {
    const step = 55, run = 420;
    final total = run + order * step;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(order * step / total, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 18), child: child),
      ),
    );
  }
}

/// The cover, Apple Music's way: full size while the song plays, a little smaller when it pauses, springing between the
/// two; a new song's cover cross-fades in with a slight zoom. Its shadow takes the cover's own colour wash.
class SpringCover extends StatelessWidget {
  final String? image;
  final String id;
  final double size;
  final bool playing;
  const SpringCover({super.key, required this.image, required this.id, required this.size, required this.playing});

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.055;
    return AnimatedScale(
      scale: playing ? 1 : 0.86,
      duration: const Duration(milliseconds: 520),
      curve: spring,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              // a blur is drawn again with every frame (Impeller caches nothing), and its cost grows with its radius
              blurRadius: playing ? 32 : 18,
              spreadRadius: playing ? -2 : -6,
              offset: Offset(0, playing ? 18 : 8),
              color: Colors.black.withValues(alpha: playing ? 0.45 : 0.3),
            ),
          ],
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 380),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(a), child: child),
          ),
          child: Cover(image, key: ValueKey(id), size: size, radius: radius),
        ),
      ),
    );
  }
}

/// A control that dips when pressed and springs back: the feel of a physical button. Wraps any tappable child.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;
  final double depth;
  const Pressable({super.key, required this.child, this.onTap, this.tooltip, this.depth = 0.9});
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final body = MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? widget.depth : _hover ? 1.04 : 1,
          duration: Duration(milliseconds: _down ? 90 : 340),
          curve: _down ? Curves.easeOut : spring,
          child: widget.child,
        ),
      ),
    );
    return widget.tooltip == null ? body : Tooltip(message: widget.tooltip!, child: body);
  }
}

/// The big round play button: a disc in the song's accent colour; the icon turns from play to pause with a quick spin
/// and scale. Shows the hourglass while the song loads.
class PlayDisc extends StatelessWidget {
  final double size;
  const PlayDisc({super.key, required this.size});
  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final theme = Theme.of(context);
    final disc = theme.colorScheme.onSurface;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) => Pressable(
        tooltip: p.isPlaying ? 'Pause' : 'Play',
        onTap: p.togglePlayPause,
        depth: 0.86,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: disc,
            shape: BoxShape.circle,
          ),
          child: p.isBuffering
              ? Center(child: Waiting(size: size * 0.42, tooltip: 'Loading the song…'))
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: spring,
                  transitionBuilder: (child, a) => RotationTransition(
                    turns: Tween(begin: -0.12, end: 0.0).animate(a),
                    child: ScaleTransition(scale: a, child: child),
                  ),
                  child: Icon(
                    p.isPlaying ? FluentIcons.pause_24_filled : FluentIcons.play_24_filled,
                    key: ValueKey(p.isPlaying),
                    size: size * 0.42,
                    color: theme.colorScheme.surface,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Shuffle, previous, the play disc, next and repeat, spaced as on Apple Music. An active mode glows in the accent.
class ConceptTransport extends StatelessWidget {
  final double play;

  /// The player bar's size: smaller buttons, packed together.
  final bool compact;
  const ConceptTransport({super.key, this.play = 68, this.compact = false});
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
        Widget mode(IconData icon, String tip, bool on, VoidCallback tap) => Pressable(
              tooltip: tip,
              onTap: tap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                width: compact ? 30 : 40,
                height: compact ? 30 : 40,
                decoration: BoxDecoration(color: on ? accent.withValues(alpha: 0.16) : Colors.transparent, shape: BoxShape.circle),
                child: Icon(icon, size: compact ? 16 : 20, color: on ? accent : ink.withValues(alpha: 0.5)),
              ),
            );
        Widget skip(IconData icon, String tip, VoidCallback tap) => Pressable(
              tooltip: tip,
              onTap: tap,
              child: SizedBox(width: compact ? 34 : 48, height: compact ? 34 : 48, child: Icon(icon, size: compact ? 20 : 30, color: ink.withValues(alpha: 0.92))),
            );
        return Row(mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.spaceBetween, spacing: compact ? 6 : 0, children: [
          mode(FluentIcons.arrow_shuffle_24_regular, q.isShuffled ? 'Shuffle is on' : 'Shuffle', q.isShuffled, p.toggleShuffle),
          skip(FluentIcons.previous_24_filled, 'Previous', p.previous),
          PlayDisc(size: play),
          skip(FluentIcons.next_24_filled, 'Next', p.next),
          mode(
            q.repeat == Repeat.one ? FluentIcons.arrow_repeat_1_24_regular : FluentIcons.arrow_repeat_all_24_regular,
            switch (q.repeat) { Repeat.off => 'Repeat', Repeat.all => 'Repeating the queue', Repeat.one => 'Repeating this song' },
            q.repeat != Repeat.off,
            p.cycleRepeat,
          ),
        ]);
      },
    );
  }
}

/// Apple's volume: a quiet speaker at each end of a thin line that swells, and shows its knob, while the pointer is on
/// it or it is being dragged. The low speaker mutes; the high one turns it all the way up.
class AppleVolume extends StatefulWidget {
  final bool compact;
  const AppleVolume({super.key, this.compact = false});
  @override
  State<AppleVolume> createState() => _AppleVolumeState();
}

class _AppleVolumeState extends State<AppleVolume> {
  bool _hover = false, _dragging = false;
  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final ink = Theme.of(context).colorScheme.onSurface;
    final active = _hover || _dragging;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Row(mainAxisSize: widget.compact ? MainAxisSize.min : MainAxisSize.max, children: [
          Pressable(
            tooltip: p.volume == 0 ? 'Unmute' : 'Mute',
            onTap: p.toggleMute,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(p.volume == 0 ? FluentIcons.speaker_mute_24_regular : FluentIcons.speaker_1_24_regular,
                  size: 16, color: ink.withValues(alpha: active ? 0.85 : 0.5)),
            ),
          ),
          SizedBox(width: widget.compact ? 4 : 6),
          Builder(builder: (context) {
            final slider = TweenAnimationBuilder<double>(
              tween: Tween(end: active ? 1 : 0),
              duration: const Duration(milliseconds: 280),
              curve: spring,
              builder: (context, t, _) => SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4 + 4 * t,
                  activeTrackColor: ink.withValues(alpha: 0.62 + 0.3 * t),
                  inactiveTrackColor: ink.withValues(alpha: 0.14),
                  thumbColor: Colors.white,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7 * t.clamp(0, 1), elevation: 2 * t.clamp(0, 1), pressedElevation: 3),
                  overlayShape: SliderComponentShape.noOverlay,
                  trackShape: const RoundedRectSliderTrackShape(),
                ),
                child: Slider(
                  value: p.volume,
                  onChangeStart: (_) => setState(() => _dragging = true),
                  onChangeEnd: (_) => setState(() => _dragging = false),
                  onChanged: p.setVolume,
                ),
              ),
            );
            return widget.compact ? SizedBox(width: 84, child: slider) : Expanded(child: slider);
          }),
          // the bar has room for one speaker, as Apple's mini player; Now Playing has both ends
          if (!widget.compact) const SizedBox(width: 6),
          if (!widget.compact) Pressable(
            tooltip: 'Full volume',
            onTap: () => p.setVolume(1),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(FluentIcons.speaker_2_24_regular, size: 16, color: ink.withValues(alpha: active ? 0.85 : 0.5)),
            ),
          ),
          if (widget.compact) const SizedBox(width: 6),
        ]),
      ),
    );
  }
}

/// Apple Music's scrubber: a thin rounded line, played part in ink, that swells while the pointer is on it or it is being
/// dragged (a one-shot spring). The painter draws two rounded rectangles. Repaints once a second while the song plays
/// and the window is in front, as the old line did. Tap or drag anywhere on it to seek.
class AppleScrubber extends StatefulWidget {
  /// The player bar's line, which Now Playing covers when it is open: it does not tick then.
  final bool inBar;

  /// The bar's form: the times beside the line instead of under it.
  final bool compact;
  const AppleScrubber({super.key, this.inBar = false, this.compact = false});
  @override
  State<AppleScrubber> createState() => _AppleScrubberState();
}

class _AppleScrubberState extends State<AppleScrubber> {
  double? _dragged;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    inFront.addListener(_frontChanged);
    secondTick.addListener(_ticked);
  }

  void _frontChanged() {
    if (inFront.value && mounted) setState(() {});
  }

  /// The app's one tick a second (in_front.dart), shared with every other time line on screen.
  void _ticked() {
    if (!mounted) return;
    final p = Scope.of(context).player;
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
    final pos = (_dragged ?? p.position).clamp(0, dur > 0 ? dur : 0).toDouble();
    final active = _hover || _dragged != null;
    final small = TextStyle(fontSize: 11.5, color: ink.withValues(alpha: active ? 0.8 : 0.55), fontFeatures: const [FontFeature.tabularFigures()]);
    final line = LayoutBuilder(builder: (context, box) {
          double at(double x) => dur <= 0 ? 0 : (x / box.maxWidth).clamp(0, 1) * dur;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => p.seek(at(d.localPosition.dx)),
              onHorizontalDragStart: (d) => setState(() => _dragged = at(d.localPosition.dx)),
              onHorizontalDragUpdate: (d) => setState(() => _dragged = at(d.localPosition.dx)),
              onHorizontalDragEnd: (_) {
                final to = _dragged;
                setState(() => _dragged = null);
                if (to != null) p.seek(to);
              },
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: active ? 1 : 0),
                duration: const Duration(milliseconds: 280),
                curve: spring,
                builder: (context, swell, _) => CustomPaint(
                  size: Size(box.maxWidth, widget.compact ? 14 : 18),
                  painter: _LinePainter(dur > 0 ? pos / dur : 0, ink, widget.compact ? swell * 0.6 : swell),
                ),
              ),
            ),
          );
        });
    return RepaintBoundary(
      child: widget.compact
          ? Row(children: [
              SizedBox(width: 38, child: Text(formatTime(pos), textAlign: TextAlign.right, style: small)),
              const SizedBox(width: 8),
              Expanded(child: line),
              const SizedBox(width: 8),
              SizedBox(width: 42, child: Text('-${formatTime(dur - pos)}', style: small)),
            ])
          : Column(children: [
              line,
              const SizedBox(height: 4),
              Row(children: [
                Text(formatTime(pos), style: small),
                const Spacer(),
                Text('-${formatTime(dur - pos)}', style: small),
              ]),
            ]),
    );
  }
}

class _LinePainter extends CustomPainter {
  final double played, swell;
  final Color ink;
  _LinePainter(this.played, this.ink, this.swell);

  @override
  void paint(Canvas canvas, Size size) {
    final h = 4 + 5 * swell;
    final top = (size.height - h) / 2;
    final r = Radius.circular(h / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, top, size.width, h), r), Paint()..color = ink.withValues(alpha: 0.18));
    if (played > 0) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, top, size.width * played.clamp(0, 1), h), r),
          Paint()..color = ink.withValues(alpha: 0.65 + 0.3 * swell));
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.played != played || old.swell != swell || old.ink != ink;
}

/// A pill-shaped choice in Now Playing's corner (Lyrics, Up Next): fills in the accent when on.
class PillToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;
  const PillToggle({super.key, required this.icon, required this.label, required this.on, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    return Pressable(
      tooltip: on ? 'Hide $label' : 'Show $label',
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: on ? ink : ink.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: on ? theme.colorScheme.surface : ink.withValues(alpha: 0.8)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? theme.colorScheme.surface : ink.withValues(alpha: 0.85))),
        ]),
      ),
    );
  }
}

/// The floating bar's hover: it rises a little while the pointer is over it (one-shot).
class HoverLift extends StatefulWidget {
  final Widget Function(bool lifted) builder;
  const HoverLift({super.key, required this.builder});
  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _over = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: AnimatedSlide(
          offset: Offset(0, _over ? -0.03 : 0),
          duration: const Duration(milliseconds: 300),
          curve: spring,
          child: widget.builder(_over),
        ),
      );
}

/// Apple's Play and Shuffle: a pill with an icon and a word, filled in the accent or tinted with it.
class ActionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback? onTap;
  const ActionPill({super.key, required this.icon, required this.label, this.filled = false, this.onTap});
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final fg = filled ? Colors.white : accent;
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Pressable(
        onTap: onTap,
        // at least 128 wide, as Apple's pair, and wider for larger text
        child: Container(
          constraints: const BoxConstraints(minWidth: 128, minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(color: filled ? accent : accent.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 17, color: fg),
            const SizedBox(width: 7),
            Text(label, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: fg)),
          ]),
        ),
      ),
    );
  }
}

/// A round icon button in the same family as [ActionPill].
class RoundAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool on;
  const RoundAction({super.key, required this.icon, required this.tooltip, this.onTap, this.on = false});
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Pressable(
      tooltip: tooltip,
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: accent.withValues(alpha: on ? 0.24 : 0.13), shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: accent),
      ),
    );
  }
}

/// A page opened over the current screen comes in from the right, as a pushed page does on the Mac. It runs when the
/// page is first built; going back to a page that was kept does not run it again.
class PushIn extends StatelessWidget {
  final Widget child;
  const PushIn({super.key, required this.child});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 340),
        curve: Curves.easeOutCubic,
        child: child,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset((1 - t) * 36, 0), child: child),
        ),
      );
}

/// A cover on a shelf, Apple Music's way: under the pointer it lifts a little and casts a shadow, and a round play
/// button rises in its corner; a press dips it. The playing song's cover wears still bars in the accent instead.
/// Every change is one-shot. [onTap] opens or plays the whole; [onPlay], when given, is the corner button's.
class HoverCover extends StatefulWidget {
  final Widget child;
  final double size;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final bool playing;
  const HoverCover({super.key, required this.child, required this.size, this.radius = 10, this.onTap, this.onPlay, this.playing = false});
  @override
  State<HoverCover> createState() => _HoverCoverState();
}

class _HoverCoverState extends State<HoverCover> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final button = (widget.size * 0.26).clamp(22.0, 40.0);
    final inset = (widget.size * 0.055).clamp(4.0, 10.0);
    final showButton = _hover && widget.onPlay != null;
    final badge = showButton || widget.playing;
    // a small cover (a compact row) takes its mark in the middle, as a song row does; a large one in the corner
    final small = widget.size < 80;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.96 : _hover ? 1.035 : 1,
          duration: Duration(milliseconds: _down ? 90 : 320),
          curve: _down ? Curves.easeOut : spring,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              // only under the pointer: a shadow at rest would be drawn again with every frame for nothing
              boxShadow: [
                BoxShadow(
                  blurRadius: _hover ? 18 : 0,
                  offset: Offset(0, _hover ? 10 : 0),
                  color: Colors.black.withValues(alpha: _hover ? 0.32 : 0),
                ),
              ],
            ),
            child: Stack(children: [
              widget.child,
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _hover ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(widget.radius),
                        color: Colors.black.withValues(alpha: 0.16),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: small ? 0 : inset,
                bottom: small ? 0 : inset,
                left: small ? 0 : null,
                top: small ? 0 : null,
                child: Center(child: AnimatedScale(
                  scale: badge ? 1 : 0.5,
                  duration: const Duration(milliseconds: 300),
                  curve: spring,
                  child: AnimatedOpacity(
                    opacity: badge ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: GestureDetector(
                      onTap: showButton ? widget.onPlay : null,
                      child: Container(
                        width: button,
                        height: button,
                        decoration: BoxDecoration(
                          color: showButton ? accent : Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          showButton ? FluentIcons.play_24_filled : FluentIcons.data_bar_vertical_24_filled,
                          size: button * 0.46,
                          color: showButton ? Colors.white : accent,
                        ),
                      ),
                    ),
                  ),
                )),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Now Playing's backdrop: the cover, decoded at 64 pixels and blurred once when the song changes, then stretched by the
/// GPU to fill the window. It stays one still 64-pixel texture, so nothing is blurred again while the song plays. The
/// 12-pixel cover it replaces, stretched to the window, showed its pixels as soft blocks (15 Oct). The next song's
/// backdrop fades in over the last.
class CoverBackdrop extends StatefulWidget {
  final String url;
  const CoverBackdrop({super.key, required this.url});
  @override
  State<CoverBackdrop> createState() => _CoverBackdropState();
}

class _CoverBackdropState extends State<CoverBackdrop> {
  static const _px = 64;
  ui.Image? _shown, _leaving; // the backdrop, and the one it fades in over
  String? _wanted;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _load(widget.url);
  }

  @override
  void didUpdateWidget(CoverBackdrop old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load(widget.url);
  }

  void _load(String url) {
    _stop();
    _wanted = url;
    final listener = ImageStreamListener((info, _) {
      _stop();
      _blur(url, info);
    }, onError: (_, _) => _stop()); // no cover: the colour wash goes without it
    _stream = ResizeImage(coverProvider(url, px: _px), width: _px, height: _px).resolve(ImageConfiguration.empty)
      ..addListener(listener);
    _listener = listener;
  }

  void _stop() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = _listener = null;
  }

  Future<void> _blur(String url, ImageInfo info) async {
    final source = info.image;
    final area = Offset.zero & Size(source.width.toDouble(), source.height.toDouble());
    final recorder = ui.PictureRecorder();
    // mirrored at the edges, so the blur does not darken them
    Canvas(recorder).drawImageRect(source, area, area,
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5, tileMode: TileMode.mirror));
    final picture = recorder.endRecording();
    final blurred = await picture.toImage(source.width, source.height);
    picture.dispose();
    info.dispose();
    if (!mounted || url != _wanted) {
      blurred.dispose();
      return;
    }
    final gone = _leaving; // still drawn until this frame: released after it
    setState(() {
      _leaving = _shown;
      _shown = blurred;
    });
    if (gone != null) WidgetsBinding.instance.addPostFrameCallback((_) => gone.dispose());
  }

  void _faded() {
    final gone = _leaving;
    if (gone == null || !mounted) return;
    setState(() => _leaving = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => gone.dispose());
  }

  @override
  void dispose() {
    _stop();
    _shown?.dispose();
    _leaving?.dispose();
    super.dispose();
  }

  Widget _image(ui.Image image) =>
      RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium, width: double.infinity, height: double.infinity);

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.expand();
    return Stack(fit: StackFit.expand, children: [
      if (_leaving != null) _image(_leaving!),
      TweenAnimationBuilder<double>(
        key: ObjectKey(shown),
        tween: Tween(begin: _leaving == null ? 1 : 0, end: 1), // the first one is there at once
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOut,
        onEnd: _faded,
        builder: (_, opacity, child) => Opacity(opacity: opacity, child: child),
        child: _image(shown),
      ),
    ]);
  }
}

/// Frosted glass in the player's own colours: what is behind it, blurred, under the same see-through surface as Now
/// Playing's panel. For things that are open only for a moment (a Genius note on hover, its window): the blur is drawn
/// again with every frame they are open, and not at all once they close.
///
/// [appear] (0 to 1) brings it in: the blur, the surface and the content come up together. It must never be faded from
/// outside: a BackdropFilter under an Opacity blurs the empty layer the opacity draws into, so a fading card showed black
/// until the fade ended and then the glass all at once (15 Oct).
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double appear;
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.radius = 18, this.appear = 1});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);
    final a = appear.clamp(0.0, 1.0);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [BoxShadow(blurRadius: 30, offset: const Offset(0, 14), color: Colors.black.withValues(alpha: (dark ? 0.32 : 0.14) * a))],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24 * a, sigmaY: 24 * a),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: (dark ? 0.55 : 0.68) * a),
              borderRadius: shape,
              border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: (dark ? 0.12 : 0.08) * a)),
            ),
            // the content fades inside the glass, where an opacity layer does no harm
            child: Opacity(opacity: a, child: Padding(padding: padding, child: child)),
          ),
        ),
      ),
    );
  }
}
