use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use mdk_core::encrypted_media::{EncryptedMediaUpload, MediaReference};
use mdk_core::groups::NostrGroupConfigData;
use mdk_core::messages::{EventTag, MessageProcessingResult};
use mdk_core::MDK;
use mdk_memory_storage::{MdkMemoryStorage, MemoryStorageSnapshot};
use mdk_storage_traits::groups::types::{Group, GroupState};
use mdk_storage_traits::groups::GroupStorage;
use mdk_storage_traits::messages::types::Message;
use mdk_storage_traits::GroupId;
use nostr::{
    Event, EventBuilder, EventId, JsonUtil, Keys, Kind, PublicKey, RelayUrl, TagKind, Timestamp,
    UnsignedEvent,
};
use openmls_traits::OpenMlsProvider;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const KEY_PACKAGE_KIND: u16 = 30443;
const CHAT_KIND: u16 = 9;
/// Call started/ended entries in the chat history (*provisional* kind, ours).
const CALL_KIND: u16 = 25052;
/// Call signaling inside the group (*provisional* kind, ours).
const SIGNAL_KIND: u16 = 25050;
const SNAPSHOT_MAGIC: &[u8; 4] = b"MSN1";

pub type Result<T> = std::result::Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// NIP-40 tag from an optional `expires_at` (unix seconds), so relays that
/// honor it drop the event.
fn expiration(args: &Value) -> Option<Vec<EventTag>> {
    let at = args["expires_at"].as_u64()?;
    Some(vec![EventTag::expiration(Timestamp::from(at))])
}

pub struct Engine {
    mdk: MDK<MdkMemoryStorage>,
    keys: Keys,
    cipher: ChaCha20Poly1305,
}

#[derive(Deserialize)]
pub struct OpenArgs {
    pub secret_key: String,
    pub storage_key: String,
    pub snapshot: Option<String>,
}

#[derive(Serialize)]
struct GroupDto {
    id: String,
    nostr_group_id: String,
    name: String,
    relays: Vec<String>,
    admins: Vec<String>,
    member_count: usize,
    last_message_at: Option<u64>,
    epoch: u64,
}

#[derive(Serialize)]
struct MessageDto {
    id: String,
    group_id: String,
    sender: String,
    text: String,
    created_at: u64,
    media: Vec<MediaDto>,
    /// A call event; `text` holds its JSON.
    call: bool,
}

/// An encrypted attachment as carried in a message's `imeta` tag (MIP-04).
#[derive(Serialize, Deserialize)]
struct MediaDto {
    url: String,
    original_hash: String,
    mime: String,
    filename: String,
    nonce: String,
    version: String,
    width: Option<u32>,
    height: Option<u32>,
}

/// What `send_media` needs to rebuild the upload for the `imeta` tag.
#[derive(Serialize, Deserialize)]
struct UploadDto {
    original_hash: String,
    encrypted_hash: String,
    mime: String,
    filename: String,
    size: u64,
    nonce: String,
    width: Option<u32>,
    height: Option<u32>,
    blurhash: Option<String>,
    thumbhash: Option<String>,
}

impl Engine {
    pub fn open(args: OpenArgs) -> Result<Self> {
        let keys = Keys::parse(&args.secret_key).map_err(err)?;
        let key = hex::decode(&args.storage_key).map_err(err)?;
        if key.len() != 32 {
            return Err("storage key must be 32 bytes".into());
        }
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
        let storage = MdkMemoryStorage::default();
        if let Some(encoded) = args.snapshot {
            let blob = BASE64.decode(encoded).map_err(err)?;
            storage.restore_snapshot(decrypt_snapshot(&cipher, &blob)?);
        }
        Ok(Self {
            mdk: MDK::new(storage),
            keys,
            cipher,
        })
    }

    pub fn call(&mut self, method: &str, args: Value) -> Result<Value> {
        match method {
            "snapshot" => self.snapshot(),
            "key_package" => self.key_package(args),
            "create_group" => self.create_group(args),
            "process_welcome" => self.process_welcome(args),
            "invites" => self.invites(),
            "accept" => self.accept(args),
            "decline" => self.decline(args),
            "add_members" => self.add_members(args),
            "groups" => self.groups(),
            "members" => self.members(args),
            "encrypt_text" => self.encrypt_text(args),
            "receive" => self.receive(args),
            "merge" => self.merge(args),
            "messages" => self.messages(args),
            "leave" => self.leave(args),
            "encrypt_media" => self.encrypt_media(args),
            "send_media" => self.send_media(args),
            "decrypt_media" => self.decrypt_media(args),
            "send_signal" => self.send_signal(args),
            "export_secret" => self.export_secret(args),
            "prune" => self.prune(args),
            _ => Err(format!("unknown method {method}")),
        }
    }

