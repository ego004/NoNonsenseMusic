import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/models.dart';
import 'cover.dart';
import 'scope.dart';

/// The first screen, as on the Mac: a greeting; Jump back in (recently played covers in a sideways shelf); your
/// playlists; Liked Songs as compact rows three high. A shelf moves only sideways. No fade-ups: nothing animates.
class Home extends StatelessWidget {
  final void Function(String playlistId) openPlaylist;
  const Home({super.key, required this.openPlaylist});

  static String greeting(DateTime t) => t.hour < 5 ? 'Good night' : t.hour < 12 ? 'Good morning' : t.hour < 17 ? 'Good afternoon' : 'Good evening';

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final lib = s.library;
        final recent = lib.recent.map((x) => x.track).take(20).toList();
        final liked = lib.liked.map((x) => x.track).toList();
        Widget title(String t) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(t, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)));
        return ListView(padding: const EdgeInsets.fromLTRB(32, 28, 32, 120), children: [
          Text(greeting(DateTime.now()), style: theme.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 28),
          if (!lib.reachable)
            const _Note('Can\'t reach your server', 'Your library lives on it.', FluentIcons.plug_disconnected_24_regular)
          else if (recent.isEmpty && liked.isEmpty && lib.playlists.isEmpty)
            const _Note('Your music lives here', 'Search for a song you love, then play it, like it, or add it to a playlist.', FluentIcons.music_note_2_24_regular),
          if (recent.isNotEmpty) ...[
            title('Jump back in'),
            SizedBox(
              height: 210,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: recent.length,
                separatorBuilder: (_, _) => const SizedBox(width: 20),
                itemBuilder: (_, i) => _CoverTile(track: recent[i], onPlay: () => s.player.play(lib.recent.map((x) => x.track).toList(), startAt: i)),
              ),
            ),
            const SizedBox(height: 32),
          ],
          if (lib.ownPlaylists.isNotEmpty) ...[
            title('Your playlists'),
            Wrap(spacing: 22, runSpacing: 22, children: [
              for (final p in lib.ownPlaylists) _PlaylistCard(playlist: p, onOpen: () => openPlaylist(p.id)),
            ]),
            const SizedBox(height: 32),
          ],
          if (lib.sharedPlaylists.isNotEmpty) ...[
            title('Shared with you'),
            Wrap(spacing: 22, runSpacing: 22, children: [
              for (final p in lib.sharedPlaylists) _PlaylistCard(playlist: p, onOpen: () => openPlaylist(p.id)),
            ]),
            const SizedBox(height: 32),
          ],
          if (liked.isNotEmpty) ...[
            title('Liked Songs'),
            SizedBox(
              height: 3 * 62,
              child: GridView.builder(
                scrollDirection: Axis.horizontal,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisExtent: 300, crossAxisSpacing: 4, mainAxisSpacing: 16),
                itemCount: liked.take(24).length,
                itemBuilder: (_, i) => _CompactTile(track: liked[i], onPlay: () => s.player.play(liked, startAt: i)),
              ),
            ),
          ],
        ]);
      },
    );
  }
}

class _CoverTile extends StatelessWidget {
  final Track track;
  final VoidCallback onPlay;
  const _CoverTile({required this.track, required this.onPlay});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onPlay,
        child: SizedBox(
          width: 148,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Cover(track.image, size: 148, radius: 10),
            const SizedBox(height: 8),
            Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(track.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
}

class _PlaylistCard extends StatelessWidget {
  final PlaylistSummary playlist;
  final VoidCallback onOpen;
  const _PlaylistCard({required this.playlist, required this.onOpen});
  @override
  Widget build(BuildContext context) {
    final detail = Scope.of(context).library.details[playlist.id];
    final covers = detail?.tracks.map((t) => t.image).whereType<String>().toSet().take(4).toList() ?? [];
    return GestureDetector(
      onTap: onOpen,
      child: SizedBox(
        width: 148,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PlaylistCover(covers: covers, size: 148, name: playlist.name),
          const SizedBox(height: 8),
          Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text('${playlist.songCount} songs', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

/// The first four covers in a 2×2 grid, one cover for fewer, a soft gradient (coloured by the name) for none.
class PlaylistCover extends StatelessWidget {
  final List<String> covers;
  final double size;
  final String name;
  const PlaylistCover({super.key, required this.covers, required this.size, required this.name});
  @override
  Widget build(BuildContext context) {
    if (covers.length >= 4) {
      final h = size / 2;
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(width: size, height: size, child: Wrap(children: [for (final c in covers.take(4)) Cover(c, size: h, radius: 0)])),
      );
    }
    if (covers.isNotEmpty) return Cover(covers.first, size: size, radius: 10);
    final hue = (name.codeUnits.fold(0, (a, b) => a + b) * 37 % 360).toDouble();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(colors: [HSLColor.fromAHSL(1, hue, 0.45, 0.45).toColor(), HSLColor.fromAHSL(1, (hue + 40) % 360, 0.5, 0.3).toColor()]),
      ),
      child: Icon(FluentIcons.music_note_2_24_regular, color: Colors.white70, size: size * 0.3),
    );
  }
}

class _CompactTile extends StatelessWidget {
  final Track track;
  final VoidCallback onPlay;
  const _CompactTile({required this.track, required this.onPlay});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onPlay,
        child: Row(children: [
          Cover(track.image, size: 48),
          const SizedBox(width: 10),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              Text(track.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
      );
}

class _Note extends StatelessWidget {
  final String title, detail;
  final IconData icon;
  const _Note(this.title, this.detail, this.icon);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(children: [
          Icon(icon, size: 44),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          Text(detail, textAlign: TextAlign.center),
        ]),
      );
}
