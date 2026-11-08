import 'package:flutter/material.dart';

import '../core/calls/call_log.dart';
import '../core/expiry.dart';
import '../core/friend_protocol.dart';
import '../core/groups/group_engine.dart';
import '../core/groups/groups.dart';
import '../core/identity.dart';
import '../core/session.dart';
import 'call_page.dart';
import 'chat_page.dart';
import 'expiry_button.dart';
import 'group_conversation.dart';
import 'manga.dart';
import 'people.dart';
import 'search.dart';
import 'server_dialog.dart';
import 'theme.dart';

class GroupsTab extends StatelessWidget {
  const GroupsTab({super.key, required this.session, required this.onCreate});

  final Session session;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final groups = session.groups;
    if (groups == null) {
      return EmptyState(
        icon: Icons.lock_outline,
        title: 'GROUPS ARE OFF',
        message: 'The encryption engine did not start: ${session.groupsError}',
      );
    }
    final spaces = groups.spaces;
    if (spaces.isEmpty) {
      return EmptyState(
        icon: Icons.forum_outlined,
        title: 'NO GROUPS YET',
        message:
            'Start one with your friends. Everything inside is end-to-end '
            'encrypted with MLS.',
        action: FilledButton(
          onPressed: onCreate,
          child: const Text('New group'),
        ),
      );
    }
    final text = Theme.of(context).textTheme;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 96),
      itemCount: spaces.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final space = spaces[i];
        final info = groups.group(space.id);
        final last = groups.messagesIn(space.main.mlsGroupId).lastOrNull;
        return Entrance(
          index: i,
          child: RowPanel(
            icon: Icons.groups_outlined,
            title: Text(space.name, style: text.titleMedium),
            line: last == null
                ? members(info?.memberCount ?? 0)
                : '${_speaker(session, last.sender)}: '
                      '${messagePreview(last)}',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openGroup(context, session, space.id),
          ),
        );
      },
    );
  }
}

String members(int count) => count == 1 ? '1 member' : '$count members';

String _speaker(Session session, String pubkey) =>
    pubkey == session.identity.publicKey ? 'You' : session.displayName(pubkey);

void openGroup(BuildContext context, Session session, String groupId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GroupChatPage(session: session, groupId: groupId),
      ),
    );

/// Asks for a name and friends, creates the group, and returns its id.
class NewGroupDialog extends StatefulWidget {
  const NewGroupDialog({super.key, required this.session});

  final Session session;

  @override
  State<NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<NewGroupDialog> {
  final _name = TextEditingController();
  final Set<String> _picked = {};
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _picked.isEmpty) {
      setState(() => _error = 'Give it a name and pick at least one friend');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final group = await widget.session.groups!.create(name, [..._picked]);
      if (mounted) Navigator.of(context).pop(group.id);
    } on MissingKeyPackage catch (e) {
      setState(() => _error = _missingMessage(e));
    } catch (e) {
      setState(() => _error = 'Could not create: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final friends = widget.session.friends;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('NEW GROUP'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LabeledField(
                label: 'Name',
                hint: 'The crew',
                controller: _name,
                autofocus: true,
              ),
              const SizedBox(height: 16),
              Text('Friends', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              FriendPicker(
                session: widget.session,
                friends: friends,
                picked: _picked,
                onChanged: () => setState(() {}),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Text(error, style: const TextStyle(color: MangaColors.error)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _busy ? null : _create,
            child: Text(_busy ? 'Creating…' : 'Create'),
          ),
        ],
      ),
    );
  }
}

String _missingMessage(MissingKeyPackage e) =>
    'Ask them to open Moranduba first, so they can be invited: '
    '${e.pubkeys.map(shortKey).join(', ')}';

class FriendPicker extends StatelessWidget {
  const FriendPicker({
    super.key,
    required this.session,
    required this.friends,
    required this.picked,
    required this.onChanged,
  });

