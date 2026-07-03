import { useEffect, useRef } from "react";
import { motion, useReducedMotion } from "motion/react";
import { Github, ArrowRight, BookOpen } from "lucide-react";

export default function Hero() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const prefersReducedMotion = useReducedMotion();

  // Light hero background — apple.com-style near-white surface
  // with a faint brand-tinted wash. The dark canvas code-rain
  // motif is demoted to a tiny ambient band so the headline
  // and product feel are the visual focus.
  useEffect(() => {
    if (videoRef.current) {
      videoRef.current.play().catch(() => {});
    }
  }, []);

  useEffect(() => {
    if (prefersReducedMotion) return;

    const canvas = canvasRef.current;
    const container = containerRef.current;
    if (!canvas || !container) return;

    let animationFrameId: number;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    let width = 0;
    let height = 0;

    const handleResize = (entries: ResizeObserverEntry[]) => {
      for (const entry of entries) {
        const { width: w, height: h } = entry.contentRect;
        width = w;
        height = h;
        canvas.width = w;
        canvas.height = h;
      }
    };

    const resizeObserver = new ResizeObserver((entries) => {
      requestAnimationFrame(() => handleResize(entries));
    });
    resizeObserver.observe(container);

    const swiftSnippets = [
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
    ];

    interface Stream {
      x: number;
      y: number;
      speed: number;
      text: string;
      fontSize: number;
      opacity: number;
    }

    // Far fewer streams + much lower opacity than before — the
    // code rain is now an ambient texture, not the visual focus.
    const streams: Stream[] = [];
    for (let i = 0; i < 8; i++) {
      streams.push({
        x: Math.random() * 1000 - 200,
        y: Math.random() * 200,
        speed: 0.2 + Math.random() * 0.4,
        text: swiftSnippets[Math.floor(Math.random() * swiftSnippets.length)],
        fontSize: Math.floor(Math.random() * 3) + 10,
        opacity: 0.04 + Math.random() * 0.06,
      });
    }

    const tick = () => {
      if (!ctx || width === 0 || height === 0) {
        animationFrameId = requestAnimationFrame(tick);
        return;
      }

      ctx.clearRect(0, 0, width, height);

      streams.forEach((s) => {
        s.x += s.speed;

        if (s.x > width + 150) {
          s.x = -150 - Math.random() * 200;
          s.y = Math.random() * height;
          s.text = swiftSnippets[Math.floor(Math.random() * swiftSnippets.length)];
          s.opacity = 0.04 + Math.random() * 0.06;
        }

        ctx.save();
        ctx.font = `500 ${s.fontSize}px ui-monospace, "SF Mono", Menlo, monospace`;
        ctx.fillStyle = `rgba(251, 114, 153, ${s.opacity})`;
        ctx.fillText(s.text, s.x, s.y);
        ctx.restore();
      });

      animationFrameId = requestAnimationFrame(tick);
    };

    tick();

    return () => {
      cancelAnimationFrame(animationFrameId);
      resizeObserver.disconnect();
    };
  }, [prefersReducedMotion]);

  return (
    <section
      className="relative w-full min-h-screen flex items-center justify-center overflow-hidden bg-white text-[color:var(--color-text-primary)] pt-24 pb-24 scroll-mt-20"
      id="hero"
    >
      {/* Ambient code-rain band, demoted to a thin strip with
          low opacity. Lives behind a wash so it never competes
          with the headline. */}
      <div
        ref={containerRef}
        className="absolute inset-x-0 top-20 h-40 z-0 overflow-hidden pointer-events-none"
      >
        <canvas ref={canvasRef} className="absolute inset-0 w-full h-full block" />
      </div>

      {/* Brand-tinted bottom wash so the hero stays light while
          carrying a hint of identity. */}
      <div className="absolute inset-x-0 bottom-0 h-32 bg-gradient-to-t from-[color:var(--color-bg-secondary)] to-transparent z-0 pointer-events-none" />

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

      {/* Hidden video element kept as a future asset slot for the
          sticky-shrink hero pattern. Loaded silently when present. */}
      <video
        ref={videoRef}
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