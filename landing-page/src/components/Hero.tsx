import { useEffect, useRef } from "react";
import { motion, useReducedMotion } from "motion/react";
import { Github, ArrowRight, BookOpen } from "lucide-react";

export default function Hero() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const prefersReducedMotion = useReducedMotion();

  // Light hero background — apple.com-style near-white surface
  // overlaid with a pre-rendered ffmpeg drawtext loop of pink
  // Swift snippets drifting left→right. The mod()-wrapped x
  // expression makes the loop seamless; snippets sit at 6–13%
  // opacity on a white canvas so they're felt, not read. When
  // prefers-reduced-motion is set, the video stays parked on
  // its poster frame and never plays.
  useEffect(() => {
    if (prefersReducedMotion) return;
    if (videoRef.current) {
      videoRef.current.play().catch(() => {});
    }
  }, [prefersReducedMotion]);

  return (
    <section
      className="relative w-full min-h-screen flex items-center justify-center overflow-hidden bg-white text-[color:var(--color-text-primary)] pt-24 pb-24 scroll-mt-20"
      id="hero"
    >
      {/* Ambient code-rain backdrop, full-bleed. object-cover keeps
          the field populated regardless of viewport aspect — the
          snippet density (24 snippets across 1920×1080) means even
          a portrait crop retains ~10 visible streams. The section's
          own bg-white shows through any seams so the background
          reads as continuous surface, not a tacked-on video. */}
      <video
        ref={videoRef}
        autoPlay={!prefersReducedMotion}
        loop
        muted
        playsInline
        preload="auto"
        poster="/hero-bg-poster.jpg"
        aria-hidden="true"
        className="absolute inset-0 w-full h-full object-cover z-0 pointer-events-none select-none"
        src="/hero-bg.mp4"
      />

      {/* Brand-tinted bottom wash so the hero stays light while
          carrying a hint of identity. Sits on top of the video so
          the wash itself never gets overdrawn by drifting snippets. */}
      <div className="absolute inset-x-0 bottom-0 h-32 bg-gradient-to-t from-[color:var(--color-bg-secondary)] to-transparent z-[1] pointer-events-none" />

      <div className="relative z-10 w-full max-w-5xl mx-auto px-6 text-center flex flex-col items-center">
        <motion.p
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.1, duration: 0.6 }}
          className="text-sm font-normal tracking-[0.02em] text-[color:var(--color-text-secondary)] mb-6"
        >
          Paladala — Pure Swift Bilibili Client
        </motion.p>

        <motion.h1
          initial={{ opacity: 0, y: 25 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2, duration: 0.8, ease: [0.4, 0, 0.2, 1] }}
          className="font-bold text-[color:var(--color-text-primary)] mb-6 select-none leading-[1.05] tracking-[-0.022em]"
          style={{ fontSize: "clamp(48px, 7.5vw, 96px)" }}
        >
          Reinventing Bilibili,
          <br />
          in Pure Swift.
        </motion.h1>

        <motion.p
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.3, duration: 0.8 }}
          className="max-w-2xl text-[color:var(--color-text-secondary)] tracking-[-0.005em] leading-[1.4] mb-12 text-center"
          style={{ fontSize: "clamp(19px, 1.6vw, 24px)" }}
        >
          Paladala is a ground-up native Swift rewrite of the Bilibili iOS client.
          No webviews, no bloat. Local HLS proxy, dual design language, and
          AVKit-powered playback.
        </motion.p>

        <motion.div
          initial={{ opacity: 0, y: 15 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.4, duration: 0.6 }}
          className="flex flex-col sm:flex-row items-center justify-center gap-6 w-full sm:w-auto"
        >
          <a
            href="https://github.com/darrenintr/pure-bilibili-rethinking"
            target="_blank"
            rel="noopener noreferrer"
            className="apple-pill inline-flex items-center justify-center gap-2 cursor-pointer"
            style={{ padding: "12px 22px" }}
          >
            <Github className="w-4 h-4" />
            <span>View on GitHub</span>
          </a>
          <a
            href="#features"
            onClick={(e) => {
              e.preventDefault();
              document.getElementById("features")?.scrollIntoView({ behavior: "smooth" });
            }}
            className="apple-link inline-flex items-center gap-1 cursor-pointer"
          >
            <span>Learn more</span>
            <ArrowRight className="w-4 h-4" />
          </a>
        </motion.div>

        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.8 }}
          className="mt-16 text-center"
        >
          <div
            className="inline-flex items-center gap-2 px-3 py-1.5 rounded-lg text-[13px]"
            style={{
              background: "var(--color-bg-secondary)",
              border: "1px solid var(--color-border-hairline)",
              color: "var(--color-text-primary)",
            }}
          >
            <BookOpen className="w-3.5 h-3.5 text-[color:var(--color-text-secondary)]" />
            <span>41 Swift files · 13,784 LOC · Zero dependencies</span>
          </div>
        </motion.div>
      </div>

      {/* Original placeholder asset (hero.mp4) kept around as the
          future-asset slot for the sticky-shrink hero pattern. Loaded
          silently when present, never displayed. */}
      <video
        autoPlay
        loop
        muted
        playsInline
        className="hidden"
        src="/hero.mp4"
      />
    </section>
  );
}
