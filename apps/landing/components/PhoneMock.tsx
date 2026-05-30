export default function PhoneMock() {
  const lines = [
    { color: "#00e5a0", text: "$ nudge daemon start" },
    { color: "#8b949e", text: "✓ daemon ready (pid 48291)" },
    { color: "#8b949e", text: "✓ phone connected" },
    { color: "#ffffff", text: "" },
    { color: "#00e5a0", text: "$ claude" },
    { color: "#60a5fa", text: "Claude Code v1.2.1" },
    { color: "#8b949e", text: "◆ Refactor auth module" },
    { color: "#484f58", text: "  Reading files..." },
    { color: "#484f58", text: "  Analyzing code..." },
    { color: "#00e5a0", text: "  ✎ Writing jwt.ts" },
    { color: "#4ade80", text: "  ✓ 42 tests passed" },
    { color: "#ffffff", text: "" },
    { color: "#00e5a0", text: "$ _" },
  ];

  return (
    <div className="relative">
      {/* Glow */}
      <div
        className="absolute -inset-6 rounded-full opacity-30"
        style={{
          background:
            "radial-gradient(ellipse, rgba(0,229,160,0.25), transparent 70%)",
          filter: "blur(20px)",
        }}
        aria-hidden="true"
      />

      {/* Phone frame */}
      <div
        className="relative w-[160px] rounded-[32px] overflow-hidden"
        style={{
          border: "2px solid var(--color-border-bright)",
          boxShadow:
            "0 0 0 1px rgba(0,229,160,0.15), 0 32px 64px rgba(0,0,0,0.6), inset 0 1px 0 rgba(255,255,255,0.08)",
          background: "#0d1117",
        }}
        role="img"
        aria-label="iPhone showing Nudge terminal app"
      >
        {/* Status bar */}
        <div
          className="flex items-center justify-between px-4 py-2 text-[10px]"
          style={{
            background: "#080b0f",
            color: "var(--color-text-muted)",
            fontFamily: "var(--font-mono)",
          }}
          aria-hidden="true"
        >
          <span>9:41</span>
          {/* Dynamic Island notch */}
          <div
            className="w-16 h-4 rounded-full"
            style={{ background: "#000", transform: "translateY(-2px)" }}
          />
          <span>●●●</span>
        </div>

        {/* App header */}
        <div
          className="flex items-center justify-between px-3 py-1.5 border-b"
          style={{
            background: "#0d1117",
            borderColor: "var(--color-border)",
          }}
          aria-hidden="true"
        >
          <div className="flex gap-1">
            <div
              className="px-2 py-0.5 rounded text-[9px] font-medium"
              style={{
                background: "rgba(0,229,160,0.15)",
                color: "var(--color-accent)",
                fontFamily: "var(--font-mono)",
              }}
            >
              bash
            </div>
          </div>
          <div
            className="w-1.5 h-1.5 rounded-full animate-glow-pulse"
            style={{ background: "var(--color-accent)" }}
          />
        </div>

        {/* Terminal area */}
        <div
          className="px-3 py-2 overflow-hidden"
          style={{
            background: "#080b0f",
            minHeight: "200px",
            fontFamily: "var(--font-mono)",
            fontSize: "9px",
            lineHeight: "1.6",
          }}
          aria-hidden="true"
        >
          {lines.map((line, i) => (
            <div key={i} style={{ color: line.color }}>
              {line.text || " "}
              {i === lines.length - 1 && (
                <span
                  className="inline-block w-1.5 h-3 cursor-blink"
                  style={{
                    background: "var(--color-accent)",
                    marginLeft: "1px",
                    verticalAlign: "middle",
                  }}
                />
              )}
            </div>
          ))}
        </div>

        {/* Home indicator */}
        <div
          className="flex justify-center py-2"
          style={{ background: "#080b0f" }}
          aria-hidden="true"
        >
          <div
            className="w-20 h-1 rounded-full"
            style={{ background: "var(--color-border-bright)" }}
          />
        </div>
      </div>
    </div>
  );
}
