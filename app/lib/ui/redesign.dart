// UI v2 (15 Oct): the home-screen redesign on a computer. Floating glass panels over the window's own background
// (Settings › Window, drawn by Windows: no blur of the app's own, so no CPU for it), lit by the playing cover (CoverGlow);
// a sidebar with the logo, the places and the playlists; on Home a line of greeting, the song playing with Up Next,
// shelves that scroll by a button, and the library as one grid. Search is the command bar at the top (command_bar.dart).
// A phone keeps its own layout.

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/download_store.dart';
import '../core/jam.dart';
import '../core/models.dart';
import '../core/player.dart';
import '../core/settings.dart';
import '../core/social.dart';
import 'concept.dart';
import 'cover.dart';
import 'friends.dart';
import 'home.dart';
import 'in_front.dart';
import 'jam_panel.dart';
import 'layout.dart';
import 'popover.dart';
import 'scope.dart';
import 'song_row.dart';

/// The fill of a glass panel over the window's background: more of it where less is behind (Clear has no blur, a solid
/// window no see-through at all), never so little that the text on it stops reading.
Color panelFill(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (Look.of(context).material) {
    WindowMaterial.glass => dark ? const Color(0xFF1B1B20).withValues(alpha: 0.42) : Colors.white.withValues(alpha: 0.5),
    WindowMaterial.acrylic => dark ? Colors.white.withValues(alpha: 0.05) : Colors.white.withValues(alpha: 0.4),
    WindowMaterial.mica => dark ? Colors.white.withValues(alpha: 0.045) : Colors.white.withValues(alpha: 0.55),
    WindowMaterial.solidDark || WindowMaterial.solidLight =>
      Theme.of(context).colorScheme.onSurface.withValues(alpha: dark ? 0.045 : 0.035),
    WindowMaterial.clear => dark ? const Color(0xFF141418).withValues(alpha: 0.7) : Colors.white.withValues(alpha: 0.75),
  };
}

/// The tint of glass that floats over the content (the player bar), with a blur under it: strong enough that what
/// scrolls beneath shows only as a hint of colour (at 74% the bar read as too see-through, 15 Oct). Settings ›
/// Appearance › Surfaces › Player bar › Transparency fills in the rest of it, up to solid.
Color floatingFill(BuildContext context) {
  final fill = Look.of(context).solid(0.88);
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF1E1E23).withValues(alpha: fill)
      : Colors.white.withValues(alpha: fill);
}

/// A panel of the redesign: rounded glass with a hairline edge. Its fill only, no blur: the window's background is the
/// glass behind it.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  const GlassPanel({super.key, required this.child, this.padding = EdgeInsets.zero, this.radius = 22});

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: panelFill(context),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: ink.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.1 : 0.08)),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(radius), child: Padding(padding: padding, child: child)),
    );
  }
}

/// The logo's mark, in the colour of the text around it.
class BrandMark extends StatelessWidget {
  final double height;
  const BrandMark({super.key, this.height = 22});
  @override
  Widget build(BuildContext context) => Image.asset('assets/icon/mark-white.png',
      height: height, color: Theme.of(context).colorScheme.onSurface, colorBlendMode: BlendMode.srcIn, filterQuality: FilterQuality.medium);
}

/// Liked Songs, Recently Played and Downloads as a square tile: a gradient and the collection's icon.
enum Collection {
  liked('Liked Songs', FluentIcons.heart_24_filled, [Color(0xFFF26B9B), Color(0xFF9B4DE0)]),
  recent('Recently Played', FluentIcons.history_24_filled, [Color(0xFF5B8DEF), Color(0xFF3557B7)]),
  downloads('Downloads', FluentIcons.arrow_download_24_filled, [Color(0xFF8A8F98), Color(0xFF4B5058)]);

  final String label;
  final IconData icon;
  final List<Color> colors;
  const Collection(this.label, this.icon, this.colors);
}

