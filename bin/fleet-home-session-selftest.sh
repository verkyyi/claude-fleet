#!/bin/bash
# fleet-home-session-selftest.sh — `fleet claude` / `fleet codex` (issue #2264,
# EPIC #2259 C5): bin/fleet → bin/fleet-home-session.sh → the home machine's
# bin/fleet-client-place.sh `- home` over `fleet-thin.py --run` (issue #3004; the
# old client's own road went with it, issue #3008) → the thin client onto it.
#
#   A. the dispatch: `fleet codex hi there` places `- home --agent codex --new`
#      on the home (a fake ssh, FLEET_THIN_ARGV_CMD) with "hi there" in its body
#      file, and the thin client goes to the window the place answered
#      (FLEET_HOME_THIN_CMD); --node travels; a RESUME answer goes back to that
#      session; a refused place says why with its code and attaches nothing; a
#      bad option is exit 2 and places nothing; no terminal is exit 2
#   B. `fleet claude --here …` is `fleet run claude …`: the same script, the same
#      words, the same answer (here: FLEET_CRED_PROXY off → exit 3, one line)
#   D. `fleet-client-place.sh - home` is `- scratch`; a home with a repo is exit 2
#   F. the guard (#1931): a session's `fleet codex` is a client start; `--here` is not
#
# No tmux, no network. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-home-session selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fhs-st.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
mkdir -p "$WORK/home" "$WORK/tmp" "$WORK/rbin" "$WORK/conf"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" XDG_CONFIG_HOME="$WORK/home/.config" XDG_CACHE_HOME="$WORK/home/.cache"
export FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp" FLEET_NODE_STATE="$WORK/no-node"
unset TMUX TMUX_PANE FLEET_HUB_URL FLEET_HUB_TOKEN CCQUOTA_FLEET CCQUOTA_HUB_URL FLEET_HOME_THIN_CMD

FAILS=0; CHECKS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
ok()   { printf 'ok   %s\n' "$*"; }
eq()   { CHECKS=$((CHECKS + 1)); if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ok "$1" ;; *) fail "$1: [$2] lacks [$3]" ;; esac; }

# --- A. the dispatch ------------------------------------------------------------------
# the home's one-shot ssh: runs the command it was handed, here
cat > "$WORK/ssh.sh" <<'SH'
#!/bin/bash
for a in "$@"; do last=$a; done
eval "$last"
SH
printf '#!/bin/sh\nprintf %s\n' "'{\"argv\": [\"bash\", \"$WORK/ssh.sh\", \"home\"], \"host\": 2, \"route\": \"lan\"}\\n'" > "$WORK/argv.sh"
# the home's place: one line per call (its argv and a body file's text), then the answer in $WORK/answer
cat > "$WORK/rbin/fleet-client-place.sh" <<EOF
#!/bin/bash
{ printf 'place:%s' "\$*"
  prev=''; for a in "\$@"; do [ "\$prev" = --body-file ] && printf '|body=%s' "\$(cat "\$a")"; prev=\$a; done
  printf '\n'; } >> "$WORK/place.log"
cat "$WORK/answer"
exit "\$(cat "$WORK/answer.rc" 2>/dev/null || echo 0)"
EOF
export FLEET_THIN_ARGV_CMD="sh $WORK/argv.sh" FLEET_THIN_LOG="$WORK/thin.log" FLEET_REMOTE_BIN="$WORK/rbin"
home() {   # home <fleet args…> → $rc, $out; the place's calls in place.log, the thin client's target in want
  : > "$WORK/place.log"; rm -f "$WORK/want"
  out=$(FLEET_HOME_THIN_CMD="printf '%s' \"\$1\" > '$WORK/want'" sh "$BIN/fleet" "$@" 2>&1 </dev/null); rc=$?
}
printf 'LOCAL -\t@7 issue\n' > "$WORK/answer"; rm -f "$WORK/answer.rc"
home codex hi there
eq "A fleet codex hi there: exit 0" "$rc" 0
has "A the home places a new home codex session" "$(cat "$WORK/place.log")" "place:- home --agent codex --new --body-file "
has "A the first sentence rides in the body file" "$(cat "$WORK/place.log")" "|body=hi there"
eq "A one place, nothing else" "$(wc -l < "$WORK/place.log" | tr -d ' ')" 1
eq "A the thin client goes to the window placed" "$(cat "$WORK/want" 2>/dev/null)" "@7"
home claude --node mac-a
eq "A --node: the place names it, no body, no --new" "$(cat "$WORK/place.log")" "place:- home --agent claude --node mac-a"
printf 'RESUME - U/f1/scratch-3\tback\n' > "$WORK/answer"
home claude
eq "A RESUME: back to that session" "$(cat "$WORK/want" 2>/dev/null)" "U/f1/scratch-3"
printf 'REFUSED -\t没有机器能开 — mac-c 满了\n' > "$WORK/answer"; echo 4 > "$WORK/answer.rc"
home claude
eq "A a refused place: its code" "$rc" 4
has "A …says why" "$out" "没有机器能开"
eq "A …and attaches nothing" "$([ -e "$WORK/want" ] && echo attached)" ""
rm -f "$WORK/answer.rc"
home codex --bogus
eq "A a bad option: exit 2" "$rc" 2
eq "A a bad option places nothing" "$(wc -l < "$WORK/place.log" | tr -d ' ')" 0
: > "$WORK/place.log"
sh "$BIN/fleet" codex hi </dev/null >/dev/null 2>&1; rc=$?
eq "A no terminal: exit 2, nothing placed" "$rc:$(wc -l < "$WORK/place.log" | tr -d ' ')" "2:0"

# --- B. --here is fleet run -----------------------------------------------------------
oa=$(FLEET_CRED_PROXY=0 sh "$BIN/fleet" claude --here --model x 2>&1); ra=$?
ob=$(FLEET_CRED_PROXY=0 sh "$BIN/fleet" run claude --model x 2>&1); rb=$?
eq "B fleet claude --here answers as fleet run claude" "$ra|$oa" "$rb|$ob"
eq "B (switched off: exit 3)" "$ra" 3
oa=$(FLEET_CRED_PROXY=0 sh "$BIN/fleet" codex hi --here 2>&1); ra=$?
ob=$(FLEET_CRED_PROXY=0 sh "$BIN/fleet" run codex hi 2>&1); rb=$?
eq "B --here anywhere: the other words are fleet run's" "$ra|$oa" "$rb|$ob"

# --- D. client-place: home = a no-repo scratch ----------------------------------------
bash "$BIN/fleet-client-place.sh" o/a home >/dev/null 2>&1; rc=$?
eq "D a home with a repo: exit 2" "$rc" 2

# --- F. the guard ---------------------------------------------------------------------
g() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
        | env -u FLEET_HUB FLEET_WORKER_CRED=fwc1.x FLEET_HEAVY=0 FLEET_LIB=/nonexistent python3 "$ROOT/hooks/bash-guard.py" >/dev/null 2>&1
      echo $?; }
eq "F a session's fleet codex is a client start" "$(g 'fleet codex hi')" 2
eq "F fleet claude --here is not" "$(g 'fleet claude --here')" 0
eq "F fleet --test-identity codex passes" "$(g 'fleet --test-identity codex')" 0

printf '%s checks, %s failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" = 0 ]
