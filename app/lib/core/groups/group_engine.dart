import 'dart:typed_data';

/// The MLS side of groups: key packages, membership and message crypto.
///
/// Implementations never touch relays. They take and return raw Nostr event
/// JSON, and `Groups` moves those events over the network. Pubkeys are hex.
abstract interface class GroupEngine {
  /// A signed key package event (kind 30443) that lets others invite us.
  /// Its private half is persisted before this returns.
  Future<String> signedKeyPackage(List<String> relays);

  /// Creates a group whose initial members are all admins. Returns one
  /// welcome rumor per member.
  Future<GroupCreated> create({
    required String name,
    required List<String> relays,
    required List<String> memberKeyPackages,
  });

  /// Publish the commit, then [merge], then send the welcomes.
  Future<MembersAdded> addMembers(String groupId, List<String> keyPackages);

  /// Stores an unwrapped welcome rumor (kind 444) as a pending invite.
  Future<void> receiveWelcome(String wrapperId, String rumorJson);

  Future<List<GroupInvite>> invites();

  Future<void> acceptInvite(String inviteId);

  Future<void> declineInvite(String inviteId);

  /// Groups we are an active member of.
  Future<List<GroupInfo>> groups();

  Future<List<String>> members(String groupId);

  /// Encrypts [text] into a group event (kind 445) ready to publish.
  Future<String> encryptText(String groupId, String text);

  /// Processes a group event (kind 445).
  Future<GroupReceipt> receive(String eventJson);

  /// Applies our own pending commit once relays have it.
  Future<void> merge(String groupId);

  /// Encrypts an attachment with the group's current media key (MIP-04).
  Future<EncryptedMedia> encryptMedia(
    String groupId,
    Uint8List data, {
    required String mime,
    required String filename,
  });

  /// A chat message (kind 445) pointing at an uploaded [EncryptedMedia].
  Future<String> sendMedia(
    String groupId, {
    required String caption,
    required String url,
    required Map<String, Object?> upload,
  });

  Future<Uint8List> decryptMedia(
    String groupId,
    Uint8List data,
    MediaRef media,
  );

  /// A call signal (offer, answer, presence) as a group event (kind 445).
  Future<String> sendSignal(String groupId, String payload);

  /// MLS-Exporter on the group's current epoch.
  Future<ExportedSecret> exportSecret(
    String groupId, {
    required String label,
    required String context,
    int length = 32,
  });

  /// Stored chat messages, oldest first.
  Future<List<GroupMessage>> messages(String groupId);

  /// Events to publish in order. The group is gone locally right away.
  Future<List<String>> leave(String groupId);

  /// Removes this identity's stored state.
  Future<void> wipe();

  Future<void> close();
}

class GroupInfo {
  const GroupInfo({
    required this.id,
    required this.nostrGroupId,
    required this.name,
    required this.relays,
    required this.admins,
    required this.memberCount,
    this.epoch = 0,
    this.lastMessageAt,
  });

  /// MLS group id, local only.
  final String id;

  /// The `h` tag value on this group's kind 445 events.
  final String nostrGroupId;
  final String name;
  final List<String> relays;
  final List<String> admins;
  final int memberCount;

  /// MLS epoch; moves on every membership change.
  final int epoch;

  /// Unix seconds.
  final int? lastMessageAt;
}

class GroupMessage {
  const GroupMessage({
    required this.id,
    required this.groupId,
    required this.sender,
    required this.text,
    required this.createdAt,
    this.media = const [],
  });

  final String id;
  final String groupId;
  final String sender;
  final String text;

  /// Unix seconds, as claimed by the sender.
  final int createdAt;
  final List<MediaRef> media;
}

/// An encrypted attachment from a message's `imeta` tag.
class MediaRef {
  const MediaRef({
    required this.url,
    required this.originalHash,
    required this.mime,
    required this.filename,
    required this.nonce,
    required this.version,
    this.width,
    this.height,
  });

  final String url;

  /// SHA-256 of the plaintext, hex.
  final String originalHash;
  final String mime;
  final String filename;
  final String nonce;
  final String version;
  final int? width;
  final int? height;

  bool get isImage => mime.startsWith('image/');

  Map<String, Object?> toJson() => {
    'url': url,
    'original_hash': originalHash,
    'mime': mime,
    'filename': filename,
    'nonce': nonce,
    'version': version,
    'width': width,
    'height': height,
  };
}

class EncryptedMedia {
  const EncryptedMedia({required this.data, required this.upload});

  /// The ciphertext to upload.
  final Uint8List data;

  /// Engine metadata, handed back to [GroupEngine.sendMedia] as is.
  final Map<String, Object?> upload;
}

class GroupInvite {
  const GroupInvite({
    required this.id,
    required this.groupName,
    required this.inviter,
    required this.memberCount,
  });

  final String id;
  final String groupName;
  final String inviter;
  final int memberCount;
}

class GroupCreated {
  const GroupCreated({required this.group, required this.welcomeRumors});

  final GroupInfo group;
  final List<String> welcomeRumors;
}

class MembersAdded {
  const MembersAdded({required this.commit, required this.welcomeRumors});

  final String commit;
  final List<String> welcomeRumors;
}

class ExportedSecret {
  const ExportedSecret({required this.secret, required this.epoch});

  final Uint8List secret;
  final int epoch;
}

/// A call signal from a member; [payload] is JSON.
class GroupSignal {
  const GroupSignal({
    required this.id,
    required this.groupId,
    required this.sender,
    required this.payload,
    required this.createdAt,
  });

  final String id;
  final String groupId;
  final String sender;
  final String payload;

  /// Unix seconds.
  final int createdAt;
}

/// What processing one group event produced.
class GroupReceipt {
  const GroupReceipt({this.groupId, this.message, this.signal, this.publish});

  final String? groupId;
  final GroupMessage? message;
  final GroupSignal? signal;

  /// A commit we made in response (an auto-committed leave). Publish it,
  /// then [GroupEngine.merge].
  final String? publish;
}