class CollectionTile extends StatelessWidget {
  final Collection kind;
  final double size;
  const CollectionTile(this.kind, {super.key, required this.size});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.18),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: kind.colors),
        ),
        child: Icon(kind.icon, color: Colors.white, size: size * 0.45),
      );
}

String songs(int n) => n == 1 ? '1 song' : '$n songs';

/// A username as a name to greet: its first letter a capital ("sam" is greeted as Sam).
String displayName(String username) => username.isEmpty ? '' : username[0].toUpperCase() + username.substring(1);

/// The sidebar's places: a rounded row, filled when it is the one shown.
class NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;
  const NavItem({super.key, required this.icon, required this.label, required this.selected, required this.onTap, this.trailing});
  @override
  State<NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<NavItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 44,
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: widget.selected ? ink.withValues(alpha: 0.12) : _hover ? ink.withValues(alpha: 0.06) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.selected ? ink.withValues(alpha: 0.1) : Colors.transparent),
          ),
          child: Row(children: [
            Icon(widget.icon, size: 20, color: ink.withValues(alpha: widget.selected ? 1 : 0.78)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14.5, fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500, color: ink.withValues(alpha: widget.selected ? 1 : 0.85))),
            ),
            ?widget.trailing,
          ]),
        ),
      ),
    );
  }
}

/// A collection or a playlist in the sidebar: its picture, its name and how many songs.
class SidebarRow extends StatefulWidget {
  final Widget picture;
  final String name;
  final String detail;
  final bool selected;
  final VoidCallback onTap;
  const SidebarRow({super.key, required this.picture, required this.name, required this.detail, required this.selected, required this.onTap});
  @override
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: widget.selected ? ink.withValues(alpha: 0.12) : _hover ? ink.withValues(alpha: 0.06) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: 40, height: 40, child: widget.picture)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ink.withValues(alpha: 0.95))),
                const SizedBox(height: 1),
                Text(widget.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: ink.withValues(alpha: 0.55))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Where the sidebar can take the user, and which one is shown.
class SidebarPlaces {
  final bool home, library, friends, settings;
  final Collection? collection;
  final String? playlistId;
  const SidebarPlaces({this.home = false, this.library = false, this.friends = false, this.settings = false, this.collection, this.playlistId});
}

