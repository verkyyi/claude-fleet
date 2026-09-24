#!/bin/bash
# conf-surface-selftest.sh — the config surface cannot quietly grow back (issue #1101).
#
# fleet.conf.example is the ONE list of settings (and their defaults); the prefix+c
# modal renders it. #1101 cut the modal's face from 178 rows to ≤ 120 by tagging
# pacing/budget/timeout knobs @tier=internal — but a list trimmed once grows back
# one undocumented `${FLEET_X:-5}` at a time. This pins both directions:
#
#   A  every key in fleet.conf.example has a READER outside the example + the
#      modal plumbing (a dead key would be a row that does nothing);
#   B  every `${FLEET_X:-…}` / `${FLEET_X-…}` / `${FLEET_X:=…}` a script in bin/ or
#      hooks/ reads is either a key in the example (any @tier) or listed in
#      conf/fleet-env-internal.list (env handoffs, test seams, paths, knobs);
#   C  the list stays honest: each line carries a reason, no name is both listed
#      and in the example, and every listed name is still read somewhere.
#
# Selftests are excluded from the scan on both sides: a test may set any name.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
EX="$ROOT/fleet.conf.example"
WL="$ROOT/conf/fleet-env-internal.list"
pass=0
ok()   { pass=$((pass+1)); }
fail() { printf 'conf-surface FAIL: %s\n' "$1" >&2; exit 1; }
[ -f "$EX" ] || fail "no fleet.conf.example at $EX"
[ -f "$WL" ] || fail "no conf/fleet-env-internal.list at $WL"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/conf-surface.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

# The scanned scripts: bin/ + hooks/, minus selftests. -L follows the shadow
# root's symlinked bin/ (run-selftests.sh), which holds links, not files.
find -L "$BIN" "$ROOT/hooks" -maxdepth 1 -type f ! -name '*selftest*' 2>/dev/null | sort > "$WORK/scripts"
[ -s "$WORK/scripts" ] || fail 'found no scripts to scan'
# Readers for A also include the skills/commands (a key read only by a slash
# command's markdown is still read), minus the modal plumbing, which names keys
# generically.
{ cat "$WORK/scripts"
  find -L "$ROOT/commands" "$ROOT/skills" "$ROOT/conf" "$ROOT/extras" "$ROOT/shell" -type f 2>/dev/null
} | grep -vE '/(fleet-config-lib\.sh|tmux-config\.sh|dash-config-edit\.sh|fleet_config_write\.py|fleet-env-internal\.list)$' \
  | grep -vE '/[^/]*selftest[^/]*$' > "$WORK/readers"   # basename only: the shadow root's own path says "selftest"

grep -oE '^#?[[:space:]]*FLEET_[A-Z0-9_]+=' "$EX" | sed -E 's/^#?[[:space:]]*//; s/=$//' | sort -u > "$WORK/example"
grep -vE '^[[:space:]]*(#|$)' "$WL" | awk '{print $1}' | sort > "$WORK/listed"
sort -u "$WORK/listed" > "$WORK/listed.u"

# --- C: the list itself -------------------------------------------------------
dup=$(uniq -d "$WORK/listed")
[ -z "$dup" ] || fail "listed twice in fleet-env-internal.list: $dup"; ok
bad=$(grep -vE '^[[:space:]]*(#|$)' "$WL" | awk 'NF < 3 || $1 !~ /^FLEET_[A-Z0-9_]+$/ {print $1}')
[ -z "$bad" ] || fail "fleet-env-internal.list lines need 'NAME kind: reason': $bad"; ok
both=$(comm -12 "$WORK/listed.u" "$WORK/example")
[ -z "$both" ] || fail "in BOTH the example and fleet-env-internal.list (keep one): $both"; ok

# --- B: every ${FLEET_X:-…} a script reads is documented or listed -----------
# shellcheck disable=SC2046
tr '\n' '\0' < "$WORK/scripts" | xargs -0 grep -ohE '\$\{FLEET_[A-Z0-9_]+:?[-=]' 2>/dev/null \
  | sed -E 's/^\$\{//; s/:?[-=]$//' | sort -u > "$WORK/read"
[ -s "$WORK/read" ] || fail 'scan found no ${FLEET_X:-…} reads at all — the scanner is broken'; ok
cat "$WORK/example" "$WORK/listed.u" | sort -u > "$WORK/known"
new=$(comm -23 "$WORK/read" "$WORK/known")
[ -z "$new" ] || fail "read by a script but neither in fleet.conf.example nor conf/fleet-env-internal.list:
$new
— a setting an operator might change goes in the example (with a tag line; @tier=internal
  if it is pacing); an env handoff / test seam / path goes in the list, with a reason."
ok

# --- A + C: every documented key and every listed name is read somewhere -----
tr '\n' '\0' < "$WORK/readers" | xargs -0 grep -ohwE 'FLEET_[A-Z0-9_]+' 2>/dev/null | sort -u > "$WORK/mentioned"
dead=$(comm -23 "$WORK/example" "$WORK/mentioned")
[ -z "$dead" ] || fail "in fleet.conf.example but read by nothing (a dead row): $dead"; ok
# (a listed name may be read by the modal plumbing itself — FLEET_CONFIG_SHOW_INTERNAL)
cat "$WORK/scripts" "$WORK/readers" | tr '\n' '\0' | xargs -0 grep -ohwE 'FLEET_[A-Z0-9_]+' 2>/dev/null \
  | sort -u > "$WORK/mentioned.all"
stale=$(comm -23 "$WORK/listed.u" "$WORK/mentioned.all")
[ -z "$stale" ] || fail "in fleet-env-internal.list but read by nothing (drop the line): $stale"; ok

# --- the face stays small ------------------------------------------------------
n=$(bash -c '. "$1/fleet-config-lib.sh"; fcfg_table | grep -c .' _ "$BIN")
[ "$n" -le 120 ] || fail "the config modal's default view has $n rows (cap 120) — tag pacing knobs @tier=internal"; ok

printf 'conf-surface selftest PASS: %d assertions (%s keys · %s listed · %s reads · face %s rows)\n' \
  "$pass" "$(grep -c . "$WORK/example")" "$(grep -c . "$WORK/listed.u")" "$(grep -c . "$WORK/read")" "$n"
