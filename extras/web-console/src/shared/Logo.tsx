// Logo.tsx — the app icon (extras/fleet-theme/logo.svg's shape: a white Pac-Man
// on a clay tile), drawn in the shared theme's clay. Headers wear the wordmark
// (Wordmark.tsx); this is the square mark only.
import type { FC } from "react";

export const Logo: FC<{ className?: string }> = ({ className }) => (
  <svg viewBox="0 0 64 64" className={className} aria-hidden>
    <rect width="64" height="64" rx="15" fill="var(--fleet-clay)" />
    <path fill="#ffffff" d="M30 32L48.71 41.53A21 21 0 1 1 48.71 22.47Z" />
  </svg>
);