/// The redesign's sidebar: the logo, the places, the playlists, and the signed-in user with Settings. Search is at the
/// top of the page (CommandBar), not here: one box, not two.
class DesktopSidebar extends StatelessWidget {
  final SidebarPlaces shown;
  final VoidCallback openHome, openLibrary, openFriends, openSettings, newPlaylist;
  final void Function(Collection) openCollection;
  final void Function(String id) openPlaylist;
  const DesktopSidebar({
    super.key,
    required this.shown,
    required this.openHome,
    required this.openLibrary,
    required this.openFriends,
    required this.openSettings,
    required this.newPlaylist,
    required this.openCollection,
    required this.openPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final name = s.auth.user?.username ?? '';
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(14, 20, 14, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(children: [
            const BrandMark(height: 20),
            const SizedBox(width: 10),
            Flexible(child: Text('NoNonsenseMusic', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: ink))),
          ]),
        ),
        const SizedBox(height: 22),
        NavItem(icon: FluentIcons.home_24_regular, label: 'Home', selected: shown.home, onTap: openHome),
        NavItem(icon: FluentIcons.library_24_regular, label: 'Library', selected: shown.library, onTap: openLibrary),
        NavItem(icon: FluentIcons.people_24_regular, label: 'Friends', selected: shown.friends, onTap: openFriends, trailing: RequestCount()),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Divider(height: 1, color: ink.withValues(alpha: 0.08)),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(children: [
            Expanded(child: Text('Playlists', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ink.withValues(alpha: 0.6)))),
            IconButton(tooltip: 'New Playlist', icon: const Icon(FluentIcons.add_24_regular, size: 18), onPressed: newPlaylist),
          ]),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([s.library, DownloadStore.shared]),
            builder: (context, _) {
              final lib = s.library;
              Widget collection(Collection c, int n) => SidebarRow(
                    picture: CollectionTile(c, size: 40),
                    name: c.label,
                    detail: songs(n),
                    selected: shown.collection == c,
                    onTap: () => openCollection(c),
                  );
              Widget playlist(PlaylistSummary p) {
                final covers = lib.details[p.id]?.tracks.map((t) => t.image).whereType<String>().toSet().take(4).toList() ?? const <String>[];
                return SidebarRow(
                  picture: PlaylistCover(covers: covers, size: 40, name: p.name),
                  name: p.name,
                  detail: songs(p.songCount),
                  selected: shown.playlistId == p.id,
                  onTap: () => openPlaylist(p.id),
                );
              }
              return ListView(padding: EdgeInsets.zero, children: [
                collection(Collection.liked, lib.liked.length),
                collection(Collection.recent, lib.recent.length),
                if (DownloadStore.shared.folder != null) collection(Collection.downloads, DownloadStore.shared.items.length),
                for (final p in lib.ownPlaylists) playlist(p),
                if (lib.sharedPlaylists.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 12, 0, 4),
                    child: Text('Shared with you', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ink.withValues(alpha: 0.5))),
                  ),
                for (final p in lib.sharedPlaylists) playlist(p),
              ]);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Divider(height: 1, color: ink.withValues(alpha: 0.08)),
        ),
        const SizedBox(height: 10),
        Row(children: [
          const SizedBox(width: 4),
          Avatar(name: name, size: 34),
          const SizedBox(width: 10),
          Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ink))),
          IconButton(
            tooltip: 'Settings',
            onPressed: openSettings,
            style: IconButton.styleFrom(backgroundColor: shown.settings ? ink.withValues(alpha: 0.12) : null),
            icon: const Icon(FluentIcons.settings_24_regular, size: 20),
          ),
        ]),
      ]),
    );
  }
}

/// The top right of a computer's window: Jam beside the bell, in one glass pill. Jam is here only, not in the sidebar
/// too (15 Oct).
class TopActions extends StatelessWidget {
  final Widget bell;
  const TopActions({super.key, required this.bell});
  @override
  Widget build(BuildContext context) => GlassPanel(
        radius: 22,
        // the hover and press shades are drawn over the glass, not under its fill
        child: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            height: 44,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const _JamPill(),
              Container(width: 1, height: 20, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1)),
              SizedBox(width: 44, child: Center(child: bell)),
            ]),
          ),
        ),
      );
}

/// Jam in the top pill: it opens the jam's panel under it, and says LIVE while the user is in one.
class _JamPill extends StatelessWidget {
  const _JamPill();
  @override
  Widget build(BuildContext context) {
    final jam = JamSession.shared;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: jam,
      builder: (context, _) {
        final live = jam.inJam;
        final ink = live ? scheme.primary : scheme.onSurface.withValues(alpha: 0.85);
        return Builder(
          builder: (anchor) => Tooltip(
            message: live ? 'Jam' : 'Start or Join a Jam',
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => showPanel(anchor, builder: (_) => JamPanel(jam: jam, social: Social.shared)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(live ? FluentIcons.people_team_24_filled : FluentIcons.people_team_24_regular, size: 20, color: ink),
                  const SizedBox(width: 8),
                  Text('Jam', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ink)),
                  if (live) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10)),
                      child: Text('LIVE', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: scheme.primary)),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Home's top on a computer (15 Oct): the song playing, large, with what comes next from Up Next beside it (under it in
/// a narrower window); with nothing playing, the last song played, to pick up again. Only the time line moves, once a
/// second while the song plays and the window is in front: the rest is drawn again when the song, its state or Up Next
/// changes.
class NowHero extends StatelessWidget {
  /// A phone shows only the song to pick up again: while one plays, the player bar under the page is already it.
  final bool resumeOnly;
  const NowHero({super.key, this.resumeOnly = false});

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final p = s.player;
    return ListenableBuilder(
      listenable: Listenable.merge([p, s.library]),
      builder: (context, _) {
        final current = p.current;
        if (current == null) {
          final last = s.library.recent.firstOrNull?.track;
          return last == null ? const SizedBox.shrink() : _ResumeCard(track: last);
        }
        if (resumeOnly) return const SizedBox.shrink();
        final next = p.nextSongs; // the room's in a jam
        final now = _NowCard(track: current);
        if (next.isEmpty) return now;
        return LayoutBuilder(
          builder: (context, box) => box.maxWidth < 900
              ? Column(children: [now, const SizedBox(height: 16), _UpNextCard(next: next)])
              : IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(flex: 3, child: now),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: _UpNextCard(next: next)),
                  ]),
                ),
        );
      },
    );
  }
}

