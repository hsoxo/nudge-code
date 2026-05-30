# Nudge Landing Page

Marketing landing page for [Nudge](https://nudgecode.dev) — a local-first, phone-first remote shell for developers.

## Local development

```bash
cd apps/landing
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Production build

```bash
cd apps/landing
npm install
npm run build
```

The build output is in `out/` (static export via `next export`).

## Deploy to Vercel

[![Deploy with Vercel](https://vercel.com/button)](https://vercel.com/new/clone?repository-url=https://github.com/TODO/nudge&root-directory=apps/landing)

**Manual deploy steps:**

1. Push the repo to GitHub (or connect an existing repo).
2. In the Vercel dashboard, click **Add New Project**.
3. Import the repository.
4. Set **Root Directory** to `apps/landing`.
5. Framework preset: **Next.js** (auto-detected).
6. Click **Deploy**.

No environment variables are required — this is a fully static marketing page.

## Tech stack

- [Next.js 15](https://nextjs.org) (App Router, static export)
- [React 19](https://react.dev)
- [TypeScript](https://typescriptlang.org)
- [Tailwind CSS v4](https://tailwindcss.com)
- [Geist font](https://vercel.com/font) (sans + mono)
- [lucide-react](https://lucide.dev) (icons)

## Structure

```
apps/landing/
├── app/
│   ├── globals.css       # Tailwind + custom CSS variables + animations
│   ├── layout.tsx        # Root layout with metadata and fonts
│   └── page.tsx          # Main page (composes all sections)
├── components/
│   ├── Nav.tsx           # Sticky nav with mobile hamburger
│   ├── Hero.tsx          # Hero section with terminal + phone mockup
│   ├── TerminalMock.tsx  # Desktop terminal window visual
│   ├── PhoneMock.tsx     # iPhone frame visual
│   ├── TrustStrip.tsx    # Trust badges strip
│   ├── Features.tsx      # Feature grid (6 cards)
│   ├── HowItWorks.tsx    # 3-step how it works with code blocks
│   ├── Security.tsx      # Security section with crypto stack
│   ├── Pricing.tsx       # Free + Pro/Coming soon tiers
│   ├── FAQ.tsx           # Accordion FAQ
│   ├── CTA.tsx           # Final call to action band
│   └── Footer.tsx        # Footer with links
├── public/
│   └── favicon.svg
├── next.config.ts
├── postcss.config.mjs
├── tailwind.config (via @theme in globals.css)
├── tsconfig.json
└── package.json
```

## TODO placeholders

Links marked `#TODO-*` need to be updated when the following are ready:

- `#TODO-github` → GitHub repository URL
- `#TODO-docs` → Documentation URL
- `#TODO-waitlist` → Waitlist form URL
- `#TODO-changelog` → Changelog page
- `#TODO-privacy` → Privacy policy
- `#TODO-terms` → Terms of service
- `#TODO-github-releases` → GitHub releases
- `#TODO-github-issues` → GitHub issues
