// Builds docs/hero-iso.svg with the anatomy isometric kit.
// Usage: node docs-src/hero.mjs [--kit /path/to/anatomy/kit/iso-kit.mjs] [--out docs/hero-iso.svg] [--theme dark|light]
import { writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : d; };
const KIT = arg("--kit", "/Users/sanan/Documents/Work/Gridcast/Ai builds/Gridcast front website/.claude/skills/anatomy/kit/iso-kit.mjs");
const OUT = resolve(arg("--out", join(HERE, "../docs/hero-iso.svg")));
const THEME = arg("--theme", "dark");
const k = await import(pathToFileURL(KIT).href);

const W = 1280, H = 640;
const PLATE = { x: -100, y: -275, w: 200, d: 570, r: 10 };
const PH = 10;

// sender laptop (back), receiver iMac (front); data flows along +y
const LBASE = { x: -70, y: -250, w: 110, d: 120, r: 6 };
const LSCR = { x: -74, y: -250, w: 5, d: 120, r: 2 };
const ENC = { x: -20, y: -104, w: 44, d: 44, r: 3 };
const DEC = { x: -20, y: 60, w: 44, d: 44, r: 3 };
const RIB = { x: -5, y: -58, w: 10, d: 118, r: 1 };
const IMAC = { x: -8, y: 118, w: 8, d: 156, r: 2 };
const IFOOT = { x: -22, y: 170, w: 50, d: 56, r: 6 };
const INECK = { x: -6, y: 188, w: 14, d: 20, r: 2 };
const IZ0 = 44, IZ1 = 134;

const pts = [
  ...k.boxCorners(PLATE, -PH, 0),
  [LSCR.x, LSCR.y, 90], [LSCR.x, LSCR.y + LSCR.d, 90], [IMAC.x, IMAC.y, IZ1 + 6], [IMAC.x, IMAC.y + IMAC.d, IZ1 + 6],
];
const P0 = k.fitProjection(pts, 780, 610, { pad: 16, azimuth: 42 });
const P = { ...P0, origin: [P0.origin[0] + 470, P0.origin[1] + 14] };

const at = (p) => k.iso(p, P);
const S = (paths, style) => k.solidSvg(paths, style);
const Ln = (d, style) => k.lineSvg(d, style);
const D = (points, style) => k.dotsSvg(points, style);
const mid = (r) => k.depthOf([r.x + r.w / 2, r.y + r.d / 2, 0], P);

function plate() {
  const o = [`<path class="iso-halo" d="${k.haloOf(PLATE, -PH, PH, P)}"/>`];
  o.push(S(k.slabOf(PLATE, -PH, PH, P, 8, 1.4), { tone: "mid" }));
  o.push(Ln(k.planOutline(k.insetPlan(PLATE, 6), 0, P), { tone: "lo" }));
  const scr = k.corners(PLATE, 12);
  o.push(Ln(scr.map(([x, y]) => k.ring(x, y, 2.4, 0, P, 16)).join(""), { tone: "lo" }));
  o.push(D(scr.map(([x, y]) => at([x, y, 0])), { size: 0.5 }));
  const ticks = k.topTicks(PLATE.y + 20, PLATE.y + PLATE.d - 20, 10, 5, PLATE.x + 10, 0, [2.2, 4.2], P, "y");
  o.push(Ln(ticks.minor, { tone: "faint" }), Ln(ticks.major, { tone: "lo" }));
  return o.join("");
}

