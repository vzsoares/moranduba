import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/groups/group_engine.dart';
import '../core/groups/groups.dart';
import '../core/identity.dart';
import '../core/session.dart';
import 'chat_page.dart';
import 'groups_page.dart';
import 'manga.dart';
import 'notifications/notifications.dart';
import 'people.dart';
import 'profile_editor.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.session, required this.onLogout});

  final Session session;
  final Future<void> Function() onLogout;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this)
    ..addListener(() => setState(() {}));

  Session get session => widget.session;
  late final StreamSubscription<Notice> _notices;

  @override
  void initState() {
    super.initState();
    _notices = showNotices(session);
  }

  @override
  void dispose() {
    unawaited(_notices.cancel());
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, ?session.groups]),
      builder: (context, _) {
        final requests =
            session.incomingRequests.length +
            (session.groups?.invites.length ?? 0);
        return Scaffold(
          appBar: AppBar(
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [Logo(), SizedBox(width: 10), Text('MORANDUBA')],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Tooltip(
                  message: 'Profile and key',
                  child: InkResponse(
                    onTap: () => _showIdentity(context),
                    child: PersonAvatar(
                      session: session,
                      pubkey: session.identity.publicKey,
                      size: 36,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            bottom: TabBar(
              controller: _tabs,
              tabs: [
                const Tab(text: 'Friends'),
                const Tab(text: 'Groups'),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Requests'),
                      if (requests > 0) ...[
                        const SizedBox(width: 8),
                        _Badge(count: requests),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: TabBarView(
                controller: _tabs,
                children: [
                  _FriendsTab(
                    session: session,
                    onAdd: () => _addFriend(context),
                  ),
                  GroupsTab(
                    session: session,
                    onCreate: () => _newGroup(context),
                  ),
                  _RequestsTab(session: session),
                ],
              ),
            ),
          ),
          floatingActionButton: switch (_tabs.index) {
            0 => FloatingActionButton.extended(
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add friend'),
              onPressed: () => _addFriend(context),
            ),
            1 when session.groups != null => FloatingActionButton.extended(
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('New group'),
              onPressed: () => _newGroup(context),
            ),
            _ => null,
          },
        );
      },
    );
  }

  Future<void> _addFriend(BuildContext context) async {
    final sent = await showDialog<bool>(
      context: context,
      builder: (_) => _AddFriendDialog(session: session),
    );
    if (sent == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request sent. Waiting for them.')),
      );
    }
  }

  Future<void> _newGroup(BuildContext context) async {
    final groupId = await showDialog<String>(
      context: context,
      builder: (_) => NewGroupDialog(session: session),
    );
    if (groupId != null && context.mounted) {
      openGroup(context, session, groupId);
    }
  }

  Future<void> _showIdentity(BuildContext context) => showPanelSheet<void>(
    context,
    builder: (_) => _IdentitySheet(session: session, onLogout: widget.onLogout),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      color: MangaColors.charcoal,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      '$count',
      style: const TextStyle(
        color: MangaColors.paper,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _PersonPanel extends StatelessWidget {
  const _PersonPanel({
    required this.session,
    required this.pubkey,
    required this.line,
    this.icon,
    this.trailing,
    this.onTap,
  });

  final Session session;
  final String pubkey;
  final String line;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => RowPanel(
    title: PersonName(session: session, pubkey: pubkey),
    line: line,
    leading: icon == null
        ? PersonAvatar(session: session, pubkey: pubkey)
        : null,
    icon: icon ?? Icons.person_outline,
    trailing: trailing,
    onTap: onTap,
  );
}

class _FriendsTab extends StatelessWidget {
  const _FriendsTab({required this.session, required this.onAdd});

  final Session session;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final friends = session.friends;
    if (friends.isEmpty) {
      return EmptyState(
        icon: Icons.groups_outlined,
        title: 'NOBODY HERE YET',
        message: 'Share your npub from your profile button, or add a friend’s.',
        action: FilledButton(onPressed: onAdd, child: const Text('Add friend')),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 96),
      itemCount: friends.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final pubkey = friends[i];
        final chat = session.chatWith(pubkey);
        return Entrance(
          index: i,
          child: _PersonPanel(
            session: session,
            pubkey: pubkey,
            line: switch (chat.lastOrNull) {
              null => 'Say hi',
              final last when last.fileMetadata != null =>
                'Sent ${dmFileName(last)}',
              final last => last.content,
            },
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChatPage(session: session, peer: pubkey),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RequestsTab extends StatelessWidget {
  const _RequestsTab({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final incoming = session.incomingRequests;
    final outgoing = session.outgoingRequests;
    final groups = session.groups;
    final invites = groups?.invites ?? const <GroupInvite>[];
    if (incoming.isEmpty && outgoing.isEmpty && invites.isEmpty) {
      return const EmptyState(
        icon: Icons.mark_email_unread_outlined,
        title: 'ALL QUIET',
        message: 'Friend requests and group invites show up here.',
      );
    }
    final text = Theme.of(context).textTheme;
    final rows = <Widget>[
      for (final invite in invites)
        RowPanel(
          icon: Icons.group_add_outlined,
          title: Text(invite.groupName, style: text.titleMedium),
          line:
              'Group invite from ${session.displayName(invite.inviter)} · '
              '${members(invite.memberCount)}',
          trailing: _InviteActions(groups: groups!, invite: invite),
        ),
      for (final pubkey in incoming)
        _PersonPanel(
          session: session,
          pubkey: pubkey,
          line: 'Wants to be your friend',
          trailing: Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => session.declineFriend(pubkey),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: () => session.acceptFriend(pubkey),
                child: const Text('Accept'),
              ),
            ],
          ),
        ),
      for (final pubkey in outgoing)
        _PersonPanel(
          session: session,
          pubkey: pubkey,
          icon: Icons.schedule,
          line: 'Request sent, waiting for them',
        ),
    ];
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 96),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, i) => Entrance(index: i, child: rows[i]),
    );
  }
}

class _InviteActions extends StatefulWidget {
  const _InviteActions({required this.groups, required this.invite});

  final Groups groups;
  final GroupInvite invite;

  @override
  State<_InviteActions> createState() => _InviteActionsState();
}

class _InviteActionsState extends State<_InviteActions> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    children: [
      TextButton(
        onPressed: _busy
            ? null
            : () => _run(() => widget.groups.decline(widget.invite.id)),
        child: const Text('Decline'),
      ),
      FilledButton(
        onPressed: _busy
            ? null
            : () => _run(() => widget.groups.accept(widget.invite.id)),
        child: Text(_busy ? 'Joining…' : 'Join'),
      ),
    ],
  );
}

class _AddFriendDialog extends StatefulWidget {
  const _AddFriendDialog({required this.session});

  final Session session;

  @override
  State<_AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<_AddFriendDialog> {
  final _key = TextEditingController();
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.session.requestFriend(parsePublicKey(_key.text));
      if (mounted) Navigator.of(context).pop(true);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    } catch (e) {
      setState(() => _error = 'Could not send: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_sending,
      child: AlertDialog(
        title: const Text('ADD FRIEND'),
        content: SizedBox(
          width: 420,
          child: LabeledField(
            label: 'Their npub',
            hint: 'npub1…',
            controller: _key,
            autofocus: true,
            monospace: true,
            error: _error,
            onSubmitted: (_) => _send(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _sending ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _sending ? null : _send,
            child: Text(_sending ? 'Sending…' : 'Send request'),
          ),
        ],
      ),
    );
  }
}

class _IdentitySheet extends StatefulWidget {
  const _IdentitySheet({required this.session, required this.onLogout});

  final Session session;
  final Future<void> Function() onLogout;

  @override
  State<_IdentitySheet> createState() => _IdentitySheetState();
}

class _IdentitySheetState extends State<_IdentitySheet> {
  bool _showSecret = false;

  @override
  Widget build(BuildContext context) {
    final identity = widget.session.identity;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('YOUR PROFILE', style: text.headlineSmall),
                const SizedBox(height: 12),
                ProfileEditor(session: widget.session),
                if (notificationsSupported) ...[
                  const SizedBox(height: 12),
                  _NotificationsSwitch(session: widget.session),
                ],
                const SizedBox(height: 20),
                Text('YOUR KEY', style: text.headlineSmall),
                const SizedBox(height: 12),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('npub · share it', style: text.labelLarge),
                      const SizedBox(height: 6),
                      SelectableText(identity.npub, style: monoStyle),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy npub'),
                          onPressed: () => _copy(identity.npub),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Panel(
                  toned: !_showSecret,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Secret key · never share', style: text.labelLarge),
                      const SizedBox(height: 6),
                      if (_showSecret)
                        SelectableText(identity.nsec, style: monoStyle)
                      else
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton(
                            onPressed: () => setState(() => _showSecret = true),
                            child: const Text('Reveal to back it up'),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: MangaColors.error,
                    side: const BorderSide(
                      width: 1.5,
                      color: MangaColors.error,
                    ),
                  ),
                  onPressed: _confirmLogout,
                  child: const Text('Remove key from this device'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('npub copied')));
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('REMOVE KEY?'),
        content: const Text(
          'Without a backup of your secret key, this identity and its '
          'friends are gone for good.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MangaColors.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop();
    await widget.onLogout();
  }
}

class _NotificationsSwitch extends StatefulWidget {
  const _NotificationsSwitch({required this.session});

  final Session session;

  @override
  State<_NotificationsSwitch> createState() => _NotificationsSwitchState();
}

class _NotificationsSwitchState extends State<_NotificationsSwitch> {
  bool _on = notificationsAllowed;

  @override
  Widget build(BuildContext context) => Panel(
    padding: EdgeInsets.zero,
    child: SwitchListTile(
      title: const Text('Notify me about messages and calls'),
      subtitle: Text(
        kIsWeb
            ? _on
                  ? 'While this tab is in the background. Turn off in the '
                        "browser's site settings."
                  : 'While this tab is in the background.'
            : 'While Moranduba is in the background.',
      ),
      value: _on,
      onChanged: _on && !notificationsRevocable
          ? null
          : (on) async {
              if (on) {
                on = await askForNotifications();
                if (on) widget.session.enablePush();
              } else {
                await turnOffNotifications();
              }
              if (mounted) setState(() => _on = on);
            },
    ),
  );
}
