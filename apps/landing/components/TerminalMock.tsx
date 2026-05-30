export default function TerminalMock() {
  const lines = [
    { type: "prompt", text: "~ nudge daemon start" },
    { type: "output", text: "✓ Nudge daemon running (pid 48291)" },
    { type: "output", text: "✓ PTY pool ready · 4 tabs available" },
    { type: "output", text: "⟳ Waiting for phone connection..." },
    { type: "blank", text: "" },
    { type: "prompt", text: "~ claude" },
    { type: "agent", text: "Claude Code v1.2.1 — ready" },
    { type: "output", text: "◆ Task: Refactor auth module" },
    { type: "output-dim", text: "  Reading src/auth/index.ts..." },
    { type: "output-dim", text: "  Analyzing 847 lines..." },
    { type: "agent-accent", text: "  ✎ Writing src/auth/jwt.ts" },
    { type: "output-dim", text: "  Running tests..." },
    { type: "success", text: "  ✓ 42 tests passed in 1.8s" },
    { type: "blank", text: "" },
    { type: "prompt-active", text: "~ _" },
  ];

  return (
    <div className="relative w-full max-w-[520px]">
      {/* Glow backdrop */}
      <div
        className="absolute -inset-4 rounded-2xl opacity-40"
        style={{
          background:
            "radial-gradient(ellipse at 50% 80%, rgba(0,229,160,0.18), transparent 70%)",
        }}
        aria-hidden="true"
      />

      {/* Terminal window */}
      <div className="relative rounded-xl overflow-hidden glow-border-accent">
        {/* Title bar */}
        <div
          className="flex items-center gap-2 px-4 py-3 border-b border-[var(--color-border)]"
          style={{ background: "var(--color-surface)" }}
        >
          {/* Traffic lights */}
          <span className="w-3 h-3 rounded-full bg-[#ff5f57]" aria-hidden="true" />
          <span className="w-3 h-3 rounded-full bg-[#febc2e]" aria-hidden="true" />
          <span className="w-3 h-3 rounded-full bg-[#28c840]" aria-hidden="true" />
          <span
            className="ml-auto text-xs text-[var(--color-text-subtle)] terminal-text"
            aria-label="Terminal window title"
          >
            nudge — bash
          </span>
        </div>

        {/* Terminal body */}
        <div
          className="p-4 terminal-text text-sm leading-relaxed"
          style={{ background: "#0a0f14", minHeight: "280px" }}
          role="region"
          aria-label="Terminal output"
        >
          {lines.map((line, i) => {
            if (line.type === "blank") return <div key={i} className="h-2" />;

            const colorMap: Record<string, string> = {
              prompt: "var(--color-accent)",
              "prompt-active": "var(--color-accent)",
              output: "var(--color-text-muted)",
              "output-dim": "var(--color-text-subtle)",
              agent: "#60a5fa",
              "agent-accent": "var(--color-accent)",
              success: "#4ade80",
            };

            const color = colorMap[line.type] || "var(--color-text-muted)";

            return (
              <div key={i} className="flex items-start gap-0" aria-hidden={line.type === "blank"}>
                {line.type === "prompt" || line.type === "prompt-active" ? (
                  <span style={{ color: "var(--color-accent)" }} className="select-none">
                    {"$ "}
                  </span>
                ) : null}
                <span style={{ color }} className="break-all">
                  {line.type === "prompt" || line.type === "prompt-active"
                    ? line.text.replace(/^~ /, "")
                    : line.text}
                </span>
                {line.type === "prompt-active" && (
                  <span
                    className="inline-block w-2 h-4 ml-0.5 bg-[var(--color-accent)] cursor-blink"
                    aria-hidden="true"
                  />
                )}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
