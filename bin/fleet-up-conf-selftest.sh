#!/bin/bash
# fleet-up-conf-selftest.sh — hermetic unit tests for fleet_write_conf() in
# bin/fleet-lib.sh, the per-fleet conf writer fleet-up.sh uses (issue #170).
#
# The bug: fleet-up.sh regenerated the conf with a truncating `cat >` that wrote
# ONLY the three derived keys (FLEET_REPO/FLEET_MAIN/FLEET_BASE_BRANCH). A crash +
# `cf`/restore re-runs fleet-up → every custom knob the operator set (FLEET_ISSUE_BRIDGE,
# FLEET_CLEANUP, FLEET_MAX_SESSIONS, FLEET_STEWARD_ISSUE, …) was
# silently wiped and the feature went OFF undetected. The fix preserves every
# non-derived FLEET_* key while still refreshing the derived three, atomically.
#
# Covered:
#   1. FRESH      — no existing conf: derived three written, no stray keys.
#   2. PRESERVE   — existing conf with custom keys: customs survive verbatim...
#   3. REFRESH    — ...while the derived three are updated to the new values.
#   4. NO-DUP     — a second rewrite doesn't duplicate keys or stack headers.
#   5. ATOMIC     — no leftover .tmp file; conf is a single complete unit.
#   6. EXPORT     — `export FLEET_FOO=` custom forms are preserved too.
#   7. NON-FLEET  — comments, `source` includes, and plain (non-FLEET_) vars an
#                   operator put in the conf survive too — not just FLEET_* keys
#                   (dropping a `source secrets.conf` is the same silent loss).
#
# Fully hermetic: FLEET_CONF_DIR points at a scratch dir, no tmux/git/gh/network.
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-up-conf-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# Isolate the conf dir before sourcing, so the lib picks it up.
export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR"
# shellcheck source=/dev/null
. "$LIB"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() {  # <desc> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"
}
has() {   # <desc> <file> <exact-line>
  CHECKS=$((CHECKS + 1))
  grep -qxF "$3" "$2" || fail "$1 — missing line [$3] in $(cat "$2")"
}
hasnt() { # <desc> <file> <grep-ere>
  CHECKS=$((CHECKS + 1))
  grep -qE "$3" "$2" && fail "$1 — unexpected match /$3/ in $(cat "$2")"
  return 0
}
# read a FLEET_* value by sourcing the conf in a subshell (its real consumer path)
val() { ( . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" ); }

CONF="$FLEET_CONF_DIR/fleet-demo.conf"

# ================================================================ 1. FRESH =====
fleet_write_conf "$CONF" "fleet-demo" "acme/widgets" "/home/me/widgets" "main" "2026-07-09 12:00:00" \
  || fail "fresh: fleet_write_conf returned non-zero"
[ -f "$CONF" ] || fail "fresh: no conf written"
eq "fresh: FLEET_REPO"        "acme/widgets"     "$(val "$CONF" FLEET_REPO)"
eq "fresh: FLEET_MAIN"        "/home/me/widgets" "$(val "$CONF" FLEET_MAIN)"
eq "fresh: FLEET_BASE_BRANCH" "main"             "$(val "$CONF" FLEET_BASE_BRANCH)"
# a fresh conf carries no other FLEET_* keys
hasnt "fresh: no stray keys" "$CONF" '^[[:space:]]*(export[[:space:]]+)?FLEET_(ISSUE_BRIDGE|CLEANUP|MAX_SESSIONS)='

# ===================================================== 2+3. PRESERVE / REFRESH =
# Seed a conf as an operator would: derived three PLUS custom knobs. Then rewrite
# with NEW derived values (as a restore would) and assert the customs survive.
cat > "$CONF" <<'SEED'
# claude-fleet: fleet 'fleet-demo' — written by fleet-up.sh 2026-01-01 00:00:00
# Overlays the global fleet.conf for this fleet's tmux session. Add any other
# FLEET_* keys (see fleet.conf.example) — e.g. FLEET_CTX_WINDOW, FLEET_PROTECTED_RE.
FLEET_REPO="acme/OLD"
FLEET_MAIN="/old/path"
FLEET_BASE_BRANCH="develop"
FLEET_ISSUE_BRIDGE=1
FLEET_STEWARD_ISSUE=169
FLEET_CLEANUP=0
FLEET_MAX_SESSIONS=3
FLEET_CTX_WINDOW=1
SEED

fleet_write_conf "$CONF" "fleet-demo" "acme/widgets" "/new/path" "master" "2026-07-09 19:29:00" \
  || fail "preserve: fleet_write_conf returned non-zero"

# derived three refreshed to the NEW values
eq "refresh: FLEET_REPO"        "acme/widgets" "$(val "$CONF" FLEET_REPO)"
eq "refresh: FLEET_MAIN"        "/new/path"    "$(val "$CONF" FLEET_MAIN)"
eq "refresh: FLEET_BASE_BRANCH" "master"       "$(val "$CONF" FLEET_BASE_BRANCH)"
# and NOT the stale ones
hasnt "refresh: old repo gone" "$CONF" 'acme/OLD'
hasnt "refresh: old base gone" "$CONF" 'FLEET_BASE_BRANCH="develop"'

# every custom key survives verbatim — this is the core regression guard
has "preserve: FLEET_ISSUE_BRIDGE" "$CONF" "FLEET_ISSUE_BRIDGE=1"
has "preserve: FLEET_STEWARD_ISSUE" "$CONF" "FLEET_STEWARD_ISSUE=169"
has "preserve: FLEET_CLEANUP"      "$CONF" "FLEET_CLEANUP=0"
has "preserve: FLEET_MAX_SESSIONS" "$CONF" "FLEET_MAX_SESSIONS=3"
has "preserve: FLEET_CTX_WINDOW"   "$CONF" "FLEET_CTX_WINDOW=1"

# ================================================================ 4. NO-DUP ====
# A second rewrite (another restore) must not duplicate keys or stack headers.
fleet_write_conf "$CONF" "fleet-demo" "acme/widgets" "/new/path" "master" "2026-07-09 20:00:00" \
  || fail "no-dup: fleet_write_conf returned non-zero"
eq "no-dup: single FLEET_ISSUE_BRIDGE" "1" "$(grep -c '^FLEET_ISSUE_BRIDGE=' "$CONF")"
eq "no-dup: single FLEET_REPO"         "1" "$(grep -c '^FLEET_REPO=' "$CONF")"
eq "no-dup: single header line"        "1" "$(grep -c 'written by fleet-up.sh' "$CONF")"

# ================================================================ 5. ATOMIC ====
# The temp file is created in-dir then mv'd; none must survive a successful write.
eq "atomic: no leftover tmp" "0" "$(find "$FLEET_CONF_DIR" -name '*.tmp.*' | wc -l | tr -d ' ')"

# ================================================================ 6. EXPORT ====
# A custom key written with `export ` (a legit shell form) must be preserved.
printf 'export FLEET_PROTECTED_RE="^main$"\n' >> "$CONF"
fleet_write_conf "$CONF" "fleet-demo" "acme/widgets" "/new/path" "master" "2026-07-09 21:00:00" \
  || fail "export: fleet_write_conf returned non-zero"
has "export: preserved" "$CONF" 'export FLEET_PROTECTED_RE="^main$"'
# and it must NOT have been mistaken for a derived key and dropped/duplicated
eq "export: single line" "1" "$(grep -c 'FLEET_PROTECTED_RE=' "$CONF")"

# =========================================================== 7. NON-FLEET ======
# The regression the code review caught: preservation must keep ALL operator
# content, not only FLEET_* keys. A `source` include (e.g. a secrets/creds file
# the bridge or self-land needs), a plain non-FLEET var, and a hand comment must
# all survive a rewrite — dropping any of them is the same silent-loss class.
cat > "$CONF" <<'SEED2'
# claude-fleet: fleet 'fleet-demo' — written by fleet-up.sh 2026-01-01 00:00:00
# Overlays the global fleet.conf for this fleet's tmux session. Add any other
# FLEET_* keys (see fleet.conf.example) — e.g. FLEET_CTX_WINDOW, FLEET_PROTECTED_RE.
FLEET_REPO="acme/OLD"
FLEET_MAIN="/old/path"
FLEET_BASE_BRANCH="develop"
# operator note: bridge creds live in the sourced file below
source ~/.config/claude-fleet/secrets.conf
MY_HELPER_VAR=xyz
FLEET_ISSUE_BRIDGE=1
SEED2

fleet_write_conf "$CONF" "fleet-demo" "acme/widgets" "/new/path" "master" "2026-07-09 22:00:00" \
  || fail "non-fleet: fleet_write_conf returned non-zero"
has "non-fleet: source include preserved" "$CONF" 'source ~/.config/claude-fleet/secrets.conf'
has "non-fleet: plain var preserved"      "$CONF" 'MY_HELPER_VAR=xyz'
has "non-fleet: operator comment preserved" "$CONF" '# operator note: bridge creds live in the sourced file below'
has "non-fleet: FLEET_ISSUE_BRIDGE preserved" "$CONF" 'FLEET_ISSUE_BRIDGE=1'
eq "non-fleet: derived refreshed" "acme/widgets" "$(val "$CONF" FLEET_REPO)"
# OUR header must NOT accumulate — the seed carried one, we regenerate one, net = 1
eq "non-fleet: single header line" "1" "$(grep -c 'written by fleet-up.sh' "$CONF")"
eq "non-fleet: single 'Overlays' header line" "1" "$(grep -c '^# Overlays the global fleet.conf' "$CONF")"

printf 'selftest PASS: fleet_write_conf — derived three refreshed, %d preserve/atomic/no-dup checks held (issue #170)\n' "$CHECKS"
exit 0
