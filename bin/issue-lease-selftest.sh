#!/bin/bash
# issue-lease-selftest.sh — the hub issue lease in bin/dash-issue-session.sh
# (issue #1422, EPIC #1419 C3): with CCQUOTA_FLEET=1 a spawn takes the hub's
# lease on (repo, issue) BEFORE its GitHub claim check, so two machines opening
# the same issue at once cannot both pass. The lease command is faked through
# FLEET_HUB_LEASE_CMD (the seam fleet_hub_lease runs; in production it is
# `ccquota lease`, whose hub side is tokenledger/internal/api/fleet_leases.go);
# git/gh/tmux are faked on PATH as in dash-issue-prespawn-dedup-selftest.sh, and
# the real dash-issue-session.sh + fleet-lib.sh run unmodified.
#
#   OFF    CCQUOTA_FLEET unset → the lease command never runs, and the spawn's
#          stderr / gh / tmux / git traffic is byte-identical to a run with no
#          lease command configured at all (the degenerate case is sacred).
#   HELD   lease held by m5 → exit 3, stderr 「已被 m5 认领」, no GitHub claim, no spawn.
#   ALIAS  the holder's hostname goes through FLEET_NODE_ALIASES (macmini=m5).
#   GRANT  lease granted → acquire names <fleet UUID>/issue-<N>, then the GitHub
#          claim + spawn run as today, and the lease is NOT released.
#   BACK   lease granted, then the GitHub check refuses → the lease is given back.
#   DOWN   lease command fails (hub unreachable) → one stderr note, today's path.
#   WHY    (issue #1507) the note says WHY, off the command's own stderr — never
#          「hub unreachable」 for a hub that answered: a 403 reads 「lease refused:
#          HTTP 403 — <its error>」, anything else 「ccquota exit N: <first line>」;
#          a grant says 「租约已拿到」 and nothing else.
#   NOUUID no fleet UUID on this machine → one stderr note, today's path.
#   FORCE  --force → acquire carries --force; the takeover is announced.
#   MULTI  a 2-repo fleet keys the lease <slug>:issue-<N>, as its heartbeat will.
#   TOKEN  (issue #1491) no CCQUOTA_TOKEN in the pane, one in $FLEET_CONF_DIR/node.env
#          → the lease command sees it; the spawned window does NOT (the credential
#          never enters the pane's environment); an env token wins over the file.
#   NOTOKEN the default `ccquota lease` with no token anywhere → ccquota is not even
#          run, stderr says 「no node token (… node.env missing)」 + the fix (not
#          「hub unreachable」), and the spawn falls back to the GitHub claim; with
#          node.env present the default command runs with the token. A seam
#          (FLEET_HUB_LEASE_CMD) is never held to the token (DOWN above).
#   MOVE   fleet_hub_move shares the plumbing: its command sees node.env's token;
#          the default `ccquota move` without one says 「no node token」.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
[ -x "$SPAWN" ] || { echo "selftest: $SPAWN missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lease-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2
         [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2
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
  set-window-option) : ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

LEASE_LOG="$WORK/lease.log"

# --- fake lease command: LOG its argv (+ the token it was given, issue #1491),
# answer LEASE_ANSWER / exit LEASE_RC --------------------------------------------
cat > "$WORK/fakebin/fake-lease" <<LEASEFAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$LEASE_LOG"
printf '%s\n' "\${CCQUOTA_TOKEN:-<unset>}" > "$WORK/lease.env"
case "\${1:-}" in
  release) echo RELEASED; exit 0 ;;
esac
[ -n "\${LEASE_ANSWER:-}" ] && printf '%s\n' "\$LEASE_ANSWER"
[ -n "\${LEASE_STDERR:-}" ] && printf '%s\n' "\$LEASE_STDERR" >&2
exit "\${LEASE_RC:-0}"
LEASEFAKE
chmod +x "$WORK/fakebin/fake-lease"

# --- a fake `ccquota` for the DEFAULT path (no seam): on its own PATH dir, added
# only by the legs that want it. Logs argv + the token; lease → GRANTED here.
mkdir -p "$WORK/ccqbin"
cat > "$WORK/ccqbin/ccquota" <<CCQFAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/ccq.log"
printf '%s\n' "\${CCQUOTA_TOKEN:-<unset>}" > "$WORK/ccq.env"
case "\${1:-} \${2:-}" in
  'lease release') echo RELEASED; exit 0 ;;
  'lease acquire') echo 'GRANTED m5'; exit 0 ;;
  'move '*)        printf 'LOCAL m5\tnothing to move\n'; exit 0 ;;
