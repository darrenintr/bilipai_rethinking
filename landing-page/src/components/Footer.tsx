import { Github, Heart, Star } from "lucide-react";

export default function Footer() {
  return (
    <footer className="bg-gray-950 text-gray-500 py-16 px-6 border-t border-white/5 relative z-10">
      <div className="max-w-7xl mx-auto flex flex-col md:flex-row items-center justify-between gap-8 text-center md:text-left">
        <div className="flex flex-col items-center md:items-start space-y-3">
          <div className="flex items-center gap-2.5">
            <div className="w-8 h-8 rounded bg-transparent flex items-center justify-center">
              <svg viewBox="0 0 120 120" className="w-8 h-8" fill="none" xmlns="http://www.w3.org/2000/svg">
                <rect x="12" y="32" width="96" height="74" rx="22" stroke="#FB7299" strokeWidth="8" fill="white" />
                <path d="M42 32L24 12" stroke="#FB7299" strokeWidth="8.5" strokeLinecap="round" />
                <path d="M78 32L96 12" stroke="#FB7299" strokeWidth="8.5" strokeLinecap="round" />
                <path d="M38 106V114" stroke="#FB7299" strokeWidth="8.5" strokeLinecap="round" />
                <path d="M82 106V114" stroke="#FB7299" strokeWidth="8.5" strokeLinecap="round" />
                <path d="M38 68L46 73L38 78" stroke="#FB7299" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
                <path d="M82 68L74 73L82 78" stroke="#FB7299" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
                <path d="M54 81C56 83.5 58 84.5 60 84.5C62 84.5 64 83.5 66 81C68 83.5 70 84.5 72 84.5C74 84.5 76 83.5 78 81" stroke="#FB7299" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            </div>
            <span className="font-black text-md tracking-wider text-white">Paladala</span>
          </div>
          <p className="text-xs text-gray-400 max-w-sm leading-relaxed text-center md:text-left">
            A native Swift rewrite of the Bilibili iOS client. Local HLS proxy, dual design language, AVKit player, and zero webview dependencies.
          </p>
        </div>

        <div className="flex flex-wrap items-center justify-center gap-6 text-xs text-gray-450">
          <a href="#features" className="hover:text-bili-pink transition-colors">Features</a>
          <span>&middot;</span>
          <a href="#metrics" className="hover:text-bili-pink transition-colors">Performance</a>
          <span>&middot;</span>
          <a
            href="https://github.com/darrenintr/pure-bilibili-rethinking"
            target="_blank"
            rel="noopener noreferrer"
            className="text-bili-pink hover:text-bili-pink-hover font-semibold inline-flex items-center gap-1 transition-colors"
          >
            <Star className="w-3 h-3 fill-bili-pink" /> <span>GitHub</span>
          </a>
        </div>

        <div className="flex flex-col items-center md:items-end space-y-2">
          <div className="flex items-center gap-1.5 text-xs">
            <span className="text-gray-400">Crafted with</span>
            <Heart className="w-3 h-3 text-bili-pink fill-bili-pink" />
            <span className="text-gray-400">in pure Swift</span>
          </div>
          <span className="text-[10px] text-gray-650 font-mono">
            &copy; {new Date().getFullYear()} Paladala. MIT License.
          </span>
        </div>
      </div>
    </footer>
  );
}
