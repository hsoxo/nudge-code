import type { Metadata } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://nudgecode.dev"),
  title: "Nudge — Your Terminal, In Your Pocket",
  description:
    "A local-first, phone-first remote shell for developers. Drive your computer's terminal from your iPhone. Purpose-built for babysitting AI coding agents like Claude Code and Codex.",
  keywords: [
    "remote terminal",
    "iPhone terminal",
    "AI agent monitoring",
    "Claude Code",
    "Codex",
    "developer tool",
    "local-first",
    "end-to-end encrypted",
  ],
  authors: [{ name: "Nudge" }],
  openGraph: {
    title: "Nudge — Your Terminal, In Your Pocket",
    description:
      "Drive your computer's terminal from your iPhone. Built for developers who babysit AI agents from anywhere.",
    url: "https://nudgecode.dev",
    siteName: "Nudge",
    type: "website",
    locale: "en_US",
  },
  twitter: {
    card: "summary_large_image",
    title: "Nudge — Your Terminal, In Your Pocket",
    description:
      "Drive your computer's terminal from your iPhone. Built for developers who babysit AI agents from anywhere.",
  },
  robots: {
    index: true,
    follow: true,
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html
      lang="en"
      className={`${GeistSans.variable} ${GeistMono.variable}`}
    >
      <head>
        <link rel="icon" href="/favicon.svg" type="image/svg+xml" />
      </head>
      <body className="antialiased">{children}</body>
    </html>
  );
}