/// The white round play button of Home's cards.
class _RoundPlay extends StatelessWidget {
  final bool playing;
  final double size;
  final VoidCallback onTap;
  const _RoundPlay({required this.playing, required this.onTap, this.size = 48});
  @override
  Widget build(BuildContext context) => Pressable(
        tooltip: playing ? 'Pause' : 'Play',
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: Icon(playing ? FluentIcons.pause_24_filled : FluentIcons.play_24_filled, color: const Color(0xFF111114), size: size * 0.46),
        ),
      );
}

class _NowCard extends StatelessWidget {
  final Track track;
  const _NowCard({required this.track});

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    final playing = p.isPlaying || p.isBuffering;
    return GlassPanel(
      padding: const EdgeInsets.all(20),
      child: Row(children: [
        GestureDetector(
          onTap: () => p.setShowNowPlaying(true),
          child: MouseRegion(cursor: SystemMouseCursors.click, child: Cover(track.image, size: 148, radius: 12)),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(playing ? 'NOW PLAYING' : 'PAUSED',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 2, color: theme.colorScheme.primary)),
            const SizedBox(height: 6),
            // the editorial type: the title as the page's headline
            Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: displayFont, fontFamilyFallback: appFontFallbacks, fontSize: 42, fontWeight: FontWeight.w800, letterSpacing: -1.2, height: 1.1, color: ink)),
            const SizedBox(height: 2),
            Text(track.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: ink.withValues(alpha: 0.65))),
            const SizedBox(height: 18),
            Row(children: [
              _RoundPlay(playing: playing, onTap: p.togglePlayPause, size: 44),
              const SizedBox(width: 16),
              const Expanded(child: _NowLine()),
              const SizedBox(width: 4),
              Builder(
                builder: (anchor) => IconButton(
                  tooltip: 'More',
                  icon: Icon(FluentIcons.more_horizontal_24_regular, size: 20, color: ink.withValues(alpha: 0.8)),
                  onPressed: () {
                    final box = anchor.findRenderObject() as RenderBox;
                    showSongMenu(anchor, box.localToGlobal(box.size.bottomLeft(Offset.zero)), track);
                  },
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// How far the song has got: a line and "0:26 / 3:36" in figures of one width, so the numbers do not shift. It is
/// the only part of Home that moves while a song plays: once a second, with the player bar, and only while the window
/// is in front.
class _NowLine extends StatefulWidget {
  const _NowLine();
  @override
  State<_NowLine> createState() => _NowLineState();
}

class _NowLineState extends State<_NowLine> {
  @override
  void initState() {
    super.initState();
    inFront.addListener(_ticked);
    secondTick.addListener(_ticked);
  }

  /// The app's one tick a second (in_front.dart), the player bar's too: both lines are drawn in one frame. Back in
  /// front, the time is right at once.
  void _ticked() {
    if (mounted && inFront.value && Scope.of(context).player.isPlaying) setState(() {});
  }

  @override
  void dispose() {
    inFront.removeListener(_ticked);
    secondTick.removeListener(_ticked);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final ink = Theme.of(context).colorScheme.onSurface;
    final share = p.duration > 0 ? (p.position / p.duration).clamp(0.0, 1.0) : 0.0;
    return Row(children: [
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 4,
            child: Stack(fit: StackFit.expand, children: [
              ColoredBox(color: ink.withValues(alpha: 0.12)),
              FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: share, child: ColoredBox(color: ink.withValues(alpha: 0.8))),
            ]),
          ),
        ),
      ),
      // a box of its own size: the time changing never lays out the card again
      SizedBox(
        width: textWidth(context, 104, 12.5),
        child: Text('${formatTime(p.position)} / ${formatTime(p.duration)}',
            textAlign: TextAlign.right,
            maxLines: 1,
            style: TextStyle(fontSize: 12.5, color: ink.withValues(alpha: 0.6), fontFeatures: const [FontFeature.tabularFigures()])),
      ),
    ]);
  }
}

/// Up Next on Home: the next three songs; one clicked plays now, See all opens Up Next itself.
class _UpNextCard extends StatelessWidget {
  final List<NextSong> next;
  const _UpNextCard({required this.next});

