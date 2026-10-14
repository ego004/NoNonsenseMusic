import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/social.dart';
import 'layout.dart';
import 'playlist_screen.dart';

/// A button sized for a row: shorter and narrower than the theme's, so two fit beside a name on a phone.
final ButtonStyle compactButton = FilledButton.styleFrom(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  minimumSize: const Size(0, 32),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
);

/// The first letter of a name in a circle. The colour comes from the name, so a person keeps theirs everywhere.
class Avatar extends StatelessWidget {
  final String name;
  final double size;
  const Avatar({super.key, required this.name, required this.size});

  @override
  Widget build(BuildContext context) {
    final hue = avatarHue(name).toDouble();
    final initial = name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [HSVColor.fromAHSV(1, hue, 0.45, 0.9).toColor(), HSVColor.fromAHSV(1, hue, 0.6, 0.72).toColor()],
          ),
        ),
        child: Text(initial, style: TextStyle(fontSize: size * 0.45, fontWeight: FontWeight.w600, color: Colors.white)),
      ),
    );
  }
}

/// A person: an avatar, the name, a line of detail and actions on the right. A long name gives way to the actions.
class PersonRow extends StatelessWidget {
  final String name, detail;
  final List<Widget> actions;
  const PersonRow({super.key, required this.name, required this.detail, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Row(children: [
        Avatar(name: name, size: 36),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          ]),
        ),
        for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
      ]),
    );
  }
}

/// Shows the Friends screen: requests waiting on the user (Accept, Decline), the ones the user sent, then friends.
/// Add Friend sends a request by username. It stays current through [Social]'s socket, so it has no refresh button.
class FriendsScreen extends StatefulWidget {
  final Social social;
  FriendsScreen({super.key, Social? social}) : social = social ?? Social.shared;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  @override
  void initState() {
    super.initState();
    widget.social.refresh(); // what changed while the screen was closed is already in; this catches the rest
  }

  void _say(String? problem) {
    if (problem != null) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(problem)));
  }

  Future<void> _add() async {
    final sentTo = await showDialog<String>(context: context, builder: (_) => AddFriendDialog(social: widget.social));
    if (sentTo != null && mounted) _say('Request sent to $sentTo');
  }

  Future<void> _remove(Friend friend) async {
    if (await confirm(context, 'Remove ${friend.username}?', null, action: 'Remove Friend')) _say(await widget.social.remove(friend));
  }

  String _on(String prefix, String since) {
    final day = shortDay(since);
    return day.isEmpty ? prefix : '$prefix $day';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pad = gutter(context);
    Widget heading(String text) => SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, 18, pad, 4),
          sliver: SliverToBoxAdapter(child: Text(text, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
        );
    Widget rows(List<Friend> people, Widget Function(Friend) row) => SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: pad - 8),
          sliver: SliverList.builder(itemCount: people.length, itemBuilder: (_, i) => row(people[i])),
        );
    return ListenableBuilder(
      listenable: widget.social,
      builder: (context, _) {
        final s = widget.social;
        final empty = s.friends.isEmpty && s.incoming.isEmpty && s.outgoing.isEmpty;
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, isPhone(context) ? phoneTop : 36, pad, 8),
            sliver: SliverToBoxAdapter(
              child: Row(children: [
                Expanded(child: Text('Friends', style: theme.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold))),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(FluentIcons.person_add_24_regular, size: 18),
                  label: const Text('Add Friend'),
                ),
              ]),
            ),
          ),
          if (empty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: bottomClearance(context)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(FluentIcons.people_24_regular, size: 44, color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
                  const SizedBox(height: 10),
                  Text('No Friends Yet', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text('Add a friend by their username.', style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.55))),
                  const SizedBox(height: 16),
                  OutlinedButton(onPressed: _add, child: const Text('Add Friend…')),
                ]),
              ),
            ),
          if (s.incoming.isNotEmpty) ...[
            heading('Requests'),
            rows(
              s.incoming,
              (p) => PersonRow(name: p.username, detail: 'Wants to be friends', actions: [
                TextButton(
                  style: compactButton,
                  onPressed: () async => _say(await s.respond(p.username, accept: false)),
                  child: const Text('Decline'),
                ),
                FilledButton(
                  style: compactButton,
                  onPressed: () async => _say(await s.respond(p.username, accept: true)),
                  child: const Text('Accept'),
                ),
              ]),
            ),
          ],
          if (s.outgoing.isNotEmpty) ...[
            heading('Sent'),
            rows(s.outgoing, (p) => PersonRow(name: p.username, detail: _on('Request sent', p.since))),
          ],
          if (s.friends.isNotEmpty) ...[
            heading('Your Friends'),
            rows(
              s.friends,
              (f) => PersonRow(name: f.username, detail: _on('Friends since', f.since), actions: [
                PopupMenuButton<String>(
                  tooltip: 'More about ${f.username}',
                  icon: const Icon(FluentIcons.more_horizontal_24_regular, size: 20),
                  itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Remove Friend…'))],
                  onSelected: (_) => _remove(f),
                ),
              ]),
            ),
          ],
          // room for the player bar
          if (!empty) SliverToBoxAdapter(child: SizedBox(height: isPhone(context) ? 170 : 120)),
        ]);
      },
    );
  }
}

