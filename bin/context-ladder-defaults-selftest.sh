#!/bin/bash
# context-ladder-defaults-selftest.sh — the context ladder's repo defaults are ONE
# set of numbers (issue #1571): compact in place from 55%, at most 3 times per
# session, hand off at 80%. A machine whose fleet.conf says nothing must run the
# same ladder as one that writes those three lines — before #1571 one machine wrote
# 35/55 by hand and the other ran the code's 70/OFF/2, so sessions on the two lived
# different lives.
#
# The defaults are spelled in several places (each a different language or a hot
# path that cannot source a shared table), so this test holds them in lockstep:
#   A  fleet.conf.example's commented defaults ARE 55 / 80 / 3
#   B  every code default equals fleet.conf.example's (a lint — the next edit to
#      one site without the others reds here):
#        bin/set-claude-state.sh    the Stop hook (_hp / _cp / _cm)
#        bin/fleet-context.sh       the read the session asks
#        conf/statusline.sh         the header band (handoff line only)
#        bin/fleet-doctor.sh        the `handoff` row (d_h / d_c / d_m)
#        bin/fleet-codex-session.py the codex context read (handoff line only)
#   C  behaviour: fleet-context.sh with NO conf anywhere (this shadow root has no
#      fleet.conf; outside tmux there is no overlay) prints 80 / 55 / 3, text + JSON
#   D  0 still means off for each key
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
EX="$ROOT/fleet.conf.example"
CTX="$BIN/fleet-context.sh"

pass=0 failn=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { failn=$((failn + 1)); printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; }

# ---- A: fleet.conf.example --------------------------------------------------------
exval() { sed -n "s/^#$1=\([0-9][0-9]*\)[[:space:]].*/\1/p" "$EX" | head -1; }
H=$(exval FLEET_AUTO_HANDOFF_PCT); C=$(exval FLEET_COMPACT_PREP_PCT); M=$(exval FLEET_COMPACT_MAX)
[ "$H/$C/$M" = "80/55/3" ] && ok "A fleet.conf.example: handoff 80 · compact-prep 55 · max 3" \
  || bad "A fleet.conf.example must document 80/55/3, got '$H/$C/$M'"
[ -n "$H" ] && [ -n "$C" ] && [ -n "$M" ] || { printf 'context-ladder-defaults-selftest: FAIL (no defaults parsed)\n' >&2; exit 1; }

# ---- B: every code site carries the same numbers ----------------------------------
# site <file> <fixed string> <what>
site() {
  if grep -qF -- "$2" "$ROOT/$1"; then ok "B $1: $3"
  else bad "B $1 must carry the fleet.conf.example default ($3): no '$2'"; fi
}
site bin/set-claude-state.sh    "then _hp=$H; else _hp=0; fi"            "handoff $H"
site bin/set-claude-state.sh    "then _cp=$C; else _cp=0; fi"            "compact-prep $C"
site bin/set-claude-state.sh    "then _cm=$M; else _cm=0; fi"            "compact max $M"
site bin/fleet-context.sh       "\${FLEET_AUTO_HANDOFF_PCT:-$H}"         "handoff $H"
site bin/fleet-context.sh       "\${FLEET_COMPACT_PREP_PCT:-$C}"         "compact-prep $C"
site bin/fleet-context.sh       "\${FLEET_COMPACT_MAX:-$M}"              "compact max $M"
site conf/statusline.sh         "[[ -z \"\$SL_PCT\" ]] && SL_PCT=$H"     "handoff $H"
site bin/fleet-doctor.sh        "then d_h=$H d_c=$C d_m=$M;"             "$H / $C / $M"
site bin/fleet-codex-session.py "value.stdout.strip() or '$H'"           "handoff $H"
# …and none of the retired numbers is left behind as a default.
for f in bin/set-claude-state.sh bin/fleet-doctor.sh; do
  if grep -nE "then _(cp|cm)=(70|2);|csees=70|\(unset ⇒ 2;" "$ROOT/$f" >/dev/null; then
    bad "B $f still carries a pre-#1571 default" "$(grep -nE "then _(cp|cm)=(70|2);|csees=70|\(unset ⇒ 2;" "$ROOT/$f")"
  fi
done

# ---- C: fleet-context.sh with no conf at all ---------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ladder-defaults.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/projects"
T="$WORK/t.jsonl"
printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":1000,"cache_read_input_tokens":20000,"output_tokens":500}}}\n' > "$T"
[ -f "$ROOT/fleet.conf" ] && bad "C precondition: this root must have no fleet.conf (run through run-selftests.sh)" "$ROOT/fleet.conf"
# nocfg [KEY=val …] [--flag …] — fleet-context.sh from a clean env: no conf layer,
# no tmux; KEY=val words go to the environment, the rest to the script.
nocfg() {
  local envs=() args=() a
  for a in "$@"; do case "$a" in *=*) envs+=("$a") ;; *) args+=("$a") ;; esac; done
  env -i PATH="$PATH" HOME="$WORK/home" TMPDIR="$WORK" CLAUDE_PROJECTS_DIR="$WORK/projects" \
      FLEET_CONF_DIR="$WORK/home/.config/claude-fleet" FLEET_SKIP_GLOBAL_CONF=1 ${envs[@]+"${envs[@]}"} \
    bash "$CTX" --transcript "$T" ${args[@]+"${args[@]}"} 2>&1
}
out=$(nocfg)
case "$out" in *"auto-handoff at ${H}% · watch from $((H - 15))%"*) ok "C text: auto-handoff at ${H}%" ;;
  *) bad "C with no conf fleet-context.sh must print 'auto-handoff at ${H}%'" "$out" ;; esac
case "$out" in *"compact   in place from ${C}% · at most $M per session"*) ok "C text: compact in place from ${C}%, at most $M" ;;
  *) bad "C with no conf fleet-context.sh must print 'compact   in place from ${C}% · at most $M per session'" "$out" ;; esac
out=$(nocfg --json)
case "$out" in *"\"handoff_pct\":$H,\"auto_handoff_pct\":$H,\"compact_prep_pct\":$C,\"compact_max\":$M,"*) ok "C json: $H / $C / $M" ;;
  *) bad "C --json must carry auto_handoff_pct $H, compact_prep_pct $C, compact_max $M" "$out" ;; esac

# ---- D: 0 is still off -----------------------------------------------------------
out=$(nocfg FLEET_AUTO_HANDOFF_PCT=0 FLEET_COMPACT_PREP_PCT=0)
case "$out" in *'auto-handoff OFF (FLEET_AUTO_HANDOFF_PCT=0)'*'in-place compaction OFF (FLEET_COMPACT_PREP_PCT=0)'*) ok "D 0 = off for both lines" ;;
  *) bad "D an explicit 0 must still turn each line off" "$out" ;; esac
out=$(nocfg FLEET_COMPACT_MAX=0)
case "$out" in *"in place from ${C}% · no cap"*) ok "D FLEET_COMPACT_MAX=0 = no cap" ;;
  *) bad "D FLEET_COMPACT_MAX=0 must read 'no cap'" "$out" ;; esac

if [ "$failn" -gt 0 ]; then
  printf 'context-ladder-defaults-selftest: FAIL (%s failed, %s ok)\n' "$failn" "$pass" >&2; exit 1
fi
printf 'context-ladder-defaults-selftest: PASS (%s checks)\n' "$pass"
