//! Snapshot and rollback support for memory storage.
//!
//! This module provides the ability to create snapshots of all in-memory state
//! and restore them later. This provides functionality analogous to SQLite
//! savepoints for testing and rollback scenarios.
//!
//! # Concurrency
//!
//! Snapshot creation and restoration are **atomic** operations:
//!
//! - `create_snapshot()` acquires a global read lock on the storage state,
//!   ensuring a consistent snapshot even with concurrent reads.
//! - `restore_snapshot()` acquires a global write lock on the storage state,
//!   ensuring the restore is consistent and blocks all other operations.

use std::collections::{BTreeSet, HashMap};

use lru::LruCache;
use mdk_storage_traits::GroupId;
use mdk_storage_traits::groups::types::{Group, GroupExporterSecret, GroupRelay};
use mdk_storage_traits::messages::types::{Message, ProcessedMessage};
use mdk_storage_traits::welcomes::types::{ProcessedWelcome, Welcome};
use nostr::EventId;

use crate::mls_storage::GroupDataType;

/// A group-scoped snapshot that only contains data for a single group.
///
/// Unlike [`MemoryStorageSnapshot`] which captures all data in the storage,
/// this snapshot only captures data relevant to a specific group. This enables
/// proper rollback isolation where rolling back Group A doesn't affect Group B.
///
/// This matches the behavior of SQLite's group-scoped snapshots where:
/// - `snapshot_group_state()` only copies rows WHERE `group_id = ?`
/// - `restore_group_from_snapshot()` only deletes/restores rows for that group
///
/// # Group-Scoped Data
///
/// The following data is captured per group:
/// - MLS group data (tree state, join config, etc.)
/// - MLS own leaf nodes for this group
/// - MLS proposals for this group
/// - MLS epoch key pairs for this group
/// - MDK group record
/// - MDK group relays
/// - MDK group exporter secrets
///
/// The following data is NOT captured (not group-scoped):
/// - MLS key packages (identity-scoped, not group-scoped)
/// - MLS PSKs (identity-scoped, not group-scoped)
/// - MLS signature keys (identity-scoped, not group-scoped)
/// - MLS encryption keys (identity-scoped, not group-scoped)
/// - Messages (handled separately via `invalidate_messages_after_epoch`)
/// - Welcomes (keyed by EventId, not group-scoped)
#[derive(Clone)]
pub struct GroupScopedSnapshot {
    /// The group ID this snapshot is for
    pub(crate) group_id: GroupId,

    /// Unix timestamp when this snapshot was created
    pub(crate) created_at: u64,

    // MLS data (filtered by group_id)
    /// MLS group data: (group_id, data_type) -> data
    pub(crate) mls_group_data: HashMap<(Vec<u8>, GroupDataType), Vec<u8>>,
    /// MLS own leaf nodes for this group
    pub(crate) mls_own_leaf_nodes: Vec<Vec<u8>>,
    /// MLS proposals: proposal_ref -> proposal (group_id is implicit)
    pub(crate) mls_proposals: HashMap<Vec<u8>, Vec<u8>>,
    /// MLS epoch key pairs: (epoch_id, leaf_index) -> key_pairs (group_id is implicit)
    pub(crate) mls_epoch_key_pairs: HashMap<(Vec<u8>, u32), Vec<u8>>,

    // MDK data
    /// The group record itself
    pub(crate) group: Option<Group>,
    /// Group relays
    pub(crate) group_relays: BTreeSet<GroupRelay>,
    /// Group exporter secrets (MIP-03 group-event): epoch -> secret
    pub(crate) group_exporter_secrets: HashMap<u64, GroupExporterSecret>,
    /// Legacy pre-0.7.0 exporter secrets retained for migration compatibility.
    pub(crate) group_legacy_exporter_secrets: HashMap<u64, GroupExporterSecret>,
    /// Group MIP-04 encrypted-media exporter secrets: epoch -> secret
    pub(crate) group_mip04_exporter_secrets: HashMap<u64, GroupExporterSecret>,
}

