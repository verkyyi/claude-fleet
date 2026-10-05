#!/bin/bash
# hub-place-selftest.sh — placement in bin/dash-issue-session.sh (issue #1425,
# EPIC #1419 C6): with CCQUOTA_FLEET=1 a spawn names no machine (`--node auto`),
# and after the hub lease (issue-lease-selftest.sh) it asks the hub which machine
# opens it. The place command is faked through FLEET_HUB_PLACE_CMD (the seam
# fleet_hub_place runs; in production `ccquota place`, whose hub side is
# tokenledger/internal/api/fleet_place.go — the m5-busy→m4 integration lives in
# its fleet_place_test.go); the lease through FLEET_HUB_LEASE_CMD; git/gh/tmux on
# PATH as in issue-lease-selftest.sh. The real dash-issue-session.sh +
# fleet-lib.sh run unmodified.
#
#   OFF     CCQUOTA_FLEET unset → the place command never runs; stderr / gh / tmux
#           / git are byte-identical to a run with none configured — with no
#           --node and with --node auto / local (the degenerate case is sacred).
#   NOHUB   CCQUOTA_FLEET unset + --node m4 → refused (exit 1), nothing spawned.
#   REMOTE  the hub placed it on m4 → exit 0, stderr names m4 and the reason, no
#           window, no GitHub claim here, the lease NOT given back.
#   PARENT  a worker spawning a child sends its worker_id as --origin-wid.
#   LOCAL   the hub chose this machine → today's claim + spawn.
#   HELD    the hub says another machine holds it → exit 3, no spawn.
#   NOELIG  auto, no machine eligible → opened here, one note.
#   NAMED   --node m4 refused by the hub → exit 2, no spawn, lease given back.
#   DOWN    hub unreachable → opened here.
#   HUBSENT a start the hub sent (fleet-control-read.sh: --origin hub --node
#           local) → never placed again; its --origin-wid is stamped verbatim,
#           and its key as @origin (fleet-report-parent.sh needs a key there).
#   SELF    --node local / this host's alias → never asks the hub.
#   CAP     this machine is full → still placed on m4 (exit 0); a LOCAL answer
#           then refuses with the cap reason (exit 2).
#   TOKEN   (issue #1491) the place command sees node.env's CCQUOTA_TOKEN; the
#           spawned window never inherits it; the default `ccquota place` with no
#           token anywhere is not run and says 「no node token」, not 「unreachable」.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
[ -x "$SPAWN" ] || { echo "selftest: $SPAWN missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/place-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2
         [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2
         printf -- '--- place log ---\n%s\n' "$(cat "$PLACE_LOG" 2>/dev/null)" >&2
         printf -- '--- lease log ---\n%s\n--- gh log ---\n%s\n--- tmux log ---\n%s\n--- stderr ---\n%s\n' \
           "$(cat "$LEASE_LOG" 2>/dev/null)" "$(cat "$GH_LOG" 2>/dev/null)" \
           "$(cat "$TMUX_LOG" 2>/dev/null)" "$(cat "$WORK/spawn.err" 2>/dev/null)" >&2
         exit 1; }

mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/dash"
GH_LOG="$WORK/gh.log"; TMUX_LOG="$WORK/tmux.log"; GIT_LOG="$WORK/git.log"; DISPLAY_LOG="$WORK/display.log"

# --- fake git: fetch/worktree/branch succeed; worktree+branch ops are LOGGED -------
cat > "$WORK/fakebin/git" <<GITFAKE
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  worktree|branch) printf 'git %s\n' "\$*" >> "$GIT_LOG" ;;   # add / remove / prune / branch -D
  rev-parse)       case "\$*" in *--show-toplevel*) pwd -P ;; *) printf 'deadbeef\n' ;; esac ;;
  *) : ;;   # fetch / remote → succeed silently
esac
exit 0
GITFAKE

