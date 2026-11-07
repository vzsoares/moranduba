use nostr::{Event, JsonUtil, Keys};
use serde_json::{json, Value};

use super::call;

const RELAYS: [&str; 1] = ["wss://relay.test"];

fn ok(handle: u32, method: &str, args: Value) -> Value {
    let reply: Value = serde_json::from_str(&call(handle, method, &args.to_string())).unwrap();
    if let Some(e) = reply.get("err") {
        panic!("{method} failed: {e}");
    }
    reply["ok"].clone()
}

struct Peer {
    handle: u32,
    keys: Keys,
    storage_key: String,
}

impl Peer {
    fn new() -> Self {
        let keys = Keys::generate();
        let storage_key = hex::encode([7u8; 32]);
        let handle = Self::open(&keys, &storage_key, None);
        Self {
            handle,
            keys,
            storage_key,
        }
    }

    fn open(keys: &Keys, storage_key: &str, snapshot: Option<Value>) -> u32 {
        ok(
            0,
            "open",
            json!({
                "secret_key": keys.secret_key().to_secret_hex(),
                "storage_key": storage_key,
                "snapshot": snapshot,
            }),
        )
        .as_u64()
        .unwrap() as u32
    }

    fn call(&self, method: &str, args: Value) -> Value {
        ok(self.handle, method, args)
    }

    fn pubkey(&self) -> String {
        self.keys.public_key().to_hex()
    }

    fn key_package(&self) -> String {
        self.call("key_package", json!({ "relays": RELAYS }))
            .as_str()
            .unwrap()
            .to_string()
    }

    fn join(&self, welcome: &Value) {
        // Welcomes arrive gift-wrapped; any 32-byte id stands in for the wrap.
        let wrapper = hex::encode([9u8; 32]);
        self.call(
            "process_welcome",
            json!({ "wrapper_id": wrapper, "rumor": welcome }),
        );
        let invites = self.call("invites", json!(null));
        let id = invites[0]["id"].as_str().unwrap().to_string();
        self.call("accept", json!({ "id": id }));
    }

    /// Restarts this peer from its own encrypted snapshot.
    fn restart(&mut self) {
        let snapshot = self.call("snapshot", json!(null));
        call(self.handle, "close", "");
        self.handle = Self::open(&self.keys, &self.storage_key, Some(snapshot));
    }
}

fn send(from: &Peer, group: &str, text: &str) -> String {
    from.call("encrypt_text", json!({ "group_id": group, "text": text }))
        .as_str()
        .unwrap()
        .to_string()
}

#[test]
fn group_lifecycle_with_restart_and_leave() {
    let alice = Peer::new();
    let mut bob = Peer::new();

    let created = alice.call(
        "create_group",
        json!({ "name": "Moranduba", "relays": RELAYS, "key_packages": [bob.key_package()] }),
    );
    let group = created["group"]["id"].as_str().unwrap().to_string();
    let nostr_group_id = created["group"]["nostr_group_id"].as_str().unwrap();
    assert_eq!(created["welcomes"].as_array().unwrap().len(), 1);

    bob.join(&created["welcomes"][0]);
    let bob_groups = bob.call("groups", json!(null));
    assert_eq!(bob_groups[0]["id"], json!(group));
    assert_eq!(bob_groups[0]["member_count"], json!(2));

    let event = send(&alice, &group, "hello bob");
    let parsed = Event::from_json(&event).unwrap();
    assert_eq!(parsed.kind.as_u16(), 445);
    let h = parsed.tags.iter().find(|t| t.as_slice()[0] == "h").unwrap();
    assert_eq!(h.as_slice()[1], nostr_group_id);

    let received = bob.call("receive", json!({ "event": event }));
    assert_eq!(received["message"]["text"], json!("hello bob"));
    assert_eq!(received["message"]["sender"], json!(alice.pubkey()));

    // State survives a restart from the encrypted snapshot.
    bob.restart();
    let history = bob.call("messages", json!({ "group_id": group }));
    assert_eq!(history[0]["text"], json!("hello bob"));
    let reply = send(&bob, &group, "hi alice");
    let got = alice.call("receive", json!({ "event": reply }));
    assert_eq!(got["message"]["text"], json!("hi alice"));
    assert_eq!(
        alice
            .call("messages", json!({ "group_id": group }))
            .as_array()
            .unwrap()
            .len(),
        2
    );

    // Bob is an admin, so leaving is a self-demote commit plus a proposal
    // that Alice auto-commits.
    let events = bob.call("leave", json!({ "group_id": group }));
    let events = events.as_array().unwrap();
    assert_eq!(events.len(), 2);
    alice.call("receive", json!({ "event": events[0] }));
    let proposal = alice.call("receive", json!({ "event": events[1] }));
    let commit = proposal["publish"]
        .as_str()
        .expect("auto-commit")
        .to_string();
    alice.call("merge", json!({ "group_id": group }));
    assert_eq!(
        alice.call("members", json!({ "group_id": group })),
        json!([alice.pubkey()])
    );

    // Bob's copy went inactive when he left; the commit is only for others.
    assert_eq!(bob.call("groups", json!(null)), json!([]));
    let _ = call(
        bob.handle,
        "receive",
        &json!({ "event": commit }).to_string(),
    );
}

