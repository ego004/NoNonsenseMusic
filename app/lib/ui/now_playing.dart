import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'browse_nav.dart';
import 'browse_widgets.dart';
import 'concept.dart';
import '../core/models.dart';
import '../core/settings.dart';
import 'copy_menu.dart';
import 'cover.dart';
import 'glass.dart';
import 'jam_panel.dart';
import 'layout.dart';
import 'lyrics_panel.dart';
import 'player_bar.dart';
import 'scope.dart';
import 'song_row.dart';

/// Displays the full-window Now Playing view: a large cover, the song details, progress and transport controls, with
/// the Up Next queue beside them. Rows in Up Next can be dragged to reorder, clicked to play, and dismissed
/// with the remove icon. Escape or the chevron closes the view.
class NowPlaying extends StatelessWidget {
  const NowPlaying({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            p.setShowNowPlaying(false),
      },
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: Listenable.merge([p, NowPlayingInk.behind]),
          builder: (context, _) {
            final t = p.current;
            if (t == null) return const SizedBox.shrink();
            final small = MediaQuery.sizeOf(context).width < 700 || MediaQuery.sizeOf(context).height < 600;
            final dark = theme.brightness == Brightness.dark;
            // the cover's opacity (Settings › Appearance › Surfaces › Now Playing › Colour strength), and the surface's
            // veil over it from top to bottom: the text reads on the cover where the veil is thinnest, at any strength
            // (NowPlayingInk, #20)
            final look = Look.of(context);
            final cover = Look.strong(look.nowPlayingColour, small ? (dark ? 0.55 : 0.4) : (dark ? 0.78 : 0.55));
            final veil = small ? const [0.35, 0.75] : const [0.5, 0.18, 0.82];
            final readable = NowPlayingInk(theme, share: cover * (1 - veil.reduce((a, b) => a < b ? a : b)));
            final backdrop = backdropFor(look, t.image, ink: readable);
            // the accent's text (the artists, a noted lyric, a mode that is on) reads on the cover's colours too
            final accent = readable.readable(theme.colorScheme.primary, backdrop == null ? const [] : NowPlayingInk.behind.value);
            return Theme(
              data: theme.copyWith(colorScheme: theme.colorScheme.copyWith(primary: accent)),
              child: Stack(
              fit: StackFit.expand,
              children: [
                if (small)
                  const PhoneBackdrop()
                else
                  ColoredBox(color: theme.colorScheme.surface),
                // The background takes the cover's colours (or the user's, Colours › Background), blurred once per song
                // and stretched by the GPU (CoverBackdrop): a live blur would be redrawn with every frame; this stays one
                // small texture. The concept (13 Oct): a computer's is stronger, strongest behind the song and deepening
                // toward the edges
                if (backdrop != null) Opacity(opacity: cover, child: backdrop),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: small ? null : const [0, 0.45, 1],
                      colors: [for (final a in veil) theme.colorScheme.surface.withValues(alpha: a)],
                    ),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, box) {
                    final info = Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            // the title has all the room the buttons leave, on one line as on the Mac and a computer.
                            // A Spacer beside it took half that room, so "Superstar" by Dox broke onto a second line
                            // on a phone with room to spare (#20)
                            Expanded(
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      t.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.4,
                                        height: 1.15,
                                      ),
                                    ),
                                  ),
                                  if (t.isExplicit)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 8),
                                      child: ExplicitBadge(),
                                    ),
                                ],
                              ),
                            ),
                            // the playing song's heart and its menu (Add to Playlist, Download), as a row has them
                            LikeButton(track: t, size: 22),
                            SongMoreButton(track: t, size: 22),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // the artists and the album open their pages (Now Playing closes first)
                        ArtistLinks(
                          artists: t.artists,
                          track: t,
                          style: TextStyle(
                            fontSize: 16,
                            color: ink.withValues(alpha: NowPlayingInk.secondary),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (t.albumTitle != null) ...[
                              Flexible(
                                child: Tooltip(
                                  message: 'Go to ${t.albumTitle}',
                                  child: InkWell(
                                    onTap: () => openBrowse(context, albumOf(t)),
                                    child: Text(
                                      t.albumTitle!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: ink.withValues(alpha: NowPlayingInk.secondary),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: Text(
                                  '·',
                                  style: TextStyle(
                                    color: ink.withValues(alpha: NowPlayingInk.tertiary),
                                  ),
                                ),
                              ),
                            ],
                            Flexible(child: CopyMenu(track: t)),
                          ],
                        ),
                      ],
                    );
                    final panel = p.panel == 'lyrics'
                        ? const LyricsPanel()
                        : JamUpNext(child: const UpNext());
                    final panelBox = BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: ink.withValues(alpha: 0.06)),
                    );
                    // Landscape phones need a compact row even when their width exceeds the portrait breakpoint.
                    final mobileLandscape =
                        box.maxHeight < 600 && box.maxWidth > box.maxHeight;
                    final phone = box.maxWidth < 700 || mobileLandscape;
                    final controlWidth = mobileLandscape
                        ? (box.maxWidth - 72) / 2
                        : box.maxWidth - 48;
                final mobileTransport = controlWidth < 300
                    ? const Transport(size: 18, play: 44)
                    : const Transport(size: 22, play: 56);
                    final artworkOrPanel = phone
                        ? AnimatedSwitcher(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 280),
                            reverseDuration:
                                MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 220),
                            layoutBuilder: (current, previous) => Stack(
                              fit: StackFit.expand,
                              children: [
                                ...previous,
                                ?current,
                              ],
                            ),
                            transitionBuilder: (child, animation) =>
                                phoneRevealTransition(
                                  child,
                                  animation,
                                  dy: 0.055,
                                ),
                            child: p.panel == 'none'
                                ? KeyedSubtree(
                                    key: const ValueKey('artwork-panel'),
                                    child: _FittedArtwork(t.image),
                                  )
                                : GlassSurface(
                                    key: ValueKey(p.panel),
                                    radius: 24,
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      14,
                                      10,
                                      10,
                                    ),
                                    child: panel,
                                  ),
                          )
                        : p.panel == 'none'
                        ? _FittedArtwork(t.image)
                        : Container(
                            decoration: panelBox,
                            padding: const EdgeInsets.fromLTRB(14, 14, 10, 10),
                            child: panel,
                          );
                    // Lyrics and Up Next; pressing the one shown hides it, leaving the song alone. On a phone they sit
                    // under the controls, where the thumb is: in the top corner they went unnoticed (13 Oct)
                    final panelButtons = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (id, icon, label) in [
                          ('lyrics', FluentIcons.comment_quote_24_regular, 'Lyrics'),
                          ('upNext', FluentIcons.text_bullet_list_ltr_24_regular, 'Up Next'),
                        ])
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: phone ? 14 : 3),
                            child: IconButton(
                              tooltip: p.panel == id ? 'Hide $label' : 'Show $label',
                              iconSize: phone ? 22 : 20,
                              style: IconButton.styleFrom(
                                backgroundColor: p.panel == id
                                    ? accent.withValues(alpha: 0.18)
                                    : Colors.transparent,
                              ),
                              color: p.panel == id ? accent : ink.withValues(alpha: 0.75),
                              onPressed: () => p.setPanel(id),
                              icon: Icon(icon),
                            ),
                          ),
                      ],
                    );
                    final body = phone
                        ? SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                54,
                                24,
                                12,
                              ),
                              child: mobileLandscape
                                  ? Row(
                                      children: [
                                        Expanded(child: artworkOrPanel),
                                        const SizedBox(width: 24),
                                        Expanded(
                                          child: LayoutBuilder(
                                            builder: (context, area) =>
                                                SingleChildScrollView(
                                                  child: ConstrainedBox(
                                                    constraints: BoxConstraints(
                                                      minHeight: area.maxHeight,
                                                    ),
                                                    child: Column(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceEvenly,
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        info,
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                        Progress(
                                                          key: ValueKey(
                                                            'np${t.id}',
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                        mobileTransport,
                                                        panelButtons,
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : Column(
                                      children: [
                                        Expanded(child: artworkOrPanel),
                                        const SizedBox(height: 12),
                                        info,
                                        const SizedBox(height: 8),
                                        GlassSurface(
                                          radius: 22,
                                          padding: const EdgeInsets.fromLTRB(
                                            8,
                                            8,
                                            8,
                                            10,
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Progress(
                                                key: ValueKey('np${t.id}'),
                                              ),
                                              const SizedBox(height: 4),
                                              mobileTransport,
                                              panelButtons,
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          )
                        : null;
                    if (body != null) {
                      return Stack(
                        children: [
                          Positioned(
                            left: 24,
                            top: MediaQuery.paddingOf(context).top + 8,
                            child: IconButton(
                              tooltip: 'Close (Esc)',
                              iconSize: 20,
                              style: IconButton.styleFrom(
                                backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.55),
                              ),
                              onPressed: () => p.setShowNowPlaying(false),
                              icon: const Icon(FluentIcons.chevron_down_24_regular),
                            ),
                          ),
                          body,
                        ],
                      );
                    }
                    // The concept (13 Oct): Apple Music's Now Playing on a computer. Everything below animates once,
                    // when it changes, and then holds still.
                    // the cover gives way to the controls: the window's height less the bar on top and the controls
                    final art = (box.maxHeight - 440).clamp(170.0, 470.0).toDouble();
                    const panelGap = 56.0, panelWidth = 380.0;
                    final title = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 320),
                          transitionBuilder: (child, a) => FadeTransition(
                            opacity: a,
                            child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a), child: child),
                          ),
                          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                          child: Column(key: ValueKey(t.id), crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Flexible(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontFamily: displayFont, fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -0.5, height: 1.15))),
                              if (t.isExplicit) const Padding(padding: EdgeInsets.only(left: 8), child: ExplicitBadge()),
                            ]),
                            const SizedBox(height: 3),
                            ArtistLinks(artists: t.artists, track: t, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: accent)),
                            const SizedBox(height: 4),
                            CopyMenu(track: t),
                          ]),
                        ),
                      ),
                      LikeButton(track: t, size: 22),
                      SongMoreButton(track: t, size: 22),
                    ]);
                    final column = SizedBox(
                      width: art,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Stagger(order: 0, child: SpringCover(image: t.image, id: t.id, size: art, playing: p.isPlaying || p.isBuffering)),
                        const SizedBox(height: 30),
                        Stagger(order: 1, child: title),
                        const SizedBox(height: 18),
                        Stagger(order: 2, child: AppleScrubber(key: ValueKey('scrub${t.id}'))),
                        const SizedBox(height: 12),
                        const Stagger(order: 3, child: ConceptTransport()),
                        const SizedBox(height: 14),
                        const Stagger(order: 4, child: AppleVolume()),
                      ]),
                    );
                    final glass = BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: dark ? 0.42 : 0.6),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: ink.withValues(alpha: 0.08)),
                      boxShadow: [BoxShadow(blurRadius: 40, offset: const Offset(0, 20), color: Colors.black.withValues(alpha: 0.18))],
                    );
                    return Stack(children: [
                      // the bar along the top: close, what is playing, and the two panels as pills
                      Positioned(
                        left: 24, right: 24, top: 16,
                        child: Stagger(
                          order: 0,
                          child: Stack(alignment: Alignment.center, children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Pressable(
                                tooltip: 'Close (Esc)',
                                onTap: () => p.setShowNowPlaying(false),
                                child: Container(
                                  width: 38, height: 38,
                                  decoration: BoxDecoration(color: ink.withValues(alpha: 0.08), shape: BoxShape.circle),
                                  child: Icon(FluentIcons.chevron_down_24_regular, size: 18, color: ink.withValues(alpha: 0.85)),
                                ),
                              ),
                            ),
                            // what is playing, over the middle of the window and the song: centred between the close
                            // button and the wider pills, it sat 77 points left of the song (15 Oct)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 220),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                Text('NOW PLAYING', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: ink.withValues(alpha: NowPlayingInk.secondary))),
                                if (t.albumTitle != null)
                                  Text(t.albumTitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ink.withValues(alpha: 0.85))),
                              ]),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                PillToggle(icon: FluentIcons.comment_quote_24_regular, label: 'Lyrics', on: p.panel == 'lyrics', onTap: () => p.setPanel('lyrics')),
                                const SizedBox(width: 8),
                                PillToggle(icon: FluentIcons.text_bullet_list_ltr_24_regular, label: 'Up Next', on: p.panel == 'upNext', onTap: () => p.setPanel('upNext')),
                              ]),
                            ),
                          ]),
                        ),
                      ),
                      Padding(
                        // as much room below as the bar takes above: the song sits in the middle of the window
                        padding: const EdgeInsets.fromLTRB(24, 64, 24, 64),
                        // a window shorter than the column scales it down whole rather than cutting the volume off the bottom
                        child: Center(child: FittedBox(fit: BoxFit.scaleDown,
                          // the song and the panel are centred together; the panel is as tall as the song, from the top
                          // of the cover to the volume
                          child: Stack(clipBehavior: Clip.none, children: [
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              column,
                              // the room the panel takes beside the song: the song moves over as it opens
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 420),
                                curve: Curves.easeOutCubic,
                                width: p.panel == 'none' ? 0 : panelGap + panelWidth,
                              ),
                            ]),
                            Positioned(
                              left: art + panelGap,
                              top: 0,
                              bottom: 0,
                              width: panelWidth,
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                transitionBuilder: (child, a) => FadeTransition(
                                  opacity: a,
                                  child: SlideTransition(position: Tween(begin: const Offset(0.08, 0), end: Offset.zero).animate(a), child: child),
                                ),
                                child: p.panel == 'none'
                                    ? const SizedBox.shrink(key: ValueKey('no panel'))
                                    : Container(
                                        key: ValueKey(p.panel),
                                        decoration: glass,
                                        padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
                                        child: panel,
                                      ),
                              ),
                            ),
                          ]),
                        )),
                      ),
                    ]);
                  },
                ),
              ],
            ),
            );
          },
        ),
      ),
    );
  }
}