function laptop() {
  const o = [];
  o.push(S(k.slabOf(LSCR, 6, 84, P, 4, 0.8), { tone: "mid" }));
  const fx = LSCR.x + LSCR.w;
  const win = (y, w, z, h, tone, lit) => S(k.slabOf({ x: fx - 0.2, y, w: 1.4, d: w, r: 0.8 }, z, h, P, 2), { tone, crease: "none", lit });
  o.push(S(k.slabOf({ x: fx - 0.4, y: LSCR.y + 7, w: 1.4, d: LSCR.d - 14, r: 1 }, 14, 66, P, 2), { tone: "lo", crease: "none" }));
  o.push(win(LSCR.y + 12, 50, 24, 48, "hi", true));
  o.push(win(LSCR.y + 68, 40, 46, 26, "mid"));
  o.push(win(LSCR.y + 68, 40, 20, 20, "mid"));
  o.push(win(LSCR.y + 12, 98, 17, 4, "mid"));
  o.push(S(k.slabOf(LBASE, 0, 6, P, 4, 0.9), { tone: "mid" }));
  o.push(D(k.dotGrid(LBASE.x + 24, LBASE.y + 10, 11, 4, 9.4, 6, P), { size: 0.9, tone: "lo" }));
  o.push(S(k.slabOf({ x: LBASE.x + 62, y: LBASE.y + 36, w: 34, d: 48, r: 2 }, 6, 0.5, P, 3), { tone: "lo", crease: "none" }));
  o.push(Ln(k.planOutline({ x: LBASE.x + 5, y: LBASE.y + 5, w: LBASE.w - 10, d: LBASE.d - 10, r: 3 }, 6, P, 3), { tone: "faint" }));
  o.push(S(k.slabOf({ x: LBASE.x + LBASE.w - 1, y: LBASE.y + LBASE.d - 22, w: 2, d: 10, r: 0.8 }, 1.4, 2.8, P, 2), { tone: "hi", crease: "none" }));
  return o.join("");
}

function chip(R, label) {
  const o = [];
  o.push(S(k.slabOf(R, 0, 8, P, 4, 0.8), { tone: "mid" }));
  const inner = { x: R.x + 9, y: R.y + 9, w: R.w - 18, d: R.d - 18, r: 2 };
  o.push(S(k.slabOf(inner, 8, 4, P, 3, 0.6), { tone: "hi", lit: true }));
  o.push(Ln(k.planOutline(k.insetPlan(inner, 4), 12, P, 3), { tone: "faint" }));
  const pins = [];
  for (let i = 0; i < 6; i++) {
    const t = R.y + 6 + i * ((R.d - 12) / 5);
    pins.push(k.lineOnTop([R.x - 3, t], [R.x, t], 8, P), k.lineOnTop([R.x + R.w, t], [R.x + R.w + 3, t], 8, P));
  }
  o.push(Ln(pins.join(""), { tone: "mid" }));
  o.push(k.faceTextSvg(k.topMatrix([R.x + 11, R.y + R.d / 2 + 2], 12, P, "x"), label, { size: 4.2, tone: "lo" }));
  return o.join("");
}

function ribbon() {
  const o = [];
  o.push(S(k.slabOf(RIB, 0, 1.6, P, 2), { tone: "lo", crease: "none" }));
  o.push(Ln(k.lineOnTop([RIB.x + RIB.w / 2, RIB.y + 2], [RIB.x + RIB.w / 2, RIB.y + RIB.d - 2], 1.6, P), { tone: "faint", dashed: true }));
  return o.join("");
}
const packet = (y) => S(k.slabOf({ x: -4.2, y, w: 8.4, d: 8, r: 1 }, 1.6, 4, P, 2), { tone: "hi", crease: "none", lit: true });
const FRAMES = [-52, -40, -28, -16, 14, 26, 38, 50];

function gate() {
  const o = [];
  const post = (x) => S(k.cylinder(x, 0, 5, 0, 42, P, 24, 0.5), { tone: "mid" });
  o.push(post(-24));
  o.push(S(k.slabOf({ x: -30, y: -6, w: 60, d: 12, r: 2 }, 42, 6, P, 3, 0.7), { tone: "hi", lit: true }));
  o.push(S(k.slabOf({ x: -8, y: -5, w: 16, d: 10, r: 2 }, 48, 13, P, 3, 0.6), { tone: "hi", lit: true }));
  o.push(Ln(k.sideRing([0, -5.2, 66], 5.5, "y", P, 24), { tone: "hi" }));
  o.push(D([at([0, -5.2, 54])], { size: 0.8, tone: "lo" }));
  o.push(post(24));
  return o.join("");
}

