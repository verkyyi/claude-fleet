// Logo.tsx — ClaudeFleet's mark, drawn in the shared theme's colours
// (extras/fleet-theme/logo.svg's shape; the colours are its variables).
import type { FC } from "react";

export const Logo: FC<{ className?: string }> = ({ className }) => (
  <svg viewBox="0 0 64 64" className={className} aria-hidden>
    <rect width="64" height="64" rx="15" fill="var(--fleet-bg)" stroke="var(--fleet-line)" />
    <polyline points="14.4,35.5 21.6,42 14.4,48.5" fill="none" stroke="var(--fleet-clay)" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
    <polyline points="35,15 47,26 35,37" fill="none" stroke="var(--fleet-clay)" strokeWidth="9" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);