# --- fake gh: LOG every call; answer the claim-ledger reads from env ---------------
# CLAIM_STATE = "<assignee_count>\t<state>"  (the taken-check read — assignees,state)
# PR_COUNT    = open-PR count on issue-<N>   (the PR probe)
cat > "$WORK/fakebin/gh" <<GHFAKE
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$GH_LOG"
case "\$*" in
  *"issue view"*"--json assignees,state"*) printf '%s\n' "\${CLAIM_STATE:-0	OPEN}" ;;
  *"issue view"*"--json title"*)           printf '%s\n' "\${GH_TITLE:-Some Issue}" ;;
  *"pr list"*)                             printf '%s\n' "\${PR_COUNT:-0}" ;;
  *"issue edit"*)                          : ;;
  *"api user"*)                            printf 'me\n' ;;
  *) : ;;
esac
exit 0
GHFAKE

# --- fake tmux: -p queries answered; new-window / kill-window / display LOGGED ------
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
case "\${1:-}" in
  display-message)
    case "\$*" in
      *-p*) case "\$*" in
              *window_id*)    echo "\${TMUX_WIN:-@9}" ;;
              *session_name*) echo 'testsess' ;;
              *) echo '' ;;
            esac ;;
      *) shift; printf '%s\n' "\$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  list-windows)      : ;;                                   # no existing windows → no local dedup hit
  show-options)      echo '' ;;
  new-window)        printf 'new-window %s\n' "\$*" >> "$TMUX_LOG"; printf '%s\n' "\${CCQUOTA_TOKEN:-<unset>}" > "$WORK/tmux.env"; echo "\${TMUX_WIN:-@9}" ;;
  kill-window)       printf 'kill-window %s\n' "\$*" >> "$TMUX_LOG" ;;
  set-window-option) case "\$*" in *@origin*) printf 'set-window-option %s\n' "\$*" >> "$TMUX_LOG" ;; esac ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

LEASE_LOG="$WORK/lease.log"; PLACE_LOG="$WORK/place.log"

# --- fake place command: LOG its argv, answer PLACE_ANSWER (TAB-separated) / PLACE_RC
cat > "$WORK/fakebin/fake-place" <<PLACEFAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$PLACE_LOG"
printf '%s\n' "\${CCQUOTA_TOKEN:-<unset>}" > "$WORK/place.env"
[ -n "\${PLACE_ANSWER:-}" ] && printf '%s\n' "\$PLACE_ANSWER"
[ -n "\${PLACE_STDERR:-}" ] && printf '%s\n' "\$PLACE_STDERR" >&2
exit "\${PLACE_RC:-0}"
PLACEFAKE
chmod +x "$WORK/fakebin/fake-place"

# --- fake lease command: LOG its argv, answer LEASE_ANSWER / exit LEASE_RC -------
cat > "$WORK/fakebin/fake-lease" <<LEASEFAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$LEASE_LOG"
case "\${1:-}" in
  release) echo RELEASED; exit 0 ;;
esac
[ -n "\${LEASE_ANSWER:-}" ] && printf '%s\n' "\$LEASE_ANSWER"
exit "\${LEASE_RC:-0}"
LEASEFAKE
chmod +x "$WORK/fakebin/fake-lease"

# A control database with a machine id: what fleet_uuid derives the fleet UUID from.
MACHINE=11111111-1111-4111-8111-111111111111
mkdir -p "$WORK/conf/control"
python3 - "$WORK/conf/control/state.sqlite3" "$MACHINE" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)")
con.execute("INSERT INTO metadata VALUES ('machine_id', ?)", (sys.argv[2],))
con.commit()
PY

