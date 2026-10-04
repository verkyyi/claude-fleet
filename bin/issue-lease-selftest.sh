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
#   NOUUID no fleet UUID on this machine → one stderr note, today's path.
#   FORCE  --force → acquire carries --force; the takeover is announced.
#   MULTI  a 2-repo fleet keys the lease <slug>:issue-<N>, as its heartbeat will.
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
  new-window)        printf 'new-window %s\n' "\$*" >> "$TMUX_LOG"; echo "\${TMUX_WIN:-@9}" ;;
  kill-window)       printf 'kill-window %s\n' "\$*" >> "$TMUX_LOG" ;;
  set-window-option) : ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

LEASE_LOG="$WORK/lease.log"

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
  : > "$GH_LOG"; : > "$TMUX_LOG"; : > "$GIT_LOG"; : > "$DISPLAY_LOG"; : > "$LEASE_LOG"
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
  LEASE_RC=3 LEASE_ANSWER="HELD m5 $UUID/issue-258 2026-10-03T12:00:00Z" run_spawn 258
[ "$(rc)" = 3 ]                                  || fail "HELD exits 3 (the claimed class)" "rc=$(rc)"
err_has '已被 m5 认领'                            || fail "HELD stderr must say 已被 m5 认领"
lease_has "acquire acme/widgets 258 $UUID/issue-258" || fail "HELD acquire must name the repo, issue and worker_id"
gh_has '--add-assignee'                          && fail "HELD the lease is checked BEFORE the GitHub claim — no assign"
gh_has 'assignees,state'                         && fail "HELD must not even read the GitHub claim"
tmux_has 'new-window'                            && fail "HELD must not spawn"
ok "HELD lease on m5 → exit 3, 已被 m5 认领, no GitHub claim, no spawn"

# The hub names a machine by its hostname; the operator's FLEET_NODE_ALIASES names it m5.
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" FLEET_NODE_ALIASES="macmini=m5 mini2=m4" \
  LEASE_RC=3 LEASE_ANSWER="HELD macmini $UUID/issue-258 2026-10-03T12:00:00Z" run_spawn 258
[ "$(rc)" = 3 ] && err_has '已被 m5 认领'          || fail "ALIAS the holder must be named through FLEET_NODE_ALIASES"
ok "ALIAS HELD by macmini + FLEET_NODE_ALIASES=macmini=m5 → 已被 m5 认领"

# ===== GRANT: lease granted ⇒ today's claim + spawn, lease kept ==================
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" \
  LEASE_ANSWER="GRANTED m4" run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "GRANT spawns" "$(cat "$WORK/spawn.err")"
gh_has '--add-assignee'                          || fail "GRANT the GitHub claim still runs as the second guard"
tmux_has 'new-window'                            || fail "GRANT spawns the window"
lease_has release                                && fail "GRANT a spawned session keeps its lease"
[ -s "$WORK/spawn.err" ]                         && fail "GRANT a clean spawn prints nothing on stderr"
ok "GRANT lease granted → GitHub claim + spawn, lease kept"

# ===== BACK: granted, then GitHub refuses ⇒ lease given back =====================
CLAIM_STATE=$'1\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" \
  LEASE_ANSWER="GRANTED m4" run_spawn 258
[ "$(rc)" = 3 ]                                  || fail "BACK the GitHub refusal still exits 3" "rc=$(rc)"
lease_has "release acme/widgets 258 $UUID/issue-258" || fail "BACK a refused spawn must release the lease it took"
ok "BACK granted then GitHub-refused → lease released"

# ===== DOWN: hub unreachable ⇒ note + today's path ===============================
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" LEASE_RC=1 run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "DOWN an unreachable hub must not block the spawn" "$(cat "$WORK/spawn.err")"
err_has 'hub unreachable'                        || fail "DOWN must say on stderr that the hub could not be asked"
gh_has '--add-assignee'                          || fail "DOWN falls back to the GitHub claim"
tmux_has 'new-window'                            || fail "DOWN spawns"
ok "DOWN hub unreachable → stderr note, today's GitHub claim + spawn"

# ===== NOUUID: no control database ⇒ note + today's path =========================
mkdir -p "$WORK/conf2"
CONF_DIR="$WORK/conf2" CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "NOUUID spawns" "$(cat "$WORK/spawn.err")"
[ -s "$LEASE_LOG" ]                              && fail "NOUUID no worker_id → the lease command must not run"
err_has 'no fleet UUID'                          || fail "NOUUID must say why there is no lease"
ok "NOUUID no fleet UUID → stderr note, today's path"

# ===== FORCE: --force ⇒ acquire --force, takeover announced ======================
CLAIM_STATE=$'1\tOPEN' CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" \
  LEASE_ANSWER="FORCED m4 m5 $UUID/issue-258" run_spawn 258 --force
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

printf '\nselftest OK: %s assertions passed (hub issue lease, issue #1422)\n' "$pass"
exit 0
