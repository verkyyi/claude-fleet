#!/bin/bash
# desk-ticket-selftest.sh — a no-code session has a ticket too (issue #2676,
# EPIC #2668 C8): bin/fleet-ticket.sh (the one door to a ticket) and the desk
# branch of bin/dash-raw-session.sh.
#
# Hermetic: a fake tmux logs new-window / set-window-option, a fake gh answers
# the label list, the sub-issues API and close/reopen, a fake curl stands in for
# the hub's register call, and the sandbox bin/ swaps fleet-issue-file.sh /
# fleet-comment.sh / fleet-gh.sh / fleet-evidence.sh for loggers — so what is
# asserted is what fleet-ticket.sh hands each of them.
#
#   A. desk on, `--origin hub --prompt …`, no repo → ONE desk ticket in the desk
#      repo (label desk, body = the task's first line + who opened it), the window
#      stamped @desk 1 @issue N @repo <desk> beside @norepo 1, opened in $HOME, no
#      worktree, the seed told its ticket; one register call on the hub
#   B. off (no FLEET_HOST / FLEET_DESK) → nothing filed, nothing stamped, the seed
#      untouched — byte for byte the opts of an explicit --no-desk run
#   C. a scratch's spawn (origin scratch-3) → no ticket; --desk asks for one anyway
#   D. --desk=<owner/name> → the ticket is filed in THAT repo (a private project's)
#   E. a desk repo this fleet does not host → no ticket, said on stderr
#   F. hub off → the ticket is filed, NOT registered, said on stderr
#   G. a slash-command seed → ticketed, but its seed is left as typed
#   H. fleet-ticket.sh: parse · hub:N refused · read · comment · state · children ·
#      evidence · the `desk` label in the canonical taxonomy
#   I. (n) adding a repo to the fleet changes nothing for a desk spawn: the same
#      filer call and the same window options, byte for byte
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in dash-raw-session.sh fleet-ticket.sh fleet-lib.sh fleet-gh-lib.sh fleet-ui-lang.sh; do
  [ -f "$BIN/$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "selftest: python3 absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/desk-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf/fleets/testsess/repos" "$WORK/tmp" "$WORK/home"
for f in dash-raw-session.sh fleet-ticket.sh fleet-lib.sh fleet-gh-lib.sh fleet-ui-lang.sh fleet_reap_policy.py; do
  ln -s "$BIN/$f" "$WORK/bin/$f"
done
LOG="$WORK/calls"   # every stand-in appends `<name> <args…>` here
for f in fleet-issue-file.sh fleet-comment.sh fleet-gh.sh fleet-evidence.sh; do
  cat > "$WORK/bin/$f" <<EOF
#!/bin/bash
printf '%s' "$f" >> "\$CALL_LOG"; for a in "\$@"; do a=\${a//\$'\\n'/\\\\n}; printf ' [%s]' "\$a" >> "\$CALL_LOG"; done; echo >> "\$CALL_LOG"
[ "$f" = fleet-issue-file.sh ] && { [ "\${FILE_FAIL:-0}" = 1 ] && exit 1
  r=''; while [ "\$#" -gt 0 ]; do [ "\$1" = --repo ] && r=\$2; shift; done
  echo "https://github.com/\$r/issues/\${TICKET_N:-42}"; }
exit 0
EOF
  chmod +x "$WORK/bin/$f"
done

cat > "$WORK/fakebin/tmux" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  display-message)
    case "$*" in
      *-p*) case "$*" in *session_name*) echo testsess ;; *pane_id*) echo '%9' ;; *) echo '' ;; esac ;;
    esac ;;
  list-windows)      printf 'home\n' ;;
  new-window)        printf 'NEWWIN %s\n' "$*" >> "$NEWWIN_LOG"; echo '@9' ;;
  set-window-option) printf 'SETOPT %s\n' "$*" >> "$OPTS_LOG" ;;
esac
exit 0
EOF
cat > "$WORK/fakebin/gh" <<'EOF'
#!/bin/bash
printf 'gh' >> "$CALL_LOG"; for a in "$@"; do printf ' [%s]' "$a" >> "$CALL_LOG"; done; echo >> "$CALL_LOG"
case "$1 $2" in
  "label list") printf 'bug\n%s' "${GH_LABELS:-desk}" ;;
  "api repos/acme/desk/issues/7/sub_issues") printf 'acme/desk\t8\tOPEN\nacme/widgets\t3\tCLOSED\n' ;;
esac
exit 0
EOF
cat > "$WORK/fakebin/curl" <<'EOF'
#!/bin/bash
printf 'curl' >> "$CALL_LOG"; for a in "$@"; do printf ' [%s]' "$a" >> "$CALL_LOG"; done; echo >> "$CALL_LOG"
printf '201'
EOF
chmod +x "$WORK/fakebin/"*

