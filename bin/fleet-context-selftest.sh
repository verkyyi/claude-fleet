#!/bin/bash
# fleet-context-selftest.sh — hermetic test for the self-context read (issue #464).
#
# bin/fleet-context.sh answers "how full is THIS session's context?" — the read
# Claude Code exposes to the human but not to the model. It folds TWO sources:
# a synthetic transcript under a FAKE ~/.claude/projects tree (CLAUDE_PROJECTS_DIR)
# and the @ctx_pct stamp read off a FAKE tmux (the same PATH-shim shape
# bin/auto-handoff-selftest.sh uses). No tmux server, no live Claude, no network.
#
# Legs:
#   RESOLVE   a session id globs to its transcript across project dirs, even from
#             an unrelated cwd; --transcript overrides; nothing found → UNKNOWN.
#   SUM       live context = the LAST main-thread assistant usage row (input +
#             cache_creation + cache_read + output); sidechain rows are EXCLUDED;
#             a torn final line is skipped, not fatal; turns/output/peak fold.
#   BANDS     FLEET_AUTO_HANDOFF_PCT sets HANDOFF at the threshold and WATCH 15
#             below; with it off the statusline's own 50/80 bands apply.
#   STAMP     a numeric @ctx_pct wins over the derived percentage (src=statusline)
#             and a non-numeric/absent stamp falls back to the transcript.
#   LIMIT     the denominator chain (#477): @ctx_limit → FLEET_CONTEXT_LIMIT →
#             200000, each named in the output, so a default-limit reading is
#             never mistaken for an authoritative one.
#   BUS       a pane inside tmux with NO @ctx_pct stamp is reported as a DEAD
#             measurement bus — the failure that also silently switches off the
#             auto-handoff nudge — and never reported outside tmux.
#   EXIT      0 for OK, 1 for every other verdict (mirrors fleet-pr-verdict.sh).
#
# Exit 0 = pass, non-zero = fail (prints which leg diverged). jq absent → SKIP.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CTX="$BIN/fleet-context.sh"
[ -f "$CTX" ] || { printf 'selftest: %s not found\n' "$CTX" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'fleet-context-selftest: jq absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-context-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/projects/-tmp-someone-issue-7" "$WORK/projects/-tmp-elsewhere"

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; fails=$((fails+1)); }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }   # $2=got $3=want
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output containing '$3'" "$2" ;; esac; }

# --- fake tmux: answer @ctx_pct / @handoff_armed from FAKE_* -------------------
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
[ "${1:-}" = "display-message" ] || exit 0
case "$*" in
  *@ctx_pct*)       printf '%s\n' "${FAKE_CTX_PCT:-}" ;;
  *@ctx_limit*)     printf '%s\n' "${FAKE_CTX_LIMIT:-}" ;;
  *@handoff_armed*) printf '%s\n' "${FAKE_ARMED:-}" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- a synthetic transcript ---------------------------------------------------
# One assistant row per line. `usage` carries the four fields the script sums; a
# sidechain row and a torn line are planted to prove they're ignored.
row() {  # $1=input $2=cache_creation $3=cache_read $4=output $5=sidechain(true/false)
  printf '{"type":"assistant","isSidechain":%s,"message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
    "$5" "$1" "$2" "$3" "$4"
}
T="$WORK/projects/-tmp-someone-issue-7/sess-abc.jsonl"
{
  row 1 1000 20000 500 false          # 21501
  printf '{"type":"user","message":{"content":"hi"}}\n'
  row 9 9000 900000 9000 true         # SIDECHAIN — must be ignored
  row 2 2000 40000 800 false          # 42802  ← the live figure
  printf '{"type":"assistant","isSidech'                  # TORN final line
} > "$T"

run() { PATH="$WORK/fakepath:$PATH" CLAUDE_PROJECTS_DIR="$WORK/projects" TMUX="fake" TMUX_PANE="%9" "$CTX" "$@" 2>&1; }
# same, but OUTSIDE tmux — no pane to carry a stamp, so no bus to call dead.
run_notmux() { PATH="$WORK/fakepath:$PATH" CLAUDE_PROJECTS_DIR="$WORK/projects" env -u TMUX -u TMUX_PANE "$CTX" "$@" 2>&1; }

