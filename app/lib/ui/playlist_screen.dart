import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/api.dart';
import '../core/catalog.dart';

import 'browse_nav.dart';
import 'friends.dart';
import 'glass_menu.dart';
import 'home.dart';
import 'account_settings.dart';
import 'concept.dart';
import 'layout.dart';
import 'list_filter.dart';
import 'scope.dart';
import 'download_button.dart';
import 'song_row.dart';
import 'waiting.dart';

/// Shows one playlist: cover, name, song count, Play, Shuffle, the overflow menu and the songs.
///
/// [id] selects the playlist and [onDeleted] fires when it is deleted or is no longer reachable. Actions follow the
/// user's role: an owner may rename, share, publish, delete and edit the songs; an editor may edit the songs and
/// leave; a viewer may only play and leave. Drag a song by its grip to move it, double-click to play it, and
/// right-click for Remove.
class PlaylistScreen extends StatefulWidget {
  final String id;
  final VoidCallback onDeleted;
  const PlaylistScreen({super.key, required this.id, required this.onDeleted});
  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  // The shell gives each playlist its own key, so this runs once per opening, not on every theme or size change.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scope.of(context).library.loadPlaylist(widget.id).then((ok) {
        // A 404 means the playlist was deleted or is no longer shared. The list has dropped it already, so close.
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
      listenable: Listenable.merge([s.library, _filter]),
      builder: (context, _) {
        final d = s.library.details[widget.id];
        if (d == null) return const Center(child: Waiting(size: 28));
        final tracks = d.tracks;
        final covers = tracks.map((t) => t.image).whereType<String>().toSet().take(4).toList();
        final minutes = (d.items.fold<int>(0, (a, i) => a + i.$2.duration) / 60).round();
        final p = d.summary;
        // Standing under the title: null for the user's own private playlist, which needs no label.
        final phone = isPhone(context);
        // A computer's rows start 28 in, level with the rows that have a grip; a phone's are cards on the gutter.
        final rowPad = EdgeInsets.fromLTRB(phone ? gutter(context) : 16, 0, rowGutter(context), bottomClearance(context));
        final noGrip = EdgeInsets.only(left: phone ? 0 : 28);
        final standing = p.isOwner ? (p.public ? 'Public' : null) : 'Shared · ${p.canEdit ? 'Can make changes' : 'View only'}';
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter(context), phone ? phoneTop : 36, gutter(context), phone ? 16 : 24),
            sliver: SliverToBoxAdapter(
              // A phone: the cover above the name and the buttons. Beside a 172 cover they had 150 of its width, and
              // the buttons stood one to a line (13 Oct). Flex 0 lets the text take its own height in the column.
              // The concept (13 Oct): the cover, then the text, come in once
              child: Flex(direction: phone ? Axis.vertical : Axis.horizontal, crossAxisAlignment: phone ? CrossAxisAlignment.start : CrossAxisAlignment.end, children: [
                Stagger(order: 0, child: PlaylistCover(covers: covers, size: phone ? 148 : 200, name: d.summary.name)),
                SizedBox(width: phone ? 0 : 28, height: phone ? 16 : 0),
                Expanded(
                  flex: phone ? 0 : 1,
                  child: Stagger(order: 1, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.isAlbum ? 'ALBUM' : 'PLAYLIST', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 1.4)),
                    const SizedBox(height: 4),
                    Text(d.summary.name, maxLines: 2, style: theme.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w700, fontFamily: displayFont, letterSpacing: -0.5)),
                    Text('${d.items.length} songs · $minutes min', style: theme.textTheme.bodyMedium),
                    if (standing != null) Text(standing, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      ActionPill(icon: FluentIcons.play_24_filled, label: 'Play', filled: true,
                          onTap: tracks.isEmpty ? null : () => s.player.play(tracks, keys: d.keys, source: d.queueSource, wholeList: true)),
                      ActionPill(icon: FluentIcons.arrow_shuffle_24_regular, label: 'Shuffle',
                          onTap: tracks.isEmpty ? null : () => s.player.play(tracks, keys: d.keys, source: d.queueSource, shuffled: true, wholeList: true)),
                      DownloadAllButton(tracks: tracks),
                      if (p.canEdit && !p.isAlbum) ImportIntoPlaylistButton(playlistId: widget.id),
                      if (tracks.isNotEmpty) FilterField(controller: _filter),
                      GlassMenuButton<String>(
                        icon: const Icon(FluentIcons.more_horizontal_24_regular),
                        // Only what the role allows: the server refuses anything else with 403, so it is not offered.
                        entries: () => p.isAlbum
                            // a pinned album is a copy of the source's album: nothing to rename, share or reorder
                            ? [
                                if (p.source != null && p.sourceId != null) const GlassMenuEntry('album', 'Go to Album'),
                                const GlassMenuEntry.divider(),
                                const GlassMenuEntry('unpin', 'Unpin from Home'),
                              ]
                            : p.isOwner
                            ? [
                                const GlassMenuEntry('rename', 'Rename…'),
                                const GlassMenuEntry('share', 'Share…'),
                                GlassMenuEntry('public', p.public ? 'Make Private' : 'Make Public'),
                                const GlassMenuEntry.divider(),
                                const GlassMenuEntry('delete', 'Delete…'),
                              ]
                            : const [
                                GlassMenuEntry('share', 'People…'), // The same dialog, read-only.
                                GlassMenuEntry('leave', 'Leave…'),
                              ],
                        onSelected: (v) async {
                          switch (v) {
                            case 'album':
                              openBrowse(context, AlbumTarget(AlbumRef(
                                  source: p.source!, id: p.sourceId!, title: p.name, songCount: p.songCount)));
                            case 'unpin':
                              final problem = await s.library.unpin(p);
                              if (problem == null) {
                                widget.onDeleted();
                              } else {
                                _say(problem);
                              }
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
                  ])),
                ),
              ]),
            ),
          ),
          if (tracks.isEmpty)
            SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(40), child: Center(child: Text('No songs yet. ${phone ? 'Press and hold' : 'Right-click'} any song › Add to Playlist.', textAlign: TextAlign.center))))
          else if (_filter.text.isNotEmpty)
            // Search narrows the rows: playing one plays what is shown (as its own queue, not kept in step with the
            // playlist, which would bring the hidden songs back); no dragging while some songs are hidden
            Builder(builder: (context) {
              final shown = [for (var i = 0; i < tracks.length; i++) if (songMatches(tracks[i], _filter.text)) i];
              final shownTracks = [for (final i in shown) tracks[i]];
              return SliverPadding(
                padding: rowPad,
                sliver: shown.isEmpty
                    ? SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(32), child: Center(child: Text('No songs match “${_filter.text}”'))))
                    : SliverList.builder(
                        itemCount: shown.length,
                        itemBuilder: (_, row) => Padding(
                          padding: noGrip,
                          child: SizedBox(height: songRowExtent(context), child: SongRow(queue: shownTracks, index: row,
                              removeFrom: p.canEdit
                                  ? (name: d.summary.name, remove: () => s.library.remove(d.items[shown[row]].$1, d.summary.id))
                                  : null)),
                        ),
                      ),
              );
            })
          else if (!p.canEdit)
            // A viewer gets the songs to play, without grips or Remove, which the server would refuse.
            SliverPadding(
              padding: rowPad,
              sliver: SliverList.builder(
                itemCount: d.items.length,
                itemBuilder: (_, i) => Padding(
                  padding: noGrip,
                  child: SizedBox(height: songRowExtent(context), child: SongRow(queue: tracks, index: i, keys: d.keys, source: d.queueSource, number: p.isAlbum ? i + 1 : null)),
                ),
              ),
            )
          else
            SliverPadding(
              // the grip has 12 beside its dots on a phone: the dots, not their box, stand on the gutter
              padding: phone ? rowPad.copyWith(left: gutter(context) - 12) : rowPad,
              sliver: SliverReorderableList(
                itemCount: d.items.length,
                onReorderItem: (from, to) => s.library.moveItem(d.summary.id, from, to),
                itemBuilder: (_, i) => Row(
                  key: ValueKey(d.items[i].$1),
                  children: [
                    ReorderableDragStartListener(
                      index: i,
                      // a finger needs more to take hold of than a pointer: 40 wide and the row's height on a phone
                      child: MouseRegion(cursor: SystemMouseCursors.grab, child: Padding(padding: phone ? const EdgeInsets.symmetric(horizontal: 12, vertical: 16) : const EdgeInsets.all(6), child: const Icon(FluentIcons.re_order_dots_vertical_24_regular, size: 16))),
                    ),
                    Expanded(
                      child: SizedBox(height: songRowExtent(context), child: SongRow(queue: tracks, index: i, keys: d.keys, source: d.queueSource,
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

/// Prompts for a playlist name, as used by New Playlist and Rename, and returns it trimmed.
///
/// Returns null when the dialog is cancelled or the entry is blank.
Future<String?> askName(BuildContext context, {required String title, String initial = ''}) {
  final field = TextEditingController(text: initial);
  return showGlassDialog<String>(
    context: context,
    builder: (c) => GlassDialog(
      title: Text(title),
      content: TextField(controller: field, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v.trim().isEmpty ? null : v.trim())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, field.text.trim().isEmpty ? null : field.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

/// Asks the user to confirm [title], optionally with [detail], and returns whether they chose [action].
///
/// Dismissing the dialog counts as a refusal.
Future<bool> confirm(BuildContext context, String title, String? detail, {String action = 'Delete'}) async =>
    await showGlassDialog<bool>(
      context: context,
      builder: (c) => GlassDialog(title: Text(title), content: detail == null ? null : Text(detail), actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
      ]),
    ) ??
    false;

/// Shows who is on a playlist and, for its owner, invites a username at a chosen role.
///
/// Sharing again with the same person changes their role; the owner removes people from the list. Anyone else sees
/// the list only. The dialog stays open after an invite so the new member appears in the list; Done closes it. A
/// server refusal stays in the dialog, for example "No account with that username". Returns null, since every
/// outcome shows in the dialog rather than to the caller.
Future<String?> share(BuildContext context, PlaylistSummary p) {
  final library = Scope.of(context).library;
  final name = TextEditingController();
  var role = 'viewer';
  String? error;
  var busy = false;
  List<PlaylistMember>? members;
  var asked = false;
  var copied = false;
  return showGlassDialog<String>(
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
        return GlassDialog(
          title: Row(children: [
            Expanded(child: Text(p.isOwner ? 'Share “${p.name}”' : 'People on “${p.name}”')),
            // The web address: anyone it is shared with, or anyone at all when it is public, can open it.
            TextButton.icon(
              icon: Icon(copied ? Icons.check : Icons.link, size: 18),
              label: Text(copied ? 'Copied' : 'Copy Link'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: Api.playlistLink(p.id)));
                set(() => copied = true);
              },
            ),
          ]),
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
                // Friends who are not on the playlist yet: one tap shares it at the chosen role.
                if (members != null)
                  FriendPicks(
                    exclude: {for (final m in members!) m.username},
                    enabled: !busy,
                    onPick: (username) { name.text = username; go(); },
                  ),
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
