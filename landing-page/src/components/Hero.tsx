import { useState, useEffect, useRef } from "react";
import { motion } from "motion/react";
import { Github, ArrowRight } from "lucide-react";

export default function Hero() {
  const [videoError, setVideoError] = useState(false);
  const [videoLoaded, setVideoLoaded] = useState(false);
  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (videoRef.current) {
      videoRef.current.play().catch(() => {});
    }
  }, []);

  useEffect(() => {
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
      "class PlayerController",
      "func fetchRecommendations() async",
      "struct VideoDetailView",
      "let proxy = LocalHLSProxyServer()",
      "PaladalaTheme.paladalaPink",
      "AVPlayer(url: streamURL)",
      "struct MiniPlayerOverlay",
      "enum ThemeMode: String",
      "BilibiliAPIClient.shared",
      "func paladalaCardSurface()",
      "let haptic = Haptics.tap()",
      "struct VideoCard: View",
      "class AuthStore: ObservableObject",
      "func openVideo(_ video: BiliVideo)",
      "struct RootView: View",
    ];

    interface Stream {
      x: number;
      y: number;
      speed: number;
      text: string;
      fontSize: number;
      opacity: number;
      waveOffset: number;
      waveSpeed: number;
      waveAmplitude: number;
    }

    const streams: Stream[] = [];
    for (let i = 0; i < 20; i++) {
      streams.push({
        x: Math.random() * 1000 - 200,
        y: Math.random() * 350 + 80,
        speed: 0.5 + Math.random() * 1.2,
        text: swiftSnippets[Math.floor(Math.random() * swiftSnippets.length)],
        fontSize: Math.floor(Math.random() * 5) + 11,
        opacity: 0.15 + Math.random() * 0.4,
        waveOffset: Math.random() * Math.PI * 2,
        waveSpeed: 0.005 + Math.random() * 0.012,
        waveAmplitude: 15 + Math.random() * 20,
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
        s.waveOffset += s.waveSpeed;
        const currentY = s.y + Math.sin(s.waveOffset) * s.waveAmplitude;

        if (s.x > width + 150) {
          s.x = -150 - Math.random() * 200;
          s.y = Math.random() * (height - 200) + 50;
          s.text = swiftSnippets[Math.floor(Math.random() * swiftSnippets.length)];
          s.opacity = 0.15 + Math.random() * 0.4;
        }

        ctx.save();
        ctx.font = `650 ${s.fontSize}px "JetBrains Mono", monospace`;
        ctx.fillStyle = `rgba(251, 114, 153, ${s.opacity})`;
        ctx.shadowColor = "#FB7299";
        ctx.shadowBlur = 8;
        ctx.fillText(s.text, s.x, currentY);
        ctx.restore();
      });

      const chipX = width / 2;
      const chipY = height * 0.78;

      ctx.save();
      ctx.lineWidth = 1.2;

      for (let i = -400; i <= 400; i += 80) {
        const xStart = chipX + i;
        const yStart = height;
        const xCorner = chipX + i * 0.45;
        const yCorner = chipY + (height - chipY) * 0.5;

        ctx.strokeStyle = "rgba(251, 114, 153, 0.05)";
        ctx.beginPath();
        ctx.moveTo(xStart, yStart);
        ctx.lineTo(xCorner, yCorner);
        ctx.lineTo(chipX + i * 0.04, chipY + 15);
        ctx.stroke();

        const pulseTime = (Date.now() * 0.0008 * (0.6 + Math.abs(i) * 0.0004)) % 1;
        ctx.strokeStyle = "rgba(239, 68, 68, 0.45)";
        ctx.shadowColor = "#EF4444";
        ctx.shadowBlur = 6;
        ctx.beginPath();

        const segment1 = 0.65;
        if (pulseTime < segment1) {
          const t = pulseTime / segment1;
          const cx = xStart + (xCorner - xStart) * t;
          const cy = yStart + (yCorner - yStart) * t;
          ctx.moveTo(
            xStart + (xCorner - xStart) * Math.max(0, t - 0.12),
            yStart + (yCorner - yStart) * Math.max(0, t - 0.12),
          );
          ctx.lineTo(cx, cy);
        } else {
          const t = (pulseTime - segment1) / (1 - segment1);
          const cx = xCorner + (chipX + i * 0.04 - xCorner) * t;
          const cy = yCorner + (chipY + 15 - yCorner) * t;
          ctx.moveTo(
            xCorner + (chipX + i * 0.04 - xCorner) * Math.max(0, t - 0.12),
            yCorner + (chipY + 15 - yCorner) * Math.max(0, t - 0.12),
          );
          ctx.lineTo(cx, cy);
        }
        ctx.stroke();
      }

      const pulseVal = Math.abs(Math.sin(Date.now() * 0.002));
      ctx.shadowColor = "#FB7299";
      ctx.shadowBlur = 12;
      ctx.fillStyle = "rgba(18, 12, 22, 0.9)";
      ctx.strokeStyle = `rgba(251, 114, 153, ${0.35 + pulseVal * 0.35})`;
      ctx.lineWidth = 2.5;

      const chipSize = 54;
      ctx.beginPath();
      ctx.rect(chipX - chipSize / 2, chipY - chipSize / 2, chipSize, chipSize);
      ctx.fill();
      ctx.stroke();

      ctx.fillStyle = `rgba(239, 68, 68, ${0.3 + pulseVal * 0.5})`;
      ctx.shadowColor = "#EF4444";
      ctx.shadowBlur = 8;
      ctx.beginPath();
      ctx.arc(chipX, chipY, 12, 0, Math.PI * 2);
      ctx.fill();

      ctx.restore();

      animationFrameId = requestAnimationFrame(tick);
    };

    tick();

    return () => {
      cancelAnimationFrame(animationFrameId);
      resizeObserver.disconnect();
    };
  }, []);

  return (
    <section
      className="relative w-full min-h-screen flex items-center justify-center overflow-hidden bg-gray-950 text-white pt-20"
      id="hero"
    >
      <video
        ref={videoRef}
        autoPlay
        loop
        muted
        playsInline
        onError={() => setVideoError(true)}
        onCanPlay={() => setVideoLoaded(true)}
        className={`absolute inset-0 w-full h-full object-cover transition-opacity duration-1000 z-0 ${
          videoLoaded && !videoError ? "opacity-35" : "opacity-0"
        }`}
        src="/hero.mp4"
      />

      {(!videoLoaded || videoError) && (
        <div ref={containerRef} className="absolute inset-0 z-0 overflow-hidden bg-gray-950">
          <canvas ref={canvasRef} className="absolute inset-0 w-full h-full block opacity-65" />
          <div className="absolute inset-0 bg-gradient-to-t from-gray-950 via-gray-950/20 to-transparent" />
        </div>
      )}

      <div className="absolute inset-0 bg-gradient-to-b from-gray-950/40 via-gray-950/70 to-gray-950 z-1" />

      <div className="relative z-10 w-full max-w-5xl mx-auto px-6 py-20 text-center flex flex-col items-center">
        <motion.p
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.1, duration: 0.6 }}
          className="font-mono text-xs font-bold tracking-[0.4em] uppercase text-bili-pink mb-4"
        >
          PALADALA NATIVE CLIENT
        </motion.p>

        <motion.h1
          initial={{ opacity: 0, y: 25 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2, duration: 0.8, ease: "easeOut" }}
          className="font-black text-4xl sm:text-6xl lg:text-7xl leading-[1.05] tracking-tight text-white mb-6 select-none"
        >
          Reinventing Bilibili <br />
          <span className="text-transparent bg-clip-text bg-gradient-to-r from-bili-pink via-white to-bili-blue text-glow-bili">
            in Pure Swift
          </span>
        </motion.h1>

        <motion.p
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.3, duration: 0.8 }}
          className="max-w-3xl text-gray-300 text-base sm:text-lg md:text-xl tracking-normal leading-relaxed mb-12 text-center"
        >
          Paladala is a ground-up native Swift rewrite of the Bilibili iOS client.
          No webviews, no bloat. Local HLS proxy, dual design language (Material 3 & Liquid Glass),
          AVKit-powered player with Picture-in-Picture, and 13,784 lines of pure Swift.
        </motion.p>

        <motion.div
          initial={{ opacity: 0, scale: 0.95 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ delay: 0.4, duration: 0.6 }}
          className="flex flex-col sm:flex-row items-center justify-center gap-4 w-full sm:w-auto"
        >
          <a
            href="https://github.com/darrenintr/pure-bilibili-rethinking"
            target="_blank"
            rel="noopener noreferrer"
            className="group relative w-full sm:w-auto inline-flex items-center justify-center gap-2.5 px-8 py-4 rounded-xl bg-bili-pink text-white font-bold tracking-wide shadow-lg shadow-bili-pink/30 hover:bg-bili-pink-hover hover:scale-[1.02] active:scale-[0.98] transition-all duration-300 cursor-pointer text-center"
          >
            <Github className="w-5 h-5" />
            <span>View on GitHub</span>
            <ArrowRight className="w-4 h-4 group-hover:translate-x-1.5 transition-transform duration-300" />
            <div className="absolute -inset-1 rounded-xl bg-gradient-to-r from-bili-pink to-bili-blue opacity-0 group-hover:opacity-20 blur-md transition-opacity duration-500 -z-1" />
          </a>
        </motion.div>

        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.8 }}
          className="mt-16 text-center"
        >
          <div className="inline-flex items-center gap-1 text-[11px] font-mono text-gray-500 bg-white/5 border border-white/5 px-3 py-1.5 rounded-md">
            <span className="w-1.5 h-1.5 rounded-full bg-green-500" />
            <span>41 Swift files &middot; 13,784 LOC &middot; Zero dependencies</span>
          </div>
        </motion.div>
      </div>

      <div className="absolute bottom-0 left-0 w-full h-16 bg-gradient-to-t from-gray-900 to-transparent z-1" />
    </section>
  );
}