printf '\n-- RESOLVE --\n'
out=$(cd / && run --session sess-abc --json); rc=$?
has "session id globs to its transcript from an unrelated cwd" "$out" '"live_tokens":42802'
is  "OK verdict exits 0" "$rc" "0"
out=$(run --transcript "$T" --json)
has "--transcript override reads the same file" "$out" '"live_tokens":42802'
out=$(cd / && run --session nope-no-such --json); rc=$?
has "no transcript anywhere → UNKNOWN" "$out" '"verdict":"UNKNOWN"'
is  "UNKNOWN exits 1" "$rc" "1"

printf '\n-- SUM --\n'
out=$(run --transcript "$T" --json)
has "live = LAST main-thread row, not the max"      "$out" '"live_tokens":42802'
has "sidechain row excluded from the turn count"    "$out" '"turns":2'
has "output tokens sum main-thread rows only"       "$out" '"output_tokens":1300'
has "peak folds main-thread rows"                   "$out" '"peak_tokens":42802'
case "$out" in *900000*) bad "sidechain tokens leak into the fold" "no 900000 anywhere" "$out" ;; *) ok "sidechain tokens never leak" ;; esac
out=$(FLEET_CONTEXT_LIMIT=100000 run --transcript "$T" --json)
has "FLEET_CONTEXT_LIMIT sets the denominator" "$out" '"derived_pct":43'

printf '\n-- BANDS --\n'
# 42802/200000 = 21% → OK on the default bands.
out=$(run --transcript "$T" -q); is "21% is OK on the default 50/80 bands" "$out" "OK"
out=$(FLEET_CONTEXT_LIMIT=100000 run --transcript "$T" -q); is "43% still OK" "$out" "OK"
out=$(FLEET_CONTEXT_LIMIT=70000  run --transcript "$T" -q); is "61% is WATCH" "$out" "WATCH"
out=$(FLEET_CONTEXT_LIMIT=50000  run --transcript "$T" -q); is "86% is HANDOFF" "$out" "HANDOFF"
out=$(FLEET_AUTO_HANDOFF_PCT=60 FLEET_CONTEXT_LIMIT=70000 run --transcript "$T" -q)
is "threshold 60 makes 61% HANDOFF, not WATCH" "$out" "HANDOFF"
out=$(FLEET_AUTO_HANDOFF_PCT=60 FLEET_CONTEXT_LIMIT=90000 run --transcript "$T" -q)
is "threshold 60 makes 48% WATCH (the 15 points below it)" "$out" "WATCH"
out=$(FLEET_AUTO_HANDOFF_PCT=60 FLEET_CONTEXT_LIMIT=100000 run --transcript "$T" -q)
is "43% is still OK — just under the 45% watch floor" "$out" "OK"
out=$(FLEET_AUTO_HANDOFF_PCT=60 FLEET_CONTEXT_LIMIT=200000 run --transcript "$T" -q)
is "threshold 60 leaves 21% OK" "$out" "OK"

printf '\n-- STAMP --\n'
out=$(FAKE_CTX_PCT=91 run --transcript "$T" --json)
has "numeric @ctx_pct wins the percentage"   "$out" '"pct":91'
has "and is named as the source"             "$out" '"source":"statusline"'
has "the derived figure is still reported"   "$out" '"derived_pct":21'
out=$(FAKE_CTX_PCT=91 run --transcript "$T" -q); is "the stamp drives the verdict" "$out" "HANDOFF"
out=$(FAKE_CTX_PCT="null" run --transcript "$T" --json)
has "a non-numeric stamp falls back to the transcript" "$out" '"source":"transcript"'
out=$(FAKE_CTX_PCT=91 FAKE_ARMED=1 run --transcript "$T" --json)
has "@handoff_armed is surfaced" "$out" '"armed":true'
out=$(FAKE_CTX_PCT=44 run --session nope-no-such --json)
has "a stamp alone (no transcript) still yields a verdict" "$out" '"pct":44'