    fn storage(&self) -> &MdkMemoryStorage {
        self.mdk.provider.storage()
    }

    fn snapshot(&self) -> Result<Value> {
        let plain = self.storage().create_snapshot().to_json().map_err(err)?;
        let mut nonce = [0u8; 12];
        getrandom::fill(&mut nonce).map_err(err)?;
        let sealed = self
            .cipher
            .encrypt(Nonce::from_slice(&nonce), plain.as_slice())
            .map_err(err)?;
        let mut blob = Vec::with_capacity(4 + 12 + sealed.len());
        blob.extend_from_slice(SNAPSHOT_MAGIC);
        blob.extend_from_slice(&nonce);
        blob.extend_from_slice(&sealed);
        Ok(json!(BASE64.encode(blob)))
    }

    fn key_package(&self, args: Value) -> Result<Value> {
        let relays = relays(&args["relays"])?;
        let data = self
            .mdk
            .create_key_package_for_event(&self.keys.public_key(), relays)
            .map_err(err)?;
        let event = EventBuilder::new(Kind::Custom(KEY_PACKAGE_KIND), data.content)
            .tags(data.tags_30443)
            .sign_with_keys(&self.keys)
            .map_err(err)?;
        Ok(json!(event.as_json()))
    }

    /// Every initial member is an admin: MIP-03 lets only non-admins leave,
    /// and a self-demote needs another admin to remain.
    fn create_group(&self, args: Value) -> Result<Value> {
        let name = str_arg(&args, "name")?;
        let relays = relays(&args["relays"])?;
        let packages = strings(&args["key_packages"])?
            .iter()
            .map(|json| Event::from_json(json).map_err(err))
            .collect::<Result<Vec<_>>>()?;
        let me = self.keys.public_key();
        let mut admins = vec![me];
        admins.extend(packages.iter().map(|p| p.pubkey));
        let config = NostrGroupConfigData::new(
            name.to_string(),
            String::new(),
            None,
            None,
            None,
            relays,
            admins,
        );
        let result = self.mdk.create_group(&me, packages, config).map_err(err)?;
        self.mdk
            .merge_pending_commit(&result.group.mls_group_id)
            .map_err(err)?;
        let group = self.group_dto(&result.group)?;
        let welcomes: Vec<String> = result.welcome_rumors.iter().map(|r| r.as_json()).collect();
        Ok(json!({ "group": group, "welcomes": welcomes }))
    }

    fn process_welcome(&self, args: Value) -> Result<Value> {
        let wrapper = EventId::from_hex(str_arg(&args, "wrapper_id")?).map_err(err)?;
        let rumor = UnsignedEvent::from_json(str_arg(&args, "rumor")?).map_err(err)?;
        self.mdk.process_welcome(&wrapper, &rumor).map_err(err)?;
        Ok(Value::Null)
    }

    fn invites(&self) -> Result<Value> {
        let invites: Vec<Value> = self
            .mdk
            .get_pending_welcomes(None)
            .map_err(err)?
            .iter()
            .map(|w| {
                json!({
                    "id": w.id.to_hex(),
                    "group_name": w.group_name,
                    "inviter": w.welcomer.to_hex(),
                    "member_count": w.member_count,
                })
            })
            .collect();
        Ok(json!(invites))
    }

    fn accept(&self, args: Value) -> Result<Value> {
        let welcome = self.welcome(&args)?;
        self.mdk.accept_welcome(&welcome).map_err(err)?;
        Ok(Value::Null)
    }

    fn decline(&self, args: Value) -> Result<Value> {
        let welcome = self.welcome(&args)?;
        self.mdk.decline_welcome(&welcome).map_err(err)?;
        Ok(Value::Null)
    }

    fn welcome(&self, args: &Value) -> Result<mdk_storage_traits::welcomes::types::Welcome> {
        let id = EventId::from_hex(str_arg(args, "id")?).map_err(err)?;
        self.mdk
            .get_welcome(&id)
            .map_err(err)?
            .ok_or_else(|| "invite not found".to_string())
    }

    /// The commit must reach relays before `merge`; the welcomes go out after.
    fn add_members(&self, args: Value) -> Result<Value> {
        let packages = strings(&args["key_packages"])?
            .iter()
            .map(|json| Event::from_json(json).map_err(err))
            .collect::<Result<Vec<_>>>()?;
        let result = self
            .mdk
            .add_members(&group_id(&args)?, &packages)
            .map_err(err)?;
        let welcomes: Vec<String> = result
            .welcome_rumors
            .unwrap_or_default()
            .iter()
            .map(|r| r.as_json())
            .collect();
        Ok(json!({ "commit": result.evolution_event.as_json(), "welcomes": welcomes }))
    }

