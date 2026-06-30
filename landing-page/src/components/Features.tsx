import { motion } from "motion/react";
import * as LucideIcons from "lucide-react";
import { FEATURES_LIST } from "../data";
import { FeatureCard } from "../types";

function DynamicIcon({ name, className }: { name: string; className?: string }) {
  const IconComponent = (LucideIcons as any)[name];
  if (!IconComponent) {
    return <LucideIcons.HelpCircle className={className} />;
  }
  return <IconComponent className={className} />;
}

export default function Features() {
  return (
    <section
      className="relative py-24 md:py-32 bg-white text-gray-900 overflow-hidden bg-grid-pattern-light border-y border-gray-100 scroll-mt-20"
      id="features"
    >
      <div className="absolute inset-x-0 top-0 h-40 bg-gradient-to-b from-gray-50/50 to-transparent pointer-events-none" />

      <div className="max-w-7xl mx-auto px-6 relative z-10">
        <div className="text-center max-w-3xl mx-auto mb-20">
          <motion.p
            initial={{ opacity: 0, y: 10 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.5 }}
            className="font-mono text-xs font-bold tracking-[0.25em] text-bili-pink uppercase mb-3"
          >
            Architecture Highlights
          </motion.p>

          <motion.h2
            initial={{ opacity: 0, y: 15 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.6, delay: 0.1 }}
            className="font-black text-3xl sm:text-5xl tracking-tight text-gray-900 mb-6"
          >
            Built Different, Not Heavier
          </motion.h2>

          <motion.p
            initial={{ opacity: 0, y: 15 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.6, delay: 0.2 }}
            className="text-gray-500 text-lg"
          >
            Paladala replaces every webview and JavaScript bridge with native Swift. Here's how the architecture delivers a faster, lighter Bilibili experience.
          </motion.p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 sm:gap-8">
          {FEATURES_LIST.map((feature: FeatureCard, idx: number) => (
            <motion.div
              key={feature.title}
              initial={{ opacity: 0, y: 25 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-50px" }}
              transition={{ duration: 0.5, delay: idx * 0.1 }}
              whileHover={{ y: -6, transition: { duration: 0.2 } }}
              className="relative group rounded-2xl bg-white border border-gray-150 p-6 md:p-8 shadow-sm hover:shadow-xl hover:border-bili-pink/25 transition-all duration-300 flex flex-col justify-between overflow-hidden bg-gradient-to-b from-white to-gray-50/50"
            >
              <div className="absolute -top-12 -right-12 w-28 h-28 rounded-full bg-bili-pink-light opacity-0 group-hover:opacity-100 group-hover:scale-110 transition-all duration-500 -z-1 blur-xl" />

              <div>
                <div className="flex items-center justify-between mb-6">
                  <span className="inline-flex px-2.5 py-1 rounded-md text-[10px] uppercase tracking-wider font-mono font-bold bg-bili-pink-light text-bili-pink border border-bili-pink/10">
                    {feature.badge}
                  </span>
                  <div className="w-10 h-10 rounded-xl bg-gray-50 group-hover:bg-bili-pink group-hover:text-white flex items-center justify-center border border-gray-150 group-hover:border-bili-pink text-gray-700 transition-all duration-300 shadow-sm shadow-black/5">
                    <DynamicIcon name={feature.iconName} className="w-5 h-5 transition-transform duration-300 group-hover:rotate-6" />
                  </div>
                </div>

                <h3 className="font-extrabold text-xl text-gray-950 mb-3 ml-0.5 tracking-tight group-hover:text-bili-pink transition-colors duration-200">
                  {feature.title}
                </h3>

                <p className="text-sm text-gray-500 leading-relaxed ml-0.5">
                  {feature.description}
                </p>
              </div>

              <div className="w-full h-1 bg-gradient-to-r from-bili-pink/5 to-transparent absolute bottom-0 left-0 group-hover:from-bili-pink/40 group-hover:to-bili-blue/40 transition-all duration-500" />
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