esac
exit 2
CCQFAKE
chmod +x "$WORK/ccqbin/ccquota"

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
  : > "$GH_LOG"; : > "$TMUX_LOG"; : > "$GIT_LOG"; : > "$DISPLAY_LOG"; : > "$LEASE_LOG"
  rm -f "$WORK/lease.env" "$WORK/tmux.env" "$WORK/ccq.log" "$WORK/ccq.env"
  rm -rf "$WORK/dash/.claude-dash"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="${CONF_DIR:-$WORK/conf}" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
    "$SPAWN" "$@" ${CCQUOTA_FLEET:+--node local} >"$WORK/spawn.out" 2>"$WORK/spawn.err"
  echo $? > "$WORK/spawn.rc"
}
# `--node local` with the hub on: placement (issue #1425, after the lease) is
# hub-place-selftest.sh's to test — here every session opens on this machine.
rc()          { cat "$WORK/spawn.rc"; }
err_has()     { grep -qF -- "$1" "$WORK/spawn.err"; }
gh_has()      { grep -qF -- "$1" "$GH_LOG"; }
tmux_has()    { grep -qF -- "$1" "$TMUX_LOG"; }
lease_has()   { grep -qF -- "$1" "$LEASE_LOG"; }
snap()        { cat "$WORK/spawn.rc" "$WORK/spawn.err" "$GH_LOG" "$TMUX_LOG" "$GIT_LOG"; }