function imac() {
  const o = [];
  o.push(S(k.slabOf(IFOOT, 0, 4, P, 5, 0.8), { tone: "mid" }));
  o.push(S(k.slabOf(INECK, 4, IZ0 - 2, P, 3, 0.6), { tone: "mid" }));
  o.push(S(k.slabOf(IMAC, IZ0, IZ1 - IZ0, P, 4, 1), { tone: "mid" }));
  const fx = IMAC.x + IMAC.w;
  const pane = (y, w, z, h, tone, lit) => S(k.slabOf({ x: fx - 0.4, y, w: 1.4, d: w, r: 1 }, z, h, P, 2), { tone, crease: "none", lit });
  o.push(pane(IMAC.y + 7, IMAC.d - 14, IZ0 + 16, IZ1 - IZ0 - 22, "lo"));
  o.push(pane(IMAC.y + 14, 66, IZ0 + 24, 58, "hi", true));
  o.push(pane(IMAC.y + 86, 52, IZ0 + 54, 28, "mid"));
  o.push(pane(IMAC.y + 86, 52, IZ0 + 24, 24, "mid"));
  o.push(pane(IMAC.y + 14, IMAC.d - 28, IZ0 + 19, 3, "mid"));
  o.push(D([at([fx, IMAC.y + IMAC.d / 2, IZ0 + 8])], { size: 1.1, tone: "hi" }));
  return o.join("");
}

const draw = [];
draw.push({ depth: -1e9, html: plate() });
draw.push({ depth: -1e8, html: ribbon() });
const cableA = [[LBASE.x + LBASE.w + 1, LBASE.y + LBASE.d - 17, 2.2], [14, LBASE.y + LBASE.d - 17, 0.6], [ENC.x + ENC.w / 2, -112, 0.6], [ENC.x + ENC.w / 2, ENC.y, 4]].map(at);
const cableB = [[DEC.x + DEC.w / 2, DEC.y + DEC.d, 4], [DEC.x + DEC.w / 2, 112, 0.6], [IFOOT.x + 5, IFOOT.y + 6, 0.6], [IFOOT.x + 5, IFOOT.y + IFOOT.d / 2, 4]].map(at);
draw.push({ depth: -9e7, html: k.wireSvg(cableA[0], cableA.at(-1), { via: cableA.slice(1, -1), tone: "mid", size: 1.1 }) });
draw.push({ depth: -9e7, html: k.wireSvg(cableB[0], cableB.at(-1), { via: cableB.slice(1, -1), tone: "mid", size: 1.1 }) });
draw.push({ depth: mid(LBASE) - 0.5, html: laptop() });
draw.push({ depth: mid(ENC), html: chip(ENC, "ENC") });
draw.push({ depth: mid(DEC), html: chip(DEC, "DEC") });
for (const y of FRAMES) draw.push({ depth: k.depthOf([0, y + 3, 0], P), html: packet(y) });
draw.push({ depth: k.depthOf([0, 0, 0], P) + 0.2, html: gate() });
draw.push({ depth: mid(IFOOT) - 0.5, html: imac() });
draw.sort((a, b) => a.depth - b.depth);