  final Session session;
  final List<String> friends;
  final Set<String> picked;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    if (friends.isEmpty) {
      return const Text('No friends to add yet. Add some from Friends.');
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final pubkey in friends)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: picked.contains(pubkey),
              secondary: PersonAvatar(
                session: session,
                pubkey: pubkey,
                size: 32,
              ),
              title: PersonName(session: session, pubkey: pubkey),
              onChanged: (on) {
                if (on ?? false) {
                  picked.add(pubkey);
                } else {
                  picked.remove(pubkey);
                }
                onChanged();
              },
            ),
        ],
      ),
    );
  }
}

class GroupChatPage extends StatelessWidget {
  const GroupChatPage({
    super.key,
    required this.session,
    required this.groupId,
  });

  final Session session;
  final String groupId;

  @override
  Widget build(BuildContext context) {
    final groups = session.groups!;
    return ListenableBuilder(
      listenable: Listenable.merge([groups, session]),
      builder: (context, _) {
        final info = groups.group(groupId);
        if (info == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.logout,
              title: 'NOT IN THIS GROUP',
              message: 'You left this group or were removed from it.',
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: [
                const Avatar(icon: Icons.groups_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.name, overflow: TextOverflow.ellipsis),
                      Text(
                        members(info.memberCount),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Search this chat',
                icon: const Icon(Icons.search),
                onPressed: () =>
                    showChatSearch(context, session, chat: groupChat(groupId)),
              ),
              ExpiryButton(session: session, chat: groupChat(groupId)),
              IconButton(
                tooltip: 'Call',
                icon: const TelephoneIcon(),
                onPressed: () => openCall(context, session, groupId),
              ),
              IconButton(
                tooltip: 'Members',
                icon: const Icon(Icons.group_outlined),
                onPressed: () => _showMembers(context, info),
              ),
              PopupMenuButton<void>(
                tooltip: 'More',
                itemBuilder: (_) => [
                  PopupMenuItem(
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          ServerDialog(session: session, groupId: groupId),
                    ),
                    child: const Text('Call server…'),
                  ),
                  CheckedPopupMenuItem(
                    checked: session.logsCalls(groupId),
                    onTap: () => session.setCallLog(
                      groupId,
                      on: !session.logsCalls(groupId),
                    ),
                    child: const Text('Log calls in chat'),
                  ),
                  PopupMenuItem(
                    onTap: () => _confirmLeave(context, info),
                    child: const Text('Leave group'),
                  ),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              _CallBanner(session: session, groupId: groupId),
              Expanded(
                child: GroupConversation(session: session, groupId: groupId),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showMembers(BuildContext context, GroupInfo info) =>
      showPanelSheet<void>(
        context,
        builder: (_) => _MembersSheet(session: session, info: info),
      );

  Future<void> _confirmLeave(BuildContext context, GroupInfo info) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('LEAVE GROUP?'),
        content: Text(
          'You stop receiving messages in ${info.name}. Someone has to '
          'invite you again to come back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MangaColors.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await session.groups!.leave(groupId);
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not leave: $e')));
    }
  }
}

/// "N in a call" with a join button, while others are in this group's call.
class _CallBanner extends StatelessWidget {
  const _CallBanner({required this.session, required this.groupId});

  final Session session;
  final String groupId;

  @override
  Widget build(BuildContext context) {
    final calls = session.calls;
    if (calls == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: calls,
      builder: (context, _) {
        final inCall = calls.inCall(groupId);
        final mine = calls.active?.groupId == groupId;
        if (inCall.isEmpty || mine) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Panel(
            toned: true,
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.videocam),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${inCall.length} in a call',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton(
                  onPressed: () => openCall(context, session, groupId),
                  child: const Text('Join'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MembersSheet extends StatefulWidget {
  const _MembersSheet({required this.session, required this.info});

  final Session session;
  final GroupInfo info;

  @override
  State<_MembersSheet> createState() => _MembersSheetState();
}

class _MembersSheetState extends State<_MembersSheet> {
  late Future<List<String>> _members = _load();

  Future<List<String>> _load() =>
      widget.session.groups!.members(widget.info.id);

  Future<void> _add(List<String> current) async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _AddMembersDialog(
        session: widget.session,
        groupId: widget.info.id,
        candidates: [
          for (final f in widget.session.friends)
            if (!current.contains(f)) f,
        ],
      ),
    );
    if (added == true) setState(() => _members = _load());
  }

  String _relation(String pubkey) => switch (widget.session.stateOf(pubkey)) {
    FriendState.friend => 'Message',
    FriendState.outgoing => 'Friend request sent',
    FriendState.incoming => 'Wants to be friends',
    FriendState.none => 'Add as friend to message',
  };

  /// Friends open their DM; anyone else gets a friend request first, since
  /// DMs go only between friends.
  Future<void> _open(String pubkey) async {
    final session = widget.session;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    switch (session.stateOf(pubkey)) {
      case FriendState.friend:
        navigator.pop();
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => ChatPage(session: session, peer: pubkey),
          ),
        );
      case FriendState.outgoing:
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Waiting for them to accept your friend request.'),
          ),
        );
      case FriendState.incoming:
        await session.acceptFriend(pubkey);
        if (mounted) setState(() {});
        messenger.showSnackBar(
          const SnackBar(content: Text('Friends now. Tap again to message.')),
        );
      case FriendState.none:
        final send = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('ADD AS FRIEND?'),
            content: Text(
              'Messages go only between friends. Send '
              '${session.displayName(pubkey)} a friend request?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Send request'),
              ),
            ],
          ),
        );
        if (send != true) return;
        await session.requestFriend(pubkey);
        if (mounted) setState(() {});
        messenger.showSnackBar(
          const SnackBar(content: Text('Friend request sent.')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final me = widget.session.identity.publicKey;
    return SafeArea(
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: FutureBuilder(
              future: _members,
              builder: (context, snapshot) {
                final members = snapshot.data;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('MEMBERS', style: text.headlineSmall),
                    const SizedBox(height: 12),
                    if (members == null)
                      const Skeleton()
                    else
                      for (final pubkey in members)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: RowPanel(
                            leading: PersonAvatar(
                              session: widget.session,
                              pubkey: pubkey,
                            ),
                            title: PersonName(
                              session: widget.session,
                              pubkey: pubkey,
                            ),
                            line: [
                              if (widget.info.admins.contains(pubkey)) 'Admin',
                              if (pubkey != me) _relation(pubkey),
                            ].join(' · '),
                            trailing: pubkey == me
                                ? null
                                : const Icon(Icons.chevron_right),
                            onTap: pubkey == me ? null : () => _open(pubkey),
                          ),
                        ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.person_add_alt, size: 18),
                      label: const Text('Add friends'),
                      onPressed: members == null ? null : () => _add(members),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AddMembersDialog extends StatefulWidget {
  const _AddMembersDialog({
    required this.session,
    required this.groupId,
    required this.candidates,
  });

  final Session session;
  final String groupId;
  final List<String> candidates;

  @override
  State<_AddMembersDialog> createState() => _AddMembersDialogState();
}

class _AddMembersDialogState extends State<_AddMembersDialog> {
  final Set<String> _picked = {};
  String? _error;
  bool _busy = false;

  Future<void> _add() async {
    if (_picked.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.groups!.addMembers(widget.groupId, [..._picked]);
      if (mounted) Navigator.of(context).pop(true);
    } on MissingKeyPackage catch (e) {
      setState(() => _error = _missingMessage(e));
    } catch (e) {
      setState(() => _error = 'Could not add: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('ADD FRIENDS'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FriendPicker(
              session: widget.session,
              friends: widget.candidates,
              picked: _picked,
              onChanged: () => setState(() {}),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Text(error, style: const TextStyle(color: MangaColors.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy || _picked.isEmpty ? null : _add,
          child: Text(_busy ? 'Adding…' : 'Add'),
        ),
      ],
    ),
  );
}
