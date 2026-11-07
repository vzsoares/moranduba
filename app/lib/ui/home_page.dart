import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/identity.dart';
import '../core/session.dart';
import 'chat_page.dart';
import 'manga.dart';
import 'theme.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.session, required this.onLogout});

  final Session session;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final requests = session.incomingRequests.length;
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('MORANDUBA'),
              actions: [
                IconButton(
                  tooltip: 'My key',
                  icon: const Icon(Icons.key_outlined),
                  onPressed: () => _showIdentity(context),
                ),
                const SizedBox(width: 8),
              ],
              bottom: TabBar(
                tabs: [
                  const Tab(text: 'Friends'),
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
                  children: [
                    _FriendsTab(
                      session: session,
                      onAdd: () => _addFriend(context),
                    ),
                    _RequestsTab(session: session),
                  ],
                ),
              ),
            ),
            floatingActionButton: FloatingActionButton.extended(
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add friend'),
              onPressed: () => _addFriend(context),
            ),
          ),
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

  Future<void> _showIdentity(BuildContext context) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _IdentitySheet(session: session, onLogout: onLogout),
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

/// One row in a list: a panel with avatar, name, line and trailing actions.
class _PersonPanel extends StatelessWidget {
  const _PersonPanel({
    required this.pubkey,
    required this.line,
    this.icon = Icons.person_outline,
    this.trailing,
    this.onTap,
  });

  final String pubkey;
  final String line;
  final IconData icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Panel(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Avatar(icon: icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(shortKey(pubkey), style: monoStyle),
                      const SizedBox(height: 2),
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium,
                      ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
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
        message: 'Share your npub from the key button, or add a friend’s.',
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
            pubkey: pubkey,
            line: chat.isEmpty ? 'Say hi' : chat.last.content,
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
    if (incoming.isEmpty && outgoing.isEmpty) {
      return const EmptyState(
        icon: Icons.mark_email_unread_outlined,
        title: 'ALL QUIET',
        message: 'Friend requests you send or receive show up here.',
      );
    }
    final rows = <Widget>[
      for (final pubkey in incoming)
        _PersonPanel(
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
