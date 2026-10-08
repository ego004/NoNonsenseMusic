import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';

import 'home.dart';
import 'scope.dart';
import 'song_row.dart';
import 'waiting.dart';

/// One playlist: cover, name, count, Play, Shuffle, ⋯, the songs. What you may do follows your role (AUTH-3): yours
/// (owner): rename, share, public, delete, and edit the songs; shared with you as an editor: edit the songs, leave; as
/// a viewer: play, leave. Drag a song by its grip to move it; double-click plays; right-click has Remove.
class PlaylistScreen extends StatefulWidget {
  final String id;
  final VoidCallback onDeleted;
  const PlaylistScreen({super.key, required this.id, required this.onDeleted});
  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  // once per opening (the shell gives each playlist its own key), not on every theme or size change
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scope.of(context).library.loadPlaylist(widget.id).then((ok) {
        // 404: deleted, or no longer shared with you. It closes (the list has dropped it already)
        if (mounted && !ok) widget.onDeleted();
      });
    });
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final d = s.library.details[widget.id];
        if (d == null) return const Center(child: Waiting(size: 28));
        final tracks = d.tracks;
        final covers = tracks.map((t) => t.image).whereType<String>().toSet().take(4).toList();
        final minutes = (d.items.fold<int>(0, (a, i) => a + i.$2.duration) / 60).round();
        final p = d.summary;
        // who you are here, under the title: nothing for your own private playlist
        final standing = p.isOwner ? (p.public ? 'Public' : null) : 'Shared · ${p.canEdit ? 'Can make changes' : 'View only'}';
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32, 36, 32, 24),
            sliver: SliverToBoxAdapter(
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                PlaylistCover(covers: covers, size: 172, name: d.summary.name),
                const SizedBox(width: 22),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('PLAYLIST', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
                    Text(d.summary.name, maxLines: 2, style: theme.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold)),
                    Text('${d.items.length} songs · $minutes min', style: theme.textTheme.bodyMedium),
                    if (standing != null) Text(standing, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Row(children: [
                      FilledButton.icon(onPressed: tracks.isEmpty ? null : () => s.player.play(tracks, keys: d.keys, source: d.queueSource),
                          icon: const Icon(FluentIcons.play_24_filled, size: 18), label: const Text('Play')),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(onPressed: tracks.isEmpty ? null : () => s.player.play(tracks, keys: d.keys, source: d.queueSource, shuffled: true),
                          icon: const Icon(FluentIcons.arrow_shuffle_24_regular, size: 18), label: const Text('Shuffle')),
                      const SizedBox(width: 4),
                      PopupMenuButton<String>(
                        icon: const Icon(FluentIcons.more_horizontal_24_regular),
                        // only what your role allows: the server refuses the rest (403), so it is not offered
                        itemBuilder: (_) => p.isOwner
                            ? [
                                const PopupMenuItem(value: 'rename', child: Text('Rename…')),
                                const PopupMenuItem(value: 'share', child: Text('Share…')),
                                PopupMenuItem(value: 'public', child: Text(p.public ? 'Make Private' : 'Make Public')),
                                const PopupMenuDivider(),
                                const PopupMenuItem(value: 'delete', child: Text('Delete…')),
                              ]
                            : const [
                                PopupMenuItem(value: 'share', child: Text('People…')), // the same dialog, to look at
                                PopupMenuItem(value: 'leave', child: Text('Leave…')),
                              ],
                        onSelected: (v) async {
                          switch (v) {
                            case 'rename':
                              final name = await askName(context, title: 'Rename Playlist', initial: p.name);
                              if (name != null) await s.library.renamePlaylist(p.id, name);
                            case 'share':
                              final done = await share(context, p);
                              if (done != null) _say(done);
                            case 'public':
                              final error = await s.library.setPublic(p.id, !p.public);
                              _say(error ?? (p.public ? '“${p.name}” is private' : '“${p.name}” is public'));
                            case 'delete':
                              if (await confirm(context, 'Delete “${p.name}”?', 'Its songs stay in your library.')) {
                                await s.library.deletePlaylist(p.id);
                                widget.onDeleted();
                              }
                            case 'leave':
                              final me = s.auth.user;
                              if (me != null && await confirm(context, 'Leave “${p.name}”?', null, action: 'Leave')) {
                                final error = await s.library.leave(p.id, me.id);
                                if (error == null) {
                                  widget.onDeleted();
                                } else {
                                  _say(error);
                                }
                              }
                          }
                        },
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
          if (tracks.isEmpty)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: Text('No songs yet. Right-click any song › Add to Playlist.'))))
          else if (!p.canEdit)
            // a viewer: the songs to play, no grips and no Remove (the server would refuse both)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 22, 120),
              sliver: SliverList.builder(
                itemCount: d.items.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(left: 28),
                  child: SizedBox(height: 58, child: SongRow(queue: tracks, index: i, keys: d.keys, source: d.queueSource)),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 22, 120),
              sliver: SliverReorderableList(
                itemCount: d.items.length,
                onReorderItem: (from, to) => s.library.moveItem(d.summary.id, from, to),
                itemBuilder: (_, i) => Row(
                  key: ValueKey(d.items[i].$1),
                  children: [
                    ReorderableDragStartListener(
                      index: i,
                      child: const MouseRegion(cursor: SystemMouseCursors.grab, child: Padding(padding: EdgeInsets.all(6), child: Icon(FluentIcons.re_order_dots_vertical_24_regular, size: 16))),
                    ),
                    Expanded(
                      child: SizedBox(height: 58, child: SongRow(queue: tracks, index: i, keys: d.keys, source: d.queueSource,
                          removeFrom: (name: d.summary.name, remove: () => s.library.remove(d.items[i].$1, d.summary.id)))),
                    ),
                  ],
                ),
              ),
            ),
        ]);
      },
    );
  }
}

