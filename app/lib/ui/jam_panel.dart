import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/jam.dart';
import '../core/social.dart';
import 'cover.dart';
import 'friends.dart';
import 'popover.dart';

/// The jam's button in the top bar: filled while the user is in one. It opens the panel that starts or joins a jam,
/// and in one shows the room.
class JamButton extends StatelessWidget {
  final JamSession jam;
  final Social social;
  JamButton({super.key, JamSession? jam, Social? social})
      : jam = jam ?? JamSession.shared,
        social = social ?? Social.shared;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: jam,
      builder: (context, _) => Builder(
        builder: (anchor) => IconButton(
          tooltip: jam.inJam ? 'Jam' : 'Start or Join a Jam',
          onPressed: () => showPanel(anchor, builder: (_) => JamPanel(jam: jam, social: social)),
          icon: Icon(jam.inJam ? FluentIcons.people_team_24_filled : FluentIcons.people_team_24_regular, color: jam.inJam ? primary : null),
        ),
      ),
    );
  }
}

/// The jam panel: not in a jam, a way to start or join one; in one, the room.
class JamPanel extends StatelessWidget {
  final JamSession jam;
  final Social social;
  const JamPanel({super.key, required this.jam, required this.social});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: jam,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: jam.state == null ? _StartView(jam: jam) : _RoomView(jam: jam, social: social, room: jam.state!),
        ),
      );
}

/// Not in a jam: start one, or join one with its code.
class _StartView extends StatefulWidget {
  final JamSession jam;
  const _StartView({required this.jam});

  @override
  State<_StartView> createState() => _StartViewState();
}

class _StartViewState extends State<_StartView> {
  final _code = TextEditingController();
  String? _problem;
  bool _working = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _go(Future<String?> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    final problem = await action();
    if (mounted) setState(() { _working = false; _problem = problem; });
  }

  void _join() => _go(() => widget.jam.join(_code.text));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(FluentIcons.people_team_24_regular, size: 20),
        const SizedBox(width: 8),
        Text('Jam', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: FilledButton(onPressed: _working ? null : () => _go(() => widget.jam.start()), child: const Text('Start a Jam')),
      ),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _code,
            enabled: !_working,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.go,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(hintText: 'Code', isDense: true),
            onChanged: (_) => setState(() => _problem = null),
            onSubmitted: (_) => _join(),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: _code.text.trim().isEmpty || _working ? null : _join, child: const Text('Join')),
      ]),
      if (_problem != null) ...[
        const SizedBox(height: 10),
        Text(_problem!, style: TextStyle(fontSize: 13.5, color: theme.colorScheme.error)),
      ],
    ]);
  }
}

/// In a jam: the code to share, where it plays, the song and its controls, Up Next, the people, and Leave Jam.
class _RoomView extends StatefulWidget {
  final JamSession jam;
  final Social social;
  final JamState room;
  const _RoomView({required this.jam, required this.social, required this.room});

  @override
  State<_RoomView> createState() => _RoomViewState();
}

class _RoomViewState extends State<_RoomView> {
  bool _copied = false;
  final _invited = <String>{};
  String? _inviteProblem;

  JamSession get jam => widget.jam;
  JamState get room => widget.room;

