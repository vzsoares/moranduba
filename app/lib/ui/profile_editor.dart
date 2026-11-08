import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/session.dart';
import 'manga.dart';
import 'people.dart';
import 'picture_cropper.dart';
import 'theme.dart';

/// Name and picture, shared encrypted with friends and groups.
class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, required this.session});

  final Session session;

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  late final _name = TextEditingController(
    text: widget.session.myProfile?.name ?? '',
  );
  Uint8List? _picked;
  bool _removePicture = false;
  bool _saving = false;
  String? _error;

  Session get session => widget.session;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Pictures',
          extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
          mimeTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
        ),
      ],
    );
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final square = await cropPicture(context, bytes);
      if (square == null || !mounted) return;
      setState(() {
        _picked = square;
        _removePicture = false;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'That picture does not open: $e');
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await session.updateProfile(
        name: _name.text,
        picture: _picked,
        mime: _picked == null ? null : 'image/png',
        removePicture: _removePicture,
      );
      if (!mounted) return;
      setState(() {
        _picked = null;
        _removePicture = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile sent to friends and groups')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = session.identity.publicKey;
    final hasPicture =
        _picked != null ||
        (!_removePicture && session.myProfile?.picture != null);
    final avatar = switch ((_picked, _removePicture)) {
      (final Uint8List bytes, _) => Avatar(picture: bytes, size: 72),
      (null, true) => const Avatar(size: 72),
      _ => PersonAvatar(session: session, pubkey: me, size: 72),
    };
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Tooltip(
                message: 'Choose a picture',
                child: InkResponse(
                  onTap: _saving ? null : _choose,
                  child: avatar,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: LabeledField(
                  label: 'Name',
                  hint: 'How friends see you',
                  controller: _name,
                  maxLength: 64,
                  onSubmitted: (_) => _save(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.photo_outlined, size: 18),
                label: const Text('Picture'),
                onPressed: _saving ? null : _choose,
              ),
              if (hasPicture)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _picked = null;
                          _removePicture = true;
                        }),
                  child: const Text('Remove picture'),
                ),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save'),
              ),
            ],
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 8),
            SelectableText(
              error,
              style: const TextStyle(color: MangaColors.error),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            'Only friends and group members can see it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