run_spawn() { # $@ = args to dash-issue-session.sh
  : > "$GH_LOG"; : > "$TMUX_LOG"; : > "$GIT_LOG"; : > "$DISPLAY_LOG"; : > "$LEASE_LOG"; : > "$PLACE_LOG"
  rm -f "$WORK/place.env" "$WORK/tmux.env" "$WORK/ccq.log"
  rm -rf "$WORK/dash/.claude-dash"
  # INFLIGHT=1: one fresh spawn-in-flight marker, so FLEET_GLOBAL_MAX_SESSIONS=1 is full.
  if [ "${INFLIGHT:-0}" = 1 ]; then mkdir -p "$WORK/dash/.claude-dash/global/spawn-inflight"; : > "$WORK/dash/.claude-dash/global/spawn-inflight/x.1"; fi
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="${CONF_DIR:-$WORK/conf}" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
    "$SPAWN" "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
  echo $? > "$WORK/spawn.rc"
}
rc()          { cat "$WORK/spawn.rc"; }
err_has()     { grep -qF -- "$1" "$WORK/spawn.err"; }
gh_has()      { grep -qF -- "$1" "$GH_LOG"; }
tmux_has()    { grep -qF -- "$1" "$TMUX_LOG"; }
lease_has()   { grep -qF -- "$1" "$LEASE_LOG"; }
place_has()   { grep -qF -- "$1" "$PLACE_LOG"; }
snap()        { cat "$WORK/spawn.rc" "$WORK/spawn.err" "$GH_LOG" "$TMUX_LOG" "$GIT_LOG"; }

