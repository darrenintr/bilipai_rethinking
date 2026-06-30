import { useState, useEffect } from "react";
import { motion, AnimatePresence } from "motion/react";
import { CheckCircle, Flame, Shield, TrendingDown } from "lucide-react";
import { PERFORMANCE_METRICS } from "../data";

export default function Metrics() {
  const [activeTab, setActiveTab] = useState<"bundle" | "memory" | "startup">("bundle");
  const [simulatedRamSaved, setSimulatedRamSaved] = useState(486);

  useEffect(() => {
    const interval = setInterval(() => {
      setSimulatedRamSaved((prev) => {
        const delta = (Math.random() - 0.5) * 2;
        return parseFloat((486 + delta).toFixed(1));
      });
    }, 2500);
    return () => clearInterval(interval);
  }, []);

  const getMetricIndex = () => {
    switch (activeTab) {
      case "bundle": return 0;
      case "memory": return 1;
      case "startup": return 2;
      default: return 0;
    }
  };

  const selectedMetric = PERFORMANCE_METRICS[getMetricIndex()];

  return (
    <section
      className="relative py-24 md:py-32 bg-gray-50 text-gray-900 border-b border-gray-150 scroll-mt-20"
      id="metrics"
    >
      <div className="max-w-7xl mx-auto px-6">
        <div className="flex flex-col lg:flex-row lg:items-end justify-between mb-16 gap-6">
          <div className="max-w-2xl">
            <span className="font-mono text-xs font-bold tracking-[0.25em] text-bili-pink uppercase block mb-3">
              Benchmarks
            </span>
            <h2 className="font-black text-3xl sm:text-5xl tracking-tight text-gray-950">
              Native vs. Hybrid
            </h2>
            <p className="mt-4 text-gray-500 text-base md:text-lg">
              Hardware metrics comparing Paladala's compiled Swift binary against the official Bilibili app. Tested on identical iOS devices.
            </p>
          </div>

          <motion.div
            layout
            className="inline-flex flex-col items-start lg:items-end bg-white border border-bili-pink/20 hover:border-bili-pink/40 p-4 rounded-xl shadow-sm"
          >
            <div className="flex items-center gap-2 mb-1">
              <span className="flex h-1.5 w-1.5 rounded-full bg-green-500 animate-pulse" />
              <span className="text-[10px] font-mono uppercase font-bold text-gray-400">
                Live Savings
              </span>
            </div>
            <div className="font-black text-2xl text-bili-pink tabular-nums">
              {simulatedRamSaved} MB
            </div>
            <span className="text-[10px] text-gray-600 tracking-wide">
              RAM Overhead Reduced
            </span>
          </motion.div>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-12 gap-8 items-start">
          <div className="lg:col-span-4 flex flex-col gap-3">
            <span className="text-[10px] uppercase font-mono tracking-widest text-gray-400 font-bold ml-1 mb-1">
              Metrics
            </span>

            {[
              { key: "bundle" as const, label: "App Package Size", desc: "Compiled binary weight", icon: Shield },
              { key: "memory" as const, label: "Memory Footprint", desc: "RAM usage during playback", icon: TrendingDown },
              { key: "startup" as const, label: "Cold Boot Speed", desc: "Launch to video viewport", icon: Flame },
            ].map(({ key, label, desc, icon: Icon }) => (
              <button
                key={key}
                onClick={() => setActiveTab(key)}
                className={`w-full text-left p-4 rounded-xl border transition-all duration-300 flex items-start justify-between ${
                  activeTab === key
                    ? "bg-white border-bili-pink text-gray-900 shadow-md"
                    : "bg-transparent border-gray-200 hover:border-bili-pink/30 text-gray-600 hover:bg-white"
                }`}
              >
                <div>
                  <span className="font-bold text-md block">{label}</span>
                  <span className="text-xs text-gray-400">{desc}</span>
                </div>
                <Icon className={`w-4 h-4 mt-0.5 ${activeTab === key ? "text-bili-pink" : "text-gray-450"}`} />
              </button>
            ))}
          </div>

          <div className="lg:col-span-8 bg-white border border-gray-150 rounded-2xl p-6 sm:p-8 shadow-sm">
            <AnimatePresence mode="wait">
              <motion.div
                key={activeTab}
                initial={{ opacity: 0, x: 10 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: -10 }}
                transition={{ duration: 0.3 }}
                className="space-y-8"
              >
                <div className="flex items-center justify-between border-b border-gray-100 pb-5">
                  <div>
                    <span className="text-[10px] font-mono font-bold text-bili-pink uppercase">
                      Selected Metric
                    </span>
                    <h3 className="font-extrabold text-2xl text-gray-950 mt-1">
                      {selectedMetric.label}
                    </h3>
                  </div>
                  <div className="text-right">
                    <span className="text-xs text-gray-400 block">Improvement</span>
                    <span className="font-black text-bili-pink text-xl sm:text-2xl">
                      {selectedMetric.improvement}
                    </span>
                  </div>
                </div>

                <div className="space-y-6">
                  <div className="space-y-2">
                    <div className="flex justify-between items-end">
                      <div className="flex items-center gap-2">
                        <span className="font-mono text-xs font-black px-1.5 py-0.5 rounded bg-bili-pink text-white">
                          PALADALA
                        </span>
                        <span className="font-extrabold text-sm text-gray-800">Swift Native Core</span>
                      </div>
                      <span className="font-mono font-bold text-bili-pink text-base">
                        {selectedMetric.paladalaValue}
                      </span>
                    </div>
                    <div className="w-full h-8 bg-gray-50 rounded-lg overflow-hidden border border-gray-100 flex items-center px-1">
                      <motion.div
                        initial={{ width: 0 }}
                        animate={{ width: "8%" }}
                        transition={{ duration: 0.8, ease: "easeOut" }}
                        className="h-6 rounded bg-bili-pink shadow-md relative group flex items-center justify-end pr-2 overflow-hidden"
                      >
                        <span className="text-[9px] font-mono text-white font-bold opacity-0 group-hover:opacity-100 transition-opacity">
                          Optimized
                        </span>
                        <div className="absolute top-0 left-0 w-32 h-full bg-gradient-to-r from-white/10 to-transparent" />
                      </motion.div>
                    </div>
                  </div>

                  <div className="space-y-2">
                    <div className="flex justify-between items-end">
                      <div className="flex items-center gap-2">
                        <span className="font-mono text-xs font-bold px-1.5 py-0.5 rounded bg-gray-150 text-gray-500">
                          OFFICIAL
                        </span>
                        <span className="font-medium text-sm text-gray-500">Standard Bilibili App</span>
                      </div>
                      <span className="font-mono font-bold text-gray-500 text-base">
                        {selectedMetric.officialValue}
                      </span>
                    </div>
                    <div className="w-full h-8 bg-gray-50 rounded-lg overflow-hidden border border-gray-100 flex items-center px-1">
                      <motion.div
                        initial={{ width: 0 }}
                        animate={{ width: "95%" }}
                        transition={{ duration: 1.0, ease: "easeOut" }}
                        className="h-6 rounded bg-gray-400 group relative flex items-center justify-end pr-3 overflow-hidden"
                      >
                        <span className="text-[9px] font-mono text-white font-bold tracking-wider">
                          Overhead
                        </span>
                      </motion.div>
                    </div>
                  </div>
                </div>

                <div className="grid grid-cols-1 md:grid-cols-2 gap-4 pt-6 border-t border-gray-100 text-xs text-gray-500 leading-relaxed">
                  <div className="flex gap-2.5 items-start">
                    <CheckCircle className="w-4 h-4 text-bili-pink shrink-0 mt-0.5" />
                    <span>
                      <strong>Swift Compilation:</strong> Direct arm64 machine code. No JavaScript engine overhead.
                    </span>
                  </div>
                  <div className="flex gap-2.5 items-start">
                    <CheckCircle className="w-4 h-4 text-bili-pink shrink-0 mt-0.5" />
                    <span>
                      <strong>Zero WebKit:</strong> No WKWebView caches, no uncollected media assets.
                    </span>
                  </div>
                </div>
              </motion.div>
            </AnimatePresence>
          </div>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6 mt-16">
          <div className="bg-white border border-gray-150 p-6 rounded-xl relative overflow-hidden">
            <h4 className="font-extrabold text-3xl text-gray-900 mb-1">100%</h4>
            <p className="font-mono text-[10px] text-bili-pink uppercase tracking-widest font-bold mb-2">
              Swift Concurrency
            </p>
            <p className="text-xs text-gray-500 leading-relaxed">
              async/await throughout. Thread-safe Actor-isolated API client and proxy server.
            </p>
          </div>
          <div className="bg-white border border-gray-150 p-6 rounded-xl relative overflow-hidden">
            <h4 className="font-extrabold text-3xl text-gray-900 mb-1">41</h4>
            <p className="font-mono text-[10px] text-bili-pink uppercase tracking-widest font-bold mb-2">
              Swift Source Files
            </p>
            <p className="text-xs text-gray-500 leading-relaxed">
              13,784 lines across app shell, features, player, data, design system, and infrastructure.
            </p>
          </div>
          <div className="bg-white border border-gray-150 p-6 rounded-xl relative overflow-hidden">
            <h4 className="font-extrabold text-3xl text-gray-900 mb-1">2</h4>
            <p className="font-mono text-[10px] text-bili-pink uppercase tracking-widest font-bold mb-2">
              Design Languages
            </p>
            <p className="text-xs text-gray-500 leading-relaxed">
              Material 3 and Liquid Glass modes with instant runtime switching. No restart needed.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
