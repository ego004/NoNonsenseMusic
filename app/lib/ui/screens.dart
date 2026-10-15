import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/download_store.dart';
import '../core/search_model.dart';
import 'browse_widgets.dart';
import 'concept.dart';
import 'download_button.dart';
import 'layout.dart';
import 'list_filter.dart';
import 'scope.dart';
import 'song_row.dart';
import 'storage_settings.dart';
import 'waiting.dart';
import 'glass_menu.dart';

/// Shows a search field with the matches below it: filter capsules under the field once something is typed, then
/// either all three kinds (an Artists shelf, an Albums shelf, then Songs) or a grid of one kind.
///
/// A query runs 350 ms after typing stops, the same delay the Mac app uses. Choosing a song plays that song alone:
/// the other results are not queued, and Autoplay fills Up Next with related songs.
class SearchScreen extends StatefulWidget {
  /// What to search for as it opens: the command bar's "All results".
  final String initial;
  const SearchScreen({super.key, this.initial = ''});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _field = TextEditingController();
  final _model = SearchModel();

  @override
  void initState() {
    super.initState();
    if (widget.initial.isNotEmpty) {
      _field.text = widget.initial;
      _model.typed(widget.initial);
      _model.submit();
    }
  }

  @override
  void dispose() {
    _field.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _model,
      builder: (context, _) {
        final m = _model;
        final phone = isPhone(context);
        final side = gutter(context);
        return Column(children: [
          Padding(
            // a computer's empty search stands lower in its tall window; a phone's is under the top bar either way
            padding: EdgeInsets.fromLTRB(side, phone ? phoneTop : (m.isIdle ? 120 : 28), side, phone && !m.isIdle ? 4 : 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(
                  controller: _field,
                  autofocus: true,
                  onChanged: m.typed,
                  onSubmitted: (_) => m.submit(),
                  style: const TextStyle(fontSize: 16),
                  cursorWidth: 1.5,
                  decoration: InputDecoration(
                    hintText: 'Songs, artists, albums',
                    hintStyle: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.45)),
                    prefixIcon: Icon(FluentIcons.search_24_regular, size: 20, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                    suffixIcon: m.loading ? const Waiting(tooltip: 'Searching…') : null,
                    filled: true,
                    fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.055),
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5)),
                  ),
                ),
                if (!m.isIdle) ...[
                  SizedBox(height: phone ? 4 : 12), // a phone's capsules reach 8 above what is drawn
                  FilterCapsules(selection: m.filter, onChanged: m.setFilter),
                  if (m.result.unavailable.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(didNotRespond(m.result.unavailable), style: theme.textTheme.bodySmall),
                  ],
                ],
              ]),
            ),
          ),
          Expanded(
            child: m.failed
                ? const _Empty('Can\'t reach your server', 'Is the backend running?', FluentIcons.plug_disconnected_24_regular)
                : m.showsNoResults
                    ? const _Empty('No results', 'Try another spelling.', FluentIcons.search_24_regular)
                    : m.isIdle ? const SizedBox.shrink() : _Results(model: m, side: side),
          ),
        ]);
      },
    );
  }
}

/// The matches: a grid of one kind for a filter, else the shelves and the songs.
class _Results extends StatelessWidget {
  final SearchModel model;
  final double side;
  const _Results({required this.model, required this.side});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String text) => SliverToBoxAdapter(
        child: Padding(padding: EdgeInsets.fromLTRB(side, 10, side, 8), child: Text(text, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))));
    final gridPad = EdgeInsets.fromLTRB(side, 8, side, bottomClearance(context, extra: 20));
    final songs = model.songs;
    return switch (model.filter) {
      SearchFilter.artists => CustomScrollView(slivers: [SliverPadding(padding: gridPad, sliver: ArtistGrid(artists: model.artists))]),
      SearchFilter.albums => CustomScrollView(slivers: [SliverPadding(padding: gridPad, sliver: AlbumGrid(albums: model.albums))]),
      _ => CustomScrollView(slivers: [
          if (model.artists.isNotEmpty) ...[
            heading('Artists'),
            SliverToBoxAdapter(child: ArtistShelf(artists: model.artists)),
          ],
          if (model.albums.isNotEmpty) ...[
            heading('Albums'),
            SliverToBoxAdapter(child: AlbumShelf(albums: model.albums)),
          ],
          if (songs.isNotEmpty && (model.artists.isNotEmpty || model.albums.isNotEmpty)) heading('Songs'),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(rowGutter(context), 0, rowGutter(context), bottomClearance(context, extra: 20)), // the last row clear of the player bar
            sliver: SliverFixedExtentList.builder(
              itemExtent: songRowExtent(context),
              itemCount: songs.length,
              // the song alone: Autoplay brings the related songs, the other results are not queued
              itemBuilder: (_, i) => SongRow(queue: [songs[i]], index: 0),
            ),
          ),
        ]),
    };
  }
}

/// Shows either the liked songs or the recently played tracks, chosen by [liked].
///
/// Renders the title, the song count, Play and Shuffle actions, then the list.
/// Liked Songs and Recently Played, from the server; Downloads, from this device (there with no server or internet).
class SongListScreen extends StatefulWidget {
  final bool liked;
  final bool downloads;

