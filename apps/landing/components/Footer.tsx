const footerLinks = [
  {
    label: "Product",
    links: [
      { href: "#features", label: "Features" },
      { href: "#how-it-works", label: "How it works" },
      { href: "#pricing", label: "Pricing" },
      { href: "#TODO-changelog", label: "Changelog" },
    ],
  },
  {
    label: "Developers",
    links: [
      { href: "#TODO-docs", label: "Documentation" },
      { href: "#TODO-github", label: "GitHub" },
      { href: "#TODO-github-releases", label: "Releases" },
      { href: "#TODO-github-issues", label: "Issues" },
    ],
  },
  {
    label: "Company",
    links: [
      { href: "#faq", label: "FAQ" },
      { href: "#security", label: "Security" },
      { href: "#TODO-privacy", label: "Privacy policy" },
      { href: "#TODO-terms", label: "Terms of service" },
    ],
  },
];

export default function Footer() {
  const year = new Date().getFullYear();

  return (
    <footer
      className="border-t border-[var(--color-border)]"
      style={{ background: "var(--color-surface)" }}
      role="contentinfo"
      aria-label="Site footer"
    >
      <div className="max-w-6xl mx-auto px-4 sm:px-6 py-16">
        {/* Top row */}
        <div className="flex flex-col lg:flex-row gap-12 lg:gap-16 mb-12">
          {/* Brand */}
          <div className="lg:max-w-xs">
            <a
              href="#"
              className="flex items-center gap-2.5 mb-4 group"
              aria-label="Nudge home"
            >
              <svg
                width="26"
                height="26"
                viewBox="0 0 28 28"
                fill="none"
                xmlns="http://www.w3.org/2000/svg"
                aria-hidden="true"
              >
                <rect width="28" height="28" rx="7" fill="var(--color-accent)" />
                <path
                  d="M7 10L12 14L7 18"
                  stroke="#080b0f"
                  strokeWidth="2.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
                <line
                  x1="14"
                  y1="18"
                  x2="21"
                  y2="18"
                  stroke="#080b0f"
                  strokeWidth="2.5"
                  strokeLinecap="round"
                />
              </svg>
              <span className="text-base font-semibold text-[var(--color-text)] group-hover:text-[var(--color-accent)] transition-colors">
                Nudge
              </span>
            </a>
            <p className="text-sm text-[var(--color-text-muted)] leading-relaxed mb-4">
              A local-first, phone-first remote shell for developers. Control
              your terminal and AI agents from your iPhone.
            </p>
            <a
              href="https://nudgecode.dev"
              className="text-xs terminal-text"
              style={{ color: "var(--color-text-subtle)" }}
            >
              nudgecode.dev
            </a>
          </div>

          {/* Link groups */}
          <div className="flex-1 grid grid-cols-2 sm:grid-cols-3 gap-8">
            {footerLinks.map((group) => (
              <div key={group.label}>
                <h3
                  className="text-xs font-semibold tracking-widest uppercase mb-4 terminal-text"
                  style={{ color: "var(--color-text-subtle)" }}
                >
                  {group.label}
                </h3>
                <ul className="flex flex-col gap-2.5" role="list">
                  {group.links.map((link) => (
                    <li key={link.label}>
                      <a
                        href={link.href}
                        className="text-sm text-[var(--color-text-muted)] hover:text-[var(--color-text)] transition-colors duration-150"
                      >
                        {link.label}
                      </a>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </div>

        {/* Bottom bar */}
        <div
          className="flex flex-col sm:flex-row items-center justify-between gap-4 pt-8 border-t border-[var(--color-border)]"
        >
          <p className="text-xs text-[var(--color-text-subtle)] terminal-text">
            &copy; {year} Nudge. All rights reserved.
          </p>

          {/* E2E note */}
          <div
            className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-xs terminal-text"
            style={{
              background: "var(--color-accent-glow-sm)",
              color: "var(--color-accent)",
              border: "1px solid rgba(0,229,160,0.15)",
            }}
            aria-label="End-to-end encrypted"
          >
            <svg
              width="12"
              height="12"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.5"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
            >
              <rect x="3" y="11" width="18" height="11" rx="2" ry="2" />
              <path d="M7 11V7a5 5 0 0 1 10 0v4" />
            </svg>
            End-to-end encrypted
          </div>
        </div>
      </div>
    </footer>
  );
}
