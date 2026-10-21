#!/bin/bash
# selftest-parts: 3
# hub-place-selftest.sh — placement in bin/dash-issue-session.sh (issue #1425,
# EPIC #1419 C6): with CCQUOTA_FLEET=1 a spawn names no machine (`--node auto`),
# and after the hub lease (issue-lease-selftest.sh) it asks the hub which machine
# opens it. The place command is faked through FLEET_HUB_PLACE_CMD (the seam
# fleet_hub_place runs; in production `ccquota place`, whose hub side is
# tokenledger/hub/api/fleet_place.go — the mac-b-busy→mac-a integration lives in
# its fleet_place_test.go); the lease through FLEET_HUB_LEASE_CMD; git/gh/tmux on
# PATH as in issue-lease-selftest.sh. The real dash-issue-session.sh +
# fleet-lib.sh run unmodified.
#
#   OFF     CCQUOTA_FLEET unset → the place command never runs; stderr / gh / tmux
#           / git are byte-identical to a run with none configured — with no
#           --node and with --node auto / local (the degenerate case is sacred).
#   NOHUB   CCQUOTA_FLEET unset + --node mac-a → refused (exit 1), nothing spawned.
#   REMOTE  the hub placed it on mac-a → exit 0, stderr names mac-a and the reason, no
#           window, the lease NOT given back.
#   PARENT  a worker spawning a child sends its worker_id as --origin-wid.
#   LOCAL   the hub chose this machine → spawn here (no GitHub claim since #4898).
#   HELD    the hub says another machine holds it → exit 3, no spawn.
#   NOELIG  auto, no machine eligible → opened here, one note.
#   NAMED   --node mac-a refused by the hub → exit 2, no spawn, lease given back.
#   DOWN    hub unreachable → refused, no local fallback (#4392).
#   HUBSENT a start the hub sent (fleet-control-read.sh: --origin hub --node
#           local) → never placed again; its --origin-wid is stamped verbatim,
#           and its key as @origin (fleet-report-parent.sh needs a key there).
#   SELF    --node local / this host's alias → never asks the hub.
#   CAP     this machine is full → still placed on mac-a (exit 0); a LOCAL answer
#           then refuses with the cap reason (exit 2).
#   NOTHERE (issue T672) this machine full ⇒ its reason rides the ONE place ask as
#           `--not-here <why>` (one round trip, counted); the hub's ALL_DECLINED
#           then refuses naming every machine (exit 2); the hub never reached
#           (connection refused, rc 11) ⇒ opened here, `@placed fallback-local`;
#           a LOCAL answer stamps `@placed hub`; every ask says `place_ms=`.
#   DONE    (issue #1586) the hub waited and mac-a opened it → exit 0, the window id
#           on stderr and in the parent's children/<key>.dispatch.
#   DECLINED mac-a's spawn refused it → the same exit a refusal here gives (2 full ·
#           3 claimed · 1 else), its reason on stderr, the lease released, nothing
#           opened here (never the auto fallback); a re-send is granted, no --force.
#           (issue #1606/#1610) A start that never reached mac-a / never started
#           there comes back the same way (exit 1, its line, the operation id).
#   UNKNOWN still running there when the wait ran out → exit 1 saying 未知,
#           never a success; (issue #1606) the lease the hub gave back is
#           released; nothing opened here.
#   UNCLAIM a spawn here that failed (new-window) releases its lease; since #4898
#           nothing is claimed on GitHub, so nothing is given back there.
#   FALLBACK (issue #1610) the hub tried the next machine after a decline: the
#           line's `after <m>:<op>:<exit>,…` field is a dispatch row per machine
#           before the answer's, stripped from every message; each try's stderr
#           line passes through; LOCAL after the others opens here; REFUSED
#           ALL_DECLINED refuses (2 when every machine was full, else 1), never
#           opens here, gives the lease back.
#   ASYNC   --async asks with --wait 0; the operation id is left in the dispatch
#           file and `fleet-children.py show --json` lists it.
#   PERSONAL (issue #1721) a personal login (node.env CCQUOTA_FLEET_PERSONAL=1,
#           compute on) opens its spawns here when nothing names a machine;
#           FLEET_SPAWN_NODE still wins; compute off / no line ⇒ auto
#   PERFLEET (issue #1539) the hub switch and FLEET_SPAWN_NODE are read PER FLEET:
#           two fleets on one login, one conf `CCQUOTA_FLEET=0` and one `=1`, do
#           not affect each other whichever way the login-wide value points; a
#           fleet's FLEET_SPAWN_NODE beats the login's; no line ⇒ the login's.
#   ACCOUNT (issue #1540) --account local|pool rides to the hub as `--account <c>`
#           on the place command — never onto the window since the launcher's
#           pick retired (T550: no @account_class stamp); `any`, no flag
#           and garbage (named on stderr) add nothing; the fleet conf's
#           FLEET_ACCOUNT_CLASS is the default and `--account any` turns it off;
#           with the hub off the window is still stamped, nothing is placed.
#   TOKEN   (issue #1491) the place command sees node.env's CCQUOTA_TOKEN; the
#           spawned window never inherits it; the default `ccquota place` with no
#           token anywhere is not run and says 「no node token」, not 「unreachable」 —
#           and, never reached (T672), opens it here, @placed fallback-local.
#   SCRATCH (issue #1541, EPIC #1529 R3) bin/dash-raw-session.sh is placed the
#           same way, as `<repo> scratch <fleet UUID>` with its --name and parent:
#           hub off ⇒ byte-identical and --node mac-a refused; REMOTE / done /
#           LOCAL / no machine / named-refused / DECLINED / UNKNOWN / hub down
#           branch as an issue spawn's do, with NO lease at any point; local /
#           this host's alias never ask; a no-repo scratch with no task record
#           never travels, one bound to its record does with no repo (T742), a
#           seeded one (--prompt) does, its words as --body-file (T672), and so
#           does --as fleet-worker (a shipped file); a start the hub sent (--origin hub --node local
#           --origin-wid) is never placed again, stamps the parent verbatim and
#           prints its --print receipt; a full machine still places elsewhere;
#           the dash's --bg hands --node to the background pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-sections.sh"
selftest_sections 3
SPAWN="$BIN/dash-issue-session.sh"
[ -x "$SPAWN" ] || { echo "selftest: $SPAWN missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/place-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
# Read-only identity evidence before fixture exports/PATH changes. This is a
# creation-time snapshot, not a cleanup receipt; missing/unknown is not success.
if python3 - "$WORK" "${TMUX_TMPDIR:-}" "${FLEET_SELFTEST_ROOT:-}" "$$" "$SELFTEST_SECTION" 2>/dev/null <<'RESOURCE_RECORD'
import json, os, stat, sys, time

record = {"event": "hub-place-resources", "version": 1,
          "entry": "hub-place-selftest.sh", "section": sys.argv[5],
          "phase": "after_work_trap_before_fixture_environment", "cleanup_verified": False,
          "shell_pid": int(sys.argv[4]), "reader_pid": os.getpid(),
          "reader_ppid": os.getppid(), "wall_ns": time.time_ns(), "resources": []}
sources = (("WORK", sys.argv[1], "this entry mktemp result", "place-selftest."),
           ("TMUX_TMPDIR", sys.argv[2], "inherited TMUX_TMPDIR", "selftest-tt."),
           ("FLEET_SELFTEST_ROOT", sys.argv[3], "inherited FLEET_SELFTEST_ROOT", "fleet-selftest-root."))
for name, raw, source, prefix in sources:
    item = {"name": name, "source": source, "raw": None, "canonical": None,
            "raw_identity": None, "canonical_identity": None, "status": "missing"}
    record["resources"].append(item)
    if not raw:
        continue
    # Bound before JSON escaping; overlong paths are missing evidence, not
    # truncated strings that a later reader could mistake for a cleanup target.
    if len(os.fsencode(raw)) > 1024:
        item["status"] = "raw_path_too_long"
        continue
    item["raw"] = raw
    if not os.path.isabs(raw):
        item["status"] = "unknown_source_relative_path"
        continue
    try:
        canonical = os.path.realpath(raw)
        if len(os.fsencode(canonical)) > 1024:
            item["status"] = "canonical_path_too_long"
            continue
        item["canonical"] = canonical
        original, resolved = os.stat(raw), os.stat(canonical)
        item["raw_identity"] = {"dev": original.st_dev, "inode": original.st_ino}
        item["canonical_identity"] = {"dev": resolved.st_dev, "inode": resolved.st_ino}
        # Only check the known directory-name shape; this does not authenticate
        # an inherited directory's creator or authorize any cleanup operation.
        if not all(os.path.basename(p).startswith(prefix) for p in (raw, canonical)):
            item["status"] = "unknown_source_name"
        elif not stat.S_ISDIR(original.st_mode) or not stat.S_ISDIR(resolved.st_mode):
            item["status"] = "not_directory"
        elif item["raw_identity"] != item["canonical_identity"]:
            item["status"] = "identity_changed_during_read"
        else:
            item["status"] = "observed"
    except (OSError, ValueError) as exc:
        item.update(status="read_error", error_type=type(exc).__name__, errno=getattr(exc, "errno", None))
record["complete"] = (record["reader_ppid"] == record["shell_pid"]
                      and all(r["status"] == "observed" for r in record["resources"]))
record["read_end_wall_ns"] = time.time_ns()
line = "hub-place-resources " + json.dumps(record, ensure_ascii=True, separators=(",", ":"))
if len(line.encode("ascii")) + 1 > 65536:
    line = 'hub-place-resources {"complete":false,"status":"record_too_large"}'
print(line, flush=True)
RESOURCE_RECORD
then
  :
else
  printf 'hub-place-resources {"complete":false,"status":"reader_failed","reader_exit":%s,"shell_pid":%s,"section":"%s"}\n' "$?" "$$" "$SELFTEST_SECTION"
fi
cat > "$WORK/authority" <<'AUTH'
#!/bin/sh
printf '%s\n' '{"mode":"legacy","reservation":"fixture-local-start"}'
AUTH
chmod +x "$WORK/authority"
export FLEET_HUB_AUTHORITY_CMD="$WORK/authority"

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
# The shipped fleet-worker in the checkout (T672), so every runner resolves the
# issue spawn's default --as the same way (it travels with the placement).
mkdir -p "$WORK/main/.claude/agents"
cp "$BIN/../conf/agent-defaults/claude/agents/fleet-worker.md" "$WORK/main/.claude/agents/"
. "$BIN/selftest-repo-fixture.sh"
fx_repo "$WORK/conf" testsess acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master
GH_LOG="$WORK/gh.log"; TMUX_LOG="$WORK/tmux.log"; GIT_LOG="$WORK/git.log"; DISPLAY_LOG="$WORK/display.log"

# --- fake git: fetch/worktree/branch succeed; worktree+branch ops are LOGGED -------
cat > "$WORK/fakebin/git" <<GITFAKE
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  worktree|branch) printf 'git %s\n' "\$*" >> "$GIT_LOG" ;;   # add / remove / prune / branch -D
  rev-parse)       case "\$*" in *--show-toplevel*) pwd -P ;; *) printf 'deadbeef\n' ;; esac ;;
  show-ref)        exit 1 ;;   # no scratch-<N> branch yet (fleet_scratch_alloc, #1541)
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
  *"issue view"*"--json assignees --jq"*)  printf '%s\n' "\${PRE_ASSIGNEES:-0}" ;;   # the pre-place read (#1610)
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
  new-window)        printf 'new-window %s\n' "\$*" >> "$TMUX_LOG"; printf '%s\n' "\${CCQUOTA_TOKEN:-<unset>}" > "$WORK/tmux.env"
                     [ "\${TMUX_NEWWIN_FAIL:-0}" = 1 ] && exit 1; echo "\${TMUX_WIN:-@9}" ;;
  kill-window)       printf 'kill-window %s\n' "\$*" >> "$TMUX_LOG" ;;
  set-window-option) case "\$*" in *@origin*) printf 'set-window-option %s\n' "\$*" >> "$TMUX_LOG" ;; esac ;;
  run-shell)         printf 'run-shell %s\n' "\$*" | tr '\n' ' ' >> "$TMUX_LOG"; echo >> "$TMUX_LOG" ;;
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
# the seed a scratch carries (T672): --body-file's contents, before the caller removes it
prev=''; for a in "\$@"; do [ "\$prev" = --body-file ] && cat "\$a" > "$WORK/place.body"; prev=\$a; done
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
  # HUBCACHE=1: a fresh hub session table with no session in it (issue #1610).
  if [ "${HUBCACHE:-0}" = 1 ]; then
    mkdir -p "$WORK/dash/.claude-dash/global"
    printf '#ts\037%s\n' "$(date +%s)" > "$WORK/dash/.claude-dash/global/remote_testsess"
    date +%s > "$WORK/dash/.claude-dash/global/hub_ok"
  fi
  # INFLIGHT=1: one fresh spawn-in-flight marker, so FLEET_GLOBAL_MAX_SESSIONS=1 is full.
  if [ "${INFLIGHT:-0}" = 1 ]; then mkdir -p "$WORK/dash/.claude-dash/global/spawn-inflight"; : > "$WORK/dash/.claude-dash/global/spawn-inflight/x.1"; fi
  FLEET_ORIGIN_GATE=0 \
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
# The gh log sorted: the spawn's issue read and open-PR probe run side by side
# (issue #2237), so their order is not part of what "nothing changed" means.
# place_ms (T672) is a clock reading: the same run twice differs only there.
snap()        { cat "$WORK/spawn.rc"; sed -E 's/place_ms=[0-9]+/place_ms=N/; s/共 [0-9]+ ms/共 N ms/' "$WORK/spawn.err"; sort "$GH_LOG"; cat "$TMUX_LOG" "$GIT_LOG"; }

