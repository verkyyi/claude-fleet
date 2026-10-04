#!/bin/bash
# statusline-selftest.sh — conf/statusline.sh as the fleet's measurement bus (issue #1452).
#
# Since #1452 the Claude Code status line PRINTS NOTHING — the numbers moved to the
# pane header's right side (pane-header-selftest.sh) — and stamps what it reads
# onto the pane's window, only when a value changed:
#
#   A  a full render in a tmux pane: stdout + stderr EMPTY, exit 0, git never run,
#      ONE tmux write chain carrying @ctx_pct (rounded) @ctx_limit @ctx_band
#      @model @effort and the @rl* set (#1267), in that order, @rl_src unset last
#   B  nothing changed → the chain carries only the @rl* set (its @rl_ts is the
#      quota watch's freshness); with no rate_limits at all, NO tmux write
#   C  only what changed is written: a new % writes @ctx_pct + @ctx_band, not the
#      unchanged @ctx_limit / @model; a model without an effort level UNSETS
#      @effort; a payload with no model touches neither @model nor @effort; no
#      context_window touches no @ctx_*
#   D  @ctx_band follows the fleet's handoff lines, read from the conf layers the
#      cheap way: nothing set → 50/80; FLEET_AUTO_HANDOFF_PCT from the environment,
#      then the install's fleet.conf, then $FLEET_CONF_DIR/fleet.settings, then
#      THIS fleet's fleets/<sess>/conf (legacy <sess>.conf) — each winning over
#      the previous, quotes + trailing comments stripped, another fleet's overlay
#      ignored; FLEET_AUTO_HANDOFF_TOKENS wins over the % key, converted against
#      context_window_size rounded up (#1317), and falls back to the % key when
#      the payload carries no size
#   E  outside tmux: no stdout, no tmux call, exit 0; no jq on PATH: exit 0, silent
#   F  odd payloads ({} / "weird" rate_limits / a string effort or model / not
#      JSON) exit 0 with no stdout, no stderr and no @rl stamp
#
# Hermetic: the status line is copied into a sandbox install (so ../fleet.conf is
# ours), a fake `tmux` on PATH answers display-message from $FAKE_CUR and logs each
# set-window-option CALL as one line, a fake `git` fails loudly, HOME +
# FLEET_CONF_DIR in a temp dir, the two FLEET_AUTO_HANDOFF_* keys scrubbed from the
# environment.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SL="$BIN/../conf/statusline.sh"
[ -f "$SL" ] || { printf 'selftest: %s missing\n' "$SL" >&2; exit 2; }
if ! command -v jq >/dev/null 2>&1; then
  printf 'selftest: SKIP — jq not on PATH (the status line is jq-gated)\n'; exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/statusline.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/inst/conf" "$WORK/stub" "$WORK/home" "$WORK/cfg/fleets/fleet-x" "$WORK/cfg/fleets/fleet-y"
cp "$SL" "$WORK/inst/conf/statusline.sh"
TMUXLOG="$WORK/tmux.log"; GITLOG="$WORK/git.log"; ERR="$WORK/err"
cat > "$WORK/stub/tmux" <<STUB
#!/bin/sh
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
case "\${1:-}" in
  display-message)   printf '%s\n' "\${FAKE_CUR:-}" ;;
  set-window-option) printf '%s\n' "\$*" >> "$TMUXLOG" ;;
  *) exit 1 ;;
esac
STUB
printf '#!/bin/sh\necho "git \$*" >> "%s"\nexit 99\n' "$GITLOG" > "$WORK/stub/git"
chmod +x "$WORK/stub/tmux" "$WORK/stub/git"

US=$(printf '\037')
PANE='TMUX=/private/tmp/tmux-501/fleet-x,123,0 TMUX_PANE=%1'
# render [VAR=val …] — the sandboxed status line in a fleet-x pane, payload on stdin.
render() {
  : > "$TMUXLOG"; : > "$GITLOG"
  env -u FLEET_AUTO_HANDOFF_PCT -u FLEET_AUTO_HANDOFF_TOKENS \
      HOME="$WORK/home" FLEET_CONF_DIR="$WORK/cfg" PATH="$WORK/stub:$PATH" $PANE "$@" \
      bash "$WORK/inst/conf/statusline.sh" 2>"$ERR"
}
calls() { wc -l < "$TMUXLOG" | tr -d ' '; }
log()   { cat "$TMUXLOG"; }

FULL='{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"effort":{"level":"high"},"workspace":{"current_dir":"/tmp/x"},"context_window":{"used_percentage":42.4,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":12.7,"resets_at":1791031200},"seven_day":{"used_percentage":2,"resets_at":1791554400}}}'
NORL='{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"context_window":{"used_percentage":42.4,"context_window_size":200000}}'
CUR_FULL="42${US}200000${US}ok${US}Opus 5.5${US}high"

