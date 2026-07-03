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
      className="relative bg-white text-[color:var(--color-text-primary)] overflow-hidden bg-grid-pattern-light border-y border-[color:var(--color-border-hairline)] scroll-mt-20"
      id="features"
      style={{ paddingTop: "clamp(80px, 12vw, 160px)", paddingBottom: "clamp(80px, 12vw, 160px)" }}
    >
      <div className="max-w-7xl mx-auto px-6">
        <div className="text-center max-w-3xl mx-auto mb-20">
          <motion.p
            initial={{ opacity: 0, y: 10 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.5 }}
            className="text-sm font-normal tracking-[0.02em] text-[color:var(--color-text-secondary)] mb-3"
          >
            Architecture
          </motion.p>

          <motion.h2
            initial={{ opacity: 0, y: 15 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.6, delay: 0.1 }}
            className="font-bold mb-6 leading-[1.1] tracking-[-0.015em]"
            style={{ fontSize: "clamp(36px, 4.5vw, 56px)" }}
          >
            Built Different. Lighter.
          </motion.h2>

          <motion.p
            initial={{ opacity: 0, y: 15 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.6, delay: 0.2 }}
            className="text-[color:var(--color-text-secondary)]"
            style={{ fontSize: "clamp(17px, 1.4vw, 19px)", lineHeight: 1.5 }}
          >
            Paladala replaces every webview and JavaScript bridge with native Swift. Here's how the architecture delivers a faster, lighter Bilibili experience.
          </motion.p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {FEATURES_LIST.map((feature: FeatureCard, idx: number) => (
            <motion.article
              key={feature.title}
              initial={{ opacity: 0, y: 25 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-50px" }}
              transition={{ duration: 0.5, delay: idx * 0.08 }}
              className="rounded-[18px] bg-white border border-[color:var(--color-border-hairline)] hover:border-[color:var(--color-border-hover)] flex flex-col"
              style={{
                padding: "40px",
                transition: "border-color 200ms cubic-bezier(0.4, 0, 0.2, 1)",
              }}
            >
              <div>
                <div className="flex items-center justify-between mb-8">
                  <span
                    className="inline-flex px-2.5 py-1 rounded-md text-[11px] tracking-wide font-medium bg-[color:var(--color-bg-secondary)] text-[color:var(--color-text-secondary)]"
                    style={{ border: "1px solid var(--color-border-hairline)" }}
                  >
                    {feature.badge}
                  </span>
                  <DynamicIcon
                    name={feature.iconName}
                    className="w-6 h-6 text-[color:var(--color-text-primary)]"
                  />
                </div>

                <h3
                  className="font-semibold text-[color:var(--color-text-primary)] mb-3 tracking-[-0.01em]"
                  style={{ fontSize: "21px", lineHeight: 1.3 }}
                >
                  {feature.title}
                </h3>

                <p
                  className="text-[color:var(--color-text-secondary)]"
                  style={{ fontSize: "15px", lineHeight: 1.5 }}
                >
                  {feature.description}
                </p>
              </div>
            </motion.article>
          ))}
        </div>
      </div>
    </section>
  );
}