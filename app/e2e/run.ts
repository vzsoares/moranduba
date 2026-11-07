// Opens one e2e page per participant in headless Chrome with fake camera and
// microphone. Exits 0 when every page logs PASS, 1 on any FAIL, 2 on timeout.
import puppeteer from "puppeteer-core";
import { generateSecretKey, getPublicKey } from "nostr-tools/pure";
import { bytesToHex } from "@noble/hashes/utils";

const base = process.argv[2];
const roles = (process.argv[3] ?? "alice,bob").split(",");
const chrome =
  process.env.CHROME ??
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const keys = roles.map(() => bytesToHex(generateSecretKey()));
const pubkeys = keys.map((sk) => getPublicKey(Buffer.from(sk, "hex")));

const browser = await puppeteer.launch({
  executablePath: chrome,
  headless: true,
  args: [
    "--use-fake-device-for-media-stream",
    "--use-fake-ui-for-media-stream",
    "--autoplay-policy=no-user-gesture-required",
  ],
});

const results = roles.map(async (role, i) => {
  const page = await browser.newPage();
  const peers = pubkeys.filter((_, j) => j !== i).join(",");
  const done = new Promise<boolean>((resolve) => {
    page.on("console", (message) => {
      const text = message.text();
      if (text.startsWith("E2E")) console.log(text);
      else if (process.env.E2E_VERBOSE) console.log(`${role}:`, text.slice(0, 300));
      if (text.startsWith(`E2E ${role} PASS`)) resolve(true);
      if (text.startsWith(`E2E ${role} FAIL`)) resolve(false);
    });
    page.on("pageerror", (error) => console.log(`${role} pageerror:`, error.message));
    if (process.env.E2E_VERBOSE) {
      page.on("workercreated", async (worker) => {
        console.log(`${role} worker created:`, worker.url());
        worker.on("console", (m) => console.log(`${role} worker:`, m.text().slice(0, 300)));
        // @ts-ignore: CDP session of the worker target
        const client = worker.client;
        client.on("Runtime.exceptionThrown", (e: any) =>
          console.log(`${role} worker exception:`, JSON.stringify(e.exceptionDetails).slice(0, 600)),
        );
        client.on("Runtime.consoleAPICalled", (e: any) =>
          console.log(
            `${role} worker:`,
            e.args.map((a: any) => a.value ?? a.description).join(" ").slice(0, 300),
          ),
        );
        await client.send("Runtime.enable").catch(() => {});
      });
    }
  });
  if (process.env.E2E_NO_SCRIPT_TRANSFORM) {
    await page.evaluateOnNewDocument(() => {
      // @ts-ignore
      delete window.RTCRtpScriptTransform;
    });
  }
  // Stagger so the first role sets up the group before others look for it.
  await new Promise((r) => setTimeout(r, i * 1500));
  if (process.env.E2E_VERBOSE) {
    setTimeout(async () => {
      const report = await page.evaluate(() =>
        // @ts-ignore
        (window.morandubaE2ee?.receivers ?? []).map((x: any) => ({
          same: x.receiver.transform === x.transform,
          kind: x.receiver.track.kind,
          pcs: x.pc.connectionState,
        })),
      );
      console.log(`${role} receivers:`, JSON.stringify(report));
    }, 25_000);
  }
  await page.goto(`${base}?role=${role}&sk=${keys[i]}&peer=${peers}${process.env.E2E_QUERY ?? ''}`);
  return done;
});

const timeout = new Promise<boolean[]>((resolve) =>
  setTimeout(() => {
    console.log("E2E TIMEOUT");
    resolve([false]);
  }, 240_000),
);
const outcome = await Promise.race([Promise.all(results), timeout]);
await browser.close();
process.exit(outcome.every(Boolean) ? 0 : outcome.length === 1 ? 2 : 1);