/// A snapshot of all in-memory state that can be restored later.
///
/// This enables rollback functionality similar to SQLite savepoints,
/// allowing you to:
/// 1. Create a snapshot before an operation
/// 2. Attempt the operation
/// 3. Restore the snapshot if the operation fails or needs to be undone
///
/// # Concurrency
///
/// Snapshot creation and restoration are **atomic**. `create_snapshot()` acquires
/// a global read lock and `restore_snapshot()` acquires a global write lock,
/// ensuring consistency in multi-threaded environments.
///
/// # Example
///
/// ```ignore
/// let storage = MdkMemoryStorage::default();
///
/// // Make some changes
/// storage.save_group(group)?;
///
/// // Create a snapshot (ensure no concurrent operations)
/// let snapshot = storage.create_snapshot();
///
/// // Try an operation that might need rollback
/// storage.save_message(message)?;
///
/// // If we need to undo (ensure no concurrent operations):
/// storage.restore_snapshot(snapshot);
/// ```
#[derive(Clone)]
pub struct MemoryStorageSnapshot {
    // MLS data
    pub(crate) mls_group_data: HashMap<(Vec<u8>, GroupDataType), Vec<u8>>,
    pub(crate) mls_own_leaf_nodes: HashMap<Vec<u8>, Vec<Vec<u8>>>,
    pub(crate) mls_proposals: HashMap<(Vec<u8>, Vec<u8>), Vec<u8>>,
    pub(crate) mls_key_packages: HashMap<Vec<u8>, Vec<u8>>,
    pub(crate) mls_psks: HashMap<Vec<u8>, Vec<u8>>,
    pub(crate) mls_signature_keys: HashMap<Vec<u8>, Vec<u8>>,
    pub(crate) mls_encryption_keys: HashMap<Vec<u8>, Vec<u8>>,
    pub(crate) mls_epoch_key_pairs: HashMap<(Vec<u8>, Vec<u8>, u32), Vec<u8>>,

    // MDK data - hot caches (LruCache) and security-critical maps (HashMap)
    pub(crate) groups: HashMap<GroupId, Group>,
    pub(crate) groups_by_nostr_id: HashMap<[u8; 32], Group>,
    pub(crate) group_relays: HashMap<GroupId, BTreeSet<GroupRelay>>,
    pub(crate) group_exporter_secrets: HashMap<(GroupId, u64), GroupExporterSecret>,
    pub(crate) group_legacy_exporter_secrets: HashMap<(GroupId, u64), GroupExporterSecret>,
    pub(crate) group_mip04_exporter_secrets: HashMap<(GroupId, u64), GroupExporterSecret>,
    pub(crate) welcomes: HashMap<EventId, Welcome>,
    pub(crate) processed_welcomes: HashMap<EventId, ProcessedWelcome>,
    pub(crate) messages: HashMap<EventId, Message>,
    pub(crate) messages_by_group: HashMap<GroupId, HashMap<EventId, Message>>,
    pub(crate) processed_messages: HashMap<EventId, ProcessedMessage>,
}

#[cfg(test)]
impl MemoryStorageSnapshot {
    /// Create a new empty snapshot for testing.
    pub(crate) fn new() -> Self {
        Self {
            mls_group_data: HashMap::new(),
            mls_own_leaf_nodes: HashMap::new(),
            mls_proposals: HashMap::new(),
            mls_key_packages: HashMap::new(),
            mls_psks: HashMap::new(),
            mls_signature_keys: HashMap::new(),
            mls_encryption_keys: HashMap::new(),
            mls_epoch_key_pairs: HashMap::new(),
            groups: HashMap::new(),
            groups_by_nostr_id: HashMap::new(),
            group_relays: HashMap::new(),
            group_exporter_secrets: HashMap::new(),
            group_legacy_exporter_secrets: HashMap::new(),
            group_mip04_exporter_secrets: HashMap::new(),
            welcomes: HashMap::new(),
            processed_welcomes: HashMap::new(),
            messages: HashMap::new(),
            messages_by_group: HashMap::new(),
            processed_messages: HashMap::new(),
        }
    }
}

/// Helper trait to clone LRU cache contents into a HashMap.
pub(crate) trait LruCacheExt<K, V> {
    /// Clone all entries from the LRU cache into a HashMap.
    fn clone_to_hashmap(&self) -> HashMap<K, V>
    where
        K: Clone + std::hash::Hash + Eq,
        V: Clone;
}

impl<K, V> LruCacheExt<K, V> for LruCache<K, V> {
    fn clone_to_hashmap(&self) -> HashMap<K, V>
    where
        K: Clone + std::hash::Hash + Eq,
        V: Clone,
    {
        self.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
    }
}