unset FLEET_PRESPAWN_DEDUP CCQUOTA_FLEET FLEET_HUB_LEASE_CMD FLEET_HUB_STATUS_CMD FLEET_NODE_ALIASES
# The operator's stop-gap before #1491 exported the node token into every pane:
# a run from such a pane must still test the no-token paths.
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_MOVE_CMD FLEET_HUB_PLACE_CMD
LEASE="$WORK/fakebin/fake-lease"
UUID=$(cd "$WORK" && FLEET_CONF_DIR="$WORK/conf" FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" \
  bash -c '. "$1/fleet-lib.sh"; fleet_uuid testsess' _ "$BIN")
[ -n "$UUID" ] || fail "setup: fleet_uuid derived nothing from the fake control database"

# ===== OFF: CCQUOTA_FLEET unset ⇒ nothing runs, byte-identical ===================
CLAIM_STATE=$'0\tOPEN' run_spawn 258
base=$(snap)
CLAIM_STATE=$'0\tOPEN' FLEET_HUB_LEASE_CMD="$LEASE" run_spawn 258
[ -s "$LEASE_LOG" ]                              && fail "OFF the lease command must not run without CCQUOTA_FLEET=1"
[ "$(snap)" = "$base" ]                          || fail "OFF a configured lease command must change nothing while the hub is off" "$(diff <(printf '%s\n' "$base") <(snap))"
[ "$(rc)" = 0 ]                                  || fail "OFF spawns as today"
ok "OFF CCQUOTA_FLEET unset → no lease call, byte-identical spawn"

# ===== HELD: another node holds it ⇒ exit 3, names the holder, no claim/spawn ====
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" \
  LEASE_RC=3 LEASE_ANSWER="HELD m5 $UUID/acme-widgets:issue-258 2026-10-03T12:00:00Z" run_spawn 258
[ "$(rc)" = 3 ]                                  || fail "HELD exits 3 (the claimed class)" "rc=$(rc)"
err_has '已被 m5 认领'                            || fail "HELD stderr must say 已被 m5 认领"
lease_has "acquire acme/widgets 258 $UUID/acme-widgets:issue-258" || fail "HELD acquire must name the repo, issue and worker_id"
gh_has '--add-assignee'                          && fail "HELD the lease is checked BEFORE the GitHub claim — no assign"
gh_has 'assignees,state'                         && fail "HELD must not even read the GitHub claim"
tmux_has 'new-window'                            && fail "HELD must not spawn"
ok "HELD lease on m5 → exit 3, 已被 m5 认领, no GitHub claim, no spawn"

# The hub names a machine by its hostname; the operator's FLEET_NODE_ALIASES names it m5.
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" FLEET_NODE_ALIASES="macmini=m5 mini2=m4" \
  LEASE_RC=3 LEASE_ANSWER="HELD macmini $UUID/acme-widgets:issue-258 2026-10-03T12:00:00Z" run_spawn 258
[ "$(rc)" = 3 ] && err_has '已被 m5 认领'          || fail "ALIAS the holder must be named through FLEET_NODE_ALIASES"
ok "ALIAS HELD by macmini + FLEET_NODE_ALIASES=macmini=m5 → 已被 m5 认领"

# ===== GRANT: lease granted ⇒ today's claim + spawn, lease kept ==================
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" \
  LEASE_ANSWER="GRANTED m4" run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "GRANT spawns" "$(cat "$WORK/spawn.err")"
gh_has '--add-assignee'                          || fail "GRANT the GitHub claim still runs as the second guard"
tmux_has 'new-window'                            || fail "GRANT spawns the window"
lease_has release                                && fail "GRANT a spawned session keeps its lease"
[ "$(cat "$WORK/spawn.err")" = "dash-issue-session: #258 的入口租约已拿到 (m4)" ] || fail "GRANT a clean spawn prints only 「租约已拿到」 on stderr" "$(cat "$WORK/spawn.err")"
ok "GRANT lease granted → GitHub claim + spawn, lease kept"

# ===== BACK: granted, then GitHub refuses ⇒ lease given back =====================
CLAIM_STATE=$'1\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" \
  LEASE_ANSWER="GRANTED m4" run_spawn 258
[ "$(rc)" = 3 ]                                  || fail "BACK the GitHub refusal still exits 3" "rc=$(rc)"
lease_has "release acme/widgets 258 $UUID/acme-widgets:issue-258" || fail "BACK a refused spawn must release the lease it took"
ok "BACK granted then GitHub-refused → lease released"

# ===== DOWN: hub unreachable ⇒ note + today's path ===============================
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" LEASE_RC=1 \
  LEASE_STDERR='ccquota: Post "https://hub.test/v1/node/lease": dial tcp 127.0.0.1:9: connect: connection refused' run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "DOWN an unreachable hub must not block the spawn" "$(cat "$WORK/spawn.err")"
err_has 'fleet: hub unreachable (dial tcp 127.0.0.1:9: connect: connection refused) — no lease on #258' \
                                                 || fail "DOWN must say on stderr that the hub could not be asked, and why" "$(cat "$WORK/spawn.err")"
gh_has '--add-assignee'                          || fail "DOWN falls back to the GitHub claim"
tmux_has 'new-window'                            || fail "DOWN spawns"
ok "DOWN hub unreachable → stderr note, today's GitHub claim + spawn"

# ===== WHY: a hub that ANSWERED is never 「unreachable」 (issue #1507) ============
# The #1427 case: the hub answers 403 for a fleet UUID the node never registered.
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" LEASE_RC=1 \
  LEASE_STDERR='ccquota: hub answered HTTP 403: {"error":"fleet c45a2451 is not registered to this node (has its heartbeat reached the hub?)"}' run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "WHY a refused lease must not block the spawn" "$(cat "$WORK/spawn.err")"
err_has 'fleet: lease refused: HTTP 403 — fleet c45a2451 is not registered to this node (has its heartbeat reached the hub?) — no lease on #258' \
                                                 || fail "WHY a 403 must read 「lease refused」 with the hub's own error" "$(cat "$WORK/spawn.err")"
err_has 'unreachable'                            && fail "WHY a hub that answered is not 「unreachable」" "$(cat "$WORK/spawn.err")"
gh_has '--add-assignee'                          || fail "WHY falls back to the GitHub claim"
# anything else: the command's name, its code and its first line
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" LEASE_RC=7 \
  LEASE_STDERR=$'\nccquota: hub answered something that is not JSON\nsecond line' run_spawn 258
err_has "fleet: ${LEASE%% *} exit 7: hub answered something that is not JSON — no lease on #258" \
                                                 || fail "WHY any other failure names the command, its exit and its first stderr line" "$(cat "$WORK/spawn.err")"
err_has 'second line'                            && fail "WHY only the first stderr line is carried"
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" LEASE_RC=1 run_spawn 258
err_has "${LEASE%% *} exit 1: (no stderr)"       || fail "WHY a silent failure says so" "$(cat "$WORK/spawn.err")"
ok "WHY 403 → 「lease refused: HTTP 403 — <error>」, other → 「<cmd> exit N: <line>」, never 「unreachable」"

# ===== NOUUID: no control database ⇒ note + today's path =========================
mkdir -p "$WORK/conf2"
CONF_DIR="$WORK/conf2" CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "NOUUID spawns" "$(cat "$WORK/spawn.err")"
[ -s "$LEASE_LOG" ]                              && fail "NOUUID no worker_id → the lease command must not run"
err_has 'no fleet UUID'                          || fail "NOUUID must say why there is no lease"
ok "NOUUID no fleet UUID → stderr note, today's path"

# ===== FORCE: --force ⇒ acquire --force, takeover announced ======================
CLAIM_STATE=$'1\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" \
  LEASE_ANSWER="FORCED m4 m5 $UUID/acme-widgets:issue-258" run_spawn 258 --force
[ "$(rc)" = 0 ]                                  || fail "FORCE spawns" "$(cat "$WORK/spawn.err")"
lease_has "acquire --force acme/widgets 258"     || fail "FORCE the acquire must carry --force"
err_has '强制从 m5 收回'                          || fail "FORCE must announce whom the lease was taken from"
tmux_has 'new-window'                            || fail "FORCE spawns"
ok "FORCE --force → acquire --force, takeover announced, spawn"

# ===== MULTI: a 2-repo fleet keys the lease <slug>:issue-<N> =====================
out=$(cd "$WORK" && FLEET_CONF_DIR="$WORK/conf" FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" \
  CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" LEASE_ANSWER="GRANTED m4" bash -c '
    . "$1/fleet-lib.sh"
    _fleet_hosts_many() { return 0; }
    fleet_slug() { printf "wd"; }
    : > "$2"; fleet_hub_lease acquire testsess acme/widgets 12' _ "$BIN" "$LEASE_LOG")
lease_has "acquire acme/widgets 12 $UUID/wd:issue-12" || fail "MULTI a multi-repo lease must use the <slug>:issue-<N> key"
[ "$out" = "GRANTED m4" ]                        || fail "MULTI fleet_hub_lease prints the command's line" "$out"
ok "MULTI multi-repo fleet → <slug>:issue-<N> worker_id"

# ===== TOKEN: node.env's token reaches the lease command and NOTHING else (#1491) ==
NODE_ENV="$WORK/conf/node.env"
printf 'CCQUOTA_HUB_URL=http://hub.test\nCCQUOTA_TOKEN=tok-node\n' > "$NODE_ENV"; chmod 600 "$NODE_ENV"
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" LEASE_ANSWER="GRANTED m5" run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "TOKEN spawns" "$(cat "$WORK/spawn.err")"
[ "$(cat "$WORK/lease.env" 2>/dev/null)" = tok-node ] || fail "TOKEN the lease command must see node.env's CCQUOTA_TOKEN" "lease saw: $(cat "$WORK/lease.env" 2>/dev/null)"
[ "$(cat "$WORK/tmux.env" 2>/dev/null)" = '<unset>' ] || fail "TOKEN the spawned window must NOT inherit the node token" "tmux saw: $(cat "$WORK/tmux.env" 2>/dev/null)"
[ "$(cat "$WORK/spawn.err")" = "dash-issue-session: #258 的入口租约已拿到 (m5)" ] || fail "TOKEN a token from node.env is the normal path: only the grant on stderr" "$(cat "$WORK/spawn.err")"
# an exported token wins; node.env only fills the gap
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" LEASE_ANSWER="GRANTED m5" CCQUOTA_TOKEN=tok-env run_spawn 258
[ "$(cat "$WORK/lease.env" 2>/dev/null)" = tok-env ] || fail "TOKEN CCQUOTA_TOKEN in the environment wins over node.env" "lease saw: $(cat "$WORK/lease.env" 2>/dev/null)"
ok "TOKEN node.env's token reaches the lease command only; the pane and its window never hold it"

# ===== NOTOKEN: default `ccquota lease`, no token anywhere → named, not 「unreachable」 =
rm -f "$NODE_ENV"
PATH="$WORK/ccqbin:$PATH" CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "NOTOKEN a missing token must not block the spawn" "$(cat "$WORK/spawn.err")"
[ -e "$WORK/ccq.log" ]                           && fail "NOTOKEN ccquota must not be run without a token (it would only exit 1)" "$(cat "$WORK/ccq.log")"
err_has "no node token (CCQUOTA_TOKEN unset and $NODE_ENV missing)" || fail "NOTOKEN stderr must name what is missing" "$(cat "$WORK/spawn.err")"
err_has 'fleet-hub-node.sh env --write'          || fail "NOTOKEN stderr must carry the fix" "$(cat "$WORK/spawn.err")"
err_has 'only the GitHub claim guards #258'      || fail "NOTOKEN stderr must say what guards the issue now" "$(cat "$WORK/spawn.err")"
err_has 'hub unreachable'                        && fail "NOTOKEN a missing token is not 「hub unreachable」" "$(cat "$WORK/spawn.err")"
gh_has '--add-assignee'                          || fail "NOTOKEN falls back to the GitHub claim"
tmux_has 'new-window'                            || fail "NOTOKEN spawns"
# a node.env with no CCQUOTA_TOKEN= line is named as such
printf 'CCQUOTA_HUB_URL=http://hub.test\n' > "$NODE_ENV"
PATH="$WORK/ccqbin:$PATH" CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 run_spawn 258
err_has "$NODE_ENV has no CCQUOTA_TOKEN= line"   || fail "NOTOKEN a token-less node.env is named" "$(cat "$WORK/spawn.err")"
# with node.env in place the DEFAULT command runs, with the token, and says nothing
printf 'CCQUOTA_HUB_URL=http://hub.test\nCCQUOTA_TOKEN=tok-node\n' > "$NODE_ENV"; chmod 600 "$NODE_ENV"
PATH="$WORK/ccqbin:$PATH" CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "NOTOKEN+node.env spawns" "$(cat "$WORK/spawn.err")"
grep -qF "lease acquire acme/widgets 258 $UUID/acme-widgets:issue-258" "$WORK/ccq.log" 2>/dev/null || fail "NOTOKEN+node.env the default ccquota lease must run" "$(cat "$WORK/ccq.log" 2>/dev/null)"
[ "$(cat "$WORK/ccq.env" 2>/dev/null)" = tok-node ] || fail "NOTOKEN+node.env ccquota must see node.env's token" "ccquota saw: $(cat "$WORK/ccq.env" 2>/dev/null)"
[ "$(cat "$WORK/tmux.env" 2>/dev/null)" = '<unset>' ] || fail "NOTOKEN+node.env the window still never inherits it"
[ "$(cat "$WORK/spawn.err")" = "dash-issue-session: #258 的入口租约已拿到 (m5)" ] || fail "NOTOKEN+node.env prints only the grant on stderr" "$(cat "$WORK/spawn.err")"
ok "NOTOKEN default ccquota without a token → 「no node token」 + fix, no ccquota run; with node.env it runs with the token"

# ===== MOVE: fleet_hub_move shares the plumbing ==================================
cat > "$WORK/fakebin/fake-move" <<MOVEFAKE
#!/bin/bash
printf 'LOCAL m5\t%s\n' "\${CCQUOTA_TOKEN:-<unset>}"
MOVEFAKE
chmod +x "$WORK/fakebin/fake-move"
out=$(cd "$WORK" && FLEET_CONF_DIR="$WORK/conf" CCQUOTA_FLEET=1 FLEET_HUB_MOVE_CMD="$WORK/fakebin/fake-move" \
  bash -c '. "$1/fleet-lib.sh"; fleet_hub_move plan --node auto acme/widgets x/issue-1' _ "$BIN")
[ "$out" = $'LOCAL m5\ttok-node' ]               || fail "MOVE the move command must see node.env's token" "$out"
rm -f "$NODE_ENV"
err=$(cd "$WORK" && PATH="$WORK/ccqbin:$PATH" FLEET_CONF_DIR="$WORK/conf" CCQUOTA_FLEET=1 \
  bash -c '. "$1/fleet-lib.sh"; fleet_hub_move plan --node auto acme/widgets x/issue-1; echo "rc=$?"' _ "$BIN" 2>&1)
case "$err" in *'no node token (CCQUOTA_TOKEN unset and '*'node.env missing)'*'the move cannot be asked for'*'rc=1'*) ;;
  *) fail "MOVE the default ccquota move without a token says 「no node token」, rc 1" "$err" ;; esac
