"use client";

import { useState } from "react";

const faqs = [
  {
    q: "What does 'local-first' mean?",
    a: "It means your data never has to leave infrastructure you control. You run the relay — on your Mac, a VPS, or a home server. Nudge never sends your terminal output to a third-party service. A managed hosted relay is coming soon for those who prefer convenience, but it will always be opt-in.",
  },
  {
    q: "Can the relay read my terminal?",
    a: "No. The relay is a blind router. All data between your computer and your iPhone is encrypted with ChaCha20-Poly1305 before it ever reaches the relay. The relay sees only sealed ciphertext and has no access to the decryption keys, which are derived end-to-end between your devices using X25519 key exchange.",
  },
  {
    q: "Which phones and iOS versions are supported?",
    a: "Nudge requires iOS 17 or later and is optimized for iPhone 13 and newer. iPad support is not planned for the initial release.",
  },
  {
    q: "Which AI agents and CLIs work with Nudge?",
    a: "Any CLI that runs in a terminal works with Nudge — it operates at the PTY level, so there's nothing agent-specific to configure. Claude Code, Codex, Aider, Cursor background agents, and standard shells (bash, zsh, fish) all work out of the box.",
  },
  {
    q: "Do I need to host anything to get started?",
    a: "Yes — in the current free tier you run the relay yourself. This is a one-liner: the nudge CLI includes the relay server. A hosted option where you don't manage any infrastructure is on the roadmap.",
  },
  {
    q: "Is there a free tier, and what are its limits?",
    a: "Yes. The free tier supports one computer and one active terminal tab. Sessions, commands, and data transfer are unlimited. There are no time limits or paywalls on the free tier.",
  },
];

function FAQItem({ q, a }: { q: string; a: string }) {
  const [open, setOpen] = useState(false);
  const id = `faq-${q.slice(0, 20).replace(/\s+/g, "-").toLowerCase()}`;

  return (
    <div className="border-b border-[var(--color-border)] last:border-0">
      <button
        type="button"
        aria-expanded={open}
        aria-controls={id}
        onClick={() => setOpen((v) => !v)}
        className="w-full flex items-center justify-between gap-4 py-5 text-left text-[var(--color-text)] hover:text-[var(--color-accent)] transition-colors duration-150 group"
      >
        <span className="text-sm sm:text-base font-medium">{q}</span>
        <svg
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          className={`flex-shrink-0 transition-transform duration-200 ${open ? "rotate-45" : ""}`}
          style={{ color: open ? "var(--color-accent)" : "var(--color-text-muted)" }}
          aria-hidden="true"
        >
          <line x1="12" y1="5" x2="12" y2="19" />
          <line x1="5" y1="12" x2="19" y2="12" />
        </svg>
      </button>

      <div
        id={id}
        role="region"
        aria-label={q}
        className={`overflow-hidden transition-all duration-300 ${open ? "max-h-96" : "max-h-0"}`}
      >
        <p className="pb-5 text-sm text-[var(--color-text-muted)] leading-relaxed">
          {a}
        </p>
      </div>
    </div>
  );
}

export default function FAQ() {
  return (
    <section
      id="faq"
      className="py-24 md:py-32 border-t border-[var(--color-border)]"
      aria-labelledby="faq-heading"
    >
      <div className="max-w-3xl mx-auto px-4 sm:px-6">
        <div className="text-center mb-14">
          <p
            className="text-xs font-semibold tracking-widest uppercase mb-4 terminal-text"
            style={{ color: "var(--color-accent)" }}
          >
            FAQ
          </p>
          <h2
            id="faq-heading"
            className="text-3xl sm:text-4xl font-bold tracking-tight text-[var(--color-text)]"
          >
            Frequently asked questions
          </h2>
        </div>

        <div
          className="rounded-2xl overflow-hidden glow-border"
          style={{ background: "var(--color-surface)" }}
        >
          <div className="px-6 sm:px-8">
            {faqs.map((faq) => (
              <FAQItem key={faq.q} q={faq.q} a={faq.a} />
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
