import TerminalMock from "./TerminalMock";
import PhoneMock from "./PhoneMock";

export default function Hero() {
  return (
    <section
      className="relative min-h-screen flex flex-col justify-center pt-16 overflow-hidden"
      aria-labelledby="hero-headline"
    >
      {/* Background layers */}
      <div className="absolute inset-0 bg-grid" aria-hidden="true" />
      <div className="absolute inset-0 hero-glow" aria-hidden="true" />

      {/* Radial vignette */}
      <div
        className="absolute inset-0"
        style={{
          background:
            "radial-gradient(ellipse 60% 60% at 50% 100%, rgba(0,0,0,0.8), transparent)",
        }}
        aria-hidden="true"
      />

      <div className="relative max-w-6xl mx-auto px-4 sm:px-6 py-20 md:py-28">
        <div className="flex flex-col lg:flex-row items-center gap-16 lg:gap-12">
          {/* Left: copy */}
          <div className="flex-1 text-center lg:text-left max-w-xl mx-auto lg:mx-0">
            {/* Badge */}
            <div className="animate-fade-up inline-flex items-center gap-2 px-3 py-1.5 mb-8 rounded-full text-xs font-medium terminal-text glow-border"
              style={{ color: "var(--color-accent)", background: "var(--color-accent-glow-sm)" }}
            >
              <span
                className="w-1.5 h-1.5 rounded-full animate-glow-pulse"
                style={{ background: "var(--color-accent)" }}
                aria-hidden="true"
              />
              Now in early access · iOS 17+
            </div>

            {/* Headline */}
            <h1
              id="hero-headline"
              className="animate-fade-up-delay-1 text-5xl sm:text-6xl lg:text-7xl font-bold leading-[1.05] tracking-tight text-[var(--color-text)] mb-6"
            >
              Your terminal.
              <br />
              <span style={{ color: "var(--color-accent)" }}>In your pocket.</span>
            </h1>

            {/* Subhead */}
            <p className="animate-fade-up-delay-2 text-lg sm:text-xl text-[var(--color-text-muted)] leading-relaxed mb-10 max-w-lg mx-auto lg:mx-0">
              Drive your computer's terminal from your iPhone — purpose-built
              for babysitting AI coding agents like Claude&nbsp;Code and Codex,
              end&#8209;to&#8209;end encrypted, and local&#8209;first.
            </p>

            {/* CTAs */}
            <div className="animate-fade-up-delay-3 flex flex-col sm:flex-row items-center gap-4 justify-center lg:justify-start">
              <a
                href="#pricing"
                className="w-full sm:w-auto inline-flex items-center justify-center gap-2 px-6 py-3 rounded-lg text-sm font-semibold bg-[var(--color-accent)] text-[#080b0f] hover:bg-[var(--color-accent-dim)] transition-all duration-150 hover:scale-[1.02] active:scale-[0.98]"
              >
                Get started free
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
                  <path d="M3 8h10M9 4l4 4-4 4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </a>
              <a
                href="#TODO-github"
                className="w-full sm:w-auto inline-flex items-center justify-center gap-2 px-6 py-3 rounded-lg text-sm font-medium glow-border text-[var(--color-text-muted)] hover:text-[var(--color-text)] hover:border-[var(--color-border-bright)] transition-all duration-150"
                aria-label="View Nudge on GitHub (link coming soon)"
              >
                {/* GitHub icon */}
                <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                  <path d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z" />
                </svg>
                View on GitHub
              </a>
            </div>

            {/* Social proof strip */}
            <p className="animate-fade-up-delay-4 mt-8 text-xs text-[var(--color-text-subtle)] terminal-text">
              Works with Claude Code · Codex · any CLI · any shell
            </p>
          </div>

          {/* Right: visual mockup */}
          <div className="flex-1 flex items-center justify-center lg:justify-end w-full">
            <div className="animate-fade-up-delay-2 flex items-end gap-6 lg:gap-8">
              <TerminalMock />
              {/* Sync arrow */}
              <div className="flex flex-col items-center gap-2 pb-16 flex-shrink-0" aria-hidden="true">
                <div
                  className="w-px h-8"
                  style={{ background: "linear-gradient(to bottom, transparent, var(--color-accent))" }}
                />
                <svg width="28" height="28" viewBox="0 0 28 28" fill="none">
                  <path
                    d="M7 14h14M7 9l-4 5 4 5M21 9l4 5-4 5"
                    stroke="var(--color-accent)"
                    strokeWidth="1.5"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
                <div
                  className="w-px h-8"
                  style={{ background: "linear-gradient(to top, transparent, var(--color-accent))" }}
                />
                <span className="text-[10px] terminal-text mt-1"
                  style={{ color: "var(--color-accent)", writingMode: "vertical-rl", letterSpacing: "0.12em" }}
                >
                  E2E ENCRYPTED
                </span>
              </div>
              <PhoneMock />
            </div>
          </div>
        </div>
      </div>

      {/* Bottom fade */}
      <div
        className="absolute bottom-0 left-0 right-0 h-24"
        style={{ background: "linear-gradient(to bottom, transparent, var(--color-bg))" }}
        aria-hidden="true"
      />
    </section>
  );
}
