#!/bin/bash
# fleet-doctor-orchestrate-selftest.sh — fleet-doctor.sh's `skills` WARN for an
# orchestrator with no /fleet-orchestrate skill (issue #2110). The orchestrating
# session (bin/fleet-orchestrator.sh, issue #1957) is seeded `/fleet-orchestrate`;
# a skills pass that skipped it left the session on `Unknown command`, silently.
#
#   A. orchestrator on (FLEET_ORCHESTRATOR=1), skill missing  → WARN naming it
#   B. the skill installed                                     → no row
#   C. FLEET_ORCHESTRATOR=0, skill missing                     → no row
#   D. FLEET_AGENT=codex: the Codex home's skills/ is the one looked at
#
# Hermetic: sandbox HOME / FLEET_CONF_DIR / CLAUDE_SKILLS_DIR / CODEX_HOME.
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-orch-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/conf" "$WORK/skills" "$WORK/codex/skills"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
doc() { # env assignments… → the doctor's orchestrate line(s)
  env HOME="$WORK/home" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" \
    CLAUDE_SKILLS_DIR="$WORK/skills" CODEX_HOME="$WORK/codex" "$@" \
    bash "$BIN/fleet-doctor.sh" 2>/dev/null | grep 'fleet-orchestrate/SKILL.md'
}
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2" ;; esac; }
none() { CHECKS=$((CHECKS + 1)); [ -z "$1" ] || fail "$2" "$1"; }

out=$(doc FLEET_ORCHESTRATOR=1)
has "WARN" "$out" 'A missing skill → WARN'
has "$WORK/skills/fleet-orchestrate/SKILL.md" "$out" 'A names the Claude skills path'
has 'FLEET_ORCHESTRATOR=0' "$out" 'A says how to silence it'

mkdir -p "$WORK/skills/fleet-orchestrate"; printf '# x\n\n<!-- fleet skill -->\n' > "$WORK/skills/fleet-orchestrate/SKILL.md"
none "$(doc FLEET_ORCHESTRATOR=1)" 'B installed → no row'
rm -rf "$WORK/skills/fleet-orchestrate"

none "$(doc FLEET_ORCHESTRATOR=0)" 'C off → no row'

has "$WORK/codex/skills/fleet-orchestrate/SKILL.md" "$(doc FLEET_ORCHESTRATOR=1 FLEET_AGENT=codex)" 'D codex → the Codex home'

printf 'fleet-doctor-orchestrate-selftest: PASS (%d checks)\n' "$CHECKS"