#[test]
fn add_member_and_decline_invite() {
    let alice = Peer::new();
    let bob = Peer::new();
    let carol = Peer::new();
    let dave = Peer::new();

    let created = alice.call(
        "create_group",
        json!({ "name": "late", "relays": RELAYS, "key_packages": [bob.key_package()] }),
    );
    let group = created["group"]["id"].as_str().unwrap().to_string();
    bob.join(&created["welcomes"][0]);

    let added = alice.call(
        "add_members",
        json!({ "group_id": group, "key_packages": [carol.key_package()] }),
    );
    alice.call("merge", json!({ "group_id": group }));
    bob.call("receive", json!({ "event": added["commit"] }));
    carol.join(&added["welcomes"][0]);
    assert_eq!(
        bob.call("members", json!({ "group_id": group }))
            .as_array()
            .unwrap()
            .len(),
        3
    );

    let hello = send(&carol, &group, "hi all");
    assert_eq!(
        bob.call("receive", json!({ "event": hello }))["message"]["text"],
        json!("hi all")
    );

    let other = alice.call(
        "create_group",
        json!({ "name": "nope", "relays": RELAYS, "key_packages": [dave.key_package()] }),
    );
    dave.call(
        "process_welcome",
        json!({ "wrapper_id": hex::encode([3u8; 32]), "rumor": other["welcomes"][0] }),
    );
    let id = dave.call("invites", json!(null))[0]["id"].clone();
    dave.call("decline", json!({ "id": id }));
    assert_eq!(dave.call("invites", json!(null)), json!([]));
    assert_eq!(dave.call("groups", json!(null)), json!([]));
}

#[test]
fn snapshot_needs_the_right_key() {
    let peer = Peer::new();
    let snapshot = peer.call("snapshot", json!(null));
    let reply: Value = serde_json::from_str(&call(
        0,
        "open",
        &json!({
            "secret_key": peer.keys.secret_key().to_secret_hex(),
            "storage_key": hex::encode([1u8; 32]),
            "snapshot": snapshot,
        })
        .to_string(),
    ))
    .unwrap();
    assert!(reply["err"].as_str().unwrap().contains("decrypt"));
}

#[test]
fn leave_in_a_trio_has_one_committer() {
    let alice = Peer::new();
    let bob = Peer::new();
    let carol = Peer::new();
    let created = alice.call(
        "create_group",
        json!({
            "name": "trio",
            "relays": RELAYS,
            "key_packages": [bob.key_package(), carol.key_package()],
        }),
    );
    let group = created["group"]["id"].as_str().unwrap().to_string();
    bob.join(&created["welcomes"][0]);
    carol.join(&created["welcomes"][1]);

    let events = bob.call("leave", json!({ "group_id": group }));
    let events = events.as_array().unwrap();
    let mut commits = Vec::new();
    for peer in [&alice, &carol] {
        let mut publish = None;
        for event in events {
            let receipt = peer.call("receive", json!({ "event": event }));
            if let Some(commit) = receipt["publish"].as_str() {
                publish = Some(commit.to_string());
            }
        }
        if let Some(commit) = publish {
            peer.call("merge", json!({ "group_id": group }));
            commits.push((peer.pubkey(), commit));
        }
    }
    assert_eq!(commits.len(), 1, "exactly one member commits the leave");
    let (committer, commit) = &commits[0];
    assert_eq!(*committer, alice.pubkey().min(carol.pubkey()));
    let other = if *committer == alice.pubkey() {
        &carol
    } else {
        &alice
    };
    other.call("receive", json!({ "event": commit }));

    for peer in [&alice, &carol] {
        let members = peer.call("members", json!({ "group_id": group }));
        assert_eq!(members.as_array().unwrap().len(), 2);
    }
    let note = send(other, &group, "still two of us");
    let from = if other.pubkey() == alice.pubkey() {
        &carol
    } else {
        &alice
    };
    assert_eq!(
        from.call("receive", json!({ "event": note }))["message"]["text"],
        json!("still two of us")
    );
}