# --- A: a full render ---------------------------------------------------------
out=$(printf '%s' "$FULL" | render)
[ -z "$out" ] || fail "A: the status line must print nothing" "$(printf '%q' "$out")"
[ ! -s "$ERR" ] || fail "A: stderr must be empty" "$(cat "$ERR")"
[ ! -s "$GITLOG" ] || fail "A: git must never run" "$(cat "$GITLOG")"
[ "$(calls)" = 1 ] || fail "A: expected ONE tmux write chain, got $(calls)" "$(log)"
grep -Eq '^set-window-option -t %1 @ctx_pct 42 ; set-window-option -t %1 @ctx_limit 200000 ; set-window-option -t %1 @ctx_band ok ; set-window-option -t %1 @model Opus 5\.5 ; set-window-option -t %1 @effort high ; set-window-option -t %1 @rl5h 12 ; set-window-option -t %1 @rl7d 2 ; set-window-option -t %1 @rl_reset 1791031200 1791554400 ; set-window-option -t %1 @rl_ts [0-9]{10} ; set-window-option -u -t %1 @rl_src$' "$TMUXLOG" \
  || fail "A: the chain must stamp ctx → model/effort → rl, in order" "$(log)"
ok "A full render: silent, no git, one chain with every stamp"

# --- B: nothing changed -------------------------------------------------------
out=$(printf '%s' "$FULL" | FAKE_CUR="$CUR_FULL" render)
[ -z "$out" ] && [ "$(calls)" = 1 ] || fail "B: unchanged values + rate limits → exactly the rl chain" "$(log)"
grep -Eq '^set-window-option -t %1 @rl5h 12 ; ' "$TMUXLOG" || fail "B: the chain must START with the rl set (nothing else changed)" "$(log)"
grep -q '@ctx\|@model\|@effort' "$TMUXLOG" && fail "B: unchanged ctx/model/effort must not be re-written" "$(log)"
out=$(printf '%s' "$NORL" | FAKE_CUR="$CUR_FULL" render)
[ -z "$out" ] && [ "$(calls)" = 0 ] || fail "B: unchanged values, no rate limits → no tmux write at all" "$(log)"
ok "B unchanged: only the rl set; without rate limits, no write"

# --- C: only what changed -----------------------------------------------------
printf '%s' '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"context_window":{"used_percentage":70,"context_window_size":200000}}' \
  | FAKE_CUR="$CUR_FULL" render
[ "$(log)" = 'set-window-option -t %1 @ctx_pct 70 ; set-window-option -t %1 @ctx_band watch' ] \
  || fail "C: a new % must write @ctx_pct + @ctx_band only" "$(log)"
printf '%s' '{"model":{"display_name":"Haiku 4.5"},"context_window":{"used_percentage":42,"context_window_size":200000}}' \
  | FAKE_CUR="$CUR_FULL" render
[ "$(log)" = 'set-window-option -t %1 @model Haiku 4.5 ; set-window-option -u -t %1 @effort' ] \
  || fail "C: a model without an effort level must write @model and UNSET @effort" "$(log)"
printf '%s' '{"context_window":{"used_percentage":42,"context_window_size":200000}}' | FAKE_CUR="$CUR_FULL" render
[ "$(calls)" = 0 ] || fail "C: no model in the payload must touch neither @model nor @effort" "$(log)"
printf '%s' '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"max"}}' | FAKE_CUR="$CUR_FULL" render
[ "$(log)" = 'set-window-option -t %1 @effort max' ] || fail "C: no context_window must touch no @ctx_*, and write just the changed @effort" "$(log)"
printf '%s' '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"context_window":{"used_percentage":42}}' | FAKE_CUR="$CUR_FULL" render
[ "$(calls)" = 0 ] || fail "C: a % without a size must not unset @ctx_limit" "$(log)"
ok "C only the changed stamps are written; effort unset for a model without one"

