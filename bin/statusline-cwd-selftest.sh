#!/bin/bash
# statusline-cwd-selftest.sh — the status line's cwd + git segments (issue #1361).
#
# conf/statusline.sh drops segment 2 (cwd) and 3 (git branch + dirty star) in a
# fleet pane — the tmux window name and task bar already show both — and skips the
# 2-3 `git` runs behind them. FLEET_STATUSLINE_CWD: auto (default) | 1 | 0.
#
#   A  outside tmux, auto: the output is BYTE FOR BYTE today's line (bar │ cwd │
#      branch* │ model), git asked three times.
#   B  in a fleet pane (socket label has a fleet conf), auto: no cwd, no branch,
#      and git is NEVER called (a stub counts every call).
#   C  in tmux on a socket that is NOT a fleet (ad-hoc `default`): shown as today.
#   D  FLEET_STATUSLINE_CWD=1 shows in a fleet pane; =0 hides outside tmux.
#   E  the key is read from the install's fleet.conf + $FLEET_CONF_DIR/fleet.settings
#      (settings wins, quotes stripped) ahead of the environment — as fleet-lib
#      sources them.
#   F  the default has one home: fleet_statusline_cwd prints auto, and the status
#      line's own fallback is the same word.
#
# Hermetic: the status line is copied into a sandbox install (so ../fleet.conf is
# ours), fake `git` / `tmux` on PATH, HOME + FLEET_CONF_DIR in a temp dir.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SL="$BIN/../conf/statusline.sh"
[ -f "$SL" ] || { printf 'selftest: %s missing\n' "$SL" >&2; exit 2; }
if ! command -v jq >/dev/null 2>&1; then
  printf 'selftest: SKIP — jq not on PATH (the status line is jq-gated)\n'; exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/statusline-cwd.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/inst/conf" "$WORK/stub" "$WORK/home" "$WORK/cfg/fleets/fleet-x"
cp "$SL" "$WORK/inst/conf/statusline.sh"
: > "$WORK/cfg/fleets/fleet-x/conf"
GITLOG="$WORK/git.log"
cat > "$WORK/stub/git" <<EOF
#!/bin/sh
echo "\$*" >> "$GITLOG"
case "\$*" in
  *rev-parse*)        echo issue-9 ;;
  *"diff --cached"*)  exit 0 ;;
  *diff*)             exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$WORK/stub/tmux"
chmod +x "$WORK/stub/git" "$WORK/stub/tmux"

INPUT='{"workspace":{"current_dir":"'"$WORK"'/home/proj"},"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.4,"context_window_size":200000}}'

# render [VAR=val …] — run the sandboxed status line with a clean fleet env.
render() {
  : > "$GITLOG"
  env -u TMUX -u TMUX_PANE -u FLEET_STATUSLINE_CWD \
      HOME="$WORK/home" FLEET_CONF_DIR="$WORK/cfg" PATH="$WORK/stub:$PATH" "$@" \
      bash "$WORK/inst/conf/statusline.sh" <<< "$INPUT"
}
gitcalls() { wc -l < "$GITLOG" | tr -d ' '; }

R=$'\033[0m'; D=$'\033[2m'; B=$'\033[1m'
SEP="${D} │ ${R}"
BAR=$'\033[32m████░░░░░░ 42%'"$R"
CWDSEG="${B}"$'\033[36m~/proj'"$R"
BRSEG=$'\033[33missue-9*'"$R"
MODSEG=$'\033[35mOpus'"$R"
FULL="${BAR}${SEP}${CWDSEG}${SEP}${BRSEG}${SEP}${MODSEG}"
BARE="${BAR}${SEP}${MODSEG}"
FLEETPANE=(TMUX="/private/tmp/tmux-501/fleet-x,123,0" TMUX_PANE=%1)
ADHOC=(TMUX="/private/tmp/tmux-501/default,123,0" TMUX_PANE=%1)

# --- A: outside tmux, today's bytes ----------------------------------------
out=$(render)
[ "$out" = "$FULL" ] || fail "A: outside tmux must be today's line" "$(printf '%q\n%q' "$out" "$FULL")"
[ "$(gitcalls)" = 3 ] || fail "A: expected 3 git calls, got $(gitcalls)" "$(cat "$GITLOG")"
ok "A outside tmux: byte-identical line, 3 git calls"

