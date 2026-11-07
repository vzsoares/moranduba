// Group lifecycle against the wasm engine, to catch wasm-only panics
// (clocks, randomness). Run through tool/test_web_mls.sh.
const { mlsCall } = require(process.argv[2]);
const { randomBytes } = require("crypto");

const hex = (n) => randomBytes(n).toString("hex");
const relays = ["wss://relay.test"];
const storageKey = hex(32);

function ok(handle, method, args) {
  const reply = JSON.parse(
    mlsCall(handle, method, args === undefined ? "" : JSON.stringify(args)),
  );
  if (reply.err !== undefined) throw new Error(`${method}: ${reply.err}`);
  return reply.ok;
}

function peer() {
  const secret = hex(32);
  const open = (snapshot) =>
    ok(0, "open", { secret_key: secret, storage_key: storageKey, snapshot });
  const p = { handle: open(null) };
  p.call = (m, a) => ok(p.handle, m, a);
  p.keyPackage = () => p.call("key_package", { relays });
  p.join = (welcome) => {
    p.call("process_welcome", { wrapper_id: hex(32), rumor: welcome });
    p.call("accept", { id: p.call("invites")[0].id });
  };
  p.restart = () => {
    const snapshot = p.call("snapshot");
    p.call("close");
    p.handle = open(snapshot);
  };
  return p;
}

function expect(condition, what) {
  if (!condition) throw new Error(`failed: ${what}`);
}

const alice = peer();
const bob = peer();
const carol = peer();

const created = alice.call("create_group", {
  name: "wasm",
  relays,
  key_packages: [bob.keyPackage()],
});
const group_id = created.group.id;
bob.join(created.welcomes[0]);

const hello = alice.call("encrypt_text", { group_id, text: "hello" });
expect(bob.call("receive", { event: hello }).message.text === "hello", "chat");

const added = alice.call("add_members", {
  group_id,
  key_packages: [carol.keyPackage()],
});
alice.call("merge", { group_id });
bob.call("receive", { event: added.commit });
carol.join(added.welcomes[0]);

const png =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const media = alice.call("encrypt_media", {
  group_id,
  data: png,
  mime: "image/png",
  filename: "dot.png",
});
const pic = alice.call("send_media", {
  group_id,
  caption: "pic",
  url: "https://blossom.test/x",
  upload: media.upload,
});
const ref = bob.call("receive", { event: pic }).message.media[0];
const plain = bob.call("decrypt_media", { group_id, data: media.encrypted, media: ref });
expect(Buffer.from(plain, "base64").subarray(1, 4).toString() === "PNG", "image");

bob.restart();
const after = carol.call("encrypt_text", { group_id, text: "after restart" });
expect(
  bob.call("receive", { event: after }).message.text === "after restart",
  "decrypt after restart",
);

const [demote, leave] = bob.call("leave", { group_id });
alice.call("receive", { event: demote });
carol.call("receive", { event: demote });
// Every member auto-commits a leave; only the lowest pubkey may publish.
const receipts = [alice, carol].map((p) => p.call("receive", { event: leave }));
const committers = receipts.filter((r) => typeof r.publish === "string");
expect(committers.length === 1, "one committer");
const committerIndex = receipts.indexOf(committers[0]);
const committer = [alice, carol][committerIndex];
const other = [alice, carol][1 - committerIndex];
committer.call("merge", { group_id });
other.call("receive", { event: committers[0].publish });
expect(alice.call("members", { group_id }).length === 2, "bob removed");
expect(carol.call("members", { group_id }).length === 2, "carol agrees");
const bye = other.call("encrypt_text", { group_id, text: "just us" });
expect(
  committer.call("receive", { event: bye }).message.text === "just us",
  "chat after the leave",
);

console.log("wasm lifecycle ok");
