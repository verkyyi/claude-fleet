// theme.ts — 深色 / 浅色 (claude-fleet#3931, EPIC #3923 rule 10): the system's
// by default, a person's own pick kept on this device only (localStorage),
// never sent anywhere. The page always says which one it is drawing on <html>
// as data-theme — the shared theme (extras/fleet-theme/theme.css) and this
// app's dark: variant (index.css) both read that.
export type ThemePick = "system" | "light" | "dark";

const KEY = "fleet.theme";
const dark = typeof matchMedia !== "undefined" ? matchMedia("(prefers-color-scheme: dark)") : null;

export function themePick(): ThemePick {
  try {
    const v = localStorage.getItem(KEY);
    return v === "light" || v === "dark" ? v : "system";
  } catch { return "system"; }
}

function draw() {
  const p = themePick();
  const on = p === "system" ? !!dark?.matches : p === "dark";
  document.documentElement.dataset.theme = on ? "dark" : "light";
}

export function setThemePick(p: ThemePick) {
  try {
    if (p === "system") localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, p);
  } catch { /* a browser that keeps nothing: this page still switches */ }
  draw();
}

// drawn once before the first render, then again whenever the system turns
if (typeof document !== "undefined") {
  draw();
  dark?.addEventListener("change", draw);
}
