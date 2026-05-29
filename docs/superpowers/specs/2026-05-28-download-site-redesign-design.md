# Download Site Redesign — Design Spec

Date: 2026-05-28
Component: `download-site/` (Next.js landing page for the Personal Env macOS app)

## Problem

The current landing page (`download-site/app/page.tsx` + `globals.css`) is a dark,
glassy "liquid glass" marketing page with neon gradients, frosted translucent cards,
3D card tilt, and mouse-tracking light. It reads as a generic SaaS site and looks
nothing like the actual product — a calm, light, warm-neutral native macOS utility.
That mismatch undermines trust for a security tool whose whole pitch is "local,
private, precise."

## Goal

A **conversion-first, single-page** site: a developer lands, trusts it within seconds,
and downloads the DMG. The site should look like it came from the same studio as the
app, and let the real product UI do the selling. Minimal scroll; the Download action
is always reachable.

## Direction

Match the app's look (the "Acme Web App" product screen), with three user-directed
deviations from `DESIGN.md`:

1. **Pure white** surfaces — not the warm off-white the app uses.
2. **macOS system blue `#0a84ff`** as the accent (primary action, brand mark,
   selection, section labels) — not the app's deep teal.
3. **Keep a subtle pointer-following light** animation on headline + buttons, but
   **remove all glassy/frosted/3D-tilt treatment**. Surfaces are solid and clean.

These overrides take precedence over `DESIGN.md` for the website only; the native app
keeps its own (warm, teal) system.

## Visual System

- **Surfaces:** background `#ffffff`; subtle panels `#f7f8fa` / `#fafbfc`; hairlines
  `#ececf0` and `#f0f0f4`.
- **Text:** ink `#16181d`; muted `#5b6170`; soft/meta `#9298a6`.
- **Accent:** `#0a84ff` for Download button, brand mark, selected vault row, and
  uppercase monospace section labels. Soft blue glow under the primary CTA
  (`box-shadow: 0 6px 16px rgba(10,132,255,.28)`) and a faint blue radial wash behind
  the hero.
- **Scope/data colors** (kept — they are data, matching the app): Production red
  `#c0392b`, Staging amber `#b8860b`, Development green `#1e7a46`.
- **Typography:** system sans (`ui-sans-serif, -apple-system, …`) for prose and
  headings; **monospace (`ui-monospace`) only** for keys, masked values, scopes, the
  CLI block, the version/meta line, and section eyebrow labels.
- **Shape:** rounded 8–14px. Panels + dividers + table density. **No nested cards.**
- **Motion:** a soft pointer-following light highlight on the headline and primary
  buttons (carried over from the existing `moveTextLight` handler). No 3D tilt, no
  frosted glass, no decorative page-load animation. Respect `prefers-reduced-motion`.

## Page Structure (top to bottom, single scroll)

1. **Top bar** — brand (blue rounded-square mark + "Personal Env"); right side:
   Features, CLI, GitHub links, and a blue **Download** button. Sticky is optional;
   default non-sticky.
2. **Hero** (two-column on desktop, stacked on mobile):
   - Left: monospace eyebrow `macOS · App + CLI`; headline "Your .env files, locked
     in the Keychain."; one-line subcopy; primary **Download for macOS** + secondary
     **View source**; a meta line `Apple-notarized · macOS 13+ · penv CLI included`.
   - Right: the **Acme Web App product window** rendered in the product's style —
     traffic lights + "Acme Web App" titlebar, a vault sidebar (Acme Web App selected,
     plus Acme Mobile / Infrastructure / Data Pipeline), and a masked secrets table
     (KEY / VALUE / SCOPE) with the scope badge colors, footer row
     "+ New Variable · 7 variables · Unlocked". Solid panel, soft drop shadow, no frost.
3. **Trust strip** — a 4-up row bounded by hairlines (no cards): **Keychain-backed**,
   **Device auth** (Touch ID on every read), **No network** (no account, no telemetry),
   **CLI included** (penv ships in the DMG). Each: bold label + muted one-liner.
4. **CLI section** — monospace eyebrow "The penv CLI"; heading "Same vault, from your
   terminal."; one **dark terminal block** (`#14161b`) showing a real `penv import` /
   `penv export --scope production` flow with success lines and a "(Touch ID confirmed)"
   note. This is the only dark element on the page, used deliberately.
5. **Footer** — minimal, monospace: `Personal Env v1.0` · GitHub · MIT · Made for macOS.

## Content / Data

- Download URL stays `/downloads/Personal-Env-macOS.dmg` (existing `downloadUrl`).
- Source/Docs link stays `https://github.com/lordboba/personal-env`.
- The product-window secrets reuse the existing `secrets` list, themed to the
  "Acme Web App" vault. Sidebar vault names are illustrative (Acme Web App, Acme
  Mobile, Infrastructure, Data Pipeline).
- All values are masked (`••••••••`). No real secrets in markup.

## Implementation Notes

- Rewrite `download-site/app/page.tsx` and `download-site/app/globals.css`. Keep the
  Next.js app-router structure and `layout.tsx` metadata (update description if needed).
- Remove: `color-scheme: dark`, dark gradients/scanlines, `.liquidPane` / `.glass` /
  `moveGlass` 3D-tilt logic, frosted backgrounds, neon gradient text.
- Keep: a trimmed `moveTextLight` pointer-light effect on headline + primary buttons,
  gated behind `prefers-reduced-motion`.
- `color-scheme: light`. The CLI terminal block is locally dark via explicit colors,
  not a global theme.
- Responsive: hero collapses to single column below ~860px; trust strip wraps to 2×2;
  product window scales down but stays legible.
- Accessibility: visible focus rings on links/buttons; AA contrast on muted text
  against white; the product window is decorative (`aria-hidden`) with the real value
  prop in the text column.

## Out of Scope (YAGNI)

- Dark mode toggle, additional marketing pages, blog/changelog, analytics, animations
  beyond the pointer-light, screenshots gallery/carousel, pricing.

## Success Criteria

- Page visually reads as the same product family as the app screenshot.
- Download is reachable in the top bar and hero without scrolling.
- No glass/frost/3D-tilt anywhere; surfaces are solid white with hairline structure.
- Accent is `#0a84ff`; monospace is confined to keys/scopes/CLI/meta.
- Works at desktop and mobile widths; honors reduced-motion.
