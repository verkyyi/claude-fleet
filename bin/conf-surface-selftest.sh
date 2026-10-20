#!/bin/bash
# conf-surface-selftest.sh — the config surface cannot quietly grow back (issue #1101).
#
# conf/fleet.conf.reference is the ONE list of settings (and their defaults). A list
# trimmed once grows back one undocumented `${FLEET_X:-5}` at a time, and keeps a
# row whose reader is gone. This pins both directions:
#
#   A  every key in conf/fleet.conf.reference has a READER — a non-comment line
#      outside the reference (a dead key would be a row that does nothing);
#   B  every `${FLEET_X:-…}` / `${FLEET_X-…}` / `${FLEET_X:=…}` a script in bin/ or
#      hooks/ reads is either a key in the example (any @tier) or listed in
#      conf/fleet-env-internal.list (env handoffs, test seams, paths, knobs);
#   C  the list stays honest: each line carries a reason, no name is both listed
#      and in the example, and every listed name is still read somewhere.
#
# Selftests are excluded from the scan on both sides: a test may set any name.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$BIN/.."
EX="$ROOT/conf/fleet.conf.reference"
WL="$ROOT/conf/fleet-env-internal.list"
pass=0
ok()   { pass=$((pass+1)); }
[ -f "$EX" ] || st_fail "no conf/fleet.conf.reference at $EX"
[ -f "$WL" ] || st_fail "no conf/fleet-env-internal.list at $WL"

st_sandbox "${TMPDIR:-/tmp}/conf-surface.XXXXXX"

# The scanned scripts: bin/ + hooks/, minus selftests. -L follows the shadow
# root's symlinked bin/ (run-selftests.sh), which holds links, not files.
find -L "$BIN" "$ROOT/hooks" -maxdepth 1 -type f ! -name '*selftest*' 2>/dev/null | sort > "$WORK/scripts"
[ -s "$WORK/scripts" ] || st_fail 'found no scripts to scan'
# Readers for A also include the skills/commands (a key read only by a slash
# command's markdown is still read), minus the config writer, which names keys
# generically.
{ cat "$WORK/scripts"
  find -L "$ROOT/commands" "$ROOT/skills" "$ROOT/plugins" "$ROOT/conf" "$ROOT/extras" "$ROOT/shell" -type f 2>/dev/null
} | grep -vE '/(fleet_config_write\.py|fleet-env-internal\.list|fleet\.conf\.reference)$' \
  | grep -vE '/[^/]*selftest[^/]*$' > "$WORK/readers"   # basename only: the shadow root's own path says "selftest"

grep -oE '^#?[[:space:]]*FLEET_[A-Z0-9_]+=' "$EX" | sed -E 's/^#?[[:space:]]*//; s/=$//' | sort -u > "$WORK/example"
grep -vE '^[[:space:]]*(#|$)' "$WL" | awk '{print $1}' | sort > "$WORK/listed"
sort -u "$WORK/listed" > "$WORK/listed.u"

# --- C: the list itself -------------------------------------------------------
dup=$(uniq -d "$WORK/listed")
[ -z "$dup" ] || st_fail "listed twice in fleet-env-internal.list: $dup"; ok
bad=$(grep -vE '^[[:space:]]*(#|$)' "$WL" | awk 'NF < 3 || $1 !~ /^FLEET_[A-Z0-9_]+$/ {print $1}')
[ -z "$bad" ] || st_fail "fleet-env-internal.list lines need 'NAME kind: reason': $bad"; ok
both=$(comm -12 "$WORK/listed.u" "$WORK/example")
[ -z "$both" ] || st_fail "in BOTH the example and fleet-env-internal.list (keep one): $both"; ok

# --- B: every ${FLEET_X:-…} a script reads is documented or listed -----------
# shellcheck disable=SC2046
tr '\n' '\0' < "$WORK/scripts" | xargs -0 grep -ohE '\$\{FLEET_[A-Z0-9_]+:?[-=]' 2>/dev/null \
  | sed -E 's/^\$\{//; s/:?[-=]$//' | sort -u > "$WORK/read"
