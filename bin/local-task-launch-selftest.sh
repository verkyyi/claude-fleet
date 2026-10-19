#!/bin/bash
# local-task-launch-selftest.sh — an accepted task that opens on THIS machine
# (issue #4754, the #4453 regression). The hub binds only a remote start
# (claimLaunch → FLEET_LAUNCH); a start that stays here — placement LOCAL, or a
# no-repo / scratch session that is never placed — got none, and
# `fleet_launch.py admit` refused every one: `launch: unsupported launch contract`.
# Now the spawner claims the task itself (`fleet_launch.py local`, the hub's
# fenced `claim` mutation) and carries the same binding; no claim ⇒ no window.
#
# Both roads, real spawners, faked tmux / git / gh and a faked hub
# (FLEET_HUB_CURL answers /v1/node/tasks/T1):
#   I  dash-issue-session.sh — a repo task opened here: claimed, @launch + @task
#      on the window before its agent starts, worker_id = <fleet UUID>/<op>
#   R  dash-raw-session.sh --no-repo — a template session (agent file) opened
#      here: claimed, @launch on the window
#   X  the hub refuses the claim (409) / the task is no longer accepted ⇒ both
#      spawners refuse, no window — never opened unbound
#   T  dash-raw-session.sh --repo --task — a development task with no issue
#      (issue #4897): claimed, @task + @task_flow before the agent starts
#   N  a dispatch with no task (a park wake's --task T<n>) ⇒ no hub call, opens
#
# selftest-deps: fleet_launch.py dash-issue-session.sh dash-raw-session.sh fleet-task-record.sh fleet_task_recovery.py
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "selftest: python3 absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/local-task-launch.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

FUUID=22222222-2222-4222-8222-222222222222
mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf/fleets/testsess" "$WORK/dash" "$WORK/home/.claude/agents"
# The orchestrator template as the core ships it into ~/.claude/agents.
cp "$BIN/../conf/agent-defaults/claude/agents/orchestrator.md" "$WORK/home/.claude/agents/"
printf 'CCQUOTA_TOKEN=tok\nCCQUOTA_HUB_URL=http://hub.test\n' > "$WORK/conf/node.env"
printf '%s\n' "$FUUID" > "$WORK/conf/fleets/testsess/identity"   # fleet_uuid's frozen file
printf 'CCQUOTA_FLEET=1\n' > "$WORK/conf/fleets/testsess/conf"         # the hub is on for this fleet
. "$BIN/selftest-repo-fixture.sh"; fx_repo "$WORK/conf" testsess acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master
HUBLOG="$WORK/hub.log"; NEWWIN="$WORK/newwin"

