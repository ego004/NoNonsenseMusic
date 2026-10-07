import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/models.dart';
import 'scope.dart';
import 'song_row.dart';
import 'waiting.dart';

/// Search: a big bar, results under it. Waits 350 ms after typing stops, as the Mac app does.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _field = TextEditingController();
  List<Track> results = [];
  bool loading = false, failed = false;
  Timer? _wait;
  int _asked = 0;

  void _changed(String text) {
    _wait?.cancel();
    final q = text.trim();
    if (q.isEmpty) return setState(() { results = []; loading = false; failed = false; });
    setState(() => loading = true);
    _wait = Timer(const Duration(milliseconds: 350), () => _search(q));
  }

  Future<void> _search(String q) async {
    final mine = ++_asked;
    try {
      final found = await Api.search(q);
      if (mine != _asked) return; // a newer search started
      setState(() { results = found; loading = false; failed = false; });
      Api.prefetch(found.take(1).map((t) => t.best).toList()).catchError((_) {}); // the top result, ready
    } catch (_) {
      if (mine == _asked) setState(() { loading = false; failed = true; });
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      Padding(
        padding: EdgeInsets.fromLTRB(32, _field.text.isEmpty ? 120 : 28, 32, 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: TextField(
            controller: _field,
            autofocus: true,
            onChanged: _changed,
            onSubmitted: (q) { _wait?.cancel(); if (q.trim().isNotEmpty) _search(q.trim()); },
            style: const TextStyle(fontSize: 16),
            cursorWidth: 1.5,
            decoration: InputDecoration(
              hintText: 'Songs, artists, albums',
              hintStyle: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.45)),
              prefixIcon: Icon(FluentIcons.search_24_regular, size: 20, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
              suffixIcon: loading ? const Waiting(tooltip: 'Searching…') : null,
              filled: true,
              fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.055),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5)),
            ),
          ),
        ),
      ),
      Expanded(
        child: failed
            ? const _Empty('Can\'t reach your server', 'Is the backend running?', FluentIcons.plug_disconnected_24_regular)
            : !loading && results.isEmpty && _field.text.trim().isNotEmpty
                ? const _Empty('No results', 'Try another spelling.', FluentIcons.search_24_regular)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 120), // clear of the player bar
                    itemCount: results.length,
                    itemExtent: 58,
                    itemBuilder: (_, i) => SongRow(queue: results, index: i),
                  ),
      ),
    ]);
  }
}

/// Liked Songs and Recently Played: title, count, Play, Shuffle, the list.
class SongListScreen extends StatelessWidget {
  final bool liked;
  const SongListScreen({super.key, required this.liked});

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final tracks = (liked ? s.library.liked : s.library.recent).map((x) => x.track).toList();
        final title = liked ? 'Liked Songs' : 'Recently Played';
        if (tracks.isEmpty) {
          return !s.library.reachable
              ? _Empty('Can\'t reach your server', '$title comes from it.', FluentIcons.plug_disconnected_24_regular)
              : _Empty(liked ? 'No liked songs yet' : 'Nothing played yet',
                  liked ? 'Tap ♥ on any song to keep it here.' : 'Songs you play show up here.',
                  liked ? FluentIcons.heart_24_regular : FluentIcons.history_24_regular);
        }
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32, 36, 32, 22),
            sliver: SliverToBoxAdapter(
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.6)),
                    const SizedBox(height: 4),
                    Text('${tracks.length} songs', style: TextStyle(fontSize: 13.5, color: theme.colorScheme.onSurface.withValues(alpha: 0.55))),
                  ]),
                ),
                FilledButton.icon(onPressed: () => s.player.play(tracks), icon: const Icon(FluentIcons.play_24_filled, size: 16), label: const Text('Play')),
                const SizedBox(width: 10),
                OutlinedButton.icon(onPressed: () => s.player.play(tracks, startAt: 0, shuffled: true), icon: const Icon(FluentIcons.arrow_shuffle_24_regular, size: 16), label: const Text('Shuffle')),
              ]),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 120),
            sliver: SliverFixedExtentList.builder(itemExtent: 58, itemCount: tracks.length, itemBuilder: (_, i) => SongRow(queue: tracks, index: i)),
          ),
        ]);
      },
    );
  }
}

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