  @override
  Widget build(BuildContext context) {
    final p = Scope.of(context).player;
    final ink = Theme.of(context).colorScheme.onSurface;
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text('Up Next', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ink.withValues(alpha: 0.85))),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              p.panel = 'upNext';
              p.setShowNowPlaying(true);
            },
            style: TextButton.styleFrom(foregroundColor: ink.withValues(alpha: 0.7)),
            child: const Text('See all'),
          ),
        ]),
        for (final song in next.take(3)) _SongLine(track: song.track, onTap: song.play),
      ]),
    );
  }
}

/// A song as one line: its cover, title and artists, and its length.
class _SongLine extends StatefulWidget {
  final Track track;
  final VoidCallback onTap;
  const _SongLine({required this.track, required this.onTap});
  @override
  State<_SongLine> createState() => _SongLineState();
}

class _SongLineState extends State<_SongLine> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final t = widget.track;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(color: _hover ? ink.withValues(alpha: 0.06) : null, borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Cover(t.image, size: 40, radius: 6),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ink)),
                Text(t.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: ink.withValues(alpha: 0.55))),
              ]),
            ),
            const SizedBox(width: 8),
            Text(formatTime(t.duration.toDouble()),
                style: TextStyle(fontSize: 12.5, color: ink.withValues(alpha: 0.5), fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ),
      ),
    );
  }
}

/// With nothing playing: the last song played, and a button to play on from it.
class _ResumeCard extends StatelessWidget {
  final Track track;
  const _ResumeCard({required this.track});

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    void play() => s.player.play(s.library.recent.map((x) => x.track).toList(), startAt: 0);
    return GlassPanel(
      padding: const EdgeInsets.all(18),
      child: Row(children: [
        GestureDetector(
          onTap: play,
          child: MouseRegion(cursor: SystemMouseCursors.click, child: Cover(track.image, size: 84, radius: 10)),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('PICK UP AGAIN', // one line on a phone too (it took two, 20 Oct)
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 2, color: ink.withValues(alpha: 0.55))),
            const SizedBox(height: 6),
            Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: displayFont, fontFamilyFallback: appFontFallbacks, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6, color: ink)),
            Text(track.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, color: ink.withValues(alpha: 0.65))),
          ]),
        ),
        const SizedBox(width: 16),
        _RoundPlay(playing: false, onTap: play, size: 52),
      ]),
    );
  }
}

/// A shelf's heading: its title, and "See all" where there is more.
class ShelfHeading extends StatelessWidget {
  final String title;
  final VoidCallback? seeAll;
  final EdgeInsetsGeometry padding;
  const ShelfHeading(this.title, {super.key, this.seeAll, this.padding = EdgeInsets.zero});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    return Padding(
      padding: padding,
      child: Row(children: [
        Expanded(
          child: Text(title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontFamily: displayFont, letterSpacing: -0.3)),
        ),
        if (seeAll != null)
          TextButton(
            onPressed: seeAll,
            style: TextButton.styleFrom(foregroundColor: ink.withValues(alpha: 0.7)),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [Text('See all'), SizedBox(width: 4), Icon(FluentIcons.chevron_right_24_regular, size: 14)]),
          ),
      ]),
    );
  }
}

