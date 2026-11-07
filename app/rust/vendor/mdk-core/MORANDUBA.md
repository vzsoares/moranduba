Vendored from crates.io `mdk-core` 0.8.0 (MIT, see LICENSE).

Patch: `std::time::{Instant, SystemTime, UNIX_EPOCH}` replaced with `web_time`
in `src/epoch_snapshots.rs` and `src/lib.rs`, because std's clock panics on
wasm32-unknown-unknown. `web_time` re-exports std on native targets.

Patch: `pending_removed_members_pubkeys` in `src/groups.rs` also reports the
sender of a pending SelfRemove, so members can agree on who commits a leave.
