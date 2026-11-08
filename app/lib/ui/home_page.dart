import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/groups/group_engine.dart';
import '../core/groups/groups.dart';
import '../core/groups/space.dart';
import '../core/identity.dart';
import '../core/session.dart';
import 'audio_settings.dart';
import 'chat_page.dart';
import 'groups_page.dart';
import 'hotkeys.dart';
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
        if (MediaQuery.sizeOf(context).width >= _wideFrom) {
          return _WideHome(
            session: session,
            requests: requests,
            onAddFriend: () => _addFriend(context),
            onNewGroup: () => showDialog<String>(
              context: context,
              builder: (_) => NewGroupDialog(session: session),
            ),
            onProfile: () => _showIdentity(context),
          );
        }
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
                    onOpen: (pubkey) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            ChatPage(session: session, peer: pubkey),
                      ),
                    ),
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

/// From this width the home becomes a rail, a list and the open chat.
const _wideFrom = 900.0;

/// What the wide home shows beside the rail.
sealed class _Pane {
  const _Pane();
}

/// Direct messages; [peer] is the chat open, if any.
class _HomePane extends _Pane {
  const _HomePane([this.peer]);

  final String? peer;
}

class _GroupPane extends _Pane {
  const _GroupPane(this.groupId);

  final String groupId;
}

class _RequestsPane extends _Pane {
  const _RequestsPane();
}

/// Discord-style home for wide windows: a rail of home, groups and actions;
/// a friends column on home; the open chat filling the rest.
class _WideHome extends StatefulWidget {
  const _WideHome({
    required this.session,
    required this.requests,
    required this.onAddFriend,
    required this.onNewGroup,
    required this.onProfile,
  });

  final Session session;
  final int requests;
  final VoidCallback onAddFriend;
  final Future<String?> Function() onNewGroup;
  final VoidCallback onProfile;

  @override
  State<_WideHome> createState() => _WideHomeState();
}

class _WideHomeState extends State<_WideHome> {
  _Pane _pane = const _HomePane();

  Session get session => widget.session;