[ -s "$WORK/read" ] || st_fail 'scan found no ${FLEET_X:-…} reads at all — the scanner is broken'; ok
cat "$WORK/example" "$WORK/listed.u" | sort -u > "$WORK/known"
new=$(comm -23 "$WORK/read" "$WORK/known")
[ -z "$new" ] || st_fail "read by a script but neither in conf/fleet.conf.reference nor conf/fleet-env-internal.list:
$new
— a setting an operator might change goes in the example (with a tag line; @tier=internal
  if it is pacing); an env handoff / test seam / path goes in the list, with a reason."
ok

# --- A + C: every documented key and every listed name is read somewhere -----
# A comment does not read a key ("FLEET_X left with #N"), and the reference itself
# is not its own reader: both once kept a dead row alive (issue #4905).
mentions() { xargs -0 grep -hwE 'FLEET_[A-Z0-9_]+' 2>/dev/null | grep -vE '^[[:space:]]*#' \
               | grep -owE 'FLEET_[A-Z0-9_]+' | sort -u; }
tr '\n' '\0' < "$WORK/readers" | mentions > "$WORK/mentioned"
dead=$(comm -23 "$WORK/example" "$WORK/mentioned")
[ -z "$dead" ] || st_fail "in conf/fleet.conf.reference but read by nothing (a dead row): $dead"; ok
# (C counts a comment: B reads one too, so a name only a comment spells stays listed.)
cat "$WORK/scripts" "$WORK/readers" | tr '\n' '\0' | xargs -0 grep -ohwE 'FLEET_[A-Z0-9_]+' 2>/dev/null \
  | sort -u > "$WORK/mentioned.all"
stale=$(comm -23 "$WORK/listed.u" "$WORK/mentioned.all")
[ -z "$stale" ] || st_fail "in fleet-env-internal.list but read by nothing (drop the line): $stale"; ok

# --- the short sample at the root is generated from the reference (issue #3576) ---
bash "$BIN/fleet-conf-example.sh" --check || st_fail "fleet.conf.example is stale — bin/fleet-conf-example.sh > fleet.conf.example"; ok

# --- the global-only list == the @scope=global tags (issue #237) -------------
# fleet_load_conf strips exactly fleet-lib's $_FLEET_GLOBAL_ONLY from a per-fleet
# overlay, so that list MUST equal the keys the reference tags @scope=global (each
# key's tag line is the @label= comment in its block, directly above it). Drift
# makes a global-only key per-fleet-overridable again, or strips a per-fleet one.
# (Held by the config modal's selftest until the modal went, issue #4902.)
ex_global=$(awk '
  { L[NR] = $0 }
  END {
    for (n = 1; n <= NR; n++) {
      if (L[n] !~ /^#?[[:space:]]*FLEET_[A-Z0-9_]+=/) continue
      k = L[n]; sub(/^#?[[:space:]]*/, "", k); sub(/=.*/, "", k)
      for (i = n - 1; i >= 1; i--) {
        if (L[i] ~ /^[[:space:]]*$/ || L[i] !~ /^[[:space:]]*#/) break
        if (L[i] ~ /@label=/) { if (L[i] ~ /@scope=global([[:space:]]|$)/) print k; break }
      }
    }
  }' "$EX" | sort -u | tr '\n' ' ')
lib_global=$( . "$BIN/fleet-lib.sh" >/dev/null 2>&1; printf '%s' "$_FLEET_GLOBAL_ONLY" | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ' )
[ "$ex_global" = "$lib_global" ] || st_fail "_FLEET_GLOBAL_ONLY (bin/fleet-lib.sh) != the @scope=global keys of conf/fleet.conf.reference:
  only in the lib:       $(comm -23 <(tr ' ' '\n' <<< "$lib_global" | grep .) <(tr ' ' '\n' <<< "$ex_global" | grep .) | tr '\n' ' ')
  only in the reference: $(comm -13 <(tr ' ' '\n' <<< "$lib_global" | grep .) <(tr ' ' '\n' <<< "$ex_global" | grep .) | tr '\n' ' ')"
ok
n=$(printf '%s' "$ex_global" | wc -w | tr -d ' ')

printf 'conf-surface selftest PASS: %d assertions (%s keys · %s listed · %s reads · %s global-only)\n' \
  "$pass" "$(grep -c . "$WORK/example")" "$(grep -c . "$WORK/listed.u")" "$(grep -c . "$WORK/read")" "$n"
