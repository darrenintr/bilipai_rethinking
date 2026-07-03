import { motion } from "motion/react";
import { CheckCircle } from "lucide-react";
import { PERFORMANCE_METRICS } from "../data";

/**
 * Static 3-column specs table — modeled on apple.com's
 * iPhone tech-specs page. Replaces the tabbed bar-chart
 * widget that lived here previously.
 *
 * Each row reads a single `PERFORMANCE_METRICS` entry: the
 * left column shows the metric label, the centre shows
 * Paladala's value at large display size, and the right
 * column shows the official Bilibili app's value as a small
 * "vs." comparison.
 */
export default function Metrics() {
  return (
    <section
      className="relative bg-[color:var(--color-bg-secondary)] text-[color:var(--color-text-primary)] border-b border-[color:var(--color-border-hairline)] scroll-mt-20"
      id="metrics"
      style={{ paddingTop: "clamp(80px, 12vw, 160px)", paddingBottom: "clamp(80px, 12vw, 160px)" }}
    >
      <div className="max-w-7xl mx-auto px-6">
        <div className="max-w-2xl mb-16">
          <p className="text-sm font-normal tracking-[0.02em] text-[color:var(--color-text-secondary)] mb-3">
            Benchmarks
          </p>
          <h2
            className="font-bold leading-[1.1] tracking-[-0.015em] mb-6"
            style={{ fontSize: "clamp(36px, 4.5vw, 56px)" }}
          >
            Native, not hybrid.
          </h2>
          <p
            className="text-[color:var(--color-text-secondary)]"
            style={{ fontSize: "clamp(17px, 1.4vw, 19px)", lineHeight: 1.5 }}
          >
            Hardware metrics comparing Paladala's compiled Swift binary against the official Bilibili app. Tested on identical iOS devices.
          </p>
        </div>

        <div
          className="grid grid-cols-1 md:grid-cols-3 bg-white border border-[color:var(--color-border-hairline)] rounded-[18px] overflow-hidden"
          style={{ padding: "clamp(32px, 4vw, 56px)" }}
        >
          {PERFORMANCE_METRICS.map((metric, idx) => (
            <motion.div
              key={metric.label}
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ duration: 0.5, delay: idx * 0.08 }}
              className={
                "flex flex-col items-center text-center " +
                (idx > 0 ? "md:border-l border-[color:var(--color-border-hairline)] " : "") +
                (idx > 0 ? "md:pl-8 " : "")
              }
            >
              <p className="text-sm font-normal tracking-[0.02em] text-[color:var(--color-text-secondary)] mb-4">
                {metric.label}
              </p>
              <p
                className="font-semibold text-[color:var(--color-text-primary)] tracking-[-0.015em] mb-3"
                style={{ fontSize: "clamp(40px, 5vw, 64px)", lineHeight: 1.05 }}
              >
                {metric.paladalaValue}
              </p>
              <p className="text-xs text-[color:var(--color-text-secondary)] tracking-wide">
                vs. {metric.officialValue} official
              </p>
              <p
                className="mt-2 text-xs font-medium"
                style={{ color: "var(--color-bili-pink)" }}
              >
                {metric.improvement}
              </p>
            </motion.div>
          ))}
        </div>

        {/* Footnotes row, Apple-style. */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mt-8 text-xs text-[color:var(--color-text-secondary)]" style={{ lineHeight: 1.5 }}>
          <div className="flex gap-2.5 items-start">
            <CheckCircle className="w-4 h-4 shrink-0 mt-0.5" style={{ color: "var(--color-bili-pink)" }} />
            <span>
              <strong className="text-[color:var(--color-text-primary)]">Swift Compilation:</strong> Direct arm64 machine code. No JavaScript engine overhead.
            </span>
          </div>
          <div className="flex gap-2.5 items-start">
            <CheckCircle className="w-4 h-4 shrink-0 mt-0.5" style={{ color: "var(--color-bili-pink)" }} />
            <span>
              <strong className="text-[color:var(--color-text-primary)]">Zero WebKit:</strong> No WKWebView caches, no uncollected media assets.
            </span>
          </div>
        </div>

        {/* Stat callouts — factual, no mono labels, no pink. */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-6 mt-16">
          {[
            { value: "100%", title: "Swift Concurrency", desc: "async/await throughout. Thread-safe Actor-isolated API client and proxy server." },
            { value: "41", title: "Swift Source Files", desc: "13,784 lines across app shell, features, player, data, design system, and infrastructure." },
            { value: "2", title: "Design Languages", desc: "Material 3 and Liquid Glass modes with instant runtime switching. No restart needed." },
          ].map((stat) => (
            <div
              key={stat.title}
              className="bg-white rounded-[18px] border border-[color:var(--color-border-hairline)]"
              style={{ padding: "32px" }}
            >
              <p
                className="font-semibold text-[color:var(--color-text-primary)] tracking-[-0.015em] mb-2"
                style={{ fontSize: "40px", lineHeight: 1.05 }}
              >
                {stat.value}
              </p>
              <p
                className="font-medium text-[color:var(--color-text-primary)] mb-2"
                style={{ fontSize: "15px" }}
              >
                {stat.title}
              </p>
              <p className="text-xs text-[color:var(--color-text-secondary)]" style={{ lineHeight: 1.5 }}>
                {stat.desc}
              </p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}