/// A sideways shelf with a round "more" button over its right end, which moves it on by most of its width. It is cut off
/// at the content's margins ([padding]), as the rest of the page is: it ran on to the window's edge (15 Oct).
class ArrowShelf extends StatefulWidget {
  final double height;
  final int itemCount;
  final double gap;
  final EdgeInsetsGeometry padding;
  final IndexedWidgetBuilder itemBuilder;
  const ArrowShelf({super.key, required this.height, required this.itemCount, required this.itemBuilder, this.gap = 20, this.padding = EdgeInsets.zero});
  @override
  State<ArrowShelf> createState() => _ArrowShelfState();
}

class _ArrowShelfState extends State<ArrowShelf> {
  final _scroll = ScrollController();
  bool _more = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!_scroll.hasClients) return;
    final more = _scroll.position.pixels < _scroll.position.maxScrollExtent - 4;
    if (more != _more) setState(() => _more = more);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final pad = widget.padding.resolve(Directionality.of(context));
    return SizedBox(
      height: widget.height,
      child: Stack(children: [
        ClipRect(
          clipper: _SidesOnly(pad.left, pad.right),
          child: ListView.separated(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: widget.padding,
            itemCount: widget.itemCount,
            separatorBuilder: (_, _) => SizedBox(width: widget.gap),
            itemBuilder: widget.itemBuilder,
          ),
        ),
        Positioned(
          right: (pad.right - 20).clamp(8.0, double.infinity),
          top: 0,
          bottom: 0,
          child: Center(
            child: AnimatedOpacity(
              opacity: _more ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_more,
                child: Pressable(
                  tooltip: 'More',
                  onTap: () => _scroll.animateTo(
                    (_scroll.offset + _scroll.position.viewportDimension * 0.8).clamp(0.0, _scroll.position.maxScrollExtent),
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                  ),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
                      shape: BoxShape.circle,
                      border: Border.all(color: ink.withValues(alpha: 0.12)),
                      boxShadow: [BoxShadow(blurRadius: 12, color: Colors.black.withValues(alpha: 0.25))],
                    ),
                    child: Icon(FluentIcons.chevron_right_24_regular, size: 18, color: ink),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Clips a shelf at the content's margins only: the covers' shadows still fall above and below it.
class _SidesOnly extends CustomClipper<Rect> {
  final double left, right;
  const _SidesOnly(this.left, this.right);
  @override
  Rect getClip(Size size) => Rect.fromLTRB(left, -60, size.width - right, size.height + 60);
  @override
  bool shouldReclip(_SidesOnly old) => old.left != left || old.right != right;
}

/// Home's "Your Library" on a computer (15 Oct): Liked Songs, Downloads and every playlist as one grid of small tiles,
/// each its picture, name and size. Recently Played is above it already, as Jump back in.
class LibraryShelf extends StatelessWidget {
  final void Function(Collection) openCollection;
  final void Function(String id) openPlaylist;
  const LibraryShelf({super.key, required this.openCollection, required this.openPlaylist});

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, DownloadStore.shared]),
      builder: (context, _) {
        final lib = s.library;
        final tiles = <Widget>[
          _LibraryTile(
            picture: const CollectionTile(Collection.liked, size: 52),
            name: Collection.liked.label,
            detail: songs(lib.liked.length),
            onTap: () => openCollection(Collection.liked),
          ),
          if (DownloadStore.shared.folder != null)
            _LibraryTile(
              picture: const CollectionTile(Collection.downloads, size: 52),
              name: Collection.downloads.label,
              detail: songs(DownloadStore.shared.items.length),
              onTap: () => openCollection(Collection.downloads),
            ),
          for (final p in [...lib.ownPlaylistsOnly, ...lib.pinnedAlbums, ...lib.sharedPlaylists])
            _PlaylistTile(playlist: p, onTap: () => openPlaylist(p.id)),
        ];
        return LayoutBuilder(builder: (context, box) {
          const gap = 12.0;
          final columns = (box.maxWidth / 300).floor().clamp(2, 5);
          final width = (box.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(spacing: gap, runSpacing: gap, children: [for (final t in tiles) SizedBox(width: width, child: t)]);
        });
      },
    );
  }
}

class _LibraryTile extends StatefulWidget {
  final Widget picture;
  final String name, detail;
  final VoidCallback onTap;
  const _LibraryTile({required this.picture, required this.name, required this.detail, required this.onTap});
  @override
  State<_LibraryTile> createState() => _LibraryTileState();
}

class _LibraryTileState extends State<_LibraryTile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Color.alphaBlend(ink.withValues(alpha: _hover ? 0.06 : 0), panelFill(context)),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: ink.withValues(alpha: 0.08)),
          ),
          child: Row(children: [
            widget.picture,
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: ink)),
                const SizedBox(height: 2),
                Text(widget.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: ink.withValues(alpha: 0.55))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A playlist's tile: its cover is made from its songs' covers, so its songs load when the tile first shows and again
/// when the count changes (as Home's playlist cards do).
class _PlaylistTile extends StatefulWidget {
  final PlaylistSummary playlist;
  final VoidCallback onTap;
  const _PlaylistTile({required this.playlist, required this.onTap});
  @override
  State<_PlaylistTile> createState() => _PlaylistTileState();
}

class _PlaylistTileState extends State<_PlaylistTile> {
  @override
  void initState() {
    super.initState();
    _loadIfStale();
  }

  @override
  void didUpdateWidget(_PlaylistTile old) {
    super.didUpdateWidget(old);
    if (old.playlist.songCount != widget.playlist.songCount) _loadIfStale();
  }

  void _loadIfStale() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final library = Scope.of(context).library;
        if (library.details[widget.playlist.id]?.tracks.length != widget.playlist.songCount) library.loadPlaylist(widget.playlist.id);
      });

  @override
  Widget build(BuildContext context) {
    final p = widget.playlist;
    final covers = Scope.of(context).library.details[p.id]?.tracks.map((t) => t.image).whereType<String>().toSet().take(4).toList() ?? const <String>[];
    return _LibraryTile(
      picture: PlaylistCover(covers: covers, size: 52, name: p.name),
      name: p.name,
      detail: songs(p.songCount),
      onTap: widget.onTap,
    );
  }
}

