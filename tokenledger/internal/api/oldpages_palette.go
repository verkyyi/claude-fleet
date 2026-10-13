package api

// authPaletteCSS is the old public pages' palette, light and dark — the keys
// page (claude-fleet#3069) and the tickets page still wear it until their
// members of EPIC #3923 move them onto the theme (C7 #3930, C5 #3928); the way
// in left it with claude-fleet#3932 (entry_pages.go). Never use it on a new page.
const authPaletteCSS = `:root{--bg:#f4f6f5;--panel:#fff;--ink:#15201d;--ink-2:#3c4945;--muted:#6a7773;--line:#e0e6e3;--line-2:#ecf0ee;--brand:#0e6e5e;--brand-ink:#fff;--bad:#b5361f;--bad-soft:#fbe6e1;--warn:#a86a00;--warn-soft:#fbefd6;
--shadow:0 1px 2px rgba(16,30,26,.06),0 4px 16px -6px rgba(16,30,26,.10);--f-display:"Bricolage Grotesque","Avenir Next","Segoe UI",system-ui,sans-serif;--f-ui:"IBM Plex Sans","Segoe UI",system-ui,sans-serif;--gh:#1f2328;--gh-ink:#fff;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#0e1412;--panel:#151d1b;--ink:#e5ece9;--ink-2:#c1ccc8;--muted:#8b9894;--line:#26302d;--line-2:#1e2725;--brand:#3fc2a6;--brand-ink:#062019;--bad:#f08a76;--bad-soft:#3a1c16;--warn:#e8b85a;--warn-soft:#33290f;--shadow:0 1px 2px rgba(0,0,0,.3),0 6px 20px -8px rgba(0,0,0,.5);--gh:#f0f3f6;--gh-ink:#1f2328;color-scheme:dark}}
`