case "$err" in *'hub unreachable'*) fail "MOVE a missing token is not 「hub unreachable」" "$err" ;; esac
ok "MOVE fleet_hub_move: node.env's token reaches the command; none → 「no node token」"

# ===== UUID: the worker_id's fleet UUID is the FLEET's, not the window's repo (#1491) =
# A 2-repo fleet; the pane's window belongs to the second repo, so fleet_load_conf
# lays its overlay on (issue #788). fleet_uuid must still hash the fleet conf's own
# [session, FLEET_REPO, FLEET_MAIN] — what fleet_control.py's inventory minted and
# the hub registered — or every lease from such a pane is 403 「not registered」.
mkdir -p "$WORK/conf/fleets/testsess/repos" "$WORK/other" "$WORK/ovbin"
printf 'FLEET_REPO="acme/widgets"\nFLEET_MAIN="%s"\n' "$WORK/main" > "$WORK/conf/fleets/testsess/conf"
printf 'FLEET_REPO="acme/other"\nFLEET_MAIN="%s"\n' "$WORK/other" > "$WORK/conf/fleets/testsess/repos/acme-other.conf"
cat > "$WORK/ovbin/tmux" <<OVTMUX
#!/bin/bash
# the pane's window: session testsess, @repo acme/other
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
case "\$*" in
  *session_name*) echo testsess ;;
  *'@repo'*)      printf 'acme/other||\n' ;;
  *)              echo '' ;;
