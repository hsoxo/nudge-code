const primitives = [
  { name: "X25519", role: "Key agreement — ephemeral session keys" },
  { name: "HKDF-SHA256", role: "Key derivation from shared secret" },
  { name: "ChaCha20-Poly1305", role: "Authenticated encryption of all terminal data" },
  { name: "Ed25519", role: "Signs handshake transcripts — prevents MITM" },
];

export default function Security() {
  return (
    <section
      id="security"
      className="py-24 md:py-32 border-t border-[var(--color-border)]"
      aria-labelledby="security-heading"
    >
      <div className="max-w-6xl mx-auto px-4 sm:px-6">
        <div className="flex flex-col lg:flex-row gap-16 lg:gap-24 items-start">
          {/* Left: text */}
          <div className="flex-1 max-w-xl">
            <p
              className="text-xs font-semibold tracking-widest uppercase mb-4 terminal-text"
              style={{ color: "var(--color-accent)" }}
            >
              Security
            </p>
            <h2
              id="security-heading"
              className="text-3xl sm:text-4xl font-bold tracking-tight text-[var(--color-text)] mb-6"
            >
              The relay is{" "}
              <span style={{ color: "var(--color-accent)" }}>blind</span>{" "}
              by design
            </h2>
            <div
              className="text-[var(--color-text-muted)] leading-relaxed space-y-4 mb-10"
            >
              <p>
                Nudge's relay is a dumb router. It shuttles encrypted packets
                between your computer and your phone without ever possessing a
                decryption key. Even if the relay were fully compromised, an
                attacker would see only sealed ciphertext.
              </p>
              <p>
                Keys are derived fresh for each session using X25519 elliptic
                curve Diffie-Hellman. Terminal data is encrypted with
                ChaCha20-Poly1305, authenticated encryption that detects any
                tampering in transit. The Ed25519-signed WebSocket challenge
                prevents relay impersonation entirely.
              </p>
              <p>
                And because Nudge is local-first, you can run your own relay.
                Your data stays on infrastructure you control.
              </p>
            </div>

            {/* Local-first callout */}
            <div
              className="rounded-xl p-5 glow-border flex gap-4 items-start"
              style={{ background: "var(--color-accent-glow-sm)" }}
            >
              <div
                className="mt-0.5 flex-shrink-0"
                style={{ color: "var(--color-accent)" }}
                aria-hidden="true"
              >
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>
                  <polyline points="9 22 9 12 15 12 15 22"/>
                </svg>
              </div>
              <div>
                <p className="text-sm font-semibold text-[var(--color-text)] mb-1">
                  Local-first guarantee
                </p>
                <p className="text-sm text-[var(--color-text-muted)] leading-relaxed">
                  Nudge is not a SaaS. Run the relay on your Mac, a VPS, or
                  your home server. A managed hosted option is coming soon for
                  those who prefer it.
                </p>
              </div>
            </div>
          </div>

          {/* Right: crypto table */}
          <div className="flex-1 w-full max-w-md">
            <div
              className="rounded-xl overflow-hidden glow-border"
              role="region"
              aria-label="Cryptographic primitives used by Nudge"
            >
              {/* Header */}
              <div
                className="px-5 py-3 border-b border-[var(--color-border)]"
                style={{ background: "var(--color-surface)" }}
              >
                <span
                  className="text-xs font-semibold terminal-text tracking-wider uppercase"
                  style={{ color: "var(--color-text-subtle)" }}
                >
                  Cryptographic stack
                </span>
              </div>

              {/* Primitives */}
              <ul role="list">
                {primitives.map((p, i) => (
                  <li
                    key={i}
                    className="flex items-start gap-4 px-5 py-4 border-b border-[var(--color-border)] last:border-0"
                    style={{ background: i % 2 === 0 ? "var(--color-surface)" : "var(--color-bg)" }}
                  >
                    <code
                      className="flex-shrink-0 text-sm font-bold terminal-text px-2 py-0.5 rounded"
                      style={{
                        color: "var(--color-accent)",
                        background: "var(--color-accent-glow-sm)",
                        border: "1px solid rgba(0,229,160,0.15)",
                        minWidth: "140px",
                      }}
                    >
                      {p.name}
                    </code>
                    <span className="text-sm text-[var(--color-text-muted)] leading-relaxed">
                      {p.role}
                    </span>
                  </li>
                ))}
              </ul>

              {/* Footer note */}
              <div
                className="px-5 py-3 border-t border-[var(--color-border)]"
                style={{ background: "var(--color-surface-2)" }}
              >
                <p className="text-xs text-[var(--color-text-subtle)] terminal-text">
                  Relay sees: ciphertext only · No keys ever leave your devices
                </p>
              </div>
            </div>

            {/* Architecture diagram (text-based) */}
            <div
              className="mt-6 rounded-xl p-5 glow-border terminal-text text-xs leading-loose"
              style={{ background: "#0a0f14", color: "var(--color-text-muted)" }}
              role="img"
              aria-label="Architecture: Computer daemon connects through encrypted relay to iPhone app"
            >
              <div className="flex items-center justify-between gap-2 flex-wrap">
                <div
                  className="flex flex-col items-center gap-1 px-3 py-2 rounded-lg"
                  style={{ background: "var(--color-surface)", border: "1px solid var(--color-border)" }}
                >
                  <span style={{ color: "var(--color-accent)" }}>⬛</span>
                  <span className="text-[10px]">Your Mac</span>
                  <span className="text-[10px]" style={{ color: "var(--color-text-subtle)" }}>nudge daemon</span>
                </div>
                <div className="flex flex-col items-center gap-0.5 text-center">
                  <span style={{ color: "var(--color-accent)" }}>── E2E ──▶</span>
                  <span className="text-[10px]" style={{ color: "var(--color-text-subtle)" }}>ChaCha20</span>
                </div>
                <div
                  className="flex flex-col items-center gap-1 px-3 py-2 rounded-lg"
                  style={{ background: "var(--color-surface-2)", border: "1px solid var(--color-border)" }}
                >
                  <span style={{ color: "var(--color-text-subtle)" }}>▣</span>
                  <span className="text-[10px]">Relay</span>
                  <span className="text-[10px]" style={{ color: "var(--color-text-subtle)" }}>blind router</span>
                </div>
                <div className="flex flex-col items-center gap-0.5 text-center">
                  <span style={{ color: "var(--color-accent)" }}>── E2E ──▶</span>
                  <span className="text-[10px]" style={{ color: "var(--color-text-subtle)" }}>ChaCha20</span>
                </div>
                <div
                  className="flex flex-col items-center gap-1 px-3 py-2 rounded-lg"
                  style={{ background: "var(--color-surface)", border: "1px solid var(--color-border)" }}
                >
                  <span style={{ color: "var(--color-accent)" }}>📱</span>
                  <span className="text-[10px]">iPhone</span>
                  <span className="text-[10px]" style={{ color: "var(--color-text-subtle)" }}>Nudge app</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