  /// The downloads to list; [DownloadStore.shared] when null (tests give their own).
  final DownloadStore? store;
  const SongListScreen({super.key, required this.liked})
      : downloads = false,
        store = null;
  const SongListScreen.downloads({super.key, this.store})
      : liked = false,
        downloads = true;
  @override
  State<SongListScreen> createState() => _SongListScreenState();
}

class _SongListScreenState extends State<SongListScreen> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /// Removes every download once the user confirms: the songs stay in the library and play from the internet.
  Future<void> _confirmRemoveAll(DownloadStore store) async {
    final n = store.items.length;
    final yes = await showGlassDialog<bool>(
      context: context,
      builder: (c) => GlassDialog(
        title: Text(n == 1 ? 'Remove the download?' : 'Remove all $n downloads?'),
        content: const Text('They stay in your library and still play from the internet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove All')),
        ],
      ),
    );
    if (yes == true) await store.removeAll();
  }

  @override
  Widget build(BuildContext context) {
    final liked = widget.liked, downloads = widget.downloads;
    final store = widget.store ?? DownloadStore.shared;
    final s = Scope.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, _filter, if (downloads) store]),
      builder: (context, _) {
        final tracks = downloads
            ? [for (final item in store.items) item.track] // newest first
            : (liked ? s.library.liked : s.library.recent).map((x) => x.track).toList();
        // Search narrows the rows; playing one plays what is shown, in that order
        final shown = _filter.text.isEmpty ? tracks : [for (final t in tracks) if (songMatches(t, _filter.text)) t];
        final title = downloads ? 'Downloads' : liked ? 'Liked Songs' : 'Recently Played';
        if (tracks.isEmpty && downloads) {
          return const _Empty('Nothing downloaded yet',
              "Choose Download in a song's menu, or a list's Download button. Downloads play without the server or the internet.",
              FluentIcons.arrow_download_24_regular);
        }
        if (tracks.isEmpty) {
          return !s.library.reachable
              ? _Empty('Can\'t reach your server', '$title comes from it.', FluentIcons.plug_disconnected_24_regular)
              : _Empty(liked ? 'No liked songs yet' : 'Nothing played yet',
                  liked ? 'Tap ♥ on any song to keep it here.' : 'Songs you play show up here.',
                  liked ? FluentIcons.heart_24_regular : FluentIcons.history_24_regular);
        }
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter(context), isPhone(context) ? phoneTop : 36, gutter(context), isPhone(context) ? 16 : 22),
            sliver: SliverToBoxAdapter(
              child: Builder(builder: (context) {
                final heading = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.headlineLarge?.copyWith(fontFamily: displayFont, fontWeight: FontWeight.w700, letterSpacing: -0.6)),
                  const SizedBox(height: 4),
                  Text(downloads ? '${songCount(tracks.length)}, ${formatBytes(store.totalBytes)}' : songCount(tracks.length),
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 13.5)),
                ]);
                final actions = Wrap(spacing: 10, runSpacing: 8, children: [
                  ActionPill(icon: FluentIcons.play_24_filled, label: 'Play', filled: true, onTap: () => s.player.play(tracks, wholeList: true)),
                  ActionPill(icon: FluentIcons.arrow_shuffle_24_regular, label: 'Shuffle', onTap: () => s.player.play(tracks, startAt: 0, shuffled: true, wholeList: true)),
                  if (downloads)
                    OutlinedButton.icon(
                        onPressed: () => _confirmRemoveAll(store),
                        icon: const Icon(FluentIcons.delete_24_regular, size: 16),
                        label: const Text('Remove All'))
                  else
                    DownloadAllButton(tracks: tracks),
                  FilterField(controller: _filter),
                ]);
                // three buttons do not fit beside the title on a phone: they go under it
                // the concept (13 Oct): the title, then the buttons, come in once
                final top = Stagger(order: 0, child: heading), buttons = Stagger(order: 1, child: actions);
                return isPhone(context)
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [top, const SizedBox(height: 12), buttons])
                    : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: top), buttons]);
              }),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(rowGutter(context), 0, rowGutter(context), bottomClearance(context)),
            sliver: shown.isEmpty
                ? SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(32), child: Center(child: Text('No songs match “${_filter.text}”'))))
                : SliverFixedExtentList.builder(itemExtent: songRowExtent(context), itemCount: shown.length, itemBuilder: (_, i) => SongRow(queue: shown, index: i)),
          ),
        ]);
      },
    );
  }
}

/// Shows a centered icon with a title and a detail line, used for empty lists and failures.
class _Empty extends StatelessWidget {
  final String title, detail;
  final IconData icon;
  const _Empty(this.title, this.detail, this.icon);
  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 44, color: muted),
        const SizedBox(height: 10),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(detail, style: TextStyle(color: muted)),
      ]),
    );
  }
}

/// "JioSaavn didn't respond. Search again to include it." for the sources whose results are missing.
String didNotRespond(List<String> sources) {
  final names = sources.length < 2 ? sources.join() : '${sources.sublist(0, sources.length - 1).join(', ')} and ${sources.last}';
  return "$names didn't respond. Search again to include ${sources.length < 2 ? 'it' : 'them'}.";
}