# --- D: the band and the handoff lines ------------------------------------------
# band_of <pct> [size] [VAR=val …] → the @ctx_band the render stamps
band_of() {
  local pct="$1" size="${2:-200000}" sz=''; shift; shift 2>/dev/null
  [ "$size" != - ] && sz=",\"context_window_size\":$size"
  printf '{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":%s%s}}' "$pct" "$sz" | render "$@"
  sed -n 's/.*@ctx_band \([a-z]*\).*/\1/p' "$TMUXLOG"
}
expect() { # <want> <pct> [size] [VAR=val …]
  local want="$1"; shift; local got; got=$(band_of "$@")
  [ "$got" = "$want" ] || fail "D: band for % $1 ($*) should be $want, got '$got'" "$(log)"
}
expect ok 49;  expect watch 50;  expect watch 79;  expect handoff 80
ok "D nothing set: the 50 / 80 fallback bands"
expect handoff 30 200000 FLEET_AUTO_HANDOFF_PCT=30; expect watch 15 200000 FLEET_AUTO_HANDOFF_PCT=30; expect ok 14 200000 FLEET_AUTO_HANDOFF_PCT=30
ok "D the environment is the floor: PCT=30 → 15 / 30"
printf 'FLEET_AUTO_HANDOFF_PCT=60\n' > "$WORK/inst/fleet.conf"
expect ok 44; expect watch 45; expect handoff 60
expect ok 30 200000 FLEET_AUTO_HANDOFF_PCT=30
ok "D the install's fleet.conf (60) wins over the environment"
printf '# x\nexport FLEET_AUTO_HANDOFF_PCT="70"   # quoted, exported, commented\n' > "$WORK/cfg/fleet.settings"
expect ok 54; expect watch 55; expect watch 69; expect handoff 70
ok "D fleet.settings (70) wins over fleet.conf; quotes + comment stripped"
printf "FLEET_AUTO_HANDOFF_PCT='90'\n" > "$WORK/cfg/fleets/fleet-y/conf"
expect handoff 70
ok "D another fleet's overlay (fleet-y) is ignored"
printf "FLEET_AUTO_HANDOFF_PCT='50'\n" > "$WORK/cfg/fleets/fleet-x/conf"
expect ok 34; expect watch 35; expect handoff 50
ok "D this fleet's fleets/fleet-x/conf (50) wins over fleet.settings"
rm "$WORK/cfg/fleets/fleet-x/conf"; printf 'FLEET_AUTO_HANDOFF_PCT=40\n' > "$WORK/cfg/fleet-x.conf"
expect ok 24; expect watch 25; expect handoff 40
rm "$WORK/cfg/fleet-x.conf"
ok "D a legacy <sess>.conf overlay counts too"
printf 'FLEET_AUTO_HANDOFF_PCT=50\nFLEET_AUTO_HANDOFF_TOKENS=120000\n' > "$WORK/cfg/fleets/fleet-x/conf"
expect ok 44; expect watch 45; expect watch 59; expect handoff 60
expect handoff 50 -                                   # no size in the payload → the % key
expect handoff 12 1000000; expect watch 1 1000000; expect ok 0 1000000   # 120k of a 1M window = 12 (warn floors at 1)
printf 'FLEET_AUTO_HANDOFF_TOKENS=100001\n' > "$WORK/cfg/fleets/fleet-x/conf"
expect watch 50; expect handoff 51                    # rounded UP, as set-claude-state.sh does
printf 'FLEET_AUTO_HANDOFF_TOKENS=900000\n' > "$WORK/cfg/fleets/fleet-x/conf"
expect watch 99; expect handoff 100                   # clamped to 100
rm -f "$WORK/cfg/fleets/fleet-x/conf" "$WORK/cfg/fleet.settings" "$WORK/inst/fleet.conf"
ok "D FLEET_AUTO_HANDOFF_TOKENS wins over the % key, converted against the window size"

# --- E: no bus ------------------------------------------------------------------
: > "$TMUXLOG"
out=$(printf '%s' "$FULL" | env -u TMUX -u TMUX_PANE HOME="$WORK/home" FLEET_CONF_DIR="$WORK/cfg" PATH="$WORK/stub:$PATH" bash "$WORK/inst/conf/statusline.sh" 2>"$ERR"; echo "rc=$?")
[ "$out" = "rc=0" ] && [ ! -s "$ERR" ] && [ "$(calls)" = 0 ] || fail "E: outside tmux must print nothing, call no tmux, exit 0" "$out $(cat "$ERR") $(log)"
: > "$TMUXLOG"
out=$(printf '%s' "$FULL" | env -i HOME="$WORK/home" PATH="$WORK/stub" $PANE /bin/bash "$WORK/inst/conf/statusline.sh" 2>"$ERR"; echo "rc=$?")
[ "$out" = "rc=0" ] && [ ! -s "$ERR" ] && [ "$(calls)" = 0 ] || fail "E: no jq on PATH must exit 0 silently" "$out $(cat "$ERR") $(log)"
ok "E outside tmux / without jq: silent, exit 0"

# --- F: odd payloads --------------------------------------------------------------
for J in '{}' '{"rate_limits":"weird"}' '{"rate_limits":null}' '{"effort":"x","model":"str","context_window":"no"}' \
         '{"model":{"display_name":"x"}}' '{"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1}}}' 'not json' ''; do
  out=$(printf '%s' "$J" | render; echo "rc=$?")
  [ "$out" = "rc=0" ] || fail "F: payload [$J] must exit 0 with no stdout" "$out"
  [ ! -s "$ERR" ] || fail "F: payload [$J] must not write stderr" "$(cat "$ERR")"
  grep -q '@rl' "$TMUXLOG" && fail "F: payload [$J] must stamp no @rl* (both windows or nothing)" "$(log)"
done
printf '%s' '{"model":{"display_name":"x"}}' | render
[ "$(log)" = 'set-window-option -t %1 @model x' ] || fail "F: a lone model still stamps @model (nothing on the bus to unset)" "$(log)"
ok "F odd payloads: exit 0, silent, no half rl stamp"

printf 'selftest: statusline PASS (%d groups)\n' "$pass"
