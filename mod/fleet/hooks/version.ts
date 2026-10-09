// The Claude Code versions this mod is written against (EPIC #1334 rule 5).
// The function-hook API is early access and moves between releases, so outside
// this range the mod registers nothing and the session runs exactly as it does
// with no mod at all: the window says `@mod_state off:version` and fleet-doctor's
// `mod` row counts it. Widen BELOW after checking a new release.

/** The mod's own version — keep equal to .claude-plugin/plugin.json. */
export const MOD_VERSION = '0.4.5'

/** Supported Claude Code releases: MIN inclusive, BELOW exclusive. */
export const SUPPORTED = { min: '2.1.288', below: '2.2.0' } as const

type Triple = [number, number, number]

/** `2.1.288`, `2.1.288-dev`, `2.1.288-dev.20260920…` → [2, 1, 288]; else null. */
export function parseVersion(text: string | undefined): Triple | null {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(text ?? '')
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null
}

function cmp(a: Triple, b: Triple): number {
  for (let i = 0; i < 3; i++) {
    const d = (a[i] ?? 0) - (b[i] ?? 0)
    if (d !== 0) return d
  }
  return 0
}

/** True when `version` (a release or dev spelling) lies in SUPPORTED. */
export function isSupported(version: string | undefined): boolean {
  const v = parseVersion(version)
  const lo = parseVersion(SUPPORTED.min)
  const hi = parseVersion(SUPPORTED.below)
  if (v === null || lo === null || hi === null) return false
  return cmp(v, lo) >= 0 && cmp(v, hi) < 0
}
