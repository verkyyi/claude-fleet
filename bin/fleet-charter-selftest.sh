#!/bin/bash
# fleet-charter-selftest.sh — hermetic tests for the issue #283 worker-lifecycle
# helpers in bin/fleet-lib.sh:
#   • fleet_worker_charter <sess> — the LAYERED worker charter /fleet-claim loads:
#       a gated repo charter ($FLEET_MAIN/.fleet/worker.md, behind FLEET_REPO_CHARTER=1,
#       default OFF/fail-closed) UNDER an always-trusted fleet overlay
#       ($FLEET_CONF_DIR/fleets/<sess>/worker.md). Later layer wins → overlay is
#       printed AFTER the repo charter.
#   • fleet_merge_method — FLEET_MERGE_METHOD (squash default) validated to
#       squash|merge|rebase; unset/typo falls back to squash.
# No network, no git, no gh — pure function calls over a temp dir. Real fleet-lib.sh.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/charter-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# Point the conf dir at the temp tree BEFORE sourcing (fleet-lib defaults it only
# when unset), then source the real library.
export FLEET_CONF_DIR="$WORK/conf"
export FLEET_MAIN="$WORK/main"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

SESS="mysess"
mkdir -p "$FLEET_MAIN/.fleet" "$FLEET_CONF_DIR/fleets/$SESS"
REPO_MD="$FLEET_MAIN/.fleet/worker.md"
OVERLAY_MD="$FLEET_CONF_DIR/fleets/$SESS/worker.md"

# ===== charter: no files, gate off ⇒ empty ========================================
unset FLEET_REPO_CHARTER
out=$(fleet_worker_charter "$SESS")
[ -z "$out" ] || fail "no charter files + gate off must emit nothing" "$out"
ok "no files → empty charter (worker runs on the built-in default)"

# ===== charter: overlay only ⇒ printed, marked operator/wins =======================
printf 'OVERLAY-ORDERS: prefer squash and small PRs\n' > "$OVERLAY_MD"
out=$(fleet_worker_charter "$SESS")
case "$out" in *OVERLAY-ORDERS*) : ;; *) fail "overlay charter must be printed" "$out" ;; esac
case "$out" in *"overlay"*"operator"*) : ;; *) fail "overlay layer must be labelled operator" "$out" ;; esac
ok "fleet overlay charter (operator, always trusted) is printed"

# ===== charter: repo file present but gate OFF (default) ⇒ NOT printed =============
printf 'REPO-ORDERS: injected via a PR\n' > "$REPO_MD"
unset FLEET_REPO_CHARTER                       # default OFF / fail-closed
out=$(fleet_worker_charter "$SESS")
case "$out" in *REPO-ORDERS*) fail "repo charter must be SKIPPED when the gate is off (fail-closed)" "$out" ;; esac
case "$out" in *OVERLAY-ORDERS*) : ;; *) fail "overlay must still print with the gate off" "$out" ;; esac
ok "repo charter is fail-closed: skipped unless FLEET_REPO_CHARTER=1"

# ===== charter: gate ON ⇒ repo printed, and overlay comes AFTER it (later wins) ====
export FLEET_REPO_CHARTER=1
out=$(fleet_worker_charter "$SESS")
case "$out" in *REPO-ORDERS*) : ;; *) fail "repo charter must print when FLEET_REPO_CHARTER=1" "$out" ;; esac
case "$out" in *OVERLAY-ORDERS*) : ;; *) fail "overlay must print alongside the repo charter" "$out" ;; esac
repo_at=$(printf '%s\n' "$out" | grep -n 'REPO-ORDERS'    | head -1 | cut -d: -f1)
ovl_at=$(printf '%s\n' "$out" | grep -n 'OVERLAY-ORDERS' | head -1 | cut -d: -f1)
[ -n "$repo_at" ] && [ -n "$ovl_at" ] && [ "$repo_at" -lt "$ovl_at" ] \
  || fail "overlay (higher precedence) must be printed AFTER the repo charter" "$out"
ok "gate on → repo charter first, overlay after (later layer wins on conflict)"