# --- B: fleet pane, auto ----------------------------------------------------
out=$(render "${FLEETPANE[@]}")
[ "$out" = "$BARE" ] || fail "B: a fleet pane must drop cwd + branch" "$(printf '%q\n%q' "$out" "$BARE")"
[ "$(gitcalls)" = 0 ] || fail "B: a fleet pane must not call git" "$(cat "$GITLOG")"
ok "B fleet pane: no cwd, no branch, 0 git calls"

# legacy flat <sess>.conf counts as a fleet too
rm "$WORK/cfg/fleets/fleet-x/conf"; : > "$WORK/cfg/fleet-x.conf"
out=$(render "${FLEETPANE[@]}")
[ "$out" = "$BARE" ] || fail "B: a legacy <sess>.conf fleet must drop cwd + branch" "$(printf '%q' "$out")"
rm "$WORK/cfg/fleet-x.conf"; : > "$WORK/cfg/fleets/fleet-x/conf"
ok "B legacy flat conf: also a fleet pane"

# --- C: tmux, not a fleet ---------------------------------------------------
out=$(render "${ADHOC[@]}")
[ "$out" = "$FULL" ] || fail "C: an ad-hoc tmux session must keep cwd + branch" "$(printf '%q' "$out")"
ok "C ad-hoc tmux socket: shown as today"

# --- D: the switch ----------------------------------------------------------
out=$(render "${FLEETPANE[@]}" FLEET_STATUSLINE_CWD=1)
[ "$out" = "$FULL" ] || fail "D: =1 must show in a fleet pane" "$(printf '%q' "$out")"
out=$(render FLEET_STATUSLINE_CWD=0)
[ "$out" = "$BARE" ] || fail "D: =0 must hide outside tmux" "$(printf '%q' "$out")"
[ "$(gitcalls)" = 0 ] || fail "D: =0 must not call git" "$(cat "$GITLOG")"
ok "D FLEET_STATUSLINE_CWD=1 shows, =0 hides (no git)"

# --- E: read from the conf files, settings last -----------------------------
printf 'FLEET_STATUSLINE_CWD=0\n' > "$WORK/inst/fleet.conf"
out=$(render FLEET_STATUSLINE_CWD=1)
[ "$out" = "$BARE" ] || fail "E: the install fleet.conf must win over the env" "$(printf '%q' "$out")"
printf '# x\nexport FLEET_STATUSLINE_CWD="1"   # show it\n' > "$WORK/cfg/fleet.settings"
out=$(render "${FLEETPANE[@]}")
[ "$out" = "$FULL" ] || fail "E: fleet.settings must win over fleet.conf (quoted, exported, commented)" "$(printf '%q' "$out")"
printf "FLEET_STATUSLINE_CWD='auto'\n" > "$WORK/cfg/fleet.settings"
out=$(render)
[ "$out" = "$FULL" ] || fail "E: settings auto outside tmux must show" "$(printf '%q' "$out")"
out=$(render "${FLEETPANE[@]}")
[ "$out" = "$BARE" ] || fail "E: settings auto in a fleet pane must hide" "$(printf '%q' "$out")"
rm -f "$WORK/inst/fleet.conf" "$WORK/cfg/fleet.settings"
ok "E conf files read: fleet.settings > fleet.conf > env"

# --- F: one default ---------------------------------------------------------
lib_default=$(env -u FLEET_STATUSLINE_CWD FLEET_SKIP_GLOBAL_CONF=1 bash -c '. "$1"; fleet_statusline_cwd' _ "$BIN/fleet-lib.sh")
[ "$lib_default" = auto ] || fail "F: fleet_statusline_cwd default must be auto, got '$lib_default'"
grep -q 'SL_CWD:-auto' "$SL" || fail "F: the status line's fallback must be auto (fleet_statusline_cwd)"
for v in 0 1; do
  got=$(FLEET_STATUSLINE_CWD=$v FLEET_SKIP_GLOBAL_CONF=1 bash -c '. "$1"; fleet_statusline_cwd' _ "$BIN/fleet-lib.sh")
  [ "$got" = "$v" ] || fail "F: fleet_statusline_cwd must echo $v, got '$got'"
done
ok "F default auto in fleet-lib and the status line"

printf 'selftest: statusline-cwd PASS (%d checks)\n' "$pass"