  Future<void> _invite(String username) async {
    final problem = await jam.invite(username);
    if (!mounted) return;
    setState(() {
      if (problem == null) _invited.add(username);
      _inviteProblem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final host = jam.isHost;
    final problem = jam.problem ?? _inviteProblem;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(room.title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
        const SizedBox(width: 8),
        TextButton.icon(
          style: compactButton,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: room.code));
            if (mounted) setState(() => _copied = true);
          },
          icon: Icon(_copied ? FluentIcons.checkmark_24_regular : FluentIcons.copy_24_regular, size: 16),
          label: Text(room.code.toUpperCase(), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
        ),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Icon(FluentIcons.speaker_2_24_regular, size: 16, color: muted),
        const SizedBox(width: 6),
        Expanded(
            child: Text(
                room.onlyHostPlays
                    ? (host ? 'Playing on this device only' : "Playing on ${room.hostName}'s device")
                    : host || jam.playHere
                        ? 'Playing on every device'
                        : 'Silent here, playing on the others',
                style: TextStyle(fontSize: 13.5, color: muted))),
        if (!host && !room.onlyHostPlays)
          Tooltip(
            message: 'Off: this device follows the jam without sound, for friends in the same room',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Play here', style: TextStyle(fontSize: 13.5, color: muted)),
              Transform.scale(scale: 0.75, child: Switch(value: jam.playHere, onChanged: (on) => setState(() => jam.playHere = on))),
            ]),
          ),
        // where the jam plays: every device (the default) or this one only, and who hosts. Only with someone else in the
        // room, the only time it means anything; a switch beside the line did not fit the panel's width
        if (host && room.members.length > 1)
          PopupMenuButton<Object>(
            tooltip: 'Choose where the jam plays',
            itemBuilder: (_) => [
              CheckedPopupMenuItem<Object>(value: _onlyHere, checked: room.onlyHostPlays, child: const Text('Only this device plays')),
              CheckedPopupMenuItem<Object>(value: _onlyMe, checked: room.onlyHostControls, child: const Text('Only I control playback')),
              const PopupMenuDivider(),
              for (final m in room.members.where((m) => m.userId != room.hostId))
                PopupMenuItem<Object>(value: m, child: Text("Make ${m.username} the host")),
            ],
            onSelected: (choice) => switch (choice) {
              JamMember m => jam.giveSpeakers(m),
              _onlyMe => jam.setOnlyHostControls(!room.onlyHostControls),
              _ => jam.setOnlyHostPlays(!room.onlyHostPlays),
            },
            child: const _MenuLabel(icon: FluentIcons.speaker_2_24_regular, label: 'Speakers'),
          ),
      ]),
      // a member while the host controls the room: their play, skip and seek would be refused, so they are told why
      if (!host && room.onlyHostControls) ...[
        const SizedBox(height: 6),
        Text(JamSession.lockedNotice, style: TextStyle(fontSize: 12.5, color: muted)),
      ],
      const SizedBox(height: 12),
      _nowPlaying(context),
      if (room.queue.isNotEmpty) ...[
        const SizedBox(height: 14),
        Text('Up Next', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: muted)),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: room.queue.length,
            itemBuilder: (_, i) => _EntryRow(entry: room.queue[i], jam: jam),
          ),
        ),
      ] else if (room.current != null) ...[
        const SizedBox(height: 10),
        Text('Play any song to add it to the jam.', style: TextStyle(fontSize: 12.5, color: muted)),
      ],
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: Text('People', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: muted))),
        if (host) _inviteMenu(),
      ]),
      for (final m in room.members) _MemberRow(member: m, room: room, host: host, jam: jam),
      if (problem != null) ...[
        const SizedBox(height: 10),
        Text(problem, style: TextStyle(fontSize: 13.5, color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          onPressed: () async {
            await jam.leave();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Leave Jam'),
        ),
      ),
    ]);
  }

  /// The host's Invite menu: friends not in the room yet. Each invitation sends them a notification with the code.
  Widget _inviteMenu() {
    return ListenableBuilder(
      listenable: widget.social,
      builder: (context, _) {
        final inRoom = {for (final m in room.members) m.username};
        final friends = [for (final f in widget.social.friends) if (!inRoom.contains(f.username)) f];
        return PopupMenuButton<String>(
          tooltip: 'Invite a friend to this jam',
          itemBuilder: (_) => [
            if (friends.isEmpty) const PopupMenuItem<String>(enabled: false, child: Text('Add friends to invite them')),
            for (final f in friends)
              PopupMenuItem(
                value: f.username,
                enabled: !_invited.contains(f.username),
                child: Text(_invited.contains(f.username) ? '${f.username} (Invited)' : f.username),
              ),
          ],
          onSelected: _invite,
          child: const _MenuLabel(icon: FluentIcons.person_add_24_regular, label: 'Invite'),
        );
      },
    );
  }

  Widget _nowPlaying(BuildContext context) {
    final theme = Theme.of(context);
    final entry = room.current;
    if (entry == null) {
      return Text('Nothing playing. Play any song to start the jam.',
          style: TextStyle(fontSize: 13.5, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)));
    }
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Cover(entry.listing.image, size: 44, radius: 8),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.listing.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            Text(entry.listing.artists.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          ]),
        ),
        IconButton(
          tooltip: room.isPlaying ? 'Pause' : 'Play',
          onPressed: jam.togglePlay,
          icon: Icon(room.isPlaying ? FluentIcons.pause_24_filled : FluentIcons.play_24_filled),
        ),
        IconButton(tooltip: 'Next', onPressed: jam.skip, icon: const Icon(FluentIcons.next_24_filled)),
      ]),
    );
  }
}

