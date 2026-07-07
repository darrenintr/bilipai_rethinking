#!/usr/bin/env node
// Renders a seamless-looping ambient code-rain background video
// for the Paladala landing page Hero. The output is white-bg,
// low-opacity, pink-tinted Swift snippets drifting left→right.
//
// We avoid the 200-line ffmpeg filtergraph shell escape and just
// generate the drawtext chain programmatically. Each stream has a
// deterministic x-seed and speed; the x expression uses ffmpeg's
// mod() function so every stream wraps cleanly within one loop,
// making the video perfectly seamless without crossfade or fade.
//
// Usage:  node scripts/render-hero-bg.mjs
// Output: public/hero-bg.mp4
//
// Knobs at the top: WIDTH, HEIGHT, DURATION, FPS, STREAMS, SPEED_MIN/MAX,
// FONT_PATH, FONT_SIZE_MIN/MAX, OPACITY_MIN/MAX. Edit and re-run.

import { spawnSync } from "node:child_process";
import { mkdirSync, existsSync, statSync, unlinkSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT = resolve(__dirname, "..");
const OUT = resolve(PROJECT, "public", "hero-bg.mp4");

// --- visual knobs ---------------------------------------------------------

const WIDTH = 1920;
const HEIGHT = 1080;
const DURATION = 8.0; // seconds
const FPS = 30;
const STREAMS = 24;
// With the mod() wraparound each stream is on-screen for
// roughly WIDTH/speed seconds. Speeds in [140, 280] px/s
// give 6.9–13.7s screen-cross time, so visibility per loop
// is ~58–116% (effective ~85% on average). That keeps the
// field populated without ever feeling busy.
const SPEED_MIN = 140;
const SPEED_MAX = 280;
const FONT_SIZE_MIN = 16;
const FONT_SIZE_MAX = 24;
const OPACITY_MIN = 0.06;
const OPACITY_MAX = 0.13;
const PINK = "0xFB7299"; // brand pink

// Seamless-loop trick: each stream's x is computed by the
// ffmpeg expression evaluator as
//
//     x = mod(xStart + speed*t, WIDTH) - WIDTH
//
// (mod is the ffmpeg built-in mod() function, not a JS one).
// Because the snippet always lives at one of WIDTH discrete
// x-offsets per loop, its position at t=DURATION equals its
// position at t=0, so the video loops cleanly with no flash,
// no crossfade, and no visible seam. xStart is chosen in
// [-WIDTH, 0] so the snippet starts off-screen left and
// enters from the left edge of the frame.

const SWIFT_SNIPPETS = [
  "import SwiftUI",
  "import AVKit",
  "import AVFoundation",
  "struct VideoDetailView",
  "LocalHLSProxyServer()",
  "AVPlayer(url: streamURL)",
  "struct MiniPlayerOverlay",
  "BilibiliAPIClient.shared",
  "let haptic = Haptics.tap()",
  "struct VideoCard: View",
  "class AuthStore",
  "struct RootView: View",
  "@Published private(set) var",
  ".ultraThinMaterial",
  "func prewarmProxyServer()",
  "PlayerController()",
];

// --- font discovery -------------------------------------------------------

const FONT_CANDIDATES = [
  "/usr/share/fonts/TTF/CaskaydiaCoveNerdFontMono-Regular.ttf",
  "/usr/share/fonts/TTF/JetBrainsMonoNLNerdFontPropo-Regular.ttf",
  "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
];
const FONT_PATH = FONT_CANDIDATES.find((p) => existsSync(p));
if (!FONT_PATH) {
  console.error("No monospaced TTF found. Tried:\n  " + FONT_CANDIDATES.join("\n  "));
  process.exit(1);
}
console.log("font:", FONT_PATH);

// --- deterministic PRNG so re-runs are identical --------------------------

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rng = mulberry32(0xC0DEFA17);

// --- escape a snippet for the drawtext text= argument --------------------

function escapeForDrawtext(s) {
  // Order matters: backslashes first, then colons (drawtext option
  // separator), then single quotes (drawtext text= delimiter), then
  // %, which is the drawtext expansion char.
  return s
    .replace(/\\/g, "\\\\")
    .replace(/:/g, "\\:")
    .replace(/'/g, "\\'")
    .replace(/%/g, "\\%");
}

// --- build streams --------------------------------------------------------

const streams = [];
for (let i = 0; i < STREAMS; i++) {
  // Start each stream off-screen to the left, distributed across
  // one full screen-width so the field looks populated from t=0.
  // xStart is in [-WIDTH, 0] so the mod() expression lands the
  // snippet cleanly on the canvas without a one-frame flash.
  const speed = SPEED_MIN + rng() * (SPEED_MAX - SPEED_MIN);
  const xStart = -WIDTH + rng() * WIDTH;
  const yStart = 40 + rng() * (HEIGHT - 80);
  const fontSize = Math.floor(FONT_SIZE_MIN + rng() * (FONT_SIZE_MAX - FONT_SIZE_MIN));
  const opacity = OPACITY_MIN + rng() * (OPACITY_MAX - OPACITY_MIN);
  const snippet = SWIFT_SNIPPETS[Math.floor(rng() * SWIFT_SNIPPETS.length)];
  streams.push({ i, speed, xStart, yStart, fontSize, opacity, snippet });
}

// --- build drawtext filter graph -----------------------------------------

// Each drawtext is a sliding text. x moves linearly with t.
// Alpha is encoded into the fill color's alpha channel via the
// color string format color@0xAA where AA is hex alpha (00..FF).
const drawtexts = streams
  .map((s) => {
    const alphaHex = Math.round(s.opacity * 255)
      .toString(16)
      .padStart(2, "0");
    const color = `${PINK}@0x${alphaHex}`;
    const text = escapeForDrawtext(s.snippet);
    return [
      `drawtext=fontfile=${FONT_PATH}`,
      `text='${text}'`,
      `fontsize=${s.fontSize}`,
      `fontcolor=${color}`,
      // x: wrap-around linear slide. mod() makes the snippet
      // re-enter from the left once it exits right; the -WIDTH
      // offset keeps the position math non-negative inside the
      // expression evaluator. Because x wraps cleanly over a
      // fixed WIDTH interval, the loop seam is invisible.
      `x='mod(${s.xStart.toFixed(2)}+${s.speed.toFixed(2)}*t\\,${WIDTH})-${WIDTH}'`,
      `y=${s.yStart.toFixed(2)}`,
    ].join(":");
  })
  .join(",");

// --- compose final ffmpeg args -------------------------------------------

// Render to MP4 (H.264 yuv420p so it plays in <video> everywhere).
// -movflags +faststart puts the moov atom at the start so the
// browser can start playing without a full download.
const args = [
  "-y",
  "-f", "lavfi",
  "-i", `color=c=white:s=${WIDTH}x${HEIGHT}:r=${FPS}:d=${DURATION}`,
  "-vf", drawtexts,
  "-c:v", "libx264",
  "-pix_fmt", "yuv420p",
  "-profile:v", "high",
  "-preset", "medium",
  "-crf", "26",             // visually clean, small file
  "-movflags", "+faststart",
  "-an",
  OUT,
];

// Sanity: size estimate
const est = Math.round(WIDTH * HEIGHT * DURATION * FPS * 0.07 / 1024 / 1024);
console.log(`target: ${OUT}`);
console.log(`size estimate: ~${est} MB`);

if (existsSync(OUT)) {
  const prev = statSync(OUT).size;
  console.log(`(overwrites existing ${(prev / 1024 / 1024).toFixed(2)} MB file)`);
  unlinkSync(OUT);
}

const t0 = Date.now();
const result = spawnSync("ffmpeg", args, { stdio: "inherit" });
if (result.status !== 0) {
  console.error(`ffmpeg exited with code ${result.status}`);
  process.exit(result.status ?? 1);
}
const dt = ((Date.now() - t0) / 1000).toFixed(1);
const finalSize = statSync(OUT).size;
console.log(`done in ${dt}s → ${(finalSize / 1024 / 1024).toFixed(2)} MB`);