# A fleet of two repos: no --repo ⇒ a no-repo session (issue #1943).
printf 'FLEET_SESSION=testsess\n' > "$WORK/conf/fleets/testsess/conf"
add_repo() {  # <owner/name>
  local slug; slug=$(printf '%s' "$1" | tr '/' '-')
  printf 'FLEET_REPO=%s\nFLEET_MAIN=%s\n' "$1" "$WORK/main-$slug" > "$WORK/conf/fleets/testsess/repos/$slug.conf"
  printf '%s\n' "$slug" >> "$WORK/conf/fleets/testsess/repos/.order"
}
add_repo acme/desk; add_repo acme/widgets
printf 'CCQUOTA_TOKEN=tok\nCCQUOTA_HUB_URL=http://hub.test\n' > "$WORK/conf/node.env"

NEWWIN_LOG="$WORK/newwin"; OPTS_LOG="$WORK/opts"
run_raw() {   # env prefix per leg; args → dash-raw-session.sh
  : > "$NEWWIN_LOG"; : > "$OPTS_LOG"; : > "$LOG"
  find "$WORK" -name 'task_norepo-*' -exec rm -f {} + 2>/dev/null
  env -u CCQUOTA_HUB_URL -u CCQUOTA_TOKEN \
  FLEET_ORIGIN_GATE=0 HOME="$WORK/home" PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" \
  FLEET_CONF_DIR="$WORK/conf" FLEET_DESK_REPO="${DESK_REPO:-acme/desk}" FLEET_GH_WRITE_GAP=0 \
  CALL_LOG="$LOG" NEWWIN_LOG="$NEWWIN_LOG" OPTS_LOG="$OPTS_LOG" FLEET_UI_LANG=zh \
    bash ${XTRACE:+-x} "$WORK/bin/dash-raw-session.sh" "$@" testsess >"$WORK/out" 2>"$WORK/err"
}
opts() { grep -v '@norepo_sid\|@fleet_id\|@born' "$OPTS_LOG"; }   # minus what is minted per run
seed() { cat "$(find "$WORK" -name 'task_norepo-*' 2>/dev/null | head -1)" 2>/dev/null; }

# ============================ A: the desk ticket ==============================
FLEET_HOST=1 CCQUOTA_FLEET=1 run_raw --origin hub --prompt $'写设计页：编排架构\n第二行细节'
grep -q 'fleet-issue-file.sh .*\[--repo\] \[acme/desk\]' "$LOG" || fail "A the ticket is filed in the desk repo" "$(cat "$LOG" "$WORK/err")"
grep -q 'fleet-issue-file.sh .*\[--title\] \[写设计页：编排架构\]' "$LOG" || fail "A its title is the task's first line" "$(cat "$LOG")"
grep -q 'fleet-issue-file.sh .*\[--label\] \[desk\]' "$LOG" || fail "A it carries the desk label" "$(cat "$LOG")"
grep -q 'fleet:desk origin=hub' "$LOG" || fail "A its body names who opened it" "$(cat "$LOG")"
[ "$(grep -c '^fleet-issue-file.sh' "$LOG")" = 1 ] || fail "A exactly one ticket" "$(cat "$LOG")"
grep -q "NEWWIN .*-c $WORK/home " "$NEWWIN_LOG" || fail "A it opens in \$HOME — no workspace" "$(cat "$NEWWIN_LOG")"
for o in '@desk 1' '@issue 42' '@repo acme/desk' '@norepo 1'; do
  grep -q "SETOPT .*$o\$" "$OPTS_LOG" || fail "A window option $o" "$(cat "$OPTS_LOG")"
  grep -qF "${o% *} '${o#* }'" "$NEWWIN_LOG" || fail "A $o is stamped before the launcher reads it" "$(cat "$NEWWIN_LOG")"
done
grep -q '@raw\|@worktree' "$OPTS_LOG" && fail "A a desk session has no worktree" "$(cat "$OPTS_LOG")"
seed | grep -qF 'gh:acme/desk#42' || fail "A the seed tells the session its ticket" "$(seed)"
seed | head -1 | grep -qx '写设计页：编排架构' || fail "A the seed still starts as typed" "$(seed)"
grep -q 'curl .*\[http://hub.test/v1/fleet/tickets/register\]' "$LOG" || fail "A one register call on the hub" "$(cat "$LOG")"
grep -q 'curl .*"id": "gh:acme/desk#42"' "$LOG" || fail "A the register row carries the id" "$(cat "$LOG")"
grep -q 'curl .*tok' "$LOG" || fail "A the node token rides the header" "$(cat "$LOG")"
grep -q '第二行细节' "$LOG" && { grep '^curl' "$LOG" | grep -q '第二行细节' && fail "A the hub row carries no body" "$(cat "$LOG")"; }
ok "A orchestrator/hub no-repo session → desk ticket, @desk/@issue/@repo + @norepo, \$HOME, registered"
A_OPTS=$(opts); A_FILE=$(grep '^fleet-issue-file.sh' "$LOG")