unset CCQUOTA_FLEET FLEET_HUB_LEASE_CMD FLEET_HUB_PLACE_CMD FLEET_HUB_STATUS_CMD FLEET_NODE_ALIASES
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL   # a pane under the pre-#1491 stop-gap exports the token
LEASE="$WORK/fakebin/fake-lease"; PLACE="$WORK/fakebin/fake-place"
# A configured fleet (an empty conf; its repo is the overlay): the UUID is frozen
# here, once, and every later spawn reads that file (issue #1936).
[ -f "$WORK/conf/fleets/testsess/conf" ] || : > "$WORK/conf/fleets/testsess/conf"
UUID=$(cd "$WORK" && FLEET_CONF_DIR="$WORK/conf" FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" \
  bash -c '. "$1/fleet-lib.sh"; fleet_uuid testsess' _ "$BIN")
[ -n "$UUID" ] || fail "setup: fleet_uuid derived nothing from the fake control database"


WID="$UUID/acme-widgets:issue-258"   # keys carry the repo (issue 1939)
REMOTE_LINE=$'REMOTE mac-a op_42 accepted\tchose mac-a (score 0.875, load 0.10/core); mac-b excluded: load 1.00/core > 0.8'

if selftest_section 1; then
# ===== OFF: CCQUOTA_FLEET unset ⇒ nothing runs, byte-identical ====================
CLAIM_STATE=$'0\tOPEN' run_spawn 258
base=$(snap)
for extra in '' '--node auto' '--node local'; do
  # shellcheck disable=SC2086  # deliberate: '' is no flag, the others two words
  CLAIM_STATE=$'0\tOPEN' FLEET_HUB_PLACE_CMD="$PLACE" FLEET_HUB_LEASE_CMD="$LEASE" run_spawn 258 $extra
  [ -s "$PLACE_LOG" ]                            && fail "OFF ($extra) the place command must not run without CCQUOTA_FLEET=1"
  [ "$(snap)" = "$base" ]                        || fail "OFF ($extra) must change nothing while the hub is off" "$(diff <(printf '%s\n' "$base") <(snap))"
done
CLAIM_STATE=$'0\tOPEN' TMUX_NEWWIN_FAIL=1 run_spawn 258
gh_has '--remove-assignee'                       && fail "OFF a failed spawn with the hub off keeps today's behaviour (no claim take-back)"
ok "OFF CCQUOTA_FLEET unset → no placement, byte-identical (no flag, --node auto, --node local)"

CLAIM_STATE=$'0\tOPEN' FLEET_HUB_PLACE_CMD="$PLACE" run_spawn 258 --node mac-a
[ "$(rc)" = 1 ]                                  || fail "NOHUB --node mac-a without the hub refuses (rc=$(rc))"
err_has 'needs the hub'                          || fail "NOHUB says why"
tmux_has 'new-window'                            && fail "NOHUB must not open it here instead"
ok "NOHUB --node <other machine> without the hub → refused, not silently local"

fi

# Parts 2/3 need the same hub seam without replaying OFF assertions.
export CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" FLEET_HUB_PLACE_CMD="$PLACE"

if selftest_section 1; then

# ===== REMOTE: placed on mac-a ⇒ nothing here, lease kept ============================
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "REMOTE exits 0 (rc=$(rc))"
place_has "--node auto --agent claude --as fleet-worker acme/widgets 258 $WID" || fail "REMOTE asks with node auto and this fleet's worker_id"
err_has '#258 → mac-a (hub operation op_42, accepted)' || fail "REMOTE names the machine and the operation"
err_has 'mac-b excluded: load 1.00/core > 0.8'      || fail "REMOTE carries the reason"
tmux_has 'new-window'                            && fail "REMOTE must not open a window here"
gh_has '--add-assignee'                          && fail "REMOTE leaves the GitHub claim to the machine that opens it"
lease_has release                                && fail "REMOTE the lease is the remote fleet's now — never given back"
head -n1 "$LEASE_LOG" | grep -q '^acquire' || fail "REMOTE the lease is taken BEFORE placing"
ok "REMOTE mac-b busy → sent to mac-a with its reason; no window, no claim, lease kept"

# an explicit --as of a file the release ships is still the hub's to place (T672)
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 --as fleet-worker
[ "$(rc)" = 0 ] && place_has '--node auto ' && place_has '--as fleet-worker' \
                                                 || fail "REMOTE --as fleet-worker still asks the hub (rc=$(rc))"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 --origin issue-77
place_has "--origin-wid $UUID/issue-77"          || fail "PARENT the parent's worker_id rides the placement"
ok "PARENT a worker's child carries --origin-wid <fleet UUID>/issue-77"

# ===== LOCAL: the hub chose this machine ⇒ today's path ===========================
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b (score 0.9)' run_spawn 258
[ "$(rc)" = 0 ]                                  || fail "LOCAL spawns (rc=$(rc))"
tmux_has 'new-window'                            || fail "LOCAL opens the window here"
gh_has '--add-assignee'                          && fail "LOCAL claims nothing on GitHub (#4898)"
err_has '开在本机 mac-b'                             || fail "LOCAL says where and why"
ok "LOCAL the hub chose this machine → spawn here, no GitHub claim"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'HELD mac-a\t#258 is leased to mac-a' PLACE_RC=3 run_spawn 258
[ "$(rc)" = 3 ]                                  || fail "HELD exits 3 (rc=$(rc))"
tmux_has 'new-window'                            && fail "HELD must not spawn"
ok "HELD leased elsewhere → exit 3, no spawn"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'REFUSED NO_ELIGIBLE_NODE\tNo machine can take a new session now' PLACE_RC=4 run_spawn 258
[ "$(rc)" = 1 ] && ! tmux_has 'new-window'         || fail "NOELIG auto with no eligible machine opens nothing here"
err_has 'no local fallback'                        || fail "NOELIG says so"
ok "NOELIG auto, no machine eligible → refused, no fallback"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'REFUSED NO_ELIGIBLE_NODE\tmac-a: at the per-person cap (6/6 sessions)' PLACE_RC=4 run_spawn 258 --node mac-a
[ "$(rc)" = 2 ]                                  || fail "NAMED a refused named machine exits 2 (rc=$(rc))"
place_has '--node mac-a '                     || fail "NAMED asks for that machine"
tmux_has 'new-window'                            && fail "NAMED must not open it here instead"
lease_has release                                || fail "NAMED the lease is given back"
ok "NAMED --node mac-a refused → exit 2, no spawn, lease back"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_RC=1 \
  PLACE_STDERR='ccquota: Post "https://hub.test/v1/node/place": context deadline exceeded (Client.Timeout exceeded while awaiting headers)' run_spawn 258
[ "$(rc)" = 1 ] && ! tmux_has 'new-window'         || fail "DOWN hub unreachable opens nothing here"
err_has 'fleet: hub unreachable (context deadline exceeded (Client.Timeout exceeded while awaiting headers)) — placing #258, opening it here' \
                                                 || fail "DOWN one note, with the cause"
ok "DOWN hub unreachable → refused, no fallback"

# issue #1507: a hub that ANSWERED is never 「unreachable」 — the note carries its error
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_RC=1 \
  PLACE_STDERR='ccquota: hub answered HTTP 403: {"error":"fleet c45a2451 is not registered to this node"}' run_spawn 258
[ "$(rc)" = 1 ] && ! tmux_has 'new-window'         || fail "WHY a refused placement opens nothing here"
err_has 'fleet: placement refused: HTTP 403 — fleet c45a2451 is not registered to this node — placing #258' \
                                                 || fail "WHY a 403 reads 「placement refused」 with the hub's error"
err_has 'unreachable'                            && fail "WHY a hub that answered is not 「unreachable」"
ok "WHY hub answered 403 → refused with its error, no fallback"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-a" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 --origin hub --origin-wid "$MACHINE/issue-77" --node local
[ -s "$PLACE_LOG" ]                              && fail "HUBSENT a start the hub sent is never placed again"
tmux_has 'new-window'                            || fail "HUBSENT opens it here"
tmux_has "@origin_wid $MACHINE/issue-77"         || fail "HUBSENT stamps the given parent worker_id"
tmux_has "@origin issue-77"                      || fail "HUBSENT stamps the parent's key as @origin too — the report path needs it"
ok "HUBSENT --origin hub --node local → no re-placement; @origin_wid stamped verbatim"

for n in local mac-b; do
  CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" \
    FLEET_NODE_ALIASES="$(hostname -s | tr '[:upper:]' '[:lower:]')=mac-b" run_spawn 258 --node "$n"
  [ -s "$PLACE_LOG" ]                            && fail "SELF --node $n must not ask the hub"
  tmux_has 'new-window'                          || fail "SELF --node $n opens it here"
done
ok "SELF --node local / this host's alias → no hub call"

# ===== PIN (issue #1543): --node local holds in any argv order, and FUSED ==========
# EPIC #1524 ran `extra="--node local"; dash-issue-session.sh $n --title "$t" $extra`
# in Claude's Bash tool — zsh, where an unquoted $extra does NOT word-split — so the
# script got ONE arg "--node local", ignored it as an unknown flag and let the hub
# place #1525 on mac-a. A fused "--flag value" is now read as --flag=value.
for args in "--repo|acme/widgets|--title|x|--node|local" "--node|local|--title|x|--repo|acme/widgets" \
            "--title|x|--node local" "--node local|--title x|--repo acme/widgets" "--node  local"; do
  _o=$IFS; IFS='|'; set -- $args; IFS=$_o
  CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 "$@"
  [ -s "$PLACE_LOG" ]                            && fail "PIN [$args] must not ask the hub"
  err_has 'chose'                                && fail "PIN [$args] prints no chose line"
  err_has 'unknown flag'                         && fail "PIN [$args] is no unknown flag"
  tmux_has "-n x"  || tmux_has "-n some-issue"   || fail "PIN [$args] opens it here"
done
if command -v zsh >/dev/null 2>&1; then          # the exact shape of the EPIC #1524 call
  printf '#!/bin/sh\nexec zsh -fc %s _ "%s"\n' "'extra=\"--node local\"; \"\$1\" 258 --title x \$extra'" "$SPAWN" > "$WORK/zsh-spawn"
  chmod +x "$WORK/zsh-spawn"
  CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" SPAWN="$WORK/zsh-spawn" run_spawn
  [ -s "$PLACE_LOG" ]                            && fail "PIN zsh's unsplit \$extra must not ask the hub"
  tmux_has 'new-window'                          || fail "PIN zsh's unsplit \$extra opens it here"
fi
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 "--node mac-a"
place_has "--node mac-a --agent claude --as fleet-worker acme/widgets 258"           || fail "PIN a fused --node <other machine> is asked for by name"
ok "PIN --node local in any order and fused (\"--node local\", zsh's unsplit \$var) → no hub call; fused mac-a → by name"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_spawn 258
[ "$(rc)" = 0 ] && err_has '#258 → mac-a'           || fail "CAP a full machine still places elsewhere (rc=$(rc))"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b' INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_spawn 258
[ "$(rc)" = 2 ] && err_has 'at capacity'         || fail "CAP opening here after all applies the cap (rc=$(rc))"
tmux_has 'new-window'                            && fail "CAP must not spawn past the cap"
lease_has release                                || fail "CAP the refused spawn gives the lease back"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_spawn 258 --node local
[ "$(rc)" = 2 ] && [ ! -s "$PLACE_LOG" ]         || fail "CAP --node local refuses at the cap without asking (rc=$(rc))"
ok "CAP a full machine still places elsewhere; opening here keeps the cap"

# ===== NOTHERE (T672): this machine's own refusal rides the one ask ==============
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_spawn 258
[ "$(rc)" = 0 ] && place_has '--not-here fleet at capacity' || fail "NOTHERE a full machine tells the hub so on its place ask (rc=$(rc))"
[ "$(grep -c . "$PLACE_LOG")" = 1 ]               || fail "NOTHERE one round trip: exactly one place ask (got $(grep -c . "$PLACE_LOG"))"
err_has 'place_ms='                              || fail "NOTHERE the ask is timed"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258
place_has '--not-here'                           && fail "NOTHERE a machine with room says nothing of the kind"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_RC=4 INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 \
  PLACE_ANSWER=$'REFUSED ALL_DECLINED\tevery machine that could take it said no — mac-b: 本机准入不过：fleet at capacity; mac-a: load 1.00/core > 0.8' run_spawn 258
[ "$(rc)" = 2 ] && err_has 'mac-b: 本机准入不过' && err_has 'mac-a: load 1.00/core' \
                                                 || fail "NOTHERE all full → refused (exit 2) naming every machine (rc=$(rc))" "$(cat "$WORK/spawn.err")"
tmux_has 'new-window'                            && fail "NOTHERE all full must not open here"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_RC=1 \
  PLACE_STDERR='ccquota: Post "https://hub.test/v1/node/place": dial tcp hub.test:443: connect: connection refused' run_spawn 258
[ "$(rc)" = 0 ] && tmux_has 'new-window' && tmux_has "@placed 'fallback-local'" \
                                                 || fail "NOTHERE the hub never reached → opened here, @placed fallback-local (rc=$(rc))" "$(cat "$WORK/spawn.err")"
err_has 'hub 不可达'                             || fail "NOTHERE the fallback is said"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b' run_spawn 258
tmux_has "@placed 'hub'"                         || fail "NOTHERE a LOCAL answer stamps @placed hub"
ok "NOTHERE a full machine's reason rides the one ask; all full names each; never reached → here, @placed fallback-local"

# ===== ALLFULL (issue #1587): every machine at its own cap ⇒ 都满了, naming each =====
ALLFULL=$'REFUSED AT_CAPACITY\tall-full: every machine is at its session cap — mac-a: full (8/8 sessions, the login\'s own cap); mac-b: full (1/1 sessions, the login\'s own cap)'
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$ALLFULL" PLACE_RC=4 INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_spawn 258
[ "$(rc)" = 2 ]                                  || fail "ALLFULL exits 2 (rc=$(rc))"
err_has '#258 都满了'                             || fail "ALLFULL says 都满了"
err_has 'mac-a: full (8/8 sessions'                 || fail "ALLFULL names each machine's count"
err_has 'raise FLEET_GLOBAL_MAX_SESSIONS'        && fail "ALLFULL is the fleet-wide answer, not this machine's cap line"
tmux_has 'new-window'                            && fail "ALLFULL must not spawn"
lease_has release                                || fail "ALLFULL gives the lease back"
# Even if a local slot freed, the refused accepted dispatch must not be replaced.
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$ALLFULL" PLACE_RC=4 run_spawn 258
[ "$(rc)" = 1 ] && ! tmux_has 'new-window'        || fail "ALLFULL a local slot cannot replace refused placement (rc=$(rc))"
ok "ALLFULL every machine full → 都满了 naming each, exit 2; a slot here since → still refused"

# ===== FLEET_SPAWN_NODE (issue #1475): the login-wide default when nothing names a machine
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=local run_spawn 258
[ -s "$PLACE_LOG" ]                              && fail "SPAWN_NODE=local must not ask the hub"
tmux_has 'new-window'                            || fail "SPAWN_NODE=local opens it here"
ok "SPAWN_NODE local → no placement, opened here (auto never leaves the machine)"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=mac-a run_spawn 258
place_has '--node mac-a '                           || fail "SPAWN_NODE=mac-a asks for that machine by name"
err_has '#258 → mac-a'                              || fail "SPAWN_NODE=mac-a is placed there"
ok "SPAWN_NODE mac-a → asked for by name"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=auto run_spawn 258
place_has '--node auto '                         || fail "SPAWN_NODE=auto asks with auto"
ok "SPAWN_NODE auto → the hub picks, as with no knob"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=local run_spawn 258 --node mac-a
place_has '--node mac-a '                           || fail "SPAWN_NODE a --node on the command still wins"
ok "SPAWN_NODE --node mac-a overrides the knob"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE='mac-a; rm -rf /' run_spawn 258
place_has '--node auto '                         || fail "SPAWN_NODE a value that is no machine name reads as auto"
ok "SPAWN_NODE garbage → auto"

# ===== PERSONAL (issue #1721): a person's own computer opens its spawns here by default
[ -e "$WORK/conf/node.env" ] && fail "setup: a node.env already in the sandbox conf"
printf 'CCQUOTA_FLEET_COMPUTE=1\nCCQUOTA_FLEET_PERSONAL=1\n' > "$WORK/conf/node.env"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258
[ -s "$PLACE_LOG" ]                              && fail "PERSONAL with no knob must not ask the hub"
tmux_has 'new-window'                            || fail "PERSONAL opens it here"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=auto run_spawn 258
place_has '--node auto '                         || fail "PERSONAL an explicit FLEET_SPAWN_NODE=auto still asks the hub"
printf 'CCQUOTA_FLEET_COMPUTE=0\nCCQUOTA_FLEET_PERSONAL=1\n' > "$WORK/conf/node.env"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258
place_has '--node auto '                         || fail "PERSONAL a login that only coordinates is not personal: auto"
printf 'CCQUOTA_FLEET_COMPUTE=1\n' > "$WORK/conf/node.env"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258
place_has '--node auto '                         || fail "PERSONAL no personal line: auto, as before"
rm -f "$WORK/conf/node.env"
ok "PERSONAL node.env CCQUOTA_FLEET_PERSONAL=1 → local by default; the knob, compute off, or no line → auto"

base=$(CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET='' FLEET_HUB_PLACE_CMD='' FLEET_HUB_LEASE_CMD='' run_spawn 258; snap)
CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET='' FLEET_HUB_PLACE_CMD='' FLEET_HUB_LEASE_CMD='' FLEET_SPAWN_NODE=mac-a run_spawn 258
[ "$(snap)" = "$base" ]                          || fail "SPAWN_NODE with the hub off must change nothing" "$(diff <(printf '%s\n' "$base") <(snap))"
ok "SPAWN_NODE off → byte-identical (the knob is never read without the hub)"

fi

if selftest_section 2; then
# ===== issue #1586: the outcome of a REMOTE start comes back ======================
DISPATCH="$WORK/conf/fleets/testsess/children/issue-77.dispatch"
rm -f "$DISPATCH"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'REMOTE mac-a op_43 done @42\tchose mac-a' run_spawn 258 --origin issue-77
[ "$(rc)" = 0 ]                                  || fail "DONE exits 0 (rc=$(rc))"
err_has '#258 → mac-a 已开窗 @42 (hub operation op_43)' || fail "DONE names the window that opened there"
place_has '--wait'                               && fail "DONE a sync spawn leaves the wait to the hub's default"
tmux_has 'new-window'                            && fail "DONE must not open a window here"
lease_has release                                && fail "DONE the lease is the remote's"
grep -q '"child": "acme-widgets:issue-258".*"op": "op_43".*"state": "done".*"window": "@42"' "$DISPATCH" \
                                                 || fail "DONE the parent's dispatch file records the window" "$(cat "$DISPATCH" 2>/dev/null)"
ok "DONE mac-a opened it → exit 0, window @42 on stderr and in the dispatch file"

for x in 2 3 1; do
  CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_RC=5 \
    PLACE_ANSWER=$'DECLINED mac-a op_44 '"$x"$'\tdash-issue-session: at capacity: 6/6 sessions on mac-a' run_spawn 258 --origin issue-77
  [ "$(rc)" = "$x" ]                             || fail "DECLINED exit $x comes back as $x (rc=$(rc))"
  err_has "#258 被 mac-a 拒绝 (exit $x): dash-issue-session: at capacity: 6/6 sessions on mac-a" || fail "DECLINED $x carries mac-a's reason"
  tmux_has 'new-window'                          && fail "DECLINED $x must not open it here (no auto fallback)"
  lease_has 'release'                            || fail "DECLINED $x releases the lease the hub gave back"
done
grep -q '"state": "refused"' "$DISPATCH"         || fail "DECLINED is recorded" "$(cat "$DISPATCH")"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b' run_spawn 258
grep -q -- '--force' "$LEASE_LOG"                && fail "DECLINED a re-send must not need --force"
ok "DECLINED mac-a refused → exit 2/3/1 with its reason, lease released, nothing opened"

CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_RC=6 \
  PLACE_ANSWER=$'UNKNOWN mac-a op_45\tno final state from mac-a (operation accepted)' run_spawn 258 --origin issue-77
[ "$(rc)" = 1 ]                                  || fail "UNKNOWN exits 1, never 0 (rc=$(rc))"
err_has '未知，不当成功: no final state from mac-a' || fail "UNKNOWN says so"
tmux_has 'new-window'                            && fail "UNKNOWN must not open it here too"
lease_has release                                || fail "UNKNOWN releases the lease the hub gave back (#1606)"
gh_has '--remove-assignee'                       && fail "UNKNOWN keeps the GitHub claim: mac-a may yet open it"
ok "UNKNOWN still running → exit 1 saying 未知; lease released, claim kept; nothing here"

# ===== #1606/#1610: a start mac-a swallowed — failed, lease AND claim given back =====
SWALLOWED=$'DECLINED mac-a op_47 1\tmac-a accepted operation op_47 but never started it within 60 s — nothing opened; re-send it'
CLAIM_STATE=$'0\tOPEN' PRE_ASSIGNEES=0 LEASE_ANSWER="GRANTED mac-b" PLACE_RC=5 PLACE_ANSWER="$SWALLOWED" run_spawn 258 --origin issue-77
[ "$(rc)" = 1 ]                                  || fail "SWALLOWED exits 1, never 0 (rc=$(rc))"
err_has '#258 被 mac-a 拒绝 (exit 1): mac-a accepted operation op_47 but never started it' || fail "SWALLOWED one line naming mac-a and the operation"
lease_has release                                || fail "SWALLOWED releases the lease"
gh_has '--remove-assignee'                       && fail "SWALLOWED writes nothing to GitHub (#4898: no claim to withdraw)"
grep -q '"op": "op_47".*"state": "refused"' "$DISPATCH" || fail "SWALLOWED is recorded with its operation" "$(cat "$DISPATCH")"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b' run_spawn 258
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "SWALLOWED the re-send opens without --force (rc=$(rc))"
grep -q -- '--force' "$LEASE_LOG"                && fail "SWALLOWED a re-send must not need --force"
CLAIM_STATE=$'1\tOPEN' PRE_ASSIGNEES=1 LEASE_ANSWER="GRANTED mac-b" PLACE_RC=5 PLACE_ANSWER="$SWALLOWED" run_spawn 258
gh_has '--remove-assignee'                       && fail "SWALLOWED an assignee that predates the ask is not ours to take"
CLAIM_STATE=$'0\tOPEN' PRE_ASSIGNEES=0 LEASE_ANSWER="GRANTED mac-b" PLACE_RC=5 \
  PLACE_ANSWER=$'DECLINED mac-a op_48 3\tdash-issue-session: #258 already claimed elsewhere (assigned)' run_spawn 258
gh_has '--remove-assignee'                       && fail "SWALLOWED exit 3 (claimed there) never withdraws the claim"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_RC=5 PLACE_ANSWER="$SWALLOWED" run_spawn 258 --async
gh_has '--json assignees --jq'                   && fail "SWALLOWED --async never pays for the pre-place read"
ok "SWALLOWED never started on mac-a → exit 1 with its line; lease back; re-send needs no --force"

# ===== UNCLAIM: a spawn here that failed gives its lease back, writes no GitHub ======
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b' TMUX_NEWWIN_FAIL=1 run_spawn 258
[ "$(rc)" = 1 ]                                  || fail "UNCLAIM a failed new-window exits 1 (rc=$(rc))"
gh_has 'assignee'                                && fail "UNCLAIM no claim taken or given back (#4898)"
lease_has release                                || fail "UNCLAIM the failed spawn releases its lease"
ok "UNCLAIM a failed spawn here releases its lease and writes nothing to GitHub"

DISPATCH="$WORK/conf/fleets/testsess/children/acme-widgets:issue-77.dispatch"
# ===== FALLBACK (issue #1610): the hub tried the next machine after a decline =====
rm -f "$DISPATCH"; DISPATCH="$WORK/conf/fleets/testsess/children/issue-77.dispatch"   # the writer's, as above
rm -f "$DISPATCH"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_RC=0 \
  PLACE_STDERR='ccquota place: mac-d declined (exit 1): fleet discover: fork/exec fleet-control.py: invalid argument — trying the next machine' \
  PLACE_ANSWER=$'REMOTE mac-a op_61 done @61\tchose mac-a\tafter mac-d:op_60:1' run_spawn 258 --origin issue-77
[ "$(rc)" = 0 ]                                  || fail "FALLBACK done on the next machine exits 0 (rc=$(rc))" "$(cat "$WORK/spawn.err")"
err_has '#258 → mac-a 已开窗 @61 (hub operation op_61) — chose mac-a' || fail "FALLBACK the reason stops before the after field" "$(cat "$WORK/spawn.err")"
err_has '#258 先被 mac-d 拒绝，入口已换下一台'    || fail "FALLBACK names the machine that declined first"
err_has 'fleet: mac-d declined (exit 1): fleet discover' || fail "FALLBACK passes each declined try through as it happened"
grep -q '"node": "mac-d", "op": "op_60", "state": "refused"' "$DISPATCH" || fail "FALLBACK mac-d's decline is its own dispatch row" "$(cat "$DISPATCH")"
python3 - "$DISPATCH" <<'PY' || fail "FALLBACK the book's last row for the child is mac-a's done" "$(cat "$DISPATCH")"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert [r['node'] for r in rows] == ['mac-d', 'mac-a'] and rows[-1]['state'] == 'done', rows
PY
lease_has release                                && fail "FALLBACK the lease is the machine's that opened it"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b\tafter mac-d:-:1,mac-a:op_62:2' run_spawn 258
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "FALLBACK LOCAL after the others opens here (rc=$(rc))"
err_has '#258 开在本机 mac-b — chose mac-b'$'\n'         || err_has '#258 开在本机 mac-b — chose mac-b' || fail "FALLBACK LOCAL reason without the after field"
err_has 'after mac-d'                            && fail "FALLBACK the after field never reaches a message raw"
for pre in 0 1; do
  CLAIM_STATE=$'0\tOPEN' PRE_ASSIGNEES=$pre LEASE_ANSWER="GRANTED mac-b" PLACE_RC=4 \
    PLACE_ANSWER=$'REFUSED ALL_DECLINED\tevery machine that could take it said no — mac-d: declined: fork; mac-a: declined: full\tafter mac-d:op_63:1,mac-a:op_64:2' run_spawn 258 --origin issue-77
  [ "$(rc)" = 1 ]                                || fail "ALL_DECLINED (pre=$pre) exits 1 (rc=$(rc))"
  err_has '#258 每台机器都拒绝了: every machine that could take it said no — mac-d: declined: fork; mac-a: declined: full' || fail "ALL_DECLINED names each machine's reason" "$(cat "$WORK/spawn.err")"
  tmux_has 'new-window'                          && fail "ALL_DECLINED never opens it here on the hub's no"
  lease_has release                              || fail "ALL_DECLINED releases the lease the hub gave back"
  gh_has '--remove-assignee'                     && fail "ALL_DECLINED writes nothing to GitHub (#4898)"
done
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_RC=4 \
  PLACE_ANSWER=$'REFUSED ALL_DECLINED\tall full\tafter mac-d:op_63:2,mac-a:op_64:2' run_spawn 258
[ "$(rc)" = 2 ]                                  || fail "ALL_DECLINED every machine full exits 2 (rc=$(rc))"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b' run_spawn 258
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "ALL_DECLINED the re-send opens without --force (rc=$(rc))"
grep -q -- '--force' "$LEASE_LOG"                && fail "ALL_DECLINED a re-send must not need --force"
ok "FALLBACK the hub's next machine: done/LOCAL after a decline recorded per machine; ALL_DECLINED refuses, gives the lease back, no --force after"

rm -f "$DISPATCH"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'REMOTE mac-a op_46 accepted\tchose mac-a' run_spawn 258 --origin issue-77 --async
[ "$(rc)" = 0 ]                                  || fail "ASYNC exits 0 (rc=$(rc))"
place_has '--wait 0 --as fleet-worker acme/widgets 258'            || fail "ASYNC asks with --wait 0"
grep -q '"op": "op_46".*"state": "accepted"' "$DISPATCH" || fail "ASYNC leaves the operation id" "$(cat "$DISPATCH" 2>/dev/null)"
shown=$(python3 "$BIN/fleet-children.py" show --dir "$(dirname "$DISPATCH")" --parent issue-77 --json </dev/null)
printf '%s' "$shown" | grep -q '"dispatches": \[{.*"op": "op_46"' || fail "ASYNC fleet-children lists the dispatch" "$shown"
shown=$(python3 "$BIN/fleet-children.py" show --dir "$WORK/conf/none" --parent issue-77 --json </dev/null)
printf '%s' "$shown" | grep -q dispatches         && fail "ASYNC no dispatch file → no dispatches key (unchanged answer)"
ok "ASYNC --async → --wait 0, operation id in the dispatch file, listed by fleet-children"

# ===== PERFLEET: the hub switch + FLEET_SPAWN_NODE per fleet (issue #1539) ========
# testsess = the fleet the fake tmux answers; `other` = a second fleet on the same
# login, named as the spawn's second argument (a headless target). Each conf carries only the lines under test.
mkdir -p "$WORK/conf/fleets/testsess" "$WORK/conf/fleets/other"
fx_repo "$WORK/conf" other acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master
printf 'CCQUOTA_FLEET=0\n' > "$WORK/conf/fleets/testsess/conf"
printf 'export CCQUOTA_FLEET=1\n' > "$WORK/conf/fleets/other/conf"
for login in 1 ''; do
  CCQUOTA_FLEET=$login CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258
  [ -s "$PLACE_LOG" ] || [ -s "$LEASE_LOG" ]     && fail "PERFLEET (login=${login:-unset}) a fleet whose conf says 0 must not ask the hub"
  tmux_has 'new-window'                          || fail "PERFLEET (login=${login:-unset}) the local fleet opens it here"
  CCQUOTA_FLEET=$login CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 other
  place_has '--node auto '                       || fail "PERFLEET (login=${login:-unset}) a fleet whose conf says 1 is placed by the hub"
  tmux_has 'new-window'                          && fail "PERFLEET (login=${login:-unset}) the hub fleet's remote placement opens nothing here"
done
ok "PERFLEET one fleet local, one hub — neither follows the other, nor the login-wide value"

printf 'CCQUOTA_FLEET=1\nFLEET_SPAWN_NODE=local\n' > "$WORK/conf/fleets/testsess/conf"
printf 'FLEET_SPAWN_NODE=mac-a\n' > "$WORK/conf/fleets/other/conf"
FLEET_SPAWN_NODE=mac-a CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258
[ -s "$PLACE_LOG" ]                              && fail "PERFLEET a fleet's FLEET_SPAWN_NODE=local beats the login's mac-a"
tmux_has 'new-window'                            || fail "PERFLEET SPAWN_NODE=local (fleet) opens it here"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 other
place_has '--node mac-a '                           || fail "PERFLEET the other fleet's own FLEET_SPAWN_NODE=mac-a (login: hub on, no knob)"
rm -f "$WORK/conf/fleets/other/conf"
FLEET_SPAWN_NODE=mac-a CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 other
place_has '--node mac-a '                           || fail "PERFLEET a fleet with no line follows the login's FLEET_SPAWN_NODE"
rm -f "$WORK/conf/fleets/testsess/conf"
ok "PERFLEET FLEET_SPAWN_NODE: the fleet's line beats the login's; no line ⇒ the login's"

# ===== ACCOUNT: --account local|pool|any — the subscription class (issue #1540) ====
LOCAL_LINE=$'LOCAL mac-b\tchose mac-b'
base=$(CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$LOCAL_LINE" run_spawn 258; snap)
place_has '--account'                            && fail "ACCOUNT no flag → nothing on the place command"
tmux_has '@account_class'                        && fail "ACCOUNT no flag → no stamp"
for a in '--account any' '--account=any'; do
  # shellcheck disable=SC2086  # deliberate: two words / one word
  CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$LOCAL_LINE" run_spawn 258 $a
  [ "$(snap)" = "$base" ]                        || fail "ACCOUNT ($a) must be byte-identical to no flag" "$(diff <(printf '%s\n' "$base") <(snap))"
done
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$LOCAL_LINE" run_spawn 258 --account bogus
err_has 'unknown --account bogus (local|pool|any)' || fail "ACCOUNT garbage is named on stderr" "$(cat "$WORK/spawn.err")"
place_has '--account'                            && fail "ACCOUNT garbage must not reach the place command"
tmux_has '@account_class'                        && fail "ACCOUNT garbage must not stamp the window"
tmux_has 'new-window'                            || fail "ACCOUNT garbage still opens it here"
ok "ACCOUNT no flag / any / garbage → nothing added (garbage named on stderr)"

for c in local pool; do
  CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$LOCAL_LINE" run_spawn 258 --account "$c"
  [ "$(rc)" = 0 ]                                || fail "ACCOUNT --account $c spawns (rc=$(rc))" "$(cat "$WORK/spawn.err")"
  place_has "--account $c --as fleet-worker acme/widgets 258 $WID" || fail "ACCOUNT --account $c is asked for on the place command"
  tmux_has '@account_class'                      && fail "ACCOUNT --account $c stamps no @account_class (T550)"
  tmux_has 'new-window'                          || fail "ACCOUNT --account $c: a LOCAL answer opens it here"
done
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$REMOTE_LINE" run_spawn 258 --account pool
place_has '--account pool --as fleet-worker acme/widgets'          || fail "ACCOUNT remote: the class travels with the placement"
tmux_has 'new-window'                            && fail "ACCOUNT remote: nothing opens here"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$LOCAL_LINE" run_spawn 258 "--account local"
place_has '--account local --as fleet-worker acme/widgets'         || fail "ACCOUNT a fused \"--account local\" (zsh's unsplit \$var) is read"
ok "ACCOUNT --account local|pool → --account on the place command, no window stamp; fused form read"

printf 'CCQUOTA_FLEET=1\nFLEET_ACCOUNT_CLASS=local\n' > "$WORK/conf/fleets/testsess/conf"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$LOCAL_LINE" run_spawn 258
place_has '--account local --as fleet-worker acme/widgets'         || fail "ACCOUNT the fleet conf's FLEET_ACCOUNT_CLASS is the default"
tmux_has '@account_class'                        && fail "ACCOUNT the conf default stamps nothing either (T550)"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$LOCAL_LINE" run_spawn 258 --account pool
place_has '--account pool --as fleet-worker acme/widgets'          || fail "ACCOUNT --account beats the conf default"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER="$LOCAL_LINE" run_spawn 258 --account any
place_has '--account'                            && fail "ACCOUNT --account any turns the conf default off"
tmux_has '@account_class'                        && fail "ACCOUNT --account any: no stamp either"
rm -f "$WORK/conf/fleets/testsess/conf"
ok "ACCOUNT FLEET_ACCOUNT_CLASS in the fleet conf is the default; --account wins, any switches it off"

CLAIM_STATE=$'0\tOPEN' CCQUOTA_FLEET='' FLEET_HUB_PLACE_CMD='' FLEET_HUB_LEASE_CMD='' run_spawn 258 --account local
[ -s "$PLACE_LOG" ]                              && fail "ACCOUNT hub off: nothing is placed"
tmux_has '@account_class'                        && fail "ACCOUNT hub off: no stamp — there is no local picker (T550)"
tmux_has 'new-window'                            || fail "ACCOUNT hub off: opens here"
ok "ACCOUNT with the hub off nothing is placed and nothing stamped"

# ===== TOKEN: node.env's token reaches the place command only (issue #1491) =======
NODE_ENV="$WORK/conf/node.env"
printf 'CCQUOTA_HUB_URL=http://hub.test\nCCQUOTA_TOKEN=tok-node\n' > "$NODE_ENV"; chmod 600 "$NODE_ENV"
CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b' run_spawn 258
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "TOKEN spawns (rc=$(rc))" "$(cat "$WORK/spawn.err")"
[ "$(cat "$WORK/place.env" 2>/dev/null)" = tok-node ] || fail "TOKEN the place command must see node.env's CCQUOTA_TOKEN" "place saw: $(cat "$WORK/place.env" 2>/dev/null)"
[ "$(cat "$WORK/tmux.env" 2>/dev/null)" = '<unset>' ] || fail "TOKEN the spawned window must NOT inherit the node token" "tmux saw: $(cat "$WORK/tmux.env" 2>/dev/null)"
# the DEFAULT `ccquota place` (no seam) with no token anywhere: not run, named
rm -f "$NODE_ENV"
cat > "$WORK/fakebin/ccquota" <<CCQFAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/ccq.log"; printf 'LOCAL mac-b\tchose mac-b\n'; exit 0
CCQFAKE
chmod +x "$WORK/fakebin/ccquota"
FLEET_HUB_PLACE_CMD='' CLAIM_STATE=$'0\tOPEN' LEASE_ANSWER="GRANTED mac-b" run_spawn 258
# never reached (T672, rc 11): nothing was sent, so it opens here — said and stamped
[ "$(rc)" = 0 ] && tmux_has 'new-window' && tmux_has "@placed 'fallback-local'" \
                                                 || fail "TOKEN-less default place opens here, @placed fallback-local (rc=$(rc))" "$(cat "$WORK/spawn.err")"
[ -e "$WORK/ccq.log" ]                           && fail "TOKEN-less: ccquota place must not be run without a token" "$(cat "$WORK/ccq.log")"
err_has "no node token (CCQUOTA_TOKEN unset and $NODE_ENV missing)" || fail "TOKEN-less stderr names what is missing" "$(cat "$WORK/spawn.err")"
err_has 'opening #258 here'                      || fail "TOKEN-less stderr says where it opens" "$(cat "$WORK/spawn.err")"
err_has 'hub unreachable'                        && fail "TOKEN-less is not 「hub unreachable」" "$(cat "$WORK/spawn.err")"
rm -f "$WORK/fakebin/ccquota"
ok "TOKEN node.env's token reaches the place command only; none → refused"

fi

if selftest_section 3; then
# ===== SCRATCH (issue #1541, EPIC #1529 R3): a raw scratch session is placed too ===
# The same seams (FLEET_HUB_PLACE_CMD / FLEET_HUB_LEASE_CMD, the fake git / gh /
# tmux), the real dash-raw-session.sh + fleet-lib.sh. A scratch has no issue: the
# hub is asked as `<repo> scratch <fleet UUID>` (+ --name, + --origin-wid for a
# parent) and the lease command is NEVER run.
RAW="$BIN/dash-raw-session.sh"
run_raw() { # $@ = args to dash-raw-session.sh
  : > "$GH_LOG"; : > "$TMUX_LOG"; : > "$GIT_LOG"; : > "$DISPLAY_LOG"; : > "$LEASE_LOG"; : > "$PLACE_LOG"
  rm -f "$WORK/place.env" "$WORK/tmux.env" "$WORK/ccq.log"
  rm -rf "$WORK/dash/.claude-dash"
  if [ "${INFLIGHT:-0}" = 1 ]; then mkdir -p "$WORK/dash/.claude-dash/global/spawn-inflight"; : > "$WORK/dash/.claude-dash/global/spawn-inflight/x.1"; fi
  FLEET_ORIGIN_GATE=0 \
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
    "$RAW" "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
  echo $? > "$WORK/spawn.rc"
}
unset CCQUOTA_FLEET FLEET_HUB_LEASE_CMD FLEET_HUB_PLACE_CMD FLEET_SPAWN_NODE FLEET_NODE_ALIASES
rm -f "$WORK/conf/node.env"

run_raw
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "SCRATCH-OFF a plain scratch opens here (rc=$(rc))" "$(cat "$WORK/spawn.err")"
rbase=$(snap)
for extra in '' '--node auto' '--node local'; do
  # shellcheck disable=SC2086  # deliberate: '' is no flag, the others two words
  FLEET_HUB_PLACE_CMD="$PLACE" FLEET_HUB_LEASE_CMD="$LEASE" run_raw $extra
  [ -s "$PLACE_LOG" ]                            && fail "SCRATCH-OFF ($extra) the place command must not run without CCQUOTA_FLEET=1"
  [ "$(snap)" = "$rbase" ]                       || fail "SCRATCH-OFF ($extra) must change nothing while the hub is off" "$(diff <(printf '%s\n' "$rbase") <(snap))"
done
FLEET_HUB_PLACE_CMD="$PLACE" run_raw --node mac-a
[ "$(rc)" = 1 ] && err_has 'needs the hub'       || fail "SCRATCH-NOHUB --node mac-a without the hub refuses (rc=$(rc))" "$(cat "$WORK/spawn.err")"
tmux_has 'new-window'                            && fail "SCRATCH-NOHUB must not open it here instead"
[ -s "$PLACE_LOG" ]                              && fail "SCRATCH-NOHUB must not ask the hub"
ok "SCRATCH OFF: hub off → no placement, byte-identical (no flag, auto, local); --node mac-a refused, nothing opened"

export CCQUOTA_FLEET=1 FLEET_HUB_LEASE_CMD="$LEASE" FLEET_HUB_PLACE_CMD="$PLACE"
PLACE_ANSWER="$REMOTE_LINE" run_raw --node mac-a --name '试一下 侧边栏' --origin issue-77
[ "$(rc)" = 0 ]                                  || fail "SCRATCH-REMOTE exits 0 (rc=$(rc))" "$(cat "$WORK/spawn.err")"
place_has "--node mac-a --origin-wid $UUID/issue-77 --agent claude --name 试一下 侧边栏 acme/widgets scratch $UUID" \
                                                 || fail "SCRATCH-REMOTE asks for mac-a as a scratch of THIS fleet, with its parent and name" "$(cat "$PLACE_LOG")"
[ -s "$LEASE_LOG" ]                              && fail "SCRATCH-REMOTE a scratch takes no lease" "$(cat "$LEASE_LOG")"
err_has 'scratch → mac-a (hub operation op_42, accepted)' || fail "SCRATCH-REMOTE names the machine and the operation" "$(cat "$WORK/spawn.err")"
err_has 'mac-b excluded: load 1.00/core > 0.8'      || fail "SCRATCH-REMOTE carries the reason"
tmux_has 'new-window'                            && fail "SCRATCH-REMOTE must not open a window here"
grep -q 'git worktree add' "$GIT_LOG"            && fail "SCRATCH-REMOTE must not allocate a worktree here"
ok "SCRATCH REMOTE --node mac-a → asked as «acme/widgets scratch <fleet UUID>» with --name + parent; no lease, no window, no worktree"

PLACE_ANSWER=$'REMOTE mac-a op_43 done @42\tchose mac-a (score 0.875)' run_raw --node auto
[ "$(rc)" = 0 ] && err_has 'scratch → mac-a 已开窗 @42 (hub operation op_43)' || fail "SCRATCH-DONE the hub waited and mac-a opened it (rc=$(rc))" "$(cat "$WORK/spawn.err")"
tmux_has 'new-window'                            && fail "SCRATCH-DONE nothing opens here"
ok "SCRATCH DONE → exit 0, the window id on stderr"

PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b (score 0.9)' run_raw
[ "$(rc)" = 0 ] && tmux_has 'new-window'         || fail "SCRATCH-LOCAL the hub chose this machine → opened here (rc=$(rc))" "$(cat "$WORK/spawn.err")"
place_has "--node auto --agent claude acme/widgets scratch $UUID" || fail "SCRATCH-LOCAL no --node asks with auto (the FLEET_SPAWN_NODE default)" "$(cat "$PLACE_LOG")"
err_has 'scratch 开在本机 mac-b'                      || fail "SCRATCH-LOCAL says where and why"
[ -s "$LEASE_LOG" ]                              && fail "SCRATCH-LOCAL still no lease"
ok "SCRATCH LOCAL → opened here as today; asked with auto when nothing names a machine"

PLACE_ANSWER=$'REFUSED NO_ELIGIBLE_NODE\tNo machine can take a new session now' PLACE_RC=4 run_raw
[ "$(rc)" = 1 ] && ! tmux_has 'new-window'         || fail "SCRATCH-NOELIG auto with no eligible machine opens nothing here (rc=$(rc))"
err_has 'no local fallback'                  || fail "SCRATCH-NOELIG says so"
PLACE_ANSWER=$'REFUSED NO_ELIGIBLE_NODE\tmac-a: at the per-person cap (6/6 sessions)' PLACE_RC=4 run_raw --node mac-a
[ "$(rc)" = 2 ]                                  || fail "SCRATCH-NAMED a refused named machine exits 2 (rc=$(rc))"
tmux_has 'new-window'                            && fail "SCRATCH-NAMED must not open it here instead"
err_has 'scratch 不能开在 mac-a: mac-a: at the per-person cap' || fail "SCRATCH-NAMED carries the hub's reason" "$(cat "$WORK/spawn.err")"
ok "SCRATCH NOELIG auto → refused; NAMED refused → exit 2, nothing opened"

PLACE_ANSWER=$'DECLINED mac-a op_44 2\tdash-raw-session: at capacity: 6/6 sessions' PLACE_RC=5 run_raw --node mac-a
[ "$(rc)" = 2 ] && err_has '被 mac-a 拒绝 (exit 2): dash-raw-session: at capacity' || fail "SCRATCH-DECLINED mac-a full → exit 2 with its line (rc=$(rc))" "$(cat "$WORK/spawn.err")"
tmux_has 'new-window'                            && fail "SCRATCH-DECLINED never the auto fallback"
PLACE_ANSWER=$'DECLINED mac-a op_44 1\tdash-raw-session: could not create a scratch worktree' PLACE_RC=5 run_raw --node mac-a
[ "$(rc)" = 1 ]                                  || fail "SCRATCH-DECLINED anything else → exit 1 (rc=$(rc))"
PLACE_ANSWER=$'UNKNOWN mac-a op_45\tno final state from mac-a' PLACE_RC=6 run_raw --node mac-a
[ "$(rc)" = 1 ] && err_has '未知，不当成功'         || fail "SCRATCH-UNKNOWN no final state → exit 1, never a success (rc=$(rc))" "$(cat "$WORK/spawn.err")"
tmux_has 'new-window'                            && fail "SCRATCH-UNKNOWN nothing opens here"
PLACE_ANSWER=$'REFUSED ALL_DECLINED\tevery machine that could take it said no — mac-d: declined: fork\tafter mac-d:op_70:1' PLACE_RC=4 run_raw
[ "$(rc)" = 1 ] && err_has '每台机器都拒绝了: every machine that could take it said no — mac-d: declined: fork' \
                                                 || fail "SCRATCH-ALL_DECLINED → exit 1 with each reason (rc=$(rc))" "$(cat "$WORK/spawn.err")"
tmux_has 'new-window'                            && fail "SCRATCH-ALL_DECLINED never opens it here on the hub's no (#1610)"
ok "SCRATCH DECLINED (2 full · 1 else), ALL_DECLINED and UNKNOWN (exit 1) come back as an issue spawn's do"

PLACE_RC=1 PLACE_STDERR='ccquota: Post "https://hub.test/v1/node/place": context deadline exceeded' run_raw
[ "$(rc)" = 1 ] && ! tmux_has 'new-window'         || fail "SCRATCH-DOWN hub unreachable opens nothing here (rc=$(rc))"
err_has 'fleet: hub unreachable (context deadline exceeded) — placing a scratch session, opening it here' || fail "SCRATCH-DOWN one note, with the cause" "$(cat "$WORK/spawn.err")"
PLACE_RC=1 run_raw --node mac-a
[ "$(rc)" = 1 ] && err_has 'scratch 不能开在 mac-a'    || fail "SCRATCH-DOWN a named machine with the hub down is refused (rc=$(rc))" "$(cat "$WORK/spawn.err")"
ok "SCRATCH DOWN → neither auto nor a named machine opens locally"

for n in local mac-b; do
  PLACE_ANSWER="$REMOTE_LINE" FLEET_NODE_ALIASES="$(hostname -s | tr '[:upper:]' '[:lower:]')=mac-b" run_raw --node "$n"
  [ -s "$PLACE_LOG" ]                            && fail "SCRATCH-SELF --node $n must not ask the hub"
  tmux_has 'new-window'                          || fail "SCRATCH-SELF --node $n opens it here"
done
PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=local run_raw
[ -s "$PLACE_LOG" ]                              && fail "SCRATCH-SPAWN_NODE=local must not ask the hub"
tmux_has 'new-window'                            || fail "SCRATCH-SPAWN_NODE=local opens it here"
PLACE_ANSWER="$REMOTE_LINE" FLEET_SPAWN_NODE=mac-a run_raw
place_has "--node mac-a --agent claude acme/widgets scratch $UUID" && err_has 'scratch → mac-a' || fail "SCRATCH-SPAWN_NODE=mac-a asks for that machine by name" "$(cat "$PLACE_LOG")"
ok "SCRATCH SELF (local / this host's alias) and FLEET_SPAWN_NODE=local never ask; FLEET_SPAWN_NODE=mac-a asks by name"

# A seeded scratch travels (T672): its words ride the start as --body-file.
rm -f "$WORK/place.body"
PLACE_ANSWER="$REMOTE_LINE" run_raw --node mac-a --prompt 'seed me'
[ "$(rc)" = 0 ] && place_has '--body-file' && [ "$(cat "$WORK/place.body" 2>/dev/null)" = 'seed me' ] \
                                                 || fail "SCRATCH-SEEDED --prompt travels with its words (rc=$(rc))" "$(cat "$WORK/spawn.err")"
tmux_has 'new-window'                            && fail "SCRATCH-SEEDED placed elsewhere must not open here too"
PLACE_ANSWER="$REMOTE_LINE" INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_raw --prompt 'seed me'
[ "$(rc)" = 0 ] && place_has '--not-here fleet at capacity' && err_has 'scratch → mac-a' \
                                                 || fail "SCRATCH-SEEDED a full machine sends a seeded scratch elsewhere (rc=$(rc))" "$(cat "$WORK/spawn.err")"
# the shipped fleet-worker travels; a file only here does not (T672, T604)
PLACE_ANSWER="$REMOTE_LINE" run_raw --node mac-a --as fleet-worker
[ "$(rc)" = 0 ] && place_has '--as fleet-worker' || fail "SCRATCH-AS --as fleet-worker opens on another machine (rc=$(rc))" "$(cat "$WORK/spawn.err")"
# …and with no --node it is still the hub's to place — dispatch --spawn's road
# (T672: an --as used to pin every spawn here)
PLACE_ANSWER="$REMOTE_LINE" run_raw --as fleet-worker
[ "$(rc)" = 0 ] && place_has '--node auto ' && place_has '--as fleet-worker' \
                                                 || fail "SCRATCH-AS --as fleet-worker with no --node asks the hub (rc=$(rc))" "$(cat "$PLACE_LOG")"
PLACE_ANSWER="$REMOTE_LINE" run_raw --node mac-a --no-repo
[ "$(rc)" = 1 ] && err_has 'a no-repo scratch with no task record opens on this machine only' || fail "SCRATCH-NOREPO --no-repo + --node mac-a is refused (rc=$(rc))" "$(cat "$WORK/spawn.err")"
[ -s "$PLACE_LOG" ]                              && fail "SCRATCH-NOREPO must not ask the hub"
PLACE_ANSWER="$REMOTE_LINE" run_raw --no-repo
[ "$(rc)" = 0 ] && [ ! -s "$PLACE_LOG" ] && tmux_has 'new-window' \
                                                 || fail "SCRATCH-NOREPO with no record (⌘N) opens here, never asking (rc=$(rc))" "$(cat "$PLACE_LOG")"
# A no-repo session bound to its task record is the hub's to place (T742): no repo
# to place by (an empty repo argument — any machine of the person's), its words as
# --body-file, a plugin's shipped agent file (epic-driver) with it.
rm -f "$WORK/place.body"
T42_DISPATCH='{"version":1,"request_id":"t42-req","requested_agent":"default","resolved_agent":"claude","agent_source":"default","task":"T42","generation":1,"attempt_id":"task:T42:g1"}'
printf '[{"id": "fleet-epic@claude-fleet", "enabled": true, "installPath": "%s"}]\n' "$BIN/../plugins/fleet-epic" > "$WORK/plugins.json"
PLACE_ANSWER="$REMOTE_LINE" FLEET_DISPATCH=$T42_DISPATCH FLEET_AGENT_PLUGINS_CMD="cat '$WORK/plugins.json'" \
  run_raw --no-repo --task T42 --as epic-driver --prompt 'drive the batch'
[ "$(rc)" = 0 ] && place_has '--node auto ' && place_has "  scratch $UUID" && ! place_has 'acme/widgets' \
  && place_has '--as epic-driver' && [ "$(cat "$WORK/place.body" 2>/dev/null)" = 'drive the batch' ] \
                                                 || fail "SCRATCH-NOREPO-TASK a no-repo task asks the hub with no repo (rc=$(rc))" "$(cat "$PLACE_LOG"; cat "$WORK/spawn.err")"
tmux_has 'new-window'                            && fail "SCRATCH-NOREPO-TASK placed elsewhere must not open here too"
PLACE_ANSWER="$REMOTE_LINE" FLEET_DISPATCH=$T42_DISPATCH run_raw --node mac-a --no-repo --task T42
[ "$(rc)" = 0 ] && place_has '--node mac-a ' && err_has 'scratch → mac-a' \
                                                 || fail "SCRATCH-NOREPO-TASK a named machine takes a no-repo task (rc=$(rc))" "$(cat "$WORK/spawn.err")"
PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b' FLEET_DISPATCH=$T42_DISPATCH run_raw --no-repo --task T42
[ "$(rc)" = 0 ] && tmux_has 'new-window' && tmux_has '@norepo' \
                                                 || fail "SCRATCH-NOREPO-TASK LOCAL opens it here, still no repo (rc=$(rc))" "$(cat "$WORK/spawn.err")"
ok "SCRATCH a seeded scratch, the shipped fleet-worker and a no-repo task travel; a record-less no-repo one stays here"

PLACE_ANSWER="$REMOTE_LINE" run_raw testsess --origin hub --origin-wid "$MACHINE/issue-77" --node local --print --name '试一下'
[ "$(rc)" = 0 ]                                  || fail "SCRATCH-HUBSENT exits 0 (rc=$(rc))" "$(cat "$WORK/spawn.err")"
[ -s "$PLACE_LOG" ]                              && fail "SCRATCH-HUBSENT a start the hub sent is never placed again"
tmux_has 'new-window'                            || fail "SCRATCH-HUBSENT opens it here"
tmux_has "@origin_wid $MACHINE/issue-77"         || fail "SCRATCH-HUBSENT stamps the given parent worker_id verbatim" "$(cat "$TMUX_LOG")"
tmux_has "@origin issue-77"                      || fail "SCRATCH-HUBSENT stamps the parent's key as @origin too — the report path needs it" "$(cat "$TMUX_LOG")"
# the 4th column is the window's @fleet_id (issue #1873) — present, whatever this fake tmux mints
[ "$(head -n1 "$WORK/spawn.out" | cut -f1-3)" = "$(printf '@9\t试一下\t%s/main-scratch-1' "$WORK")" ] \
  && [ "$(head -n1 "$WORK/spawn.out" | awk -F'\t' '{print NF}')" = 4 ] \
                                                 || fail "SCRATCH-HUBSENT --print prints the receipt <window_id>\\t<name>\\t<worktree>\\t<fleet_id>" "$(cat "$WORK/spawn.out")"
run_raw testsess --origin hub --node local
[ -s "$WORK/spawn.out" ]                         && fail "SCRATCH-HUBSENT without --print nothing is printed" "$(cat "$WORK/spawn.out")"
ok "SCRATCH HUBSENT --origin hub --node local → no re-placement; @origin_wid verbatim + @origin key; --print receipt"

PLACE_ANSWER="$REMOTE_LINE" INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_raw --node mac-a
[ "$(rc)" = 0 ] && err_has 'scratch → mac-a'        || fail "SCRATCH-CAP a full machine still places elsewhere (rc=$(rc))" "$(cat "$WORK/spawn.err")"
PLACE_ANSWER=$'LOCAL mac-b\tchose mac-b' INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_raw
[ "$(rc)" = 2 ] && err_has 'at capacity'         || fail "SCRATCH-CAP opening here after all applies the cap (rc=$(rc))" "$(cat "$WORK/spawn.err")"
tmux_has 'new-window'                            && fail "SCRATCH-CAP must not spawn past the cap"
INFLIGHT=1 FLEET_GLOBAL_MAX_SESSIONS=1 run_raw --node local
[ "$(rc)" = 2 ] && [ ! -s "$PLACE_LOG" ]         || fail "SCRATCH-CAP --node local refuses at the cap without asking (rc=$(rc))"
ok "SCRATCH CAP a full machine still places elsewhere; opening here keeps the cap"

# The dash's ⌃s is `--bg`: the keypress returns at once and the BACKGROUND pass
# does the asking — so --node (and --origin-wid) must ride the re-exec.
PLACE_ANSWER="$REMOTE_LINE" run_raw --bg --node mac-a --origin-wid "$MACHINE/issue-77"
[ "$(rc)" = 0 ]                                  || fail "SCRATCH-BG --bg returns 0 (rc=$(rc))" "$(cat "$WORK/spawn.err")"
[ -s "$PLACE_LOG" ]                              && fail "SCRATCH-BG the foreground --bg pass must not ask the hub itself"
tmux_has "run-shell"                             || fail "SCRATCH-BG hands off through run-shell -b" "$(cat "$TMUX_LOG")"
grep -q -- "--node=mac-a --origin-wid=$MACHINE/issue-77" "$TMUX_LOG" || fail "SCRATCH-BG the re-exec carries --node and --origin-wid" "$(cat "$TMUX_LOG")"
PLACE_ANSWER="$REMOTE_LINE" run_raw --bg
grep -q -- '--node=auto' "$TMUX_LOG"             || fail "SCRATCH-BG with the hub on and no flag the re-exec says --node=auto" "$(cat "$TMUX_LOG")"
unset CCQUOTA_FLEET
run_raw --bg
grep -q -- '--node=' "$TMUX_LOG"                 && fail "SCRATCH-BG hub off: the re-exec carries no --node (byte for byte)" "$(cat "$TMUX_LOG")"
export CCQUOTA_FLEET=1
ok "SCRATCH BG --bg carries --node / --origin-wid to the background pass; hub off carries nothing"

fi

printf 'hub-place-selftest: %s checks passed (selected section %s/3)\n' "$pass" "$SELFTEST_SECTION"
