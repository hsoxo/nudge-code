export default function Pricing() {
  return (
    <section
      id="pricing"
      className="py-24 md:py-32 border-t border-[var(--color-border)]"
      aria-labelledby="pricing-heading"
    >
      <div className="max-w-6xl mx-auto px-4 sm:px-6">
        {/* Header */}
        <div className="text-center mb-16">
          <p
            className="text-xs font-semibold tracking-widest uppercase mb-4 terminal-text"
            style={{ color: "var(--color-accent)" }}
          >
            Pricing
          </p>
          <h2
            id="pricing-heading"
            className="text-3xl sm:text-4xl font-bold tracking-tight text-[var(--color-text)] mb-4"
          >
            Start free. Scale when you're ready.
          </h2>
          <p className="text-[var(--color-text-muted)] max-w-md mx-auto">
            Nudge is free for local use. Pro and hosted tiers are on the roadmap.
          </p>
        </div>

        {/* Plans */}
        <div className="grid md:grid-cols-2 gap-6 max-w-3xl mx-auto">
          {/* Free tier */}
          <div
            className="rounded-2xl p-8 flex flex-col gap-6 glow-border-accent relative overflow-hidden"
            style={{ background: "var(--color-surface)" }}
          >
            {/* Active badge */}
            <div
              className="absolute top-0 right-0 px-3 py-1 text-xs font-semibold terminal-text rounded-bl-lg"
              style={{
                background: "var(--color-accent)",
                color: "#080b0f",
              }}
              aria-label="Currently available"
            >
              Available now
            </div>

            <div>
              <p
                className="text-xs font-semibold tracking-widest uppercase terminal-text mb-3"
                style={{ color: "var(--color-accent)" }}
              >
                Free
              </p>
              <div className="flex items-baseline gap-2 mb-2">
                <span className="text-5xl font-bold text-[var(--color-text)]">$0</span>
                <span className="text-[var(--color-text-muted)] text-sm">/ forever</span>
              </div>
              <p className="text-sm text-[var(--color-text-muted)]">
                Self-hosted relay · local-first
              </p>
            </div>

            <ul className="flex flex-col gap-3" role="list">
              {[
                "1 computer",
                "1 active tab",
                "Unlimited sessions",
                "End-to-end encrypted",
                "Run your own relay",
                "iOS 17+ · iPhone 13+",
                "Claude Code & Codex support",
              ].map((item) => (
                <li key={item} className="flex items-center gap-3 text-sm text-[var(--color-text-muted)]">
                  <svg
                    width="16"
                    height="16"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2.5"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    style={{ color: "var(--color-accent)", flexShrink: 0 }}
                    aria-hidden="true"
                  >
                    <polyline points="20 6 9 17 4 12" />
                  </svg>
                  {item}
                </li>
              ))}
            </ul>

            <a
              href="#TODO-docs"
              className="mt-auto block text-center px-5 py-3 rounded-lg text-sm font-semibold bg-[var(--color-accent)] text-[#080b0f] hover:bg-[var(--color-accent-dim)] transition-colors duration-150"
              aria-label="Get started with Nudge free tier"
            >
              Get started free
            </a>
          </div>

          {/* Pro / Coming soon */}
          <div
            className="rounded-2xl p-8 flex flex-col gap-6 glow-border relative overflow-hidden"
            style={{ background: "var(--color-surface)" }}
          >
            {/* Coming soon badge */}
            <div
              className="absolute top-0 right-0 px-3 py-1 text-xs font-semibold terminal-text rounded-bl-lg"
              style={{
                background: "var(--color-surface-2)",
                color: "var(--color-text-muted)",
                border: "1px solid var(--color-border)",
              }}
              aria-label="Coming soon"
            >
              Coming soon
            </div>

            <div>
              <p
                className="text-xs font-semibold tracking-widest uppercase terminal-text mb-3"
                style={{ color: "var(--color-text-subtle)" }}
              >
                Pro / Hosted
              </p>
              <div className="flex items-baseline gap-2 mb-2">
                <span className="text-5xl font-bold text-[var(--color-text-muted)]">—</span>
              </div>
              <p className="text-sm text-[var(--color-text-subtle)]">
                Managed relay · waitlist open
              </p>
            </div>

            <ul className="flex flex-col gap-3" role="list">
              {[
                "Everything in Free",
                "Multiple computers",
                "Unlimited tabs",
                "Managed relay (we host it)",
                "Team sharing",
                "Priority support",
                "More coming based on feedback",
              ].map((item) => (
                <li
                  key={item}
                  className="flex items-center gap-3 text-sm"
                  style={{ color: "var(--color-text-subtle)" }}
                >
                  <svg
                    width="16"
                    height="16"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2.5"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    style={{ flexShrink: 0 }}
                    aria-hidden="true"
                  >
                    <circle cx="12" cy="12" r="10" />
                    <line x1="12" y1="8" x2="12" y2="12" />
                    <line x1="12" y1="16" x2="12.01" y2="16" />
                  </svg>
                  {item}
                </li>
              ))}
            </ul>

            <a
              href="#TODO-waitlist"
              className="mt-auto block text-center px-5 py-3 rounded-lg text-sm font-medium transition-colors duration-150"
              style={{
                background: "var(--color-surface-2)",
                color: "var(--color-text-muted)",
                border: "1px solid var(--color-border)",
              }}
              aria-label="Join the Nudge Pro waitlist (coming soon)"
            >
              Join waitlist
            </a>
          </div>
        </div>

        <p className="text-center mt-10 text-xs text-[var(--color-text-subtle)] terminal-text">
          Pricing subject to change. Free tier will always exist.
        </p>
      </div>
    </section>
  );
}