# ============================ B: off ⇒ as before ==============================
run_raw --origin hub --prompt '写设计页：编排架构'
[ -s "$LOG" ] && fail "B off: nothing filed, nothing asked" "$(cat "$LOG")"
grep -q '@desk\|@issue\|@repo' "$OPTS_LOG" && fail "B off: no ticket options" "$(cat "$OPTS_LOG")"
[ "$(seed)" = '写设计页：编排架构' ] || fail "B off: the seed is untouched" "$(seed)"
B_OPTS=$(opts)
FLEET_HOST=1 run_raw --origin hub --prompt '写设计页：编排架构' --no-desk
[ -s "$LOG" ] && fail "B --no-desk files nothing" "$(cat "$LOG")"
[ "$B_OPTS" = "$(opts)" ] || fail "B off ≡ --no-desk, byte for byte" "$B_OPTS"
FLEET_HOST=1 FLEET_DESK=0 run_raw --origin hub --prompt '写设计页：编排架构'
[ -s "$LOG" ] && fail "B FLEET_DESK=0 files nothing" "$(cat "$LOG")"
ok "B desk off / --no-desk / FLEET_DESK=0 → no ticket, the same options, the seed untouched"

# ============================ C: a scratch's spawn ============================
FLEET_HOST=1 run_raw --origin scratch-3 --prompt '查一下 X'
[ -s "$LOG" ] && fail "C a scratch's no-repo child gets no ticket by default" "$(cat "$LOG")"
FLEET_HOST=1 run_raw --origin scratch-3 --prompt '查一下 X' --desk
grep -q 'fleet-issue-file.sh .*\[--repo\] \[acme/desk\]' "$LOG" || fail "C --desk asks for one anyway" "$(cat "$LOG" "$WORK/err")"
FLEET_HOST=1 run_raw --origin orchestrator --prompt '查一下 X'
grep -q '^fleet-issue-file.sh' "$LOG" || fail "C the orchestrator's spawn is ticketed" "$(cat "$LOG" "$WORK/err")"
ok "C only the person / the orchestrator by default; --desk for anyone"

# ============================ D: --desk=<repo> =================================
FLEET_HOST=1 run_raw --origin hub --prompt '拓客：写第二版' --desk=acme/widgets
grep -q 'fleet-issue-file.sh .*\[--repo\] \[acme/widgets\]' "$LOG" || fail "D filed in the named repo" "$(cat "$LOG" "$WORK/err")"
grep -q 'SETOPT .*@repo acme/widgets$' "$OPTS_LOG" || fail "D the window's @repo is that repo" "$(cat "$OPTS_LOG")"
ok "D --desk=<owner/name> tickets a private project's no-code work in its own repo"

# ============================ E: not hosted ====================================
DESK_REPO=other/elsewhere FLEET_HOST=1 run_raw --origin hub --prompt '写设计页'
[ -s "$LOG" ] && fail "E a desk repo this fleet does not host: nothing filed" "$(cat "$LOG")"
FLEET_HOST=1 run_raw --origin hub --prompt '写设计页' --desk=other/elsewhere
[ -s "$LOG" ] && fail "E --desk=<not hosted>: nothing filed" "$(cat "$LOG")"
grep -q 'not a repo this fleet hosts' "$WORK/err" || fail "E said on stderr" "$(cat "$WORK/err")"
grep -q 'NEWWIN' "$NEWWIN_LOG" || fail "E the session still opens" "$(cat "$WORK/err")"
FILE_FAIL=1 FLEET_HOST=1 run_raw --origin hub --prompt '写设计页'
grep -q '@desk\|@issue' "$OPTS_LOG" && fail "E a failed filing stamps no ticket" "$(cat "$OPTS_LOG")"
grep -q 'NEWWIN' "$NEWWIN_LOG" || fail "E a failed filing still opens the session" "$(cat "$WORK/err")"
ok "E an unhosted desk repo / a failed filing → the session opens without a ticket, and says why"

# ============================ F: hub off =======================================
FLEET_HOST=1 run_raw --origin hub --prompt '写设计页'
grep -q '^fleet-issue-file.sh' "$LOG" || fail "F hub off: the ticket is still filed" "$(cat "$LOG")"
grep -q '^curl' "$LOG" && fail "F hub off: nothing registered" "$(cat "$LOG")"
grep -q 'not registered' "$WORK/err" || fail "F hub off: said on stderr" "$(cat "$WORK/err")"
grep -q 'SETOPT .*@desk 1$' "$OPTS_LOG" || fail "F hub off: the window is bound as ever" "$(cat "$OPTS_LOG")"
ok "F hub off → the ticket stands, unregistered"

