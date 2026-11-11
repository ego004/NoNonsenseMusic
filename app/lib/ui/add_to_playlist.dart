import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/models.dart';
import 'glass_menu.dart';
import 'layout.dart';
import 'playlist_screen.dart';
import 'scope.dart';

/// "Add to Playlist…", the Spotify way: every playlist you may add to, with a ✓ where it already has the song and a + where
/// it does not. A + adds it; a ✓ asks what to do (Add Again, which makes a second row, or Remove, which takes out every row
/// of the song). A bottom sheet on a phone, a window on a computer. It was a menu of names that added the song a second
/// time without a word.
Future<void> showAddToPlaylist(BuildContext context, Track track) {
  if (isPhone(context)) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
      builder: (_) => AddToPlaylistSheet(track: track),
    );
  }
  return showGlassDialog<void>(
    context: context,
    builder: (_) => SizedBox(width: 380, height: 460, child: AddToPlaylistSheet(track: track)),
  );
}

class AddToPlaylistSheet extends StatefulWidget {
  final Track track;
  const AddToPlaylistSheet({super.key, required this.track});

  @override
  State<AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<AddToPlaylistSheet> {
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_asked) {
      _asked = true;
      Scope.of(context).library.loadMembership();
    }
  }

  Future<void> _tap(PlaylistSummary playlist) async {
    final library = Scope.of(context).library;
    final rows = library.entriesOf(widget.track, playlist.id);
    if (rows == null) return;
    if (rows.isEmpty) {
      await library.add(widget.track, playlist.id);
      return;
    }
    final choice = await showGlassDialog<String>(
      context: context,
      builder: (c) => GlassDialog(
        title: Text('Already in “${playlist.name}”'),
        content: Text('“${widget.track.title}” is in this playlist. A second copy makes it play twice.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, 'remove'), child: const Text('Remove from Playlist')),
          FilledButton(onPressed: () => Navigator.pop(c, 'again'), child: const Text('Add Again')),
        ],
      ),
    );
    if (choice == 'again') {
      await library.add(widget.track, playlist.id, allowDuplicate: true);
    } else if (choice == 'remove') {
      for (final id in rows) {
        await library.remove(id, playlist.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = Scope.of(context).library;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final editable = [for (final p in library.playlists) if (p.canEdit) p];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Add to Playlist', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text(widget.track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              ]),
            ),
            ListTile(
              leading: const Icon(FluentIcons.add_24_regular),
              title: const Text('New Playlist…'),
              onTap: () async {
                final navigator = Navigator.of(context);
                final name = await askName(context, title: 'New Playlist with “${widget.track.title}”');
                if (name != null) {
                  await library.createPlaylist(name, adding: widget.track);
                  if (navigator.mounted) navigator.pop();
                }
              },
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (editable.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No playlists yet.')),
                  for (final p in editable) _row(context, library, p),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, library, PlaylistSummary p) {
    final rows = library.entriesOf(widget.track, p.id) as List<String>?;
    final theme = Theme.of(context);
    return Semantics(
      label: p.name,
      value: rows == null ? 'Checking' : (rows.isEmpty ? 'Not added' : 'Already added'),
      child: ListTile(
        title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(rows != null && rows.isNotEmpty ? 'Already added' : songCount(p.songCount)),
        trailing: rows == null
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : rows.isEmpty
                ? Icon(FluentIcons.add_circle_24_regular, color: theme.colorScheme.onSurface.withValues(alpha: 0.6))
                : Icon(FluentIcons.checkmark_circle_24_filled, color: theme.colorScheme.primary),
        onTap: rows == null ? null : () => _tap(p),
      ),
    );
  }
}
