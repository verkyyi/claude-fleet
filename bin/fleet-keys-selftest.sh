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
#   3. The `?` popup bind exists in the conf, and the dash (`?`) + backlog (`?`)
#      each open fleet-keys.sh — scoped to their own panel (issue #265).
#   4. The sheet renders non-empty in --plain mode and lists all four groups.
#   5. Context scoping (issue #265): `--context dash`/`--context backlog` show
#      that panel + the global `tmux prefix` group, and drop the OTHER panels.
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
# Also EXCLUDE the "restore-a-tmux-default" binds (issue #289): `bind n
# next-window` and `bind r refresh-client` exist only so a live server reverts
# cleanly when the fleet stops overriding those keys (a bare unbind would leave
# them dead) — they are not fleet shortcuts, so the cheatsheet deliberately omits
# them and this guard must not demand a sheet row for them.
conf_prefix_keys="$(awk '$1=="bind"||$1=="bind-key"{ if ($2!="-n" && $3!="next-window" && $3!="refresh-client") print $2 }' "$CONF" | sort -u)"
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
# The `?` bind opens a display-popup; since issue #308 it is wrapped with a
# `set -g @popup_open 1 \; … \; set -g @popup_open 0` flag (pause the dash repaint
# under the modal), so allow anything between the key and `display-popup`.
grep -Eq '^bind[[:space:]]+\?[[:space:]].*display-popup' "$CONF" \
  || fail "conf 'prefix ?' does not open a display-popup"
# The in-panel opens are scoped to their own panel (issue #265): the dash `?`
# passes `--context dash`, the backlog `⌃k` passes `--context backlog` — while the
# global `prefix ?` (checked above) stays the full sheet.
grep -Eq -- '--bind "\?:.*fleet-keys.sh --context dash' "$DASH" \
  || fail "dashboard '?' does not open fleet-keys.sh scoped '--context dash'"
# `?` opens the cheatsheet two ways depending on mode (#123, renamed ⌃k→? in
# #289 for one `?` convention everywhere): a windowed panel binds `?` straight to
# fleet-keys.sh; the prefix+b popup can't nest a popup, so `?` drops a 'keys'
# sentinel that the gap dispatcher maps to fleet-keys.sh. Assert both halves of
# the chain so a break in either fails the guard (not a loose grep).
grep -Eq -- '\?:.*(keys|fleet-keys\.sh.*--context backlog)' "$ISSUES" \
  || fail "backlog has no '?' bind wired to the (backlog-scoped) keys cheatsheet"
grep -Eq -- 'keys\).*fleet-keys\.sh.*--context backlog' "$ISSUES" \
  || fail "backlog '?' keys-sentinel dispatch does not open '--context backlog'"

# --- 5. context scoping drops the OTHER panels (issue #265) --------------------
# `--context dash` ⇒ tmux prefix + dashboard only; backlog/config gone.
DSHEET="$(NO_COLOR=1 bash "$KEYS" --plain --context dash)" \
  || fail "fleet-keys.sh --context dash exited non-zero"
printf '%s\n' "$DSHEET" | grep -qi '^tmux prefix '  || fail "--context dash dropped the global 'tmux prefix' group"
printf '%s\n' "$DSHEET" | grep -qi '^dashboard '    || fail "--context dash missing its own 'dashboard' group"
printf '%s\n' "$DSHEET" | grep -qi '^backlog '      && fail "--context dash should NOT list the 'backlog' group"
printf '%s\n' "$DSHEET" | grep -qi '^config modal ' && fail "--context dash should NOT list the 'config modal' group"
# `--context backlog` ⇒ tmux prefix + backlog only; dashboard/config gone.
BSHEET="$(NO_COLOR=1 bash "$KEYS" --plain --context backlog)" \
  || fail "fleet-keys.sh --context backlog exited non-zero"
printf '%s\n' "$BSHEET" | grep -qi '^tmux prefix '  || fail "--context backlog dropped the global 'tmux prefix' group"
printf '%s\n' "$BSHEET" | grep -qi '^backlog '      || fail "--context backlog missing its own 'backlog' group"
printf '%s\n' "$BSHEET" | grep -qi '^dashboard '    && fail "--context backlog should NOT list the 'dashboard' group"
printf '%s\n' "$BSHEET" | grep -qi '^config modal ' && fail "--context backlog should NOT list the 'config modal' group"

printf 'selftest OK: cheatsheet matches shipped binds (%s prefix keys checked)\n' \
  "$(printf '%s\n' "$sheet_prefix_keys" | grep -c .)"