# ============================ G: slash seed ====================================
FLEET_HOST=1 run_raw --origin hub --prompt '/loop 20m /steward-tick'
grep -q '^fleet-issue-file.sh' "$LOG" || fail "G a slash seed is ticketed too" "$(cat "$LOG")"
[ "$(seed)" = '/loop 20m /steward-tick' ] || fail "G a slash command's seed is left as typed" "$(seed)"
ok "G a slash-command seed keeps its arguments"

# ============================ H: fleet-ticket.sh ================================
T() { env -u CCQUOTA_HUB_URL -u CCQUOTA_TOKEN FLEET_CONF_DIR="$WORK/conf" PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" CALL_LOG="$LOG" FLEET_GH_WRITE_GAP=0 \
        bash "$WORK/bin/fleet-ticket.sh" "$@"; }
: > "$LOG"
[ "$(T parse 'gh:acme/desk#7')" = "acme/desk	7" ] || fail "H parse"
T parse 'hub:7' 2>"$WORK/err"; [ $? = 2 ] || fail "H hub:N is reserved — exit 2"
grep -q 'reserved' "$WORK/err" || fail "H hub:N says it is reserved" "$(cat "$WORK/err")"
T parse 'acme/desk#7' 2>/dev/null; [ $? = 2 ] || fail "H a bare owner/name#N is not an id"
T read 'gh:acme/desk#7' --json title >/dev/null
grep -qx 'fleet-gh.sh \[issue\] \[view\] \[7\] \[--repo\] \[acme/desk\] \[--json\] \[title\]' "$LOG" || fail "H read → fleet-gh.sh issue view" "$(cat "$LOG")"
T comment 'gh:acme/desk#7' --to-worker --body 'hi' >/dev/null
grep -qx 'fleet-comment.sh \[7\] \[--repo\] \[acme/desk\] \[--to-worker\] \[--body\] \[hi\]' "$LOG" || fail "H comment → fleet-comment.sh" "$(cat "$LOG")"
[ "$(T state 'gh:acme/desk#7' closed --reason not_planned)" = closed ] || fail "H state closed"
grep -q 'gh \[issue\] \[close\] \[7\] \[--repo\] \[acme/desk\] \[--reason\] \[not planned\]' "$LOG" || fail "H state → gh issue close" "$(cat "$LOG")"
T state 'gh:acme/desk#7' open >/dev/null
grep -q 'gh \[issue\] \[reopen\] \[7\]' "$LOG" || fail "H state open → gh issue reopen" "$(cat "$LOG")"
[ "$(T children 'gh:acme/desk#7')" = "$(printf 'gh:acme/desk#8\topen\ngh:acme/widgets#3\tclosed')" ] \
  || fail "H children → one id + state per sub-issue, each in its own repo" "$(T children 'gh:acme/desk#7')"
T evidence 'gh:acme/desk#7' after --note n >/dev/null
grep -qx 'fleet-evidence.sh \[after\] \[--repo\] \[acme/desk\] \[--issue\] \[7\] \[--note\] \[n\]' "$LOG" || fail "H evidence → fleet-evidence.sh" "$(cat "$LOG")"
: > "$LOG"
GH_LABELS=bug T new --repo acme/desk --title t >/dev/null 2>&1
grep -q 'gh \[label\] \[create\] \[desk\] \[--repo\] \[acme/desk\]' "$LOG" || fail "H new mints the desk label once when the repo lacks it" "$(cat "$LOG")"
( . "$BIN/fleet-lib.sh"; fleet_labels_allowed ) | grep -qx desk || fail "H desk is in the canonical label taxonomy"
# GitHub refuses a label description past 100 characters (HTTP 422)
( . "$BIN/fleet-lib.sh"; fleet_labels_canonical ) | python3 -c '
import sys
for l in sys.stdin:
    n, _, d = l.rstrip("\n").split("|", 2)
    if n == "desk" and len(d) > 100: sys.exit(1)' || fail "H the desk label description fits GitHub's 100 characters"
ok "H fleet-ticket.sh: parse · hub: reserved · read · comment · state · children · evidence · label"

# ============================ I: (n) another repo ==============================
add_repo acme/third
FLEET_HOST=1 CCQUOTA_FLEET=1 run_raw --origin hub --prompt $'写设计页：编排架构\n第二行细节'
[ "$A_OPTS" = "$(opts)" ] || fail "I a third repo changes no window option" "$(diff <(printf '%s\n' "$A_OPTS") <(opts))"
[ "$A_FILE" = "$(grep '^fleet-issue-file.sh' "$LOG")" ] || fail "I a third repo changes no filing" "$(cat "$LOG")"
ok "I (n) adding a repo leaves a desk spawn byte for byte"

printf 'desk-ticket-selftest: %d legs passed\n' "$pass"
