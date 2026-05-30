const features = [
  {
    icon: (
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <rect x="5" y="2" width="14" height="20" rx="2" ry="2"/>
        <line x1="12" y1="18" x2="12.01" y2="18"/>
      </svg>
    ),
    title: "Phone-first control",
    description:
      "A native iOS app built around the terminal. Type commands, scroll output, manage tabs — everything feels at home on your iPhone.",
  },
  {
    icon: (
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <circle cx="12" cy="12" r="10"/>
        <path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/>
        <line x1="12" y1="17" x2="12.01" y2="17"/>
      </svg>
    ),
    title: "Built for AI agents",
    description:
      "Watch Claude Code, Codex, and other agents work. Approve prompts, review diffs, or kill a runaway process — all from your phone.",
  },
  {
    icon: (
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>
        <path d="M7 11V7a5 5 0 0 1 10 0v4"/>
      </svg>
    ),
    title: "End-to-end encryption",
    description:
      "X25519 key agreement, HKDF-SHA256, ChaCha20-Poly1305. The relay routes only ciphertext — it has no key and can never read your terminal data.",
  },
  {
    icon: (
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>
        <polyline points="9 22 9 12 15 12 15 22"/>
      </svg>
    ),
    title: "Local-first, your relay",
    description:
      "Run the relay on your own infrastructure. Your data never touches a third-party server. A hosted option is coming soon for those who want it.",
  },
  {
    icon: (
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <polyline points="1 4 1 10 7 10"/>
        <path d="M3.51 15a9 9 0 1 0 .49-3.5"/>
      </svg>
    ),
    title: "Instant reconnect",
    description:
      "Background the app, take a call, come back. Nudge reconnects immediately. Your terminal session is exactly where you left it.",
  },
  {
    icon: (
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <polyline points="4 17 10 11 4 5"/>
        <line x1="12" y1="19" x2="20" y2="19"/>
      </svg>
    ),
    title: "Live xterm.js sync",
    description:
      "Full terminal emulation powered by xterm.js. Colors, control sequences, scrollback — rendered faithfully on a 6-inch screen.",
  },
];

export default function Features() {
  return (
    <section
      id="features"
      className="py-24 md:py-32"
      aria-labelledby="features-heading"
    >
      <div className="max-w-6xl mx-auto px-4 sm:px-6">
        {/* Section header */}
        <div className="text-center mb-16">
          <p
            className="text-xs font-semibold tracking-widest uppercase mb-4 terminal-text"
            style={{ color: "var(--color-accent)" }}
          >
            Features
          </p>
          <h2
            id="features-heading"
            className="text-3xl sm:text-4xl font-bold tracking-tight text-[var(--color-text)] mb-4"
          >
            Everything you need to work<br className="hidden sm:block" /> from anywhere
          </h2>
          <p className="text-[var(--color-text-muted)] max-w-xl mx-auto">
            Nudge is lean by design. Every feature earns its place.
          </p>
        </div>

        {/* Grid */}
        <ul
          className="grid sm:grid-cols-2 lg:grid-cols-3 gap-px"
          role="list"
          style={{ background: "var(--color-border)" }}
        >
          {features.map((feature, i) => (
            <li
              key={i}
              className="group p-8 flex flex-col gap-4 transition-colors duration-200"
              style={{ background: "var(--color-surface)" }}
            >
              <div
                className="w-10 h-10 rounded-lg flex items-center justify-center transition-colors duration-200 group-hover:bg-[var(--color-accent-glow)]"
                style={{
                  background: "var(--color-accent-glow-sm)",
                  color: "var(--color-accent)",
                }}
              >
                {feature.icon}
              </div>
              <h3 className="text-base font-semibold text-[var(--color-text)]">
                {feature.title}
              </h3>
              <p className="text-sm text-[var(--color-text-muted)] leading-relaxed">
                {feature.description}
              </p>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
