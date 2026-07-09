#!/bin/bash
# fleet-keys-selftest.sh — drift guard for the keymap cheatsheet (issue #110).
#
# fleet-keys.sh is a CURATED source of truth; this test keeps it honest by
# cross-checking it against the binds actually shipped, so the sheet can't go
# stale silently:
#
#   1. Every `prefix <k>` row in the sheet has a matching `bind <k> ...` line in
#      conf/tmux-attention.conf (and F9 has a `bind -n F9`).
#   2. Every prefix `bind`/`bind -n` in the conf (minus the mouse status bind) is
#      documented in the sheet — no missing entries.
#   3. The `?` popup bind exists in the conf, and the dash (`?`) + backlog (`⌃k`)
#      each open fleet-keys.sh.
#   4. The sheet renders non-empty in --plain mode and lists all four groups.
#
# Exit 0 = pass. Non-zero = fail (prints what diverged). No network / no tmux.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
KEYS="$BIN/fleet-keys.sh"
CONF="$ROOT/conf/tmux-attention.conf"
DASH="$BIN/tmux-dashboard.sh"
ISSUES="$BIN/tmux-issues.sh"

for f in "$KEYS" "$CONF" "$DASH" "$ISSUES"; do
  [ -f "$f" ] || { printf 'selftest: missing %s\n' "$f" >&2; exit 2; }
done

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

SHEET="$(NO_COLOR=1 bash "$KEYS" --plain)" || fail "fleet-keys.sh --plain exited non-zero"
[ -n "$SHEET" ] || fail "sheet rendered empty"

# --- 4. all four group headers present ----------------------------------------
for g in "tmux prefix" "dashboard" "backlog" "config modal"; do
  printf '%s\n' "$SHEET" | grep -qi "^$g " || fail "sheet missing group: $g"
done

# Keys after "prefix " in each sheet row (a, j, G, b, A, c, r, ?). Set as text,
# one key per line — compared with grep -Fxq so metachars like ? stay literal.
sheet_prefix_keys="$(printf '%s\n' "$SHEET" \
  | sed -n 's/^  prefix \([^ ]\) .*/\1/p' | sort -u)"
[ -n "$sheet_prefix_keys" ] || fail "no 'prefix X' rows parsed from the sheet"
# Prefix binds shipped in the conf: `bind <key> ...` or `bind-key <key> ...`,
# excluding root-table `bind -n ...` ($2 == "-n"). F9/mouse are surfaced as the
# F9 / "● N" rows and checked separately, so they must not be `bind <key>` here.
conf_prefix_keys="$(awk '$1=="bind"||$1=="bind-key"{ if ($2!="-n") print $2 }' "$CONF" | sort -u)"
[ -n "$conf_prefix_keys" ] || fail "no prefix binds parsed from the conf"

# --- 1. every 'prefix X' row in the sheet is bound in the conf -----------------
while IFS= read -r k; do
  [ -n "$k" ] || continue
  printf '%s\n' "$conf_prefix_keys" | grep -Fxq "$k" \
    || fail "sheet lists 'prefix $k' but conf has no matching bind"
done <<EOF
$sheet_prefix_keys
EOF

# F9 (root-table) is documented in the sheet and must exist as `bind -n F9`.
printf '%s\n' "$SHEET" | grep -q 'F9' || fail "sheet missing the F9 row"
grep -Eq '^bind[[:space:]]+-n[[:space:]]+F9([[:space:]]|$)' "$CONF" \
  || fail "sheet lists F9 but conf has no 'bind -n F9'"

# --- 2. every prefix bind in the conf is documented in the sheet --------------
while IFS= read -r k; do
  [ -n "$k" ] || continue
  printf '%s\n' "$sheet_prefix_keys" | grep -Fxq "$k" \
    || fail "conf binds 'prefix $k' but the sheet does not document it"
done <<EOF
$conf_prefix_keys
EOF

# --- 3. the popup wiring is present -------------------------------------------
grep -q 'bin/fleet-keys.sh' "$CONF"   || fail "conf has no fleet-keys.sh popup bind"
grep -Eq '^bind[[:space:]]+\?[[:space:]]+display-popup' "$CONF" \
  || fail "conf 'prefix ?' is not a display-popup"
grep -Eq -- '--bind "\?:.*fleet-keys.sh' "$DASH" \
  || fail "dashboard has no '?' bind opening fleet-keys.sh"
grep -Eq -- '--bind "ctrl-k:.*fleet-keys.sh' "$ISSUES" \
  || fail "backlog has no '⌃k' bind opening fleet-keys.sh"

printf 'selftest OK: cheatsheet matches shipped binds (%s prefix keys checked)\n' \
  "$(printf '%s\n' "$sheet_prefix_keys" | grep -c .)"