    fn groups(&self) -> Result<Value> {
        let groups = self
            .mdk
            .get_groups()
            .map_err(err)?
            .iter()
            .filter(|g| g.state == GroupState::Active)
            .map(|g| self.group_dto(g))
            .collect::<Result<Vec<_>>>()?;
        Ok(json!(groups))
    }

    fn members(&self, args: Value) -> Result<Value> {
        let members: Vec<String> = self
            .mdk
            .get_members(&group_id(&args)?)
            .map_err(err)?
            .iter()
            .map(PublicKey::to_hex)
            .collect();
        Ok(json!(members))
    }

    /// `call: true` stores a call event instead of a chat message.
    fn encrypt_text(&self, args: Value) -> Result<Value> {
        let kind = if args["call"].as_bool() == Some(true) {
            CALL_KIND
        } else {
            CHAT_KIND
        };
        let rumor = EventBuilder::new(Kind::Custom(kind), str_arg(&args, "text")?)
            .build(self.keys.public_key());
        let event = self
            .mdk
            .create_message(&group_id(&args)?, rumor, expiration(&args))
            .map_err(err)?;
        Ok(json!(event.as_json()))
    }

    /// Deletes messages created before `before` (unix seconds).
    fn prune(&self, args: Value) -> Result<Value> {
        let before = args["before"].as_u64().ok_or("missing before")?;
        let deleted = self
            .storage()
            .delete_messages_before(&group_id(&args)?, Timestamp::from(before));
        Ok(json!(deleted))
    }

    /// `publish` is set when processing produced a commit (an auto-committed
    /// leave) that must go to relays before `merge`.
    ///
    /// Every member auto-commits a leave, and MDK 0.8 cannot roll back a commit
    /// it merged itself, so only the lowest remaining pubkey publishes; the
    /// rest drop theirs and wait for that commit.
    fn receive(&self, args: Value) -> Result<Value> {
        let event = Event::from_json(str_arg(&args, "event")?).map_err(err)?;
        let result = self.mdk.process_message(&event).map_err(err)?;
        Ok(match result {
            MessageProcessingResult::ApplicationMessage(m)
                if m.kind == Kind::Custom(SIGNAL_KIND) =>
            {
                json!({
                    "group_id": hex::encode(m.mls_group_id.as_slice()),
                    "signal": {
                        "id": m.id.to_hex(),
                        "sender": m.pubkey.to_hex(),
                        "payload": m.content,
                        "created_at": m.created_at.as_secs(),
                    },
                })
            }
            MessageProcessingResult::ApplicationMessage(m) => json!({
                "group_id": hex::encode(m.mls_group_id.as_slice()),
                "message": self.message_dto(&m),
            }),
            MessageProcessingResult::Proposal(update) => {
                let gid = update.mls_group_id;
                if self.commits_leave(&gid)? {
                    json!({
                        "group_id": hex::encode(gid.as_slice()),
                        "publish": update.evolution_event.as_json(),
                    })
                } else {
                    self.mdk.clear_pending_commit(&gid).map_err(err)?;
                    json!({ "group_id": hex::encode(gid.as_slice()) })
                }
            }
            MessageProcessingResult::Commit { mls_group_id }
            | MessageProcessingResult::PendingProposal { mls_group_id }
            | MessageProcessingResult::IgnoredProposal { mls_group_id, .. }
            | MessageProcessingResult::ExternalJoinProposal { mls_group_id }
            | MessageProcessingResult::Unprocessable { mls_group_id } => {
                json!({ "group_id": hex::encode(mls_group_id.as_slice()) })
            }
            MessageProcessingResult::PreviouslyFailed => json!({}),
        })
    }

    fn commits_leave(&self, gid: &GroupId) -> Result<bool> {
        let leaving = self.mdk.pending_removed_members_pubkeys(gid).map_err(err)?;
        let committer = self
            .mdk
            .get_members(gid)
            .map_err(err)?
            .into_iter()
            .filter(|pk| !leaving.contains(pk))
            .min();
        Ok(committer == Some(self.keys.public_key()))
    }

    fn merge(&self, args: Value) -> Result<Value> {
        self.mdk
            .merge_pending_commit(&group_id(&args)?)
            .map_err(err)?;
        Ok(Value::Null)
    }

