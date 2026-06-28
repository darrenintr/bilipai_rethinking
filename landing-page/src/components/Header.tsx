import { motion } from "motion/react";
import { Github, ExternalLink } from "lucide-react";

export default function Header() {
  return (
    <motion.header
      initial={{ y: -50, opacity: 0 }}
      animate={{ y: 0, opacity: 1 }}
      transition={{ duration: 0.6, ease: "easeOut" }}
      className="fixed top-0 left-0 w-full z-50 px-4 py-3 md:py-4 bg-white/70 backdrop-blur-md border-b border-bili-pink/10 shadow-sm"
    >
      <div className="max-w-7xl mx-auto flex items-center justify-between">
        <a href="#hero" className="flex items-center gap-2.5 group">
          <div className="relative w-10 h-10 shrink-0 group-hover:scale-105 transition-transform duration-300">
            <svg
              viewBox="0 0 120 120"
              className="w-10 h-10"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
            >
              <rect x="12" y="32" width="96" height="74" rx="22" stroke="#FB7299" strokeWidth="7.5" fill="white" />
              <path d="M42 32L24 12" stroke="#FB7299" strokeWidth="8" strokeLinecap="round" />
              <path d="M78 32L96 12" stroke="#FB7299" strokeWidth="8" strokeLinecap="round" />
              <path d="M38 106V114" stroke="#FB7299" strokeWidth="8" strokeLinecap="round" />
              <path d="M82 106V114" stroke="#FB7299" strokeWidth="8" strokeLinecap="round" />
              <path d="M38 68L46 73L38 78" stroke="#FB7299" strokeWidth="5" strokeLinecap="round" strokeLinejoin="round" />
              <path d="M82 68L74 73L82 78" stroke="#FB7299" strokeWidth="5" strokeLinecap="round" strokeLinejoin="round" />
              <path d="M54 81C56 83.5 58 84.5 60 84.5C62 84.5 64 83.5 66 81C68 83.5 70 84.5 72 84.5C74 84.5 76 83.5 78 81" stroke="#FB7299" strokeWidth="5.5" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            <div className="absolute top-0 right-0 w-2.5 h-2.5 rounded-full bg-bili-blue border-2 border-white animate-pulse" />
          </div>
          <div className="flex flex-col">
            <span className="font-black text-xl tracking-tight text-gray-900 group-hover:text-bili-pink transition-colors duration-300 leading-none">
              Paladala
            </span>
            <span className="text-[9px] font-mono text-bili-pink font-semibold tracking-widest leading-none mt-1">
              PURE SWIFT
            </span>
          </div>
        </a>

        <nav className="hidden md:flex items-center gap-10 text-sm font-medium text-gray-600">
          <a href="#features" className="hover:text-bili-pink transition-colors duration-200">
            Features
          </a>
          <a href="#metrics" className="hover:text-bili-pink transition-colors duration-200">
            Performance
          </a>
        </nav>

        <div className="flex items-center gap-3">
          <a
            href="https://github.com/darrenintr/pure-bilibili-rethinking"
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-2 px-3.5 py-1.5 rounded-full bg-gray-900 hover:bg-bili-pink text-white text-xs font-semibold tracking-wide shadow-md shadow-gray-950/10 hover:shadow-bili-pink/30 hover:-translate-y-0.5 transition-all duration-300"
          >
            <Github className="w-3.5 h-3.5" />
            <span className="hidden sm:inline">GitHub</span>
            <ExternalLink className="w-3 h-3 opacity-70" />
          </a>
        </div>
      </div>
    </motion.header>
  );
}
