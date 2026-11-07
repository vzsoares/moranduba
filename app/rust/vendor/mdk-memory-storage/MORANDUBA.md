Vendored from crates.io `mdk-memory-storage` 0.8.0 (MIT, see LICENSE).

Patch: `MemoryStorageSnapshot::to_json` / `from_json` at the end of
`src/snapshot.rs`, so the in-memory store can be saved and restored.

Patch: `std::time::SystemTime` replaced with `web_time` in `src/lib.rs`, for
the same wasm clock reason as the vendored mdk-core.

Patch: `MdkMemoryStorage::delete_messages_before` in `src/messages.rs`, so
disappearing messages can drop expired history (the trait has no per-message
delete).