/// The look of a menu's button in the panel: an icon and a label in a thin outline.
/// The Speakers menu's "Only this device plays" item (the others are members).
const _onlyHere = 'only here';

/// The Speakers menu's "Only I control playback" item.
const _onlyMe = 'only me';

class _MenuLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MenuLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.16)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

/// A person in the room: the host is marked, and the host can remove anyone else.
class _MemberRow extends StatelessWidget {
  final JamMember member;
  final JamState room;
  final bool host;
  final JamSession jam;
  const _MemberRow({required this.member, required this.room, required this.host, required this.jam});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isHost = member.userId == room.hostId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Avatar(name: member.username, size: 26),
        const SizedBox(width: 10),
        Expanded(child: Text(member.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5))),
        if (isHost) Text('Host', style: theme.textTheme.bodySmall),
        if (host && !isHost)
          IconButton(
            tooltip: 'Remove ${member.username}',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: () => jam.removeMember(member),
            icon: const Icon(FluentIcons.dismiss_24_regular),
          ),
      ]),
    );
  }
}

/// A song in Up Next: a double tap plays it now, the cross removes it from the jam.
class _EntryRow extends StatelessWidget {
  final JamEntry entry;
  final JamSession jam;
  const _EntryRow({required this.entry, required this.jam});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => jam.jump(entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Cover(entry.listing.image, size: 30, radius: 5),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(entry.listing.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
              Text(entry.listing.artists.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
            ]),
          ),
          IconButton(
            tooltip: 'Remove from the jam',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: () => jam.remove(entry),
            icon: const Icon(FluentIcons.dismiss_circle_24_filled),
          ),
        ]),
      ),
    );
  }
}

/// Now Playing's Up Next panel: [child], the player's own queue, except in a jam, where the room decides what plays
/// and the panel shows the room's queue (a double tap plays a song now, the cross removes it), marked "Jam".
class JamUpNext extends StatelessWidget {
  final Widget child;
  final JamSession jam;
  JamUpNext({super.key, required this.child, JamSession? jam}) : jam = jam ?? JamSession.shared;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: jam,
        builder: (context, _) {
          final room = jam.state;
          if (room == null) return child;
          final theme = Theme.of(context);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 10),
              child: Row(children: [
                const Text('Up Next', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(4)),
                  child: Text('Jam', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: theme.colorScheme.primary)),
                ),
              ]),
            ),
            Expanded(
              child: room.queue.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text('Nothing queued. Play any song to add it to the jam.',
                          style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.55))),
                    )
                  // the room's queue drags as yours does; the move goes to the room, so everyone sees it
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: room.queue.length,
                      onReorderItem: (from, to) => jam.move(room.queue[from], to),
                      itemBuilder: (_, i) {
                        final entry = room.queue[i];
                        return ReorderableDragStartListener(
                          key: ValueKey(entry.entryId),
                          index: i,
                          child: GestureDetector(
                          onDoubleTap: () => jam.jump(entry),
                          child: ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                            leading: Cover(entry.listing.image, size: 36),
                            title: Text(entry.listing.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(entry.listing.artists.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: IconButton(
                              iconSize: 16,
                              tooltip: 'Remove from the jam',
                              onPressed: () => jam.remove(entry),
                              icon: const Icon(FluentIcons.dismiss_circle_24_filled),
                            ),
                          ),
                        ));
                      },
                    ),
            ),
          ]);
        },
      );
}