# ===== charter: gate ON but repo file absent ⇒ silent skip, overlay only ==========
rm -f "$REPO_MD"
out=$(fleet_worker_charter "$SESS")
case "$out" in *REPO-ORDERS*) fail "a removed repo charter must not linger" "$out" ;; esac
case "$out" in *OVERLAY-ORDERS*) : ;; *) fail "overlay must still print" "$out" ;; esac
ok "missing repo charter is skipped silently even with the gate on"

# ===== charter: no overlay dir for an unknown session ⇒ no error, no output =======
rm -f "$OVERLAY_MD"
unset FLEET_REPO_CHARTER
out=$(fleet_worker_charter "no-such-sess") || fail "missing files must not error"
[ -z "$out" ] || fail "unknown session with no files must emit nothing" "$out"
ok "missing overlay/session → silent, no error"

# ===== tap-first block (issue #328): appended for the worker ONLY when the flag =1 =
# Clean slate (no file layers), so we isolate the tap-first append from the layers.
unset FLEET_TAP_FIRST
out=$(fleet_worker_charter "$SESS")
case "$out" in *AskUserQuestion*) fail "tap-first block must NOT appear when FLEET_TAP_FIRST is unset" "$out" ;; esac
[ -z "$out" ] || fail "no files + tap-first off (unset) ⇒ empty charter (byte-identical to historic default)" "$out"
ok "tap-first off (unset) → block absent, charter unchanged"

out=$(FLEET_TAP_FIRST=0 fleet_worker_charter "$SESS")
case "$out" in *AskUserQuestion*) fail "tap-first block must NOT appear when FLEET_TAP_FIRST=0" "$out" ;; esac
[ -z "$out" ] || fail "no files + tap-first=0 ⇒ empty charter" "$out"
ok "tap-first off (=0) → block absent"

out=$(FLEET_TAP_FIRST=1 fleet_worker_charter "$SESS")
case "$out" in *AskUserQuestion*) : ;; *) fail "tap-first block MUST appear when FLEET_TAP_FIRST=1" "$out" ;; esac
case "$out" in *"FLEET_TAP_FIRST=1"*) : ;; *) fail "tap-first block should carry its machine-global header" "$out" ;; esac
# no-drift: the appended text is EXACTLY the shared fleet_tap_first_block source.
block=$(FLEET_TAP_FIRST=1 fleet_tap_first_block)
case "$out" in *"$block"*) : ;; *) fail "worker charter must embed the canonical block verbatim (DRY)" "$(printf 'CHARTER:\n%s\nBLOCK:\n%s' "$out" "$block")" ;; esac
ok "tap-first on (=1) → worker charter contains the shared block verbatim"

# the shared helper itself: the ONE canonical source (bare call, no session).
[ -z "$(fleet_tap_first_block)" ] || fail "fleet_tap_first_block must be silent when the flag is off"
[ -z "$(FLEET_TAP_FIRST=0 fleet_tap_first_block)" ] || fail "fleet_tap_first_block must be silent with FLEET_TAP_FIRST=0"
case "$(FLEET_TAP_FIRST=1 fleet_tap_first_block)" in *AskUserQuestion*) : ;; *) fail "fleet_tap_first_block must emit the block when FLEET_TAP_FIRST=1" ;; esac
ok "fleet_tap_first_block: silent when off, emits the canonical block when on"
unset FLEET_TAP_FIRST

# ===== merge method: default + validation =========================================
unset FLEET_MERGE_METHOD
[ "$(fleet_merge_method)" = squash ] || fail "unset FLEET_MERGE_METHOD must default to squash"
[ "$(FLEET_MERGE_METHOD=merge  fleet_merge_method)" = merge  ] || fail "merge should pass through"
[ "$(FLEET_MERGE_METHOD=rebase fleet_merge_method)" = rebase ] || fail "rebase should pass through"
[ "$(FLEET_MERGE_METHOD=squash fleet_merge_method)" = squash ] || fail "squash should pass through"
[ "$(FLEET_MERGE_METHOD=fast   fleet_merge_method)" = squash ] || fail "a garbage value must fall back to squash"
[ "$(FLEET_MERGE_METHOD=''     fleet_merge_method)" = squash ] || fail "empty must fall back to squash"
ok "fleet_merge_method: default squash + validates squash|merge|rebase, else squash"

printf '\nselftest OK: %s assertions passed (worker charter + merge method, issue #283)\n' "$pass"
exit 0
