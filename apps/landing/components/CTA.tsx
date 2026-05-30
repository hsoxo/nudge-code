export default function CTA() {
  return (
    <section
      className="py-20 md:py-28 border-t border-[var(--color-border)] relative overflow-hidden"
      aria-labelledby="cta-heading"
    >
      {/* Background glow */}
      <div
        className="absolute inset-0"
        style={{
          background:
            "radial-gradient(ellipse 60% 80% at 50% 100%, rgba(0,229,160,0.08), transparent)",
        }}
        aria-hidden="true"
      />
      <div className="absolute inset-0 bg-grid opacity-50" aria-hidden="true" />

      <div className="relative max-w-3xl mx-auto px-4 sm:px-6 text-center">
        <p
          className="text-xs font-semibold tracking-widest uppercase mb-6 terminal-text"
          style={{ color: "var(--color-accent)" }}
        >
          Get started
        </p>
        <h2
          id="cta-heading"
          className="text-3xl sm:text-5xl font-bold tracking-tight text-[var(--color-text)] mb-6 leading-tight"
        >
          Your agents are running.
          <br />
          <span style={{ color: "var(--color-accent)" }}>
            Are you watching?
          </span>
        </h2>
        <p className="text-lg text-[var(--color-text-muted)] mb-10 max-w-xl mx-auto leading-relaxed">
          Install Nudge in two minutes. Run your own relay. Control your
          terminal from anywhere — end-to-end encrypted, no cloud required.
        </p>

        <div className="flex flex-col sm:flex-row items-center justify-center gap-4">
          <a
            href="#TODO-docs"
            className="w-full sm:w-auto inline-flex items-center justify-center gap-2 px-7 py-3.5 rounded-lg text-sm font-semibold bg-[var(--color-accent)] text-[#080b0f] hover:bg-[var(--color-accent-dim)] transition-all duration-150 hover:scale-[1.02] active:scale-[0.98]"
          >
            Read the docs
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
              <path d="M3 8h10M9 4l4 4-4 4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </a>
          <a
            href="#TODO-github"
            className="w-full sm:w-auto inline-flex items-center justify-center gap-2 px-7 py-3.5 rounded-lg text-sm font-medium glow-border text-[var(--color-text-muted)] hover:text-[var(--color-text)] transition-colors duration-150"
            aria-label="View Nudge source on GitHub"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
              <path d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z" />
            </svg>
            View on GitHub
          </a>
        </div>

        {/* Terminal command teaser */}
        <div
          className="mt-12 inline-flex items-center gap-3 px-5 py-3 rounded-xl glow-border terminal-text text-sm"
          style={{ background: "#0a0f14" }}
          aria-label="Quick install command"
        >
          <span style={{ color: "var(--color-accent)" }} aria-hidden="true">$</span>
          <code className="text-[var(--color-text)]">
            curl -fsSL https://nudgecode.dev/install.sh | sh
          </code>
        </div>
      </div>
    </section>
  );
}