/// Fits the whole cover into the actual space available after the mobile controls have been laid out.
/// Thumbnails elsewhere retain their usual cropped square appearance.
class _FittedArtwork extends StatelessWidget {
  const _FittedArtwork(this.image);
  final String? image;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, space) {
      final side = space.maxWidth < space.maxHeight
          ? space.maxWidth
          : space.maxHeight;
      return Center(
        child: Cover(
          image,
          key: const ValueKey('now-playing-artwork'),
          size: side,
          radius: 14,
          // filled and cropped, as every other cover and the Mac's Now Playing: a video's 16:9 thumbnail floated in
          // empty bands
        ),
      );
    },
  );
}

/// Lists the songs queued after the current one: drag to reorder, double-click to play, remove icon to drop a row.
/// Songs Autoplay added come after those the user queued, under their own heading. The ∞ switches Autoplay.
class UpNext extends StatelessWidget {
  const UpNext({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final p = s.player;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: NowPlayingInk.secondary); // reads on the cover (#20)
    // Built as a const child, it listens to the player itself; otherwise it would keep the queue from its first build.
    return ListenableBuilder(
      listenable: Listenable.merge([p, s.settings]),
      builder: (context, _) {
        final entries = p.queue.upcoming;
        final heading = entries.indexWhere(
          (e) => e.autoplay,
        ); // where Autoplay's part begins; -1: none
        // A tap or a click plays the song: it is already queued, so there is nothing to select it for. A phone
        // long-presses for the song's menu and drags by the handle, so a swipe scrolls (the whole row was draggable: a
        // swipe picked a song up instead, 13 Oct). A mouse right-clicks and drags the row.
        Widget row(Track t, int offset, int index) {
          void play() => p.jump(p.queue.index + 1 + offset);
          void menu(Offset at) => showSongMenu(
            context,
            at,
            t,
            play: play,
            remove: (label: 'Remove from Up Next', run: () => p.removeFromUpNext(offset)),
          );
          return GestureDetector(
            onTap: play,
            onLongPressStart: isTouchDevice ? (d) => menu(d.globalPosition) : null,
            onSecondaryTapUp: (d) => menu(d.globalPosition),
            child: ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 6),
              leading: Cover(t.image, size: 36),
              title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                t.artistLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    iconSize: 16,
                    tooltip: 'Remove from Up Next',
                    onPressed: () => p.removeFromUpNext(offset),
                    icon: const Icon(FluentIcons.dismiss_circle_24_filled),
                  ),
                  if (isTouchDevice)
                    ReorderableDragStartListener(
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(FluentIcons.re_order_dots_vertical_24_regular, size: 20, color: muted),
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 0, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Up Next',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  AutoplayButton(
                    on: s.settings.autoplay,
                    onPressed: () async {
                      await s.settings.setAutoplay(!s.settings.autoplay);
                      if (s.settings.autoplay) p.upNextChanged(); // just switched on: the queue may need songs now
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        isTouchDevice
                            ? 'Nothing queued. Play a list, or long-press a song › Play Next or Add to Queue.'
                            : 'Nothing queued. Play a list, or right-click a song › Play Next or Add to Queue.',
                        style: TextStyle(color: muted),
                      ),
                    )
                  // One queue: your songs, then Autoplay's under its heading, as on the Mac. Any song can be dragged anywhere;
                  // which side of the heading it lands on makes it yours or Autoplay's (12 Oct). The heading row stays put.
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: entries.length + (heading < 0 ? 0 : 1),
                      onReorderItem: (from, to) {
                        // `to` is the row's index after the move
                        if (from == heading) return;
                        if (heading < 0) return p.moveUpNext(from, to);
                        final rows = [
                          for (var i = 0; i <= entries.length; i++) i,
                        ]; // the heading's own row included
                        rows.insert(to, rows.removeAt(from));
                        final below = to > rows.indexOf(heading);
                        p.moveUpNext(
                          from > heading ? from - 1 : from,
                          below ? to - 1 : to,
                          autoplay: below,
                        );
                      },
                      itemBuilder: (context, i) {
                        if (i == heading) {
                          return Padding(
                            key: const ValueKey('upnext-autoplay-heading'),
                            padding: const EdgeInsets.fromLTRB(6, 14, 6, 4),
                            child: Text(
                              'Autoplay',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: muted,
                              ),
                            ),
                          );
                        }
                        final offset = heading >= 0 && i > heading ? i - 1 : i;
                        final child = row(entries[offset].track, offset, i);
                        return isTouchDevice
                            ? KeyedSubtree(key: ValueKey(entries[offset].key), child: child)
                            : ReorderableDragStartListener(key: ValueKey(entries[offset].key), index: i, child: child);
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// ∞ in the Up Next header: on, songs like the last one keep playing when the queue runs out.
class AutoplayButton extends StatelessWidget {
  final bool on;
  final VoidCallback onPressed;
  const AutoplayButton({super.key, required this.on, required this.onPressed});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: 'Autoplay',
      value: on ? 'On' : 'Off',
      child: IconButton(
        tooltip: on
            ? 'Autoplay is on: similar songs play when Up Next runs out'
            : 'Autoplay is off',
        iconSize: 20,
        onPressed: onPressed,
        color: on
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface.withValues(alpha: 0.55),
        icon: const Icon(Icons.all_inclusive),
      ),
    );
  }
}