    fn messages(&self, args: Value) -> Result<Value> {
        let mut messages: Vec<Message> = self
            .mdk
            .get_messages(&group_id(&args)?, None)
            .map_err(err)?
            .into_iter()
            .filter(|m| m.kind == Kind::Custom(CHAT_KIND) || m.kind == Kind::Custom(CALL_KIND))
            .collect();
        messages.sort_by_key(|m| (m.created_at, m.processed_at, m.id));
        let dtos: Vec<MessageDto> = messages.iter().map(|m| self.message_dto(m)).collect();
        Ok(json!(dtos))
    }

    /// Returns the events to publish, in order: a self-demote commit when we
    /// are an admin, then the leave proposal another member will commit. The
    /// group goes inactive here so it disappears before that commit lands.
    fn leave(&self, args: Value) -> Result<Value> {
        let gid = group_id(&args)?;
        let group = self
            .mdk
            .get_group(&gid)
            .map_err(err)?
            .ok_or("group not found")?;
        let mut events = Vec::new();
        if group.admin_pubkeys.contains(&self.keys.public_key()) {
            let demote = self.mdk.self_demote(&gid).map_err(err)?;
            self.mdk.merge_pending_commit(&gid).map_err(err)?;
            events.push(demote.evolution_event.as_json());
        }
        let leave = self.mdk.leave_group(&gid).map_err(err)?;
        events.push(leave.evolution_event.as_json());
        let mut left = self
            .mdk
            .get_group(&gid)
            .map_err(err)?
            .ok_or("group not found")?;
        left.state = GroupState::Inactive;
        self.storage().save_group(left).map_err(err)?;
        Ok(json!(events))
    }

    fn encrypt_media(&self, args: Value) -> Result<Value> {
        let data = BASE64.decode(str_arg(&args, "data")?).map_err(err)?;
        let upload = self
            .mdk
            .media_manager(group_id(&args)?)
            .encrypt_for_upload(&data, str_arg(&args, "mime")?, str_arg(&args, "filename")?)
            .map_err(err)?;
        Ok(json!({
            "encrypted": BASE64.encode(&upload.encrypted_data),
            "upload": UploadDto {
                original_hash: hex::encode(upload.original_hash),
                encrypted_hash: hex::encode(upload.encrypted_hash),
                mime: upload.mime_type,
                filename: upload.filename,
                size: upload.original_size,
                nonce: hex::encode(upload.nonce),
                width: upload.dimensions.map(|d| d.0),
                height: upload.dimensions.map(|d| d.1),
                blurhash: upload.blurhash,
                thumbhash: upload.thumbhash,
            },
        }))
    }

    /// Sends a chat message whose `imeta` tag points at the uploaded blob.
    fn send_media(&self, args: Value) -> Result<Value> {
        let gid = group_id(&args)?;
        let dto: UploadDto = serde_json::from_value(args["upload"].clone()).map_err(err)?;
        let upload = EncryptedMediaUpload {
            encrypted_data: Vec::new(),
            original_hash: bytes(&dto.original_hash)?,
            encrypted_hash: bytes(&dto.encrypted_hash)?,
            mime_type: dto.mime,
            filename: dto.filename,
            original_size: dto.size,
            encrypted_size: 0,
            dimensions: dto.width.zip(dto.height),
            blurhash: dto.blurhash,
            thumbhash: dto.thumbhash,
            nonce: bytes(&dto.nonce)?,
        };
        let imeta = self
            .mdk
            .media_manager(gid.clone())
            .create_imeta_tag(&upload, str_arg(&args, "url")?);
        let rumor = EventBuilder::new(Kind::Custom(CHAT_KIND), str_arg(&args, "caption")?)
            .tag(imeta)
            .build(self.keys.public_key());
        let event = self
            .mdk
            .create_message(&gid, rumor, expiration(&args))
            .map_err(err)?;
        Ok(json!(event.as_json()))
    }

    fn decrypt_media(&self, args: Value) -> Result<Value> {
        let data = BASE64.decode(str_arg(&args, "data")?).map_err(err)?;
        let dto: MediaDto = serde_json::from_value(args["media"].clone()).map_err(err)?;
        let reference = MediaReference {
            url: dto.url,
            original_hash: bytes(&dto.original_hash)?,
            mime_type: dto.mime,
            filename: dto.filename,
            dimensions: dto.width.zip(dto.height),
            scheme_version: dto.version,
            nonce: bytes(&dto.nonce)?,
        };
        let plain = self
            .mdk
            .media_manager(group_id(&args)?)
            .decrypt_from_download(&data, &reference)
            .map_err(err)?;
        Ok(json!(BASE64.encode(plain)))
    }