#[test]
fn image_attachment_round_trip() {
    use base64::engine::general_purpose::STANDARD as BASE64;
    use base64::Engine as _;

    // 1x1 PNG.
    const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
    let alice = Peer::new();
    let bob = Peer::new();
    let created = alice.call(
        "create_group",
        json!({ "name": "pics", "relays": RELAYS, "key_packages": [bob.key_package()] }),
    );
    let group = created["group"]["id"].as_str().unwrap().to_string();
    bob.join(&created["welcomes"][0]);

    let encrypted = alice.call(
        "encrypt_media",
        json!({ "group_id": group, "data": PNG, "mime": "image/png", "filename": "dot.png" }),
    );
    let blob = encrypted["encrypted"].as_str().unwrap().to_string();
    assert_ne!(blob, PNG);
    let url = "https://blossom.test/blob";
    let event = alice.call(
        "send_media",
        json!({
            "group_id": group,
            "caption": "look",
            "url": url,
            "upload": encrypted["upload"],
        }),
    );

    let received = bob.call("receive", json!({ "event": event }));
    let message = &received["message"];
    assert_eq!(message["text"], json!("look"));
    let media = &message["media"][0];
    assert_eq!(media["url"], json!(url));
    assert_eq!(media["mime"], json!("image/png"));

    let plain = bob.call(
        "decrypt_media",
        json!({ "group_id": group, "data": blob, "media": media }),
    );
    let original = BASE64.decode(PNG).unwrap();
    let decoded = BASE64.decode(plain.as_str().unwrap()).unwrap();
    // MDK strips metadata, so compare pixels' container, not exact bytes.
    assert!(decoded.starts_with(&original[..8]), "still a PNG");
}

#[test]
fn signals_and_call_keys_agree() {
    let alice = Peer::new();
    let bob = Peer::new();
    let created = alice.call(
        "create_group",
        json!({ "name": "call", "relays": RELAYS, "key_packages": [bob.key_package()] }),
    );
    let group = created["group"]["id"].as_str().unwrap().to_string();
    bob.join(&created["welcomes"][0]);

    let signal = alice.call(
        "send_signal",
        json!({ "group_id": group, "payload": "{\"type\":\"join\"}" }),
    );
    let got = bob.call("receive", json!({ "event": signal }));
    assert_eq!(got["signal"]["payload"], json!("{\"type\":\"join\"}"));
    assert!(got.get("message").is_none());
    assert_eq!(
        bob.call("messages", json!({ "group_id": group })),
        json!([]),
        "signals stay out of the chat"
    );

    let args =
        json!({ "group_id": group, "label": "moranduba", "context": "call:x", "length": 32 });
    let a = alice.call("export_secret", args.clone());
    let b = bob.call("export_secret", args);
    assert_eq!(a, b);
    assert_eq!(a["secret"].as_str().unwrap().len(), 64);
    let other = alice.call(
        "export_secret",
        json!({ "group_id": group, "label": "moranduba", "context": "call:y", "length": 32 }),
    );
    assert_ne!(a["secret"], other["secret"]);
}

#[test]
fn any_file_round_trips() {
    use base64::engine::general_purpose::STANDARD as BASE64;
    use base64::Engine as _;

    let alice = Peer::new();
    let bob = Peer::new();
    let created = alice.call(
        "create_group",
        json!({ "name": "files", "relays": RELAYS, "key_packages": [bob.key_package()] }),
    );
    let group = created["group"]["id"].as_str().unwrap().to_string();
    bob.join(&created["welcomes"][0]);

    let cases: [(&str, &str, Vec<u8>); 3] = [
        (
            "doc.pdf",
            "application/pdf",
            b"%PDF-1.4\n1 0 obj<<>>endobj\n%%EOF".to_vec(),
        ),
        (
            "notes.bin",
            "application/octet-stream",
            (0..=255u8).collect(),
        ),
        (
            "clip.webm",
            "video/webm",
            vec![0x1a, 0x45, 0xdf, 0xa3, 1, 2, 3, 4],
        ),
    ];
    for (name, mime, bytes) in cases {
        let data = BASE64.encode(&bytes);
        let encrypted = alice.call(
            "encrypt_media",
            json!({ "group_id": group, "data": data, "mime": mime, "filename": name }),
        );
        let event = alice.call(
            "send_media",
            json!({
                "group_id": group,
                "caption": "",
                "url": format!("https://blossom.test/{name}"),
                "upload": encrypted["upload"],
            }),
        );
        let media = bob.call("receive", json!({ "event": event }))["message"]["media"][0].clone();
        assert_eq!(media["mime"], json!(mime), "{name}");
        let plain = bob.call(
            "decrypt_media",
            json!({ "group_id": group, "data": encrypted["encrypted"], "media": media }),
        );
        assert_eq!(
            BASE64.decode(plain.as_str().unwrap()).unwrap(),
            bytes,
            "{name}"
        );
    }
}