/// New Playlist and Rename: a name, or null.
Future<String?> askName(BuildContext context, {required String title, String initial = ''}) {
  final field = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(controller: field, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v.trim().isEmpty ? null : v.trim())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, field.text.trim().isEmpty ? null : field.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String? detail, {String action = 'Delete'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(title: Text(title), content: detail == null ? null : Text(detail), actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
      ]),
    ) ??
    false;

/// Who is on a playlist, and (its owner) inviting someone: a username and what they may do. Sharing again with the
/// same person changes their role; the owner removes people from the list. Someone it is shared with sees the list
/// only. The dialog stays open after an invite, so the new person shows in the list; Done closes it (8 Oct). The
/// server's reason stays in the dialog ("No account with that username"). Returns nothing to tell: it all shows here.
Future<String?> share(BuildContext context, PlaylistSummary p) {
  final library = Scope.of(context).library;
  final name = TextEditingController();
  var role = 'viewer';
  String? error;
  var busy = false;
  List<PlaylistMember>? members;
  var asked = false;
  return showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        Future<void> load() async {
          final found = await Api.members(p.id).catchError((_) => <PlaylistMember>[]);
          if (c.mounted) set(() => members = found);
        }

        if (!asked) {
          asked = true;
          load();
        }

        Future<void> go() async {
          final who = name.text.trim();
          if (who.isEmpty || busy) return;
          set(() { busy = true; error = null; });
          final e = await library.share(p.id, who, role);
          if (!c.mounted) return;
          set(() { busy = false; error = e; });
          if (e == null) {
            name.clear();
            await load();
          }
        }

        Future<void> remove(PlaylistMember m) async {
          try {
            await Api.removeMember(p.id, m.userId);
            await load();
          } catch (e) {
            if (c.mounted) set(() => error = e.toString());
          }
        }

        final theme = Theme.of(c);
        return AlertDialog(
          title: Text(p.isOwner ? 'Share “${p.name}”' : 'People on “${p.name}”'),
          content: SizedBox(
            width: 340,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final m in members ?? const <PlaylistMember>[])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Icon(Icons.account_circle_outlined, size: 20, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(child: Text(m.username)),
                    Text(m.roleName, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    if (p.isOwner && m.role != 'owner')
                      IconButton(icon: const Icon(Icons.remove_circle_outline, size: 20), tooltip: 'Remove ${m.username}', onPressed: () => remove(m)),
                  ]),
                ),
              if (p.isOwner) ...[
                const SizedBox(height: 10),
                TextField(controller: name, autofocus: true, enabled: !busy, decoration: const InputDecoration(labelText: 'Username'), onSubmitted: (_) => go()),
                const SizedBox(height: 14),
                SegmentedButton<String>(
                  segments: const [ButtonSegment(value: 'viewer', label: Text('View only')), ButtonSegment(value: 'editor', label: Text('Can make changes'))],
                  selected: {role},
                  onSelectionChanged: busy ? null : (v) => set(() => role = v.first),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Done')),
            if (p.isOwner) FilledButton(onPressed: busy ? null : go, child: const Text('Share')),
          ],
        );
      },
    ),
  );
}
