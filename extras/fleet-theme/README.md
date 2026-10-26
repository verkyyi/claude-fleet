# fleet-theme — ClaudeFleet's one look

The website (`/`, `/en/`), the docs (`/docs/`, `/en/docs/`), the web chat (`/chat/`) and the console take colour,
type, radius, spacing and the logo from this package and nowhere else (issue
#3924, EPIC #3923). `bin/fleet-theme-selftest.sh` reds on a theme colour, a theme
font family or a logo defined outside it.

| File | What |
|---|---|
| `theme.css` | the entry: `fleet:tokens` (the `--fleet-*` design variables) · the shadcn/ui tokens, light and dark · Tailwind v4 `@theme` · base layer |
| `fonts.css` | `@font-face` for the three families, `url(./fonts/…)` |
| `fonts/` | the served Latin subsets (woff2) + their OFL licences — cut, never edited |
| `fonts-src/` | the fonts as published + `glyphs.txt`, the characters the cut keeps |
| `logo.svg` | the icon: a white Pac-Man on a clay tile — favicon, app and home-screen icons only |
| `wordmark.svg` | the brand as people read it: 「tokenman」, lowercase, geometric, every letter one height; its o is the clay Pac-Man, the letters `currentColor` (ink when used as an image) — every header and the share card |

## How each consumer takes it

- **Website** — `bin/site-build.sh` inlines `fonts.css` and the `fleet:tokens`
  block into `site/template.html`'s `/*{{fleet_theme}}*/` slot (font URLs become
  `/site/fonts/…`), fills `{{fleet_bg}}` (theme-color), and copies `fonts/` and
  `logo.svg` / `wordmark.svg` out; the header and the demo `<use>` the wordmark as a symbol. The site is dark only and uses the `--fleet-*` variables directly.
- **Web chat, console** (Tailwind v4 + shadcn/ui) — after `@import "tailwindcss";`,
  `@import "<relative path>/extras/fleet-theme/theme.css";`. Vite bundles the
  fonts; use the shadcn classes (`bg-background`, `text-muted-foreground`, …) and
  `font-display` / `font-mono`. Light and dark follow the system.
- **Docs** — `bin/docs-build.sh` inlines `fonts.css` (font URLs `/site/fonts/…`,
  the site's copy) and everything from `fleet:tokens` to `@theme` (the tokens, the
  shadcn light and dark blocks) into every page, maps its own variables onto them
  (links = `--link`), and puts `wordmark.svg` in the header, its letters in the header's colour.
  SVG illustrations with a `/*{{fleet_theme}}*/` slot receive the same theme and
  embedded fonts at build time: an image cannot inherit the page's CSS or load external fonts.
- **Share cards** — `bin/site-images.sh` loads `fonts.css` and the tokens block.

## Changing it

- A colour: change its `--fleet-*` value here; every consumer follows on its
  next build (the web chat's `dist/` is committed — rebuild it).
- A new character on the website in a theme font: `bin/site-build.sh --fonts`
  (needs fontTools + brotli) re-cuts `fonts/` from `fonts-src/`. Every site build
  fails on a page character the cut lacks; outside that list (and for 中文) the
  browser uses the system font.
- Variable names start with `--fleet-` and are never renamed; the shadcn names
  are shadcn's.

## Variables

| Variable | Use |
|---|---|
| `--fleet-bg` | page background (dark); text on paper in light |
| `--fleet-bg-2` | a band darker than the page (nav pills, footer) |
| `--fleet-surface` | a card on the page |
| `--fleet-surface-2` | a raised element on a card; selected tab |
| `--fleet-line` | borders |
| `--fleet-line-2` | quiet dividers |
| `--fleet-ink` | main text (dark) |
| `--fleet-ink-2` | secondary text |
| `--fleet-muted` | hints, captions, placeholders |
| `--fleet-clay` | the accent: primary button, links, highlights |
| `--fleet-clay-hi` | the accent on hover / focus ring |
| `--fleet-clay-deep` | the accent's dark end (gradients, links on paper) |
| `--fleet-clay-soft` | an accent-tinted fill |
| `--fleet-clay-line` | an accent-tinted border; selection |
| `--fleet-sand` | the warm tint: links in mono, avatar, code on dark |
| `--fleet-ok` | good / online |
| `--fleet-bad` | error / destructive (dark) |
| `--fleet-warn` | warning |
| `--fleet-blue` | a neutral status colour (the site's terminal demo) |
| `--fleet-term` | a terminal's background |
| `--fleet-on-clay` | text on a clay button |
| `--fleet-font-display` | headings: Bricolage Grotesque |
| `--fleet-font-ui` | body text: IBM Plex Sans |
| `--fleet-font-mono` | code, numbers, labels: IBM Plex Mono |

shadcn tokens (`--background`, `--foreground`, `--card`, `--popover`,
`--primary`, `--secondary`, `--muted`, `--accent`, `--destructive`, `--border`,
`--input`, `--ring`, `--radius`) plus `--link`, `--code-bg`, `--code-fg` are mapped
onto the variables above, light by default and dark under
`prefers-color-scheme: dark`. A page that lets a person choose (the console's
设置) sets `data-theme="light"` or `"dark"` on `<html>`, which wins over the
system; with no `data-theme` a page follows the system as before. Tailwind's `@theme` adds `clay`, `clay-soft`,
`clay-line`, `sand`, `ok`, `warn` as colours, `--radius-sm…xl` and
`--spacing` (0.25rem, Tailwind's own scale).