esac
exit 0
OVTMUX
chmod +x "$WORK/ovbin/tmux"
in_pane() { (cd "$WORK" && PATH="$WORK/ovbin:$PATH" TMUX=/tmp/fake,1,0 TMUX_PANE=%1 FLEET_CONF_DIR="$WORK/conf" bash -c '. "$1/fleet-lib.sh"; '"$1" _ "$BIN"); }
no_pane() { (cd "$WORK" && env -u TMUX -u TMUX_PANE FLEET_CONF_DIR="$WORK/conf" bash -c '. "$1/fleet-lib.sh"; '"$1" _ "$BIN"); }
[ "$(in_pane 'fleet_load_conf testsess; printf %s "$FLEET_REPO"')" = acme/other ] || fail "UUID setup: the fake pane must put the second repo's overlay on" "$(in_pane 'fleet_load_conf testsess; printf %s "$FLEET_REPO"')"
[ "$(no_pane 'fleet_load_conf testsess; printf %s "$FLEET_REPO"')" = acme/widgets ] || fail "UUID setup: outside a pane the fleet conf's own repo"
u_pane=$(in_pane 'fleet_uuid testsess'); u_fleet=$(no_pane 'fleet_uuid testsess')
[ -n "$u_fleet" ]                                || fail "UUID setup: fleet_uuid derived nothing"
[ "$u_pane" = "$u_fleet" ]                       || fail "UUID a pane bound to the second repo must mint the FLEET's UUID, not its window's" "pane: $u_pane · fleet: $u_fleet"
# … and == what the controller mints from `fleet-control-read.sh inventory`'s
# [session, repo, checkout] (fleet_control.py:74) — run from the SAME fake pane.
u_inv=$(cd "$WORK" && PATH="$WORK/ovbin:$PATH" TMUX=/tmp/fake,1,0 TMUX_PANE=%1 FLEET_CONF_DIR="$WORK/conf" \
  bash "$BIN/fleet-control-read.sh" inventory 2>/dev/null | python3 -c '
import json, sys, uuid
parts = sys.stdin.buffer.read().decode("utf-8").split("\0")
sess, repo, checkout = parts[0:3]
print(repo + " " + str(uuid.uuid5(uuid.UUID(sys.argv[1]), json.dumps([sess, repo, checkout], ensure_ascii=False, sort_keys=True, separators=(",", ":")))))' "$MACHINE")
[ "$u_inv" = "acme/widgets $u_fleet" ]           || fail "UUID the inventory run from that pane must name the fleet's own repo and mint the same UUID" "inventory: $u_inv · fleet: $u_fleet"
# the conf the other legs ran under (no FLEET_MAIN line, FLEET_REPO from the env)
# is restored so this leg leaves no footprint
rm -rf "$WORK/conf/fleets/testsess/repos" "$WORK/conf/fleets/testsess/conf"
ok "UUID the worker_id's fleet UUID ignores the window's repo overlay"

printf '\nselftest OK: %s assertions passed (hub issue lease, issue #1422)\n' "$pass"
exit 0