  Future<void> _newGroup() async {
    final groupId = await widget.onNewGroup();
    if (groupId != null && mounted) {
      setState(() => _pane = _GroupPane(groupId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = session.groups;
    final pane = _pane;
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(
              color: MangaColors.paper,
              border: Border(right: BorderSide(width: MangaShape.stroke)),
            ),
            child: SizedBox(
              width: 76,
              child: SafeArea(
                right: false,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    _RailItem(
                      tooltip: 'Direct messages',
                      selected: pane is _HomePane,
                      onTap: () => setState(() => _pane = const _HomePane()),
                      child: const Logo(size: 26),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: Divider(thickness: 2, height: 2),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final space in groups?.spaces ?? const <Space>[])
                            _RailItem(
                              tooltip: space.name,
                              selected:
                                  pane is _GroupPane &&
                                  pane.groupId == space.id,
                              onTap: () =>
                                  setState(() => _pane = _GroupPane(space.id)),
                              child: Text(
                                _initials(space.name),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          if (groups != null)
                            _RailItem(
                              tooltip: 'New group',
                              onTap: _newGroup,
                              child: const Icon(Icons.add),
                            ),
                        ],
                      ),
                    ),
                    _RailItem(
                      tooltip: 'Requests',
                      selected: pane is _RequestsPane,
                      onTap: () =>
                          setState(() => _pane = const _RequestsPane()),
                      badge: widget.requests,
                      child: const Icon(Icons.inbox_outlined),
                    ),
                    _RailItem(
                      tooltip: 'Profile and key',
                      onTap: widget.onProfile,
                      child: PersonAvatar(
                        session: session,
                        pubkey: session.identity.publicKey,
                        size: 44,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
          if (pane is _HomePane)
            DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(width: MangaShape.stroke)),
              ),
              child: SizedBox(
                width: 260,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'FRIENDS',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Add friend',
                            icon: const Icon(Icons.person_add_alt),
                            onPressed: widget.onAddFriend,
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _FriendsTab(
                        session: session,
                        compact: true,
                        selected: pane.peer,
                        onAdd: widget.onAddFriend,
                        onOpen: (pubkey) =>
                            setState(() => _pane = _HomePane(pubkey)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: switch (pane) {
              _HomePane(peer: final peer?) => ChatPage(
                key: ValueKey(peer),
                session: session,
                peer: peer,
              ),
              _HomePane() => const EmptyState(
                icon: Icons.forum_outlined,
                title: 'PICK A CHAT',
                message: 'Friends are on the left, groups on the rail.',
              ),
              _GroupPane(:final groupId) => GroupChatPage(
                key: ValueKey(groupId),
                session: session,
                groupId: groupId,
              ),
              _RequestsPane() => Scaffold(
                appBar: AppBar(title: const Text('REQUESTS')),
                body: _RequestsTab(session: session),
              ),
            },
          ),
        ],
      ),
    );
  }
}

/// Up to two letters for a group's rail icon.
String _initials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final letters = [for (final w in words.take(2)) w.characters.first];
  return letters.isEmpty ? '?' : letters.join().toUpperCase();
}

/// A round rail button; the selected one gets Discord's pill on the left.
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.selected = false,
    this.badge = 0,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;
  final bool selected;
  final int badge;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 4,
          height: selected ? 36 : 0,
          decoration: const BoxDecoration(
            color: MangaColors.ink,
            borderRadius: BorderRadius.horizontal(right: Radius.circular(4)),
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: tooltip,
          child: InkResponse(
            onTap: onTap,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? MangaColors.tone : MangaColors.paper,
                    borderRadius: BorderRadius.circular(selected ? 14 : 24),
                    border: Border.all(width: MangaShape.stroke),
                  ),
                  child: child,
                ),
                if (badge > 0)
                  Positioned(right: -4, top: -4, child: _Badge(count: badge)),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// A row in the sidebar column: highlighted while its chat is open.
class _SideRow extends StatelessWidget {
  const _SideRow({
    required this.selected,
    required this.leading,
    required this.title,
    required this.onTap,
  });

  final bool selected;
  final Widget leading;
  final Widget title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? MangaColors.tone : MangaColors.paper,
    borderRadius: MangaShape.borderRadius,
    child: InkWell(
      borderRadius: MangaShape.borderRadius,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 10),
            Expanded(child: title),
          ],
        ),
      ),
    ),
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
  const _FriendsTab({
    required this.session,
    required this.onAdd,
    required this.onOpen,
    this.selected,
    this.compact = false,
  });

  final Session session;
  final VoidCallback onAdd;
  final ValueChanged<String> onOpen;

  /// The chat open beside the list, on wide layouts.
  final String? selected;

  /// The sidebar column: tighter, no empty-state art.
  final bool compact;

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
      padding: compact
          ? const EdgeInsets.all(12)
          : const EdgeInsets.fromLTRB(24, 20, 24, 96),
      itemCount: friends.length,
      separatorBuilder: (_, _) => SizedBox(height: compact ? 8 : 12),
      itemBuilder: (context, i) {
        final pubkey = friends[i];
        final chat = session.chatWith(pubkey);
        if (compact) {
          return _SideRow(
            selected: pubkey == selected,
            leading: PersonAvatar(session: session, pubkey: pubkey, size: 32),
            title: PersonName(session: session, pubkey: pubkey),
            onTap: () => onOpen(pubkey),
          );
        }
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
            onTap: () => onOpen(pubkey),
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
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.settings_voice_outlined, size: 18),
                  label: const Text('Audio: microphone and speaker'),
                  onPressed: () => showAudioSettings(context, widget.session),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.keyboard_outlined, size: 18),
                  label: const Text('Call hotkeys'),
                  onPressed: () => showHotkeySettings(context, widget.session),
                ),
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
