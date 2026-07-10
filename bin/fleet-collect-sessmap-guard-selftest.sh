#!/bin/bash
# fleet-collect-sessmap-guard-selftest.sh — the collector's sessmap write-guard,
# stale-flat prune, and un-shadow behaviour (issue #203).
#
# Background (#203): fleet_sockets globbed the pre-#181 flat *.conf path and
# discovered ZERO fleets post-migration. The collector then wrote an EMPTY
# global/sessmap that SHADOWED the still-good legacy flat sessmap → fleet_slug_cached
# returned empty → fleet_cache fell back to a stale flat $C/issues (another repo's
# data) → the backlog rendered the WRONG repo's issues. Discovery itself is fixed +
# unit-tested in fleet-lib-selftest.sh; THIS test pins the collector-side guards the
# steward asked for on top of it:
#
#   1. DISCOVERY + WRITE  — a resolvable live fleet → global/sessmap gets its row.
#   2. PRUNE              — dead pre-#180 flat issues/prmap/labels mirrors are removed
#                           (current code writes those only under fleets/<slug>/), so
#                           fleet_cache's degenerate fallback can't serve wrong-repo data.
#   3. WRITE-GUARD        — with a GOOD global/sessmap already present, a run whose
#                           discovery returns nothing must NOT clobber it with an empty map.
#   4. UN-SHADOW          — an EMPTY global/sessmap sitting on top of a non-empty legacy
#                           flat sessmap is REMOVED so the good legacy rows un-shadow.
#
# Drives the REAL collector against a FAKE gh + tmux (no network, no tmux server).
# Needs jq (the fake gh applies the collector's real --jq) + python3 (collector hard
# dep) — SKIPs cleanly if either is absent. Exit 0 = pass, non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/tmux-dash-collect.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$SRC" ] || { printf 'selftest: %s not found\n' "$SRC" >&2; exit 2; }
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }
command -v jq      >/dev/null 2>&1 || { printf 'selftest: jq not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/collect-sessmap-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath"
cp "$SRC" "$WORK/bin/tmux-dash-collect.sh"; chmod +x "$WORK/bin/tmux-dash-collect.sh"
cp "$LIB" "$WORK/bin/fleet-lib.sh"

# --- fake gh: only `issue list … --jq <expr>`, applied to an empty array via jq
# (sessmap doesn't need issues; keep the per-repo fetch cheap + hermetic).
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
if [ "$1" = issue ] && [ "$2" = list ]; then
  expr=''
  while [ "$#" -gt 0 ]; do case "$1" in --jq) shift; expr="$1" ;; esac; shift; done
  [ -n "$expr" ] && printf '[]' | jq -r "$expr"
fi
exit 0
FAKE
chmod +x "$WORK/fakepath/gh"

# --- fake tmux: strips a leading `-L <label>` like real tmux, then:
#   has-session   → up (exit 0) UNLESS the label is in $FAKE_DOWN
#   list-sessions → prints the label (session name == socket label == fleet)
#   everything else (list-windows/list-clients/capture-pane/info/display) → empty ok
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
label=""
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then label="$2"; shift 2; fi
case "${1:-}" in
  has-session)
    for d in ${FAKE_DOWN:-}; do [ "$d" = "$label" ] && exit 1; done
    exit 0 ;;
  list-sessions) [ -n "$label" ] && printf '%s\n' "$label"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- a configured fleet in the NEW #181 layout: fleets/sessA/conf → acme/widgets.
CONF="$WORK/conf"; mkdir -p "$CONF/fleets/sessA"
printf 'FLEET_REPO="acme/widgets"\n' > "$CONF/fleets/sessA/conf"

C="$WORK/.claude-dash"
G="$C/global"
run_collector() {  # $1 = FAKE_DOWN value (empty ⇒ fleet live)
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" GH_TTL=0 \
  FLEET_REPO="" FLEET_REPOS="" FLEET_NOTIFY_CMD="" \
  FLEET_CONF_DIR="$CONF" FAKE_DOWN="${1:-}" \
    bash "$WORK/bin/tmux-dash-collect.sh" >"$WORK/stdout" 2>"$WORK/log" || {
      printf 'selftest FAIL: collector exited non-zero\n' >&2; cat "$WORK/log" >&2; exit 1; }
}
fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- global/sessmap ---\n' >&2; cat "$G/sessmap" 2>/dev/null >&2
         printf -- '--- log ---\n' >&2; tail -5 "$WORK/log" 2>/dev/null >&2; exit 1; }

# ============================================================================
# 1. DISCOVERY + WRITE + 2. PRUNE — a live resolvable fleet, plus stale flat
#    leftovers seeded up front that the run must delete.
# ============================================================================
mkdir -p "$C"
printf 'STALE alpha (other repo)\n' > "$C/issues";  : > "$C/issues.ts"
printf 'STALE prmap\n'             > "$C/prmap";   : > "$C/prmap.ts"
printf 'STALE labels\n'            > "$C/labels"
run_collector ""    # sessA live

[ -s "$G/sessmap" ] || fail "1: global/sessmap should have a row after discovery"
grep -q 'sessA' "$G/sessmap"        || fail "1: sessmap should list sessA"
grep -q 'acme/widgets' "$G/sessmap" || fail "1: sessmap row should carry the resolved repo"

[ -e "$C/issues" ]    && fail "2: stale flat \$C/issues must be pruned"
[ -e "$C/issues.ts" ] && fail "2: stale flat \$C/issues.ts must be pruned"
[ -e "$C/prmap" ]     && fail "2: stale flat \$C/prmap must be pruned"
[ -e "$C/labels" ]    && fail "2: stale flat \$C/labels must be pruned"

# ============================================================================
# 3. WRITE-GUARD — good global/sessmap present, discovery now returns nothing
#    (sessA down): the good map must SURVIVE, not be clobbered by an empty one.
# ============================================================================
good="$(cat "$G/sessmap")"
run_collector "sessA"    # sessA down ⇒ fleet_sockets empty
[ -f "$G/sessmap" ]                 || fail "3: guard dropped a NON-empty sessmap on empty discovery"
[ "$(cat "$G/sessmap")" = "$good" ] || fail "3: guard must preserve the non-empty sessmap verbatim"

# ============================================================================
# 4. UN-SHADOW — an EMPTY global/sessmap over a non-empty legacy flat sessmap:
#    discovery empty ⇒ the empty global map is removed so legacy un-shadows.
# ============================================================================
: > "$G/sessmap"                                   # empty global (the #203 live mess)
printf 'sessL\tacme-legacy\tacme/legacy\n' > "$C/sessmap"   # good legacy flat rows
run_collector "sessA"    # discovery empty
[ -e "$G/sessmap" ] && fail "4: an empty global/sessmap over good legacy rows must be REMOVED (un-shadow)"
grep -q 'sessL' "$C/sessmap" || fail "4: the legacy flat sessmap must be left intact"

printf 'selftest PASS: collect sessmap guard — discovery+write, prune stale flat mirrors, write-guard, un-shadow (#203)\n'
exit 0
