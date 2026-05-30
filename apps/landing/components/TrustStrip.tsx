const items = [
  {
    icon: (
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>
        <path d="M7 11V7a5 5 0 0 1 10 0v4"/>
      </svg>
    ),
    label: "End-to-end encrypted",
  },
  {
    icon: (
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>
        <polyline points="9 22 9 12 15 12 15 22"/>
      </svg>
    ),
    label: "Local-first · your relay, your data",
  },
  {
    icon: (
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <polyline points="4 17 10 11 4 5"/>
        <line x1="12" y1="19" x2="20" y2="19"/>
      </svg>
    ),
    label: "Works with any CLI",
  },
];

export default function TrustStrip() {
  return (
    <section
      className="border-y border-[var(--color-border)]"
      style={{ background: "var(--color-surface)" }}
      aria-label="Key guarantees"
    >
      <div className="max-w-6xl mx-auto px-4 sm:px-6 py-5">
        <ul
          className="flex flex-col sm:flex-row items-center justify-center gap-6 sm:gap-10 md:gap-16"
          role="list"
        >
          {items.map((item, i) => (
            <li
              key={i}
              className="flex items-center gap-2.5 text-sm font-medium"
              style={{ color: "var(--color-text-muted)" }}
            >
              <span style={{ color: "var(--color-accent)" }}>{item.icon}</span>
              {item.label}
              {i < items.length - 1 && (
                <span
                  className="hidden sm:block ml-10 w-px h-4 opacity-30"
                  style={{ background: "var(--color-border-bright)" }}
                  aria-hidden="true"
                />
              )}
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
