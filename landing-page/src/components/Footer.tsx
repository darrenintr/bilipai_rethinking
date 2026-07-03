export default function Footer() {
  return (
    <footer
      className="text-[color:var(--color-text-secondary)]"
      style={{
        background: "var(--color-bg-secondary)",
        borderTop: "1px solid var(--color-border-hairline)",
        padding: "clamp(40px, 5vw, 56px) clamp(20px, 4vw, 40px)",
      }}
    >
      <div className="max-w-7xl mx-auto grid grid-cols-1 md:grid-cols-4 gap-8 md:gap-12">
        {/* Brand block */}
        <div className="md:col-span-1">
          <div className="flex items-center gap-2 mb-3">
            <div className="w-6 h-6">
              <svg viewBox="0 0 120 120" className="w-6 h-6" fill="none" xmlns="http://www.w3.org/2000/svg">
                <rect x="12" y="32" width="96" height="74" rx="22" stroke="#1d1d1f" strokeWidth="8" fill="white" />
                <path d="M42 32L24 12" stroke="#1d1d1f" strokeWidth="8.5" strokeLinecap="round" />
                <path d="M78 32L96 12" stroke="#1d1d1f" strokeWidth="8.5" strokeLinecap="round" />
                <path d="M38 106V114" stroke="#1d1d1f" strokeWidth="8.5" strokeLinecap="round" />
                <path d="M82 106V114" stroke="#1d1d1f" strokeWidth="8.5" strokeLinecap="round" />
                <path d="M38 68L46 73L38 78" stroke="#1d1d1f" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
                <path d="M82 68L74 73L82 78" stroke="#1d1d1f" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
                <path d="M54 81C56 83.5 58 84.5 60 84.5C62 84.5 64 83.5 66 81C68 83.5 70 84.5 72 84.5C74 84.5 76 83.5 78 81" stroke="#1d1d1f" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            </div>
            <span className="font-semibold text-[color:var(--color-text-primary)]" style={{ fontSize: "14px" }}>
              Paladala
            </span>
          </div>
          <p style={{ fontSize: "12px", lineHeight: 1.6 }} className="text-[color:var(--color-text-secondary)]">
            A native Swift rewrite of the Bilibili iOS client.
          </p>
        </div>

        {/* Product links */}
        <div>
          <h4
            className="font-medium text-[color:var(--color-text-primary)] mb-3"
            style={{ fontSize: "12px" }}
          >
            Product
          </h4>
          <ul className="space-y-2" style={{ fontSize: "12px", lineHeight: 1.6 }}>
            <li>
              <a href="#features" className="hover:text-[color:var(--color-text-primary)]" style={{ transition: "color 200ms cubic-bezier(0.4, 0, 0.2, 1)" }}>
                Features
              </a>
            </li>
            <li>
              <a href="#metrics" className="hover:text-[color:var(--color-text-primary)]" style={{ transition: "color 200ms cubic-bezier(0.4, 0, 0.2, 1)" }}>
                Performance
              </a>
            </li>
          </ul>
        </div>

        {/* Resources */}
        <div>
          <h4
            className="font-medium text-[color:var(--color-text-primary)] mb-3"
            style={{ fontSize: "12px" }}
          >
            Resources
          </h4>
          <ul className="space-y-2" style={{ fontSize: "12px", lineHeight: 1.6 }}>
            <li>
              <a
                href="https://github.com/darrenintr/pure-bilibili-rethinking"
                target="_blank"
                rel="noopener noreferrer"
                className="hover:text-[color:var(--color-text-primary)]"
                style={{ transition: "color 200ms cubic-bezier(0.4, 0, 0.2, 1)" }}
              >
                GitHub
              </a>
            </li>
            <li>
              <a
                href="https://github.com/darrenintr/pure-bilibili-rethinking#readme"
                target="_blank"
                rel="noopener noreferrer"
                className="hover:text-[color:var(--color-text-primary)]"
                style={{ transition: "color 200ms cubic-bezier(0.4, 0, 0.2, 1)" }}
              >
                README
              </a>
            </li>
          </ul>
        </div>

        {/* Legal */}
        <div>
          <h4
            className="font-medium text-[color:var(--color-text-primary)] mb-3"
            style={{ fontSize: "12px" }}
          >
            Legal
          </h4>
          <ul className="space-y-2" style={{ fontSize: "12px", lineHeight: 1.6 }}>
            <li>MIT License</li>
            <li>© {new Date().getFullYear()} Paladala</li>
          </ul>
        </div>
      </div>

      <div
        className="max-w-7xl mx-auto mt-12 pt-6 flex flex-col md:flex-row items-start md:items-center justify-between gap-4"
        style={{ borderTop: "1px solid var(--color-border-hairline)", fontSize: "12px" }}
      >
        <span className="text-[color:var(--color-text-secondary)]">
          Built with Swift and SwiftUI.
        </span>
        <span className="text-[color:var(--color-text-secondary)]">
          This project is not affiliated with Bilibili.
        </span>
      </div>
    </footer>
  );
}