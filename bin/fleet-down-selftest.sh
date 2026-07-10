#!/bin/bash
# fleet-down-selftest.sh — hermetic test for bin/fleet-down.sh's path-traversal
# guard (steward review, PR #196 / issue #181).
#
# fleet-down --purge does `rm -rf "$FLEET_CONF_DIR/fleets/$NAME"` with the raw CLI
# arg, so a typo like `fleet-down ..` or `fleet-down a/b` must NOT be allowed to
# escape fleets/<sess>/ and wipe a parent (accounts/ = OAuth tokens, diskguard/,
# every other fleet's state). This asserts:
#   • `..`, `.`, `a/b`, `x/../y`  → REFUSED (non-zero), NOTHING removed.
#   • a legit dotted name (fleet-my.app) → allowed; a real --purge removes exactly
#     that fleet's dir + its slug cache, leaving accounts/ + diskguard/ + siblings.
#
# Fully hermetic: fakes tmux (no live session, server "down" so fleet-down takes the
# disarm branch and never spawns the collector), sandboxes FLEET_CONF_DIR + FLEET_C.
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-down.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-down-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- %s\n' "$2" >&2; exit 1; }
CHECKS=0
ok()      { CHECKS=$((CHECKS+1)); }
exists()  { CHECKS=$((CHECKS+1)); [ -e "$1" ] || fail "expected to survive: $1"; }
absent()  { CHECKS=$((CHECKS+1)); [ -e "$1" ] && fail "expected removed: $1"; return 0; }

mkdir -p "$WORK/fakepath"
# fake tmux: no live session; `info`→1 (server "down") so fleet-down runs the
# --disarm branch instead of spawning the real collector.
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
case "${1:-}" in
  has-session) exit 1 ;;
  info)        exit 1 ;;
  kill-session) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$WORK/fakepath/tmux"

CONF_DIR="$WORK/conf"
# FLEET_C is TMPDIR-derived in fleet-lib, so TMPDIR=$WORK ⇒ FLEET_C=$WORK/.claude-dash.
CACHE="$WORK/.claude-dash"
mkdir -p "$CONF_DIR/fleets/victim" "$CONF_DIR/accounts" "$CONF_DIR/diskguard" "$CACHE/fleets"
: > "$CONF_DIR/accounts/personal"        # sentinel: an OAuth token that must never be wiped
: > "$CONF_DIR/fleets/victim/conf"       # sentinel: a sibling fleet that must survive

run() { PATH="$WORK/fakepath:$PATH" FLEET_CONF_DIR="$CONF_DIR" TMPDIR="$WORK" \
          bash "$SRC" "$@" >"$WORK/out" 2>"$WORK/err"; }

# --- refused: path-traversal names must die BEFORE any rm ----------------------
for bad in ".." "." "a/b" "x/../y" "../evil"; do
  if run "$bad" --purge; then fail "'$bad' should be REFUSED (fleet-down exited 0)" "$(cat "$WORK/err")"; fi
  ok
  grep -qiE 'refus|traversal' "$WORK/err" \
    || fail "'$bad' refusal should print a clear guard error" "$(cat "$WORK/err")"
  # nothing must have been removed
  exists "$CONF_DIR/accounts/personal"
  exists "$CONF_DIR/diskguard"
  exists "$CONF_DIR/fleets/victim/conf"
done
printf 'selftest: guard leg PASS (.. / . / a/b / x/../y / ../evil all refused, no rm)\n' >&2

# --- allowed: a legit dotted session name purges exactly its own state ----------
mkdir -p "$CONF_DIR/fleets/fleet-my.app" "$CACHE/fleets/acme-widgets"
printf 'FLEET_REPO="acme/widgets"\n' > "$CONF_DIR/fleets/fleet-my.app/conf"
: > "$CACHE/fleets/acme-widgets/issues"

run "fleet-my.app" --purge || fail "a legit dotted name must be ALLOWED" "$(cat "$WORK/err")"
ok
grep -qiE 'refus|traversal' "$WORK/err" \
  && fail "a legit dotted name must NOT trip the traversal guard" "$(cat "$WORK/err")"
absent "$CONF_DIR/fleets/fleet-my.app"      # its own durable state removed
absent "$CACHE/fleets/acme-widgets"         # its slug cache removed
exists "$CONF_DIR/accounts/personal"        # globals + siblings survive
exists "$CONF_DIR/diskguard"
exists "$CONF_DIR/fleets/victim/conf"
printf 'selftest: allow leg PASS (fleet-my.app purged exactly its own dirs; globals + sibling survived)\n' >&2

printf 'selftest OK: fleet-down path-traversal guard (%s assertions — traversal refused with no rm, legit dotted name allowed, blast radius contained)\n' "$CHECKS"