unset FLEET_PRESPAWN_DEDUP CCQUOTA_FLEET FLEET_HUB_LEASE_CMD FLEET_HUB_PLACE_CMD FLEET_HUB_STATUS_CMD FLEET_NODE_ALIASES
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL   # a pane under the pre-#1491 stop-gap exports the token
LEASE="$WORK/fakebin/fake-lease"; PLACE="$WORK/fakebin/fake-place"
UUID=$(cd "$WORK" && FLEET_CONF_DIR="$WORK/conf" FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" \
  bash -c '. "$1/fleet-lib.sh"; fleet_uuid testsess' _ "$BIN")
[ -n "$UUID" ] || fail "setup: fleet_uuid derived nothing from the fake control database"


WID="$UUID/issue-258"
REMOTE_LINE=$'REMOTE m4 op_42 accepted\tchose m4 (score 0.875, load 0.10/core); m5 excluded: load 1.00/core > 0.8'

# ===== OFF: CCQUOTA_FLEET unset ⇒ nothing runs, byte-identical ====================
CLAIM_STATE=$'0\tOPEN' run_spawn 258
base=$(snap)
for extra in '' '--node auto' '--node local'; do
  # shellcheck disable=SC2086  # deliberate: '' is no flag, the others two words
  CLAIM_STATE=$'0\tOPEN' FLEET_HUB_PLACE_CMD="$PLACE" FLEET_HUB_LEASE_CMD="$LEASE" run_spawn 258 $extra
  [ -s "$PLACE_LOG" ]                            && fail "OFF ($extra) the place command must not run without CCQUOTA_FLEET=1"
  [ "$(snap)" = "$base" ]                        || fail "OFF ($extra) must change nothing while the hub is off" "$(diff <(printf '%s\n' "$base") <(snap))"
done
ok "OFF CCQUOTA_FLEET unset → no placement, byte-identical (no flag, --node auto, --node local)"

CLAIM_STATE=$'0\tOPEN' FLEET_HUB_PLACE_CMD="$PLACE" run_spawn 258 --node m4
[ "$(rc)" = 1 ]                                  || fail "NOHUB --node m4 without the hub refuses (rc=$(rc))"
err_has 'needs the hub'                          || fail "NOHUB says why"
tmux_has 'new-window'                            && fail "NOHUB must not open it here instead"
ok "NOHUB --node <other machine> without the hub → refused, not silently local"

export CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" FLEET_HUB_PLACE_CMD="$PLACE"

# ===== REMOTE: placed on m4 ⇒ nothing here, lease kept ============================
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "REMOTE exits 0 (rc=$(rc))"
place_has "--node auto acme/widgets 258 $WID" || fail "REMOTE asks with node auto and this fleet's worker_id"
err_has '#258 → m4 (hub operation op_42, accepted)' || fail "REMOTE names the machine and the operation"
err_has 'm5 excluded: load 1.00/core > 0.8'      || fail "REMOTE carries the reason"
tmux_has 'new-window'                            && fail "REMOTE must not open a window here"
gh_has '--add-assignee'                          && fail "REMOTE leaves the GitHub claim to the machine that opens it"
lease_has release                                && fail "REMOTE the lease is the remote fleet's now — never given back"
head -n1 "$LEASE_LOG" | grep -q '^acquire' || fail "REMOTE the lease is taken BEFORE placing"
ok "REMOTE m5 busy → sent to m4 with its reason; no window, no claim, lease kept"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 --origin issue-77
place_has "--origin-wid $UUID/issue-77"          || fail "PARENT the parent's worker_id rides the placement"
ok "PARENT a worker's child carries --origin-wid <fleet UUID>/issue-77"

# ===== LOCAL: the hub chose this machine ⇒ today's path ===========================
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER=$'LOCAL m5\tchose m5 (score 0.9)' run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "LOCAL spawns (rc=$(rc))"
tmux_has 'new-window'                            || fail "LOCAL opens the window here"
gh_has '--add-assignee'                          || fail "LOCAL the GitHub claim runs as today"
err_has '开在本机 m5'                             || fail "LOCAL says where and why"
ok "LOCAL the hub chose this machine → claim + spawn as today"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER=$'HELD m4\t#258 is leased to m4' PLACE_RC=3 run_spawn 258
[ "$(rc)" = 3 ]                                  || fail "HELD exits 3 (rc=$(rc))"
tmux_has 'new-window'                            && fail "HELD must not spawn"
ok "HELD leased elsewhere → exit 3, no spawn"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER=$'REFUSED NO_ELIGIBLE_NODE\tNo machine can take a new session now' PLACE_RC=4 run_spawn 258
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "NOELIG auto with no eligible machine opens it here"
err_has '没有机器能接 #258'                        || fail "NOELIG says so"
ok "NOELIG auto, no machine eligible → opened here, one note"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER=$'REFUSED NO_ELIGIBLE_NODE\tm4: at the per-person cap (6/6 sessions)' PLACE_RC=4 run_spawn 258 --node m4
[ "$(rc)" = 2 ]                                  || fail "NAMED a refused named machine exits 2 (rc=$(rc))"
place_has '--node m4 '                     || fail "NAMED asks for that machine"
tmux_has 'new-window'                            && fail "NAMED must not open it here instead"
lease_has release                                || fail "NAMED the lease is given back"
ok "NAMED --node m4 refused → exit 2, no spawn, lease back"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_RC=1 \
  PLACE_STDERR='ccquota: Post "https://hub.test/v1/node/place": context deadline exceeded (Client.Timeout exceeded while awaiting headers)' run_spawn 258
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "DOWN hub unreachable opens it here"
err_has 'fleet: hub unreachable (context deadline exceeded (Client.Timeout exceeded while awaiting headers)) — placing #258, opening it here' \
                                                 || fail "DOWN one note, with the cause"
ok "DOWN hub unreachable → opened here"

# issue #1507: a hub that ANSWERED is never 「unreachable」 — the note carries its error
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_RC=1 \
  PLACE_STDERR='ccquota: hub answered HTTP 403: {"error":"fleet c45a2451 is not registered to this node"}' run_spawn 258
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "WHY a refused placement opens it here"
err_has 'fleet: placement refused: HTTP 403 — fleet c45a2451 is not registered to this node — placing #258' \
                                                 || fail "WHY a 403 reads 「placement refused」 with the hub's error"
err_has 'unreachable'                            && fail "WHY a hub that answered is not 「unreachable」"
ok "WHY hub answered 403 → 「placement refused: HTTP 403 — <error>」, opened here"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m4" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 --origin hub --origin-wid "$MACHINE/issue-77" --node local
[ -s "$PLACE_LOG" ]                              && fail "HUBSENT a start the hub sent is never placed again"
tmux_has 'new-window'                            || fail "HUBSENT opens it here"
tmux_has "@origin_wid $MACHINE/issue-77"         || fail "HUBSENT stamps the given parent worker_id"
tmux_has "@origin issue-77"                      || fail "HUBSENT stamps the parent's key as @origin too — the report path needs it"
ok "HUBSENT --origin hub --node local → no re-placement; @origin_wid stamped verbatim"

for n in local m5; do
  CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" \
    FLEET_NODE_ALIASES="$(hostname -s | tr '[:upper:]' '[:lower:]')=m5" run_spawn 258 --node "$n"
  [ -s "$PLACE_LOG" ]                            && fail "SELF --node $n must not ask the hub"
  tmux_has 'new-window'                          || fail "SELF --node $n opens it here"
done
ok "SELF --node local / this host's alias → no hub call"

# ===== PIN (issue #1543): --node local holds in any argv order, and FUSED ==========
# EPIC #1524 ran `extra="--node local"; dash-issue-session.sh $n --title "$t" $extra`
# in Claude's Bash tool — zsh, where an unquoted $extra does NOT word-split — so the
# script got ONE arg "--node local", ignored it as an unknown flag and let the hub
# place #1525 on m4. A fused "--flag value" is now read as --flag=value.
for args in "--repo|acme/widgets|--title|x|--node|local" "--node|local|--title|x|--repo|acme/widgets" \
            "--title|x|--node local" "--node local|--title x|--repo acme/widgets" "--node  local"; do
  _o=$IFS; IFS='|'; set -- $args; IFS=$_o
  CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 "$@"
  [ -s "$PLACE_LOG" ]                            && fail "PIN [$args] must not ask the hub"
  err_has 'chose'                                && fail "PIN [$args] prints no chose line"
  err_has 'unknown flag'                         && fail "PIN [$args] is no unknown flag"
  tmux_has "-n x"  || tmux_has "-n some-issue"   || fail "PIN [$args] opens it here"
done
if command -v zsh >/dev/null 2>&1; then          # the exact shape of the EPIC #1524 call
  printf '#!/bin/sh\nexec zsh -fc %s _ "%s"\n' "'extra=\"--node local\"; \"\$1\" 258 --title x \$extra'" "$SPAWN" > "$WORK/zsh-spawn"
  chmod +x "$WORK/zsh-spawn"
  CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" SPAWN="$WORK/zsh-spawn" run_spawn
  [ -s "$PLACE_LOG" ]                            && fail "PIN zsh's unsplit \$extra must not ask the hub"
  tmux_has 'new-window'                          || fail "PIN zsh's unsplit \$extra opens it here"
fi
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 "--node m4"
place_has "--node m4 acme/widgets 258"           || fail "PIN a fused --node <other machine> is asked for by name"
ok "PIN --node local in any order and fused (\"--node local\", zsh's unsplit \$var) → no hub call; fused m4 → by name"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_spawn 258
[ "$(rc)" = 0 ] && err_has '#258 → m4'           || fail "CAP a full machine still places elsewhere (rc=$(rc))"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER=$'LOCAL m5\tchose m5' INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_spawn 258
[ "$(rc)" = 2 ] && err_has 'at capacity'         || fail "CAP opening here after all applies the cap (rc=$(rc))"
tmux_has 'new-window'                            && fail "CAP must not spawn past the cap"
lease_has release                                || fail "CAP the refused spawn gives the lease back"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_spawn 258 --node local
[ "$(rc)" = 2 ] && [ ! -s "$PLACE_LOG" ]         || fail "CAP --node local refuses at the cap without asking (rc=$(rc))"
ok "CAP a full machine still places elsewhere; opening here keeps the cap"

# ===== FLEET_SPAWN_NODE (issue #1475): the login-wide default when nothing names a machine
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=local run_spawn 258
[ -s "$PLACE_LOG" ]                              && fail "SPAWN_NODE=local must not ask the hub"
tmux_has 'new-window'                            || fail "SPAWN_NODE=local opens it here"
ok "SPAWN_NODE local → no placement, opened here (auto never leaves the machine)"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=m4 run_spawn 258
place_has '--node m4 '                           || fail "SPAWN_NODE=m4 asks for that machine by name"
err_has '#258 → m4'                              || fail "SPAWN_NODE=m4 is placed there"
ok "SPAWN_NODE m4 → asked for by name"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=auto run_spawn 258
place_has '--node auto '                         || fail "SPAWN_NODE=auto asks with auto"
ok "SPAWN_NODE auto → the hub picks, as with no knob"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=local run_spawn 258 --node m4
place_has '--node m4 '                           || fail "SPAWN_NODE a --node on the command still wins"
ok "SPAWN_NODE --node m4 overrides the knob"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE='m4; rm -rf /' run_spawn 258
place_has '--node auto '                         || fail "SPAWN_NODE a value that is no machine name reads as auto"
ok "SPAWN_NODE garbage → auto"

base=$(CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET='' FLEET_HUB_PLACE_CMD='' FLEET_HUB_LEASE_CMD='' run_spawn 258; snap)
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET='' FLEET_HUB_PLACE_CMD='' FLEET_HUB_LEASE_CMD='' FLEET_SPAWN_NODE=m4 run_spawn 258
[ "$(snap)" = "$base" ]                          || fail "SPAWN_NODE with the hub off must change nothing" "$(diff <(printf '%s\n' "$base") <(snap))"
ok "SPAWN_NODE off → byte-identical (the knob is never read without the hub)"

# ===== TOKEN: node.env's token reaches the place command only (issue #1491) =======
NODE_ENV="$WORK/conf/node.env"
printf 'CCQUOTA_HUB_URL=http://hub.test\nCCQUOTA_TOKEN=tok-node\n' > "$NODE_ENV"; chmod 600 "$NODE_ENV"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" PLACE_ANSWER=$'LOCAL m5\tchose m5' run_spawn 258
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "TOKEN spawns (rc=$(rc))" "$(cat "$WORK/spawn.err")"
[ "$(cat "$WORK/place.env" 2>/dev/null)" = tok-node ] || fail "TOKEN the place command must see node.env's CCQUOTA_TOKEN" "place saw: $(cat "$WORK/place.env" 2>/dev/null)"
[ "$(cat "$WORK/tmux.env" 2>/dev/null)" = '<unset>' ] || fail "TOKEN the spawned window must NOT inherit the node token" "tmux saw: $(cat "$WORK/tmux.env" 2>/dev/null)"
# the DEFAULT `ccquota place` (no seam) with no token anywhere: not run, named
rm -f "$NODE_ENV"
cat > "$WORK/fakebin/ccquota" <<CCQFAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/ccq.log"; printf 'LOCAL m5\tchose m5\n'; exit 0
CCQFAKE
chmod +x "$WORK/fakebin/ccquota"
FLEET_HUB_PLACE_CMD='' CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED m5" run_spawn 258
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "TOKEN-less default place still opens it here (rc=$(rc))" "$(cat "$WORK/spawn.err")"
[ -e "$WORK/ccq.log" ]                           && fail "TOKEN-less: ccquota place must not be run without a token" "$(cat "$WORK/ccq.log")"
err_has "no node token (CCQUOTA_TOKEN unset and $NODE_ENV missing)" || fail "TOKEN-less stderr names what is missing" "$(cat "$WORK/spawn.err")"
err_has 'opening #258 here'                      || fail "TOKEN-less stderr says where it opens" "$(cat "$WORK/spawn.err")"
err_has 'hub unreachable'                        && fail "TOKEN-less is not 「hub unreachable」" "$(cat "$WORK/spawn.err")"
rm -f "$WORK/fakebin/ccquota"
ok "TOKEN node.env's token reaches the place command only; none → 「no node token」, opened here"

printf 'hub-place-selftest: %s checks passed\n' "$pass"
