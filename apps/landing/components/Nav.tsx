"use client";

import { useState, useEffect } from "react";
import { Menu, X } from "lucide-react";

const navLinks = [
  { href: "#features", label: "Features" },
  { href: "#how-it-works", label: "How it works" },
  { href: "#security", label: "Security" },
  { href: "#pricing", label: "Pricing" },
  { href: "#faq", label: "FAQ" },
];

function NudgeLogo() {
  return (
    <a href="#" className="flex items-center gap-2.5 group" aria-label="Nudge home">
      {/* SVG mark: a terminal prompt arrow inside a rounded square */}
      <svg
        width="28"
        height="28"
        viewBox="0 0 28 28"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        className="flex-shrink-0"
        aria-hidden="true"
      >
        <rect width="28" height="28" rx="7" fill="var(--color-accent)" />
        <path
          d="M7 10L12 14L7 18"
          stroke="#080b0f"
          strokeWidth="2.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <line
          x1="14"
          y1="18"
          x2="21"
          y2="18"
          stroke="#080b0f"
          strokeWidth="2.5"
          strokeLinecap="round"
        />
      </svg>
      <span
        className="text-lg font-semibold tracking-tight text-[var(--color-text)] group-hover:text-[var(--color-accent)] transition-colors duration-200"
        style={{ fontFamily: "var(--font-sans)" }}
      >
        Nudge
      </span>
    </a>
  );
}

export default function Nav() {
  const [scrolled, setScrolled] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);

  useEffect(() => {
    const handler = () => setScrolled(window.scrollY > 20);
    window.addEventListener("scroll", handler, { passive: true });
    return () => window.removeEventListener("scroll", handler);
  }, []);

  // Close mobile menu on route change / resize
  useEffect(() => {
    const handler = () => {
      if (window.innerWidth >= 768) setMobileOpen(false);
    };
    window.addEventListener("resize", handler);
    return () => window.removeEventListener("resize", handler);
  }, []);

  const handleMobileLink = () => setMobileOpen(false);

  return (
    <>
      <header
        role="banner"
        className={`fixed top-0 left-0 right-0 z-50 transition-all duration-300 ${
          scrolled
            ? "bg-[var(--color-bg)]/95 backdrop-blur-md border-b border-[var(--color-border)]"
            : "bg-transparent"
        }`}
      >
        <nav
          className="max-w-6xl mx-auto px-4 sm:px-6 h-16 flex items-center justify-between"
          aria-label="Main navigation"
        >
          <NudgeLogo />

          {/* Desktop links */}
          <ul className="hidden md:flex items-center gap-1" role="list">
            {navLinks.map((link) => (
              <li key={link.href}>
                <a
                  href={link.href}
                  className="px-3 py-1.5 text-sm text-[var(--color-text-muted)] hover:text-[var(--color-text)] transition-colors duration-150 rounded-md hover:bg-[var(--color-surface-2)]"
                >
                  {link.label}
                </a>
              </li>
            ))}
          </ul>

          {/* Desktop CTA */}
          <div className="hidden md:flex items-center gap-3">
            <a
              href="#pricing"
              className="px-4 py-2 text-sm font-medium rounded-lg bg-[var(--color-accent)] text-[#080b0f] hover:bg-[var(--color-accent-dim)] transition-colors duration-150"
            >
              Get started
            </a>
          </div>

          {/* Mobile hamburger */}
          <button
            type="button"
            className="md:hidden p-2 rounded-md text-[var(--color-text-muted)] hover:text-[var(--color-text)] hover:bg-[var(--color-surface-2)] transition-colors"
            aria-label={mobileOpen ? "Close menu" : "Open menu"}
            aria-expanded={mobileOpen}
            aria-controls="mobile-menu"
            onClick={() => setMobileOpen((v) => !v)}
          >
            {mobileOpen ? <X size={20} /> : <Menu size={20} />}
          </button>
        </nav>

        {/* Mobile menu */}
        {mobileOpen && (
          <div
            id="mobile-menu"
            className="md:hidden border-t border-[var(--color-border)] bg-[var(--color-bg)]/98 backdrop-blur-md"
            style={{ animation: "slide-down 0.2s ease-out" }}
          >
            <ul className="flex flex-col px-4 py-3 gap-1" role="list">
              {navLinks.map((link) => (
                <li key={link.href}>
                  <a
                    href={link.href}
                    onClick={handleMobileLink}
                    className="block px-3 py-2.5 text-sm text-[var(--color-text-muted)] hover:text-[var(--color-text)] rounded-md hover:bg-[var(--color-surface-2)] transition-colors"
                  >
                    {link.label}
                  </a>
                </li>
              ))}
            </ul>
            <div className="px-4 pb-4">
              <a
                href="#pricing"
                onClick={handleMobileLink}
                className="block w-full text-center px-4 py-2.5 text-sm font-medium rounded-lg bg-[var(--color-accent)] text-[#080b0f] hover:bg-[var(--color-accent-dim)] transition-colors"
              >
                Get started
              </a>
            </div>
          </div>
        )}
      </header>
    </>
  );
}