cat > "$WORK/fakebin/git" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
case "${1:-}" in
  rev-parse) case "$*" in *--abbrev-ref*) echo issue-234 ;; *--show-toplevel*) pwd -P ;; *) echo deadbeef ;; esac ;;
  show-ref) exit 1 ;;   # no branch yet: a scratch number is free (leg T)
  worktree) [ "${2:-}" = add ] && for a in "$@"; do case "$a" in /*) mkdir -p "$a"; break ;; esac; done ;;
esac
exit 0
EOF
cat > "$WORK/fakebin/gh" <<'EOF'
#!/bin/bash
case "${1:-} ${2:-}" in "issue view") echo 'Some Issue Title' ;; esac
exit 0
EOF
cat > "$WORK/fakebin/tmux" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
case "${1:-}" in
  display-message) case "$*" in *-p*) case "$*" in *window_id*) echo '@9' ;; *session_name*) echo testsess ;; *pane_id*) echo '%9' ;; esac ;; esac ;;
  new-window) printf '%s\n' "$*" >> "$NEWWIN"; echo '@9' ;;
esac
exit 0
EOF
# The hub's task endpoint: GET → the accepted record; POST (claim) → the record
# owned by the claiming worker, or 409 with HUB_CLAIM=refuse.
cat > "$WORK/fakebin/curl" <<'EOF'
#!/bin/bash
cat >/dev/null
m=GET body='' url=''
while [ $# -gt 0 ]; do case "$1" in -X) m=$2; shift ;; --data-binary) body=$2; shift ;; http*) url=$1 ;; esac; shift; done
printf '%s %s %s\n' "$m" "$url" "$body" >> "$HUBLOG"
if [ "$m" = POST ]; then
  [ "${HUB_CLAIM:-ok}" = ok ] || { printf '{"error":"accepted task already has an owner"}\n409'; exit 0; }
  w=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mutation"]["worker_id"])')
  printf '{"id":1,"authority_version":1,"owner":"alice","generation":1,"attempt_id":"task:T1:g1","resolved_agent":"claude","state":"starting","execution_owner":"%s"}\n200' "$w"
else
  printf '{"task":{"id":1,"authority_version":1,"owner":"alice","generation":1,"attempt_id":"task:T1:g1","resolved_agent":"claude","state":"%s"},"live":null}\n200' "${HUB_STATE:-accepted}"
fi
EOF
# The repo's authority in hub mode (fleet_repo_authority.py gate): --finish
# needs the accepted launch already bound, local or remote.
cat > "$WORK/fakebin/authority" <<'EOF'
#!/bin/sh
if [ "$2" = --finish ] && [ -z "${FLEET_LAUNCH:-}" ]; then
  echo 'hub authority requires an accepted, verified launch; no local fallback' >&2; exit 1
fi
echo '{"mode":"hub","ticket_ref":""}'
EOF
chmod +x "$WORK/fakebin/"*

DISPATCH='{"version":1,"request_id":"fixture","requested_agent":"claude","resolved_agent":"claude","agent_source":"explicit","task":"T1","generation":1,"attempt_id":"task:T1:g1"}'
PLAIN='{"version":1,"request_id":"fixture","requested_agent":"claude","resolved_agent":"claude","agent_source":"explicit"}'

env_run() {  # <dispatch> <script> args… — FLEET_LAUNCH never set: a LOCAL start
  local d="$1"; shift
  : > "$NEWWIN"; : > "$HUBLOG"
  env -u FLEET_LAUNCH HOME="$WORK/home" PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" \
    FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master FLEET_ORIGIN_GATE=0 \
    FLEET_PRESPAWN_DEDUP=0 FLEET_CODEX_READY_CHECK=0 FLEET_MAX_SESSIONS=0 FLEET_GLOBAL_MAX_SESSIONS=0 \
    FLEET_DISPATCH="$d" FLEET_HUB_CURL="$WORK/fakebin/curl" FLEET_HUB_AUTHORITY_CMD="$WORK/fakebin/authority" HUBLOG="$HUBLOG" NEWWIN="$NEWWIN" \
    HUB_CLAIM="${HUB_CLAIM:-ok}" HUB_STATE="${HUB_STATE:-accepted}" \
    bash "$@" >"$WORK/out" 2>"$WORK/err"
}
launched() {  # the window carries a launch bound to THIS fleet and a claim was made
  grep -qF -- "@launch" "$NEWWIN" && grep -qF -- "$FUUID/" "$NEWWIN" \
    && grep -q '^POST http://hub.test/v1/node/tasks/T1 .*"kind": "claim"' "$HUBLOG"
}
why() { printf 'err:\n%s\nhub:\n%s\nnewwin:\n%s\n' "$(cat "$WORK/err")" "$(cat "$HUBLOG")" "$(cat "$NEWWIN")"; }

# ===== I: a repo task the hub placed HERE ======================================
env_run "$DISPATCH" "$BIN/dash-issue-session.sh" 234 testsess --node local
launched || fail "I a local repo task must claim + open bound (@launch)" "$(why)"
grep -qF -- "@task" "$NEWWIN" || fail "I the window must carry @task" "$(why)"
grep -q 'unsupported launch contract' "$WORK/err" && fail "I the #4453 refusal is back" "$(why)"
ok "I dash-issue-session: a local accepted task claims and opens with @launch/@task"

# ===== R: a no-repo template session (never placed) ============================
printf '看一下今天的批次\n' > "$WORK/words"   # fleet-task-record.sh dispatch's own spawn line
env_run "$DISPATCH" "$BIN/dash-raw-session.sh" --no-repo --task T1 --name 看批次 --as orchestrator "--prompt-file=$WORK/words" testsess
launched || fail "R a local no-repo task must claim + open bound (@launch)" "$(why)"
grep -qF -- "@launch_seed" "$NEWWIN" || fail "R the words must be held as the launch seed" "$(why)"
ok "R dash-raw-session --no-repo: a local accepted task claims and opens with @launch"

# ===== T: a development task opened here (issue #4897) ===========================
# fleet-task-record.sh dispatch's repo spawn line: a repo worktree bound to the
# record, @task + @task_flow on the window BEFORE its agent starts (the hook reads them).
printf '修风扇\n' > "$WORK/words"
env_run "$DISPATCH" "$BIN/dash-raw-session.sh" --repo acme/widgets --task T1 --name 修风扇 --reap merged \
  "--prompt-file=$WORK/words" testsess --node local
launched || fail "T a local repo task must claim + open bound (@launch)" "$(why)"
python3 - "$NEWWIN" <<'PY' || fail "T @task T1 + @task_flow 1 must be stamped before the agent starts" "$(why)"
import sys
line = open(sys.argv[1]).read()
launch = line.find("fleet-session-wrap.sh")
for opt in ("@task 'T1'", "@task_flow '1'"):
    i = line.find(opt)
    assert 0 <= i < launch, (opt, i, launch)
PY
ok "T dash-raw-session --repo --task: claimed, @task + @task_flow stamped before the agent starts"

# ===== X: no claim ⇒ no window ==================================================
HUB_CLAIM=refuse env_run "$DISPATCH" "$BIN/dash-issue-session.sh" 234 testsess --node local
[ -s "$NEWWIN" ] && fail "X a refused claim must open no issue window" "$(why)"
HUB_CLAIM=refuse env_run "$DISPATCH" "$BIN/dash-raw-session.sh" --no-repo --task T1 testsess
[ -s "$NEWWIN" ] && fail "X a refused claim must open no raw window" "$(why)"
HUB_STATE=starting env_run "$DISPATCH" "$BIN/dash-raw-session.sh" --no-repo --task T1 testsess
[ -s "$NEWWIN" ] && fail "X a task no longer accepted must open no window" "$(why)"
grep -q '^POST' "$HUBLOG" && fail "X a task no longer accepted must not be claimed" "$(why)"
ok "X refused claim / not-accepted task ⇒ both spawners refuse, nothing opens unbound"

# ===== N: no task in the dispatch ⇒ no hub call, opens as before ================
env_run "$PLAIN" "$BIN/dash-raw-session.sh" --no-repo --task T1 testsess
[ -s "$NEWWIN" ] || fail "N a dispatch with no task must still open" "$(why)"
[ -s "$HUBLOG" ] && fail "N a dispatch with no task must not call the hub" "$(why)"
grep -qF -- "@launch" "$NEWWIN" && fail "N a dispatch with no task carries no @launch" "$(why)"
ok "N a dispatch with no task (park wake) opens unchanged, no claim"

printf '\n%d passed\n' "$pass"
