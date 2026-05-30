const steps = [
  {
    number: "01",
    title: "Install the CLI and start the daemon",
    description:
      "Install the Nudge CLI with a single command. The daemon starts in the background and manages your terminal sessions — PTYs, tabs, scrollback — all owned locally on your machine.",
    commands: [
      { comment: "# Install nudge CLI", cmd: "curl -fsSL https://nudgecode.dev/install.sh | sh" },
      { comment: "# Start the daemon", cmd: "nudge daemon start" },
      { comment: "# Output", cmd: "✓ Nudge daemon running (pid 48291)\n✓ PTY pool ready · 4 tabs available", isOutput: true },
    ],
  },
  {
    number: "02",
    title: "Bind your iPhone by scanning a QR code",
    description:
      "Run one command on your computer. Scan the QR code with the Nudge iOS app. A cryptographic handshake (Ed25519-signed, X25519 key exchange) establishes your end-to-end encrypted session. No account required.",
    commands: [
      { comment: "# Generate binding QR code", cmd: "nudge bind" },
      { comment: "# Output", cmd: "⬛⬛⬛  Scan with Nudge iOS app\n⬛⬛⬛  E2E encrypted · expires in 60s", isOutput: true },
    ],
  },
  {
    number: "03",
    title: "Control from anywhere",
    description:
      "Open Nudge on your iPhone. Your terminal is live. Type commands, monitor running agents, approve prompts, open new tabs — everything your keyboard could do, now in your pocket.",
    commands: [
      { comment: "# From your iPhone, run any command", cmd: "claude --model claude-opus-4-5" },
      { comment: "# Or kick off a build", cmd: "npm run build && npm test" },
      { comment: "# Your terminal, your rules", cmd: "# Fully interactive · live sync · instant reconnect", isOutput: true },
    ],
  },
];

export default function HowItWorks() {
  return (
    <section
      id="how-it-works"
      className="py-24 md:py-32 border-t border-[var(--color-border)]"
      aria-labelledby="how-heading"
    >
      <div className="max-w-6xl mx-auto px-4 sm:px-6">
        {/* Section header */}
        <div className="text-center mb-20">
          <p
            className="text-xs font-semibold tracking-widest uppercase mb-4 terminal-text"
            style={{ color: "var(--color-accent)" }}
          >
            How it works
          </p>
          <h2
            id="how-heading"
            className="text-3xl sm:text-4xl font-bold tracking-tight text-[var(--color-text)] mb-4"
          >
            Up and running in under a minute
          </h2>
          <p className="text-[var(--color-text-muted)] max-w-lg mx-auto">
            Three steps. No cloud accounts. No configuration files.
          </p>
        </div>

        {/* Steps */}
        <ol className="flex flex-col gap-16" role="list">
          {steps.map((step, i) => (
            <li
              key={i}
              className="flex flex-col lg:flex-row gap-10 lg:gap-16 items-start"
            >
              {/* Step number + connector */}
              <div className="flex flex-row lg:flex-col items-center lg:items-start gap-4 lg:gap-0 flex-shrink-0">
                <div
                  className="w-12 h-12 rounded-xl flex items-center justify-center text-sm font-bold terminal-text flex-shrink-0"
                  style={{
                    background: "var(--color-accent-glow)",
                    color: "var(--color-accent)",
                    border: "1px solid rgba(0,229,160,0.2)",
                  }}
                  aria-hidden="true"
                >
                  {step.number}
                </div>
                {i < steps.length - 1 && (
                  <div
                    className="hidden lg:block w-px mt-3 flex-1"
                    style={{
                      height: "80px",
                      background:
                        "linear-gradient(to bottom, rgba(0,229,160,0.3), transparent)",
                      marginLeft: "23px",
                    }}
                    aria-hidden="true"
                  />
                )}
              </div>

              {/* Content */}
              <div className="flex-1 min-w-0">
                <h3 className="text-xl font-semibold text-[var(--color-text)] mb-3">
                  {step.title}
                </h3>
                <p className="text-[var(--color-text-muted)] leading-relaxed mb-6 max-w-lg">
                  {step.description}
                </p>

                {/* Code block */}
                <div
                  className="rounded-xl overflow-hidden glow-border"
                  style={{ background: "#0a0f14" }}
                  role="region"
                  aria-label={`Code for step ${step.number}`}
                >
                  {/* Code title bar */}
                  <div
                    className="flex items-center gap-2 px-4 py-2.5 border-b border-[var(--color-border)]"
                    style={{ background: "var(--color-surface)" }}
                    aria-hidden="true"
                  >
                    <span className="w-2.5 h-2.5 rounded-full bg-[#ff5f57]" />
                    <span className="w-2.5 h-2.5 rounded-full bg-[#febc2e]" />
                    <span className="w-2.5 h-2.5 rounded-full bg-[#28c840]" />
                    <span
                      className="ml-2 text-xs terminal-text"
                      style={{ color: "var(--color-text-subtle)" }}
                    >
                      bash
                    </span>
                  </div>

                  {/* Code lines */}
                  <div className="p-5 code-block">
                    {step.commands.map((c, j) => (
                      <div key={j} className="mb-1">
                        {c.comment && (
                          <div
                            className="text-xs mb-0.5"
                            style={{ color: "var(--color-text-subtle)" }}
                          >
                            {c.comment}
                          </div>
                        )}
                        {c.isOutput ? (
                          <pre
                            className="text-xs leading-relaxed whitespace-pre"
                            style={{ color: "var(--color-text-muted)" }}
                          >
                            {c.cmd}
                          </pre>
                        ) : (
                          <div className="flex items-start gap-2">
                            <span
                              className="select-none flex-shrink-0"
                              style={{ color: "var(--color-accent)" }}
                              aria-hidden="true"
                            >
                              $
                            </span>
                            <code
                              className="text-[var(--color-text)] break-all"
                              style={{ fontSize: "0.875rem" }}
                            >
                              {c.cmd}
                            </code>
                          </div>
                        )}
                        {j < step.commands.length - 1 && (
                          <div className="h-2" aria-hidden="true" />
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}