    fn send_signal(&self, args: Value) -> Result<Value> {
        let rumor = EventBuilder::new(Kind::Custom(SIGNAL_KIND), str_arg(&args, "payload")?)
            .build(self.keys.public_key());
        let event = self
            .mdk
            .create_message(&group_id(&args)?, rumor, None)
            .map_err(err)?;
        Ok(json!(event.as_json()))
    }

    /// MLS-Exporter on the current epoch, hex. Returns the epoch it used.
    fn export_secret(&self, args: Value) -> Result<Value> {
        let gid = group_id(&args)?;
        let length = args["length"].as_u64().ok_or("missing length")? as usize;
        let secret = self
            .mdk
            .export_secret(
                &gid,
                str_arg(&args, "label")?,
                str_arg(&args, "context")?.as_bytes(),
                length,
            )
            .map_err(err)?;
        let epoch = self
            .mdk
            .get_group(&gid)
            .map_err(err)?
            .ok_or("group not found")?
            .epoch;
        Ok(json!({ "secret": hex::encode(secret), "epoch": epoch }))
    }

    fn message_dto(&self, m: &Message) -> MessageDto {
        let manager = self.mdk.media_manager(m.mls_group_id.clone());
        let media = m
            .tags
            .iter()
            .filter(|t| t.kind() == TagKind::Custom("imeta".into()))
            .filter_map(|t| manager.parse_imeta_tag(t).ok())
            .map(|r| MediaDto {
                url: r.url,
                original_hash: hex::encode(r.original_hash),
                mime: r.mime_type,
                filename: r.filename,
                nonce: hex::encode(r.nonce),
                version: r.scheme_version,
                width: r.dimensions.map(|d| d.0),
                height: r.dimensions.map(|d| d.1),
            })
            .collect();
        MessageDto {
            id: m.id.to_hex(),
            group_id: hex::encode(m.mls_group_id.as_slice()),
            sender: m.pubkey.to_hex(),
            text: m.content.clone(),
            created_at: m.created_at.as_secs(),
            media,
            call: m.kind == Kind::Custom(CALL_KIND),
        }
    }

    fn group_dto(&self, group: &Group) -> Result<GroupDto> {
        let relays = self
            .mdk
            .get_relays(&group.mls_group_id)
            .map_err(err)?
            .iter()
            .map(|r| r.to_string())
            .collect();
        Ok(GroupDto {
            id: hex::encode(group.mls_group_id.as_slice()),
            nostr_group_id: hex::encode(group.nostr_group_id),
            name: group.name.clone(),
            relays,
            admins: group.admin_pubkeys.iter().map(PublicKey::to_hex).collect(),
            member_count: self
                .mdk
                .get_members(&group.mls_group_id)
                .map_err(err)?
                .len(),
            last_message_at: group.last_message_at.map(|t| t.as_secs()),
            epoch: group.epoch,
        })
    }
}

fn decrypt_snapshot(cipher: &ChaCha20Poly1305, blob: &[u8]) -> Result<MemoryStorageSnapshot> {
    if blob.len() < 16 || &blob[..4] != SNAPSHOT_MAGIC {
        return Err("not a Moranduba snapshot".into());
    }
    let plain = cipher
        .decrypt(Nonce::from_slice(&blob[4..16]), &blob[16..])
        .map_err(|_| "snapshot does not decrypt with this key".to_string())?;
    MemoryStorageSnapshot::from_json(&plain)
}

fn bytes<const N: usize>(hex_value: &str) -> Result<[u8; N]> {
    hex::decode(hex_value)
        .map_err(err)?
        .try_into()
        .map_err(|_| format!("expected {N} bytes"))
}

fn str_arg<'a>(args: &'a Value, name: &str) -> Result<&'a str> {
    args[name]
        .as_str()
        .ok_or_else(|| format!("missing string argument {name}"))
}

fn strings(value: &Value) -> Result<Vec<String>> {
    value
        .as_array()
        .ok_or("expected an array of strings")?
        .iter()
        .map(|v| {
            v.as_str()
                .map(str::to_string)
                .ok_or("expected a string".into())
        })
        .collect()
}

fn relays(value: &Value) -> Result<Vec<RelayUrl>> {
    strings(value)?
        .iter()
        .map(|url| RelayUrl::parse(url).map_err(err))
        .collect()
}

fn group_id(args: &Value) -> Result<GroupId> {
    let bytes = hex::decode(str_arg(args, "group_id")?).map_err(err)?;
    Ok(GroupId::from_slice(&bytes))
}