const css = `
.t1{fill:var(--anatomy-hi);font:800 64px -apple-system,'SF Pro Display','Helvetica Neue',Arial,sans-serif;letter-spacing:-2px}
.t2{fill:var(--anatomy-hi);font:600 27px -apple-system,'SF Pro Display','Helvetica Neue',Arial,sans-serif}
.t3{fill:var(--anatomy-mid);font:400 18px -apple-system,'SF Pro Text','Helvetica Neue',Arial,sans-serif}
.cb{fill:var(--anatomy-hi);font:700 12px ui-monospace,'SF Mono',Menlo,monospace;letter-spacing:1.4px}
.cs{fill:var(--anatomy-mid);font:400 14px -apple-system,'SF Pro Text','Helvetica Neue',Arial,sans-serif}
.lead{fill:none;stroke:var(--anatomy-mid);stroke-width:1;stroke-dasharray:3 4}
.dot{fill:var(--anatomy-hi)}
.pill{fill:none;stroke:var(--anatomy-mid);stroke-width:1.2}
.pill-on{fill:var(--anatomy-hi)}
.pill-t{fill:var(--anatomy-paper);font:700 14px -apple-system,'SF Pro Text',Arial,sans-serif}
.pill-t2{fill:var(--anatomy-hi);font:600 14px -apple-system,'SF Pro Text',Arial,sans-serif}
.fig{fill:var(--anatomy-mid);font:600 12px ui-monospace,'SF Mono',Menlo,monospace;letter-spacing:1.5px}
`;
const callout = (label, sub, p3, dx, dy, anchor = "start") => {
  const from = at(p3);
  const to = [from[0] + dx, from[1] + dy];
  const x = anchor === "start" ? to[0] + 10 : to[0] - 10;
  return `<path class="lead" d="M${from[0].toFixed(1)} ${from[1].toFixed(1)}L${to[0].toFixed(1)} ${to[1].toFixed(1)}"/><circle class="dot" cx="${from[0].toFixed(1)}" cy="${from[1].toFixed(1)}" r="2.6"/>` +
    `<text class="cb" x="${x.toFixed(1)}" y="${(to[1] + 4).toFixed(1)}" text-anchor="${anchor}">${label}</text>` +
    `<text class="cs" x="${x.toFixed(1)}" y="${(to[1] + 22).toFixed(1)}" text-anchor="${anchor}">${sub}</text>`;
};
const CALL = [
  ["1  VIRTUAL DISPLAY", "a screen that exists only in software", [LSCR.x + 5, LSCR.y + 60, 76], -20, -36, "end"],
  ["2  ENCODE", "hardware H.264 or HEVC", [ENC.x + ENC.w, ENC.y + 10, 8], 40, 60],
  ["3  ENCRYPTED LINK", "AES-GCM over any link", [0, 0, 66], 70, 130],
  ["4  DECODE", "hardware, native pixels", [DEC.x, DEC.y + 20, 8], -70, 100, "end"],
  ["5  FULL SCREEN", "4096 × 2304 on a 2015 iMac 4K", [IMAC.x + IMAC.w, IMAC.y + 120, IZ1 - 10], 40, -110],
];
const calls = CALL.map((c) => callout(...c)).join("");

const left = `
<text class="t1" x="64" y="168">OpenAirDisplay</text>
<text class="t2" x="66" y="222">Use any old Mac as a 4K</text>
<text class="t2" x="66" y="256">external display.</text>
<text class="t3" x="66" y="306">iMac 2015+ · wired or wireless · native resolution</text>
<text class="t3" x="66" y="334">Free, open source, no account, no dongle. MCP ready.</text>
<g transform="translate(66 372)">
  <rect class="pill-on" width="96" height="34" rx="17"/><text class="pill-t" x="48" y="22" text-anchor="middle">macOS</text>
  <rect class="pill" x="108" width="372" height="34" rx="17"/><text class="pill-t2" x="294" y="22" text-anchor="middle">iPhone · iPad · Android · TV · Windows: soon</text>
</g>
<text class="fig" x="66" y="590">FIG 1 · HOW A FRAME TRAVELS FROM YOUR MAC TO AN OLD ONE</text>`;

const svg = k.figureSvg({
  width: W,
  height: H,
  standalone: THEME,
  label: "Isometric drawing: a laptop on the left creates a virtual display, encodes it, and sends frames through an encrypted gate along a link to a decoder, which shows them full screen on an old iMac. OpenAirDisplay lets an old Mac act as a 4K external display.",
  body: `<style>${css}</style><rect width="${W}" height="${H}" fill="var(--anatomy-paper)"/>` + left + draw.map((d) => d.html).join("") + calls,
});
writeFileSync(OUT, svg);
console.log("wrote", OUT, svg.length, "bytes");