/// The window lit softly by Colours › Background (15 Oct), on a computer: the playing song's cover (Song, the default)
/// or the user's colour (Custom), as Now Playing's backdrop (blurred once per song into a still 64-pixel picture the GPU
/// stretches), seen through a veil of the window's own colour, so the text reads as it does without it. It is drawn
/// again only when the song changes, fading to the next over 0.6 s. Background › System leaves it out; Surfaces › Main
/// area › Colour strength makes it softer, never stronger: the window shows the cover as it is (#20 keeps only Now
/// Playing's text readable on it), and the text on the window has only this veil over the cover.
class CoverGlow extends StatelessWidget {
  const CoverGlow({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    final look = Look.of(context);
    final dark = theme.brightness == Brightness.dark;
    final veil = theme.colorScheme.surface;
    if (look.background == ColourMode.system) return const SizedBox.shrink();
    return ValueListenableBuilder<String?>(
      valueListenable: s.player.currentId,
      builder: (context, _, _) {
        final backdrop = backdropFor(look, s.player.current?.image);
        if (backdrop == null) return const SizedBox.shrink();
        return RepaintBoundary(
          child: IgnorePointer(
            child: Stack(fit: StackFit.expand, children: [
              Opacity(opacity: Look.strong(look.artStrength, dark ? 0.55 : 0.4), child: backdrop),
              // strongest at the top, where the eye starts; calmer under the lists
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [veil.withValues(alpha: 0), veil.withValues(alpha: dark ? 0.5 : 0.45)],
                  ),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}