/// Add Friend: a username, then Send Request. The server's reason shows under the field when it refuses. Pops with the
/// username the request went to.
class AddFriendDialog extends StatefulWidget {
  final Social social;
  const AddFriendDialog({super.key, required this.social});

  @override
  State<AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<AddFriendDialog> {
  final _field = TextEditingController();
  String? _problem;
  bool _working = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final name = _field.text.trim();
    if (name.isEmpty || _working) return;
    setState(() => _working = true);
    final problem = await widget.social.addFriend(name);
    if (!mounted) return;
    if (problem == null) return Navigator.pop(context, name);
    setState(() {
      _working = false;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Friend'),
      content: SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _field,
            autofocus: true,
            enabled: !_working,
            decoration: const InputDecoration(labelText: 'Username'),
            onChanged: (_) => setState(() => _problem = null),
            onSubmitted: (_) => _send(),
          ),
          if (_problem != null) ...[
            const SizedBox(height: 10),
            Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _field.text.trim().isEmpty || _working ? null : _send,
          child: Text(_working ? 'Sending…' : 'Send Request'),
        ),
      ],
    );
  }
}

/// The number of friend requests waiting, in a small pill; nothing when there are none. Sits at the end of the
/// sidebar's Friends entry.
class RequestCount extends StatelessWidget {
  final Social social;
  RequestCount({super.key, Social? social}) : social = social ?? Social.shared;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: social,
      builder: (context, _) {
        final n = social.incoming.length;
        if (n == 0) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(right: 10),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(9)),
          child: Text('$n', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.onPrimary)),
        );
      },
    );
  }
}

/// The Friends icon for the phone's bottom bar, with the number of friend requests waiting as its badge.
class FriendsNavIcon extends StatelessWidget {
  final Social social;
  FriendsNavIcon({super.key, Social? social}) : social = social ?? Social.shared;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: social,
        builder: (context, _) => Badge(
          isLabelVisible: social.incoming.isNotEmpty,
          label: Text('${social.incoming.length}'),
          child: const Icon(FluentIcons.people_24_regular),
        ),
      );
}

/// Friends as one-tap choices, for a dialog that adds people (a playlist's collaborators, a jam's invitations).
///
/// [exclude] holds the usernames already there. Nothing shows when every friend is. [onPick] receives the username.
class FriendPicks extends StatelessWidget {
  final Set<String> exclude;
  final void Function(String username) onPick;
  final bool enabled;
  final Social social;
  FriendPicks({super.key, required this.exclude, required this.onPick, this.enabled = true, Social? social})
      : social = social ?? Social.shared;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: social,
      builder: (context, _) {
        final choices = [for (final f in social.friends) if (!exclude.contains(f.username)) f];
        if (choices.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Friends', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 96),
              child: SingleChildScrollView(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final f in choices)
                    ActionChip(
                      avatar: Avatar(name: f.username, size: 20),
                      label: Text(f.username),
                      onPressed: enabled ? () => onPick(f.username) : null,
                    ),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}