/// Helper trait to restore HashMap contents back into an LRU cache.
pub(crate) trait HashMapToLruExt<K, V> {
    /// Restore entries from a HashMap into an LRU cache.
    fn restore_to_lru(&self, cache: &mut LruCache<K, V>)
    where
        K: Clone + std::hash::Hash + Eq,
        V: Clone;
}

impl<K, V> HashMapToLruExt<K, V> for HashMap<K, V> {
    fn restore_to_lru(&self, cache: &mut LruCache<K, V>)
    where
        K: Clone + std::hash::Hash + Eq,
        V: Clone,
    {
        cache.clear();
        for (k, v) in self.iter() {
            cache.put(k.clone(), v.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use std::num::NonZeroUsize;

    use super::*;

    #[test]
    fn test_lru_cache_clone_to_hashmap() {
        let mut cache: LruCache<String, i32> = LruCache::new(NonZeroUsize::new(10).unwrap());
        cache.put("a".to_string(), 1);
        cache.put("b".to_string(), 2);
        cache.put("c".to_string(), 3);

        let map = cache.clone_to_hashmap();
        assert_eq!(map.len(), 3);
        assert_eq!(map.get("a"), Some(&1));
        assert_eq!(map.get("b"), Some(&2));
        assert_eq!(map.get("c"), Some(&3));
    }

    #[test]
    fn test_hashmap_restore_to_lru() {
        let mut map = HashMap::new();
        map.insert("x".to_string(), 10);
        map.insert("y".to_string(), 20);

        let mut cache: LruCache<String, i32> = LruCache::new(NonZeroUsize::new(10).unwrap());
        cache.put("old".to_string(), 999);

        map.restore_to_lru(&mut cache);

        assert_eq!(cache.len(), 2);
        assert_eq!(cache.get(&"x".to_string()), Some(&10));
        assert_eq!(cache.get(&"y".to_string()), Some(&20));
        assert!(cache.get(&"old".to_string()).is_none());
    }

    #[test]
    fn test_empty_snapshot() {
        let snapshot = MemoryStorageSnapshot::new();
        assert!(snapshot.mls_group_data.is_empty());
        assert!(snapshot.groups.is_empty());
        assert!(snapshot.messages.is_empty());
    }
}

// Moranduba patch: a serde form of the full snapshot, so state that only lives
// in memory (the browser build) can be persisted between sessions.

fn group_data_type_from_str(value: &str) -> Option<GroupDataType> {
    [
        GroupDataType::JoinGroupConfig,
        GroupDataType::Tree,
        GroupDataType::InterimTranscriptHash,
        GroupDataType::Context,
        GroupDataType::ConfirmationTag,
        GroupDataType::GroupState,
        GroupDataType::MessageSecrets,
        GroupDataType::ResumptionPskStore,
        GroupDataType::OwnLeafIndex,
        GroupDataType::GroupEpochSecrets,
    ]
    .into_iter()
    .find(|t| t.as_str() == value)
}

type Pairs<K, V> = Vec<(K, V)>;

#[derive(serde::Serialize, serde::Deserialize)]
struct PersistedSnapshot {
    version: u32,
    mls_group_data: Vec<(Vec<u8>, String, Vec<u8>)>,
    mls_own_leaf_nodes: Pairs<Vec<u8>, Vec<Vec<u8>>>,
    mls_proposals: Pairs<(Vec<u8>, Vec<u8>), Vec<u8>>,
    mls_key_packages: Pairs<Vec<u8>, Vec<u8>>,
    mls_psks: Pairs<Vec<u8>, Vec<u8>>,
    mls_signature_keys: Pairs<Vec<u8>, Vec<u8>>,
    mls_encryption_keys: Pairs<Vec<u8>, Vec<u8>>,
    mls_epoch_key_pairs: Pairs<(Vec<u8>, Vec<u8>, u32), Vec<u8>>,
    groups: Pairs<GroupId, Group>,
    groups_by_nostr_id: Pairs<[u8; 32], Group>,
    group_relays: Pairs<GroupId, BTreeSet<GroupRelay>>,
    group_exporter_secrets: Pairs<(GroupId, u64), GroupExporterSecret>,
    group_legacy_exporter_secrets: Pairs<(GroupId, u64), GroupExporterSecret>,
    group_mip04_exporter_secrets: Pairs<(GroupId, u64), GroupExporterSecret>,
    welcomes: Pairs<EventId, Welcome>,
    processed_welcomes: Pairs<EventId, ProcessedWelcome>,
    messages: Pairs<EventId, Message>,
    messages_by_group: Pairs<GroupId, Pairs<EventId, Message>>,
    processed_messages: Pairs<EventId, ProcessedMessage>,
}

const PERSISTED_VERSION: u32 = 1;

fn pairs<K: Clone, V: Clone>(map: &HashMap<K, V>) -> Pairs<K, V> {
    map.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
}

impl MemoryStorageSnapshot {
    /// Serializes the snapshot to JSON.
    pub fn to_json(&self) -> Result<Vec<u8>, serde_json::Error> {
        let record = PersistedSnapshot {
            version: PERSISTED_VERSION,
            mls_group_data: self
                .mls_group_data
                .iter()
                .map(|((id, t), v)| (id.clone(), t.as_str().to_string(), v.clone()))
                .collect(),
            mls_own_leaf_nodes: pairs(&self.mls_own_leaf_nodes),
            mls_proposals: pairs(&self.mls_proposals),
            mls_key_packages: pairs(&self.mls_key_packages),
            mls_psks: pairs(&self.mls_psks),
            mls_signature_keys: pairs(&self.mls_signature_keys),
            mls_encryption_keys: pairs(&self.mls_encryption_keys),
            mls_epoch_key_pairs: pairs(&self.mls_epoch_key_pairs),
            groups: pairs(&self.groups),
            groups_by_nostr_id: pairs(&self.groups_by_nostr_id),
            group_relays: pairs(&self.group_relays),
            group_exporter_secrets: pairs(&self.group_exporter_secrets),
            group_legacy_exporter_secrets: pairs(&self.group_legacy_exporter_secrets),
            group_mip04_exporter_secrets: pairs(&self.group_mip04_exporter_secrets),
            welcomes: pairs(&self.welcomes),
            processed_welcomes: pairs(&self.processed_welcomes),
            messages: pairs(&self.messages),
            messages_by_group: self
                .messages_by_group
                .iter()
                .map(|(id, m)| (id.clone(), pairs(m)))
                .collect(),
            processed_messages: pairs(&self.processed_messages),
        };
        serde_json::to_vec(&record)
    }

    /// Parses a snapshot written by [`MemoryStorageSnapshot::to_json`].
    pub fn from_json(bytes: &[u8]) -> Result<Self, String> {
        let r: PersistedSnapshot = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        if r.version != PERSISTED_VERSION {
            return Err(format!("unsupported snapshot version {}", r.version));
        }
        let mut mls_group_data = HashMap::new();
        for (id, t, v) in r.mls_group_data {
            let t = group_data_type_from_str(&t).ok_or(format!("unknown group data type {t}"))?;
            mls_group_data.insert((id, t), v);
        }
        Ok(Self {
            mls_group_data,
            mls_own_leaf_nodes: r.mls_own_leaf_nodes.into_iter().collect(),
            mls_proposals: r.mls_proposals.into_iter().collect(),
            mls_key_packages: r.mls_key_packages.into_iter().collect(),
            mls_psks: r.mls_psks.into_iter().collect(),
            mls_signature_keys: r.mls_signature_keys.into_iter().collect(),
            mls_encryption_keys: r.mls_encryption_keys.into_iter().collect(),
            mls_epoch_key_pairs: r.mls_epoch_key_pairs.into_iter().collect(),
            groups: r.groups.into_iter().collect(),
            groups_by_nostr_id: r.groups_by_nostr_id.into_iter().collect(),
            group_relays: r.group_relays.into_iter().collect(),
            group_exporter_secrets: r.group_exporter_secrets.into_iter().collect(),
            group_legacy_exporter_secrets: r.group_legacy_exporter_secrets.into_iter().collect(),
            group_mip04_exporter_secrets: r.group_mip04_exporter_secrets.into_iter().collect(),
            welcomes: r.welcomes.into_iter().collect(),
            processed_welcomes: r.processed_welcomes.into_iter().collect(),
            messages: r.messages.into_iter().collect(),
            messages_by_group: r
                .messages_by_group
                .into_iter()
                .map(|(id, m)| (id, m.into_iter().collect()))
                .collect(),
            processed_messages: r.processed_messages.into_iter().collect(),
        })
    }
}
