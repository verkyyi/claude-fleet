// Wordmark.tsx — "tokenman", the brand's text logo (extras/fleet-theme/wordmark.svg).
// Its letters are currentColor, so they wear the header's foreground in either
// theme; the o is the clay Pac-Man. Height sets the size (h-[18px] and the like).
import type { FC } from "react";
import raw from "../../../fleet-theme/wordmark.svg?raw";
import { BRAND } from "./brand";
import { parseWordmark } from "./wordmark-parse";

export const WORDMARK = parseWordmark(raw);

export const Wordmark: FC<{ className?: string }> = ({ className }) => (
  <svg viewBox={WORDMARK.viewBox.join(" ")} className={className} role="img" aria-label={BRAND}
    style={{ width: "auto", aspectRatio: `${WORDMARK.viewBox[2]} / ${WORDMARK.viewBox[3]}`, overflow: "visible" }}>
    <title>{BRAND}</title>
    {WORDMARK.parts.map((p, i) => (
      <path key={i} d={p.d} fill={p.fill} stroke={p.stroke} strokeWidth={p.strokeWidth} />
    ))}
  </svg>
);