printf '\n-- LIMIT (#477) --\n'
# The stamped window size WINS over the conf value: 42802/1000000 = 4%, not the
# 43% FLEET_CONTEXT_LIMIT alone would give. This is the 1M-window case that read
# 197% before the chain existed.
out=$(FAKE_CTX_LIMIT=1000000 FLEET_CONTEXT_LIMIT=100000 run --transcript "$T" --json)
has "@ctx_limit wins over FLEET_CONTEXT_LIMIT" "$out" '"limit":1000000'
has "…and drives the derived percentage"       "$out" '"derived_pct":4'
has "…and is named as the limit source"        "$out" '"limit_source":"stamp"'
# With no stamp, the conf value is still honoured (the per-fleet override).
out=$(FLEET_CONTEXT_LIMIT=100000 run --transcript "$T" --json)
has "no stamp → FLEET_CONTEXT_LIMIT is used" "$out" '"limit":100000'
has "…named as the conf source"              "$out" '"limit_source":"conf"'
# With neither, 200000 — and it says so, which is the whole point.
out=$(run --transcript "$T" --json)
has "neither → the 200k default" "$out" '"limit":200000'
has "…named as the default"      "$out" '"limit_source":"default"'
# A junk stamp is ignored rather than trusted.
out=$(FAKE_CTX_LIMIT="null" FLEET_CONTEXT_LIMIT=100000 run --transcript "$T" --json)
has "a non-numeric @ctx_limit falls through to conf" "$out" '"limit_source":"conf"'
out=$(FAKE_CTX_LIMIT=0 run --transcript "$T" --json)
has "a zero @ctx_limit falls through to the default" "$out" '"limit_source":"default"'
# The human line names the source too.
out=$(run --transcript "$T")
has "the context line names the limit source" "$out" "limit=default"
# CROSS wording: a wide stamp-vs-derived gap is the wrong denominator, not the
# autocompact reserve — the explanation must not claim otherwise.
out=$(FAKE_CTX_PCT=41 run --transcript "$T")
has "a wide gap blames the limit" "$out" "the derived figure used the default limit"
case "$out" in *"autocompact reserve"*) bad "a wide gap must not blame the reserve" "no 'autocompact reserve'" "$out" ;; *) ok "a wide gap never blames the reserve" ;; esac
# …while a narrow gap keeps the reserve explanation (21% derived vs 25% stamped).
out=$(FAKE_CTX_PCT=25 run --transcript "$T")
has "a narrow gap keeps the reserve explanation" "$out" "autocompact reserve"

printf '\n-- BUS (#477) --\n'
# In a pane with no stamp: a dead bus, named, with its auto-handoff consequence.
out=$(FLEET_AUTO_HANDOFF_PCT=60 run --transcript "$T")
has "an unstamped pane reports a dead bus"    "$out" "@ctx_pct is not stamped on this pane"
has "…and names the auto-handoff consequence" "$out" "auto-handoff at 60% cannot fire"
out=$(run --transcript "$T" --json)
has "the bus state is machine-readable"       "$out" '"bus":"unstamped"'
# Stamped → nothing to warn about.
out=$(FAKE_CTX_PCT=41 run --transcript "$T")
case "$out" in *"not stamped on this pane"*) bad "a stamped pane must not warn" "no bus warning" "$out" ;; *) ok "a stamped pane raises no bus warning" ;; esac
out=$(FAKE_CTX_PCT=41 run --transcript "$T" --json)
has "…and reports the bus as ok" "$out" '"bus":"ok"'
# Outside tmux there is no bus to be dead — never warn (a CLI/cron caller).
out=$(run_notmux --transcript "$T")
case "$out" in *"not stamped on this pane"*) bad "outside tmux must not warn" "no bus warning" "$out" ;; *) ok "outside tmux raises no bus warning" ;; esac
out=$(run_notmux --transcript "$T" --json)
has "…and reports the bus as n/a" "$out" '"bus":"n/a"'

printf '\n================ fleet-context selftest ================\n'
[ "$fails" -eq 0 ] && { printf 'PASS — all legs\n'; exit 0; }
printf 'FAIL — %s check(s)\n' "$fails"; exit 1
