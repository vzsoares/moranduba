// Dev-only Blossom server (BUD-01/02 subset): PUT /upload, GET /<sha256>.
// Blobs live in memory; auth is accepted without checks.
const blobs = new Map<string, Uint8Array>();
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, HEAD, PUT, OPTIONS",
  "Access-Control-Allow-Headers": "Authorization, Content-Type, *",
};

Bun.serve({
  port: 8800,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });
    if (req.method === "PUT" && url.pathname === "/upload") {
      const bytes = new Uint8Array(await req.arrayBuffer());
      const sha256 = new Bun.CryptoHasher("sha256").update(bytes).digest("hex");
      blobs.set(sha256, bytes);
      // Behind a tunnel the public scheme and host arrive as headers.
      const host = req.headers.get("host") ?? url.host;
      const scheme = req.headers.get("x-forwarded-proto") ?? "http";
      return Response.json(
        { url: `${scheme}://${host}/${sha256}`, sha256, size: bytes.length },
        { headers: cors },
      );
    }
    const blob = blobs.get(url.pathname.slice(1).split(".")[0]);
    if (blob) return new Response(blob, { headers: cors });
    return new Response("not found", { status: 404, headers: cors });
  },
});
