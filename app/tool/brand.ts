// Renders launcher-icon sources and the web favicon from assets/brand/logo.svg.
// Run from app/: bun tool/brand.ts && dart run flutter_launcher_icons
import { Resvg } from "@resvg/resvg-js@2.6.2";

const logo = await Bun.file("assets/brand/logo.svg").text();
const viewBox = logo.match(/viewBox="([^"]+)"/)?.[1].split(" ").map(Number);
if (!viewBox) throw new Error("logo.svg has no viewBox");
const [x, y, size] = viewBox;

// `scale` is the share of the canvas the logo spans.
function framed(scale: number, background?: string): string {
  const side = size / scale;
  const ox = x - (side - size) / 2;
  const oy = y - (side - size) / 2;
  const bg = background
    ? `<rect x="${ox}" y="${oy}" width="${side}" height="${side}" fill="${background}"/>`
    : "";
  return logo
    .replace(/viewBox="[^"]+"/, `viewBox="${ox} ${oy} ${side} ${side}"`)
    .replace(/(<svg[^>]*>)/, `$1${bg}`);
}

async function png(svg: string, out: string) {
  const data = new Resvg(svg, { fitTo: { mode: "width", value: 1024 } })
    .render()
    .asPng();
  await Bun.write(out, data);
}

await png(framed(0.78, "#fff"), "assets/brand/icon.png");
// Android adaptive icons crop to a circle covering ~61% of the canvas.
await png(framed(0.58), "assets/brand/icon_foreground.png");

const favicon = framed(0.94).replace(
  /(<svg[^>]*>)/,
  "$1<style>svg{color:#000}" +
    "@media (prefers-color-scheme:dark){svg{color:#fff}}" +
    "g[mask]{fill:currentColor}g[fill=none]{stroke:currentColor}</style>",
);
await Bun.write("web/favicon.svg", favicon);
