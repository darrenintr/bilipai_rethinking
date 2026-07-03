import { motion } from "motion/react";
import { Github, ChevronRight } from "lucide-react";

export default function Header() {
  return (
    <motion.header
      initial={{ y: -50, opacity: 0 }}
      animate={{ y: 0, opacity: 1 }}
      transition={{ duration: 0.6, ease: [0.4, 0, 0.2, 1] }}
      className="fixed top-0 left-0 w-full z-50 px-4 py-3 md:py-4"
      style={{
        background: "rgba(251, 251, 253, 0.8)",
        backdropFilter: "saturate(180%) blur(20px)",
        WebkitBackdropFilter: "saturate(180%) blur(20px)",
        borderBottom: "1px solid var(--color-border-hairline)",
      }}
    >
      <div className="max-w-7xl mx-auto flex items-center justify-between">
        <a href="#hero" className="flex items-center gap-2.5 group">
          <div className="w-8 h-8 shrink-0">
            <svg
              viewBox="0 0 120 120"
              className="w-8 h-8"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
            >
              <rect x="12" y="32" width="96" height="74" rx="22" stroke="#1d1d1f" strokeWidth="7.5" fill="white" />
              <path d="M42 32L24 12" stroke="#1d1d1f" strokeWidth="8" strokeLinecap="round" />
              <path d="M78 32L96 12" stroke="#1d1d1f" strokeWidth="8" strokeLinecap="round" />
              <path d="M38 106V114" stroke="#1d1d1f" strokeWidth="8" strokeLinecap="round" />
              <path d="M82 106V114" stroke="#1d1d1f" strokeWidth="8" strokeLinecap="round" />
              <path d="M38 68L46 73L38 78" stroke="#1d1d1f" strokeWidth="5" strokeLinecap="round" strokeLinejoin="round" />
              <path d="M82 68L74 73L82 78" stroke="#1d1d1f" strokeWidth="5" strokeLinecap="round" strokeLinejoin="round" />
              <path d="M54 81C56 83.5 58 84.5 60 84.5C62 84.5 64 83.5 66 81C68 83.5 70 84.5 72 84.5C74 84.5 76 83.5 78 81" stroke="#1d1d1f" strokeWidth="5.5" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </div>
          <span
            className="font-semibold text-[color:var(--color-text-primary)] leading-none"
            style={{ fontSize: "17px", letterSpacing: "-0.01em" }}
          >
            Paladala
          </span>
        </a>

        <nav className="hidden md:flex items-center gap-10 text-[14px] text-[color:var(--color-text-primary)]">
          <a
            href="#features"
            onClick={(e) => {
              e.preventDefault();
              document.getElementById("features")?.scrollIntoView({ behavior: "smooth" });
            }}
            className="hover:opacity-70"
            style={{ transition: "opacity 200ms cubic-bezier(0.4, 0, 0.2, 1)" }}
          >
            Features
          </a>
          <a
            href="#metrics"
            onClick={(e) => {
              e.preventDefault();
              document.getElementById("metrics")?.scrollIntoView({ behavior: "smooth" });
            }}
            className="hover:opacity-70"
            style={{ transition: "opacity 200ms cubic-bezier(0.4, 0, 0.2, 1)" }}
          >
            Performance
          </a>
        </nav>

        <div className="flex items-center gap-3">
          <a
            href="https://github.com/darrenintr/pure-bilibili-rethinking"
            target="_blank"
            rel="noopener noreferrer"
            className="group inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-[14px] text-[color:var(--color-text-primary)] hover:opacity-70"
            style={{ transition: "opacity 200ms cubic-bezier(0.4, 0, 0.2, 1)" }}
          >
            <Github className="w-4 h-4" />
            <span>GitHub</span>
            <ChevronRight className="w-3 h-3 opacity-60 group-hover:translate-x-0.5" style={{ transition: "transform 200ms cubic-bezier(0.4, 0, 0.2, 1)" }} />
          </a>
        </div>
      </div>
    </motion.header>
  );
}