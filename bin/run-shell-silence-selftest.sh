#!/bin/bash
# run-shell-silence-selftest.sh — a backgrounded tmux job must never paint the
# operator's screen (issue #575).
#
# THE BUG: `tmux run-shell` CAPTURES its command's stdout and, when non-empty,
# opens a full-pane view-mode overlay on the attached client that only Esc/q
# dismisses. So any `run-shell -b` job that prints hijacks whatever window the
# operator was in, whenever a daemon happens to fire. The repo knew this (it is
# written into fleet-lib.sh, dash-issue-session.sh, fleet-cleanup.sh) but the rule
# lived only in prose, and four call sites missed it in the same way: they
# redirected the OUTER tmux's stderr — `2>/dev/null` OUTSIDE the quotes — and
# handed the inner script's stdout straight to tmux:
#   fleet-quotawatch.sh  ×2  (fleet-model-switch --capped, fleet-account migrate)
#   tmux-dash-collect.sh ×2  (fleet-model-switch --model, fleet-account migrate)
#   usage-modal.sh       ×1  (fleet-account migrate --idle — no outer redirect either)
#   session-end-hook.sh  ×2  (the detached --exec reap)
# All of them already carry `--toast`, i.e. they report on the STATUS LINE via
# display-message; the stdout copy is for a human running them by hand.
#
# THE FIX this test guards, in two layers:
#   A. CENTRAL   fleet_bg wraps every dispatch as `( <cmd>\n) >/dev/null 2>&1 || :`,
#                so a call site cannot forget, and takes `-L <socket>` so a
#                headless daemon has no reason to hand-roll `tmux -L … run-shell`.
#                The `|| :` closes the SECOND route to the same overlay: tmux opens
#                the view on a NONZERO EXIT too, even from a job that printed
#                nothing (E4 below pins that down).
#   B. STATIC    no bin/*.sh may dispatch `run-shell` with a LITERAL command string
#                that runs a script without an inner redirect. This section is what
#                goes red on a pre-fix checkout (prove it:
#                `git worktree add /tmp/pre <pre-fix-sha>` then
#                `bash bin/run-shell-silence-selftest.sh /tmp/pre/bin`).
#
# Sections: A static scan · B fleet_bg wraps · C -L / FLEET_BG_SOCK routing ·
#           D the wrap survives an awkward command tail · E REAL tmux repro.
#
# E needs tmux; absent → that section SKIPs (the rest still runs), per the
# run-selftests convention. It builds its own server on a private -S socket and
# reaps it on exit — never the operator's live server.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SCAN_DIR="${1:-$BIN}"                 # arg = scan another checkout's bin/ (red-on-master proof)
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rss-selftest.XXXXXX")" || exit 2
REAL_TMUX="$(command -v tmux 2>/dev/null)"
SOCK="$WORK/tmux.sock"
cleanup() {
  [ -n "$REAL_TMUX" ] && [ -S "$SOCK" ] && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not fire on a signal — turn INT/TERM/HUP into a normal exit
# so the isolated server is reaped rather than leaked to the machine (issue #152).
trap 'exit 130' INT TERM HUP

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok()   { printf 'ok: %s\n' "$1"; }

# ============================================================================
# A. STATIC GUARD — every LITERAL `run-shell` command string that runs a script
#    must redirect INSIDE the string.
#
# Rule: on a line that dispatches `run-shell`, take the command string (from the
# first quote after `run-shell` to the LAST quote on the line — so a trailing
# outer `2>/dev/null` is correctly left OUT), and if that string invokes an
# interpreter with a script path (`bash '…/x.sh' …`) it must also mention
# /dev/null. Deliberately NOT flagged: a command carried in a variable
# (`run-shell -b "$cmd"`) — the redirect lives where the variable is built, and
# dash-raw-session-selftest.sh / dash-issue-async-spawn-selftest.sh already assert
# it there. Comments are skipped, and so are *-selftest.sh (fakes and fixtures).
# ============================================================================
[ -d "$SCAN_DIR" ] || fail "scan dir not found: $SCAN_DIR"

# NB: the scan writes to a FILE rather than into a `$( … )` — bash's recursive
# parse of a command substitution mis-tracks the quotes in a multi-line awk
# program and dies on the regexes below.
: > "$WORK/offenders"
for f in "$SCAN_DIR"/*.sh; do
  [ -f "$f" ] || continue
  case "$f" in *-selftest.sh) continue ;; esac
  awk -v F="$f" '
    function cmdstr(rest,   j, c, q, s, m, k) {
      q = ""
      for (j = 1; j <= length(rest); j++) {
        c = substr(rest, j, 1)
        if (c == "\"" || c == "\047") { q = c; break }
      }
      if (q == "") return ""
      s = substr(rest, j + 1)
      k = 0
      for (m = 1; m <= length(s); m++) if (substr(s, m, 1) == q) k = m
      if (k == 0) return ""
      return substr(s, 1, k - 1)
    }
    {
      t = $0; sub(/^[[:space:]]+/, "", t)
      if (t ~ /^#/) next                       # a comment, not a dispatch
      i = index($0, "run-shell"); if (i == 0) next
      cmd = cmdstr(substr($0, i + 9)); if (cmd == "") next
      # Does the command string RUN something through a shell (bash <script>,
      # bash <var>, sh -c …)? That is the shape whose stdout is a script report
      # — the thing that ends up overlaying the operator screen.
      # (No apostrophes in this awk program: they would close its quoting.)
      if (cmd !~ /(^|[[:space:]])(bash|sh|zsh)[[:space:]]/) next
      if (index(cmd, "/dev/null") > 0) next    # silenced inside the string — good
      printf "%s:%d: %s\n", F, FNR, t
    }
  ' "$f" >> "$WORK/offenders"
done
offenders="$(cat "$WORK/offenders")"
[ -n "$offenders" ] && fail \
  "A a run-shell command string runs a script WITHOUT an inner redirect — its stdout becomes an Esc-to-dismiss view over the operator's window (#575). Dispatch via fleet_bg (or add '>/dev/null 2>&1' INSIDE the quotes):" \
  "$offenders"
ok "A no bin/*.sh dispatches an unsilenced literal run-shell script command"

# The four known-bad call sites must now go through fleet_bg, not a hand-rolled
# `tmux … run-shell -b` — the regression this issue is actually about.
for pair in \
  "fleet-quotawatch.sh|fleet-model-switch.sh' --capped" \
  "fleet-quotawatch.sh|fleet-account.sh' migrate --account" \
  "tmux-dash-collect.sh|--model '\$fb'" \
  "tmux-dash-collect.sh|fleet-account.sh' migrate --limited" \
  "usage-modal.sh|fleet-account.sh' migrate --idle" \
  "session-end-hook.sh|session-end-hook.sh' --exec worker" \
  "session-end-hook.sh|session-end-hook.sh' --exec raw" ; do
  sf="${pair%%|*}"; pat="${pair#*|}"
  [ -f "$SCAN_DIR/$sf" ] || continue
  line="$(grep -nF -- "$pat" "$SCAN_DIR/$sf" | grep -v '^[0-9]*: *#' | head -n1)"
  [ -n "$line" ] || fail "A2 $sf: call site '$pat' not found — did it move? re-point this guard"
  case "$line" in
    *fleet_bg*) : ;;
    *) fail "A2 $sf must dispatch '$pat' via fleet_bg (silenced centrally, #575)" "$line" ;;
  esac
done
ok "A2 every known-noisy dispatch (quotawatch/collector/usage-modal/session-end) goes through fleet_bg"

# ============================================================================
# B + C. fleet_bg's own contract, driven through a PATH `tmux` shim that LOGS its
#    argv instead of talking to any server (no tmux needed, nothing to clean up).
# ============================================================================
mkdir -p "$WORK/bin"
LOG="$WORK/tmux.args"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a"; done >> "$LOG"
printf -- '--\n' >> "$LOG"
exit 0
EOF
chmod +x "$WORK/bin/tmux"

# shellcheck source=/dev/null
. "$LIB"
command -v fleet_bg >/dev/null 2>&1 || fail "fleet_bg not defined by fleet-lib.sh"

PATH="$WORK/bin:$PATH"

: > "$LOG"
fleet_bg "bash '/x/noisy.sh' --toast"
body="$(sed -n '/^run-shell$/,/^--$/p' "$LOG" | sed '1d;/^-b$/d;/^--$/d')"
case "$body" in
  "( bash '/x/noisy.sh' --toast"*) : ;;
  *) fail "B fleet_bg must wrap the command in a SUBSHELL (braces would let an 'exit n' escape the '|| :')" "$body" ;;
esac
case "$body" in
  *") >/dev/null 2>&1 || :") : ;;
  *) fail "B fleet_bg must redirect the group to /dev/null AND swallow the exit status (a nonzero exit opens the same view)" "$body" ;;
esac
case "$body" in
  *"--toast"$'\n'")"*) : ;;
  *) fail "B the closing paren must sit on its OWN line (a command ending in & ; or #comment must still close)" "$body" ;;
esac
grep -qx -- '-b' "$LOG" || fail "B fleet_bg must background the job (run-shell -b)" "$(cat "$LOG")"
ok "B fleet_bg wraps the command as '( … \\n) >/dev/null 2>&1 || :' and backgrounds it"

# C1. bare → no -L (inherits $TMUX from the calling pane)
grep -qx -- '-L' "$LOG" && fail "C1 a bare fleet_bg must NOT pass -L (it rides the caller's \$TMUX)" "$(cat "$LOG")"
ok "C1 bare fleet_bg rides the caller's \$TMUX — no -L"

# C2. -L <socket> → routed to that socket, and the flag is CONSUMED (not run)
: > "$LOG"
fleet_bg -L "sockA" "bash '/x/noisy.sh'"
head -n2 "$LOG" | tr '\n' ' ' | grep -q -- '-L sockA' \
  || fail "C2 fleet_bg -L <socket> must dispatch on that socket" "$(cat "$LOG")"
grep -q -- '-L' <<<"$(sed -n '/^run-shell$/,$p' "$LOG")" \
  && fail "C2 the -L flag must be consumed, not passed into the command body" "$(cat "$LOG")"
ok "C2 fleet_bg -L <socket> routes to that socket and consumes the flag"

# C3. FLEET_BG_SOCK is the whole-script fallback; an explicit -L wins over it.
: > "$LOG"
( FLEET_BG_SOCK=sockEnv; fleet_bg "bash '/x/n.sh'" )
head -n2 "$LOG" | tr '\n' ' ' | grep -q -- '-L sockEnv' \
  || fail "C3 FLEET_BG_SOCK must route a headless caller" "$(cat "$LOG")"
: > "$LOG"
# shellcheck disable=SC2034  # it IS read — by fleet_bg, and losing that race to -L is the point
( FLEET_BG_SOCK=sockEnv; fleet_bg -L sockArg "bash '/x/n.sh'" )
head -n2 "$LOG" | tr '\n' ' ' | grep -q -- '-L sockArg' \
  || fail "C3 an explicit -L must win over FLEET_BG_SOCK" "$(cat "$LOG")"
ok "C3 FLEET_BG_SOCK routes headless callers; an explicit -L wins"

# ============================================================================
# D. The wrap must be SH-PARSEABLE for awkward command tails — run the body the
#    way tmux does (`sh -c`) and check it still executes.
# ============================================================================
: > "$LOG"
fleet_bg "printf hi > '$WORK/d1.out'   # trailing comment"
body="$(sed -n '/^run-shell$/,/^--$/p' "$LOG" | sed '1d;/^-b$/d;/^--$/d')"
sh -c "$body" || fail "D the wrapped body must parse+run under sh -c" "$body"
[ "$(cat "$WORK/d1.out" 2>/dev/null)" = "hi" ] || fail "D a command with a trailing #comment must still run" "$body"
: > "$LOG"
fleet_bg "printf bye > '$WORK/d2.out';"
body="$(sed -n '/^run-shell$/,/^--$/p' "$LOG" | sed '1d;/^-b$/d;/^--$/d')"
sh -c "$body" || fail "D a command with a trailing ';' must still parse" "$body"
[ "$(cat "$WORK/d2.out" 2>/dev/null)" = "bye" ] || fail "D a command with a trailing ';' must still run" "$body"
ok "D the wrapped body parses and runs under sh -c (trailing #comment / ';')"

# ============================================================================
# E. THE REAL REPRO — on a REAL, isolated tmux server (its own -S socket, torn
#    down at exit): a bare `run-shell -b` that prints puts its pane in VIEW MODE;
#    the same command through fleet_bg leaves the pane alone.
# ============================================================================
if [ -z "$REAL_TMUX" ]; then
  printf 'selftest: tmux not installed — SKIP section E (the live repro)\n' >&2
  printf '\nrun-shell-silence-selftest: PASS (E skipped)\n'
  exit 0
fi

# Route the plain `tmux` that fleet_bg calls to the private socket.
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"

tmux new-session -d -s t -x 120 -y 30 2>/dev/null || fail "E could not start the isolated tmux server"
paneA="$(tmux list-panes -t t -F '#{pane_id}' | head -n1)"
paneB="$(tmux split-window -d -P -F '#{pane_id}' -t "$paneA")"
[ -n "$paneA" ] && [ -n "$paneB" ] && [ "$paneA" != "$paneB" ] || fail "E could not build two distinct panes"

in_mode() { tmux display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null; }
settle()  { i=0; while [ "$i" -lt 40 ]; do [ "$(in_mode "$1")" = "${2:-1}" ] && return 0; i=$((i+1)); sleep 0.1; done; return 1; }

[ "$(in_mode "$paneA")" = 0 ] || fail "E pane A started in a mode — bad fixture"

# E1. BUG REPRO: the unsilenced form provably opens the overlay.
tmux run-shell -b -t "$paneA" "echo NOISY-MIGRATE-REPORT"
settle "$paneA" 1 || fail "E1 a printing run-shell should have put pane A in view mode (the bug this guards) — got '$(in_mode "$paneA")'"
ok "E1 repro: an unsilenced 'run-shell -b' that prints DOES open the Esc-to-dismiss view"

# E2. THE FIX: the same noisy command via fleet_bg leaves the pane untouched.
#     FLEET_BG_TARGET is not a thing — target the pane the way run-shell does by
#     making B the ACTIVE pane, which is exactly what a real dispatch hits.
tmux select-pane -t "$paneB"
fleet_bg "echo NOISY-MIGRATE-REPORT; echo second line"
# Give the job the same grace the repro needed, then assert it never flipped.
i=0; while [ "$i" -lt 15 ]; do [ "$(in_mode "$paneB")" = 1 ] && break; i=$((i+1)); sleep 0.1; done
[ "$(in_mode "$paneB")" = 0 ] \
  || fail "E2 fleet_bg must NOT leave the active pane in view mode — its output has to be swallowed (#575)"
ok "E2 the same noisy command via fleet_bg leaves the pane out of view mode"

# E3. …and the job actually RAN (silencing must not mean skipping).
fleet_bg "echo ran > '$WORK/e3.out'"
i=0; while [ "$i" -lt 40 ]; do [ -s "$WORK/e3.out" ] && break; i=$((i+1)); sleep 0.1; done
[ "$(cat "$WORK/e3.out" 2>/dev/null)" = "ran" ] || fail "E3 the backgrounded job must still run"
[ "$(in_mode "$paneB")" = 0 ] || fail "E3 pane B must still be out of view mode"
ok "E3 the silenced job still runs (side effects land; only the chatter is dropped)"

# E4. THE OTHER ROUTE: a job that prints NOTHING but exits nonzero opens the very
#     same overlay (tmux appends its own "did not exit successfully"). fleet_bg's
#     `|| :` has to swallow that too — a backgrounded job has no tail of its own to
#     put an `exit 0` on, the way dash-zoom.sh / hub-zoom.sh do.
tmux run-shell -b -t "$paneA" "( exit 3
) >/dev/null 2>&1"
settle "$paneA" 1 || fail "E4 a silenced-but-FAILING run-shell should have opened the view (the second route this guards) — got '$(in_mode "$paneA")'"
tmux select-pane -t "$paneB"
fleet_bg "exit 3"
i=0; while [ "$i" -lt 15 ]; do [ "$(in_mode "$paneB")" = 1 ] && break; i=$((i+1)); sleep 0.1; done
[ "$(in_mode "$paneB")" = 0 ] \
  || fail "E4 fleet_bg must swallow a nonzero exit — tmux turns it into the same Esc-to-dismiss view (#575)"
ok "E4 a job that exits nonzero (silent or not) still leaves the pane out of view mode"

printf '\nrun-shell-silence-selftest: PASS\n'
exit 0
