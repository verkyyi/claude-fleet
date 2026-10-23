#!/bin/bash
# selftest-parts: 13 BREAK_PART
# fleet-break-it-selftest.sh — every known way to break the fleet, done for real
# in a sandbox, and the fleet putting itself back (issue #1786, EPIC #1776 C10).
#
# docs/dev/BREAK-IT.md is the list: one row per way (方式 · 后果 · 自愈方式 · 演练).
# Every row's 演练 cell names a `drill_<id>` below, or says 登记：<ticket> for a
# way fixed elsewhere (registered, never drilled). The table and the drills are
# held in lockstep: a row with no drill, or a drill with no row, is a FAIL. A new
# way to break the fleet gets its row and its drill FIRST (red), then the fix.
#
# Each drill breaks the thing, waits for the recovery and asserts an upper bound
# on how long it took; the run prints one line per row:
#   PASS  <id>  <secs>s ≤<cap>s  <what came back>
#
# Node half — an isolated tmux server (-S socket under $WORK, killed at exit), a
# sandbox install, a fake agent and a fake claude:
#   session-exit (exit · Ctrl+C · killed · Ctrl+Z)  bin/fleet-session-wrap.sh (the page, the TSTP guard)
#   resume-fails-fast / codex-no-id                 bin/fleet-session-wrap.sh, fleet-session-page.py
#   codex-resume-override                           bin/fleet-codex.sh, fleet-codex-posture.py
#   task-start-unseen                               bin/start-visible-selftest.sh (fleet-session-wrap.sh say_start,
#                                                   fleet_id.py start_word, fleet-epic-tick.py, fleet_task_control.py)
#   merged-then-commit                              bin/session-end-hook.sh --recycle, fleet_reap_ok
#   last-window                                     fleet_server_resident (fleet-up.sh)
#   kill-server / disk-full                         bin/fleet-restore.sh --auto, fleet-diskguard.sh --gate
#   wedged-socket                                   fleet_socket_heal (fleet-restore.sh, fleet-up.sh)
#   no-claude-on-path                               bin/fleet-claude.sh, fleet_find_tool
#   window-renamed                                  fleet_win_role (fleet-lib.sh), fleet-restore.sh
#   break-pane                                      bin/fleet-window-carry.sh (conf/tmux-attention.conf hook)
#   install-sync-killed                             bin/fleet-install-sync.sh (the tick lock)
#   spinner-booted-out                              bin/fleet-daemon-watch.sh --resident, fleet-diskguard.sh (resident_watch)
#   epic-hold-uncapped                              bin/fleet-epic-heartbeat.sh (one mark per batch), fleet_epic_holding
#                                                   (live/inflight), fleet-install-sync.sh (epic_gate with
#                                                   FLEET_EPIC_HOLD_CAP_SECS: defer before the switch, idle never
#                                                   holds, the login's clock caps a hold)
#   epic-hold-default                               fleet-install-sync.sh (epic_gate: no hold unless the cap is set, #2934)
#   doctor-stricter-rollback                        bin/fleet-install-sync.sh (the new doctor joins the
#                                                   baseline; FLEET_DOCTOR_SINCE), bin/fleet-doctor.sh
#   personal-tmux-conf                              conf/tmux-fleet-server.conf, fleet_server_new_session,
#                                                   fleet_tmuxconf_check, reapply-tmux-attention.sh
#   personal-hook-hangs / personal-hook-errors      bin/fleet-hook-personal.sh (timeout, strikes)
#   personal-mcp-missing / personal-mcp-over-default / personal-cache-truncated
#                                                   bin/fleet-agent-team.py (personal_layer), fleet-claude.sh, fleet-codex.sh
#   personal-breaks-session                         bin/fleet-session-wrap.sh, fleet-session-page.py (p), FLEET_PERSONAL=0
#   conf-keys-lost                                  bin/fleet-migrate-layout.sh, bin/fleet-conf.sh migrate
#                                                   (install-apply's layout + conf passes), fleet_conf_reserved
#   node-menu / node-prefix-keys                    conf/tmux-node-human.conf (via tmux-fleet-server.conf)
#   view-mouse-stale                                conf/tmux-view.conf + fleet-quickopen.py view-keys --if-stale
#   window-killed                                   bin/fleet-restore.sh --auto (pull-back), fleet_win_retire
#   loop-window-killed                              bin/fleet-restore.sh (loop re-arm), fleet_loop_mark.py rearm
#   restore-conversation-twice                      bin/fleet-restore.sh (restore, snapshot), fleet_restore_map_prune,
#                                                   bin/.fleet-restore-resolve.py (one row per conversation)
#   restore-peer-window / restore-role-lost        bin/fleet-restore.sh (snapshot drops @peer windows; role_handback)
#   codex-thread-lost                               bin/fleet-codex.sh (@codex_pending), fleet-restore.sh (snapshot),
#                                                   bin/.fleet-restore-resolve.py (--prior-map), fleet-session-wrap.sh
#   reap-agent-split                                bin/fleet-agent-end-selftest.py (both agents, T631),
#                                                   fleet_window_bg_busy (fleet-lib.sh), fleet-codex.sh
#   codex-clear-lost                                bin/fleet-codex-session.py (Follow, check_current: T540),
#                                                   bin/fleet-agent-deliver-selftest.py (both agents, T626),
#                                                   fleet-codex-runtime.py, fleet-peer-send.sh, fleet-report-parent.sh
#   tool-wait-idle                                  fleet_window_tool_busy / fleet_window_wait (fleet-lib.sh),
#                                                   fleet-state-reconcile.py, bin/set-claude-state.sh (Stop),
#                                                   fleet-wait-reeval.sh
#   human-step-reopen                               fleet_window_human / fleet_window_wait (fleet-lib.sh),
#                                                   bin/set-claude-state.sh (Stop + nudge), fleet-report-parent.sh,
#                                                   fleet_cfg_restart_why, fleet-wait-reeval.sh
#   cfg-reopen-loop                                 fleet_cfg_restart_why (fleet-lib.sh: the transcript backfill),
#                                                   bin/fleet-migrate.sh (cfg_update_nudge, the /loop rearm)
#   fleet-down-confirm                              bin/fleet-down.sh (confirm, --yes), fleet-up.sh --undo,
#                                                   fleet-restore.sh --undo
#   norepo-never-placed                             dash-raw-session.sh (a no-repo task asks with no repo),
#                                                   fleet_agent_file_travels (fleet-lib.sh: a plugin's agent file);
#                                                   the hub half is tokenledger/hub/api fleet_place.go (go test)
#   place-full-no-next / place-slow-bypass          fleet_hub_place (fleet-lib.sh: --not-here, rc 11, place_ms,
#                                                   fleet_hub_place_ms), dash-issue-session.sh / dash-raw-session.sh
#                                                   (CAP_HELD → the ask), fleet_agent_file_travels; the hub half is
#                                                   tokenledger/hub/api fleet_place.go not_here (go test, when here)
#   place-declined-not-retried                      fleet_hub_place (fleet-lib.sh: the `after` field, each try's
#                                                   stderr), fleet-children.py (claim: stale); the hub half is
#                                                   tokenledger/hub/api fleet_place.go (go test, when here)
#                                                   (exit 8), fleet_control.py (UNAVAILABLE); the hub half is
#                                                   tokenledger/hub/api pickNodeAfter (go test, when here)
#   oldcfg-deleted-hook                             bin/fleet-stable.sh move (the oldcfg gate), fleet-oldcfg-replay.py
#   macos-red-to-stable                             bin/fleet-macos-watch.sh (breakage alert, mac-follow.yml's jobs)
#   train-push-cancels                              .github/workflows/release-train.yml (concurrency), bin/fleet-train-board.sh,
#                                                   selftests-macos.yml (no push trigger)
#   release-artifact-missing                        bin/fleet-stable.sh move (the artifacts gate),
#                                                   fleet-node-update.py pinned-artifacts, the hub's build refusal
#   release-ccquota-stale                           bin/fleet-stable.sh move (the ccquota gate: ccquota_src, else
#                                                   /version), fleet-src-digest.py;
#                                                   the hub half is tokenledger/hub/api (go test, held by name)
#   login-browser-silent                            bin/fleet-login.py (scan: open_browser, KeyWatch, nudge, timeout)
#   login-sandbox-real-conf                         bin/fleet-login.py (conf_dir_env)
#   opening-never-ends                              tokenledger/hub/api fleet_opening.go
#                                                   (openingStuck, openingETAFor; go test, when a toolchain is here)
#   opening-eta-climbs                              tokenledger/hub/api fleet_opening.go (openingETALeft)
#   opened-login-fleet-silent                       tokenledger/hub/api fleet_opening.go (settling, settleWhy,
#                                                   openingNotes, openingOver; go test); client first-open coverage is in the thin drills
#   stale-admin-opens-login                         tokenledger/hub/api nodes.go (openerFor, CapLoginJoin) +
#                                                   fleet_accounts.go (dispatchAccounts, noLoginOpenerWhy); go test
#   heartbeat-sys-blocked                           tokenledger/agent beat_parts.go (sysSampler, asyncReading,
#                                                   fleetBeatBudget) + hub/api nodes.go (foldSys); go test
#   login-remove-record-left                        bin/fleet-login-remove.sh (step 6 checks the record is gone)
#   spare-reuse-leaks                               bin/fleet-login-reset-check.py (the category table), its selftest
#   spare-recycle-dirty                             tokenledger/hub/api fleet_recycle.go (recycleClear,
#                                                   recycleLeftovers, applyReset) + store RecycleAccount; go test
#   home-template-leak                              bin/fleet-home-template.py (build from the runtime only, refuse credentials), its selftest
#   spare-wash-resume                               bin/fleet-login-reset.sh (stop · wash · rejoin · check, the op file), its selftest
#   login-remove-uid-leftovers                      bin/fleet-login-remove.sh step 5b (#3508)
#   trial-wash-webchat-registered                   bin/fleet-login-remove.sh + fleet-node-supervisor.py service drop-fleet (#4273)
#   spare-wash-no-fda                               bin/fleet-login-reset.sh wash → bin/fleet-login-remove-ssh.sh wash (#3508)
#   spare-wash-respawn                              bin/fleet-login-reset.sh (quiesce before --since and after the home move, #3979)
#   login-remove-respawn-hang                       bin/fleet-login-remove.sh (quiesce: bootout user/gui, deleteUser time limit)
#   far-agent-switch                                bin/fleet_view.py ACTIONS agent (far), bin/fleet-control-read.sh transfer (#4184)
#   newcomer-login-no-gh                            bin/fleet-control-read.sh ready (gh only with a hosted repo)
#                                                   + bin/fleet-client-place.sh self_lines (no host-here hint)
#   login-remove-no-fda                             bin/fleet-login-remove.sh (a failed deleteUser is checked, not
#                                                   the end; leftover home moved aside) + agent accountWhy
#   account-remove-tenant-held                      tokenledger/agent runas.go (holdLogin; go test)
#   linux-hub-other-root-op                         tokenledger/agent node_machine_accounts.go (go test)
#                                                   + bin/fleet-node-linux.py (exit 3 to another op)
#   newcomer-login-hosts-repo                       bin/fleet-control-read.sh ready (a seed repo needs no gh — but a repo start does, #3424)
#   login-remove-dscl-denied                        bin/fleet-node-supervisor.py (fda reading, status --check 4), bin/fleet-login-remove-ssh.sh
#                                                   + bin/fleet-login-remove.sh (says Full Disk Access)
#   machine-lane-reissued                           tokenledger/hub/api fleet_login_node.go (deviceNode, machineServing)
#                                                   + store EndpointByTokenHash (prev_token_hash) + node_machine.go
#                                                   (staleLoginTokenWhy), tokenledger/agent lane_state.go,
#                                                   bin/fleet-node-supervisor.py (lanes, account adopt --rejoin)
#   oldcfg-broken-unmarked                          bin/fleet-oldcfg-check.sh --sweep (fleet-oldcfg-replay.py --manifest),
#                                                   fleet_cfg_state / fleet_cfg_broken_load (fleet-lib.sh), fleet-ui-lang.sh
#   pretrust-norepo                                 bin/fleet-trust.sh (node, grant --home), bin/fleet-claude.sh
#   cross-send-refused-unseen                       bin/fleet-peer-send.sh (hub_send: identity sender, fleet_hub_refused,
#                                                   receipt_watch), fleet-lib.sh fleet_hub_refused
#   status-agent-not-up / status-perm-overwritten / status-migrated-looping / status-question-lost
#   epic-driver-unknown-command                     bin/set-claude-state.sh + fleet_needs_detail.py nostart (a
#                                                   first turn with no reply is needs/nostart, not done),
#                                                   fleet_reap_notice.reap_state, bin/dash-raw-session.sh
#                                                   (FLEET_EPIC_RUN_LINE: an older charter's first line, T646)
#                                                   bin/set-claude-state.sh (the primary-source rule),
#                                                   fleet-status-7501.py pipe,
#                                                   fleet_state_carry / fleet_primary_fresh (fleet-lib.sh),
#                                                   fleet-state-reconcile.py (reconcile.sources)
#   report-parent-gone                              bin/fleet-report-parent.sh (orphan → global/orphan-reports.ndjson
#                                                   + fleet-alerts.sh event child-report; rail 1 → the hub outbox by
#                                                   @origin_wid), fleet-lib.sh fleet_origin_canon,
#                                                   bin/fleet-hub-node.sh (deliver: an identity found here is
#                                                   never «not now»), fleet-lib.sh fleet_window_okey (a keyless
#                                                   session's key is its @fleet_id, issue #4341)
#   orphan-report-unseen                            bin/fleet-orphan-reports.py, fleet-control-read.sh column 31,
#                                                   fleet_hub_common.py orphan_rep_cell
#   reap-other-repo-clears / reap-stale-stamp       bin/fleet-cleanup-idle.py, fleet_reap_notice.py, fleet-reap-live.py
#   reap-reopen-restarts-clock                      fleet_cfg_restart_why (fleet-lib.sh), fleet-cfg-restart.sh
#   reopen-reap-race                                fleet_cfg_restart_why / fleet_cfg_work_over (fleet-lib.sh),
#                                                   bin/fleet-cleanup-idle.py (close: @migrating + the transition lock)
#   stop-bare-path                                  bin/fleet-worker-stop.sh (fleet_path_fill)
#   done-window-lingers                             bin/fleet-cleanup-idle.py (id_over, --only/--grace),
#                                                   fleet-cleanup-idle.sh --now, fleet_reap_soon (fleet-lib.sh)
#   done-window-untracked                           bin/fleet-cleanup-idle.py (eligible: untracked-only, task=True)
#   stop-no-exit-hangs                              bin/fleet-worker-stop.sh (stopped:forced, fleet_kill_tree)
#   admit-tight-done-windows                        fleet_session_cap_ok / fleet_admit_make_room (fleet-lib.sh),
#                                                   fleet-cleanup-idle.sh --make-room, fleet-cleanup-idle.py --plan-room/--fold
#   reopen-folding-session                          fleet_cfg_restart_why (fleet-lib.sh: @reap_due / @reap_seen)
#   peerq-undeliverable-forever                     bin/fleet-peer-queue.sh stale / status (FLEET_PEER_QUEUE_DEAD_SECS)
#   reopen-every-release                            bin/fleet-cfg-restart.sh (cfg-restart.ledger, FLEET_CFG_RESTART_DAY)
#   report-parent-cleared                           bin/fleet-report-parent.sh + fleet_task_control.py receive
#                                                   (the parent by its ID: fleet_id_take, fleet-id.sh route)
#   id-switch-flip-report                           bin/fleet-report-parent.sh + fleet_task_control.py report
#                                                   (a task's report is its ID's result, whatever ids/.switch says)
#   c8-old-supervisor-reopen                        bin/fleet_launch.py (the C8 shim: supervise retires @launch*
#                                                   and goes the ordinary road), fleet-session-wrap.sh
#   park-while-watched / wake-timeout               bin/fleet_session_gate.py (park · wake: task HHV0),
#                                                   fleet-session-wrap.sh (park_hold), fleet-cleanup-idle.py web_park
#   epic-member-dead-record                         bin/fleet-epic-tick.py (a member by its ID chain:
#                                                   batons_of, fleet-id.sh family)
#   task-many-ids                                   bin/fleet_id.py (take_task_id, next_attempt, the reopen
#                                                   hint), dash-raw-session.sh / dash-issue-session.sh
#                                                   (fleet_task_take, fleet-lib.sh)
#   epic-driver-continued                           bin/fleet-epic-tick.py + bin/fleet_id.py (the driver's
#                                                   line: lineage_of, task_root, adopted — C18)
#   launch-binary-renamed                           bin/fleet_native_proc.py (same_executable / native_tool:
#                                                   a hard-linked binary is one file, T524)
# Cred half — cred-* rows: bin/fleet-break-it-cred-selftest.sh runs them (its own
#   test; listed here only through the lockstep lint) — and cred-shared-down,
#   bin/fleet-break-it-cred-shared-selftest.sh (issue #2217) — and cred-sep-by-agent /
#   cred-sep-bootstrap-fails, bin/fleet-break-it-cred-sep-selftest.sh (issue #2273).
# Hub half — release / hub-shape / placement / the hub's Go-tested rows, admission and
#   the node's sessions riding a tmux restart or a node update: bin/fleet-break-it-hub-selftest.sh (issue #2699, split
#   off when this run crossed the gate's 240 s per-test cap).
# Peerlink half — peerlink-* rows (issue #3002): the home machine's standing
#   connections, bin/fleet-break-it-peerlink-selftest.sh (a fake ssh, no network).
# Thin half — thin-* rows (issue #3005): a thin client's lease, notifications and
#   pages kept by its home machine, bin/fleet-break-it-thin-selftest.sh.
#   The thin loop on the person's own computer (issue #3007): bin/fleet-break-it-thin-client-selftest.sh.
# Entry half — entry-* rows (issue #3070): the home machine's public entry port, a
#   real sshd in a sandbox on 127.0.0.1, bin/fleet-break-it-entry-selftest.sh.
# Cluster half — sa-token-in-user-pod, provisioner-off-template (issue #3558): every
#   pod template's token and the provisioner against a stand-in API on 127.0.0.1,
#   bin/fleet-break-it-cluster-selftest.sh; the real cluster's RBAC and admission
#   policy on kind, deploy/k8s/provisioner/kind-drill.sh (cluster-perms.yml).
# Sidefx half — sandbox-home-real-uid (issue #4213): a teardown sandboxed by HOME
#   alone, bin/fleet-break-it-sidefx-selftest.sh (decoys, a record, no real signal).
# CI half — ci-runner-* rows (issue #3144): the machine's test runner, a fake GitHub
#   API on 127.0.0.1 and a fake runner archive, bin/fleet-break-it-ci-selftest.sh.
# Shell half — a sandbox fleet on -L kf (TMUX_TMPDIR under $WORK), the real wrapper:
#   shell-kill-fleet                                bin/tmux-shim/tmux, fleet-session-wrap.sh, hooks/bash-guard.py
# Machine half — a sandbox Homebrew prefix under a world-traversable tmp dir:
#   brew-keg-700                                    bin/fleet-diskguard.sh --brew-watch,
#                                                   bin/fleet-brew-perms.sh
#   nothing-starts-by-itself                        bin/fleet-diskguard.sh macos_watch, fleet-macos-watch.sh
#   release-push-lost                               bin/fleet-node-supervisor.py (task_due: update-now + the
#                                                   update clock), fleet-install-sync.sh --now; the Go half is
#                                                   tokenledger/{hub/api,agent} *release_push / node_release
#
# tmux / python3 absent → SKIP (exit 0). BREAK_KEEP=1 keeps the work dir.
# BREAK_ONLY="<id> <id>" runs only those drills (the lockstep lint always runs);
# so do ids given as arguments (`fleet-break-it-selftest.sh cmdn-waits-orch …`).
# BREAK_PART=K/N runs the K-th of N contiguous slices of this script's drills, in
# the table's order (issue #2955: the whole list outgrew the gate's 240 s per-test
# ceiling), balanced by each drill's wall time in bin/break-it-durations.txt
# (fleet-break-it-part.py, issue #2694). This file runs 1/13 by default,
# ids fleet-break-it-selftest.sh#2..#13 the rest (T525) —
# each its own test, its own ceiling, its own durations row; `BREAK_PART=all` runs
# every drill in one go. BREAK_ONLY / ids win over the part. Drills keep no state
# across each other beyond lazy, idempotent rigs, so any
# slice runs on its own.
set -uo pipefail
[ $# -gt 0 ] && BREAK_ONLY="$*"
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-repo-fixture.sh"
ROOT="$(cd "$BIN/.." && pwd)"
DOC="$ROOT/docs/dev/BREAK-IT.md"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-break-it: python3 absent — SKIP\n'; exit 0; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'fleet-break-it: tmux absent — SKIP\n'; exit 0; }
# never the caller's pane: a drill's `run` loop would take a pane it does not own
# for a replaced server's and end at once (#2987), and nothing here is that pane's
unset TMUX TMUX_PANE
# A worker launched by restore inherits these; each drill chooses its own mode.
unset RESTORE_UNFINISHED RESTORE_KEEP_DONE RESTORE_ONLY_MAP

WORK="$(mktemp -d "${TMPDIR:-/tmp}/brk.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
cleanup() {
  local s
  for s in "$WORK"/sock-*; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  for s in kf "kscr$$"; do TMUX_TMPDIR="$WORK/ktt" "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; done
  for s in vrn vrc; do TMUX_TMPDIR="$WORK/vt" "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; done
  pkill -f "$WORK/" 2>/dev/null
  [ -n "${BREAK_KEEP:-}" ] && { printf 'kept %s\n' "$WORK" >&2; return; }
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

now() { python3 -c 'import time; print("%.3f" % time.time())'; }
since() { python3 -c 'import sys, time; print("%.1f" % (time.time() - float(sys.argv[1])))' "$1"; }
le() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$1" "$2"; }
# until_ok <secs> <command…> — true as soon as the command is
until_ok() {
  local secs="$1" _; shift
  for _ in $(seq 1 $((secs * 10))); do "$@" && return 0; sleep 0.1; done
  "$@"
}

# suite_holds <test id> [<text>…] — a drill whose recovery IS another selftest's
# whole run (same file, same arguments, a suite id of its own) holds that test by
# name instead of running it a second time in the same suite (T532: eleven drills
# re-ran a standalone selftest, ~360 s of every full run spent twice, and a flaky
# leg had two chances to red). The held test's own run is where the recovery is
# checked: <test id> (`<file>`, `<file>#K`, or a part-split `<file>` = all its parts
# together) must be one run-selftests.sh lists,
# and each <text> — the leg, the fixture, the line that times it — must still be in
# its file. SECS is the check's own time. Keep in sync: fleet-break-it-selftest.sh
# and fleet-break-it-cred-selftest.sh (the other files' shared runner).
suite_holds() {
  local t=$1 f s; shift
  f=${t%%#*}
  [ -f "$BIN/$f" ] || { WHY="$f is gone: nothing runs what this drill held"; return 1; }
  [ -s "$WORK/suite-ids" ] || FLEET_SELFTEST_NO_SHADOW=1 FLEET_HEAVY=0 sh "$BIN/run-selftests.sh" --ids > "$WORK/suite-ids" 2>/dev/null
  { grep -qxF -- "$t" "$WORK/suite-ids" || { [ "$t" = "$f" ] && grep -q "^$f#[0-9]*\$" "$WORK/suite-ids"; }; } \
    || { WHY="$t is no longer a test the suite runs: this drill held it"; return 1; }
  for s in "$@"; do
    grep -qF -- "$s" "$BIN/$f" || { WHY="$f no longer carries [${s}]: this drill held it"; return 1; }
  done
}

# ============================================================== the list =}

# rows: "<id>" for a drilled row, "@<text>" for a registered one
ROWS=$(python3 - "$DOC" <<'PY'
import re, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.startswith("| ") or line.startswith("| 方式") or line.startswith("|---"):
        continue
    cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
    if len(cells) != 4 or not all(cells):
        print("!" + line.strip()); continue
    m = re.fullmatch(r"`([a-z0-9-]+)`", cells[3])
    if m: print(m.group(1))
    elif cells[3].startswith("登记："): print("@" + cells[3])
    else: print("!" + line.strip())
PY
)
LINT=0
lintfail() { LINT=$((LINT + 1)); printf 'FAIL  lint: %s\n' "$1"; }
[ -f "$DOC" ] || lintfail "docs/dev/BREAK-IT.md is missing"
# The cred half lives in its own script (issue #1975: its own run, its own
# durations row) — its drills are listed rows like any other.
DRILLS=$(sed -n 's/^drill_\([a-z0-9_]*\)() *{.*/\1/p' "$0" "$BIN/fleet-break-it-cred-selftest.sh" "$BIN/fleet-break-it-cred-shared-selftest.sh" "$BIN/fleet-break-it-revoke-selftest.sh" "$BIN/fleet-break-it-cred-sep-selftest.sh" "$BIN/fleet-break-it-node-selftest.sh" "$BIN/fleet-break-it-tenant-selftest.sh" "$BIN/fleet-break-it-hub-selftest.sh" "$BIN/fleet-break-it-peerlink-selftest.sh" "$BIN/fleet-break-it-thin-selftest.sh" "$BIN/fleet-break-it-thin-client-selftest.sh" "$BIN/fleet-break-it-entry-selftest.sh" "$BIN/fleet-break-it-ci-selftest.sh" "$BIN/fleet-break-it-core-selftest.sh" "$BIN/fleet-break-it-seats-selftest.sh" "$BIN/fleet-break-it-admin-selftest.sh" "$BIN/fleet-break-it-cluster-selftest.sh" "$BIN/fleet-break-it-sidefx-selftest.sh" | tr _ -)
IDS=''
NROWS=0
while IFS= read -r r; do
  [ -n "$r" ] || continue
  NROWS=$((NROWS + 1))
  case "$r" in
    '!'*) lintfail "a row is not 4 cells ending in \`<id>\` or 登记：<ticket>: ${r#!}" ;;
    '@'*) ;;
    # case, not `printf | grep -qx`: under pipefail the grep quitting on its first
    # match SIGPIPEs the printf of a long list, and the row reads as missing (#2510).
    *) case "
$DRILLS
" in *"
$r
"*) ;; *) lintfail "row \`$r\` has no drill_${r//-/_} in this script" ;; esac
       IDS="$IDS $r" ;;
  esac
done <<EOF
$ROWS
EOF
for d in $DRILLS; do
  case " $IDS " in *" $d "*) ;; *) lintfail "drill_${d//-/_} has no row in docs/dev/BREAK-IT.md" ;; esac
done
[ "$NROWS" -ge 8 ] || lintfail "the list has $NROWS rows (the issue asks for at least 8)"
# The convention is written down where the next person will read it.
grep -q 'BREAK-IT.md' "$ROOT/CLAUDE.md" 2>/dev/null || lintfail "CLAUDE.md does not name docs/dev/BREAK-IT.md"

# ======================================================= node: the sandbox }

# A tmux shim pins every tmux call (bare, -L <label>) to $BREAK_SOCK.
mkdir -p "$WORK/tbin" "$WORK/wbin" "$WORK/home"
cat > "$WORK/tbin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "\$BREAK_SOCK" "\$@"
EOF
cat > "$WORK/tbin/claude" <<EOF
#!/bin/sh
printf '%s|%s\n' "\$PWD" "\$*" >> "$WORK/claude-argv"
printf '────────\n❯ \n────────\n'; exec sleep 600
EOF
chmod +x "$WORK/tbin/tmux" "$WORK/tbin/claude"
for f in fleet-session-wrap.sh fleet_task_execution.py fleet_hub_common.py fleet_task_exit_submit.py fleet-session-page.py fleet-hook-personal.sh fleet_repo_authority.py fleet_notice.py; do ln -s "$BIN/$f" "$WORK/wbin/$f"; done
mkdir -p "$WORK/wconf/logs"   # the wrapped windows' own logs (T909), never the operator's
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/recycled"\n' "$WORK" > "$WORK/wbin/session-end-hook.sh"
cat > "$WORK/fake-agent" <<'EOF'
#!/bin/bash
# The agent: logs its argv, stamps its session id as the hooks do, waits for
# `go`, then leaves the way $CTL/mode says.
# $CTL/agent = codex: a Codex session whose id was never recorded (#1842 ④).
# $CTL/resume-fails: a resume dies at once, the way a lost conversation does.
printf '%s\n' "$*" >> "$CTL/argv"
printf '%s\n' "${FLEET_PERSONAL:-}" >> "$CTL/personal"
# $CTL/hook: a personal hook's command, run the way Claude Code runs it (through
# bin/fleet-hook-personal.sh) four times, each answer's exit code logged.
if [ -s "$CTL/hook" ]; then
  for _ in 1 2 3 4; do
    echo '{}' | sh "$(dirname "$0")/wbin/fleet-hook-personal.sh" PreToolUse -- "$(cat "$CTL/hook")" >/dev/null 2>&1
    echo $? >> "$CTL/hook-rc"
  done
fi
agent=$(cat "$CTL/agent" 2>/dev/null); [ -n "$agent" ] || agent=claude
case " $* " in *" --resume "*|*" resume "*)
  [ -e "$CTL/resume-fails" ] && { printf 'Error: No conversation found with session ID: SID-1\n' >&2; exit 1; } ;;
esac
[ "$agent" = claude ] && tmux set-option -w -t "$TMUX_PANE" @cc_session_id SID-1
tmux set-option -w -t "$TMUX_PANE" @cc_agent "$agent"
echo $$ > "$CTL/pid"
while [ ! -e "$CTL/go" ]; do
  # `z`: suspend the way Claude Code does on Ctrl+Z — tear the UI down, hook
  # SIGCONT to bring it back, then SIGTSTP to the whole process group.
  if [ -e "$CTL/z" ]; then rm -f "$CTL/z" "$CTL/cont"; trap ': > "$CTL/cont"' CONT; kill -TSTP 0; fi
  sleep 0.05
done
rm -f "$CTL/go"
# $CTL/error: the agent's last own word (OSC 7501, @agent_status) before it leaves —
# an API error (E101)
[ -s "$CTL/error" ] && tmux set-option -w -t "$TMUX_PANE" @agent_status "$(cat "$CTL/error")"
case "$(cat "$CTL/mode")" in rc0) exit 0 ;; rc1) exit 1 ;; rc130) exit 130 ;; kill) kill -9 $$ ;; esac
EOF
chmod +x "$WORK/wbin/session-end-hook.sh" "$WORK/fake-agent"

# The install --auto runs from: every bin/ file, fleet-up.sh a stub that builds
# the session the way the real one leaves it (fleet-up-selftest owns the real one);
# its --undo goes where the real one sends it (drill_fleet_down_confirm greps that).
mkdir -p "$WORK/inst/bin" "$WORK/econf/fleets/oc" "$WORK/emain"
for f in "$BIN"/* "$BIN"/.*.py; do [ -e "$f" ] && ln -s "$f" "$WORK/inst/bin/${f##*/}"; done
rm -f "$WORK/inst/bin/fleet-up.sh"
cat > "$WORK/inst/bin/fleet-up.sh" <<EOF
#!/bin/bash
[ "\${1:-}" = --undo ] && { shift; exec bash "$WORK/inst/bin/fleet-restore.sh" --undo "\$@"; }
tmux new-session -d -s oc -n home -c "$WORK/emain" 'exec sleep 600'
EOF
chmod +x "$WORK/inst/bin/fleet-up.sh"
for n in 1 2; do mkdir -p "$WORK/wt-$n"; done
: > "$WORK/econf/oc.conf"
fx_repo "$WORK/econf" "oc" acme/widgets FLEET_MAIN="$WORK/emain" FLEET_BASE_BRANCH="main"
write_map() {
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
    printf 'WIN\tissue-2\t%s\tsid-2\t2\tdone\t-\t-\n'    "$WORK/wt-2"
  } > "$WORK/econf/fleets/oc/restore.map"
}
# auto [VAR=val…] — one diskguard tick's pull-up, against the sandbox
auto() {
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf" FLEET_SKIP_GLOBAL_CONF=1 \
    BREAK_SOCK="$BREAK_SOCK" SHELL=/bin/sh FLEET_RESTORE_PROBE_SECS=2 FLEET_DISK_FLOOR_GB=0 \
    "$@" bash "$WORK/inst/bin/fleet-restore.sh" --auto >/dev/null 2>&1
}

nt() { "$REAL_TMUX" -S "$BREAK_SOCK" "$@"; }
o()  { nt display-message -p -t "$1" "#{$2}" 2>/dev/null; }

# wrapped <session> <win> <ctl> — a window running the wrapper as every spawner does
wrapped() {
  mkdir -p "$3"; : > "$3/argv"
  local cmd="env CTL='$3' FLEET_WRAP_LAUNCH='$WORK/fake-agent' FLEET_WRAP_FAST_FAIL=${WRAP_FAST:-0} FLEET_UI_LANG=zh ${WRAP_ENV:-}"
  cmd="$cmd FLEET_CONF_DIR='${PERS_CONF:-$WORK/wconf}'"
  cmd="$cmd '$WORK/wbin/fleet-session-wrap.sh' --agent claude ${WRAP_ARGS:-}'the seed'; exec sleep 600"
  if nt has-session -t "$1" 2>/dev/null; then nt new-window -d -t "$1:" -n "$2" "$cmd"
  else nt -f /dev/null new-session -d -s "$1" -n "$2" -x 100 -y 30 "$cmd"; fi
}

# exit_drill <mode> <rc> <page headline> — the agent leaves; the window stays on
# the recovery page; ↵ resumes the same conversation.
exit_drill() {
  BREAK_SOCK="$WORK/sock-x$1"; local c="$WORK/x$1" t0 page_s
  wrapped sx w "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 10 grep -q . "$c/argv" || { WHY="the agent never started"; return 1; }
  printf '%s' "$1" > "$c/mode"
  t0=$(now); : > "$c/go"
  until_ok 10 sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' capture-pane -p -t sx:w | grep -qF '⌘P 回列表'" \
    || { WHY="no recovery page — the window shows: $(nt capture-pane -p -t sx:w 2>/dev/null | grep . | tail -2 | tr '\n' ' ')"; return 1; }
  page_s=$(since "$t0")
  nt list-windows -t sx -F '#{window_name}' 2>/dev/null | grep -qx w || { WHY="the window closed"; return 1; }
  [ "$(o sx:w @claude_state)" = exited ] || { WHY="@claude_state is [$(o sx:w @claude_state)], not exited"; return 1; }
  [ "$(o sx:w @wrap_exit_rc)" = "$2" ] || { WHY="exit status [$(o sx:w @wrap_exit_rc)], want $2"; return 1; }
  nt capture-pane -p -t sx:w | grep -qF -- "$3" || { WHY="the page does not say [$3]"; return 1; }
  nt send-keys -t sx:w Enter
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="↵ relaunched nothing"; return 1; }
  [ "$(sed -n 2p "$c/argv")" = "--agent claude --resume SID-1" ] || { WHY="↵ ran [$(sed -n 2p "$c/argv")], not the same conversation"; return 1; }
  SECS=$(since "$t0"); WHAT="恢复页 ${page_s}s 出现，↵ 续上同一对话"
}

# session-exit — every way an agent leaves or stops, one table: /exit (rc 0), Ctrl+C
# (rc 130) and a kill (137) end on the recovery page (exit_drill, ≤5s each); Ctrl+Z
# (ctrl_z_leg) is resumed within 1s.
drill_transfer_target_runtime() {
  local started; started=$(now); CAP=12
  bash "$BIN/fleet-codex-runtime-selftest.sh" TargetPreflightTests >"$WORK/transfer-target-runtime.log" 2>&1 \
    || { cat "$WORK/transfer-target-runtime.log"; WHY='target initialize capability must be proven before source exit'; return 1; }
  SECS=$(since "$started"); WHAT='isolated target initialize rejects old/unknown/unreachable runtimes without threads; probe is reaped'
}

drill_broken_hook_maintenance() {
  local started; started=$(now); CAP=30
  python3 "$BIN/fleet-transfer-source-selftest.py" BrokenHookMaintenance >"$WORK/broken-hook-maintenance.log" 2>&1 \
    || { cat "$WORK/broken-hook-maintenance.log"; WHY="missing-hook maintenance identity/unknown-delivery guard failed"; return 1; }
  SECS=$(since "$started"); WHAT='same-SID maintenance proves missing hooks; paused original timer rejects unknown attempts'
}

drill_broken_hook_model_menu() {
  local started; started=$(now); CAP=10
  python3 "$BIN/fleet-transfer-source-selftest.py" BrokenHookMenu >"$WORK/broken-hook-model-menu.log" 2>&1 \
    || { cat "$WORK/broken-hook-model-menu.log"; WHY='maintenance must return from the exact model reminder once, retaining unknown input'; return 1; }
  SECS=$(since "$started"); WHAT='exact model reminder returns once; unknown input never exits or retries'
}

drill_session_exit() {
  CAP=5; local m rc head s=0 what=''
  while IFS='|' read -r m rc head; do
    exit_drill "$m" "$rc" "$head" || { WHY="$m: $WHY"; return 1; }
    s=$(python3 -c 'import sys; print(max(float(sys.argv[1]), float(sys.argv[2])))' "$s" "$SECS"); what="$what $m"
  done <<'EOF'
rc0|0|会话已结束
rc130|130|会话已结束
kill|137|会话意外退出
EOF
  ctrl_z_leg || { WHY="ctrl-z: $WHY"; return 1; }
  le "$SECS" 1 || { WHY="ctrl-z: SIGCONT came after ${SECS}s, over 1s"; return 1; }
  SECS=$s
  WHAT="/exit、Ctrl+C、被杀（$what ）：恢复页 ≤${s}s 出现、↵ 续上同一对话；$WHAT"
}

# Ctrl+Z (issue #1843). The pane's process group is orphaned (its leader, the
# pane's shell, is a session leader whose parent is the tmux server), so the
# kernel discards a SIGTSTP — nothing ever stops; but Claude Code / Codex suspend
# THEMSELVES on Ctrl+Z (UI torn down, a SIGCONT handler armed, `kill(0, SIGTSTP)`)
# and wait for a `fg` no shell will ever type. The drill does all three breaks: a
# Ctrl+Z on the pane's tty, a `kill -TSTP` aimed at the agent, and the agent's own
# suspend — within 1s it is running, resumed (its SIGCONT arrived), the window is
# not marked exited, and the guard left its stamp.
ctrl_z_leg() {
  BREAK_SOCK="$WORK/sock-xz"; local c="$WORK/xz" t0 pid st
  wrapped sz w "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 10 test -s "$c/pid" || { WHY="the agent never started"; return 1; }
  pid=$(cat "$c/pid")
  nt send-keys -t sz:w C-z; kill -TSTP "$pid" 2>/dev/null
  sleep 0.2
  t0=$(now); : > "$c/z"
  until_ok 1 test -e "$c/cont" \
    || { WHY="the agent suspended itself and nothing sent SIGCONT — it waits for an fg no shell will type"; return 1; }
  SECS=$(since "$t0")
  st=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$st" in ''|T*) WHY="the agent is [${st:-gone}] after Ctrl+Z, not running"; return 1 ;; esac
  [ "$(o sz:w @claude_state)" != exited ] || { WHY="the window went to exited"; return 1; }
  [ -n "$(o sz:w @wrap_ctrl_z)" ] || { WHY="the guard left no @wrap_ctrl_z stamp"; return 1; }
  WHAT="Ctrl+Z / kill -TSTP / 自挂起后 ${SECS}s 内收到 SIGCONT、照常运行"
}

# page_says <ctl-free text> — the recovery page on sx:w shows it
page_says() { "$REAL_TMUX" -S "$BREAK_SOCK" capture-pane -p -t sx:w 2>/dev/null | grep -qF -- "$1"; }

# A resume that dies within the fast-fail window (the conversation is gone, the
# login lapsed): the window stays on the page and says why (#1842 ③).
drill_resume_fails_fast() {
  CAP=6; BREAK_SOCK="$WORK/sock-rf"; local c="$WORK/rf" t0
  # The wrapper times a launch in whole epoch seconds: with a 1 s window the failed
  # resume had to start and end inside ONE wall-clock second, and a busy macOS
  # runner crossing the boundary read it as an ordinary exit (#2500). 3 s leaves
  # the fast fail ≥2 s of room; the first session runs past it (3.2 s).
  WRAP_FAST=3 wrapped sx w "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 10 grep -q . "$c/argv" || { WHY="the agent never started"; return 1; }
  sleep 3.2; printf rc0 > "$c/mode"; : > "$c/go"     # a real session: it ran past the window
  until_ok 10 page_says '⌘P 回列表' || { WHY="no recovery page after the first exit"; return 1; }
  : > "$c/resume-fails"
  t0=$(now); nt send-keys -t sx:w Enter
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="↵ relaunched nothing"; return 1; }
  until_ok 5 page_says '续上原对话失败' \
    || { WHY="no page after the failed resume — the window shows: $(nt capture-pane -p -t sx:w 2>/dev/null | grep . | tail -2 | tr '\n' ' ')"; return 1; }
  nt list-windows -t sx -F '#{window_name}' 2>/dev/null | grep -qx w || { WHY="the window closed"; return 1; }
  page_says '找不到这个对话' || { WHY="the page does not say why (找不到这个对话)"; return 1; }
  SECS=$(since "$t0"); WHAT="续对话 1 秒内失败，窗口留在恢复页写「找不到这个对话」"
}

# session-exited-transient (E101): an agent a temporary server error stopped (FQBW's
# 502 sat 16 h on its recovery page, put away in 已结束) — the page presses ↵ by
# itself once (FLEET_AUTO_RESUME_SECS), the same conversation in the same window;
# a second error waits for its person: no second retry, and never the 10-second
# auto-close a person's own /exit gets, even at rc 0.
drill_session_exited_transient() {
  CAP=10; BREAK_SOCK="$WORK/sock-et"; local c="$WORK/et" t0 at
  WRAP_ENV="FLEET_AUTO_RESUME_SECS=2 FLEET_EXIT_CLOSE_SECS=2" wrapped sx w "$c" \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 10 grep -q . "$c/argv" || { WHY="the agent never started"; return 1; }
  printf '{"state":"error","msg":"API Error: 502 cred-proxy: upstream direct unreachable"}' > "$c/error"
  t0=$(now); printf rc1 > "$c/mode"; : > "$c/go"
  until_ok 10 page_says '秒后' \
    || { WHY="no retry countdown — the window shows: $(nt capture-pane -p -t sx:w 2>/dev/null | grep . | tail -2 | tr '\n' ' ')"; return 1; }
  at=$(o sx:w @auto_resume_at)
  case "$at" in ''|*[!0-9]*) WHY="no @auto_resume_at for the reaper's 「N 分钟后自动重试」"; return 1 ;; esac
  until_ok 8 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="the page never retried by itself"; return 1; }
  SECS=$(since "$t0")
  [ "$(sed -n 2p "$c/argv")" = "--agent claude --resume SID-1" ] || { WHY="the retry ran [$(sed -n 2p "$c/argv")], not the same conversation"; return 1; }
  until_ok 5 sh -c "[ \"\$('$REAL_TMUX' -S '$BREAK_SOCK' display-message -p -t sx:w '#{@auto_resumed}')\" = 1 ]" \
    || { WHY="the retry was not marked spent (@auto_resumed)"; return 1; }
  printf rc0 > "$c/mode"; : > "$c/go"                 # the same error again, rc 0 this time
  until_ok 10 page_says '⌘P 回列表' || { WHY="no recovery page after the second error"; return 1; }
  sleep 3.5                                          # past both the retry's and the close's 2 s
  [ "$(grep -c . "$c/argv")" = 2 ] || { WHY="a second error retried again — one retry a window"; return 1; }
  nt list-windows -t sx -F '#{window_name}' 2>/dev/null | grep -qx w || { WHY="the error exit closed its window by the /exit countdown"; return 1; }
  page_says '秒后' && { WHY="the second page still counts down (a retry, or the /exit close)"; return 1; }
  [ -z "$(o sx:w @auto_resume_at)" ] || { WHY="@auto_resume_at left set after the retry was spent"; return 1; }
  WHAT="服务端临时出错退出：恢复页 ${SECS}s 内自动续上同一对话一次；再出错不再重试、不自动关窗，等人看"
}

drill_codex_private_group_orphan() {
  CAP=35
  local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-codex-runtime-selftest.sh" GuardianGroupTests 2>&1) \
    || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT="私有 app-server 先退出、监督管道 EOF 或 guardian 收 TERM：仍清理忽略 TERM 的同组后代；preflight 继承调用者组也不伤兄弟，仅保证 Runtime 自建私有组"
}

# A Codex session with no recorded id: ↵ must never `resume --last` — in a shared
# Codex home that is somebody else's conversation (#1842 ④). The window's own
# thread (@codex_thread_id) is resumed; with none, a new conversation.
drill_codex_no_id() {
  CAP=8; BREAK_SOCK="$WORK/sock-cx"; local c="$WORK/cx" t0
  mkdir -p "$c"; printf codex > "$c/agent"
  wrapped sx w "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 10 grep -q . "$c/argv" || { WHY="the agent never started"; return 1; }
  t0=$(now); printf rc0 > "$c/mode"; : > "$c/go"
  until_ok 10 page_says '⌘P 回列表' || { WHY="no recovery page"; return 1; }
  page_says '↵ 新开对话' || { WHY="the page does not say ↵ starts a new conversation"; return 1; }
  nt send-keys -t sx:w Enter
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="↵ relaunched nothing"; return 1; }
  [ "$(sed -n 2p "$c/argv")" = "--agent codex" ] || { WHY="no id, no thread: ↵ ran [$(sed -n 2p "$c/argv")], not a new conversation"; return 1; }
  nt set-option -w -t sx:w @codex_thread_id T-9
  printf rc0 > "$c/mode"; : > "$c/go"
  until_ok 10 page_says '⌘P 回列表' || { WHY="no recovery page the second time"; return 1; }
  nt send-keys -t sx:w Enter
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 3 ]" || { WHY="↵ relaunched nothing the second time"; return 1; }
  [ "$(sed -n 3p "$c/argv")" = "--agent codex resume T-9" ] || { WHY="with the window's thread: ↵ ran [$(sed -n 3p "$c/argv")], not resume T-9"; return 1; }
  grep -q -- '--last' "$c/argv" && { WHY="a relaunch ran resume --last"; return 1; }
  SECS=$(since "$t0"); WHAT="无 id：↵ 新开；有本窗口 thread：续它；从不 resume --last"
}

# A fresh fleet Codex whose login's config.toml already carries the fleet's posture
# (the shipped conf/agent-defaults/codex/config.default.toml) must launch with NO
# session permission override: Codex refuses every in-TUI /resume on the private
# remote runtime while one is set («Permission overrides are not supported when
# resuming a remote task», #4724). A fake codex records the argv the real one gets.
drill_codex_resume_override() {
  CAP=15; local d="$WORK/cxpost" t0 a
  mkdir -p "$d/bin" "$d/home" "$d/cwd" "$d/conf"
  printf '#!/bin/sh\nfor a; do printf "%%s\\n" "$a"; done > "%s/argv"\n' "$d" > "$d/bin/codex"; chmod +x "$d/bin/codex"
  cp "$ROOT/conf/agent-defaults/codex/config.default.toml" "$d/home/config.toml"
  t0=$(now)
  ( cd "$d/cwd" && env -i PATH="$d/bin:$PATH" HOME="$d" CODEX_HOME="$d/home" FLEET_CONF_DIR="$d/conf" \
      FLEET_MCP=0 FLEET_AGENT_CFG=0 FLEET_CODEX_VERSION_CHECK=0 bash "$BIN/fleet-codex.sh" hi ) >"$d/out" 2>&1
  [ -s "$d/argv" ] || { WHY="codex never ran: $(tail -n 2 "$d/out" | tr '\n' ' ')"; return 1; }
  for a in --dangerously-bypass-approvals-and-sandbox --yolo -a -s --ask-for-approval --sandbox; do
    grep -qxF -- "$a" "$d/argv" && { WHY="a fresh launch carries the session override $a — /resume is refused"; return 1; }
  done
  grep -Eq '^(approval_policy|sandbox_mode)=' "$d/argv" && { WHY="a fresh launch carries a -c permission override — /resume is refused"; return 1; }
  grep -qxF -- --dangerously-bypass-hook-trust "$d/argv" || { WHY="the hook-trust bypass went missing"; return 1; }
  SECS=$(since "$t0"); WHAT="默认 config.toml 已给满权限：新开 Codex 不带会话权限覆盖，会话里的 /resume 可用"
}

# ---- the recovery page's q, on the real session-end-hook (#1842 ① ②) ----------
# A real git repo with an issue worktree, a fake gh (one merged PR, with its head
# sha) and a fake tmux that runs run-shell inline — session-end-hook-selftest's rig.
seh_rig() {
  local R="$WORK/seh"; [ -d "$R" ] && return 0
  mkdir -p "$R/fp" "$R/conf" "$R/proj"
  git init -q "$R/main"; git -C "$R/main" config user.email t@t; git -C "$R/main" config user.name t
  printf 'seed\n' > "$R/main/f"; git -C "$R/main" add f; git -C "$R/main" commit -qm seed
  git -C "$R/main" branch -M main
  fx_repo "$R/conf" s1 acme/widgets FLEET_MAIN="$R/main" FLEET_BASE_BRANCH=main
  cat > "$R/fp/tmux" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = run-shell ]; then shift; [ "${1:-}" = -b ] && shift; sh -c "$1"; exit 0; fi
case "$*" in
  *@migrating*) printf '%s\n' "${MIG:-}" ;;
  *@issue*) printf '%s\n' "${ISS:-}" ;;
  *window_id*) printf '@9\n' ;;
  *session_name*) printf 's1\n' ;;
  *kill-window*) printf 'KILL\n' >> "$SEHLOG" ;;
esac
exit 0
FAKE
  cat > "$R/fp/gh" <<'FAKE'
#!/bin/bash
head=""; prev=""; for a in "$@"; do [ "$prev" = --head ] && head="$a"; prev="$a"; done
case "$*" in
  *"pr list"*headRefOid*) [ "$head" = "${GH_MERGED_HEAD:-}" ] && printf '%s\t%s\n' "$head" "$GH_MERGED_OID" ;;
  *"pr list"*headRefName*) [ "$head" = "${GH_MERGED_HEAD:-}" ] && printf '%s\n' "$head" ;;
  *"issue view"*) printf 'OPEN\n' ;;
  *issue*) printf 'GH %s\n' "$*" >> "$SEHLOG" ;;
esac
exit 0
FAKE
  chmod +x "$R/fp/tmux" "$R/fp/gh"
}
# seh_q <issue> [VAR=val…] — press q on issue-<N>'s recovery page
seh_q() {
  local R="$WORK/seh" n="$1"; shift
  env "$@" ISS="$n" SEHLOG="$R/log" PATH="$R/fp:$PATH" HOME="$WORK/home" \
    FLEET_REPO=acme/widgets FLEET_MAIN="$R/main" FLEET_BASE_BRANCH=main \
    FLEET_CONF_DIR="$R/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$R" \
    FLEET_HISTORY_LEDGER="$R/ledger" CLAUDE_PROJECTS_DIR="$R/proj" TMUX=fake TMUX_PANE=%1 \
    bash "$BIN/session-end-hook.sh" --recycle >/dev/null 2>&1
}

# seh_exit <issue> [VAR=val…] — the agent in issue-<N>'s window exits (/exit)
seh_exit() {
  local R="$WORK/seh" n="$1"; shift
  env "$@" ISS="$n" SEHLOG="$R/log" PATH="$R/fp:$PATH" HOME="$WORK/home" \
    FLEET_REPO=acme/widgets FLEET_MAIN="$R/main" FLEET_BASE_BRANCH=main \
    FLEET_CONF_DIR="$R/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$R" \
    FLEET_HISTORY_LEDGER="$R/ledger" CLAUDE_PROJECTS_DIR="$R/proj" TMUX=fake TMUX_PANE=%1 \
    FLEET_SESSION_END_REASON=prompt_input_exit \
    bash "$BIN/session-end-hook.sh" >/dev/null 2>&1
}
# seh_fresh <issue> — a zero-commit issue-<N> worktree, then the base moves on:
# its tip is a STRICT ancestor of the base, the shape the reap reads as landed.
seh_fresh() {
  local R="$WORK/seh" wt="$WORK/seh/wt-$1"
  git -C "$R/main" worktree add -q -b "issue-$1" "$wt" main >/dev/null 2>&1
  printf '%s\n' "$1" > "$R/main/base-$1"; git -C "$R/main" add "base-$1"
  git -C "$R/main" commit -qm "base moves past issue-$1"
}
# seh_kept <issue> — the worktree and branch survived, the window went
seh_kept() {
  local R="$WORK/seh" wt="$WORK/seh/wt-$1"
  [ -d "$wt" ] && git -C "$wt" rev-parse -q --verify HEAD >/dev/null \
    || { WHY="the exit removed worktree $wt — the session wakes in a deleted cwd"; return 1; }
  git -C "$R/main" rev-parse -q --verify "refs/heads/issue-$1" >/dev/null \
    || { WHY="the exit deleted branch issue-$1"; return 1; }
  grep -q KILL "$R/log" || { WHY="the old window was not closed (migrate waits for it)"; return 1; }
}

# A ver-stale / cfg-stale reopen /exits a clean, zero-commit worker: the
# SessionEnd reap read it `ancestor` and removed worktree + branch, 5 s before
# the same session resumed in that cwd (#2321, issue-2235 on 2026-10-08).
drill_ver_reopen_deletes_worktree() {
  CAP=10; seh_rig; local R="$WORK/seh" t0
  seh_fresh 11
  : > "$R/log"; t0=$(now)
  seh_exit 11 MIG=ver-stale
  SECS=$(since "$t0")
  seh_kept 11 || return 1
  # the mover's half: fleet-migrate.sh stamps the marker before it types /exit
  awk '/@migrating "\$\{CFG_REASON/{m=NR} /SK -t "\$wid" -l .\/exit/{if(!x)x=NR} END{exit !(m && x && m<x)}' "$BIN/fleet-migrate.sh" \
    || { WHY="fleet-migrate.sh does not stamp @migrating before its /exit"; return 1; }
  WHAT="版本过期重开的 /exit（@migrating ver-stale）：worktree 与分支 issue-11 都在，旧窗口照常关"
}

# Mid-migrate, a mover that stamps no @migrating (or a marker lost with its
# window) — only its rotate lease says the gap is deliberate (#550): the exit
# reap ignored the lease and removed the worktree (#2321).
drill_migrate_exit_reaps() {
  CAP=10; seh_rig; local R="$WORK/seh" wt="$WORK/seh/wt-12" t0
  seh_fresh 12
  FLEET_CONF_DIR="$R/conf" bash -c '. "$1/fleet-lib.sh"; fleet_rotate_lease_take "$2" "migrate drill"' _ "$BIN" "$wt"
  : > "$R/log"; t0=$(now)
  seh_exit 12
  SECS=$(since "$t0")
  seh_kept 12 || return 1
  WHAT="迁移途中的 /exit（只有 rotate 租约、没有标记）：worktree 与分支 issue-12 都在"
}

# Merged, then one more commit, then q: the branch and the commit stay (#1842 ①).
drill_merged_then_commit() {
  CAP=10; seh_rig; local R="$WORK/seh" wt="$WORK/seh/wt-7" t0 pr_head n
  git -C "$R/main" worktree add -q -b issue-7 "$wt" >/dev/null 2>&1
  printf 'a\n' > "$wt/a"; git -C "$wt" add a; git -C "$wt" commit -qm 'the PR'
  pr_head=$(git -C "$wt" rev-parse HEAD)
  printf 'b\n' > "$wt/b"; git -C "$wt" add b; git -C "$wt" commit -qm 'after the merge'   # the break
  : > "$R/log"; t0=$(now)
  seh_q 7 GH_MERGED_HEAD=issue-7 GH_MERGED_OID="$pr_head"
  SECS=$(since "$t0")
  git -C "$R/main" rev-parse -q --verify refs/heads/issue-7 >/dev/null || { WHY="q deleted branch issue-7 and the commit made after the merge"; return 1; }
  [ -d "$wt" ] || { WHY="q removed the worktree"; return 1; }
  n=$(git -C "$R/main" rev-list --count main..issue-7)
  [ "$n" = 2 ] || { WHY="branch issue-7 holds $n commits, want 2"; return 1; }
  grep -q 'issue close' "$R/log" && { WHY="q closed the issue as landed"; return 1; }
  WHAT="合并后再提交再按 q：分支 issue-7 仍在，$n 个提交（1 个在合并之后）"
}

# home_back <old pid> — home holds a live shell other than <old pid>
home_back() {
  local p; p=$(nt display-message -p -t lw:home '#{pane_pid} #{pane_dead}' 2>/dev/null)
  [ -n "$p" ] && [ "${p% *}" != "$1" ] && [ "${p#* }" = 0 ]
}
# tmux ≤ 3.4 on a busy box can miss the exited shell's SIGCHLD: the pane reads
# dead, the shell stays a zombie, pane-died never fires (issue #1801; 3.5a/3.6a
# never did in 80 loaded runs). There the diskguard tick's fleet_home_heal is the
# rail; from 3.5 on the hook alone must bring it back.
tmux_lost_sigchld() {
  local v; v=$("$REAL_TMUX" -V 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1 \2/')
  set -- $v
  [ -n "${2:-}" ] && { [ "$1" -lt 3 ] || { [ "$1" -eq 3 ] && [ "$2" -le 4 ]; }; }
}
drill_last_window() {
  CAP=5; BREAK_SOCK="$WORK/sock-lw"; local t0 hpid healed=''
  grep -q '^fleet_server_resident ' "$BIN/fleet-up.sh" || { WHY="fleet-up.sh no longer calls fleet_server_resident"; return 1; }
  sed -n '/^  --watch)/,/;;/p' "$BIN/fleet-diskguard.sh" | grep -q '^ *home_watch ' \
    || { WHY="the diskguard tick no longer runs home_watch (fleet_home_heal)"; return 1; }
  nt -f /dev/null new-session -d -s lw -n home -x 100 -y 30 'exec sh' || { WHY="cannot start the isolated tmux server"; return 1; }
  nt new-window -d -t lw: -n issue-9 'exec sleep 600'
  ( PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/lconf"; export PATH HOME FLEET_CONF_DIR BREAK_SOCK
    . "$BIN/fleet-lib.sh"; fleet_server_resident lw lw )
  t0=$(now)
  nt kill-window -t lw:issue-9                    # the last task ends …
  hpid=$(o lw:home pane_pid)
  nt send-keys -t lw:home 'exit' Enter            # … and home's shell exits
  if ! until_ok 5 home_back "$hpid"; then
    tmux_lost_sigchld || { WHY="home did not come back with a live shell ($("$REAL_TMUX" -V); pane: $(nt display-message -p -t lw:home 'pid=#{pane_pid} dead=#{pane_dead} status=#{pane_dead_status}' 2>&1))"; return 1; }
    # the missed SIGCHLD: one diskguard tick's home_watch, timed from the tick
    t0=$(now)
    healed=$( PATH="$WORK/tbin:$PATH" BREAK_SOCK="$BREAK_SOCK" FLEET_CONF_DIR="$WORK/lconf"; export PATH BREAK_SOCK FLEET_CONF_DIR
              . "$BIN/fleet-lib.sh"; fleet_home_heal lw lw )
    until_ok 5 home_back "$hpid" \
      || { WHY="home stayed dead, and the tick's fleet_home_heal did not respawn it [${healed}] (pane: $(nt display-message -p -t lw:home 'pid=#{pane_pid} dead=#{pane_dead}' 2>&1))"; return 1; }
  fi
  SECS=$(since "$t0")
  nt kill-session -t lw                           # and even no session at all …
  nt show-options -sv exit-empty >/dev/null 2>&1 || { WHY="the server died with its last session"; return 1; }
  WHAT="home 重开 shell，没有会话时服务器也还在${healed:+（tmux 漏了 SIGCHLD，节拍补救；节拍 60s 另计）}"
}

drill_kill_server() {
  CAP=20; BREAK_SOCK="$WORK/sock-oc"; local t0 wins
  sed -n '/^restore_watch()/,/^}/p' "$BIN/fleet-diskguard.sh" | grep -q 'fleet-restore.sh.*--auto' \
    || { WHY="the diskguard tick's restore_watch no longer runs fleet-restore.sh --auto"; return 1; }
  write_map; rm -f "$WORK/claude-argv"
  auto; nt has-session -t oc 2>/dev/null || { WHY="the sandbox fleet never came up"; return 1; }
  write_map
  nt kill-server                                  # the break
  rm -f "$WORK/claude-argv"
  t0=$(now)
  auto                                            # one diskguard tick
  until_ok "$CAP" nt has-session -t oc 2>/dev/null || { WHY="--auto did not bring it back: $(tail -3 "$WORK/econf/restore/restore.log" 2>/dev/null | tr '\n' ' ')"; return 1; }
  wins=$(nt list-windows -t oc -F '#{window_name}' | sort | tr '\n' ' ')
  [ "$wins" = "home issue-1 " ] || { WHY="came back with [$wins], want the unfinished one only"; return 1; }
  until_ok "$CAP" grep -q -- '--resume sid-1' "$WORK/claude-argv" 2>/dev/null || { WHY="issue-1 did not resume its conversation"; return 1; }
  SECS=$(since "$t0"); WHAT="下一拍拉起，只回来没做完的 issue-1（节拍 60s 另计）"
}

drill_disk_full() {
  CAP=20; BREAK_SOCK="$WORK/sock-oc"; local t0
  nt kill-server 2>/dev/null; write_map
  auto FLEET_DISK_FLOOR_GB=999999                 # the disk is "full"
  nt has-session -t oc 2>/dev/null && { WHY="--auto restored onto a full disk"; return 1; }
  grep -q 'held: disk below floor' "$WORK/econf/restore/restore.log" 2>/dev/null || { WHY="the hold left no log line"; return 1; }
  write_map
  t0=$(now)
  auto                                            # space freed: the next tick
  until_ok "$CAP" nt has-session -t oc 2>/dev/null || { WHY="space freed, still not restored"; return 1; }
  SECS=$(since "$t0"); WHAT="盘满时只记 held 不拉起，腾出空间后下一拍拉起"
}

# agent-file-broken (issue #3122, EPIC #3111 C11): a custom session is a standard
# agent file (`--as <name>` → `claude --agent <name>`). One written badly (a
# frontmatter that cannot be read) or not there would open a session that is not
# what was asked for — Claude Code silently falling back to its default, or a
# worker with no instructions. The spawn refuses instead, BEFORE any window, and
# names the file (or where it looked); the shipped default (fleet-worker) gone is
# not an error — a plain session given the ticket.
drill_agent_file_broken() {
  CAP=15; local d="$WORK/af" lbl="brkaf-$$" t0 rc wins
  mkdir -p "$d/o.git" "$d/main" "$d/conf" "$d/tmp" "$d/fb" "$d/home/.claude/agents"
  fx_repo "$d/conf" "$lbl" acme/w FLEET_MAIN="$d/main" FLEET_BASE_BRANCH=master
  git init -q --bare "$d/o.git"
  ( cd "$d/main" && git init -q -b master . && git config user.email t@t && git config user.name t \
      && printf 'x\n' > CLAUDE.md && git add -A && git commit -qm i && git remote add origin "$d/o.git" \
      && git push -q origin master ) || { WHY="cannot build the repo"; return 1; }
  printf '#!/bin/sh\nexit 0\n' > "$d/fb/gh"; printf '#!/bin/sh\nexec sleep 60\n' > "$d/fb/agent"; chmod +x "$d/fb/gh" "$d/fb/agent"
  printf -- '---\nname: doc-only\nthis line is no field\n---\n只改文档。\n' > "$d/home/.claude/agents/doc-only.md"   # the break
  env PATH="$d/fb:$PATH" FLEET_WRAP_LAUNCH="$d/fb/agent" "$REAL_TMUX" -L "$lbl" -f /dev/null new-session -d -s "$lbl" -n home \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  sp() { env -u TMUX -u TMUX_PANE -u CCQUOTA_FLEET -u CLAUDE_CONFIG_DIR PATH="$d/fb:$PATH" HOME="$d/home" FLEET_CONF_DIR="$d/conf" \
           TMPDIR="$d/tmp" FLEET_AGENT_PLUGINS_CMD='echo []' FLEET_WRAP_LAUNCH="$d/fb/agent" \
           FLEET_ORIGIN_GATE=0 FLEET_REPO=acme/w FLEET_MAIN="$d/main" FLEET_BASE_BRANCH=master \
           FLEET_WORKTREE_ROOT="$d/wt" bash "$BIN/dash-issue-session.sh" "$@" "$lbl" --title t --origin hub --print; }
  t0=$(now)
  sp 5 --as doc-only > "$d/out" 2> "$d/err"; rc=$?
  SECS=$(since "$t0")
  sp 6 --as nobody-here > "$d/out2" 2> "$d/err2"; rc2=$?
  sp 7 > "$d/out3" 2> "$d/err3"; rc3=$?   # no --as, no fleet-worker shipped: a plain session
  wins=$("$REAL_TMUX" -L "$lbl" list-windows -t "$lbl" -F '#{@issue}:#{@agent_def}' 2>/dev/null)
  "$REAL_TMUX" -L "$lbl" kill-server >/dev/null 2>&1
  [ "$rc" = 1 ] || { WHY="a broken agent file: the spawn exited $rc, want 1"; return 1; }
  grep -q "$d/home/.claude/agents/doc-only.md" "$d/err" || { WHY="the refusal does not name the file: $(tr '\n' '|' < "$d/err")"; return 1; }
  [ "$rc2" = 1 ] && grep -q "no agent file 'nobody-here'" "$d/err2" && grep -q "$d/home/.claude/agents" "$d/err2" \
    || { WHY="a missing agent file: exit $rc2, $(tr '\n' '|' < "$d/err2")"; return 1; }
  case " $(printf '%s ' $wins)" in *" 5:"*|*" 6:"*) WHY="a refused spawn left a window: $wins"; return 1 ;; esac
  [ "$rc3" = 0 ] || { WHY="with no --as and no fleet-worker the spawn failed ($rc3): $(tr '\n' '|' < "$d/err3")"; return 1; }
  case " $(printf '%s ' $wins)" in *" 7: "*) ;; *) WHY="the plain spawn is not a plain session: [$wins]"; return 1 ;; esac
  WHAT="agent 文件写坏或不在：派单 exit 1、不开窗口，stderr 说是哪个文件（或在哪几处找过）；没有 --as、自带的 fleet-worker 也删了：照常开一个普通会话"
}

# window-renamed (issue #1844): a name is not an identity. Home renamed, a worker
# renamed `home`, a restored session renamed — every automatic reader still finds
# the right window, because it reads @fleet_role / @fleet_id, not the name.
# rlib <fn> <args…> — one fleet-lib call against this drill's sandbox server
rlib() {
  ( PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/rconf"; export PATH HOME FLEET_CONF_DIR BREAK_SOCK
    . "$BIN/fleet-lib.sh"; "$@" )
}
drill_window_renamed() {
  CAP=20; BREAK_SOCK="$WORK/sock-rn"; local t0 hw ww hpid wpid n wins
  for f in dash-issue-session.sh dash-raw-session.sh; do
    grep -q 'fleet_win_role_stamp .*worker' "$BIN/$f" || { WHY="$f no longer stamps its window @fleet_role worker"; return 1; }
  done
  nt -f /dev/null new-session -d -s rn -n home -x 100 -y 30 'exec sh' || { WHY="cannot start the isolated tmux server"; return 1; }
  ww=$(nt new-window -d -P -F '#{window_id}' -t rn: -n issue-3 'exec sleep 600')
  hw=$(o rn:home window_id)
  rlib fleet_server_resident rn rn                # as fleet-up leaves home
  rlib fleet_win_role_stamp "$ww" worker rn       # as a spawner leaves its window
  t0=$(now)
  nt rename-window -t "$hw" 'my shell'            # the break: home renamed …
  n=$(rlib fleet_session_count_for rn)
  [ "$n" = 1 ] || { WHY="with home renamed, the fleet counts $n sessions, want 1: it is no longer known as a fleet"; return 1; }
  nt rename-window -t "$ww" home                  # … and the worker named `home`
  n=$(rlib fleet_session_count_for rn)
  [ "$n" = 1 ] || { WHY="with the worker named home, the fleet counts $n sessions, want 1"; return 1; }
  # home's shell exits and tmux misses the SIGCHLD (#1801): the tick's heal
  nt set-hook -uw -t "$hw" pane-died
  hpid=$(o "$hw" pane_pid); wpid=$(o "$ww" pane_pid)
  nt send-keys -t "$hw" 'exit' Enter
  until_ok 5 sh -c "[ \"\$('$REAL_TMUX' -S '$BREAK_SOCK' display-message -p -t '$hw' '#{pane_dead}')\" = 1 ]" || { WHY="home's shell did not exit"; return 1; }
  rlib fleet_home_heal rn rn >/dev/null
  until_ok 5 sh -c "p=\$('$REAL_TMUX' -S '$BREAK_SOCK' display-message -p -t '$hw' '#{pane_pid} #{pane_dead}'); [ \"\${p% *}\" != '$hpid' ] && [ \"\${p#* }\" = 0 ]" \
    || { WHY="the renamed home stayed dead: the tick's fleet_home_heal looked for it by name"; return 1; }
  [ "$(o "$ww" pane_pid)" = "$wpid" ] || { WHY="the heal respawned the worker that wears the name home"; return 1; }
  # a restored session renamed: the next tick must not open a second one
  write_fid_map() {
    { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
      printf 'FID\t1f0e0000-0000-4000-8000-000000000001\n'
      printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
    } > "$WORK/econf/fleets/oc/restore.map"
  }
  BREAK_SOCK="$WORK/sock-rr"
  write_fid_map; auto
  until_ok 10 sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t oc -F '#{window_name}' 2>/dev/null | grep -qx issue-1" \
    || { WHY="the sandbox fleet never restored issue-1"; return 1; }
  nt rename-window -t oc:issue-1 'my task'
  write_fid_map                                   # a reconcile run on the live fleet
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf" FLEET_SKIP_GLOBAL_CONF=1 \
    BREAK_SOCK="$BREAK_SOCK" SHELL=/bin/sh FLEET_RESTORE_PROBE_SECS=2 FLEET_DISK_FLOOR_GB=0 \
    bash "$WORK/inst/bin/fleet-restore.sh" >/dev/null 2>&1
  wins=$(nt list-windows -t oc -F '#{window_name}' | sort | tr '\n' ' ')
  [ "$wins" = "home my task " ] || { WHY="after renaming issue-1 a reconcile left [$wins], want [home my task ] (no duplicate)"; return 1; }
  SECS=$(since "$t0"); WHAT="home 改名照样自愈、计数照旧、改名的会话不被重开"
}

# break-pane (issue #1844): the agent pane broken out with prefix ! takes the
# session's identity with it, so its recovery page still resumes the conversation.
drill_break_pane() {
  CAP=10; BREAK_SOCK="$WORK/sock-bp"; local c="$WORK/bp" t0 hook ap ow nw v
  hook=$(grep 'fleet-window-carry.sh' "$ROOT/conf/tmux-attention.conf" | grep '^set-hook' | sed "s#~/.claude/fleet/bin/#$BIN/#")
  [ -n "$hook" ] || { WHY="conf/tmux-attention.conf has no hook carrying a broken-out pane's identity"; return 1; }
  wrapped sb issue-5 "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  printf '%s\n' "$hook" > "$WORK/bp-hook.conf"
  nt source-file "$WORK/bp-hook.conf" || { WHY="the conf's hook line does not parse"; return 1; }
  ow=$(o sb:issue-5 window_id)
  nt set-option -w -t "$ow" @issue 5; nt set-option -w -t "$ow" @fleet_id 1f0e0000-0000-4000-8000-000000000005
  nt set-option -w -t "$ow" @fleet_role worker
  until_ok 10 grep -q . "$c/argv" || { WHY="the agent never started"; return 1; }
  until_ok 5 sh -c "[ -n \"\$('$REAL_TMUX' -S '$BREAK_SOCK' show-options -wqv -t '$ow' @cc_session_id)\" ]" || { WHY="the agent never stamped its id"; return 1; }
  ap=$(o "$ow" pane_id)
  nt split-window -d -t "$ow" 'exec sleep 600'
  t0=$(now)
  nt break-pane -d -s "$ap"                       # the break: prefix !
  wopt() { "$REAL_TMUX" -S "$BREAK_SOCK" show-options -wqv -t "$1" "$2" 2>/dev/null; }
  until_ok "$CAP" sh -c "[ \"\$('$REAL_TMUX' -S '$BREAK_SOCK' show-options -wqv -t '$ap' @issue)\" = 5 ]" \
    || { WHY="the broken-out window has no @issue: the identity stayed behind"; return 1; }
  SECS=$(since "$t0")
  nw=$(o "$ap" window_id)
  [ "$nw" != "$ow" ] || { WHY="break-pane did not make a new window"; return 1; }
  for v in "@fleet_id 1f0e0000-0000-4000-8000-000000000005" "@cc_session_id SID-1" "@fleet_role worker"; do
    [ "$(wopt "$nw" "${v%% *}")" = "${v#* }" ] || { WHY="the new window's ${v%% *} is [$(wopt "$nw" "${v%% *}")], want ${v#* }"; return 1; }
  done
  [ "$(o "$nw" window_name)" = issue-5 ] || { WHY="the new window is named [$(o "$nw" window_name)], not issue-5"; return 1; }
  [ -z "$(wopt "$ow" @fleet_id)$(wopt "$ow" @issue)" ] || { WHY="the old window still carries the identity: two windows answer to it"; return 1; }
  [ "$(wopt "$ow" @fleet_role)" = panel ] || { WHY="the left-behind window is [$(wopt "$ow" @fleet_role)], not a panel"; return 1; }
  printf rc0 > "$c/mode"; : > "$c/go"             # the agent then exits …
  until_ok 10 sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' capture-pane -p -t '$ap' | grep -qF '⌘P 回列表'" || { WHY="no recovery page in the new window"; return 1; }
  nt send-keys -t "$ap" Enter                     # … and ↵ resumes it
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="↵ relaunched nothing"; return 1; }
  [ "$(sed -n 2p "$c/argv")" = "--agent claude --resume SID-1" ] || { WHY="↵ ran [$(sed -n 2p "$c/argv")], not the same conversation"; return 1; }
  WHAT="拆出的窗口带着 @issue / @fleet_id / 对话 id 和名字，恢复页 ↵ 续上同一对话"
}

# wedged-socket (issue #1729): the server is told to exit while one client never
# answers (an attach from a frozen ssh); it lives on, dropping every new client, so
# every tmux call on the label says `server exited unexpectedly`. -L <label> under
# a sandbox TMUX_TMPDIR, so fleet_socket_path resolves to this drill's socket.
drill_wedged_socket() {
  CAP=20; local tt="$WORK/tt" t0 out
  mkdir -p "$tt/tmux-$(id -u)"; chmod 700 "$tt/tmux-$(id -u)"
  BREAK_SOCK="$tt/tmux-$(id -u)/oc"
  write_map
  auto TMUX_TMPDIR="$tt"; nt has-session -t oc 2>/dev/null || { WHY="the sandbox fleet never came up"; return 1; }
  python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(120)' "$BREAK_SOCK" &
  local pin=$!
  sleep 0.3
  write_map
  nt kill-server                                  # the break: told to exit, pinned alive
  sleep 0.3
  out=$(nt list-sessions 2>&1)
  case "$out" in *'server exited unexpectedly'*) ;; *) kill "$pin" 2>/dev/null; WHY="the break did not wedge the socket: [$out]"; return 1 ;; esac
  rm -f "$WORK/claude-argv"
  t0=$(now)
  auto TMUX_TMPDIR="$tt"                          # one diskguard tick
  until_ok "$CAP" nt has-session -t oc 2>/dev/null \
    || { kill "$pin" 2>/dev/null; WHY="--auto did not bring it back: $(tail -3 "$WORK/econf/restore/restore.log" 2>/dev/null | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  kill "$pin" 2>/dev/null
  grep -q 'cleared stale socket' "$WORK/econf/restore/restore.log" 2>/dev/null || { WHY="the clear left no restore.log line"; return 1; }
  grep -q "	oc	fleet: cleared stale socket" "$WORK/econf/socket-heal.log" 2>/dev/null || { WHY="no socket-heal.log row for the doctor"; return 1; }
  WHAT="下一拍清掉陈旧 socket 并拉起，restore.log 和 socket-heal.log 都记了一行"
}

drill_no_claude_on_path() {
  CAP=5; local t0 out
  mkdir -p "$WORK/phome/.local/bin"
  printf '#!/bin/sh\necho "found-claude $*"\n' > "$WORK/phome/.local/bin/claude"; chmod +x "$WORK/phome/.local/bin/claude"
  t0=$(now)
  out=$(env -i HOME="$WORK/phome" PATH=/usr/bin:/bin FLEET_CONF_DIR="$WORK/pconf" FLEET_MOD=0 FLEET_AGENT_CFG=0 \
        bash "$BIN/fleet-claude.sh" --version 2>&1)
  case "$out" in "found-claude "*"--version") ;; *) WHY="PATH=/usr/bin:/bin: [$out]"; return 1 ;; esac
  SECS=$(since "$t0"); WHAT="PATH=/usr/bin:/bin 也找到 ~/.local/bin/claude"
}

# install-sync SIGKILLed mid-tick (launchctl kickstart -k): its trap never runs and
# the lock stays; the next tick must take a dead holder's lock over (issue #1691).
drill_install_sync_killed() {
  CAP=20; local t0 d="$WORK/isync" pid
  mkdir -p "$d/conf" "$d/home"
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/install" 2>/dev/null
    mkdir -p "$d/install/bin" "$d/install/logs"
    printf 'echo "apply: ok"\n' > "$d/install/bin/fleet-install-apply.sh"
    printf 'while [ -f "%s/hold" ]; do sleep 0.1; done; echo doctor >> "%s/doctor.log"\n' "$d" "$d" > "$d/install/bin/fleet-doctor.sh"
    printf 'exit 0\n' > "$d/install/bin/fleet-diskguard.sh"; chmod +x "$d"/install/bin/*
    printf 'logs/\n' > "$d/install/.gitignore"
    git -C "$d/install" add -A && git -C "$d/install" commit -qm one && git -C "$d/install" push -q origin master
    echo two > "$d/install/f"; git -C "$d/install" add -A; git -C "$d/install" commit -qm two
    git -C "$d/install" push -q origin master; git -C "$d/install" reset -q --hard HEAD~1
    git --git-dir="$d/origin.git" update-ref refs/tags/stable master
  ) >/dev/null 2>&1 || { WHY="sandbox install did not build"; return 1; }
  isync() { HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
            bash "$BIN/fleet-install-sync.sh" --root "$d/install"; }
  touch "$d/hold"; isync >"$d/tick1.out" 2>&1 &              # held in its baseline doctor run
  until_ok 10 grep -q switching "$d/tick1.out" || { WHY="the first tick never got to switching: $(tail -2 "$d/tick1.out")"; return 1; }
  pid=$(cat "$d/conf/global/install-sync.lock/pid" 2>/dev/null)
  kill -9 "$pid" 2>/dev/null || { WHY="no live holder pid in the lock [$pid]"; return 1; }
  wait 2>/dev/null; rm -f "$d/hold"                           # killed mid-tick: no trap ran
  [ -d "$d/conf/global/install-sync.lock" ] || { WHY="SIGKILL left no lock — nothing to drill"; return 1; }
  t0=$(now)
  isync >"$d/tick2.out" 2>&1
  grep -q 'another tick holds' "$d/tick2.out" && { WHY="the next tick skipped on a dead holder's lock: $(grep 'another tick' "$d/tick2.out")"; return 1; }
  [ "$(git -C "$d/install" rev-parse HEAD)" = "$(git --git-dir="$d/origin.git" rev-parse stable)" ] \
    || { WHY="the next tick did not follow stable: $(tail -2 "$d/tick2.out")"; return 1; }
  grep -q "holder pid=$pid is dead" "$d/tick2.out" || { WHY="the takeover left no log line naming pid=$pid"; return 1; }
  SECS=$(since "$t0"); WHAT="下一拍接管死掉那一跳（pid=${pid}）的锁，跟上 stable"
}

# spinner-booted-out (issue #1849, audit #8): `launchctl bootout` of the spinner
# — KeepAlive, so launchd never restarts what it no longer knows, and the spinner
# is the hand that puts every other unit back. The diskguard tick's
# `fleet-daemon-watch.sh --resident` bootstraps it from its plist; a unit with no
# plist (a pure client) and a managed login (the machine daemon's children) are
# left alone. A launchctl stand-in on PATH keeps the loaded set in files.
drill_spinner_booted_out() {
  CAP=10; local t0 d="$WORK/resident" la out
  la="$d/home/Library/LaunchAgents"
  mkdir -p "$la" "$d/shim" "$d/loaded" "$d/conf" "$d/tmp" "$d/node"
  : > "$la/com.claude-fleet.spinner.plist"; : > "$la/com.claude-fleet.diskguard.plist"
  cat > "$d/shim/launchctl" <<SH
#!/bin/sh
echo "\$*" >> "$d/launchctl.log"
case "\$1" in
  print)     [ -f "$d/loaded/\${2##*/}" ] && { printf '\tstate = running\n'; exit 0; }; exit 113 ;;
  bootstrap) touch "$d/loaded/\$(basename "\$3" .plist)"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$d/shim/launchctl"
  resident() { PATH="$d/shim:$PATH" HOME="$d/home" TMPDIR="$d/tmp" FLEET_CONF_DIR="$d/conf" \
               FLEET_LAUNCHD_AGENTS_DIR="$la" FLEET_NODE_STATE="$d/node" FLEET_INSTALL_LOGIN=drill \
               FLEET_DAEMON_RESIDENT_GRACE=0 "$@" bash "$BIN/fleet-daemon-watch.sh" --resident 2>&1; }
  grep -q '^    resident_watch ' "$BIN/fleet-diskguard.sh" \
    || { WHY="the diskguard --watch tick does not run resident_watch"; return 1; }
  touch "$d/loaded/com.claude-fleet.spinner"
  resident env >/dev/null
  grep -q '^bootstrap' "$d/launchctl.log" 2>/dev/null && { WHY="a LOADED spinner was bootstrapped again"; return 1; }
  rm -f "$d/loaded/com.claude-fleet.spinner"                 # launchctl bootout gui/<uid>/com.claude-fleet.spinner
  t0=$(now)
  out=$(resident env)
  [ -f "$d/loaded/com.claude-fleet.spinner" ] || { WHY="the booted-out spinner stayed out: [$out] $(tail -3 "$d/launchctl.log")"; return 1; }
  SECS=$(since "$t0")
  grep -q 'resident-bootstrap unit=spinner' "$d/conf/logs/daemon-kick.log" 2>/dev/null \
    || { WHY="the bootstrap left no line in daemon-kick.log"; return 1; }
  rm -f "$d/loaded/com.claude-fleet.spinner"; : > "$d/launchctl.log"
  resident env >/dev/null
  grep -q '^bootstrap' "$d/launchctl.log" && { WHY="a second bootstrap inside the cooldown"; return 1; }
  printf '{"drill": {"managed": true}}\n' > "$d/node/accounts.json"
  resident env FLEET_DAEMON_RESIDENT_COOLDOWN=0 >/dev/null
  grep -q '^bootstrap' "$d/launchctl.log" && { WHY="a managed login's unit was bootstrapped (it is the machine daemon's child)"; return 1; }
  rm -f "$d/node/accounts.json"
  resident env FLEET_DAEMON_RESIDENT_COOLDOWN=0 >/dev/null
  [ -f "$d/loaded/com.claude-fleet.spinner" ] || { WHY="past the cooldown the spinner was not bootstrapped again"; return 1; }
  WHAT="spinner 被 bootout 后 diskguard 一拍从 plist 装回、记一行；冷却内不重复，没 plist 的不碰，托管登录不碰"
}

# dev-checkout-overwritten (issue #2779): a person's own checkout as the install
# survives a stable move (install-sync answers off · dev), a managed login needs
# root's consent, and `dev off` goes back and follows again — the selftest's legs.
drill_dev_checkout_overwritten() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-dev-mode-selftest.sh" 2>&1) \
    || { WHY="developer mode did not hold: $(printf '%s\n' "$out" | grep '^FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="开发模式：stable 前进时 install-sync 答 off · dev、链接不动；托管登录无 root 同意即拒；dev off 指回原版，下一拍 switched"
}

# epic_sandbox <dir> — a bare origin + a clone ONE commit behind stable, with
# stub apply / doctor / diskguard; the heartbeat and the state live under
# <dir>/conf. epic_tick runs one install-sync tick on it, epic_hb the heartbeat.
epic_sandbox() {
  local d="$1"
  mkdir -p "$d/conf" "$d/home"
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/install" 2>/dev/null
    mkdir -p "$d/install/bin" "$d/install/logs"
    printf 'echo "apply: ok"\n' > "$d/install/bin/fleet-install-apply.sh"
    printf 'exit 0\n' > "$d/install/bin/fleet-doctor.sh"
    printf 'exit 0\n' > "$d/install/bin/fleet-diskguard.sh"; chmod +x "$d"/install/bin/*
    printf 'logs/\n' > "$d/install/.gitignore"
    git -C "$d/install" add -A && git -C "$d/install" commit -qm one && git -C "$d/install" push -q origin master
    echo two > "$d/install/f"; git -C "$d/install" add -A; git -C "$d/install" commit -qm two
    git -C "$d/install" push -q origin master; git -C "$d/install" reset -q --hard HEAD~1
    git --git-dir="$d/origin.git" update-ref refs/tags/stable master
  ) >/dev/null 2>&1
}
# the hold is opt-in since issue #2934: the hold drills turn it on (EPIC_CAP, 2h),
# epic-hold-default runs the default (epic_tick_default)
epic_tick() { HOME="$1/home" FLEET_CONF_DIR="$1/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_EPIC_HOLD_CAP_SECS="${EPIC_CAP:-7200}" bash "$BIN/fleet-install-sync.sh" --root "$1/install"; }
epic_tick_default() { HOME="$1/home" FLEET_CONF_DIR="$1/conf" FLEET_SKIP_GLOBAL_CONF=1 bash "$BIN/fleet-install-sync.sh" --root "$1/install"; }
epic_hb()   { local d="$1"; shift; HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 bash "$BIN/fleet-epic-heartbeat.sh" "$@"; }
epic_st()   { sed -n "s/^$2: //p" "$1/conf/global/install-sync.state" | head -1; }

# epic_up <dir> — stable moves one commit on (a clone of the origin pushes it)
epic_up() {
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    [ -d "$1/up" ] || git clone -q "$1/origin.git" "$1/up"; git -C "$1/up" pull -q
    date +%s%N >> "$1/up/f"; git -C "$1/up" commit -qam up && git -C "$1/up" push -q origin master
    git --git-dir="$1/origin.git" update-ref refs/tags/stable master ) >/dev/null 2>&1
}

# epic-hold-uncapped — the opt-in hold (FLEET_EPIC_HOLD_CAP_SECS set), one sandbox:
# · two batches on one login (#2062): one mark each, --status shows both, --clear <N>
#   takes only its own, and the other still defers the tick BEFORE the switch (#1894
#   switched and only held the node agent: no `switched` line, HEAD where it was);
# · an idle batch (--live 0 --inflight 0, #2247) never holds: once the busy one
#   clears, the tick switches under it and the epic: line says idle;
# · a batch with work that never ends (#2247) is released at the cap, with ONE note
#   on its EPIC and an `epic-released` line — on the LOGIN's clock (#2843): a batch
#   whose own clock is fresh, on an older stable, is released all the same, and
#   reaching stable clears the clock.
drill_epic_hold_uncapped() {
  CAP=30; local t0 d="$WORK/epic" st stable
  epic_sandbox "$d" || { WHY="sandbox install did not build"; return 1; }
  epic_hb "$d" 1935 --tick 22 --repo o/r --session f1 >/dev/null 2>&1
  epic_hb "$d" 1982 --tick 10 --repo o/r --session f1 >/dev/null 2>&1
  t0=$(now)
  st=$(epic_hb "$d" --status 2>&1)
  case "$st" in *"epic=1935"*"epic=1982"*|*"epic=1982"*"epic=1935"*) ;; *) WHY="--status does not show both batches: [$st]"; return 1 ;; esac
  epic_hb "$d" --clear 1935 >/dev/null 2>&1
  case "$(epic_hb "$d" --status 2>&1)" in *"epic=1982"*) ;; *) WHY="--clear 1935 took #1982's mark too"; return 1 ;; esac
  epic_tick "$d" >"$d/tick1.out" 2>&1
  stable=$(git --git-dir="$d/origin.git" rev-parse stable)
  [ "$(epic_st "$d" result)" = deferred ] || { WHY="with #1982 fresh the tick was $(epic_st "$d" result): $(epic_st "$d" reason)"; return 1; }
  case "$(epic_st "$d" reason)" in *"epic=1982"*) ;; *) WHY="the deferral does not name #1982: $(epic_st "$d" reason)"; return 1 ;; esac
  grep -q ' switched ' "$d/conf/logs/install-sync.log" 2>/dev/null && { WHY="the log has a switched line under a fresh mark"; return 1; }
  [ "$(git -C "$d/install" rev-parse HEAD)" != "$stable" ] || { WHY="the install moved to stable under a fresh mark"; return 1; }
  # an idle batch beside it: still deferred by #1982; #1982 ends ⇒ switched under the idle one
  epic_hb "$d" 2140 --tick 18 --repo o/r --session f1 --live 0 --inflight 0 >/dev/null 2>&1
  epic_hb "$d" --clear 1982 >/dev/null 2>&1
  epic_tick "$d" >"$d/tick2.out" 2>&1
  [ "$(git -C "$d/install" rev-parse HEAD)" = "$stable" ] \
    || { WHY="an idle batch (live 0, nothing in flight) held the switch: $(epic_st "$d" result) $(epic_st "$d" reason)"; return 1; }
  case "$(epic_st "$d" epic)" in *"idle (空转，不挡) epic=2140"*) ;;
    *) WHY="the state's epic: line does not say the batch was idle: [$(epic_st "$d" epic)]"; return 1 ;; esac
  # stable moves on; a busy batch holds with a fresh clock of its own on an older
  # stable, the login has been held past the cap: released, noted once, clock cleared
  epic_up "$d"; stable=$(git --git-dir="$d/origin.git" rev-parse stable)
  epic_hb "$d" 2141 --tick 30 --repo o/r --session f1 --live 1 --inflight 1 >/dev/null 2>&1
  mkdir -p "$d/conf/global/epic-hold.d"
  printf 'since: %s\nstable: %s\nreleased: -\n' "$(date +%s)" "$(printf '0%.0s' $(seq 40))" > "$d/conf/global/epic-hold.d/o-r-2141"
  printf 'since: %s\n' "$(( $(date +%s) - 7300 ))" > "$d/conf/global/epic-hold.d/.since"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/notes.log"\n' "$d" > "$d/note.sh"
  FLEET_EPIC_HOLD_NOTE_CMD="sh $d/note.sh" epic_tick "$d" >"$d/tick3.out" 2>&1
  [ "$(git -C "$d/install" rev-parse HEAD)" = "$stable" ] \
    || { WHY="a batch past the login's cap still held the switch: $(epic_st "$d" result) $(epic_st "$d" reason)"; return 1; }
  [ "$(grep -c '^2141 --repo o/r --note' "$d/notes.log" 2>/dev/null)" = 1 ] \
    || { WHY="the release was not noted once on the EPIC: [$(cat "$d/notes.log" 2>/dev/null)]"; return 1; }
  grep -q ' epic-released ' "$d/conf/logs/install-sync.log" 2>/dev/null || { WHY="no epic-released log line"; return 1; }
  [ -e "$d/conf/global/epic-hold.d/.since" ] && { WHY="at stable the login's hold clock was kept"; return 1; }
  SECS=$(since "$t0")
  WHAT="打开封顶：两个批次各一份标记、只清自己的，新鲜标记在切换前就 deferred；空转批次不挡；有活的批次按登录一个钟、满 2 小时放行 switched，EPIC 上一条说明、日志 epic-released，到 stable 清钟"
}

# epic-hold-default (issue #2934): a batch with work held every update — the
# login's and the machine's — until it ended or the 2h cap fired, so with batches
# running all day the fleet sat behind stable (mac-c two versions behind, the
# bar 「旧」 all day) to buy only «a batch's new workers on its old version». A
# switch never stops a running session. Now the hold is off unless
# FLEET_EPIC_HOLD_CAP_SECS is set: the tick switches under a live batch, the
# state names the batch `off (不挡)`, no clock, no note.
drill_epic_hold_default() {
  CAP=20; local t0 d="$WORK/epic6" stable
  epic_sandbox "$d" || { WHY="sandbox install did not build"; return 1; }
  epic_hb "$d" 2934 --tick 3 --repo o/r --session f1 --live 2 --inflight 1 >/dev/null 2>&1
  stable=$(git --git-dir="$d/origin.git" rev-parse stable)
  t0=$(now)
  epic_tick_default "$d" >"$d/tick1.out" 2>&1
  [ "$(git -C "$d/install" rev-parse HEAD)" = "$stable" ] \
    || { WHY="a batch with work held the update by default: $(epic_st "$d" result) $(epic_st "$d" reason)"; return 1; }
  case "$(epic_st "$d" epic)" in *"off (不挡) epic=2934"*) ;;
    *) WHY="the state's epic: line does not name the batch as not holding: [$(epic_st "$d" epic)]"; return 1 ;; esac
  [ -e "$d/conf/global/epic-hold.d/.since" ] && { WHY="a hold clock started with the hold off"; return 1; }
  SECS=$(since "$t0"); WHAT="有活的批次在跑、stable 前进：默认不挡，那一拍照常 switched，epic: 行写 off (不挡)，不起钟"
}

# doctor-stricter-rollback (issue #2655): the new version's doctor has a check the
# old one lacked (or made stricter), and it FAILs on what the OLD daemons wrote
# before the switch. Before: the baseline was the old doctor alone, so the FAIL
# read as the new version's → rolled back, and `skip:` kept the login there until
# stable moved again — where the same old evidence rolled it back again. Now the
# new doctor runs once from its own dir before the switch and joins the baseline.
drill_doctor_stricter_rollback() {
  CAP=20; local t0 d="$WORK/dstrict"
  epic_sandbox "$d" || { WHY="sandbox install did not build"; return 1; }
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    c="$d/c"; git clone -q "$d/origin.git" "$c" 2>/dev/null
    printf '[ -f "${FLEET_CONF_DIR:-}/logs/old-evidence" ] && echo "  FAIL  state    hub-sessions cache 12499s (old evidence)"\nexit 0\n' > "$c/bin/fleet-doctor.sh"
    git -C "$c" add -A && git -C "$c" commit -qm three && git -C "$c" push -q origin master
    git --git-dir="$d/origin.git" update-ref refs/tags/stable master
  ) >/dev/null 2>&1
  mkdir -p "$d/conf/logs"; touch "$d/conf/logs/old-evidence"   # the old daemons' last hour (the login's records, #4668)
  t0=$(now)
  epic_tick "$d" >"$d/tick.out" 2>&1
  [ "$(epic_st "$d" result)" = switched ] \
    || { WHY="a check only the new doctor has, failing on the old evidence, decided the switch: $(epic_st "$d" result) $(epic_st "$d" reason)"; return 1; }
  [ "$(git -C "$d/install" rev-parse HEAD)" = "$(git --git-dir="$d/origin.git" rev-parse stable)" ] \
    || { WHY="switched but the install is not at stable"; return 1; }
  SECS=$(since "$t0"); WHAT="新版 doctor 新加的检查读旧守护留下的证据判 FAIL：切换前先用新 doctor 在旧版上跑一次做基线，这条不算新版的错，照常 switched"
}

# personal-tmux-conf (issue #1845): the person's ~/.tmux.conf has a syntax error
# (and the fleet's own source line in it is commented out). The fleet's server
# starts from conf/tmux-fleet-server.conf the way fleet-up.sh starts it
# (fleet_server_new_session): the fleet layer is on — the reap hook, the rename
# guard, @fleet_conf_loaded — the person's lines before the error still apply,
# fleet_tmuxconf_check (the doctor's tmuxconf row) says ok, and
# reapply-tmux-attention.sh no longer takes the commented line for the real one.
drill_personal_tmux_conf() {
  CAP=5; BREAK_SOCK="$WORK/sock-pc"; local t0 h="$WORK/pchome" chk out
  grep -q 'fleet_server_new_session "\$SOCK"' "$BIN/fleet-up.sh" \
    || { WHY="fleet-up.sh does not start its server through fleet_server_new_session (-f conf/tmux-fleet-server.conf)"; return 1; }
  mkdir -p "$h"
  { printf 'set -g @personal_before 1\n'
    printf "# if-shell '[ -f %s/conf/tmux-attention.conf ]' 'source-file %s/conf/tmux-attention.conf'\n" "$ROOT" "$ROOT"
    printf 'set -g status-left "an unterminated quote\n'
    printf 'set -g @personal_after 1\n'; } > "$h/.tmux.conf"
  t0=$(now)
  ( PATH="$WORK/tbin:$PATH" HOME="$h" FLEET_CONF_DIR="$WORK/pcconf"; export PATH HOME FLEET_CONF_DIR BREAK_SOCK
    . "$BIN/fleet-lib.sh"; fleet_server_new_session pc -d -s pc -n home -x 100 -y 30 'exec sleep 600' ) >/dev/null 2>&1 \
    || { WHY="the fleet server did not start beside a broken ~/.tmux.conf"; return 1; }
  nt show-hooks -g window-unlinked 2>/dev/null | grep -q 'fleet-window-reap.sh' || { WHY="the reap hook (window-unlinked → fleet-window-reap.sh) is not on the server"; return 1; }
  [ "$(nt show-options -gv allow-rename 2>/dev/null)" = off ] || { WHY="the rename guard (allow-rename off) is not on the server"; return 1; }
  [ -n "$(nt show-options -gqv @fleet_conf_loaded 2>/dev/null)" ] || { WHY="@fleet_conf_loaded is not set on the server"; return 1; }
  [ "$(nt show-options -gqv @personal_before 2>/dev/null)" = 1 ] || { WHY="the person's own settings were not loaded"; return 1; }
  chk=$( PATH="$WORK/tbin:$PATH" BREAK_SOCK="$BREAK_SOCK"; export PATH BREAK_SOCK
         . "$BIN/fleet-lib.sh"; fleet_tmuxconf_check pc )
  case "$chk" in ok*) ;; *) WHY="fleet_tmuxconf_check (the doctor's tmuxconf row) says [$chk]"; return 1 ;; esac
  out=$(PATH="$WORK/tbin:$PATH" HOME="$h" BREAK_SOCK="$BREAK_SOCK" sh "$BIN/reapply-tmux-attention.sh" 2>&1)
  grep -q '^[[:space:]]*[^#[:space:]].*tmux-attention\.conf' "$h/.tmux.conf" \
    || { WHY="reapply-tmux-attention.sh took the commented line for the real one: [$out]"; return 1; }
  SECS=$(since "$t0"); WHAT="个人配置有语法错，fleet 层照常（回收 hook、改名保护、@fleet_conf_loaded），tmuxconf 核对 ok，reapply 补回 source 行"
}

# ---- a personal configuration written badly (issue #1862, EPIC #1855 C7) -------
# The person's own layer (C2 #1857, C3 #1858) follows them to every machine — so
# does a mistake in it. Each drill writes one bad layer; the session must still
# open and work, and say which item is bad.
#
# ph_hook <timeout> <command> <calls> — one personal hook run the way Claude Code
# runs it (bin/fleet-hook-personal.sh), <calls> times in ONE session ($PH_LAUNCH);
# prints each call's "<rc>:<secs>" on one line.
ph_hook() {
  local out='' t
  for _ in $(seq 1 "$3"); do
    t=$(now)
    echo '{"session_id":"S-1"}' | env HOME="$WORK/ph" FLEET_CONF_DIR="$WORK/ph/conf" FLEET_PERSONAL_HOOK_TIMEOUT="$1" \
      FLEET_WRAP_LAUNCH_ID="$PH_LAUNCH" sh "$BIN/fleet-hook-personal.sh" PreToolUse -- "$2" >/dev/null 2>"$WORK/ph-hook.err"
    out="$out $?:$(since "$t")"
  done
  printf '%s\n' "${out# }"
}
# A personal hook that hangs: cut off at the timeout (C3) — and after 3 failures
# in a row it is off for the rest of this session, so the next call costs nothing.
drill_personal_hook_hangs() {
  CAP=6; local t0 r last; PH_LAUNCH="hang$$"; mkdir -p "$WORK/ph/conf"
  t0=$(now); r=$(ph_hook 1 'sleep 30' 5)
  last=${r##* }
  case "$r" in 1:*' '1:*' '1:*) ;; *) WHY="the first three calls were not cut off at 1s: [$r]"; return 1 ;; esac
  [ "${last%%:*}" = 0 ] && le "${last#*:}" 0.5 \
    || { WHY="after 3 timeouts the hook still runs — every tool call waits on it again: [$r]"; return 1; }
  ls "$WORK/ph/conf/personal-hook-strikes/$PH_LAUNCH/"*.off >/dev/null 2>&1 \
    || { WHY="nothing records the hook as off (the recovery page has nothing to say)"; return 1; }
  SECS=$(since "$t0"); WHAT="个人规则卡死：每次 1s 切断，连续 3 次后本会话停用（第 5 次 ${last#*:}s）"
}
# A personal hook that always errors (exit 1, a missing command → 127): off after
# 3 in a row. A deliberate deny (exit 2) is the hook doing its job — never a strike.
drill_personal_hook_errors() {
  # 14 sequential hook launches (no waiting in them): ~2 s here, 3.9 s on a macOS
  # runner (run 37731956688, #2377). The switch-off itself is pinned by the exit
  # codes below, so the bound only has to catch a launch that hangs.
  CAP=6; local t0 r; mkdir -p "$WORK/ph/conf"
  t0=$(now); PH_LAUNCH="err$$"; r=$(ph_hook 5 'exit 1' 4)
  case "$r" in 1:*' '1:*' '1:*' '0:*) ;; *) WHY="a hook that fails every time is never switched off: [$r]"; return 1 ;; esac
  PH_LAUNCH="err127$$"; r=$(ph_hook 5 'no-such-personal-tool-xyz --go' 4)
  case "$r" in 127:*' '127:*' '127:*' '0:*) ;; *) WHY="a hook whose command is missing is never switched off: [$r]"; return 1 ;; esac
  PH_LAUNCH="deny$$"; r=$(ph_hook 5 'echo no >&2; exit 2' 5)
  case "$r" in 2:*' '2:*' '2:*' '2:*' '2:*) ;; *) WHY="a deny (exit 2) was counted as a failure: [$r]"; return 1 ;; esac
  SECS=$(since "$t0"); WHAT="个人规则一直报错（exit 1 / 命令不存在）连续 3 次后本会话停用；拒绝（exit 2）不算失败"
}
# pt <args…> — fleet-agent-team.py against the sandbox login $WORK/pt: the
# person's answer is $WORK/pt/presp.json, the team layer empty, ~/.claude.json
# carrying the fleet default github server (as the agents pass leaves it).
pt_rig() {
  local H="$WORK/pt"; rm -rf "$H"; mkdir -p "$H/.claude" "$H/.codex" "$H/conf"
  python3 -c 'import json, sys
gh = json.load(open(sys.argv[1]))["mcpServers"]["github"]
json.dump({"numStartups": 1, "mcpServers": {"github": gh}}, open(sys.argv[2], "w"))' \
    "$ROOT/conf/agent-defaults/claude/mcp.default.json" "$H/.claude.json"
  echo '{}' > "$H/.claude/settings.json"; : > "$H/.codex/config.toml"
  printf '%s\n' '{"version":1,"prev":0,"bundle":{}}' > "$H/tresp.json"
}
pt() {
  local H="$WORK/pt"
  ( cd "$H" && env -i PATH="$PATH" HOME="$H" FLEET_CONF_DIR="$H/conf" CODEX_HOME="$H/.codex" ${PT_ENV:+"$PT_ENV"} \
    FLEET_TEAM_BUNDLE_CMD="cat '$H/tresp.json'" FLEET_PERSON_BUNDLE_CMD="cat '$H/presp.json'" \
    python3 "$ROOT/bin/fleet-agent-team.py" "$@" --root "$ROOT" --claude-config "$H/.claude.json" \
    --claude-settings "$H/.claude/settings.json" --claude-skills "$H/.claude/skills" --codex-home "$H/.codex" 2>&1 )
}
ptj() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2]), sort_keys=True))' "$@" 2>/dev/null; }
# A personal MCP server whose command is not on this machine (the person's laptop
# has it, this login does not): never written into the login's files, never
# handed to a session — and the session's start line names it.
drill_personal_mcp_missing() {
  CAP=10; local t0 H="$WORK/pt" out s
  pt_rig
  printf '%s\n' '{"version":1,"prev":0,"bundle":{"mcp":{"mytool":{"command":"/nonexistent/bin/mytool"},"fine":{"command":"sh","args":["-c","cat"]}}}}' > "$H/presp.json"
  t0=$(now)
  out=$(pt sync)
  [ "$(ptj "$H/.claude.json" "'mytool' in d['mcpServers']")" = false ] \
    || { WHY="sync wrote the missing-command server into ~/.claude.json: [$out]"; return 1; }
  [ "$(ptj "$H/.claude.json" "d['mcpServers']['fine']['command']")" = '"sh"' ] || { WHY="the good personal server did not land: [$out]"; return 1; }
  grep -q mytool "$H/.codex/config.toml" && { WHY="sync wrote it into config.toml"; return 1; }
  printf '%s' "$out" | grep -q 'mytool' || { WHY="sync says nothing about mytool: [$out]"; return 1; }
  s=$(pt session claude)
  printf '%s\n' "$s" | grep -q $'^note\t.*mytool.*/nonexistent/bin/mytool' || { WHY="the session's start line does not name it: [$s]"; return 1; }
  printf '%s\n' "$s" | sed -n 's/^mcp\t//p' | xargs cat 2>/dev/null | grep -q mytool && { WHY="the session was handed mytool"; return 1; }
  # both launchers hand the composer to the one shared step (T620), which prints them
  grep -q 'note)' "$BIN/fleet-launch-lib.sh" && grep -q 'fleet_launch_cfg' "$BIN/fleet-claude.sh" \
    && grep -q 'fleet_launch_cfg' "$BIN/fleet-codex.sh" \
    || { WHY="fleet-claude.sh / fleet-codex.sh do not print the composer's note lines"; return 1; }
  SECS=$(since "$t0"); WHAT="个人 MCP 命令不存在：不写进本机文件、不交给会话，启动行点名"
}
# The personal layer replaces a fleet default MCP server (github) with one whose
# command is not here: the fleet default stays in force; the start line says why.
drill_personal_mcp_over_default() {
  CAP=10; local t0 H="$WORK/pt" out s gh
  pt_rig; gh=$(ptj "$H/.claude.json" "d['mcpServers']['github']")
  printf '%s\n' '{"version":1,"prev":0,"bundle":{"mcp":{"github":{"command":"/nonexistent/gh-mcp"}}}}' > "$H/presp.json"
  t0=$(now)
  out=$(pt sync)
  [ "$(ptj "$H/.claude.json" "d['mcpServers']['github']")" = "$gh" ] \
    || { WHY="the personal layer broke the fleet's github server: $(ptj "$H/.claude.json" "d['mcpServers']['github']") [$out]"; return 1; }
  [ "$(ptj "$H/conf/agent-effective.json" "d['items'].get('claude.mcp.github', {}).get('source')")" != '"personal"' ] \
    || { WHY="agent-effective.json says github is the personal layer's"; return 1; }
  s=$(pt session claude)
  printf '%s\n' "$s" | grep -q $'^note\t.*github' || { WHY="the session's start line does not name github: [$s]"; return 1; }
  SECS=$(since "$t0"); WHAT="个人层把 github 换成不存在的命令：fleet 默认照常生效，启动行点名"
}
# person-bundle.json cut short (a disk full mid-write, a crash, a bad hand edit):
# the session uses the last good copy and says so — the person's items do not
# silently vanish, and the next apply does not take them back.
drill_personal_cache_truncated() {
  CAP=10; local t0 H="$WORK/pt" out s
  pt_rig
  printf '%s\n' '{"version":1,"prev":0,"bundle":{"mcp":{"pm":{"command":"sh","args":["-c","cat"]}},"claude_settings":{"includeCoAuthoredBy":false}}}' > "$H/presp.json"
  pt sync >/dev/null
  [ "$(ptj "$H/.claude.json" "d['mcpServers']['pm']['command']")" = '"sh"' ] || { WHY="the rig's personal server did not land"; return 1; }
  head -c 25 "$H/conf/person-bundle.json" > "$H/pb.cut" && mv "$H/pb.cut" "$H/conf/person-bundle.json"
  t0=$(now)
  s=$(pt session claude)
  printf '%s\n' "$s" | grep -q $'^src\t.* personal:v1 ' || { WHY="a truncated cache dropped the personal layer from the session: [$s]"; return 1; }
  printf '%s\n' "$s" | grep -q $'^note\t.*person-bundle.json' || { WHY="the session's start line does not say the cache is broken: [$s]"; return 1; }
  out=$(pt apply)
  [ "$(ptj "$H/.claude.json" "d['mcpServers'].get('pm', {}).get('command')")" = '"sh"' ] \
    || { WHY="apply took the personal server back on a truncated cache: [$out]"; return 1; }
  [ "$(ptj "$H/.claude/settings.json" "d.get('includeCoAuthoredBy')")" = false ] || { WHY="apply took the personal setting back: [$out]"; return 1; }
  SECS=$(since "$t0"); WHAT="个人缓存被截断：用上一份完好的 v1，启动行告警，本机文件不被收回"
}
# The personal layer makes the session useless (a hook that refuses every call, a
# setting that breaks it): the recovery page offers p — the SAME conversation, this
# window only, without the personal layer (FLEET_PERSONAL=0: personal hooks do not
# run, the composer leaves the layer out). Hooks switched off in the run that just
# ended are named on the page.
drill_personal_breaks_session() {
  CAP=8; BREAK_SOCK="$WORK/sock-pb"; local c="$WORK/pb" t0 out rc
  mkdir -p "$c/conf" && printf '%s\n' '{"version":3,"bundle":{}}' > "$c/conf/person-bundle.json"
  printf 'exit 1' > "$c/hook"
  PERS_CONF="$c/conf" wrapped sx w "$c" || { WHY="cannot start the isolated tmux server"; return 1; }
  until_ok 15 sh -c "[ \"\$(grep -c . '$c/hook-rc' 2>/dev/null)\" = 4 ]" || { WHY="the agent's personal hook calls never finished"; return 1; }
  t0=$(now); printf rc0 > "$c/mode"; : > "$c/go"
  until_ok 10 page_says '⌘P 回列表' || { WHY="no recovery page"; return 1; }
  page_says '不带个人配置重开' \
    || { WHY="the page offers no way to reopen without the personal layer: $(nt capture-pane -p -t sx:w | grep . | tail -1)"; return 1; }
  page_says '个人自动规则' || { WHY="the page does not say a personal hook was switched off"; return 1; }
  rm -f "$c/hook"; nt send-keys -t sx:w p
  until_ok 10 sh -c "[ \$(grep -c . '$c/argv') = 2 ]" || { WHY="p relaunched nothing"; return 1; }
  [ "$(sed -n 2p "$c/argv")" = "--agent claude --resume SID-1" ] || { WHY="p ran [$(sed -n 2p "$c/argv")], not the same conversation"; return 1; }
  [ "$(sed -n 2p "$c/personal")" = 0 ] || { WHY="the relaunch did not run with FLEET_PERSONAL=0 ([$(sed -n 2p "$c/personal")])"; return 1; }
  out=$(echo '{}' | FLEET_PERSONAL=0 sh "$BIN/fleet-hook-personal.sh" PreToolUse -- 'echo no >&2; exit 2' 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="under FLEET_PERSONAL=0 a personal hook still runs (rc $rc: $out)"; return 1; }
  pt_rig; printf '%s\n' '{"version":2,"prev":1,"bundle":{"claude_settings":{"includeCoAuthoredBy":false}}}' > "$WORK/pt/presp.json"
  pt sync >/dev/null
  out=$(PT_ENV=FLEET_PERSONAL=0 pt session claude)
  printf '%s\n' "$out" | grep -q $'^src\t.* personal:off ' || { WHY="the composer under FLEET_PERSONAL=0 still uses the layer: [$out]"; return 1; }
  SECS=$(since "$t0"); WHAT="恢复页 p：同一对话、本窗口不带个人配置重开；停用的个人规则在页上点名"
}

# node-menu / node-prefix-keys / window-killed (issue #1840): what a PERSON can
# reach on a node's fleet server deletes nothing, and a session window deleted
# anyway comes back on the next tick, same conversation.
# hpty <sock> <window> <out> <bytes…> — a real client in a python pty, attached to
# <window>; each <bytes> arg (python escapes) is typed 0.6s apart; everything the
# client drew lands in <out>.
hpty() {
  python3 - "$REAL_TMUX" "$@" <<'PY'
import os, pty, select, struct, sys, time, fcntl, termios
tm, sock, win, out = sys.argv[1:5]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(tm, [tm, "-S", sock, "attach", "-t", win])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
buf = b""
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: buf += os.read(fd, 65536)
            except OSError: return
pump(0.8)
for b in sys.argv[5:]:
    os.write(fd, b.encode().decode("unicode_escape").encode("latin-1")); pump(0.6)
pump(0.4)
open(out, "wb").write(buf)
try: os.kill(pid, 9)
except OSError: pass
PY
}
# hnode <label> — a node server started the way fleet-up starts one (-f
# conf/tmux-fleet-server.conf), beside a personal ~/.tmux.conf that puts tmux's
# deletes back, with two execution windows
hnode() {
  BREAK_SOCK="$WORK/sock-$1"; local h="$WORK/$1home"
  mkdir -p "$h"
  { printf 'bind x kill-pane\nbind & kill-window\n'
    printf 'bind -n MouseDown3Pane display-menu -t = -x M -y M Kill X { kill-pane } Respawn R { respawn-pane -k }\n'; } > "$h/.tmux.conf"
  HOME="$h" "$REAL_TMUX" -S "$BREAK_SOCK" -f "$ROOT/conf/tmux-fleet-server.conf" new-session -d -s "$1" -n home -x 100 -y 30 'exec sleep 600' \
    || { WHY="the node server did not start from conf/tmux-fleet-server.conf"; return 1; }
  nt set-option -g mouse on
  nt new-window -d -t "$1:" -n issue-1 'exec sleep 600'
  nt new-window -d -t "$1:" -n issue-2 'exec sleep 600'
}

drill_node_menu() {
  CAP=5; local t0 out="$WORK/hm.out" item
  hnode hm || return 1
  t0=$(now)
  # the break: a right-click on the session's pane (SGR mouse, button 3) …
  hpty "$BREAK_SOCK" hm:issue-1 "$out" '\x1b[<2;20;10M' '\x1b[<2;20;10m'
  grep -aq 'Kill\|Respawn' "$out" && { WHY="the right-click menu still offers Kill / Respawn"; return 1; }
  for item in 复制这一屏 它在哪台 给它发消息 看它的单; do
    grep -aq "$item" "$out" || { WHY="the right-click menu has no 「${item}」 (did it open at all?)"; return 1; }
  done
  # … and no other right-click (Alt, the status line) deletes either
  nt list-keys -T root | grep -E 'MouseDown3' | grep -Eq 'kill-|respawn-' \
    && { WHY="a right-click binding still deletes: $(nt list-keys -T root | grep -E 'MouseDown3' | grep -E 'kill-|respawn-' | awk '{print $4}' | tr '\n' ' ')"; return 1; }
  [ "$(nt list-windows -t hm -F '#{window_name}' | sort | tr '\n' ' ')" = "home issue-1 issue-2 " ] || { WHY="a window went missing"; return 1; }
  SECS=$(since "$t0"); WHAT="右键弹只读菜单（复制 · 在哪台 · 发消息 · 看单），没有 Kill / Respawn；个人配置加不回来"
}

drill_node_prefix_keys() {
  CAP=10; local t0 out="$WORK/hk.out" wins
  hnode hk || return 1
  t0=$(now)
  # the break: a direct attach typing prefix x y, prefix & y, prefix $ <name> ↵, prefix < (C-b = \x02)
  hpty "$BREAK_SOCK" hk:issue-1 "$out" '\x02x' 'y' '\x02&' 'y' '\x02$' 'gone\r' '\x02<' '\x1b'
  wins=$(nt list-windows -t hk -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' ')
  [ "$wins" = "home issue-1 issue-2 " ] || { WHY="after prefix x / & the windows are [$wins], want [home issue-1 issue-2 ]"; return 1; }
  nt has-session -t '=hk' 2>/dev/null || { WHY="prefix \$ renamed the fleet session"; return 1; }
  [ "$(nt show-options -gqv @fleet_human)" = v1 ] || { WHY="the human layer (@fleet_human) is not on the server"; return 1; }
  SECS=$(since "$t0"); WHAT="prefix x / & / \$ / < 都不起作用，个人配置绑回的 x / & 也被最后一层拿掉"
}

# view-mouse-stale (issue #3000, EPIC #2999 C2): the 看台's key table is a COPY of
# root — tmux does not fall back to root for a key a session's key-table lacks — so
# a root changed after the copy (a person re-sourcing ~/.tmux.conf) leaves the
# 看台's mouse unlike a direct attach's, until attach --thin's --if-stale rebuild.
drill_view_mouse_stale() {
  CAP=10; local t0
  hnode vm || return 1
  vmcopy() { nt list-keys -T fleet-view | awk '$4 !~ /^User9[0-9][0-9]$/ && $4 != "C-]" && $4 != "C-\\\\" && $4 != "C-Space" && $4 != "F12" && $4 != "MouseDown1Status" { $3 = "root"; $1 = $1; print }' | sort; }
  # MouseDown1Status is the 看台's own (T701: the message row's click), root's inside it
  vmroot() { nt list-keys -T root | awk '$4 != "MouseDown1Status" { $1 = $1; print }' | sort; }
  [ "$(vmcopy)" = "$(vmroot)" ] || { WHY="right after start the 看台's fleet-view is not root's copy"; return 1; }
  grep -q 'view-keys --if-stale' "$BIN/fleet-remote-view.sh" || { WHY="attach --thin does not rebuild a stale fleet-view (view-keys --if-stale)"; return 1; }
  # the break: root's wheel re-bound after the copy, as a re-sourced ~/.tmux.conf does
  nt bind-key -n WheelUpPane copy-mode -e
  [ "$(vmcopy)" = "$(vmroot)" ] && { WHY="the break did not take (root's wheel is still the copy's)"; return 1; }
  t0=$(now)
  TMUX="$BREAK_SOCK,0,0" python3 "$BIN/fleet-quickopen.py" view-keys --if-stale >/dev/null 2>&1
  [ "$(vmcopy)" = "$(vmroot)" ] || { WHY="after attach --thin's rebuild the 看台's mouse still differs from root: $(diff <(vmcopy) <(vmroot) | head -3)"; return 1; }
  nt list-keys -T fleet-view | awk '$4 == "User927"' | grep -q . || { WHY="the rebuild lost the 看台's ⌘P"; return 1; }
  SECS=$(since "$t0"); WHAT="root 改了之后，下一次 attach --thin 重建看台键表：滚轮、点击与直接 attach 一致，⌘ 键还在"
}

drill_window_killed() {
  CAP=20; BREAK_SOCK="$WORK/sock-wk"; local t0 wins w2 f led="$WORK/wk-ledger.tsv"
  local f1=1f0e0000-0000-4000-8000-0000000018a1 f2=1f0e0000-0000-4000-8000-0000000018a2
  for f in dash-reap.sh session-end-hook.sh fleet-cleanup.sh fleet-move.sh fleet-worker-stop.sh fleet-diskguard.sh fleet-cleanup-idle.py; do
    grep -q 'retire' "$BIN/$f" || { WHY="$f closes a session window without marking it (fleet_win_retire): the next tick would pull it back"; return 1; }
  done
  mkdir -p "$WORK/gbin"
  printf '#!/bin/sh\necho 0\n' > "$WORK/gbin/gh"; chmod +x "$WORK/gbin/gh"     # no merged PR
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'FID\t%s\n' "$f1"; printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
    printf 'FID\t%s\n' "$f2"; printf 'WIN\tissue-2\t%s\tsid-2\t2\tidle\t-\t-\n'    "$WORK/wt-2"
  } > "$WORK/econf/fleets/oc/restore.map"
  auto
  until_ok 10 sh -c "[ \"\$('$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t oc -F '#{@fleet_id}' 2>/dev/null | grep -c .)\" = 2 ]" \
    || { WHY="the sandbox fleet never came up with both sessions"; return 1; }
  # issue-2 the fleet closes on purpose (the recovery page's q, a reap): marked first
  w2=$(nt list-windows -t oc -F '#{window_id} #{@fleet_id}' | awk -v f="$f2" '$2 == f { print $1 }')
  ( PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf"; export PATH HOME FLEET_CONF_DIR BREAK_SOCK
    . "$BIN/fleet-lib.sh"; fleet_win_retire "$w2" oc )
  : > "$WORK/claude-argv"
  nt kill-window -t "$w2"
  nt kill-window -t oc:issue-1                    # the break: a session window deleted by hand
  t0=$(now)
  auto PATH="$WORK/gbin:$WORK/tbin:$PATH" FLEET_HISTORY_LEDGER="$led"     # one diskguard tick
  until_ok "$CAP" sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t oc -F '#{@fleet_id}' 2>/dev/null | grep -qx '$f1'" \
    || { WHY="the killed issue-1 did not come back: $(grep pullback "$WORK/econf/restore/restore.log" 2>/dev/null | tail -3 | tr '\n' ' ')"; return 1; }
  until_ok "$CAP" grep -q -- '--resume sid-1' "$WORK/claude-argv" 2>/dev/null || { WHY="issue-1 came back without its conversation (--resume sid-1)"; return 1; }
  SECS=$(since "$t0")
  wins=$(nt list-windows -t oc -F '#{window_name}' | sort | tr '\n' ' ')
  [ "$wins" = "home issue-1 " ] || { WHY="after the tick the fleet has [$wins], want [home issue-1 ] (the fleet's own close stays closed)"; return 1; }
  grep -q 'sid-1.*reason=killed-window' "$led" 2>/dev/null || { WHY="/fleet-history has no reason=killed-window row: [$(cat "$led" 2>/dev/null)]"; return 1; }
  auto PATH="$WORK/gbin:$WORK/tbin:$PATH" FLEET_HISTORY_LEDGER="$led"     # a second tick: nothing doubles
  [ "$(nt list-windows -t oc -F '#{window_name}' | grep -c '^issue-1$')" = 1 ] || { WHY="a second tick opened issue-1 twice"; return 1; }
  # The marks' sweep is one pass (issue #3544): a pile of old marks stays, the
  # mark of a session live again (issue-1, back now) is lifted.
  local rdir="$WORK/econf/global/retired" i
  mkdir -p "$rdir"
  i=0; while [ "$i" -lt 300 ]; do : > "$rdir/2f0e0000-0000-4000-8000-$(printf '%012d' "$i")"; i=$((i + 1)); done
  : > "$rdir/$f1"
  python3 -c 'import os, sys, time
t = time.time() - 600
for n in os.listdir(sys.argv[1]): os.utime(os.path.join(sys.argv[1], n), (t, t))' "$rdir"
  auto PATH="$WORK/gbin:$WORK/tbin:$PATH" FLEET_HISTORY_LEDGER="$led"
  [ ! -e "$rdir/$f1" ] || { WHY="the mark of issue-1, live again, was not lifted"; return 1; }
  i=$(find "$rdir" -name '2f0e0000-*' | grep -c .)
  [ "$i" = 300 ] || { WHY="the sweep removed marks of sessions that are not live: $i of 300 left"; return 1; }
  WHAT="被删的 issue-1 下一拍以原对话回来，/fleet-history 记 reason=killed-window；fleet 自己关的 issue-2 不拉回（节拍 60s 另计）"
}

# One conversation in three map rows (issue #3543): two windows came back resuming
# the same Claude conversation, and a reaped session stayed in the map for good —
# the shrink guard ("keep the richer map") counted the duplicates and the retired.
drill_restore_conversation_twice() {
  CAP=20; BREAK_SOCK="$WORK/sock-ct"; local t0 n mf="$WORK/econf/fleets/oc/restore.map"
  local sid=3543aaaa-0000-4000-8000-000000003543 gone=3543bbbb-0000-4000-8000-000000003543
  local f1=1f0e0000-0000-4000-8000-000000035431 f2=1f0e0000-0000-4000-8000-000000035432
  local f3=1f0e0000-0000-4000-8000-000000035433 f4=1f0e0000-0000-4000-8000-000000035434
  # a no-repo row (column 16 `-`): it resumes in $HOME, where a shared cwd let three windows guess one id
  ct_row() { printf 'FID\t%s\nWIN\t%s\t%s\t%s\t-\tworking\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\n' "$1" "$2" "$WORK/home" "$3"; }
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    ct_row "$f1" 'linux-a shell' "$sid"; ct_row "$f2" 'mac-c shell' "$sid"; ct_row "$f3" 'mac-c shell' "$sid"
  } > "$mf"
  : > "$WORK/claude-argv"
  t0=$(now)
  auto                                            # the break: a restore off that map
  until_ok "$CAP" grep -q -- "--resume $sid" "$WORK/claude-argv" 2>/dev/null \
    || { WHY="the conversation was not resumed at all"; return 1; }
  sleep 1
  n=$(grep -c -- "--resume $sid" "$WORK/claude-argv")
  [ "$n" = 1 ] || { WHY="restore resumed conversation ${sid%%-*}… $n times (two agents on one transcript)"; return 1; }
  n=$(nt list-windows -t oc -F '#{@fleet_id}' | grep -cx "$f3")
  [ "$n" = 1 ] || { WHY="the kept window is not the newest row's ($f3): [$(nt list-windows -t oc -F '#{window_name} #{@fleet_id}' | tr '\n' ' ')]"; return 1; }
  auto                                            # a second tick: nothing doubles
  sleep 1
  [ "$(grep -c -- "--resume $sid" "$WORK/claude-argv")" = 1 ] || { WHY="a second tick resumed the conversation again"; return 1; }
  # a session the fleet reaped (fleet_win_retire), still in the stored map, the live
  # fleet now smaller than that map: the snapshot drops it instead of keeping it
  { cat "$mf"; ct_row "$f4" '我的会话-3' "$gone"; } > "$mf.x" && mv "$mf.x" "$mf"
  mkdir -p "$WORK/econf/global/retired"; : > "$WORK/econf/global/retired/$f4"
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf" FLEET_SKIP_GLOBAL_CONF=1 \
    BREAK_SOCK="$BREAK_SOCK" bash -c '. "$1/fleet-lib.sh"; fleet_restore_map_prune "$2" --retired "$3"' _ "$WORK/inst/bin" "$mf" "$f3" > "$mf.p"
  grep -q "$gone" "$mf.p" && { WHY="a retired session no window carries survives the prune: $(grep -c WIN "$mf.p") rows"; return 1; }
  [ "$(awk -F'\t' '$1 == "WIN"' "$mf.p" | wc -l | tr -d ' ')" = 1 ] || { WHY="the pruned map has not one row per conversation: [$(awk -F'\t' '$1 == "WIN" { print $2 }' "$mf.p" | tr '\n' ' ')]"; return 1; }
  grep -q 'fleet_restore_map_prune "$prior" --retired' "$BIN/fleet-restore.sh" \
    || { WHY="the snapshot's shrink guard does not prune the stored map before counting it"; return 1; }
  SECS=$(since "$t0"); WHAT="同一对话在地图里三行：restore 只开最新那一行一个窗口、第二拍不重开；回收过的会话从地图里删掉"
}

# A 看台's peer window (issue #3829): `@linux-b·ops`, an ssh onto another
# machine with no session of its own. The snapshot wrote it as a session row and
# guessed its conversation by mtime — $HOME's newest, an old orchestrator one — so
# a reboot's restore reopened that conversation under a deleted login's name.
drill_restore_peer_window() {
  CAP=20; BREAK_SOCK="$WORK/sock-pw"; local t0 mf="$WORK/econf/fleets/oc/restore.map"
  local old=3829aaaa-0000-4000-8000-000000003829 fp=1f0e0000-0000-4000-8000-000000038291
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'FID\t%s\n' "$fp"
    printf 'WIN\t@linux-b·ops\t%s\t%s\t-\tlooping\t-\t-\n' "$WORK/home" "$old"
    printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
  } > "$mf"
  : > "$WORK/claude-argv"
  t0=$(now)
  auto                                            # the break: a reboot's restore off an old map
  until_ok "$CAP" grep -q -- '--resume sid-1' "$WORK/claude-argv" 2>/dev/null \
    || { WHY="the sandbox fleet never came back with issue-1"; return 1; }
  sleep 1
  grep -q -- "--resume $old" "$WORK/claude-argv" \
    && { WHY="the peer window's guessed conversation ${old%%-*}… was reopened"; return 1; }
  nt list-windows -t oc -F '#{window_name}' | grep -q '^@' \
    && { WHY="a peer window came back as a session: [$(nt list-windows -t oc -F '#{window_name}' | tr '\n' ' ')]"; return 1; }
  # …and a live peer window never enters the map again
  local pw; pw=$(nt new-window -d -P -F '#{window_id}' -t oc: -n '@mac-c' -c "$WORK/home" 'exec sleep 600')
  nt set-option -w -t "$pw" @peer 'mac-c@me'; nt set-option -w -t "$pw" @fleet_role panel
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf" FLEET_SKIP_GLOBAL_CONF=1 \
    BREAK_SOCK="$BREAK_SOCK" bash "$WORK/inst/bin/fleet-restore.sh" --snapshot >/dev/null 2>&1
  grep -q '^WIN.issue-1' "$mf" || { WHY="the snapshot did not run against the sandbox (no issue-1 row)"; return 1; }
  grep -q '^WIN.@' "$mf" && { WHY="the snapshot wrote the peer window as a session: $(grep '^WIN.@' "$mf" | cut -f2-4)"; return 1; }
  SECS=$(since "$t0"); WHAT="看台对端窗口（@机器·登录）不进恢复图；旧图里有也不按它猜的对话重开"
}

# A no-repo Codex window killed, pulled back on its thread, and the pull-back sat on
# Codex's «Hooks need review» page (issue #4728): the launcher cleared the window's
# @codex_identity, no hook ever ran to write it back, and the next snapshot wrote the
# row with no thread — ⌘P then held only a new Codex and the conversation was gone.
# The resume now names its thread (@codex_pending) until its hook does, and a window
# that does not know its thread keeps the one its identity had in the stored map.
drill_codex_thread_lost() {
  CAP=25; BREAK_SOCK="$WORK/sock-tl"; local t0 w row mf="$WORK/econf/fleets/oc/restore.map"
  local tid=01a14de0-a17e-7f72-a2a8-6716048c2ebf ft=1f0e0000-0000-4000-8000-000000047281
  local cx="$WORK/cxtl"; mkdir -p "$cx/bin" "$cx/home"
  # a Codex that never reaches its first hook: it logs its argv and waits (the review page)
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/argv"\nexec sleep 600\n' "$cx" > "$cx/bin/codex"; chmod +x "$cx/bin/codex"
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'FID\t%s\nWIN\t我的会话-6\t%s\t%s\t-\tworking\t-\t-\t-\tcodex\t%s\t-\t-\t-\t-\t-\n' "$ft" "$WORK/home" "$tid" "$cx/home"
    printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
  } > "$mf"
  : > "$WORK/claude-argv"; : > "$cx/argv"
  t0=$(now)
  auto PATH="$cx/bin:$WORK/tbin:$PATH" FLEET_CODEX_SERVER=0 FLEET_CODEX_VERSION_CHECK=0 FLEET_MCP=0 \
    FLEET_AGENT_CFG=0 FLEET_PRETRUST=0 FLEET_CRED_PROXY=0
  until_ok "$CAP" grep -q "resume $tid" "$cx/argv" \
    || { WHY="the Codex row was not resumed on its thread: [$(cat "$cx/argv" | tr '\n' ' ')] DBG $(nt list-windows -a -F '#{window_name}:#{@fleet_id}' | tr '\n' ' ') $(for p in $(nt list-panes -a -F '#{pane_id}'); do nt capture-pane -p -t $p | grep . | tail -3; done | tr '\n' ' ') $(tail -5 "$WORK"/econf/logs/restore.log 2>/dev/null | tr '\n' ' ')"; return 1; }
  w=$(nt list-windows -t oc -F '#{window_id} #{@fleet_id}' | awk -v f="$ft" '$2 == f { print $1 }')
  [ -n "$w" ] || { WHY="the resumed window does not carry its identity"; return 1; }
  until_ok 5 sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' show-options -wv -t '$w' @codex_pending 2>/dev/null | grep -q '$tid'" \
    || { WHY="the resume does not name its thread on the window (@codex_pending)"; return 1; }
  snap() { env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf" FLEET_SKIP_GLOBAL_CONF=1 \
             BREAK_SOCK="$BREAK_SOCK" bash "$WORK/inst/bin/fleet-restore.sh" --snapshot >/dev/null 2>&1; }
  snap                                            # the break: a snapshot while it waits on the page
  row=$(awk -F'\t' -v f="$ft" '$1 == "FID" { n = ($2 == f); next } n && $1 == "WIN" { print; exit }' "$mf")
  [ -n "$row" ] || { WHY="the snapshot lost the session's row: [$(cut -f1-4 "$mf" | tr '\n' ' ')]"; return 1; }
  [ "$(printf '%s' "$row" | cut -f4)" = "$tid" ] \
    || { WHY="the snapshot wrote the waiting resume with thread [$(printf '%s' "$row" | cut -f4)], not ${tid%%-*}…"; return 1; }
  # …and a window that came back NEW (no thread yet, the pending stamp gone) keeps it too
  nt set-option -wu -t "$w" @codex_pending; nt set-option -w -t "$w" @cc_launcher_pid 4728
  nt set-option -w -t "$w" @claude_state needs
  snap
  row=$(awk -F'\t' -v f="$ft" '$1 == "FID" { n = ($2 == f); next } n && $1 == "WIN" { print; exit }' "$mf")
  [ "$(printf '%s' "$row" | cut -f4)" = "$tid" ] \
    || { WHY="a new window under the session's identity erased its thread: [$(printf '%s' "$row" | cut -f2-6)]"; return 1; }
  [ "$(printf '%s' "$row" | cut -f11)" = "$cx/home" ] || { WHY="the kept thread lost its Codex home: [$(printf '%s' "$row" | cut -f10-12)]"; return 1; }
  SECS=$(since "$t0"); WHAT="无仓库 Codex 被杀后续接、停在 hook 审查页或回来是新开的：恢复图那一行仍记着原 thread"
}

# ---- codex-clear-lost (T540): a Codex parent typed /clear; until the new thread's
# first turn its window still named the old one (0.162 runs SessionStart only then)
# and the old thread stays LOADED, so peer-send said «sent → codex <old>» and a
# child's report read DELIVERED — into a thread nobody sees. Now the runtime follows
# thread/started at once, and a delivery the window's server says is not into its
# current thread is held (exit 3 since T626, 4 before → queued for the window's
# identity, replayed). The recovery is fleet-codex-session-selftest.sh's own leg
# against a fixture app-server (bin/fleet_codex_fake_appserver.py): held, followed,
# drained into the new thread, DELIVERED only then — and since T626 the one delivery
# road runs the same /clear leg for BOTH agents (fleet-agent-deliver-selftest.py:
# Claude's inbox reaches the new conversation at once, Codex holds then replays) —
# both held here by name, not run twice.
drill_codex_clear_lost() {
  CAP=30; local t0
  t0=$(now)
  grep -q 'raise Held(why)' "$ROOT/bin/fleet-codex-session.py" \
    || { WHY="fleet-codex-session.py send no longer holds a delivery off the window's current thread"; return 1; }
  grep -q 'session_mod\["Follow"\]' "$ROOT/bin/fleet-codex-runtime.py" \
    || { WHY="fleet-codex-runtime.py no longer runs the thread follower"; return 1; }
  suite_holds fleet-codex-session-selftest.sh 'def test_clear_holds_then_follows_into_the_new_thread' \
    "'held is never DELIVERED'" || return 1
  suite_holds fleet-agent-deliver-selftest.py 'def test_clear_reaches_the_new_conversation' \
    "for agent in ('claude', 'codex')" "'the replay lands in the new thread'" || return 1
  WHAT='Codex clear 后普通消息暂存，不投旧线程；跟随新线程后通过原投递入口重放，Parent回报保持退役'
  SECS=$(since "$t0")
}

# A role's mark lived on its window (issue #3829): a reboot took the server and the
# `@fleet_role_def` with it, and nobody held the orchestrator role until a person
# stole it. Since issue #4341 no session needs a mark: a keyless session's key IS
# its @fleet_id, which restore stamps back — so after the reboot's restore its
# children still reach it by identity, and a conversation a person resumed by hand
# first is not opened a second time.
drill_restore_role_lost() {
  CAP=20; BREAK_SOCK="$WORK/sock-rl"; local t0 w k mf="$WORK/econf/fleets/oc/restore.map"
  local sid=3829bbbb-0000-4000-8000-000000003829 fo=1f0e0000-0000-4000-8000-000000038292
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'FID\t%s\nWIN\t编排\t%s\t%s\t-\tlooping\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\n' "$fo" "$WORK/home" "$sid"
  } > "$mf"
  : > "$WORK/claude-argv"
  t0=$(now)
  auto                                            # the break: the reboot's restore
  until_ok "$CAP" grep -q -- "--resume $sid" "$WORK/claude-argv" 2>/dev/null \
    || { WHY="the keyless session's conversation was not resumed"; return 1; }
  w=$(nt list-windows -t oc -F '#{window_id}|#{@fleet_id}' | awk -F'|' -v f="$fo" '$2 == f { print $1 }')
  [ -n "$w" ] || { WHY="no window came back with the session's identity"; return 1; }
  k=$(env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf" FLEET_SKIP_GLOBAL_CONF=1 \
      BREAK_SOCK="$BREAK_SOCK" bash -c '. "$1/fleet-lib.sh"; fleet_win_for_addr "$2"' _ "$WORK/inst/bin" "$fo" 2>&1)
  [ "$k" = "$w" ] || { WHY="its identity resolves to [$k], not the restored window $w — a child could not report to it"; return 1; }
  SECS=$(since "$t0")
  # a person resumed the conversation by hand first (a new window, a new identity):
  # restore leaves it open once and opens no second copy
  nt kill-server 2>/dev/null
  BREAK_SOCK="$WORK/sock-rl2"                     # its own server: nothing of the first half's answers
  nt -f /dev/null new-session -d -s oc -n home -c "$WORK/emain" 'exec sleep 600'
  nt new-window -d -t oc: -n 编排 -c "$WORK/home" 'exec sleep 600'
  w=$(nt list-windows -t oc -F '#{window_id}|#{window_name}' | awk -F'|' '$2 == "编排" { print $1 }')
  [ "$(printf '%s\n' "$w" | grep -c .)" = 1 ] || { WHY="the hand-resumed setup is not one window: [$w]"; return 1; }
  nt set-option -w -t "$w" @fleet_id 1f0e0000-0000-4000-8000-000000038293
  nt set-option -w -t "$w" @cc_session_id "$sid"
  : > "$WORK/claude-argv"
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/econf" FLEET_SKIP_GLOBAL_CONF=1 \
    BREAK_SOCK="$BREAK_SOCK" SHELL=/bin/sh FLEET_RESTORE_PROBE_SECS=2 FLEET_DISK_FLOOR_GB=0 \
    bash "$WORK/inst/bin/fleet-restore.sh" >/dev/null 2>&1
  # counted by windows, not argv lines: the first half's killed wrapper may still log a late relaunch
  [ "$(nt list-windows -t oc -F x | grep -c .)" = 2 ] \
    || { WHY="restore opened the hand-resumed conversation a second time: [$(nt list-windows -t oc -F '#{window_name}' | tr '\n' ' ')]"; return 1; }
  WHAT="重启后 restore 把不绑单会话开回来、身份戳回去，孩子按身份仍找得到它；人先手动接回的，不再开第二份"
}

# ---- /loop and fleet down (issue #1846) ------------------------------------------
# A transcript in the sandbox HOME's project dir for <worktree>/<sid>: one
# successful ScheduleWakeup <secs> ago, the way Claude Code writes it.
loop_transcript() {
  local wt="$1" sid="$2" lprompt="$3" d
  d=$(HOME="$WORK/home" CLAUDE_PROJECTS_DIR='' bash -c '. "$1/fleet-lib.sh"; fleet_transcript_dir "$2"' _ "$BIN" "$wt")
  mkdir -p "$d"
  python3 - "$d/$sid.jsonl" "$lprompt" <<'PY'
import datetime, json, sys
ts = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=60)).strftime('%Y-%m-%dT%H:%M:%S.000Z')
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({'type': 'user', 'timestamp': ts, 'message': {'role': 'user', 'content': '/loop ' + sys.argv[2]}}) + '\n')
    f.write(json.dumps({'type': 'assistant', 'timestamp': ts, 'message': {'role': 'assistant', 'content': [
        {'type': 'tool_use', 'id': 'tu1', 'name': 'ScheduleWakeup',
         'input': {'delaySeconds': 1200, 'prompt': sys.argv[2], 'reason': 'next tick'}}]}}) + '\n')
    f.write(json.dumps({'type': 'user', 'timestamp': ts, 'message': {'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': 'tu1', 'content': 'scheduled'}]}}) + '\n')
PY
}

# A worker running /loop is deleted by hand: the next tick brings it back with its
# conversation AND its loop — `/loop <its input>` is the resumed session's first turn.
drill_loop_window_killed() {
  CAP=20; BREAK_SOCK="$WORK/sock-lk"; local t0 f1=1f0e0000-0000-4000-8000-0000000018b1
  mkdir -p "$WORK/gbin" "$WORK/wt-3"
  printf '#!/bin/sh\necho 0\n' > "$WORK/gbin/gh"; chmod +x "$WORK/gbin/gh"     # no merged PR
  loop_transcript "$WORK/wt-3" sid-3 '/fleet-epic-run 1851'
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'FID\t%s\n' "$f1"; printf 'WIN\tissue-3\t%s\tsid-3\t3\tlooping\t-\t-\n' "$WORK/wt-3"
  } > "$WORK/econf/fleets/oc/restore.map"
  auto
  until_ok 10 sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t oc -F '#{@fleet_id}' 2>/dev/null | grep -qx '$f1'" \
    || { WHY="the sandbox fleet never came up with the looping session"; return 1; }
  : > "$WORK/claude-argv"
  nt kill-window -t oc:issue-3                    # the break
  t0=$(now)
  auto PATH="$WORK/gbin:$WORK/tbin:$PATH"         # one diskguard tick
  until_ok "$CAP" grep -q -- '--resume sid-3' "$WORK/claude-argv" 2>/dev/null \
    || { WHY="the killed issue-3 did not come back with its conversation"; return 1; }
  grep -q -- '--resume sid-3 /loop /fleet-epic-run 1851$' "$WORK/claude-argv" \
    || { WHY="issue-3 came back without its loop: [$(tail -1 "$WORK/claude-argv")], want --resume sid-3 /loop /fleet-epic-run 1851"; return 1; }
  SECS=$(since "$t0"); WHAT="被删的 issue-3 下一拍以原对话回来，第一轮就是 /loop /fleet-epic-run 1851（节拍 60s 另计）"
}

# ---- a fleet tool call outliving the turn (issue #1880, EPIC #2074 C4) --------------
# Claude Code moves an MCP call past 120 s to a background task and the turn ends
# with the call in flight: the Stop wrote `done`, and every idle judge took the
# session (#1876, 2026-10-06: 2m44s). The fake server runs its one call as a child,
# as bin/fleet-mcp.py runs every tool; the Stop hook is the real one, on an
# isolated server. FLEET_TOOL_WAIT=0 is the red this drill was written against.
tw_env() {   # <args…> — the sandbox's hooks and lib, against sock-tw
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" BREAK_SOCK="$BREAK_SOCK" TMUX="$BREAK_SOCK,1,0" \
    FLEET_CONF_DIR="$WORK/tw/conf" FLEET_SKIP_GLOBAL_CONF=1 "$@"
}
drill_tool_wait_idle() {
  CAP=10; BREAK_SOCK="$WORK/sock-tw"; local d="$WORK/tw" w p t0 st why
  mkdir -p "$d/conf/global"
  cat > "$d/fleet-mcp.py" <<'PY'
import signal, subprocess, sys, time
child = subprocess.Popen(['sleep', '120'])                 # the call in flight
def bye(*_):
    if child.poll() is None: child.kill()
    sys.exit(0)
signal.signal(signal.SIGTERM, bye); signal.signal(signal.SIGHUP, bye)
with open(sys.argv[1], 'w') as fh: fh.write(str(child.pid))
child.wait()                                               # the call returned
time.sleep(120); bye()                                     # an idle server, no child
PY
  # The pane: Claude's empty input line (the call is running, nothing to type), the
  # fleet MCP server with its call, and an agent process (comm `claude`) under it.
  ln -sf "$(command -v sleep)" "$d/claude"
  nt -f /dev/null new-session -d -s tw -n issue-9 -x 100 -y 30 \
    "printf '\033[2J\033[H> '; python3 '$d/fleet-mcp.py' '$d/call.pid' & exec '$d/claude' 600" \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  w=$(nt display-message -p -t tw:issue-9 '#{window_id}'); p=$(nt display-message -p -t "$w" '#{pane_id}')
  nt set-option -w -t "$w" @fleet_id 11111111-2222-4333-8444-555555550009 \; set-option -w -t "$w" @issue 9 \; set-option -w -t "$w" @cc_agent claude \; \
     set-option -w -t "$w" @claude_state working \; set-option -w -t "$w" @claude_state_ts "$(( $(date +%s) - 300 ))"
  until_ok 10 test -s "$d/call.pid" || { WHY="the fake server never started its call"; return 1; }
  # break ①: the sleep tick's state reconcile (#806) reads the call's empty input line
  # as an idle prompt — no hook has stamped `working` since the call began
  mkdir -p "$d/reg"
  tw_env python3 "$BIN/fleet-state-reconcile.py" --dry-run --registry "$d/reg" --cache-dir "$d/cache" \
    --log "$d/reconcile.log" --idle-secs 5 -- tw > "$d/reconcile.out" 2>&1
  grep -q "would demote.*:$w " "$d/reconcile.out" \
    && { WHY="the state reconcile would demote the window mid-call: $(grep ":$w " "$d/reconcile.out" | head -1)"; return 1; }
  grep -q ":$w .*kept working" "$d/reconcile.log" 2>/dev/null \
    || { WHY="the reconcile neither demoted nor kept $w: $(cat "$d/reconcile.out" "$d/reconcile.log" 2>/dev/null | tail -3 | tr '\n' ' ')"; return 1; }
  # break ②: the turn ends (the Stop hook runs) while the call is still running
  printf '' | tw_env TMUX_PANE="$p" sh "$BIN/set-claude-state.sh" 'done' >/dev/null 2>&1
  st="$(o "$w" @claude_state)/$(o "$w" @claude_wait)"
  [ "$st" = looping/tool ] \
    || { WHY="the Stop during a fleet tool call left @claude_state/@claude_wait=[$st], want looping/tool — reopen, reap, sleep and the backstop would all take the session mid-wait"; return 1; }
  # the one judge that reopens an idle session refuses it even when a writer that
  # never asked stamped it `done` long ago
  printf 'claude fp-new x\n' > "$d/conf/global/agent-cfg.expected"
  nt set-option -w -t "$w" @agent_cfg fp-old \; set-option -w -t "$w" @claude_state 'done' \; set-option -w -t "$w" @claude_state_ts 1
  why=$(tw_env bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why tw "$2"' _ "$BIN" "$w")
  [ "$why" = tool ] || { WHY="cfg-restart would reopen it: fleet_cfg_restart_why said [$why], want tool"; return 1; }
  # the call returns: the next re-ask (the sleep tick's fleet-wait-reeval.sh) reads done
  nt set-option -w -t "$w" @claude_state looping \; set-option -w -t "$w" @claude_wait tool
  kill "$(cat "$d/call.pid")"; t0=$(now)
  until_ok 10 sh -c '! kill -0 "$(cat "$1")" 2>/dev/null' _ "$d/call.pid"
  tw_env bash "$BIN/fleet-wait-reeval.sh" --window "$w" tw >/dev/null 2>&1
  st="$(o "$w" @claude_state)/$(o "$w" @claude_wait)"
  [ "$st" = done/ ] || { WHY="after the call returned the re-ask left [$st], want done/"; return 1; }
  SECS=$(since "$t0"); WHAT="等工具时状态核对不降级、Stop 记 looping·tool、cfg-restart 答 tool 不重开；调用返回后重判回 done"
}

# ---- a reopen / handoff mid-scan (issue #2869) ------------------------------------
# 2026-10-10 03:46Z: a worker had its first confirmation code out for the person to
# scan, a Playwright browser holding the mini-program console login under it, when
# the ver-stale idle reopen took the process — browser and login with it; the person
# scanned three more times. The Stop hook, the reopen judge, the report and the
# re-ask are the real ones; the browser is a process carrying Playwright's argv.
hw_env() {   # <args…> — the sandbox's hooks and lib, against sock-hw
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" BREAK_SOCK="$BREAK_SOCK" TMUX="$BREAK_SOCK,1,0" \
    FLEET_CONF_DIR="$WORK/hw/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_ID_PUSH=0 "$@"
}
drill_human_step_reopen() {
  CAP=60; BREAK_SOCK="$WORK/sock-hw"; local d="$WORK/hw" w p t0 st why out
  mkdir -p "$d/conf/global" "$d/conf/fleets/hw" "$d/ms-playwright-mcp"
  printf 'FLEET_AUTO_HANDOFF_PCT=80\n' > "$d/conf/fleets/hw/conf"
  printf 'claude fp-new x\n' > "$d/conf/global/agent-cfg.expected"
  # The pane: the browser Playwright opened (its own argv, the pane's child) and the agent.
  nt -f /dev/null new-session -d -s hw -n issue-9 -x 100 -y 30 \
    "python3 -c 'import time; time.sleep(600)' --remote-debugging-pipe --user-data-dir='$d/ms-playwright-mcp/mcp-chrome-1' & exec sleep 600" \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  w=$(nt display-message -p -t hw:issue-9 '#{window_id}'); p=$(nt display-message -p -t "$w" '#{pane_id}')
  nt set-option -w -t "$w" @fleet_id 11111111-2222-4333-8444-555555550009 \; set-option -w -t "$w" @issue 9 \; set-option -w -t "$w" @cc_agent claude \; \
     set-option -w -t "$w" @claude_state working \; set-option -w -t "$w" @claude_state_ts "$(date +%s)" \; \
     set-option -w -t "$w" @ctx_pct 90
  # the browser alone already reads as a person's step
  until_ok 10 sh -c 'ps -axo command= | grep -q "[m]cp-chrome-1"' || { WHY="the fake browser never started"; return 1; }
  why=$(hw_env bash -c '. "$1/fleet-lib.sh"; fleet_window_human hw "$2"' _ "$BIN" "$w")
  [ "$why" = browser ] || { WHY="an open Playwright browser did not read as a person's step: [$why]"; return 1; }
  # the agent puts the code up: `report waiting` with the page to scan
  printf '' | hw_env TMUX_PANE="$p" bash "$BIN/fleet-report-parent.sh" --state waiting \
    --summary '请扫第 1 张确认码 https://example.invalid/qr.html' >/dev/null 2>&1
  case "$(o "$w" @human_wait)" in ''|*[!0-9]*) WHY="report waiting with a page left @human_wait=[$(o "$w" @human_wait)]"; return 1 ;; esac
  # the break ①: the turn ends at 90% context — the auto-handoff would cycle the pane
  out=$(printf '' | hw_env TMUX_PANE="$p" sh "$BIN/set-claude-state.sh" 'done' 2>/dev/null)
  case "$out" in *'"decision":"block"'*) WHY="the Stop nudged a handoff while the person was scanning: $out"; return 1 ;; esac
  st="$(o "$w" @claude_state)/$(o "$w" @claude_wait)/$(o "$w" @handoff_armed)"
  [ "$st" = looping/human/ ] || { WHY="the Stop left state/wait/armed=[$st], want looping/human/"; return 1; }
  grep -q '"hold": "handoff".*"wid": "'"$w"'"' "$d/conf/logs/attention.ndjson" 2>/dev/null \
    || { WHY="the held handoff left no attention line: $(tail -1 "$d/conf/logs/attention.ndjson" 2>/dev/null)"; return 1; }
  # the break ②: the ver-stale idle reopen, even on a window stamped `done` long ago
  nt set-option -w -t "$w" @agent_cfg fp-old \; set-option -w -t "$w" @claude_state 'done' \; set-option -w -t "$w" @claude_state_ts 1
  why=$(hw_env bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why hw "$2"' _ "$BIN" "$w")
  [ "$why" = human ] || { WHY="cfg-restart would reopen it mid-scan: fleet_cfg_restart_why said [$why], want human"; return 1; }
  # the step is done: the agent's next report — the browser still open, the report decides
  nt set-option -w -t "$w" @claude_state looping \; set-option -w -t "$w" @claude_wait human \; \
     set-option -w -t "$w" @claude_state_ts "$(date +%s)"
  t0=$(now)
  printf '' | hw_env TMUX_PANE="$p" bash "$BIN/fleet-report-parent.sh" --state waiting \
    --summary 'step done, carrying on' >/dev/null 2>&1
  [ "$(o "$w" @human_wait)" = off ] || { WHY="the next report left @human_wait=[$(o "$w" @human_wait)], want off"; return 1; }
  hw_env bash "$BIN/fleet-wait-reeval.sh" --window "$w" hw >/dev/null 2>&1
  st="$(o "$w" @claude_state)/$(o "$w" @claude_wait)"
  [ "$st" = done/ ] || { WHY="after the step the re-ask left [$st], want done/"; return 1; }
  nt set-option -w -t "$w" @claude_state working
  out=$(printf '' | hw_env TMUX_PANE="$p" sh "$BIN/set-claude-state.sh" 'done' 2>/dev/null)
  case "$out" in *'"decision":"block"'*) ;; *) WHY="after the step the Stop at 90% nudged no handoff: [$out]"; return 1 ;; esac
  [ "$(o "$w" @handoff_armed)" = 1 ] || { WHY="the handoff nudge left no @handoff_armed latch"; return 1; }
  SECS=$(since "$t0"); WHAT="扫码中：Stop 记 looping·human、不接力（attention 记一行）、cfg-restart 答 human 不重开；report 标完成后下一次 Stop 即接力"
}

# ---- a config reopen dropping a /loop and a ship (issue #2189) ---------------------
# 2026-10-07: a skill landed in ~/.claude/skills, every idle session was reopened
# onto the new configuration, and scratch-4's ScheduleWakeup (03:38) died with the
# old process — its @loop had never been stamped, so the judge read plain `done`;
# four workers with a green PR came back at a bare prompt and nobody merged. The
# judge is the real one on an isolated server, the transcript the session's own;
# the notice is the real migrate's.
drill_cfg_reopen_loop() {
  CAP=10; BREAK_SOCK="$WORK/sock-cl"; local d="$WORK/cl" w t0 why n sid=c1a00000-0000-4000-8000-000000002189
  mkdir -p "$d/conf/global" "$d/wt"
  printf 'claude fp-new x\n' > "$d/conf/global/agent-cfg.expected"
  loop_transcript "$d/wt" "$sid" 'check CI'
  nt -f /dev/null new-session -d -s cl -n issue-5 -x 100 -y 30 'exec sleep 600' \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  w=$(nt display-message -p -t cl:issue-5 '#{window_id}')
  # the break: an idle worker on an old configuration, a Loop pending in its
  # transcript but no @loop (the hook never saw the ScheduleWakeup), a PR open
  nt set-option -w -t "$w" @agent_cfg fp-old \; set-option -w -t "$w" @claude_state 'done' \; \
     set-option -w -t "$w" @claude_state_ts 1 \; set-option -w -t "$w" @cc_session_id "$sid" \; \
     set-option -w -t "$w" @issue 5 \; set-option -w -t "$w" @pr_num '#55'
  t0=$(now)
  why=$(env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" BREAK_SOCK="$BREAK_SOCK" TMUX="$BREAK_SOCK,1,0" \
          FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
          bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why cl "$2"' _ "$BIN" "$w")
  [ "$why" = looping ] \
    || { WHY="cfg-restart would reopen it and drop the pending /loop: fleet_cfg_restart_why said [$why], want looping"; return 1; }
  case "$(o "$w" @loop)" in *kind=wakeup*) ;; *) WHY="the judge read the Loop but left no @loop: [$(o "$w" @loop)]"; return 1 ;; esac
  # the Loop over, the session is reopened: a worker with its PR still open is told
  # to carry the ship on, never "nothing to act on"
  n=$(bash -c 'set -u; . "$1/fleet-migrate.sh"; cfg_update_nudge "" "" cfg-stale "$2"' _ "$BIN" "$(o "$w" @pr_num)")
  case "$n" in *"Your PR #55 is still open"*"continue the ship"*) ;;
    *) WHY="a worker mid-ship is reopened with [$n] — it would park at the prompt with its PR unmerged"; return 1 ;; esac
  SECS=$(since "$t0"); WHAT="没盖 @loop 的 /loop 会话：judge 读原对话答 looping、补上 @loop、不重开；有开着 PR 的 worker 重开提示是续 ship"
}

# pty_run <answer> <command…> — run it on a terminal, type <answer>⏎ at the
# first prompt; the screen goes to $WORK/pty.out, the exit status is ours.
pty_run() {
  python3 - "$@" > "$WORK/pty.out" 2>&1 <<'PY'
import os, pty, select, sys, time
answer, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
out, sent, end = b'', False, time.time() + 20
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: data = os.read(fd, 4096)
        except OSError: break
        if not data: break
        out += data
    if not sent and ('确认'.encode() in out and out.rstrip().endswith(b':') or out.rstrip().endswith('：'.encode())):
        os.write(fd, answer.encode() + b'\r'); sent = True
sys.stdout.write(out.decode('utf-8', 'replace'))
_, st = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(st) if hasattr(os, 'waitstatus_to_exitcode') else st >> 8)
PY
}

# fleet down asks first (a terminal: type the fleet's name; a script: --yes) and
# keeps the map it is about to lose; `fleet up --undo` brings every session back.
drill_fleet_down_confirm() {
  CAP=20; BREAK_SOCK="$WORK/sock-fd"; local t0 rc wins f1=1f0e0000-0000-4000-8000-0000000018c1 f2=1f0e0000-0000-4000-8000-0000000018c2
  local fenv="PATH=$WORK/tbin:$PATH HOME=$WORK/home FLEET_CONF_DIR=$WORK/econf FLEET_SKIP_GLOBAL_CONF=1 BREAK_SOCK=$BREAK_SOCK SHELL=/bin/sh FLEET_RESTORE_PROBE_SECS=2 FLEET_DISK_FLOOR_GB=0"
  grep -q 'fleet-restore.sh.*--undo' "$BIN/fleet-up.sh" 2>/dev/null \
    || { WHY="fleet-up.sh has no --undo (it should hand it to fleet-restore.sh --undo)"; return 1; }
  rm -f "$WORK/econf/fleets/oc/restore.down" "$WORK/econf/fleets/oc"/restore.map.*
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'FID\t%s\n' "$f1"; printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
    printf 'FID\t%s\n' "$f2"; printf 'WIN\tissue-2\t%s\tsid-2\t2\tdone\t-\t-\n'    "$WORK/wt-2"
  } > "$WORK/econf/fleets/oc/restore.map"
  env $fenv bash "$WORK/inst/bin/fleet-restore.sh" >/dev/null 2>&1
  until_ok 10 sh -c "[ \"\$('$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t oc -F '#{@fleet_id}' 2>/dev/null | grep -c .)\" = 2 ]" \
    || { WHY="the sandbox fleet never came up with both sessions"; return 1; }
  # their hooks stamp the session id; the conversation is on disk (the snapshot keeps an id only then)
  nt set-option -w -t oc:issue-1 @cc_session_id sid-1; nt set-option -w -t oc:issue-2 @cc_session_id sid-2
  loop_transcript "$WORK/wt-1" sid-1 x; loop_transcript "$WORK/wt-2" sid-2 x
  nt set-option -w -t oc:issue-1 @claude_state working; nt set-option -w -t oc:issue-2 @claude_state 'done'
  # 1. a script, no --yes: nothing goes down, and it says what would have
  env $fenv bash "$WORK/inst/bin/fleet-down.sh" oc </dev/null > "$WORK/fd.out" 2>&1; rc=$?
  [ "$rc" != 0 ] || { WHY="fleet-down with no terminal and no --yes went ahead (exit 0)"; return 1; }
  nt has-session -t oc 2>/dev/null || { WHY="fleet-down with no confirmation took the fleet down"; return 1; }
  grep -q 'issue-1' "$WORK/fd.out" && grep -q 'issue-2' "$WORK/fd.out" && grep -q -- '--yes' "$WORK/fd.out" \
    || { WHY="the refusal does not list the sessions and --yes: [$(tr '\n' ' ' < "$WORK/fd.out")]"; return 1; }
  # 2. a terminal, the wrong name: nothing goes down
  pty_run nope env $fenv bash "$WORK/inst/bin/fleet-down.sh" oc; rc=$?
  [ "$rc" != 0 ] && nt has-session -t oc 2>/dev/null \
    || { WHY="a wrong name at the prompt still took the fleet down (exit $rc): [$(tr '\n' ' ' < "$WORK/pty.out")]"; return 1; }
  grep -q '确认' "$WORK/pty.out" || { WHY="no confirmation prompt on a terminal: [$(tr '\n' ' ' < "$WORK/pty.out")]"; return 1; }
  # 3. --yes: down, the map kept aside
  env $fenv bash "$WORK/inst/bin/fleet-down.sh" oc --yes </dev/null >/dev/null 2>&1
  nt has-session -t oc 2>/dev/null && { WHY="fleet-down --yes left the fleet up"; return 1; }
  ls "$WORK/econf/fleets/oc"/restore.map.down-* >/dev/null 2>&1 || { WHY="fleet-down kept no restore.map.down-<time>"; return 1; }
  # 4. fleet up --undo: every session back, on its own conversation
  : > "$WORK/claude-argv"
  t0=$(now)
  env $fenv bash "$WORK/inst/bin/fleet-up.sh" --undo >/dev/null 2>&1
  until_ok "$CAP" sh -c "grep -q -- '--resume sid-1' '$WORK/claude-argv' && grep -q -- '--resume sid-2' '$WORK/claude-argv'" \
    || { WHY="--undo did not resume both sessions: [$(tr '\n' ' ' < "$WORK/claude-argv")] $(grep -i undo "$WORK/econf/restore/restore.log" 2>/dev/null | tail -2 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  wins=$(nt list-windows -t oc -F '#{window_name}' | sort | tr '\n' ' ')
  [ "$wins" = "home issue-1 issue-2 " ] || { WHY="after --undo the fleet has [$wins], want [home issue-1 issue-2 ]"; return 1; }
  [ "$(o oc:issue-1 @fleet_id)" = "$f1" ] || { WHY="issue-1 came back with another identity [$(o oc:issue-1 @fleet_id)]"; return 1; }
  [ -e "$WORK/econf/fleets/oc/restore.down" ] && { WHY="--undo left restore.down: --auto would never bring it back again"; return 1; }
  [ -e "$WORK/econf/restore/autorestore.off" ] && { WHY="--undo left auto-restore off"; return 1; }
  WHAT="不确认不关（脚本无 --yes、终端输错名字）；--yes 关后 fleet up --undo 两个会话都以原对话回来"
}

# The certificate drills use an isolated home and cache, without a client UI.
cert_env() {
  export HOME="$WORK/chome" XDG_CONFIG_HOME="$WORK/chome/.config" XDG_CACHE_HOME="$WORK/chome/.cache"
  export FLEET_CONF_DIR="$WORK/chome/.config/claude-fleet" FLEET_SHELL_CACHE="$WORK/ccache"
  export FLEET_NODE_STATE="$WORK/chome/no-node"   # not a managed login (#4594), whatever this machine is
  unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN
  mkdir -p "$HOME/.ssh" "$FLEET_CONF_DIR"
}

# The hub refuses this machine's certificate (issue #2112): a key id its roster
# no longer names (the 2026-10-04 move to gh:<id>), an expired certificate. The
# hub is UP — /healthz 200 — and answers 401; before, the bar said 入口连不上 and
# sent the person after the network. A fake hub answering 401 「names no one」,
# the REAL lease → where chain (the retired badge is no longer involved).
# cert_hub <dir> <secs> — a fake hub: /v1/fleet/login/renew signs a fresh 12-hour
# certificate with <dir>/ca; /v1/fleet/client answers 401 「names no one」 while
# <dir>/orphan exists, else 404 (no lease door). Its port lands in <dir>/port.
cert_hub() {
  cat > "$1/hub.py" <<'PY'
import json, os, signal, subprocess, sys, tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
D = sys.argv[1]; signal.alarm(int(sys.argv[2]))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        open(os.path.join(D, "log"), "a").write(self.path + "\n")
        if self.path == "/v1/fleet/login/renew":
            t = tempfile.mkdtemp(dir=D)
            open(os.path.join(t, "k.pub"), "w").write(body["public_key"] + "\n")
            subprocess.run(["ssh-keygen", "-q", "-s", os.path.join(D, "ca"), "-I", "person:gh:1", "-n", "dave",
                            "-V", "-1m:+12h", os.path.join(t, "k.pub")], check=True)
            return self.reply(200, {"certificate": open(os.path.join(t, "k-cert.pub")).read(), "principals": ["dave"],
                                    "valid_before": "", "ssh_config": "# test\n"})
        if self.path.startswith("/v1/fleet/client") and os.path.exists(os.path.join(D, "orphan")):
            return self.reply(401, {"error": "connection certificate refused: its key id names no one this hub knows"})
        self.reply(404, {})
    do_GET = lambda self: self.reply(404, {})
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port.tmp"), "w").write(str(srv.server_address[1])); os.replace(os.path.join(D, "port.tmp"), os.path.join(D, "port"))
srv.serve_forever()
PY
  [ -f "$1/ca" ] || ssh-keygen -q -t ed25519 -N '' -f "$1/ca"
  rm -f "$1/port"
  python3 "$1/hub.py" "$1" "$2" 2>"$1/hub.err" & CHUB_PID=$!
  for _ in $(seq 1 300); do [ -s "$1/port" ] && break; sleep 0.1; done
  [ -s "$1/port" ]
}
drill_hub_refused_cert() {
  CAP=15; local t0 sc="$WORK/hrc" port wj
  mkdir -p "$sc"; : > "$sc/orphan"
  cert_hub "$sc" 60 || { kill "$CHUB_PID" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$sc/hub.err")"; return 1; }
  read -r port < "$sc/port"
  t0=$(now)
  wj=$( cert_env; export FLEET_HUB_URL="http://127.0.0.1:$port" FLEET_HUB_TOKEN=tok
        unset CCQUOTA_TOKEN CCQUOTA_HUB_URL; bash "$BIN/fleet-client-where.sh" --json 2>&1 )
  SECS=$(since "$t0")
  kill "$CHUB_PID" 2>/dev/null; wait "$CHUB_PID" 2>/dev/null
  case "$wj" in *'"hub": "refused"'*) ;; *) WHY="where --json does not say refused: [$wj]"; return 1 ;; esac
  WHAT="入口回 401「names no one」：where 报 hub refused，和入口断网分开"
}



# No client open for 12 hours (issue #3455): only an open client's keeper (#2112)
# or a new `fleet` renewed the connection certificate, so a hosting login nobody
# opened a client on woke to an expired one — the doctor's cert row red, the
# person's cross-machine ssh refused. #3455 renewed it on the diskguard tick;
# #3701 renews it only when USED. An EXPIRED certificate, no client at all: the
# doctor says PASS 已过期 · 用到时续 (never red), the hosting login's tick
# (`fleet-diskguard.sh --cert`) renews nothing, and the person's ssh to a fleet
# machine — through the `Match exec` fleet-login.py writes — renews it by the
# device key first: login.log says why=ssh, the row shows the time left.
drill_cert_expiry_no_client() {
  CAP=20; local t0 sc="$WORK/cenc" port left cc
  mkdir -p "$sc"; rm -f "$sc/orphan" "$sc/log"
  cert_hub "$sc" $((CAP * 2 + 60)) || { kill "$CHUB_PID" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$sc/hub.err")"; return 1; }
  read -r port < "$sc/port"
  ( cert_env; mkdir -p "$HOME/.ssh"; rm -f "$HOME/.ssh/fleet-cert" "$HOME/.ssh/fleet-cert.pub" "$HOME/.ssh/fleet-cert-cert.pub" \
      "$FLEET_CONF_DIR/cert-renew.last" "$FLEET_CONF_DIR/diskguard/cert-renew.last" "$FLEET_SHELL_CACHE/logs/login.log"
    ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/fleet-cert"
    ssh-keygen -q -s "$sc/ca" -I person:gh:1 -n dave -V -13h:-1h "$HOME/.ssh/fleet-cert.pub" )
  cc=$( cert_env; FLEET_HUB_URL='' python3 "$BIN/fleet-connect.py" --cert-check )
  case "$cc" in "PASS"$'\t'*已过期*用到时*) ;; *) kill "$CHUB_PID" 2>/dev/null; WHY="an expired, unused certificate is not the doctor's PASS 已过期 · 用到时续: [$cc]"; return 1 ;; esac
  # the tick renews nothing any more
  ( cert_env; FLEET_HUB_URL="http://127.0.0.1:$port" bash "$BIN/fleet-diskguard.sh" --cert ) >/dev/null 2>&1
  if [ -s "$sc/log" ]; then
    kill "$CHUB_PID" 2>/dev/null; WHY="the diskguard tick still asked the hub: $(tr '\n' ' ' < "$sc/log")"; return 1
  fi
  # the use: ssh to a fleet machine, through the section fleet-login.py writes
  ( cert_env; python3 - "$BIN/fleet-login.py" > "$sc/ssh_config" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fleet_login", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.stdout.write(m.use_section([("m1.example", "m1")]) + "Host m1 fleet-m1\n  HostName 192.0.2.10\n")
PY
  )
  t0=$(now)
  ( cert_env; FLEET_HUB_URL="http://127.0.0.1:$port" ssh -F "$sc/ssh_config" -G fleet-m1 ) >/dev/null 2>&1
  SECS=$(since "$t0")
  kill "$CHUB_PID" 2>/dev/null; wait "$CHUB_PID" 2>/dev/null
  left=$( cert_env; python3 "$BIN/fleet-login.py" check ); left=${left#valid }
  case "$left" in ''|*[!0-9.]*) left=0 ;; esac
  [ "${left%.*}" -gt 39600 ] || { WHY="ssh to a fleet machine did not renew an expired certificate first (left ${left}s; hub saw: $(tr '\n' ' ' 2>/dev/null < "$sc/log"))"; return 1; }
  grep -q 'why=ssh' "$WORK/ccache/logs/login.log" 2>/dev/null || { WHY="login.log does not say why=ssh: $(tail -2 "$WORK/ccache/logs/login.log" 2>/dev/null)"; return 1; }
  cc=$( cert_env; FLEET_HUB_URL='' python3 "$BIN/fleet-connect.py" --cert-check )
  case "$cc" in "PASS"$'\t'*" · 剩 11h"*) ;; *) WHY="the renewed certificate's row does not say the time left: [$cc]"; return 1 ;; esac
  WHAT="没开客户端、证书已过期：doctor 报 PASS「已过期 · 用到时续」，diskguard 一拍不再续；ssh 到 fleet 机器前用设备钥匙续成 12 小时（login.log why=ssh），cert 行写「剩 11h…」"
}

# A reconnect onto the SAME view id while the last connection's attach is still
# half alive (issue #1907, mac-a 2026-10-06): the far end's old attach still held
# `<fleet>@view-<id>`, the new one's `new-session` failed and it fell back to a
# plain client of the fleet session — the node's own status line under the
# header, its prefix live — and the old one's exit then removed the NEW
# registration. Since T606 only the 看台 attaches (`attach --thin`); the drill: a
# node fleet on an isolated socket, a first `attach --thin --view V1` that never
# leaves, a second with the same id; the old attach goes, the second sits in the
# SAME 看台 session (its top line on), nobody on the fleet session, the row its.
vr_env() {
  # FLEET_VIEW_FIRST_CMD: a 看台 with nowhere to land records ⌘N's road, opens nothing
  printf 'env -u TMUX -u TMUX_PANE TMUX_TMPDIR=%s FLEET_CONF_DIR=%s HOME=%s PATH=%s FLEET_VIEW_FIRST_CMD=true' \
    "$WORK/vt" "$WORK/vr/conf" "$WORK/vr" "${REAL_TMUX%/*}:/usr/bin:/bin"
}
vr() { TMUX_TMPDIR="$WORK/vt" "$REAL_TMUX" -L "$1" "${@:2}"; }
vr_clients() { vr vrn list-clients -F '#{client_session}' 2>/dev/null | sort | tr '\n' ' '; }
vr_pid() { cut -f5 "$WORK/vr/conf/remote-views/$1" 2>/dev/null; }
vr_view_reconnect() {
  CAP=5; local t0 one s gid
  mkdir -p "$WORK/vt" "$WORK/vr/conf/fleets/vrn"
  : > "$WORK/vr/conf/fleets/vrn/conf"
  fx_repo "$WORK/vr/conf" "vrn" acme/app FLEET_MAIN="$WORK/vr"
  vr vrn -f /dev/null new-session -d -s vrn -n home -x 100 -y 20 'exec sleep 600' || { WHY="no node server"; return 1; }
  vr vrc -f /dev/null new-session -d -s vrc -n t1 -x 100 -y 20 \
    "$(vr_env) bash $BIN/fleet-remote-view.sh attach --thin --view V1 --device e30= --route lan --token t1; exec sleep 600"
  until_ok 5 sh -c "[ \"\$(TMUX_TMPDIR='$WORK/vt' '$REAL_TMUX' -L vrn list-clients -F '#{client_session}')\" = 'vrn@view-V1' ]" \
    || { WHY="the first attach never sat in its 看台: [$(vr_clients)]"; return 1; }
  one=$(vr_pid V1); gid=$(vr vrn display-message -p -t '=vrn@view-V1:' '#{session_id}')
  t0=$(now)
  # the reconnect: the same view id, while the first attach still holds it
  vr vrc new-window -d -t vrc: -n t2 "$(vr_env) bash $BIN/fleet-remote-view.sh attach --thin --view V1 --resume --device e30= --route lan --token t2; exec sleep 600"
  until_ok "$CAP" sh -c "two=\$(cut -f5 '$WORK/vr/conf/remote-views/V1' 2>/dev/null); [ -n \"\$two\" ] && [ \"\$two\" != '$one' ] \
      && [ \"\$(TMUX_TMPDIR='$WORK/vt' '$REAL_TMUX' -L vrn list-clients -F '#{client_session}')\" = 'vrn@view-V1' ]" \
    || { WHY="after the reconnect the node's clients are [$(vr_clients)] (want one, on vrn@view-V1), row pid $(vr_pid V1) (first was $one)"; return 1; }
  SECS=$(since "$t0")
  s=$(vr vrn display-message -p -t '=vrn@view-V1:' '#{session_id} #{status}')
  [ "$s" = "$gid on" ] || { WHY="the resumed 看台 is [$s], want the same session [$gid] with its top line on"; return 1; }
  kill -0 "$one" 2>/dev/null && { WHY="the first attach ($one) is still alive beside the second"; return 1; }
  # the second leaves: its row says since when, the 看台 stays to be resumed
  vr vrc kill-window -t vrc:t2
  until_ok 5 sh -c "grep -q 'left=' '$WORK/vr/conf/remote-views/V1' 2>/dev/null" \
    || { WHY="the second's exit wrote no left= on its row ($(cat "$WORK/vr/conf/remote-views/V1" 2>/dev/null))"; return 1; }
  # An orphan: a registered attach whose tmux client the server no longer has
  # (its line died, the client hangs in a tty write — here an old plain attach
  # still running from before T606). `health` counts it, the next attach reaps
  # it and its row.
  mkdir -p "$WORK/vr/fake"; printf 'sleep 600\n' > "$WORK/vr/fake/fleet-remote-view.sh"
  bash "$WORK/vr/fake/fleet-remote-view.sh" attach - V9 >/dev/null 2>&1 </dev/null & one=$!
  printf '/dev/ttys999\tvrn\tshell\t%s\t%s\n' "$(date +%s)" "$one" > "$WORK/vr/conf/remote-views/V9"
  # health finds an attach by its argv: not before the fork has exec'd it (#4299)
  until_ok 5 sh -c "ps -o args= -p $one 2>/dev/null | grep -q 'fleet-remote-view.sh attach'" || :
  s=$(eval "$(vr_env) FLEET_REMOTE_ORPHAN_SECS=0 bash $BIN/fleet-remote-view.sh health" 2>&1)
  [ "$s" = "shared=0 orphans=1" ] || { pkill -P "$one"; kill "$one" 2>/dev/null; WHY="health with one orphan says [$s]"; return 1; }
  vr vrc new-window -d -t vrc: -n t3 "$(vr_env) FLEET_REMOTE_ORPHAN_SECS=0 bash $BIN/fleet-remote-view.sh attach --thin --view V3 --device e30= --route lan --token t3; exec sleep 600"
  until_ok 5 sh -c "! kill -0 $one 2>/dev/null && [ ! -e '$WORK/vr/conf/remote-views/V9' ]" \
    || { pkill -P "$one"; kill "$one" 2>/dev/null; WHY="the next attach left the orphan ($one) or its row"; return 1; }
  wait "$one" 2>/dev/null
  s=$(eval "$(vr_env) bash $BIN/fleet-remote-view.sh health" 2>&1)
  [ "$s" = "shared=0 orphans=0" ] || { WHY="health after the reap says [$s]"; return 1; }
  WHAT="同一 view id 重连：旧 attach 收掉，新的接回同一个看台会话（顶栏开着），无人挂在 fleet 会话上；孤儿 attach 下一次 attach 收掉"
}
drill_view_reconnect_shared() {
  local rc; vr_view_reconnect; rc=$?
  vr vrc kill-server 2>/dev/null; vr vrn kill-server 2>/dev/null
  return $rc
}



# A client whose node login is not the name of the computer it sits at (issue
# #2397): cj's sidebar read 「No sessions」 while the hub listed his five sessions.
# The code before #2390 kept only rows whose os_user was `id -un`, and stored the
# hub's ETag beside the empty cache it mapped; the client updated past #2390, but
# every round after sent that ETag back, the hub's answer for his scope had not
# moved (no heartbeat in it), and each 304 kept the empty list. The sandbox: the
# real fleet-hub-sessions.sh on a home machine over a connection certificate, a curl
# that answers 304 to the stored ETag and the body otherwise, and the old code's
# leftovers on disk — an empty cache and a bare ETag.
drill_client_other_login_empty_list() {
  CAP=10; local sc="$WORK/cole" t0 out F=22222222-2222-4222-8222-222222222222 S=cole
  mkdir -p "$sc/bin" "$sc/home/.ssh" "$sc/conf/fleets/$S" "$sc/t/.claude-dash/global"
  : > "$sc/conf/fleets/$S/conf"
  fx_repo "$sc/conf" "$S" acme/app
  cat > "$sc/sessions.json" <<EOF
{"sessions": [{"worker_id": "$F/issue-7", "machine_name": "mac-b", "os_user": "nodelogin", "availability": "online",
  "worker": {"issue": 7, "repo": "acme/app", "state": "done", "agent": "claude", "name": "cj-row", "needs": ""}}],
 "nodes": [{"machine_name": "mac-b", "availability": "online", "sessions": 1}]}
EOF
  # curl: 304 to If-None-Match "E1", else the body with ETag "E1"
  cat > "$sc/bin/curl" <<SHIM
#!/bin/sh
out='' hdr='' inm=''
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift ;; -D) hdr=\$2; shift ;; -H) case "\$2" in If-None-Match:*) inm=\${2#If-None-Match: } ;; esac; shift ;; esac
  shift
done
printf '%s\n' "\${inm:--}" >> '$sc/inm.log'
[ -n "\$hdr" ] && printf 'HTTP/1.1 200 OK\r\nETag: "E1"\r\n\r\n' > "\$hdr"
if [ "\$inm" = '"E1"' ]; then printf 304; exit 0; fi
[ -n "\$out" ] && cat '$sc/sessions.json' > "\$out"
printf 200
SHIM
  chmod +x "$sc/bin/curl"
  ssh-keygen -q -t ed25519 -N '' -f "$sc/ca" >/dev/null 2>&1
  ssh-keygen -q -t ed25519 -N '' -f "$sc/home/.ssh/fleet-cert" >/dev/null 2>&1
  ssh-keygen -q -s "$sc/ca" -I 'gh:cj' -n nodelogin -V '-5m:+1h' "$sc/home/.ssh/fleet-cert.pub" >/dev/null 2>&1 \
    || { WHY="could not sign a sandbox certificate"; return 1; }
  # the break: what the code before #2390 left on disk — its empty cache, the bare ETag
  printf '#ts\037%s\n' "$(date +%s)" > "$sc/t/.claude-dash/global/remote_$S"
  printf '"E1"\n' > "$sc/t/.claude-dash/global/hubsess.etag"
  date +%s > "$sc/t/.claude-dash/global/hub_ok"
  t0=$(now)
  out=$( unset CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_CMD FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_LOCAL \
               FLEET_NODE_ALIASES FLEET_HUB_URL FLEET_CERT XDG_CONFIG_HOME TMUX TMUX_PANE
         export PATH="$sc/bin:$PATH" HOME="$sc/home" TMPDIR="$sc/t" FLEET_CONF_DIR="$sc/conf" FLEET_SKIP_GLOBAL_CONF=1 \
                CCQUOTA_FLEET=1 CCQUOTA_HUB_URL=http://hub.test FLEET_HUB_SESSIONS_USER='*'
         bash "$BIN/fleet-hub-sessions.sh" --refresh >/dev/null 2>&1
         cat "$TMPDIR/.claude-dash/global/remote_$S" 2>/dev/null )
  SECS=$(since "$t0")
  case "$out" in *"wid:$F/issue-7"*) ;;
    *) WHY="the list stayed empty — the client sent [$(tr '\n' ' ' < "$sc/inm.log")] and kept the old mapping's cache: [$(printf '%s' "$out" | tr '\037\n' '| ')]"; return 1 ;;
  esac
  WHAT="客户端换版后，旧代码存下的 ETag 不再拿去问入口：入口回全量，按新代码重新映射，节点登录名≠本机用户名的会话回到侧栏"
}

# ============================================ a fleet's tmux, deleted from a shell ======
# (issue #1841, EPIC #1851 C2) A fleet is `-L <its label>` since #159, so the old
# guard's "a -L means an isolated test server" let every fleet through; and only an
# interactive zsh that sourced cw.zsh had a guard at all — a session's `bash -c`,
# `sh -c`, Codex's shell, Claude's `!` went straight to tmux. The sandbox: a fleet
# `kf` (its conf in a sandbox FLEET_CONF_DIR) on a -L label under a sandbox
# TMUX_TMPDIR, one session window (@fleet_id) beside home, and the real
# fleet-session-wrap.sh launching a fake agent that types the deletes.
kf_env() {
  export FLEET_CONF_DIR="$WORK/kconf" TMUX_TMPDIR="$WORK/ktt" ZDOTDIR="$WORK/kzd"
  unset TMUX TMUX_PANE FLEET_ALLOW_TMUX_DESTROY FLEET_HUB
  mkdir -p "$FLEET_CONF_DIR/fleets/kf" "$TMUX_TMPDIR" "$ZDOTDIR"
  : > "$FLEET_CONF_DIR/fleets/kf/conf"
  fx_repo "$FLEET_CONF_DIR" "kf" acme/widgets
  "$REAL_TMUX" -L kf has-session -t kf 2>/dev/null && return 0
  "$REAL_TMUX" -L kf new-session -d -s kf -n home 'exec sleep 600' \
    && "$REAL_TMUX" -L kf new-window -d -t kf -n issue-7 'exec sleep 600' \
    && "$REAL_TMUX" -L kf set-option -w -t kf:issue-7 @fleet_id 7f7f7f7f
}
kf_up() { "$REAL_TMUX" -L kf has-session -t kf 2>/dev/null && [ "$("$REAL_TMUX" -L kf list-windows -t kf -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' ')" = "home issue-7 " ]; }
# kf_agent <script> — run <script> (bash) as the agent the real wrapper launches
kf_agent() {
  printf '#!/bin/bash\n%s\n' "$1" > "$WORK/kagent"; chmod +x "$WORK/kagent"
  FLEET_WRAP_LAUNCH="$WORK/kagent" FLEET_MCP=0 bash "$BIN/fleet-session-wrap.sh" 2>&1
}

drill_shell_kill_fleet() {
  CAP=30; local t0 out sh cmd
  t0=$(now)
  ( kf_env
    for sh in 'bash -c' 'sh -c' 'zsh -fc'; do
      command -v "${sh%% *}" >/dev/null 2>&1 || continue      # no zsh on a linux runner
      for cmd in 'tmux -L kf kill-server' 'tmux -L kf kill-session -t kf' 'tmux -L kf kill-window -t kf:issue-7' \
                 "tmux -S $TMUX_TMPDIR/tmux-$(id -u)/kf kill-server"; do
        out=$(kf_agent "$sh '$cmd'")
        kf_up || { echo "WHY=$sh '$cmd' deleted it: [$out]"; exit 1; }
        case "$out" in *拒绝*FLEET_ALLOW_TMUX_DESTROY=1*) ;; *) echo "WHY=$sh '$cmd' gave no reason/hatch: [$out]"; exit 1 ;; esac
      done
    done
    # the test server and a non-session window are not the fleet's
    "$REAL_TMUX" -L "kscr$$" new-session -d -s s 'exec sleep 600'
    out=$(kf_agent "bash -c 'tmux -L kscr$$ kill-server'")
    "$REAL_TMUX" -L "kscr$$" has-session 2>/dev/null && { echo "WHY=-L kscr$$ kill-server was not let through: [$out]"; exit 1; }
    "$REAL_TMUX" -L kf new-window -d -t kf -n scratchpad 'exec sleep 600'
    out=$(kf_agent "bash -c 'tmux -L kf kill-window -t kf:scratchpad'")
    kf_up || { echo "WHY=a plain window's kill-window was refused or took more: [$out]"; exit 1; }
    # the Bash tool (Claude's and Codex's): hooks/bash-guard.py says the same,
    # before it runs — a login shell's path_helper puts the real tmux back in front
    for cmd in 'tmux -L kf kill-server' "bash -lc 'tmux -L kf kill-server'" \
               "zsh -lc \"echo hi; tmux -L kf kill-session -t kf\"" "${REAL_TMUX} -L kf kill-window -t kf:issue-7"; do
      out=$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$cmd" \
            | python3 "$ROOT/hooks/bash-guard.py" 2>&1)
      [ $? = 2 ] || { echo "WHY=bash-guard let [$cmd] through: [$out]"; exit 1; }
    done
    out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"tmux -L scratch kill-server"}}' | python3 "$ROOT/hooks/bash-guard.py" 2>&1)
    [ $? = 0 ] || { echo "WHY=bash-guard refused -L scratch: [$out]"; exit 1; }
    # the escape hatch, last: it really deletes
    out=$(FLEET_ALLOW_TMUX_DESTROY=1 kf_agent "bash -c 'tmux -L kf kill-server'")
    "$REAL_TMUX" -L kf has-session 2>/dev/null && { echo "WHY=FLEET_ALLOW_TMUX_DESTROY=1 did not let it through: [$out]"; exit 1; }
    exit 0
  ) > "$WORK/kf.out"; local rc=$?
  [ "$rc" = 0 ] || { WHY=$(sed -n 's/^WHY=//p' "$WORK/kf.out" | head -1); WHY=${WHY:-"the drill died (rc $rc)"}; return 1; }
  SECS=$(since "$t0"); WHAT="bash / sh / zsh -c / 登录 shell / Bash 工具里删 fleet 都被拒，-L 测试服务器和逃生口放行"
}

# conf-keys-lost (issue #1887): the machine's fleet.conf carries a key a person
# added ([client] FLEET_UI_LANG=zh) on a laptop that only coordinates — a fleet
# conf fleet-up left behind, no node.env, no fleet running. A sync runs
# install-apply's two passes, layout then conf. Before the fix the layout pass
# took fleet.conf for fleet `fleet`'s stale duplicate and deleted it, the conf
# pass rebuilt it from its template — the key gone, no backup — and called the
# machine 承载 (FLEET_HOST=1) for its leftover fleet conf. Now: the key stays,
# hub-defaults.conf stays where the shell reads it, a migrated FLEET_HOST=1 goes
# to 0 once with the old file kept as .bak-<time>; an old FLEET_ROLE="client,node"
# on a node.env COMPUTE=0 machine becomes FLEET_HOST=0 with its keys and a backup;
# a real host (node.env, no COMPUTE line) keeps FLEET_HOST=1.
drill_conf_keys_lost() {
  CAP=5; local t0 d="$WORK/ck" c out
  ck() {   # <case> <cmd…> — one sandbox login per case
    local h="$d/$1"; shift
    env -u TMUX HOME="$h/home" FLEET_CONF_DIR="$h/conf" XDG_CONFIG_HOME="$h/home/.config" \
      FLEET_LAUNCHD_AGENTS_DIR="$h/home/LA" FLEET_INSTALL_DAEMON_DIR="$h/home/LD" \
      TMUX_TMPDIR="$h/tt" FLEET_SKIP_GLOBAL_CONF=1 "$@"
  }
  ckconf() {   # <case> <common lines> <client lines>
    mkdir -p "$d/$1/conf/fleets/fleet" "$d/$1/home" "$d/$1/tt"
    printf 'FLEET_REPO="o/r"\nFLEET_MAIN="%s/nowhere"\nFLEET_BASE_BRANCH="master"\n' "$d" > "$d/$1/conf/fleets/fleet/conf"
    printf '# hub-defaults.conf — the team defaults\nFLEET_SIDEBAR_WIDTH=30\n' > "$d/$1/conf/hub-defaults.conf"
    { printf "# claude-fleet — this machine's ONE config file (issue #1623). Assignments only.\n"
      printf '# Migrated by fleet-conf.sh 2026-10-05 23:23:53 from: fleets/fleet/conf\n\n# ---- [common] ----\n%s\n' "$2"
      printf 'export FLEET_HUB_URL="https://hub.example"\n\n# ---- [client] — only the shell ----\n'
      printf 'if [ "${FLEET_SHELL:-0}" = 1 ]; then\n:\n%s\nfi  # ---- [client] end ----\n' "$3"
      printf '\n# ---- [node] ----\nif [ "${FLEET_SHELL:-0}" != 1 ]; then\n:\nfi  # ---- [node] end ----\n'
    } > "$d/$1/conf/fleet.conf"
  }
  sync_passes() { ck "$1" bash "$BIN/fleet-migrate-layout.sh" && ck "$1" bash "$BIN/fleet-conf.sh" migrate; }
  ckconf laptop 'FLEET_HOST=1' 'export FLEET_UI_LANG=zh'
  ckconf role 'FLEET_ROLE="client,node"' 'export FLEET_UI_LANG=zh'
  printf 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_FLEET_COMPUTE=0\n' > "$d/role/conf/node.env"
  ckconf host 'FLEET_HOST=1' 'export FLEET_UI_LANG=zh'
  printf 'CCQUOTA_HUB_URL=https://hub.example\n' > "$d/host/conf/node.env"
  t0=$(now)
  for c in laptop role host; do
    out=$(sync_passes "$c" 2>&1) || { WHY="$c: a sync pass failed: $(printf '%s' "$out" | tail -1)"; return 1; }
    [ -f "$d/$c/conf/fleet.conf" ] || { WHY="$c: the sync deleted fleet.conf: $(printf '%s' "$out" | head -1)"; return 1; }
    sed -n '/FLEET_SHELL:-0}" = 1/,/\[client\] end/p' "$d/$c/conf/fleet.conf" | grep -q '^export FLEET_UI_LANG=zh$' \
      || { WHY="$c: [client] lost FLEET_UI_LANG=zh: $(grep -c . "$d/$c/conf/fleet.conf") lines, $(printf '%s' "$out" | tail -1)"; return 1; }
    [ -f "$d/$c/conf/hub-defaults.conf" ] || { WHY="$c: hub-defaults.conf was moved away from where the shell reads it"; return 1; }
  done
  for c in laptop role; do
    grep -q '^FLEET_HOST=0$' "$d/$c/conf/fleet.conf" \
      || { WHY="$c: a machine that hosts nothing reads $(grep -E '^FLEET_(HOST|ROLE)=' "$d/$c/conf/fleet.conf" | tr '\n' ' ')"; return 1; }
    ls "$d/$c/conf"/fleet.conf.bak-* >/dev/null 2>&1 || { WHY="$c: rewrote fleet.conf with no fleet.conf.bak-<time>"; return 1; }
  done
  grep -q '^FLEET_HOST=1$' "$d/host/conf/fleet.conf" || { WHY="host: a real host lost FLEET_HOST=1"; return 1; }
  out=$(sync_passes laptop 2>&1); grep -q '^FLEET_HOST=0$' "$d/laptop/conf/fleet.conf" \
    && [ "$(ls "$d/laptop/conf"/fleet.conf.bak-* | wc -l | tr -d ' ')" = 1 ] \
    || { WHY="laptop: the second sync changed it again: $out"; return 1; }
  SECS=$(since "$t0"); WHAT="同步后手加的键还在、有备份；只协调的机器 FLEET_HOST=0，真承载的仍是 1"
}

# A session's test takes the person's client (issue #1931, EPIC #1906 C12): on
# 2026-10-06 a drill (#1901) on mac-a connected to the hub as the operator and took
# their one client lease — the MacBook fell to its standby screen again and again.
# A fake hub on loopback keeps the hub's rules (an acquire takes the slot over; a
# request marked X-Fleet-Worker that asks for the person's lease is 403, with the
# reason; the test door is its own slot) and dies on its own deadline. The person
# acquires first; then, from a SESSION's environment (a worker credential):
# fleet-client-lease.py acquire asks at the test door, as test, marked — and the
# person's lease and where are unchanged; FLEET_CLIENT_IDENTITY=person is refused
# 403 with the reason; outside a session the person's acquire is unmarked; and
# bash-guard refuses a session starting `fleet` / `fleet mac-a` / fleet-thin.py /
# `ssh mac-a fleet` without --test-identity, lets `fleet --test-identity`,
# `fleet doctor` and the hatch through.
drill_session_takes_client() {
  # not a recovery race: the bound only catches a hang (a macOS runner starts a
  # python in ~1s, and this drill starts ~15)
  CAP=120; local t0 hub out rc h
  t0=$(now)
  hub="$WORK/fakehub-$$"; mkdir -p "$hub/conf"
  # one process: the hub in a thread, the client as its child — nothing left
  # running in the background, and the alarm bounds it all
  cat > "$hub/drive.py" <<'PY2'
import json, os, signal, subprocess, sys, threading, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(int(sys.argv[3]))
LEASE, HOME, CONF = sys.argv[1], sys.argv[2], sys.argv[4]
cur, log = {}, []
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        worker = (self.headers.get("X-Fleet-Worker") or "").strip()
        test = self.path == "/v1/fleet/client/test" or body.get("identity") == "test"
        log.append("%s %s worker=%s identity=%s" % (self.path, body.get("action"), "yes" if worker else "no", body.get("identity", "")))
        if self.path not in ("/v1/fleet/client", "/v1/fleet/client/test"):
            self.send_response(404); self.end_headers(); return
        if worker and not test:
            out, code = {"error": "a session may not take the person's client lease — run as the test identity"}, 403
        else:
            slot = "test" if test else "person"
            if body.get("action") == "acquire":
                cur[slot] = {"id": uuid.uuid4().hex[:12], "device": body.get("device", "")}
            out, code = {"state": "active" if cur.get(slot) else "none", "lease": cur.get(slot)}, 200
            if test: out["identity"] = "test"
        b = json.dumps(out).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
def lease(extra, *args):
    env = {k: v for k, v in os.environ.items() if k not in
           ("FLEET_WORKER_CRED", "FLEET_WORKER_ASSERT", "FLEET_SEAT", "FLEET_CLIENT_IDENTITY", "SSH_CONNECTION")}
    env.update(HOME=HOME, FLEET_CONF_DIR=CONF, FLEET_HUB_URL="http://127.0.0.1:%d" % srv.server_address[1],
               FLEET_HUB_TOKEN="tok", FLEET_CLIENT_XTVERSION="0", **extra)
    r = subprocess.run([sys.executable, LEASE] + list(args), env=env, capture_output=True, text=True, timeout=20)
    return r.returncode, (r.stdout + r.stderr).strip()
def die(why):
    print("WHY=" + why + " | hub saw: " + " ; ".join(log)); sys.exit(1)
rc, out = lease({"FLEET_CLIENT_DEVICE": "MacBook"}, "acquire")
before = json.dumps(cur.get("person"))
if rc or log[-1:] != ["/v1/fleet/client acquire worker=no identity="]:
    die("the person's acquire (rc %d): %s" % (rc, out))
rc, out = lease({"FLEET_WORKER_CRED": "fwc1.x", "FLEET_CLIENT_DEVICE": "mac-a-drill"}, "acquire")
if rc or json.dumps(cur.get("person")) != before:
    die("a session's acquire took the person's lease (rc %d): %s → %s [%s]" % (rc, before, json.dumps(cur.get("person")), out))
if log[-1] != "/v1/fleet/client/test acquire worker=yes identity=test":
    die("a session's acquire did not ask as the marked test identity")
rc, out = lease({"FLEET_WORKER_CRED": "fwc1.x", "FLEET_CLIENT_IDENTITY": "person"}, "acquire")
if rc != 1 or "403" not in out or "test identity" not in out:
    die("FLEET_CLIENT_IDENTITY=person in a session: rc %d, no 403 + why: [%s]" % (rc, out))
if json.dumps(cur.get("person")) != before:
    die("a refused acquire still moved the person's lease")
print("OK")
PY2
  out=$(python3 "$hub/drive.py" "$BIN/fleet-client-lease.py" "$WORK/home" "$((CAP + 10))" "$hub/conf" 2>&1)
  [ "$out" = OK ] || { WHY=${out#WHY=}; WHY="${WHY:-the drive died}"; return 1; }
  # the guard: a session's client start must say --test-identity
  h=( env -u FLEET_HUB FLEET_WORKER_CRED=fwc1.x FLEET_HEAVY=0 FLEET_LIB=/nonexistent python3 "$ROOT/hooks/bash-guard.py" )
  for cmd in 'fleet' 'fleet mac-a' 'fleet --thin' 'fleet --old' 'FLEET_HUB_URL=https://hub.example fleet' "$BIN/fleet-thin.py" 'ssh mac-a fleet' 'ssh -p 22022 mac-a "fleet shell"' \
             'fleet codex hi' 'fleet claude --node mac-a' "$BIN/fleet-home-session.sh claude"; do
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(printf '%s' "$cmd" | sed 's/["\\]/\\&/g')" | "${h[@]}" 2>&1)
    [ $? = 2 ] || { WHY="bash-guard let a session's [$cmd] through"; return 1; }
    case "$out" in *--test-identity*FLEET_ALLOW_PERSON_CLIENT=1*) ;; *) WHY="bash-guard gave no way out for [$cmd]: [$out]"; return 1 ;; esac
  done
  for cmd in 'fleet --test-identity mac-a' 'FLEET_CLIENT_IDENTITY=test fleet' 'fleet doctor' 'ssh mac-a fleet --test-identity' 'FLEET_ALLOW_PERSON_CLIENT=1 fleet' \
             'fleet claude --here' 'fleet --test-identity codex hi' 'fleet --test-identity --thin' \
             'FLEET_CLIENT_IDENTITY=test python3 fleet-thin.py' 'python3 fleet-thin.py --help'; do
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(printf '%s' "$cmd" | sed 's/["\\]/\\&/g')" | "${h[@]}" 2>&1)
    [ $? = 0 ] || { WHY="bash-guard refused [$cmd]: [$out]"; return 1; }
  done
  out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"fleet mac-a"}}' \
        | env -u FLEET_WORKER_CRED -u FLEET_HUB FLEET_HEAVY=0 FLEET_LIB=/nonexistent python3 "$ROOT/hooks/bash-guard.py" 2>&1)
  [ $? = 0 ] || { WHY="bash-guard refused a person's own fleet: [$out]"; return 1; }
  SECS=$(since "$t0"); WHAT="执行会话的客户端只拿测试身份：运营者租约不变，要运营者租约被拒（403 + 原因），守卫拦没写 --test-identity 的启动"
}

# A login's wait with no answer (issue #2262, EPIC #2259 约定 5/8): the browser
# will not open, or opens and nobody confirms (a company network blocking
# GitHub). Before, the terminal drew a QR and waited out the code's ten minutes
# without a word. A fake hub that never confirms, a fake opener that fails, then
# one that works: it says the browser would not open and draws the QR; it says
# every few seconds what it waits for; it stops with the reason and what to do.
login_pending_hub() {
  cat > "$1/hub.py" <<'PY2'
import json, os, signal, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(int(sys.argv[2]))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/v1/fleet/login/start":
            st, out = 200, {"device_code": "d" * 64, "user_code": "BCDF-GHJK", "expires_in": 600, "interval": 1,
                            "verification_uri": "http://127.0.0.1/fleet/login?code=BCDF-GHJK",
                            "key_fingerprint": "SHA256:x", "qr": ["#.#", ".#.", "#.#"]}
        elif self.path == "/v1/fleet/login/poll":
            st, out = 202, {"status": "authorization_pending"}
        else:
            st, out = 404, {}
        b = json.dumps(out).encode()
        self.send_response(st); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(sys.argv[1], "port"), "w").write(str(srv.server_port))
srv.serve_forever()
PY2
  rm -f "$1/port"
  python3 "$1/hub.py" "$1" "$2" 2>"$1/hub.err" & LHUB_PID=$!
  for _ in $(seq 1 300); do [ -s "$1/port" ] && break; sleep 0.1; done
  [ -s "$1/port" ]
}
login_sandbox_run() {   # <dir> <env…> — fleet-login.py in a sandbox HOME (killed at 20 s), its output printed
  local d="$1"; shift
  env -i PATH="$d/fakebin:$PATH" HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" "$@" \
    python3 -c 'import subprocess, sys
try: sys.exit(subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, stderr=subprocess.STDOUT, timeout=20).returncode)
except subprocess.TimeoutExpired: print("(still waiting after 20 s — killed)"); sys.exit(124)' \
    python3 "$BIN/fleet-login.py" --hub "http://127.0.0.1:$(cat "$d/port")" 2>&1
}
drill_login_browser_silent() {
  CAP=10; local t0 d="$WORK/lbs" out
  mkdir -p "$d/home/.ssh" "$d/fakebin"
  for o in open xdg-open; do printf '#!/bin/sh\nexit "$(cat %s/open.rc)"\n' "$d" > "$d/fakebin/$o"; chmod +x "$d/fakebin/$o"; done
  login_pending_hub "$d" $((CAP * 3)) || { kill "$LHUB_PID" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$d/hub.err")"; return 1; }
  echo 1 > "$d/open.rc"
  out=$(login_sandbox_run "$d" FLEET_LOGIN_BROWSER=1 FLEET_LOGIN_NUDGE_SECS=1 FLEET_LOGIN_TIMEOUT_SECS=2)
  case "$out" in *浏览器打不开*'█'*) ;; *) kill "$LHUB_PID" 2>/dev/null; WHY="an opener that fails: no 「浏览器打不开」 + QR: [$out]"; return 1 ;; esac
  echo 0 > "$d/open.rc"
  t0=$(now)
  out=$(login_sandbox_run "$d" FLEET_LOGIN_BROWSER=1 FLEET_LOGIN_NUDGE_SECS=1 FLEET_LOGIN_TIMEOUT_SECS=3)
  SECS=$(since "$t0")
  kill "$LHUB_PID" 2>/dev/null; wait "$LHUB_PID" 2>/dev/null
  case "$out" in *还在等浏览器里授权*按\ q\ 改用二维码*) ;; *) WHY="no 「还在等浏览器里授权…（按 q 改用二维码）」 while waiting: [$out]"; return 1 ;; esac
  case "$out" in *秒内浏览器里没有完成授权，已停下*'fleet login --qr'*) ;; *) WHY="the wait did not stop with the reason + next step: [$out]"; return 1 ;; esac
  [ -e "$d/home/.ssh/fleet-cert-cert.pub" ] && { WHY="a certificate appeared with nothing confirmed"; return 1; }
  WHAT="浏览器打不开就说并画码；等着时每拍一句「还在等浏览器里授权…（按 q 改用二维码）」，到点停下给原因和下一步"
}

# A sandbox login that writes the REAL config (issue #2262): 2026-10-07 a
# worker took its 上线证据 with HOME pointed at a temp dir but its session's
# FLEET_CONF_DIR still set — `fleet login` remembered the fake hub in the
# machine's real fleet.conf and mac-b lost its hub. The real home is a seam here
# ($d/real); the guard must keep both writes (the address, node.env's dir for
# `fleet node ensure`) in the sandbox.
drill_login_sandbox_real_conf() {
  CAP=10; local t0 d="$WORK/lsr" out
  mkdir -p "$d/home/.ssh" "$d/real/.config/claude-fleet" "$d/fakebin"
  printf 'export FLEET_HUB_URL="https://hub.real"\n' > "$d/real/.config/claude-fleet/fleet.conf"
  login_pending_hub "$d" $((CAP * 3)) || { kill "$LHUB_PID" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$d/hub.err")"; return 1; }
  t0=$(now)
  out=$(login_sandbox_run "$d" FLEET_LOGIN_BROWSER=0 FLEET_LOGIN_TIMEOUT_SECS=1 \
        FLEET_LOGIN_REAL_HOME="$d/real" FLEET_CONF_DIR="$d/real/.config/claude-fleet")
  SECS=$(since "$t0")
  kill "$LHUB_PID" 2>/dev/null; wait "$LHUB_PID" 2>/dev/null
  grep -q 'hub.real' "$d/real/.config/claude-fleet/fleet.conf" && ! grep -q '127.0.0.1' "$d/real/.config/claude-fleet/fleet.conf" \
    || { WHY="the sandbox login wrote the real fleet.conf: $(cat "$d/real/.config/claude-fleet/fleet.conf")"; return 1; }
  grep -q '127.0.0.1' "$d/home/.config/claude-fleet/fleet.conf" 2>/dev/null \
    || { WHY="the sandbox's own fleet.conf did not get the address: [$out]"; return 1; }
  case "$out" in *'belongs to'*) ;; *) WHY="it did not say it ignored the carried FLEET_CONF_DIR: [$out]"; return 1 ;; esac
  WHAT="沙箱 HOME 下带着真的 FLEET_CONF_DIR 登录：真 fleet.conf 一字不动，地址写进沙箱，并说一句为什么"
}

# ---- phone-squeezes-window (#1933): two clients of one fleet, 160 and 50 columns,
# each through its own view session (#1489) on the same window, under the node
# conf's own window-size lines. Typing on one sizes the window to it; a view's
# `select` (fleet-remote-view.sh: switch-client -c) does the same for a window
# it moves to. Red on `window-size smallest`: the phone held every window at 50.
drill_phone_squeezes_window() {
  CAP=20; local t0 out conf="$ROOT/conf/tmux-attention.conf"
  out=$(grep -E '^set -g (window-size|aggressive-resize) ' "$conf")
  [ -n "$out" ] || { WHY="conf/tmux-attention.conf sets no window-size"; return 1; }
  printf '%s\n' "$out" > "$WORK/ws.conf"
  t0=$(now)
  out=$(python3 - "$REAL_TMUX" "$WORK/sock-ws" "$WORK/ws.conf" <<'PY' 2>&1
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time
tmux, sock, conf = sys.argv[1:4]
signal.alarm(30)
def T(*a): return subprocess.run([tmux, "-S", sock] + list(a), capture_output=True, text=True).stdout.strip()
def die(m): print("WHY=" + m); sys.exit(1)
T("-f", "/dev/null", "new-session", "-d", "-s", "fl", "-x", "120", "-y", "30", "sleep 600")
T("source-file", conf)
w = T("display", "-p", "-t", "=fl:", "#{window_id}")
kids, fds = [], []
def attach(view, cols, rows):
    T("new-session", "-d", "-t", "=fl", "-s", view); T("set", "-t", view, "status", "off")
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.pop("TMUX", None); os.environ["TERM"] = "xterm-256color"
        os.execvp(tmux, [tmux, "-S", sock, "attach-session", "-t", "=" + view])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    kids.append(pid); fds.append(fd); return fd
def pump(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select(fds, [], [], 0.05)
        for fd in r:
            try: os.read(fd, 65536)
            except OSError: pass
def width(win):
    return T("display", "-p", "-t", win, "#{window_width}")
def until(want, win, what):
    end = time.time() + 5
    while time.time() < end:
        if width(win) == want: return
        pump(0.1)
    die("%s: the window is %s columns, not %s" % (what, width(win), want))
try:
    mac = attach("fl@view-mac", 160, 40); pump(0.5)
    phone = attach("fl@view-phone", 50, 30); pump(0.5)
    if T("list-clients", "-F", "#{client_tty}").count("\n") != 1: die("two clients did not attach")
    os.write(mac, b"x"); until("160", w, "typed on the Mac (160 columns)")
    os.write(phone, b"y"); until("50", w, "typed on the phone (50 columns)")
    os.write(mac, b"z"); until("160", w, "typed on the Mac again")
    # the phone moves to a second window, then the Mac's view selects it the way
    # fleet-remote-view.sh does: by its client
    w2 = T("new-window", "-d", "-P", "-F", "#{window_id}", "-t", "fl:", "sleep 600")
    T("select-window", "-t", "=fl@view-phone:" + w2); os.write(phone, b"y"); until("50", w2, "the phone on window 2")
    tty = T("list-clients", "-t", "=fl@view-mac", "-F", "#{client_tty}")
    T("switch-client", "-c", tty, "-t", "=fl@view-mac:" + w2); until("160", w2, "the Mac's view selected window 2")
    print("OK")
finally:
    for pid in kids:
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
PY
)
  "$REAL_TMUX" -S "$WORK/sock-ws" kill-server 2>/dev/null
  [ "$(printf '%s\n' "$out" | tail -n 1)" = OK ] || { WHY=$(printf '%s\n' "$out" | sed -n 's/^WHY=//p' | tail -n 1)
    WHY="${WHY:-the drive died: $(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')}"; return 1; }
  grep -q 'switch-client -c "$c"' "$BIN/fleet-remote-view.sh" \
    || { WHY="fleet-remote-view.sh select no longer switches the view's own client"; return 1; }
  SECS=$(since "$t0"); WHAT="160 列与 50 列两个客户端看同一窗口：谁打字跟谁；视图切窗口也按自己的宽度"
}



drill_hub_deploy_lost_config() {
  # A hub release whose overlay lost its config (#2060): /healthz 200 and the
  # right commit, while /install and `fleet login` are 404 and /version has no
  # stable. The release's own health check (hub-release/release.sh, which the
  # workflow rolls back on) must call that unhealthy — and a whole entry healthy.
  CAP=20; local t0 sc="$WORK/hdl" rel="$ROOT/.github/actions/hub-release/release.sh" port='' _ hpid out rc
  mkdir -p "$sc"
  cat > "$sc/hub.py" <<'PY2'
import json, signal, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(int(sys.argv[2]))
mode = lambda: open(sys.argv[3]).read().strip()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body, ctype="application/json"):
        d = body.encode(); self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def do_GET(self):
        whole = mode() == "whole"
        if self.path == "/healthz": return self.reply(200, "ok", "text/plain")
        if self.path == "/version":
            v = {"commit": "abc1234", "version": "prod-abc1234", "client_version": "c3e295c85d66"}
            if whole: v["stable"] = "644641e0c0d2d12fdbba3c7b3d8d7e517062fa1a"
            return self.reply(200, json.dumps(v))
        if self.path == "/install" and whole: return self.reply(200, "#!/bin/sh\necho fleet\n", "text/x-shellscript")
        self.reply(404, "404 page not found\n", "text/plain")
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/v1/fleet/login/start" and mode() == "whole": return self.reply(400, '{"error":"no public key"}')
        self.reply(404, "404 page not found\n", "text/plain")
srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1] + ".tmp", "w").write(str(srv.server_address[1])); __import__("os").replace(sys.argv[1] + ".tmp", sys.argv[1])
srv.serve_forever()
PY2
  echo lost > "$sc/mode"
  python3 "$sc/hub.py" "$sc/port" "$((CAP + 60))" "$sc/mode" 2>"$sc/hub.err" & hpid=$!
  for _ in $(seq 1 300); do [ -s "$sc/port" ] && break; sleep 0.1; done
  { read -r port < "$sc/port"; } 2>/dev/null
  [ -n "$port" ] || { kill "$hpid" 2>/dev/null; WHY="the fake hub did not start in 30s: $(tail -2 "$sc/hub.err" | tr '\n' ' ')"; return 1; }
  t0=$(now)
  out=$(HUB_URLS="http://127.0.0.1:$port" HEALTH_SECS=0 HUB_DEPLOY_SIMULATE_UNHEALTHY=false bash "$rel" health abc1234 2>&1); rc=$?
  SECS=$(since "$t0")
  if [ "$rc" = 0 ]; then
    kill "$hpid" 2>/dev/null; WHY="a release with /install 404, no stable, login 404 passed the health check: $out"; return 1
  fi
  case "$out" in *'/install=404'*'no stable'*'login/start=404'*) ;; *)
    kill "$hpid" 2>/dev/null; WHY="the health check failed without naming the three faults: $(printf '%s' "$out" | tr '\n' ' ')"; return 1 ;; esac
  echo whole > "$sc/mode"
  out=$(HUB_URLS="http://127.0.0.1:$port" HEALTH_SECS=0 HUB_DEPLOY_SIMULATE_UNHEALTHY=false bash "$rel" health abc1234 2>&1); rc=$?
  kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  [ "$rc" = 0 ] || { WHY="a whole entry failed the health check: $(printf '%s' "$out" | tr '\n' ' ')"; return 1; }
  WHAT="入口部署丢了配置（/install 404、/version 无 stable、login/start 404）：健康检查判不健康 → hub-deploy 回退"
}

# A release that deletes a hook script an old session's table still calls: the
# move must refuse BEFORE the tag moves, naming the script; --force moves it and
# leaves one line (issue #2075, EPIC #2074 C2).
drill_oldcfg_deleted_hook() {
  CAP=30; local t0 d out rc c1 c2
  d="$WORK/oldcfg"; mkdir -p "$d/shim" "$d/seed"
  printf '#!/bin/sh\nprintf "completed success ci\\n"\n' > "$d/shim/gh"; chmod +x "$d/shim/gh"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    mkdir -p "$d/seed/hooks" "$d/seed/bin"
    printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/h.sh"}]}]}}\n' > "$d/seed/hooks/settings-hooks.json"
    printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$d/seed/bin/h.sh"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm hooked && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c1"
    git -C "$d/seed" rm -q bin/h.sh && git -C "$d/seed" commit -qm 'drop h.sh' && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c2"
    git --git-dir="$d/origin.git" update-ref refs/tags/stable "$(cat "$d/c1")" && git clone -q "$d/origin.git" "$d/co" 2>/dev/null
  ) || { WHY="could not build the rig repo"; return 1; }
  c1=$(cat "$d/c1"); c2=$(cat "$d/c2")
  t0=$(now)
  out=$(PATH="$d/shim:$PATH" FLEET_STABLE_LOG="$d/stable-move.log" sh "$BIN/fleet-stable.sh" move "$c2" --dir "$d/co" --repo o/r 2>&1); rc=$?
  SECS=$(since "$t0")
  [ "$rc" = 3 ] || { WHY="move exited $rc, want 3 (refused): $(printf '%s' "$out" | tail -3 | tr '\n' '|')"; return 1; }
  case "$out" in *'REFUSED — oldcfg:'*) ;; *) WHY="the refusal is not prefixed oldcfg: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1 ;; esac
  case "$out" in *'bin/h.sh not in the new tree'*) ;; *) WHY="the refusal does not name bin/h.sh: $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c1" ] || { WHY="stable moved despite the red replay"; return 1; }
  out=$(PATH="$d/shim:$PATH" FLEET_STABLE_LOG="$d/stable-move.log" sh "$BIN/fleet-stable.sh" move "$c2" --force --dir "$d/co" --repo o/r 2>&1) \
    || { WHY="--force did not move: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c2" ] || { WHY="--force left stable at the old commit"; return 1; }
  grep -q "	forced	" "$d/stable-move.log" 2>/dev/null || { WHY="--force left no line in stable-move.log"; return 1; }
  WHAT="删了 h.sh 的发版被拒（oldcfg: 点名 bin/h.sh，stable 没动）；--force 才挪并记一行"
}

# ---- macos-red-to-stable (#2286, rewritten by #3869, #4671): the macOS selftests run
# AFTER the release and hold none (one release line, no gate 5 — fleet-stable.sh has
# no macOS read left to drill). A BSD-only red must still be seen: the watcher alerts
# once per red run reading mac-follow's jobs (#4898: said, never filed). Fake gh
# (runs / jobs), fake alert.
drill_macos_red_to_stable() {
  CAP=30; local t0 d out
  d="$WORK/macosred"; mkdir -p "$d/shim" "$d/conf"
  cat > "$d/shim/gh" <<SH
#!/bin/sh
case "\$*" in
  *actions/workflows/*status=completed*) cat "$d/runs.watch" ;;
  *actions/workflows/*) : ;;
  *actions/runs/9/jobs*) printf '7\tfailure\tmacOS / shard 1\n' ;;
  *actions/runs/*/jobs*) printf '6\tsuccess\tmacOS / shard 1\n' ;;
  *actions/jobs/*/logs*) printf 'FAIL  bsd-only-selftest.sh  1s\n' ;;
  *) printf 'completed success shard 1\n' ;;
esac
SH
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerted"\n' "$d" > "$d/alert"
  chmod +x "$d/shim/gh" "$d/alert"
  printf '9\t%s\tfailure\tworkflow_run\n8\t%s\tsuccess\tworkflow_run\n' 2222222bbb 1111111aaa > "$d/runs.watch"
  t0=$(now)
  out=$(PATH="$d/shim:$PATH" FLEET_CONF_DIR="$d/conf" FLEET_MACOS_ALERT_CMD="$d/alert" \
          bash "$BIN/fleet-macos-watch.sh" --repo o/r --now 2>&1) || { WHY="the watcher failed: $out"; return 1; }
  grep -q 'breakage' "$d/alerted" 2>/dev/null || { WHY="the red follow was not alerted as a breakage: $out"; return 1; }
  grep -q 'bsd-only-selftest.sh' "$d/alerted" || { WHY="the alert does not name the red test"; return 1; }
  PATH="$d/shim:$PATH" FLEET_CONF_DIR="$d/conf" FLEET_MACOS_ALERT_CMD="$d/alert" bash "$BIN/fleet-macos-watch.sh" --repo o/r --now >/dev/null 2>&1
  SECS=$(since "$t0")
  [ "$(grep -c 'breakage' "$d/alerted")" = 1 ] || { WHY="the same red follow was alerted twice"; return 1; }
  WHAT="macOS 红：每个红 run 提醒一次（breakage，不开单，同一 run 不重提）"
}

# ---- stable-push-no-workflows (#3912): GitHub refuses a tag move whose range
# changes .github/workflows/* from a credential without workflows permission —
# GITHUB_TOKEN, the checkout's default. Stable stayed at one commit for a day while
# every merge touched a workflow, and the move said only «lease lost». Now the
# release checkout takes STABLE_PUSH_TOKEN when set, and fleet-stable.sh names the
# refusal. Rig: a bare remote whose pre-receive refuses such a tag move the way
# GitHub does; stable (at c1) is moved onto c2, which changes a workflow → exit 4,
# the reason said as no workflows permission, the tag left.
drill_stable_push_no_workflows() {
  CAP=30; local t0 d out rc c1
  grep -q 'token: ${{ secrets.STABLE_PUSH_TOKEN || github.token }}' "$ROOT/.github/workflows/release-train.yml" \
    || { WHY="release-train.yml's checkout does not push with STABLE_PUSH_TOKEN"; return 1; }
  d="$WORK/nowf"; mkdir -p "$d/shim" "$d/seed"
  cat > "$d/shim/gh" <<SH
#!/bin/sh
case "\$*" in
  *actions/workflows/*) printf '%s\tcompleted\tsuccess\tpush\t5\tselftests (macOS)\n%s\tcompleted\tsuccess\tpush\t6\tselftests (macOS)\n' "\$(cat "$d/c1")" "\$(cat "$d/c2")" ;;
  *) printf 'completed success shard 1\n' ;;
esac
SH
  chmod +x "$d/shim/gh"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    mkdir -p "$d/seed/.github/workflows"; echo 'name: selftests (macOS)' > "$d/seed/.github/workflows/selftests-macos.yml"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm one && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c1"
    echo 'name: release train' > "$d/seed/.github/workflows/release-train.yml"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm 'touches a workflow' && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c2"
    git --git-dir="$d/origin.git" update-ref refs/tags/stable "$(cat "$d/c1")"
    git clone -q "$d/origin.git" "$d/co" 2>/dev/null || exit 1
    cat > "$d/origin.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
z=0000000000000000000000000000000000000000
while read -r o n r; do
  case "$r" in refs/tags/*) ;; *) continue ;; esac
  if [ "$o" = "$z" ]; then w=$(git ls-tree -r --name-only "$n" .github/workflows)
  else w=$(git diff --name-only "$o" "$n" -- .github/workflows); fi
  [ -z "$w" ] && continue
  echo "refusing to allow a GitHub App to create or update workflow $(echo "$w" | head -1) without \`workflows\` permission" >&2
  exit 1
done
HOOK
    chmod +x "$d/origin.git/hooks/pre-receive"
  ) || { WHY="could not build the rig repo"; return 1; }
  c1=$(cat "$d/c1")
  t0=$(now)
  out=$(PATH="$d/shim:$PATH" GITHUB_ACTIONS=true sh "$BIN/fleet-stable.sh" move "$(cat "$d/c2")" --dir "$d/co" --repo o/r 2>&1); rc=$?
  SECS=$(since "$t0")
  [ "$rc" = 4 ] || { WHY="a push the remote refused for workflows exited $rc, want 4: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
  case "$out" in *'no workflows permission'*STABLE_PUSH_TOKEN*) ;; *) WHY="the refusal is not said as missing workflows permission: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1 ;; esac
  case "$out" in *'.github/workflows/release-train.yml'*) ;; *) WHY="the changed workflow is not named: $(printf '%s' "$out" | tail -1)"; return 1 ;; esac
  case "$out" in *'lease lost'*) WHY="still blames a lost lease: $(printf '%s' "$out" | tail -1)"; return 1 ;; esac
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c1" ] || { WHY="the refused tag moved anyway"; return 1; }
  WHAT="范围里改过工作流、凭据没有 workflows 权限：推 tag 被拒时 move 说「缺 workflows 权限」、点名改过的工作流和 STABLE_PUSH_TOKEN（退出 4、不说 lease lost、tag 不动）；release 的 checkout 用 STABLE_PUSH_TOKEN"
}

# ---- train-push-cancels (#3141, EPIC #3139 C2): every merge used to start its own
# macOS run, and the next merge cancelled it (17 of 20 one night) — so nothing was
# ever green long enough to release. Now ONE lane: release-train.yml, a fixed
# concurrency group with cancel-in-progress false (GitHub keeps one running + the
# newest waiting; a new push only replaces the WAITING one), and each train boards
# the head of origin/master at the moment it starts, not the commit that queued it.
# The GitHub half is its configuration, linted; the boarding is run for real on a
# bare repo: a push lands while a train is "running" → the next train's TRAIN_SHA is
# that later head and it carries every merge since stable; stable already at the
# head → the train is empty (skip) within the minute.
drill_train_push_cancels() {
  CAP=60; local t0 d out wf c1 c2 c3 c4 v
  wf="$ROOT/.github/workflows/release-train.yml"
  [ -f "$wf" ] || { WHY="no .github/workflows/release-train.yml — every merge still runs its own macOS"; return 1; }
  [ -x "$BIN/fleet-train-board.sh" ] || { WHY="no bin/fleet-train-board.sh"; return 1; }
  # one lane: a top-level concurrency group with a fixed name, never cancelling
  out=$(awk '/^concurrency:/{c=1; next} c && /^[^ ]/{c=0} c' "$wf")
  printf '%s\n' "$out" | grep -Eq '^[[:space:]]+group:[[:space:]]*release-train[[:space:]]*$' \
    || { WHY="release-train.yml has no top-level concurrency group 'release-train': $(printf '%s' "$out" | tr '\n' ' ')"; return 1; }
  printf '%s\n' "$out" | grep -Eq '^[[:space:]]+cancel-in-progress:[[:space:]]*false[[:space:]]*$' \
    || { WHY="the train's concurrency would cancel a running train (cancel-in-progress is not false)"; return 1; }
  grep -nE 'cancel-in-progress:[[:space:]]*(true|\$\{\{)' "$wf" >/dev/null \
    && { WHY="something in release-train.yml can cancel in progress: $(grep -nE 'cancel-in-progress' "$wf" | tr '\n' ' ')"; return 1; }
  [ "$(grep -cE '^[[:space:]]*concurrency:' "$wf")" = 1 ] \
    || { WHY="release-train.yml has a second (job-level) concurrency — it would split the lane"; return 1; }
  for v in 'push:' 'workflow_dispatch:'; do
    awk '/^on:/{o=1; next} o && /^[^ ]/{o=0} o' "$wf" | grep -q "^[[:space:]]*$v" \
      || { WHY="release-train.yml is not triggered by $v"; return 1; }
  done
  # the timed backstop is release-train-next.yml's (issue #4913), dispatching into this lane
  awk '/^on:/{o=1; next} o && /^[^ ]/{o=0} o' "$ROOT/.github/workflows/release-train-next.yml" 2>/dev/null | grep -q '^[[:space:]]*schedule:' \
    || { WHY="nothing re-boards a lost push (no schedule on release-train-next.yml)"; return 1; }
  grep -q 'fleet-train-board.sh' "$wf" || { WHY="the train does not board through bin/fleet-train-board.sh"; return 1; }
  grep -qE 'runs_on:.*macos' "$wf" && { WHY="the train still waits on macOS tests (issue #3869: mac-follow.yml follows the release)"; return 1; }
  grep -qE 'runs_on:.*macos' "$ROOT/.github/workflows/mac-follow.yml" || { WHY="nothing runs the macOS half after the release (mac-follow.yml)"; return 1; }
  # the per-merge macOS run is gone (the nightly full suite stays)
  awk '/^on:/{o=1; next} o && /^[^ ]/{o=0} o' "$ROOT/.github/workflows/selftests-macos.yml" | grep -q '^[[:space:]]*push:' \
    && { WHY="selftests-macos.yml is still triggered by push — the next merge cancels it again"; return 1; }
  d="$WORK/train"; mkdir -p "$d/seed"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    for i in 1 2; do echo "$i" > "$d/seed/f"; git -C "$d/seed" add -A; git -C "$d/seed" commit -qm "merge $i"; git -C "$d/seed" rev-parse HEAD > "$d/c$i"; done
    git -C "$d/seed" push -q origin HEAD:master || exit 1
    git --git-dir="$d/origin.git" update-ref refs/tags/stable "$(cat "$d/c1")"
    git clone -q "$d/origin.git" "$d/co" 2>/dev/null
  ) || { WHY="could not build the rig repo"; return 1; }
  c1=$(cat "$d/c1"); c2=$(cat "$d/c2")
  board() { GITHUB_SHA=$c2 GITHUB_OUTPUT="$d/out.$1" bash "$BIN/fleet-train-board.sh" --dir "$d/co" >/dev/null 2>"$d/err.$1"; }
  outv() { sed -n "s/^$2=//p" "$d/out.$1" | head -1; }
  t0=$(now)
  board 1 || { WHY="boarding failed: $(cat "$d/err.1")"; return 1; }
  [ "$(outv 1 train_sha)" = "$c2" ] && [ "$(outv 1 stable_sha)" = "$c1" ] && [ "$(outv 1 skip)" = false ] \
    || { WHY="train 1 boarded $(outv 1 train_sha) over $(outv 1 stable_sha) skip=$(outv 1 skip), want $c2 over $c1"; return 1; }
  # while train 1 "runs", two more merges land; the waiting train (queued by the
  # push of c2's era) starts after it and must board the head as it is THEN
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    for i in 3 4; do echo "$i" > "$d/seed/f"; git -C "$d/seed" commit -qam "merge $i"; git -C "$d/seed" rev-parse HEAD > "$d/c$i"; git -C "$d/seed" push -q origin HEAD:master; done
  ) || { WHY="could not push the later merges"; return 1; }
  c3=$(cat "$d/c3"); c4=$(cat "$d/c4")
  board 2 || { WHY="boarding train 2 failed: $(cat "$d/err.2")"; return 1; }
  [ "$(outv 2 train_sha)" = "$c4" ] \
    || { WHY="train 2 boarded $(outv 2 train_sha), want the head at its start $c4 (not the commit that queued it, $c2)"; return 1; }
  v=$(outv 2 merges_json)
  for c in "$c2" "$c3" "$c4"; do case "$v" in *"$c"*) ;; *) WHY="train 2 does not carry merge ${c%"${c#???????}"}: $v"; return 1 ;; esac; done
  case "$v" in *"$c1"*) WHY="train 2 carries stable's own commit: $v"; return 1 ;; esac
  # stable reaches the head: the next train has nothing to carry
  git --git-dir="$d/origin.git" update-ref refs/tags/stable "$c4"
  board 3 || { WHY="boarding train 3 failed: $(cat "$d/err.3")"; return 1; }
  SECS=$(since "$t0")
  [ "$(outv 3 skip)" = true ] || { WHY="stable at the head, the train still runs (skip=$(outv 3 skip))"; return 1; }
  WHAT="一条车道：正在跑的不取消、只留最新一趟排着；第二趟上车的是开车时的头（带上中间 3 个合并），stable 已是头就空跑"
}

# ---- quarantine-* (#3243, EPIC #3139 C10): the release train quarantines a test
# red on TWO trains in a row, untouched by the second train's change, for ≤ 48 h
# against its breakage issue — and only the train skips it. Each drill runs its leg
# of bin/fleet-train-quarantine-selftest.sh for real: the real runner and the real
# reader in a throwaway git repo, a stub filer, a fake gh.
quarantine_leg() {   # quarantine_leg <leg> <what>
  CAP=60; local t0 out
  [ -f "$BIN/fleet-train-quarantine-selftest.sh" ] || { WHY="no bin/fleet-train-quarantine-selftest.sh"; return 1; }
  [ -f "$BIN/fleet-train-quarantine.sh" ] || { WHY="no bin/fleet-train-quarantine.sh — the train has no quarantine reader"; return 1; }
  t0=$(now)
  out=$(TQ_LEG=$1 bash "$BIN/fleet-train-quarantine-selftest.sh" 2>&1) \
    || { WHY="$(printf '%s\n' "$out" | grep -E '^FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT=$2
}
drill_quarantine_one_red()  { quarantine_leg one-red  "只红一趟（或上一趟红的是别的测试）照旧 FAIL、这一片红，不隔离、不开单，只记下这趟的红留给下一趟"; }
drill_quarantine_touched()  { quarantine_leg touched  "条目还在期内，但这趟改了它点名的文件（或它自己）：照跑；在这种列车上再红是 FAIL，不再隔离"; }
drill_quarantine_expired()  { quarantine_leg expired  "过期条目视为不存在、测试照跑，摘要写「已过期，恢复」；没有隔离就不出「隔离了」那行"; }
drill_quarantine_pr_skips() { quarantine_leg pr-skips "不带 --quarantine 什么都不跳；没有 --changed 就拒（exit 2）；PR 门和夜里全量的工作流不传隔离输入，只有列车传"; }
drill_train_flaky_retry_hides_red() { quarantine_leg retry-red "重跑还红是 FAIL、这一片红（一个确定红的测试不能靠重跑发出）；--drill-red 重跑也记红；超时不重跑；--retry-red 只收 0 或 1；只有列车传 retry_red"; }



# ---- train-hub-stable-split (#3142, EPIC #3139 C3): the hub image and stable come
# from different commits — hub-deploy shipped the hub on its own clock, the
# auto-move / publish moved stable on another, and the hub refused the publish
# (422 `ccquota:`): stable moved, no machine followed. Now ONE train does both for
# one TRAIN_SHA: after its tests and precheck it deploys the hub through
# hub-deploy.yml's own job (workflow_call, sha) — or skips it when the hub already
# runs TRAIN_SHA's Go, deploy/k8s, site/ and docs/public/ (bin/fleet-train-hub.sh) — then publishes
# TRAIN_SHA and moves stable with --train (the CI gate reads this run's jobs; macOS follows, #3869).
# A rollback dispatched by hand still makes a split: the doctor's hub-image row
# says so (bin/fleet-hub-image.sh `source: SPLIT`). The hub taking the train's
# OIDC publish is its Go test, held by name. Rigs: a bare repo, a file:// hub, a
# fake gh.
drill_train_hub_stable_split() {
  CAP=60; local t0 d out rc c1 c2 c3 c4 wf hd job v
  grep -q 'TestPublishAcceptsReleaseTrain(' "$ROOT/tokenledger/hub/api/fleet_publish_test.go" 2>/dev/null \
    || { WHY="TestPublishAcceptsReleaseTrain is not in tokenledger/hub/api/fleet_publish_test.go — the hub would 401 the train's publish"; return 1; }
  wf="$ROOT/.github/workflows/release-train.yml" hd="$ROOT/.github/workflows/hub-deploy.yml"
  [ -x "$BIN/fleet-train-hub.sh" ] || { WHY="no bin/fleet-train-hub.sh — the train cannot tell whether the hub needs a new image"; return 1; }
  # hub-deploy.yml is callable with the train's sha, and builds/checks THAT commit
  awk '/^on:/{o=1; next} o && /^[^ ]/{o=0} o' "$hd" | grep -q '^[[:space:]]*workflow_call:' \
    || { WHY="hub-deploy.yml has no workflow_call — the train would need a second copy of the deploy"; return 1; }
  grep -q 'inputs.sha' "$hd" || { WHY="hub-deploy.yml never reads inputs.sha — a called deploy would build the commit that queued the train"; return 1; }
  # the train: deploy (via hub-deploy.yml) after tests + precheck, then publish, then move — all on TRAIN_SHA
  job=$(awk '/^  [a-z][a-z0-9_-]*:$/{j=$1} /uses: \.\/\.github\/workflows\/hub-deploy\.yml/{print j; exit}' "$wf")
  [ -n "$job" ] || { WHY="release-train.yml deploys no hub (no job uses ./.github/workflows/hub-deploy.yml)"; return 1; }
  v=$(awk -v j="  $job" '$0 == j {o=1; next} o && /^  [a-z]/{o=0} o' "$wf")
  for need in linux gate; do   # macOS follows the release (mac-follow.yml, #3869)
    printf '%s\n' "$v" | grep -Eq "needs:.*[^a-z_]$need([^a-z_]|\$)" || { WHY="the hub deploy ($job) does not wait for $need"; return 1; }
  done
  printf '%s\n' "$v" | grep -q 'sha: \${{ needs.board.outputs.train_sha }}' \
    || { WHY="the hub deploy ($job) is not handed TRAIN_SHA"; return 1; }
  # a called workflow sees no secret it is not handed — the overlay repo's deploy key (#3860)
  printf '%s\n' "$v" | grep -Eq '^    secrets: inherit' \
    || { WHY="the hub deploy ($job) passes no secrets — FLEET_DEPLOY_OVERLAY_SSH_KEY arrives empty (claude-fleet#3860)"; return 1; }
  grep -q 'fleet-release-publish.sh "\$TRAIN_SHA"' "$wf" || { WHY="the train does not publish TRAIN_SHA (bin/fleet-release-publish.sh \"\$TRAIN_SHA\")"; return 1; }
  grep -Eq 'fleet-stable.sh move "\$TRAIN_SHA" .*--train ' "$wf" || { WHY="the train does not move stable to TRAIN_SHA with --train"; return 1; }
  grep -Eq 'fleet-stable.sh .*--force' "$wf" && { WHY="--force is in the train"; return 1; }
  [ "$(awk '/fleet-release-publish.sh "\$TRAIN_SHA"/{print NR; exit}' "$wf")" -lt "$(awk '/fleet-stable.sh move "\$TRAIN_SHA" .*--train /{print NR; exit}' "$wf")" ] \
    || { WHY="the train moves stable before it publishes"; return 1; }
  d="$WORK/thss"; mkdir -p "$d/shim" "$d/conf" "$d/hub/v1/fleet/release"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    mkdir -p "$d/seed/bin" "$d/seed/tokenledger/hub/x" "$d/seed/deploy/k8s"
    printf 'module x\n' > "$d/seed/tokenledger/hub/go.mod"; printf 'package x\n' > "$d/seed/tokenledger/hub/x/x.go"
    printf 'a: 1\n' > "$d/seed/deploy/k8s/k.yaml"; printf 'echo\n' > "$d/seed/bin/s.sh"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm hub && git -C "$d/seed" rev-parse HEAD > "$d/c1"
    printf 'echo 2\n' > "$d/seed/bin/s.sh"; printf 'package x\n// a test-only note\n' > "$d/seed/tokenledger/hub/x/x_test.go"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm 'scripts only' && git -C "$d/seed" rev-parse HEAD > "$d/c2"
    printf 'package x\n\nconst Y = 1\n' > "$d/seed/tokenledger/hub/x/x.go"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm 'go' && git -C "$d/seed" rev-parse HEAD > "$d/c3"
    printf 'a: 2\n' > "$d/seed/deploy/k8s/k.yaml"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm 'k8s' && git -C "$d/seed" rev-parse HEAD > "$d/c4"
    mkdir -p "$d/seed/site" && printf '<p>site</p>\n' > "$d/seed/site/template.html"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm 'site' && git -C "$d/seed" rev-parse HEAD > "$d/c5"
    git -C "$d/seed" push -q origin HEAD:master && git --git-dir="$d/origin.git" update-ref refs/tags/stable "$(cat "$d/c1")" \
      && git clone -q "$d/origin.git" "$d/co" 2>/dev/null
  ) || { WHY="could not build the rig repo"; return 1; }
  c1=$(cat "$d/c1"); c2=$(cat "$d/c2"); c3=$(cat "$d/c3"); c4=$(cat "$d/c4")
  ver() { printf '{"commit":"%.7s","version":"prod-%.7s"}\n' "$1" "$1" > "$d/hub/version"; }
  plan() { out=$(bash "$BIN/fleet-train-hub.sh" "$1" --dir "$d/co" --hub "file://$d/hub" 2>&1); rc=$?; printf '%s\n' "$out" | sed -n 's/^deploy=//p' | head -1; }
  t0=$(now)
  ver "$c1"
  [ "$(plan "$c2")" = false ] || { WHY="a train with no Go / deploy/k8s change since the live hub would rebuild it: $(printf '%s' "$out" | tr '\n' '|')"; return 1; }
  [ "$(plan "$c3")" = true ] || { WHY="a train whose Go changed does not deploy the hub: $(printf '%s' "$out" | tr '\n' '|')"; return 1; }
  ver "$c3"
  [ "$(plan "$c4")" = true ] || { WHY="a train whose deploy/k8s changed does not deploy the hub: $(printf '%s' "$out" | tr '\n' '|')"; return 1; }
  ver "$c4"
  [ "$(plan "$(cat "$d/c5")")" = true ] || { WHY="a train whose website (site/) changed does not deploy the hub that carries it (#3584): $(printf '%s' "$out" | tr '\n' '|')"; return 1; }
  ver "$c3"
  printf '{"version":"prod-dev"}\n' > "$d/hub/version"
  out=$(bash "$BIN/fleet-train-hub.sh" "$c4" --dir "$d/co" --hub "file://$d/hub" 2>&1); rc=$?
  [ "$rc" != 0 ] && ! printf '%s\n' "$out" | grep -q '^deploy=true' || { WHY="a hub whose commit is unknown is deployed blind (#3319: red instead): $(printf '%s' "$out" | tr '\n' '|')"; return 1; }
  [ "$(RELEASE_TRAIN_HUB=off plan "$c4")" = false ] || { WHY="RELEASE_TRAIN_HUB=off still deploys from the train"; return 1; }
  # --train: the gates read THIS run's jobs — a red Linux job refuses, a red macOS job
  # does not (one release line, #4671), no check-runs are read
  printf '#!/bin/sh\ncase "$*" in *actions/runs/*/jobs*) cat "%s/jobs";; *) echo "unexpected gh $*" >&2; exit 9;; esac\n' "$d" > "$d/shim/gh"; chmod +x "$d/shim/gh"
  printf 'completed success board\ncompleted failure Linux / shard 1\ncompleted failure macOS / shard 1\ncompleted success precheck\nin_progress null release\n' > "$d/jobs"
  out=$(PATH="$d/shim:$PATH" FLEET_CONF_DIR="$d/conf" XDG_CONFIG_HOME="$d/conf" CCQUOTA_HUB_URL='' FLEET_HUB_URL='' \
          sh "$BIN/fleet-stable.sh" move "$c2" --train 42 --ignore-check release --dir "$d/co" --repo o/r 2>&1); rc=$?
  [ "$rc" = 3 ] || { WHY="--train past a red Linux job exited $rc, want 3: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
  case "$out" in *'not green: completed failure Linux / shard 1'*) ;; *) WHY="the refusal does not name the red Linux job: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1 ;; esac
  sed -i.bak 's/failure Linux/success Linux/' "$d/jobs"
  out=$(PATH="$d/shim:$PATH" FLEET_CONF_DIR="$d/conf" XDG_CONFIG_HOME="$d/conf" CCQUOTA_HUB_URL='' FLEET_HUB_URL='' \
          sh "$BIN/fleet-stable.sh" move "$c2" --train 42 --ignore-check release --dir "$d/co" --repo o/r 2>&1) \
    || { WHY="--train with Linux green (macOS red) did not move: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c2" ] || { WHY="stable did not move off a green train"; return 1; }
  # a rollback dispatched by hand: the hub's image source ≠ stable's — the doctor's source says SPLIT
  printf '{"artifacts":["ccquota-darwin-arm64"],"ccquota_src":"aaaa"}\n' > "$d/hub/v1/fleet/release/artifacts"
  printf '{"sha":"%s","ccquota_src":"bbbb"}\n' "$c2" > "$d/hub/v1/fleet/release/stable"
  ver "$c1"
  out=$(sh "$BIN/fleet-hub-image.sh" --dir "$d/co" --hub "file://$d/hub" 2>&1)
  case "$out" in *'source:  SPLIT'*) ;; *) WHY="fleet-hub-image.sh does not say SPLIT for a hub image of another source than stable: $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  printf '{"artifacts":["ccquota-darwin-arm64"],"ccquota_src":"bbbb"}\n' > "$d/hub/v1/fleet/release/artifacts"
  out=$(sh "$BIN/fleet-hub-image.sh" --dir "$d/co" --hub "file://$d/hub" 2>&1)
  case "$out" in *'source:  SAME'*) ;; *) WHY="same source is not SAME: $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  grep -q 'SPLIT)' "$BIN/fleet-doctor.sh" || { WHY="the doctor's hub-image row has no SPLIT case"; return 1; }
  SECS=$(since "$t0")
  WHAT="列车测试 + 门全绿后同一个 TRAIN_SHA 出入口（Go / deploy/k8s 没变就不出）、发布、--train 挪 stable（本趟 Linux 任务红就拒，macOS 红不挡）；手动回退造出的不同源 doctor 报 SPLIT"
}

# ---- release-artifact-missing (#2631): release.json pins a Claude Code version
# whose artifact nobody put in the hub's CCQUOTA_FLEET_RELEASE_ARTIFACTS. Before:
# stable moved, the hub baked the release without it, every managed machine sat
# in backoff on the old version. Now `fleet-stable.sh move` asks the hub's
# /v1/fleet/release/artifacts first and refuses with `artifacts:`, naming the
# file; once it is there the same move goes through. The hub half (a build that
# lacks a pinned artifact is refused, never baked) is its Go test, held by name.
# A file:// hub; a real bare repo + tag; fake gh.
drill_release_artifact_missing() {
  CAP=30; local t0 d out rc c1 c2 f
  f="$ROOT/tokenledger/hub/api/fleet_release_test.go"
  grep -q '^func TestReleaseBuildRefusesMissingPinned(' "$f" 2>/dev/null \
    || { WHY="the hub half's test TestReleaseBuildRefusesMissingPinned is not in ${f#$ROOT/}"; return 1; }
  d="$WORK/relart"; mkdir -p "$d/shim" "$d/seed" "$d/conf" "$d/hub/v1/fleet/release"
  printf '#!/bin/sh\nprintf "completed success ci\\n"\n' > "$d/shim/gh"; chmod +x "$d/shim/gh"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    mkdir -p "$d/seed/bin"; printf '#!/usr/bin/env python3\n' > "$d/seed/bin/fleet-node-update.py"
    sed 's/"2\.1\.[0-9]*"/"2.1.293"/' "$ROOT/release.json" > "$d/seed/release.json"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm old && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c1"
    sed 's/"2\.1\.293"/"9.9.9"/' "$d/seed/release.json" > "$d/rj" && mv "$d/rj" "$d/seed/release.json"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm 'bump claude' && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c2"
    git --git-dir="$d/origin.git" update-ref refs/tags/stable "$(cat "$d/c1")" && git clone -q "$d/origin.git" "$d/co" 2>/dev/null
  ) || { WHY="could not build the rig repo"; return 1; }
  c1=$(cat "$d/c1"); c2=$(cat "$d/c2")
  hub_has() { printf '{"artifacts":[' > "$d/hub/v1/fleet/release/artifacts"
    printf '"%s",' "$@" | sed 's/,$//' >> "$d/hub/v1/fleet/release/artifacts"
    printf ']}\n' >> "$d/hub/v1/fleet/release/artifacts"; }
  # codex / tmux as the repo's release.json pins them (a codex bump must not red this drill — #3157)
  cxv=$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["components"]; print(c["codex"]["version"], c["tmux"]["version"])' "$ROOT/release.json")
  txv=${cxv#* }; cxv=${cxv%% *}
  hub_has ccquota-darwin-arm64 claude-2.1.293-darwin-arm64 "codex-$cxv-darwin-arm64" "codex-code-mode-host-$cxv-darwin-arm64" "tmux-$txv-darwin-arm64"
  t0=$(now)
  out=$(PATH="$d/shim:$PATH" FLEET_CONF_DIR="$d/conf" XDG_CONFIG_HOME="$d/conf" CCQUOTA_HUB_URL='' FLEET_HUB_URL="file://$d/hub" \
          sh "$BIN/fleet-stable.sh" move "$c2" --dir "$d/co" --repo o/r 2>&1); rc=$?
  [ "$rc" = 3 ] || { WHY="move onto the bump exited $rc, want 3 (refused): $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
  case "$out" in *'REFUSED — artifacts:'*) ;; *) WHY="the refusal is not prefixed artifacts: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1 ;; esac
  case "$out" in *'claude-9.9.9-darwin-arm64'*) ;; *) WHY="the refusal does not name claude-9.9.9-darwin-arm64: $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c1" ] || { WHY="stable moved onto a release the hub cannot build"; return 1; }
  # the operator drops the file in → the same move goes through
  hub_has ccquota-darwin-arm64 claude-9.9.9-darwin-arm64 "codex-$cxv-darwin-arm64" "codex-code-mode-host-$cxv-darwin-arm64" "tmux-$txv-darwin-arm64"
  out=$(PATH="$d/shim:$PATH" FLEET_CONF_DIR="$d/conf" XDG_CONFIG_HOME="$d/conf" CCQUOTA_HUB_URL='' FLEET_HUB_URL="file://$d/hub" \
          sh "$BIN/fleet-stable.sh" move "$c2" --dir "$d/co" --repo o/r 2>&1) \
    || { WHY="the move after the artifact landed failed: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
  SECS=$(since "$t0")
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c2" ] || { WHY="stable did not move once the artifact was there"; return 1; }
  WHAT="release.json 钉的 claude 入口没有：stable 拒挪（artifacts: 点名缺的制品）；放进去后同一提交照常挪"
}

# ---- release-ccquota-stale: a release's ccquota is the hub image's own build, and
# `fleet-stable.sh move` holds it to the target before stable moves. One rig (a
# file:// hub, a real bare repo + tag, a fake gh), both hub kinds:
# · a hub that names no ccquota_src (older than #2930) — #2927: stable 003e89bb
#   shipped prod-343c92b, #2922's supervisor half went live without its node-program
#   half. The move reads /version and refuses `ccquota:` naming the tokenledger/
#   commit the build lacks; once the hub runs the target, it goes through;
# · a hub that names it — #2930: new scripts, old Go on every managed machine
#   (#2928). The move holds the target's node source digest (shared/ + agent/,
#   #4813) to /artifacts' ccquota_src and refuses `ccquota: … redeploy`.
# The hub half (the build / publish refusal) and the node's rollback are their
# tests, held by name.
drill_release_ccquota_stale() {
  CAP=30; local t0 d out rc c1 c2 f t pins
  for t in tokenledger/hub/api/fleet_release_test.go:TestReleaseRefusesStaleCCQuota \
           tokenledger/hub/api/fleet_publish_test.go:TestPublishRefusesStaleCCQuota \
           bin/fleet-node-update-selftest.py:test_ccquota_not_the_releases_is_rolled_back; do
    f="$ROOT/${t%%:*}"
    grep -q "${t#*:}(" "$f" 2>/dev/null || { WHY="${t#*:} is not in ${t%%:*}"; return 1; }
  done
  d="$WORK/relcq"; mkdir -p "$d/shim" "$d/seed" "$d/conf" "$d/hub/v1/fleet/release"
  printf '#!/bin/sh\nprintf "completed success ci\\n"\n' > "$d/shim/gh"; chmod +x "$d/shim/gh"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    mkdir -p "$d/seed/bin" "$d/seed/tokenledger/agent/x" "$d/seed/tokenledger/hub"; printf '#!/usr/bin/env python3\n' > "$d/seed/bin/fleet-node-update.py"
    printf 'module x\n' > "$d/seed/tokenledger/hub/go.mod"; printf 'package x\n' > "$d/seed/tokenledger/agent/x/x.go"
    cp "$ROOT/release.json" "$d/seed/release.json"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm old && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c1"
    printf 'package x\n\nconst OpID = true\n' > "$d/seed/tokenledger/agent/x/x.go"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm 'the node program keeps a book' && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c2"
    git --git-dir="$d/origin.git" update-ref refs/tags/stable "$(cat "$d/c1")" && git clone -q "$d/origin.git" "$d/co" 2>/dev/null
  ) || { WHY="could not build the rig repo"; return 1; }
  c1=$(cat "$d/c1"); c2=$(cat "$d/c2")
  # every pin is on the hub (gate 7 passes): only the ccquota differs
  pins=$(python3 "$BIN/fleet-node-update.py" pinned-artifacts - darwin-arm64 < "$ROOT/release.json" | tr -s ' \n' ' ')
  hub_src() { printf '{"artifacts":[%s],"platforms":["darwin-arm64"],"ccquota_src":"%s"}\n' \
    "$(for n in $pins; do printf '"%s",' "$n"; done | sed 's/,$//')" "$1" > "$d/hub/v1/fleet/release/artifacts"; }
  ccq_mv() { PATH="$d/shim:$PATH" FLEET_CONF_DIR="$d/conf" XDG_CONFIG_HOME="$d/conf" CCQUOTA_HUB_URL='' FLEET_HUB_URL="file://$d/hub" \
           sh "$BIN/fleet-stable.sh" move "$c2" --dir "$d/co" --repo o/r 2>&1; }
  # refused (exit 3, `ccquota:` + <what>), stable left at c1; then the hub catches up and the same move goes
  ccq_held() {
    out=$(ccq_mv); rc=$?
    [ "$rc" = 3 ] || { WHY="$1: the move exited $rc, want 3 (refused): $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
    case "$out" in *'REFUSED — ccquota:'*) ;; *) WHY="$1: the refusal is not prefixed ccquota: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1 ;; esac
    case "$out" in *"$2"*) ;; *) WHY="$1: the refusal does not say $2: $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
    [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c1" ] || { WHY="$1: stable moved onto a release whose ccquota is not the target's"; return 1; }
  }
  ccq_went() {
    out=$(ccq_mv) || { WHY="$1: the move after the hub caught up failed: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
    [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c2" ] || { WHY="$1: stable did not move once the hub ran the target"; return 1; }
  }
  t0=$(now)
  hub_src ''; printf '{"version":"prod-%.7s"}\n' "$c1" > "$d/hub/version"   # an older hub: /version only
  ccq_held 'no ccquota_src' 'the node program keeps a book' || return 1
  printf '{"version":"prod-%.7s"}\n' "$c2" > "$d/hub/version" ; ccq_went 'no ccquota_src' || return 1
  git --git-dir="$d/origin.git" update-ref refs/tags/stable "$c1"; git -C "$d/co" tag -f stable "$c1" >/dev/null 2>&1
  hub_src "$(python3 "$BIN/fleet-src-digest.py" "$d/co" "$c1")"           # the hub image is c1's
  ccq_held 'ccquota_src' redeploy || return 1
  hub_src "$(python3 "$BIN/fleet-src-digest.py" "$d/co" "$c2")" ; ccq_went 'ccquota_src' || return 1
  SECS=$(since "$t0")
  WHAT="入口的 ccquota 早于目标的 Go（旧入口按 /version 点名缺的 tokenledger/ 提交；新入口按 ccquota_src 比节点源码摘要）：stable 拒挪（ccquota:）；入口部署到目标后同一提交照常挪"
}

# A release that deletes what an OPEN session's start still names (a hook script,
# a mod tool's handler): the list must tell that session — red 会坏·需重开 — from
# one that merely lacks a new hook (yellow 配置旧, as before) and from one with no
# manifest at all (yellow too), name the broken one and the looping stale one with
# window · repo · issue · state, and reopen none of them (issue #2076, EPIC #2074 C3).
drill_oldcfg_broken_unmarked() {
  CAP=20; BREAK_SOCK="$WORK/sock-oc3"; local d="$WORK/oc3" t0 out rc st wb wl wn word
  mkdir -p "$d/conf/global" "$d/new/bin" "$d/new/hooks" "$d/new/mod/fleet/hooks" "$d/new/conf"
  # the new install: h.sh kept, new.sh added, the mod's `await` dropped from TOOL_RE
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/h.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/new.sh"}]}]}}\n' > "$d/new/hooks/settings-hooks.json"
  : > "$d/new/bin/h.sh"; : > "$d/new/bin/new.sh"; : > "$d/new/bin/fleet-mcp.py"
  printf "export const FALLBACK = ['status', 'spawn'] as const\nexport const TOOL_RE = /^mcp__fleet__fleet_(status|spawn)\$/\n" > "$d/new/mod/fleet/hooks/tools.ts"
  printf '{"mcpServers":{"fleet":{"command":"bash","args":["-c","exec python3 $HOME/.claude/fleet/bin/fleet-mcp.py"]}}}\n' > "$d/new/conf/mcp-worker.json"
  # two old sessions' starts: one named gone.sh and the dropped tool, one only lacks new.sh
  printf '{"agent":"claude","fp":"OLD","hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/gone.sh"}]}]},"tools":["mcp__fleet__fleet_status","mcp__fleet__fleet_await"],"mcp":{}}\n' > "$d/m-broken.json"
  printf '{"agent":"claude","fp":"OLD","hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/h.sh"}]}]},"tools":["mcp__fleet__fleet_status","mcp__fleet__fleet_spawn"],"mcp":{}}\n' > "$d/m-stale.json"
  printf 'claude NEW x\nver v2\n' > "$d/conf/global/agent-cfg.expected"
  nt -f /dev/null new-session -d -s oc3 -n home -x 100 -y 30 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  ocw() {   # <name> <state> <manifest> → window id: a Claude session on the OLD fingerprint
    local id; id=$(nt new-window -d -t oc3: -n "$1" -P -F '#{window_id}' 'exec sleep 600')
    nt set-option -w -t "$id" @claude_state "$2"; nt set-option -w -t "$id" @agent_cfg OLD; nt set-option -w -t "$id" @agent_ver v2
    nt set-option -w -t "$id" @issue 7; nt set-option -w -t "$id" @repo acme/app
    [ -n "$3" ] && nt set-option -w -t "$id" @agent_cfg_manifest "$3"
    printf '%s' "$id"
  }
  wb=$(ocw w-broken 'done' "$d/m-broken.json"); wl=$(ocw w-loop looping "$d/m-stale.json"); wn=$(ocw w-old 'done' '')
  t0=$(now)
  out=$(PATH="$WORK/tbin:$PATH" BREAK_SOCK="$BREAK_SOCK" FLEET_CONF_DIR="$d/conf" bash "$BIN/fleet-oldcfg-check.sh" --sweep --list --new-dir "$d/new" -- oc3 2>&1); rc=$?
  SECS=$(since "$t0")
  [ "$rc" = 2 ] || { WHY="the sweep exited $rc, want 2 (something is broken): $(printf '%s' "$out" | tr '\n' '|')"; return 1; }
  case "$out" in *"broken	oc3	w-broken	acme/app	#7	done	"*) ;; *) WHY="the list does not name w-broken as broken with window · repo · issue · state: $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  case "$out" in *"looping	oc3	w-loop	acme/app	#7	looping	"*) ;; *) WHY="the list does not name the looping stale one: $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  case "$out" in *"stale	oc3	w-old	"*) ;; *) WHY="a window with no manifest is not listed stale (the degenerate): $(printf '%s' "$out" | tr '\n' '|')"; return 1 ;; esac
  case "$out" in *"broken	oc3	w-loop"*|*"broken	oc3	w-old"*) WHY="a session that only lacks a new hook, or has no manifest, is marked broken"; return 1 ;; esac
  [ "$(grep -c . "$d/conf/global/agent-cfg.broken")" = 1 ] || { WHY="agent-cfg.broken holds $(grep -c . "$d/conf/global/agent-cfg.broken" 2>/dev/null) row(s), want 1"; return 1; }
  for w in "$wb" "$wl" "$wn"; do
    [ "$(nt display-message -p -t "$w" '#{window_id}')" = "$w" ] || { WHY="window $w was closed — nothing here may reopen a session"; return 1; }
  done
  # the rows producer's judge (fleet_cfg_state) and the word the sidebar draws
  st=$(FLEET_CONF_DIR="$d/conf" bash -c '. "$1/fleet-lib.sh"; fleet_cfg_expected_load; fleet_cfg_broken_load
         for w in "$2" "$3" "$4"; do fleet_cfg_state claude OLD v2 oc3 "$w"; printf "%s " "$FCFG_STATE"; done' _ "$BIN" "$wb" "$wl" "$wn")
  [ "$st" = "broken stale stale " ] || { WHY="fleet_cfg_state says [$st], want [broken stale stale ]"; return 1; }
  word=$(FLEET_UI_LANG=zh bash -c '. "$1/fleet-ui-lang.sh"; fleet_ui_t sidebar_cfg_broken' _ "$BIN")
  [ "$word" = '会坏·需重开' ] || { WHY="the broken row's word is [$word], not 会坏·需重开"; return 1; }
  WHAT="删了 gone.sh / await 的发版后：w-broken 红「会坏·需重开」并点名（窗口·仓库·单号·状态），只缺 new.sh 的 w-loop 黄且列为循环中，没 manifest 的 w-old 照旧黄；三个都没被重开"
}

# ---- tmpdir-shared-root (#2442): a process with no TMPDIR — the `sudo -u` half of
# a same-machine fleet-move, the tmux server it started, every pane in it — once
# fell back to the /tmp/.claude-dash every login shares; the first login made it
# 0700 and the next could not open a worker. Each login now has its own, the one
# its daemons read (macOS: DARWIN_USER_TEMP_DIR), and the server carries it.
drill_tmpdir_shared_root() {
  CAP=10; BREAK_SOCK="$WORK/sock-td"; local d="$WORK/td" t0 out lib want hits
  mkdir -p "$d/home" "$d/conf"
  t0=$(now)
  noenv() { env -u TMPDIR PATH="$WORK/tbin:$PATH" HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
              BREAK_SOCK="$BREAK_SOCK" "$@"; }
  lib=$(noenv bash -c ". '$BIN/fleet-lib.sh'; printf '%s' \"\$FLEET_C\"") || { WHY="fleet-lib.sh did not load with no TMPDIR"; return 1; }
  if [ "$(uname -s)" = Darwin ]; then want="$(getconf DARWIN_USER_TEMP_DIR)/.claude-dash"
  else want="/tmp/claude-fleet-$(id -u)/.claude-dash"; fi
  case "$lib" in /tmp/.claude-dash|/tmp/.claude-dash/) WHY="no TMPDIR still reads the shared /tmp/.claude-dash"; return 1 ;; esac
  [ "$lib" = "$want" ] || { WHY="no TMPDIR reads $lib, not this login's own $want (the daemons' dir)"; return 1; }
  # the later login opens a worker: its dash cache is its own and writable
  out=$(noenv bash -c ". '$BIN/fleet-lib.sh'; mkdir -p \"\$FLEET_C\" && [ -w \"\$FLEET_C\" ] && [ -O \"\$FLEET_C\" ] && echo ok")
  [ "$out" = ok ] || { WHY="this login cannot write its own dash cache $lib"; return 1; }
  # a server started with no TMPDIR: fleet-up / the move's launch stamp it, so a
  # server-side spawn (run-shell, a bind, a hook) reads the same directory
  env -u TMPDIR "$REAL_TMUX" -S "$BREAK_SOCK" -f /dev/null new-session -d -s td 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  noenv bash -c ". '$BIN/fleet-lib.sh'; fleet_server_tmpdir td" || { WHY="fleet_server_tmpdir failed"; return 1; }
  nt run-shell "printf '%s' \"\${TMPDIR:-/tmp/claude-fleet-\$(id -u)}/.claude-dash\" > '$d/srv'"
  until_ok "$CAP" test -s "$d/srv" || { WHY="the server-side spawn wrote nothing"; return 1; }
  [ "$(cat "$d/srv")" = "$lib" ] || { WHY="a server-side spawn reads $(cat "$d/srv"), the session's lib $lib — not one directory"; return 1; }
  SECS=$(since "$t0")
  # and nothing spells the shared fallback any more
  # find -L: under the selftest gate bin/ is a dir of symlinks, which grep -r skips
  # (GNU) — the lint read nothing in CI while two scripts still fell back (T532)
  hits=$(find -L "$ROOT/bin" "$ROOT/hooks" -type f ! -name '*-selftest*' -exec grep -Hn \
           'TMPDIR:-/tmp}/\.claude-dash\|"/tmp", "\.claude-dash"\|'"'/tmp'), '.claude-dash'" {} + 2>/dev/null | head -3)
  [ -z "$hits" ] || { WHY="a script still falls back to the shared /tmp/.claude-dash: $hits"; return 1; }
  WHAT="没有 TMPDIR 的进程（sudo -u 的半边、它起的 tmux 服务器）读写本登录自己的 ${want}：可写、属主是自己；服务器全局环境带上 TMPDIR，服务端起的命令读同一个目录；没有脚本再回退到共用的 /tmp/.claude-dash"
  tmpdir_foreign_leg || return 1
  SECS=$(since "$t0")
}

# tmpdir-shared-root's second leg (#2450): the dash cache already exists and belongs to
# ANOTHER login — the session's TMPDIR was the shared /tmp (the demoted daemon's
# fallback when DARWIN_USER_TEMP_DIR came back empty), or someone made
# /tmp/claude-fleet-<uid> first. fleet-lib must never take it: it moves to a
# per-uid directory of its own and says so; the demoted launch never falls back
# to /tmp. A symlink to a root-owned directory stands in for "another login's".
tmpdir_foreign_leg() {
  local d="$WORK/tfo" out err lib sh
  mkdir -p "$d/t" "$d/home" "$d/fbin"; ln -s /usr "$d/t/.claude-dash"
  out=$(env TMPDIR="$d/t" HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
          bash -c ". '$BIN/fleet-lib.sh'; printf '%s' \"\$FLEET_C\"" 2>"$d/err") || { WHY="fleet-lib.sh did not load"; return 1; }
  lib=$out; err=$(cat "$d/err")
  [ "$lib" != "$d/t/.claude-dash" ] || { WHY="fleet-lib took $lib, which belongs to another login"; return 1; }
  case "$lib" in *"$(id -u)"*|"$d/home/"*) ;; *) WHY="the fallback $lib is not this login's (no uid, not under HOME)"; return 1 ;; esac
  case "$err" in *'another login'*) ;; *) WHY="no stderr line said the dash cache belonged to another login ($err)"; return 1 ;; esac
  out=$(env TMPDIR="$d/t" HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
          bash -c ". '$BIN/fleet-lib.sh' 2>/dev/null; mkdir -p \"\$FLEET_C\" && [ -w \"\$FLEET_C\" ] && [ -O \"\$FLEET_C\" ] && echo ok")
  [ "$out" = ok ] || { WHY="this login cannot write its fallback dash cache $lib"; return 1; }
  # the demoted daemon launch with no DARWIN_USER_TEMP_DIR: never TMPDIR=/tmp
  printf '#!/bin/sh\nexit 1\n' > "$d/fbin/getconf"; chmod +x "$d/fbin/getconf"
  sh=$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("sup",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.ACCOUNT_SH)' "$BIN/fleet-node-supervisor.py") \
    || { WHY="cannot read ACCOUNT_SH from fleet-node-supervisor.py"; return 1; }
  env -u TMPDIR PATH="$d/fbin:/usr/bin:/bin" sh -c "$sh" _ "$d/o.log" "$d/e.log" sh -c 'printf %s "$TMPDIR" > "$0"' "$d/acct"
  case "$(cat "$d/acct" 2>/dev/null)" in /tmp|/tmp/|'') WHY="the demoted launch falls back to TMPDIR=[$(cat "$d/acct" 2>/dev/null)], the shared /tmp"; return 1 ;; esac
  WHAT="${WHAT}；TMPDIR/.claude-dash 属别的登录时 fleet-lib 不用它：stderr 报一行，改用本登录按 uid 分开的 ${lib}（可写、属主是自己）；守护降权拿不到 DARWIN_USER_TEMP_DIR 时 TMPDIR=$(cat "$d/acct")，不再是共享的 /tmp"
}

# ---- shared-dir-foreign-write (#2299): /Users/Shared/claude-fleet is every
# login's. Before, the heavy slots and the event log were 0666 (any login could
# truncate or rewrite them), the first login owned the sticky dirs (and so could
# delete anyone's entry), a file planted under another login's name in sessions/
# counted, and a planted symlink was written through. The drill takes a slot,
# plants the squats, and wants every file 0644 and its writer's, the symlink
# untouched, the squat uncounted, and root's fleet-shared-dirs.py sweeping them.
drill_shared_dir_foreign_write() {
  CAP=15; local d="$WORK/sdf" t0 me bad r
  me=$(id -un); mkdir -p "$d/home/$me" "$d/conf"
  printf 'precious\n' > "$d/victim"
  t0=$(now)
  python3 "$BIN/fleet-shared-dirs.py" --root "$d/shared" --slots 2 >/dev/null 2>&1
  ln -s "$d/victim" "$d/shared/heavy/events.$me.log" 2>/dev/null
  FLEET_HEAVY_DIR="$d/shared/heavy" HOME="$d/home/$me" "$BIN/fleet-heavy.sh" --slots 2 -- true 2>/dev/null \
    || { WHY="fleet-heavy.sh did not run"; return 1; }
  [ "$(cat "$d/victim")" = precious ] || { WHY="a planted events-log symlink was written through"; return 1; }
  FLEET_HEAVY_DIR="$d/shared2/heavy" HOME="$d/home/$me" "$BIN/fleet-heavy.sh" --slots 2 -- true 2>/dev/null
  bad=$(find "$d/shared2" -type f \( -perm -002 -o -perm -020 \) 2>/dev/null)
  [ -z "$bad" ] || { WHY="another login could rewrite: $(ls -l $bad | awk '{print $1, $NF}' | tr '\n' ' ')"; return 1; }
  printf '999 %s\n' "$(date +%s)" > "$d/shared/sessions/mallory"
  r=$(env HOME="$d/home/$me" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_MACHINE_SESSIONS_DIR="$d/shared/sessions" \
        bash -c ". '$BIN/fleet-lib.sh'; fleet_machine_sessions_summary 1" 2>/dev/null)
  [ "${r%%$'\t'*}" = 1 ] || { WHY="a sessions file planted under another login's name counted ($r)"; return 1; }
  python3 "$BIN/fleet-shared-dirs.py" --root "$d/shared" --slots 2 >/dev/null 2>&1
  [ ! -e "$d/shared/sessions/mallory" ] && [ ! -L "$d/shared/heavy/events.$me.log" ] \
    || { WHY="fleet-shared-dirs.py left the squats in place"; return 1; }
  grep -q '"shared-dirs"' "$BIN/fleet-node-supervisor.py" || { WHY="the node supervisor runs no shared-dirs task"; return 1; }
  SECS=$(since "$t0")
  WHAT="共享目录每个文件只归写它的人、0644；种下的软链不被写穿，冒名的计数不算；root 的 shared-dirs 任务把冒名文件清掉"
}

# A new login's first Claude start asks questions nobody in a fleet pane answers —
# on 2026-10-08 the new `erin` logins' `guide` sessions sat on 2.1.293's "Make
# auto mode your default permission mode?" for good (issue #2401). The fake
# `claude` gates exactly as the measured build does: no hasCompletedOnboarding →
# the onboarding; no hasSeenAutoDefaultNudge → that question; both → the prompt.
# A new login goes through the bootstrap's onboard step, an existing login (a
# .claude.json from before #2401) through the settings pass; each must reach the
# input box, with the doctor's reader agreeing.
drill_new_login_first_run_dialog() {
  CAP=10; BREAK_SOCK="$WORK/sock-fr"; local d="$WORK/fr" t0 out
  mkdir -p "$d/new/.claude" "$d/old/.claude"
  cat > "$d/claude" <<'FAKE'
#!/bin/sh
python3 - "$HOME/.claude.json" <<'PY'
import json, sys
try: s = json.load(open(sys.argv[1]))
except Exception: s = {}
if s.get("hasCompletedOnboarding") is not True: print("Choose the text style that looks best with your terminal")
elif s.get("hasSeenAutoDefaultNudge") is not True:
    print("Make auto mode your default permission mode?\n ❯ Yes, set auto mode as my default permission mode\n   No, keep bypass permissions")
else: print("❯ \n  ⏵⏵ bypass permissions on")
PY
exec sleep 600
FAKE
  chmod +x "$d/claude"
  printf '{"hasCompletedOnboarding": true, "numStartups": 3}\n' > "$d/old/.claude.json"
  printf '{}\n' > "$d/old/.claude/settings.json"
  t0=$(now)
  # the new login: the bootstrap's onboard step, before fleet-up opens anything
  out=$(python3 "$BIN/fleet-onboard-defaults.py" "$d/new" 2>&1) || { WHY="the onboard step failed: $out"; return 1; }
  # the existing login: install-apply's settings pass, fill only
  out=$(python3 "$BIN/fleet-hooks-merge.py" defaults --settings "$d/old/.claude/settings.json" --config "$d/old/.claude.json" \
          --override "$d/old/.claude/settings.fleet-override.json" 2>&1) || { WHY="the settings pass failed: $out"; return 1; }
  nt -f /dev/null new-session -d -s fr -n new -x 100 -y 20 "HOME='$d/new' exec '$d/claude'" || { WHY="cannot start the isolated tmux server"; return 1; }
  nt new-window -d -t fr: -n old "HOME='$d/old' exec '$d/claude'"
  frready() { local w p; for w in new old; do p=$(nt capture-pane -p -t "fr:$w" 2>/dev/null)
      case "$p" in *'Make auto mode'*|*'Choose the text style'*) return 1 ;; *'bypass permissions on'*) : ;; *) return 1 ;; esac; done; }
  until_ok "$CAP" frready || { WHY="a first session still stops on a first-run question: new=[$(nt capture-pane -p -t fr:new | tr '\n' '|')] old=[$(nt capture-pane -p -t fr:old | tr '\n' '|')]"; return 1; }
  SECS=$(since "$t0")
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if s.get("numStartups")==3 else 1)' "$d/old/.claude.json" \
    || { WHY="the settings pass dropped the existing login's own keys: $(cat "$d/old/.claude.json")"; return 1; }
  for h in new old; do
    out=$(python3 "$BIN/fleet-onboard-defaults.py" --check "$d/$h" 2>&1) || { WHY="the doctor's firstrun reader says no for the $h login: $out"; return 1; }
  done
  WHAT="新开账号（onboard 步）和已有账号（settings pass 只填不改）第一个会话都直接到输入框：没有 onboarding、没有「Make auto mode your default…」；doctor firstrun 两个都 ok"
}

# A first-login guide that can never come up (issue #2424): its agent exits at
# once with `Session ID … is already in use` (or sits on a spent account). The
# collector's tick reopened it every minute, forever. Now three opens is the
# budget: the tick after writes global/onboard.stuck with the reason and stops.
drill_guide_retry_forever() {
  CAP=10; BREAK_SOCK="$WORK/sock-gd"; local d="$WORK/gd" t0 i n
  mkdir -p "$d/conf/global" "$d/home"
  printf '#!/bin/sh\nprintf x >> "%s/launches"\nprintf "Error: Session ID 2aaef796 is already in use.\\n"\nexec sh\n' "$d" > "$d/agent"
  chmod +x "$d/agent"
  nt -f /dev/null new-session -d -s gd -n home -x 100 -y 20 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  nt new-window -d -t gd: -n guide "$d/agent"
  nt set-option -w -t gd:guide @pin 1
  : > "$d/conf/global/onboard.pending"; printf '1\n' > "$d/conf/global/onboard.tries"   # fleet-up's open
  printf 'drill\n' > "$d/conf/global/onboard.person"   # a person is here (issue #4852)
  t0=$(now)
  for i in 1 2 3 4 5 6; do
    printf '0\n' > "$d/conf/global/onboard.retry"
    ( PATH="$WORK/tbin:$PATH" HOME="$d/home" FLEET_CONF_DIR="$d/conf"; export PATH HOME FLEET_CONF_DIR BREAK_SOCK
      . "$BIN/fleet-lib.sh"; fleet_guide_tick gd ) 2>/dev/null
    sleep 0.3
    # the open runs detached (issue #3320): let it finish before the next tick
    until_ok 5 test ! -e "$d/conf/global/onboard.opening"
  done
  SECS=$(since "$t0")
  n=$(wc -c < "$d/launches" 2>/dev/null | tr -d ' ')
  [ "$n" = 3 ] || { WHY="six ticks opened the guide $n times, want 3 (the budget) — the retry is unbounded"; return 1; }
  grep -q '会话编号被占用' "$d/conf/global/onboard.stuck" 2>/dev/null \
    || { WHY="no onboard.stuck naming the id clash: [$(cat "$d/conf/global/onboard.stuck" 2>/dev/null)]"; return 1; }
  WHAT="引导连开 3 次都没开口：第 4 拍不再重开，写 onboard.stuck（「会话编号被占用 · 连续 3 次没开口」），窗口挂上同一句原因"
}

# A new tenant's first entry lands in a bare shell (issue #3320, linux-a
# 2026-10-11): the guide's open took longer than the collector's 30 s guide phase
# (a scratch checkout of the starter repo + claude's start on a loaded node), the
# phase budget killed it every tick — no window, no try counted, no stop — and a
# stop once written (the admission gate refused the first open) was forever. The
# opener here takes 2 s against a 1 s phase budget; the guide must still open,
# and an old stop must lift by itself.
drill_guide_killed_midopen() {
  CAP=15; BREAK_SOCK="$WORK/sock-gk"; local d="$WORK/gk" t0 f
  mkdir -p "$d/conf/global" "$d/home" "$d/bin"
  for f in "$BIN"/*; do ln -s "$f" "$d/bin/${f##*/}"; done
  rm -f "$d/bin/dash-raw-session.sh"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/opens"\nsleep 2\ntmux new-window -d -t gk: -n guide "exec sleep 600"\ntmux set-option -w -t gk:guide @pin 1\n' "$d" > "$d/bin/dash-raw-session.sh"
  chmod +x "$d/bin/dash-raw-session.sh"
  nt -f /dev/null new-session -d -s gk -n home -x 100 -y 20 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  # the stop the admission gate left on linux-a, written 2 h ago
  : > "$d/conf/global/onboard.pending"; printf '0\n' > "$d/conf/global/onboard.tries"
  printf 'drill\n' > "$d/conf/global/onboard.person"   # a person is here (issue #4852)
  printf '引导窗口没能重开 · 第 1 次 · 2026-10-11 12:38\n' > "$d/conf/global/onboard.stuck"
  printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$d/conf/global/onboard.stuck.ts"
  t0=$(now)
  ( PATH="$WORK/tbin:$PATH" HOME="$d/home" FLEET_CONF_DIR="$d/conf"; export PATH HOME FLEET_CONF_DIR BREAK_SOCK
    . "$d/bin/fleet-lib.sh"; fleet_timebox 1 fleet_guide_tick gk ) >/dev/null 2>&1
  until_ok "$CAP" sh -c "'$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t gk -F '#{window_name} #{@pin}' | grep -qx 'guide 1'" \
    || { WHY="no guide window after a 2 s open under a 1 s phase budget: opens=[$(tr '\n' '|' < "$d/opens" 2>/dev/null)] stuck=[$(cat "$d/conf/global/onboard.stuck" 2>/dev/null)] tries=$(cat "$d/conf/global/onboard.tries" 2>/dev/null)"; return 1; }
  SECS=$(since "$t0")
  grep -q -- '--no-repo' "$d/opens" 2>/dev/null || { WHY="the guide opened on a repo checkout: [$(cat "$d/opens")]"; return 1; }
  [ ! -e "$d/conf/global/onboard.stuck" ] || { WHY="the 2 h old stop is still there"; return 1; }
  [ "$(cat "$d/conf/global/onboard.tries" 2>/dev/null)" = 1 ] || { WHY="the open was not counted: tries=$(cat "$d/conf/global/onboard.tries" 2>/dev/null)"; return 1; }
  WHAT="打开要 2 s、阶段只给 1 s：开窗的那一步不在阶段的进程组里，引导照样开出来（无仓库）、算一次；2 小时前的「没能重开」停止自己解除"
}

# guide-spare-login (issue #4852, a service login, 2026-10-19): every login is
# bootstrapped with a fleet, and fleet-up opened the onboarding guide on each — a
# spare waiting to be handed out, a service login that only coordinates. Closed by
# hand it came straight back (a stop's lift had reset the try count to 0, and the
# «closed ⇒ dismissed» rule asked for tries ≥ 1). For real on an isolated server:
# with nobody arrived the tick opens nothing and closes the pinned guide left
# there; a person's arrival opens it at once; shown and then closed (tries 0) it is
# dismissed, never reopened.
drill_guide_spare_login() {
  CAP=15; BREAK_SOCK="$WORK/sock-gs"; local d="$WORK/gs" t0 f g wid
  mkdir -p "$d/conf/global" "$d/home" "$d/bin"; g="$d/conf/global"
  for f in "$BIN"/*; do ln -s "$f" "$d/bin/${f##*/}"; done
  rm -f "$d/bin/dash-raw-session.sh"
  printf '#!/bin/sh\nprintf x >> "%s/opens"\ntmux new-window -d -t gs: -n guide "exec sleep 600"\ntmux set-option -w -t gs:guide @pin 1\n' "$d" > "$d/bin/dash-raw-session.sh"
  chmod +x "$d/bin/dash-raw-session.sh"
  gl() { ( PATH="$WORK/tbin:$PATH" HOME="$d/home" FLEET_CONF_DIR="$d/conf" FLEET_GUIDE_COOLDOWN=0 FLEET_GUIDE_SPEAK_SECS=0
           export PATH HOME FLEET_CONF_DIR BREAK_SOCK FLEET_GUIDE_COOLDOWN FLEET_GUIDE_SPEAK_SECS
           . "$d/bin/fleet-lib.sh"; "$@" ) 2>/dev/null; until_ok 5 test ! -e "$g/onboard.opening"; }
  guides() { nt list-windows -t gs -F '#{window_name} #{@pin}' 2>/dev/null | grep -c '^guide 1$'; }
  opens() { wc -c 2>/dev/null < "$d/opens" | tr -d ' '; }
  nt -f /dev/null new-session -d -s gs -n home -x 100 -y 20 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  # what an older fleet-up left on a spare: pending, opened once, the guide up
  nt new-window -d -t gs: -n guide 'exec sleep 600'; nt set-option -w -t gs:guide @pin 1
  : > "$g/onboard.pending"; printf '1\n' > "$g/onboard.tries"; printf '0\n' > "$g/onboard.retry"
  t0=$(now)
  gl fleet_guide_tick gs; gl fleet_guide_tick gs
  [ "$(guides)" = 0 ] || { WHY="a pinned guide on a login nobody has reached is still open"; return 1; }
  [ -z "$(opens)" ] || [ "$(opens)" = 0 ] || { WHY="the tick opened a guide with no person: opens=$(opens)"; return 1; }
  [ -f "$g/onboard.pending" ] && [ ! -e "$g/onboard.dismissed" ] || { WHY="closing the spare's leftover was taken as a person's no"; return 1; }
  gl fleet_guide_arrive gs attach
  until_ok 5 sh -c "[ \"\$('$REAL_TMUX' -S '$BREAK_SOCK' list-windows -t gs -F '#{window_name} #{@pin}' | grep -c '^guide 1\$')\" = 1 ]" \
    || { WHY="a person's first attach did not open the guide: opens=$(opens) person=[$(cat "$g/onboard.person" 2>/dev/null)]"; return 1; }
  gl fleet_guide_tick gs
  wid=$(nt list-windows -t gs -F '#{window_name} #{window_id}' | sed -n 's/^guide //p' | head -n 1)
  nt kill-window -t "$wid"
  printf '0\n' > "$g/onboard.tries"; printf '0\n' > "$g/onboard.retry"   # a stop's lift
  gl fleet_guide_tick gs; gl fleet_guide_tick gs
  SECS=$(since "$t0")
  [ "$(guides)" = 0 ] || { WHY="the guide the person closed came back (tries 0)"; return 1; }
  [ "$(opens)" = 1 ] || { WHY="the closed guide was reopened: opens=$(opens)"; return 1; }
  [ -e "$g/onboard.dismissed" ] || { WHY="a shown-then-closed guide was not recorded as dismissed"; return 1; }
  WHAT="没人来过的登录：节拍不开引导、把旧版留下的置顶 guide 关掉（不算「不要」）；人第一次 attach 立刻开；开过又被关（tries 已清零）记 dismissed，不再拉回"
}

drill_cold_fill_fails() {
  # issue #2237: the cold start opens the agent's window before the tree is
  # checked out; a checkout that fails must take that window (and the worktree)
  # with it, and the spawn must say so — never a session on half a tree.
  CAP=10; local d="$WORK/cf" lbl="brkcf-$$" t0 rc
  mkdir -p "$d/o.git" "$d/main" "$d/conf" "$d/tmp" "$d/fb"
  fx_repo "$d/conf" "$lbl" acme/w FLEET_MAIN="$d/main" FLEET_BASE_BRANCH=master
  git init -q --bare "$d/o.git"
  ( cd "$d/main" && git init -q -b master . && git config user.email t@t && git config user.name t \
      && printf 'x\n' > CLAUDE.md && git add -A && git commit -qm i && git remote add origin "$d/o.git" \
      && git push -q origin master ) || { WHY="cannot build the repo"; return 1; }
  printf '#!/bin/sh\nexit 0\n' > "$d/fb/gh"; printf '#!/bin/sh\nexec sleep 60\n' > "$d/fb/agent"; chmod +x "$d/fb/gh" "$d/fb/agent"
  env PATH="$d/fb:$PATH" FLEET_WRAP_LAUNCH="$d/fb/agent" "$REAL_TMUX" -L "$lbl" -f /dev/null new-session -d -s "$lbl" -n home \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  t0=$(now)
  env -u TMUX -u TMUX_PANE -u CCQUOTA_FLEET PATH="$d/fb:$PATH" FLEET_CONF_DIR="$d/conf" TMPDIR="$d/tmp" \
    FLEET_ORIGIN_GATE=0 FLEET_REPO=acme/w FLEET_MAIN="$d/main" FLEET_BASE_BRANCH=master \
    FLEET_WORKTREE_ROOT="$d/wt" FLEET_SPAWN_FILL_CMD='sleep 1; exit 1' \
    bash "$BIN/dash-issue-session.sh" 5 "$lbl" --title t --origin hub --print > "$d/out" 2> "$d/err"; rc=$?
  SECS=$(since "$t0")
  local wins; wins=$("$REAL_TMUX" -L "$lbl" list-windows -t "$lbl" -F '#{@issue}' 2>/dev/null)
  "$REAL_TMUX" -L "$lbl" kill-server >/dev/null 2>&1
  [ "$rc" = 1 ] || { WHY="the spawn exited $rc, want 1"; return 1; }
  grep -q 'worktree checkout' "$d/err" || { WHY="the spawn did not say the checkout failed: $(tr '\n' '|' < "$d/err")"; return 1; }
  case " $(printf '%s ' $wins)" in *" 5 "*) WHY="the window of the failed checkout is still open"; return 1 ;; esac
  [ -z "$(ls -d "$d"/wt/*issue-5 2>/dev/null)" ] || { WHY="the half worktree is still there"; return 1; }
  WHAT="检出失败：会话窗口和半截 worktree 都收走，派发方得到 exit 1「worktree checkout」"
}

# brew-keg-700 (issue #2283): brew pours with the caller's umask, so an owner on
# 077 leaves kegs (and opt links) only it can read — every other login on the
# machine loses python ssl / tmux. The diskguard tick's brew pass repairs them to
# go+rX, as the prefix's owner, on a machine with 2+ logins; one login, or not
# the owner ⇒ nothing changes (the doctor names the owner). etc/*/private stays
# private. Another uid reads the repaired file when sudo -n can show it.
drill_brew_keg_700() {
  CAP=5; local d p t0 out x
  d="$(mktemp -d /tmp/brk-brew.XXXXXX)" || { WHY="no tmp dir"; return 1; }
  chmod 755 "$d"; p="$d/brew"
  mkdir -p "$p/Cellar/ok/1/bin" "$p/opt" "$p/etc/x"; chmod -R 755 "$p"
  ( umask 077
    mkdir -p "$p/Cellar/tmux/3.7c/lib" "$p/etc/x/private"
    printf 'x\n' > "$p/Cellar/tmux/3.7c/lib/libjemalloc.2.dylib"
    ln -s ../Cellar/tmux/3.7c "$p/opt/tmux" )
  bw() { env FLEET_BREW_PREFIX="$p" FLEET_BREW_PERMS_EVERY=0 FLEET_CONF_DIR="$d/conf" "$@" \
         bash "$BIN/fleet-diskguard.sh" --brew-watch >/dev/null 2>&1; }
  mode() { ls -ld "$1" | cut -c1-10; }
  bw FLEET_BREW_LOGINS=1
  [ "$(mode "$p/Cellar/tmux/3.7c")" = drwx------ ] || { WHY="one login: the keg was changed ($(mode "$p/Cellar/tmux/3.7c"))"; rm -rf "$d"; return 1; }
  bw FLEET_BREW_LOGINS=2 FLEET_BREW_ME=someone-else
  [ "$(mode "$p/Cellar/tmux/3.7c")" = drwx------ ] || { WHY="not the owner: the keg was changed"; rm -rf "$d"; return 1; }
  out="$(FLEET_BREW_PREFIX="$p" FLEET_BREW_LOGINS=2 FLEET_BREW_ME=someone-else bash "$BIN/fleet-brew-perms.sh" --doctor)"
  case "$out" in warn*"owned by $(id -un)"*"chmod -R go+rX"*) ;; *) WHY="non-owner doctor line: [$out]"; rm -rf "$d"; return 1 ;; esac
  t0=$(now)
  bw FLEET_BREW_LOGINS=2
  SECS=$(since "$t0")
  for x in "$p/Cellar/tmux" "$p/Cellar/tmux/3.7c" "$p/Cellar/tmux/3.7c/lib"; do
    [ "$(mode "$x")" = drwxr-xr-x ] || { WHY="$x is $(mode "$x") after the tick"; rm -rf "$d"; return 1; }
  done
  [ "$(mode "$p/Cellar/tmux/3.7c/lib/libjemalloc.2.dylib")" = -rw-r--r-- ] || { WHY="the dylib is $(mode "$p/Cellar/tmux/3.7c/lib/libjemalloc.2.dylib")"; rm -rf "$d"; return 1; }
  [ "$(uname -s)" = Darwin ] && { [ "$(mode "$p/opt/tmux")" = lrwxr-xr-x ] || { WHY="opt/tmux is $(mode "$p/opt/tmux")"; rm -rf "$d"; return 1; }; }
  [ "$(mode "$p/etc/x/private")" = drwx------ ] || { WHY="etc/x/private was opened"; rm -rf "$d"; return 1; }
  [ -z "$(FLEET_BREW_PREFIX="$p" bash "$BIN/fleet-brew-perms.sh" --scan)" ] || { WHY="--scan still lists paths"; rm -rf "$d"; return 1; }
  grep -q "keg $p/Cellar/tmux/3.7c fixed" "$d/conf/diskguard/brew-perms.log" 2>/dev/null || { WHY="no log line for the keg"; rm -rf "$d"; return 1; }
  if sudo -n -u nobody true 2>/dev/null; then
    sudo -n -u nobody cat "$p/opt/tmux/lib/libjemalloc.2.dylib" >/dev/null 2>&1 || { WHY="nobody still cannot read the dylib"; rm -rf "$d"; return 1; }
    WHAT="一个登录 / 不是属主都不动；属主那一拍把 700 的 keg、opt 链接改回 go+rX，另一个 uid（nobody）读得到，etc/*/private 不碰"
  else
    WHAT="一个登录 / 不是属主都不动；属主那一拍把 700 的 keg、opt 链接改回 go+rX（无 sudo，按权限位判），etc/*/private 不碰"
  fi
  rm -rf "$d"
}

drill_pretrust_norepo() {
  # issue #2282: on a trusted node a fleet-opened @norepo session in $HOME must
  # not park on Claude Code's "trust this folder?" dialog; on an untrusted node the
  # same launch leaves ~/.claude.json byte for byte. The fake claude does what
  # Claude Code does: an exact-key lookup of its cwd in ~/.claude.json.
  CAP=10; local d="$WORK/ptn" sock="$WORK/sock-ptn" t0 w go verdict
  mkdir -p "$d/home" "$d/conf/fleets/ptn" "$d/conf/cred-proxy" "$d/fb"
  printf 'FLEET_SESSION=ptn\n' > "$d/conf/fleets/ptn/conf"
  printf '{"numStartups": 7, "projects": {"/elsewhere": {"hasTrustDialogAccepted": true}}}\n' > "$d/home/.claude.json"
  cp "$d/home/.claude.json" "$d/before.json"
  cat > "$d/fb/claude" <<'FAKE'
#!/bin/sh
python3 -c 'import json, os, sys
d = json.load(open(os.path.join(os.environ["HOME"], ".claude.json")))
ok = d.get("projects", {}).get(os.getcwd(), {}).get("hasTrustDialogAccepted") is True
open(sys.argv[1], "w").write("no-dialog" if ok else "dialog")' "$PTN_OUT"
FAKE
  chmod +x "$d/fb/claude"
  "$REAL_TMUX" -S "$sock" -f /dev/null new-session -d -s ptn -n home || { WHY="cannot start the isolated tmux server"; return 1; }
  ptn_launch() { # <word in trust.json> → the fake claude's verdict in $d/out.<word>
    printf '{"trust": "%s", "why": "hub: %s", "ts": %s}\n' "$1" "$1" "$(date +%s)" > "$d/conf/cred-proxy/trust.json"
    go="$d/go.$1"
    w=$("$REAL_TMUX" -S "$sock" new-window -d -P -F '#{window_id}' -t ptn -c "$d/home" \
        "while [ ! -f '$go' ]; do sleep 0.05; done; exec env -i HOME='$d/home' PATH='$d/fb:/usr/bin:/bin:$(dirname "$REAL_TMUX")' TMUX=\"\$TMUX\" TMUX_PANE=\"\$TMUX_PANE\" FLEET_CONF_DIR='$d/conf' FLEET_MOD=0 FLEET_AGENT_CFG=0 FLEET_CLAUDE_BIN='$d/fb/claude' PTN_OUT='$d/out.$1' bash '$BIN/fleet-claude.sh' >'$go.log' 2>&1")
    "$REAL_TMUX" -S "$sock" set-option -w -t "$w" @norepo 1
    : > "$go"
    until_ok 8 test -s "$d/out.$1"
  }
  ptn_launch untrusted || { WHY="the untrusted launch never reached claude: $(cat "$d/go.untrusted.log" 2>/dev/null)"; return 1; }
  cmp -s "$d/home/.claude.json" "$d/before.json" || { WHY="untrusted node: ~/.claude.json changed: $(cat "$d/home/.claude.json")"; return 1; }
  [ "$(cat "$d/out.untrusted")" = dialog ] || { WHY="untrusted node: the folder was trusted anyway"; return 1; }
  t0=$(now)
  ptn_launch trusted || { WHY="the trusted launch never reached claude: $(cat "$d/go.trusted.log" 2>/dev/null)"; return 1; }
  SECS=$(since "$t0")
  verdict=$(cat "$d/out.trusted")
  "$REAL_TMUX" -S "$sock" kill-server >/dev/null 2>&1
  [ "$verdict" = no-dialog ] || { WHY="trusted node: the @norepo session in \$HOME still meets the trust dialog: $(cat "$d/go.trusted.log")"; return 1; }
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("numStartups") == 7 and "/elsewhere" in d["projects"] and len(d["projects"]) == 2 else 1)' "$d/home/.claude.json" \
    || { WHY="trusted node: wrote more than \$HOME, or lost a key: $(cat "$d/home/.claude.json")"; return 1; }
  WHAT="可信节点上 @norepo 会话开在 \$HOME 不再停在信任框（只多写 \$HOME 一项）；不可信节点同样开，~/.claude.json 一字不差"
}

# go_half <run regex> <package>… — a drill's Go half (the hub's or the agent's):
# its tests run for real in tokenledger/ where a toolchain is, offline. 0 green ·
# 1 red, or none ran (WHY set) · 2 no module cache / toolchain here · 3 no go, or
# BREAK_GO=0. On 2 and 3 the Go gate (tokenledger.yml) runs them.
go_half() {
  local run=$1 out rc; shift
  { [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; } || return 3
  out=$(cd "$ROOT/tokenledger" && GOFLAGS='' GOPROXY=off GOTOOLCHAIN=local go test -count=1 -run "$run" "$@" 2>&1); rc=$?
  case "$rc:$out" in
    0:*'no tests to run'*) WHY="the Go tests $run are not there (go test ran none)"; return 1 ;;
    0:*) return 0 ;;
    *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) return 2 ;;
    *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | grep -v '^20' | head -6 | tr '\n' ' ')"; return 1 ;;
  esac
}

# ---- the hub-half drills of #2696 share one runner: the named Go tests must
# exist, the greps must hold, and with a toolchain they must pass.
_drill_go_tests() {  # <tests> <test file> <what> [<package>, default ./hub/api]
  local tests=$1 f=$2 what=$3 pkg=${4:-./hub/api} t
  for t in $tests; do
    grep -q "^func $t(" "$f" 2>/dev/null || { WHY="the hub half's test $t is not in ${f#$ROOT/}"; return 1; }
  done
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" "$pkg"; case $? in
    0) WHAT=$what ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；测试按名核对在' ;;
    3) WHAT='没有 go：测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
}

# ---- opening-never-ends (#2696): a newcomer's login that cannot be opened
# read 「about 5s」 forever — a fixed 60 s ETA floored at 5, and no end to
# pending / creating / unknown. Now: the machine's measured ETA, and failed +
# why + who to ask past openingGiveUp or with no admin node to run it.
drill_opening_never_ends() {
  CAP=120; local t0 f="$ROOT/tokenledger/hub/api/fleet_opening.go"
  t0=$(now)
  grep -q 's.openingStuck(\*opening, now)' "$f" \
    || { WHY="accountStateOf no longer ends an opening nobody can finish"; return 1; }
  grep -q 's.openingETAFor(opening.Hostname)' "$f" \
    || { WHY="accountStateOf's ETA is no longer the machine's measured one"; return 1; }
  _drill_go_tests 'TestOpeningHasAnHonestETAAndAnEnd' "$ROOT/tokenledger/hub/api/fleet_opening_test.go" \
    '开号预计时长取这台机器的中位数、超时改说离放弃多久；20 分钟没回音或没有管理节点 → failed + why + 找谁（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- opening-eta-climbs (#2728): past the machine's median the ETA switched to
# the time left until the give-up — a number that jumps UP (313 s, then 858 s).
# Now one countdown that starts at the median and only goes down.
drill_opening_eta_climbs() {
  CAP=120; local t0 f="$ROOT/tokenledger/hub/api/fleet_opening.go"
  t0=$(now)
  grep -q 'openingETALeft(s.openingETAFor(opening.Hostname), took)' "$f" \
    || { WHY="accountStateOf's ETA is no longer the one countdown (openingETALeft)"; return 1; }
  if grep -q 'eta = int((openingGiveUp - took).Seconds())' "$f"; then
    WHY="past the median the ETA still jumps to the time until the give-up"; return 1
  fi
  _drill_go_tests 'TestOpeningETANeverClimbs' "$ROOT/tokenledger/hub/api/fleet_opening_test.go" \
    '开号预计剩余从中位数起只减不增，到放弃时限归零（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- opened-login-fleet-silent (#2941): the node said create ok, the account went
# active, and every door went quiet while the login's own fleet never reached
# the hub — placement said 「mac-d: 没有你的登录」, the client gave up after two
# tries, and an opening far past its machine's ETA never failed. Now: active
# counts once its fleet registered, else opening (stage fleet) then failed with
# the missing step; the refusal names the login; past ETA × 3 is failed; the
# client's first session waits on the hub's opening.
drill_opened_login_fleet_silent() {
  CAP=120; local t0 f="$ROOT/tokenledger/hub/api/fleet_opening.go"
  t0=$(now)
  grep -q 'reported\[\[2\]string{a.Hostname, a.Login}\]' "$f" \
    || { WHY="accountStateOf reads an opened login as done before its fleet reported"; return 1; }
  grep -q 's.openingNotes(p.Person)' "$ROOT/tokenledger/hub/api/fleet_write.go" \
    || { WHY="a refused placement no longer names the login being opened"; return 1; }
  grep -q 'took > openingOver(est)' "$f" \
    || { WHY="an opening far past its machine's ETA no longer fails"; return 1; }
  grep -q 'FLEET_HOME_FIRST_OPENING_MAX' "$ROOT/bin/fleet-thin.py" \
    || { WHY="the thin client's first session no longer waits while the hub says opening"; return 1; }
  _drill_go_tests 'TestOpenedLoginWithoutFleetIsNotDone TestOpeningPastItsOwnETAFails' \
    "$ROOT/tokenledger/hub/api/fleet_opening_test.go" \
    '开好的登录要等它的 fleet 报上来才算好：之前 opening(stage fleet)，10 分钟后 failed 说缺哪步；放置点名；超过预计 ×3 failed（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- stale-admin-opens-login (#3032): mac-d's only admin node was an old
# standalone agent (prod-e715029, before #2652) restored from the attic; the
# hub sent it the create, it dropped the join code, and the login it opened
# never came up. Now an admin says CapLoginJoin when its create hands the code
# on; a create goes only to one that said it, placement skips a machine
# without one, and the words name the stale admin.
drill_stale_admin_opens_login() {
  CAP=120; local t0 a="$ROOT/tokenledger/hub/api"
  t0=$(now)
  grep -q 'c.canLoginJoin' "$a/nodes.go" \
    || { WHY="openerFor no longer needs the admin's CapLoginJoin"; return 1; }
  grep -q 's.nodes.openerFor(a.Hostname)' "$a/fleet_accounts.go" \
    || { WHY="dispatchAccounts sends a create to any admin again"; return 1; }
  grep -q 'caps = append(caps, control.CapLoginJoin)' "$ROOT/tokenledger/agent/node.go" \
    || { WHY="the admin agent no longer says CapLoginJoin in its hello"; return 1; }
  _drill_go_tests 'TestStaleAdminIsNeverSentACreate TestLeastBusySkipsAMachineWithOnlyAStaleAdmin' \
    "$a/fleet_stale_admin_test.go" \
    '比发布旧的管理员 agent（hello 没有 login_join）收不到 create，放置不挑它的机器，入口原话点名它；新管理员一连上就接走排队的开号（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- spare-reuse-leaks (#3507, EPIC #3500 C11): a login washed for the next
# person still held the last one's crontab, own services, entry keys file,
# credsep store, onboarding kit, keychain and git/ssh credentials — and nobody
# looked. Now one category table (fleet-login-reset-check.py) is the list: the
# selftest plants one thing per category in a sandbox, every one is reported,
# clearing one drops exactly that one, and a category the table lost is red.
drill_spare_reuse_leaks() {
  CAP=60; local t0 out
  t0=$(now)
  [ -f "$ROOT/bin/fleet-login-reset-check.py" ] \
    || { WHY="no bin/fleet-login-reset-check.py: nobody checks what the last person left on a reused login"; return 1; }
  out=$(bash "$ROOT/bin/fleet-login-reset-check-selftest.sh" 2>&1) \
    || { WHY="fleet-login-reset-check-selftest.sh is red: $(printf '%s\n' "$out" | grep -m1 'FAIL')"; return 1; }
  WHAT="每类种一样 → reset: dirty 报出全部 $(printf '%s\n' "$out" | sed -n 's/^categories: //p') 类；清掉一类只少一类；--since 只认早于洗号的；表里少一类即红（沙盒真跑检查器）"
  SECS=$(since "$t0")
}

# ---- home-template-leak (#4194): a recycled login's new home is a clone of
# root's standard home — and the template carried someone's credentials or
# session, or a login could change it, so every later person got the same leak
# (or poison). Now root builds it from the runtime alone, refuses anything
# credential-shaped, keeps it 0700 root, and a clone is a copy.
drill_home_template_leak() {
  CAP=60; local t0 out
  t0=$(now)
  [ -f "$ROOT/bin/fleet-home-template.py" ] \
    || { WHY="no bin/fleet-home-template.py: a recycle has no template, or one nobody checks"; return 1; }
  out=$(bash "$ROOT/bin/fleet-home-template-selftest.sh" 2>&1) \
    || { WHY="fleet-home-template-selftest.sh is red: $(printf '%s\n' "$out" | grep -m1 'FAIL')"; return 1; }
  WHAT='模板从运行时建、剥会话与 id；node.env / 令牌 / 二进制写死暂存路径 → 整份拒绝；root 0700；克隆改写路径、ctime 晚于洗号、改克隆不动模板（沙盒真跑）'
  SECS=$(since "$t0")
}

# ---- spare-recycle-dirty (#3504, EPIC #3500 C12): a removed person's login is
# washed into a spare for the next person — and the hub still held the last
# person's node token, relay credential, leases, 家 or a join code for it, or a
# wash that said dirty / not separated / nothing was handed out all the same.
# Now: cleared before the reset is sent, checked again before the spare is
# recorded, and anything unclean leaves the row failed, never handed out.
drill_spare_recycle_dirty() {
  CAP=120; local t0 f="$ROOT/tokenledger/hub/api/fleet_recycle.go"
  t0=$(now)
  grep -Eq 'recycleLeftovers(As)?\(\*a, now' "$f" \
    || { WHY="applyReset no longer checks the hub's half before recording the spare"; return 1; }
  grep -q 'case res.Reset != control.ResetClean:' "$f" \
    || { WHY="applyReset no longer refuses a wash that did not say reset: clean"; return 1; }
  _drill_go_tests 'TestRemoveRecyclesLoginIntoSpare TestRecycleNeverHandsOutAnUncleanWash TestRecycleLeftoversNamesEachHubPiece TestRecycleNoAnswerFailsAfterThirtyMinutes TestRemoveOldRoadWhenNotRecycling' \
    "$ROOT/tokenledger/hub/api/fleet_recycle_test.go" \
    '删号发 reset、洗净且隔离才成备用（spare.recycle）；dirty / 没隔离 / 没结论 / 跑失败 / 30 分钟无回音都 failed 不发出；入口侧节点令牌·中转·租约·家·未用 join code 先清后查；delete / 备用关 / 老 admin 走老路（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- spare-wash-resume (#3505, EPIC #3500 C20): a Mac login washed for the
# next person in place (remove --recycle) — cut off half way, or missing one
# kind of leftover, and a second run either archived again, took the half-made
# setup for the last person's, or called a half-washed login clean. Now one
# script (fleet-login-reset.sh) stops, washes, sets up and checks, booking each
# phase by op_id; its selftest plants one thing per category, kills it mid
# rejoin and runs the same op again.
drill_spare_wash_resume() {
  CAP=90; local t0
  t0=$(now)
  [ -f "$ROOT/bin/fleet-login-reset.sh" ] \
    || { WHY="no bin/fleet-login-reset.sh: remove --recycle has nothing to wash a login with"; return 1; }
  grep -q -- '--recycle)' "$ROOT/bin/fleet-login-remove.sh" \
    || { WHY="fleet-login-remove.sh has no --recycle: the hub's reset op fails at its first word"; return 1; }
  # part 1 of fleet-login-reset-selftest.sh owns the A–F wash/resume/refusal path
  suite_holds 'fleet-login-reset-selftest.sh#1' || return 1
  WHAT="每类种一样 → 洗完 reset: clean + credsep: separated；留一个进程 → dirty processes；重新加入失败 → dirty rejoin；半路杀掉同 op 再跑续完、只一份存档（fleet-login-reset-selftest.sh#1 沙盒真跑检查器，这里按名守住）"
  SECS=$(since "$t0")
}

# ---- recycle-rejoins (#4195, #4194 A): every recycle re-joined the hub with a
# fresh join code (8.9–13.1 s of [7a]) though only root ever held the login's
# token. Now a login the machine daemon serves keeps it root's through the wash
# (fleet-login-reset.sh step 0, credsep setenv back, adopt from the store), the
# hub (CapRecycleKeep) leaves that node enrolled and changes only who the login
# belongs to; a token the person could reach still re-joins.
drill_recycle_rejoins() {
  CAP=150; local t0
  t0=$(now)
  grep -q 'FLEET_LOGIN_KEEP_NODE' "$ROOT/bin/fleet-login-reset.sh" \
    || { WHY="fleet-login-reset.sh no longer keeps the root-held node token: every recycle re-joins"; return 1; }
  grep -q 'logins/\$LOGIN.env' "$ROOT/bin/fleet-login-reset.sh" \
    || { WHY="fleet-login-reset.sh keeps a token without asking whether only the machine daemon ever served it"; return 1; }
  # part 2 of fleet-login-reset-selftest.sh runs the keep leg (K) for real
  suite_holds 'fleet-login-reset-selftest.sh#2' 'K not served by the machine daemon' || return 1
  _drill_go_tests 'TestRecycleKeepsRootHeldNode TestRecycleKeptNodeAmbiguousFails' \
    "$ROOT/tokenledger/hub/api/fleet_recycle_keep_test.go" \
    '机器守护代管的登录令牌回收时留在 root（不再 [7a] join）、入口只改归属（spare）并作废旧人的通行证·租约·连接·证书；令牌旧人碰得到过照旧重新入网；留下的节点说不清是哪个就失败（沙盒真跑洗号 + go test）' || return 1
  SECS=$(since "$t0")
}

# ---- recycle-old-cert (#4195): a recycled login's last person kept a live SSH
# certificate naming it (12 h), and the hub never listed it — a door would
# still let them in as the next person's login. Now every recycle puts the
# person's scope on this machine and each live certificate naming the login on
# the revocation list (refused within 10 s), and recycleLeftovers reds on one
# not there.

# PV4D: board-only plans keep their engine and coordination evidence.
drill_board_plan_facts() {
  CAP=120; local out t0
  t0=$(now)
  out=$(python3 "$BIN/fleet-view-board-selftest.py" 2>&1) || { WHY="$out"; return 1; }
  _drill_go_tests 'TestBoardPlanFacts' "$ROOT/tokenledger/hub/api/fleet_board_test.go" '计划、运行证据及协调归属分别显示' || return 1
  SECS=$(since "$t0")
}

drill_recycle_old_cert() {
  CAP=90; local t0 f="$ROOT/tokenledger/hub/api/fleet_recycle.go"
  t0=$(now)
  grep -q 'recycleRevokePerson(a, now' "$f" \
    || { WHY="recycleClear no longer revokes the last person's certificates"; return 1; }
  grep -q '"cert"' "$f" \
    || { WHY="recycleLeftovers no longer checks the last person's certificates are on the list"; return 1; }
  _drill_go_tests 'TestRecycleRevokesOldCertsWhenRejoining TestRecycleKeepsRootHeldNode' \
    "$ROOT/tokenledger/hub/api/fleet_recycle_keep_test.go" \
    '回收时旧人在这台的范围吊销 + 每张仍有效、写着这个登录的 SSH 证书上吊销名单（ssh:<serial>），留号与重新入网两条路都是；审计 spare.revoke（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- login-remove-record-left (#2728): sysadminctl -deleteUser took the home
# and left the record (drill10092046 on mac-c), and the script said done —
# the hub read removed and the OS login was nobody's. Now step 6 reads the
# record again: dscl -delete it, and exit 1 if even that leaves it.
drill_login_remove_record_left() {
  CAP=60; local t0
  t0=$(now)
  grep -q 'record still there after deleteUser' "$ROOT/bin/fleet-login-remove.sh" \
    || { WHY="fleet-login-remove.sh no longer checks the record is gone after deleteUser"; return 1; }
  suite_holds fleet-login-remove-selftest.sh "'record still there after deleteUser'" || return 1
  WHAT='deleteUser 留下账号记录 → dscl -delete 补删；补删不掉 → 退 1，不说 done（fleet-login-remove-selftest.sh 真跑 shim 化的 remove，这里按名守住）'
  SECS=$(since "$t0")
}

# ---- login-remove-respawn-hang (#2866): launchd's per-user domain brought
# distnoted back after step 4's pkill, and sysadminctl -deleteUser hung on it
# for minutes a try (drill10100326 on mac-c, 9m27s and counting). Now the
# login's user/gui domains are booted out before every kill, nothing may come
# back for a settle window, and deleteUser runs under a time limit.
drill_login_remove_respawn_hang() {
  CAP=60; local t0
  t0=$(now)
  grep -q 'launchctl bootout "user/\$UID_TARGET"' "$ROOT/bin/fleet-login-remove.sh" \
    || { WHY="fleet-login-remove.sh no longer boots out the login's user domain before killing"; return 1; }
  grep -q 'FLEET_LOGIN_REMOVE_DELETE_SECS' "$ROOT/bin/fleet-login-remove.sh" \
    || { WHY="fleet-login-remove.sh runs sysadminctl -deleteUser with no time limit"; return 1; }
  # the recovery is the two legs' own runs (respawn quieted, hanging deleteUser cut
  # off), each timed and bounded inside fleet-login-remove-selftest.sh
  suite_holds fleet-login-remove-selftest.sh "printf 'leg respawn %ss" "printf 'leg delete-hang %ss" || return 1
  SECS=$(since "$t0")
  WHAT='pkill 之后 distnoted 被 launchd 拉回 → 先 bootout user/gui 域再杀、删号不挂；deleteUser 挂住 → 到时限杀掉（fleet-login-remove-selftest.sh 真跑 shim 化的 remove，这里按名守住）'
}

# ---- newcomer-login-no-gh (#2953): a login the hub opened for a newcomer has
# no gh and hosts no repo; the ready check wanted gh all the same, so auto never
# placed the first (HOME) session there. Now gh holds only a login with a repo.
drill_newcomer_login_no_gh() {
  CAP=30; local t0 w got
  t0=$(now)
  w=$(mktemp -d "${TMPDIR:-/tmp}/brk-nogh.XXXXXX")
  mkdir -p "$w/bin" "$w/home/.claude" "$w/c1/fleets/solo" "$w/c2/fleets/app" "$w/main"
  printf '#!/bin/sh\nexit 1\n' > "$w/bin/gh"; printf '#!/bin/sh\nexit 1\n' > "$w/bin/security"
  chmod +x "$w/bin/gh" "$w/bin/security"; printf '{}' > "$w/home/.claude/.credentials.json"
  printf 'FLEET_SESSION=solo\n' > "$w/c1/fleets/solo/conf"
  : > "$w/c2/fleets/app/conf"
  fx_repo "$w/c2" "app" acme/app FLEET_MAIN="$w/main"
  got=$(HOME="$w/home" FLEET_CONF_DIR="$w/c1" PATH="$w/bin:$PATH" bash "$ROOT/bin/fleet-control-read.sh" ready 2>/dev/null)
  case "$got" in *'"ready":true'*) ;; *) rm -rf "$w"; WHY="a login with no repo and no gh reads not ready: $got"; return 1 ;; esac
  got=$(HOME="$w/home" FLEET_CONF_DIR="$w/c2" PATH="$w/bin:$PATH" bash "$ROOT/bin/fleet-control-read.sh" ready 2>/dev/null)
  rm -rf "$w"
  case "$got" in *'"ready":false'*'"gh"'*) ;; *) WHY="a login hosting a repo with no gh reads ready: $got"; return 1 ;; esac
  grep -q 'home-session.first' "$ROOT/bin/fleet-client-place.sh" \
    || { WHY="fleet-client-place.sh tells a newcomer's client to host here again"; return 1; }
  WHAT='没有仓库、没有 gh 的新登录 → ready；有仓库没 gh → not ready: gh；新人客户端不再被叫去本机 host on（真跑就绪检查）'
  SECS=$(since "$t0")
}

# ---- login-remove-no-fda (#2953): the node program has no Full Disk Access, so
# TCC kept sysadminctl -deleteUser out of the home's ~/Desktop and it failed every
# hub-sent remove (33 of 33 on mac-d), exit 1 with the record left. Now a failed
# deleteUser is checked like a timed-out one: the record goes with dscl, the home
# left behind is moved aside, and the node log keeps the script's last words.
drill_login_remove_no_fda() {
  CAP=60; local t0
  t0=$(now)
  grep -q 'checking what it left' "$ROOT/bin/fleet-login-remove.sh" \
    || { WHY="fleet-login-remove.sh stops at a failed deleteUser again"; return 1; }
  grep -q 'accountWhy(res.Detail)' "$ROOT/tokenledger/agent/node_accounts.go" \
    || { WHY="the node log no longer says why an account op failed"; return 1; }
  suite_holds fleet-login-remove-selftest.sh 'FAKE_TCC=1' || return 1
  WHAT='deleteUser 因 TCC 失败 → dscl 补删记录、剩下的家目录挪开、退 0；记录还删不掉 → 退 1（fleet-login-remove-selftest.sh 真跑 shim 化的 remove，这里按名守住）'
  SECS=$(since "$t0")
}

# ---- account-remove-tenant-held (#2953): the supervisor holds the node
# program's restart while an account op runs, so the login being removed kept
# its tenant — reads started as it while the remove waited for quiet. Now
# nothing starts as a login while its remove runs.
drill_account_remove_tenant_held() {
  CAP=120; local t0
  t0=$(now)
  grep -q 'defer holdLogin(op.Login)()' "$ROOT/tokenledger/agent/node_accounts.go" \
    || { WHY="runAccountScript no longer holds the login it removes"; return 1; }
  _drill_go_tests 'TestHoldLoginRefusesItsCommands' "$ROOT/tokenledger/agent/runas_unix_test.go" \
    '删号跑着时节点程序不以该登录起命令、别的登录照常、删完放开（go test）' github.com/verkyyi/claude-fleet/tokenledger/agent || return 1
  SECS=$(since "$t0")
}

# ---- newcomer-login-hosts-repo (#2973): the hub's new login comes up on the
# starter repo (fleet-up --seed, #1167), so ready counted a hosted repo and wanted
# gh again. A seed repo only looks: it needs no gh.
drill_newcomer_login_hosts_repo() {
  CAP=30; local t0 w got
  t0=$(now)
  w=$(mktemp -d "${TMPDIR:-/tmp}/brk-seed.XXXXXX")
  mkdir -p "$w/bin" "$w/home/.claude" "$w/c/fleets/fleet/repos" "$w/main"
  printf '#!/bin/sh\nexit 1\n' > "$w/bin/gh"; printf '#!/bin/sh\nexit 1\n' > "$w/bin/security"
  chmod +x "$w/bin/gh" "$w/bin/security"; printf '{}' > "$w/home/.claude/.credentials.json"
  printf 'FLEET_SESSION=fleet\n' > "$w/c/fleets/fleet/conf"
  printf 'FLEET_REPO=verkyyi/claude-fleet\nFLEET_MAIN=%s/main\nFLEET_SEED=1\n' "$w" > "$w/c/fleets/fleet/repos/verkyyi-claude-fleet.conf"
  got=$(HOME="$w/home" FLEET_CONF_DIR="$w/c" PATH="$w/bin:$PATH" bash "$ROOT/bin/fleet-control-read.sh" ready 2>/dev/null)
  case "$got" in *'"ready":true'*) ;; *) rm -rf "$w"; WHY="a login on the seed repo only, no gh, reads not ready: $got"; return 1 ;; esac
  # …but only for a start with no repo (#3424): an issue on the seed repo needs gh.
  case "$got" in *'"repo_ready":false,"repo_missing":["gh"]'*) ;; *) rm -rf "$w"; WHY="a login on the seed repo only, no gh, reads ready for a repo start: $got"; return 1 ;; esac
  printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$w" > "$w/c/fleets/fleet/repos/acme-app.conf"
  got=$(HOME="$w/home" FLEET_CONF_DIR="$w/c" PATH="$w/bin:$PATH" bash "$ROOT/bin/fleet-control-read.sh" ready 2>/dev/null)
  rm -rf "$w"
  case "$got" in *'"ready":false'*'"gh"'*) ;; *) WHY="a login with a repo of its own and no gh reads ready: $got"; return 1 ;; esac
  WHAT='只托管起步仓库（--seed）的新登录缺 gh → 无仓库的会话 ready、带仓库的开单 repo_ready:false 缺 gh；再加自己的仓库 → not ready: gh（真跑就绪检查）'
  SECS=$(since "$t0")
}

# ---- login-remove-dscl-denied (#2973): with no Full Disk Access in the node
# program's chain, even root's dscl . -delete is refused (eDSPermissionError) and
# the hub's remove stays removing. Now the daemon reads its FDA and the status line
# / doctor name what to grant; the script's last words say Full Disk Access.
drill_login_remove_dscl_denied() {
  CAP=60; local t0 got
  t0=$(now)
  got=$(cd "$ROOT/bin" && python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("fns", "fleet-node-supervisor.py"); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.fda_line({"fda": {"ok": False, "program": "/x/Python"}}))' 2>&1)
  case "$got" in *完全磁盘访问*/x/Python*) ;; *) WHY="the daemon no longer names what to grant Full Disk Access to: $got"; return 1 ;; esac
  grep -q '4) warn node' "$ROOT/bin/fleet-doctor.sh" \
    || { WHY="the doctor's node row ignores status --check 4 (no Full Disk Access)"; return 1; }
  suite_holds fleet-login-remove-selftest.sh 'no Full Disk Access' || return 1
  # #2994: no Full Disk Access ⇒ the delete rides a local ssh session first
  got=$(bash "$ROOT/bin/fleet-login-remove-ssh-selftest.sh" 2>&1) \
    || { WHY="fleet-login-remove-ssh-selftest.sh is red: $(printf '%s\n' "$got" | grep -m1 'selftest FAIL')"; return 1; }
  WHAT='守护读出自己没有完全磁盘访问 → status --check 4、医生 node 行 WARN 点名要授权的程序；没有完全磁盘访问时删号先走本机 ssh（强制命令只认 delete <登录名>），走不通说清原因再直删；dscl 被拒时删号脚本最后一行说清（真跑 shim 化的 remove）'
  SECS=$(since "$t0")
}

# ---- login-remove-uid-leftovers (#3508): a deleted login's files outside its
# home (/private/tmp, /Users/Shared, its tmux dir) stayed, and macOS gave its
# uid to the next login it made — that login owned the last person's files.
drill_login_remove_uid_leftovers() {
  CAP=60; local t0
  t0=$(now)
  grep -q 'step 5b "remove what $LOGIN owns outside its home' "$ROOT/bin/fleet-login-remove.sh" \
    || { WHY="fleet-login-remove.sh no longer clears the uid's files outside the home before deleting it"; return 1; }
  suite_holds fleet-login-remove-selftest.sh 'files of the uid in /Users/Shared were not removed' || return 1
  WHAT='删号前删掉这个 uid 在 /private/tmp · /private/var/tmp · /Users/Shared 里的文件（存档目录除外），uid 被下一个登录复用时它拿不到上一个人的东西（fleet-login-remove-selftest.sh 真跑 shim 化的删号，这里按名守住）'
  SECS=$(since "$t0")
}

# ---- trial-wash-webchat-registered (#4273): a trial login's web chat was
# registered by the machine daemon (`service ensure --name webchat`), and the
# remove script refused any registered service — every wash of a login that
# had chatted stopped at step 1 and the login stayed failed (fleetu7 / fleetu9
# on a managed Mac). Now the daemon drops only the entries it built itself
# (`service drop-fleet`) before the register is read; a person's still refuses.
drill_trial_wash_webchat_registered() {
  CAP=60; local t0
  t0=$(now)
  grep -q 'service drop-fleet --login "$LOGIN"' "$ROOT/bin/fleet-login-remove.sh" \
    || { WHY="fleet-login-remove.sh no longer drops the daemon's own on-demand entries: a trial login that chatted cannot be washed"; return 1; }
  grep -q 'def service_fleet_made' "$ROOT/bin/fleet-node-supervisor.py" \
    || { WHY="fleet-node-supervisor.py has no fleet-made test: drop-fleet would take a person's entry"; return 1; }
  suite_holds fleet-login-remove-selftest.sh 'drop-fleet' || return 1
  WHAT='试用号登记着守护按需建的 webchat：洗号（--recycle-stop --quick）和删号都先注销它、照常走完；人自己的条目（别的名字、改过的 webchat）照旧退 6、什么都不跑（真跑 shim 化的删号 + 真守护）'
  SECS=$(since "$t0")
}

# ---- spare-wash-no-fda (#3508): the admin agent has no Full Disk Access, and
# macOS refuses even root's rename of a home without it — every recycle on
# the Mac ended `reset: dirty wash` at `sudo mv /Users/<login> …`, the login
# failed and never went back to the spares. Now the wash rides the remove
# script's local ssh road (forced `wash <login> <stamp>`), as its delete does.
drill_spare_wash_no_fda() {
  CAP=60; local t0 got
  t0=$(now)
  grep -q '"$RM_SSH" wash "$LOGIN"' "$ROOT/bin/fleet-login-reset.sh" \
    || { WHY="fleet-login-reset.sh's wash no longer takes the local ssh road with no Full Disk Access"; return 1; }
  got=$(bash "$ROOT/bin/fleet-login-remove-ssh-selftest.sh" 2>&1) \
    || { WHY="fleet-login-remove-ssh-selftest.sh is red: $(printf '%s\n' "$got" | grep -m1 'selftest FAIL')"; return 1; }
  WHAT='没有完全磁盘访问时洗号经本机 ssh：强制命令 wash <登录名> <时间戳> 把家目录挪进存档目录并删掉（同删号的检查：普通登录、非 admin、非自己；没有完全磁盘访问退 7），走不通再直接 mv'
  SECS=$(since "$t0")
}

# ---- spare-wash-respawn (#3979): the stop quiesced the login at its step 4,
# then archived the home; in that gap launchd relaunched /usr/sbin/distnoted
# for the uid (fleetu5, op a9a30fae), and the wash's clock (--since) started
# after it — the check counted it as the last person's: `reset: dirty
# processes`, now and then. Now the wash quiesces again before its clock and
# once more after the old home is gone; nothing is let through by name.
drill_spare_wash_respawn() {
  CAP=90; local t0
  t0=$(now)
  grep -q 'quiesce$' "$ROOT/bin/fleet-login-reset.sh" \
    || { WHY="fleet-login-reset.sh no longer quiesces the login before the wash's clock"; return 1; }
  grep -q 'launchctl bootout "user/\$UIDT"' "$ROOT/bin/fleet-login-reset.sh" \
    || { WHY="fleet-login-reset.sh's quiesce no longer boots out the login's user domain"; return 1; }
  # part 2 of fleet-login-reset-selftest.sh owns the K/G/H/T/R keep-node/quiesce path
  suite_holds 'fleet-login-reset-selftest.sh#2' 'RS_RESPAWN' || return 1
  WHAT='停完之后、洗号之前 launchd 又给该 uid 拉起 distnoted → 洗号记时钟前再 bootout + 杀一轮、旧家挪走后再一轮：reset: clean（fleet-login-reset-selftest.sh#2 沙盒真跑检查器，这里按名守住）'
  SECS=$(since "$t0")
}

# ---- heartbeat-sys-blocked (#2798): the beat ran the fleet probe before it
# read the load, under one observed_at, and the hub folded a machine's load from
# its login rows only — the machine link's row was skipped — so a slow probe or
# a refused lane left mac-b with no load all day. Now the load is sampled on its
# own clock (sys_at), the fleet half waits at most fleetBeatBudget and carries
# the last completed read with its own fleet_at, and the machine row takes the
# newest timed reading of any heard row, the machine link's included.
drill_heartbeat_sys_blocked() {
  CAP=180; local t0 w1 ag="$ROOT/tokenledger/agent" api="$ROOT/tokenledger/hub/api"
  t0=$(now)
  grep -q 'fillSys(&hb, processSys)' "$ag/node.go" \
    || { WHY="nodeHeartbeat no longer takes the sampler's load"; return 1; }
  # the max age is 0, or fleetReuse() — the last read kept only while hub-nudge
  # has not moved (issue #3544); the budget is what this guards
  grep -qE 'a\.fleetRd\.get\(ctx, (0|a\.fleetReuse\(\)), fleetBeatBudget' "$ag/node.go" \
    || { WHY="nodeHeartbeat waits on the fleet read with no budget again"; return 1; }
  if grep -q 'readSysInfo()' "$ag/node.go" "$ag/node_machine.go"; then
    WHY="a beat reads the kernel inline again instead of the sampler"; return 1
  fi
  grep -q 'm.foldSys(sysBest\[v.Hostname\], v)' "$api/nodes.go" \
    || { WHY="the roster no longer folds every heard row's load (the machine link's too)"; return 1; }
  _drill_go_tests 'TestHeartbeatGoesOutWhileTheFleetProbeHangs TestUnreadSysIsSaidAndLoggedOnce' "$ag/beat_parts_test.go" \
    'fleet 探测卡住，心跳照常按时发出：负载新鲜（sys_at）、fleet 那一半是上一次读完的（旧 fleet_at，不为空）（go test）' \
    github.com/verkyyi/claude-fleet/tokenledger/agent || return 1
  w1=$WHAT
  _drill_go_tests 'TestMachineLoadIsTheNewestTimedReadingOfAnyRow' "$api/nodes_sys_test.go" \
    '机器行取任一在线行（含整机连接）带时间的最新负载，旧节点为「时间未知」（go test）' || return 1
  WHAT="${w1}；${WHAT}"
  SECS=$(since "$t0")
}

# ---- home-pool-claim-unkeyed (#2339): `fleet claude` opens a HOME session — a
# no-repo window, claimed from the pool's HOME slot or opened cold — that has no
# @raw and so no key. The start's result check looked for the receipt's window
# among `scratch` rows only: UNKNOWN every time, the client said 开不了, and the
# window stayed open with nobody holding it. Now the receipt's @fleet_id is
# matched first (identity before key, #1646) and the result names window_id; a
# start whose window still matches nothing is closed by `stop fid:<id>`.
drill_home_pool_claim_unkeyed() {
  CAP=10; local t0 out
  t0=$(now)
  out=$(python3 - "$BIN" <<'PY' 2>&1
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import fleet_control as fc
FID = "c63813a3-3f3f-4cea-bec6-c12705d98fc3"
def run(rows):
    tmp = tempfile.mkdtemp()
    c = fc.Control.__new__(fc.Control)
    class Store:
        root = __import__("pathlib").Path(tmp)
        def connect(self):
            import sqlite3
            db = sqlite3.connect(os.path.join(tmp, "s.db")); db.row_factory = sqlite3.Row
            return db
    c.store = Store()
    with c.store.connect() as db:
        db.execute("CREATE TABLE operations (id TEXT, action TEXT, request TEXT, status TEXT, result TEXT, created REAL, updated REAL)")
        req = {"fleet_id": "f", "action": "worker_start", "params": {"kind": "scratch", "no_repo": True, "agent": "claude"}}
        db.execute("INSERT INTO operations VALUES ('0f0e0d0c-0b0a-4908-8706-050403020100','worker_start',?,'accepted','',?,?)", (json.dumps(req), fc.now() - 0.2, fc.now()))
    c.fleet = lambda fid: {"name": "s", "fleet_id": "f"}
    stops = []
    def adapter(*a, **k):
        if a[0] == "stop":
            stops.append(a[2])
        if a[0] == "start":
            return 0, ("@694\tnorepo\t/home\t%s\t1000\t\t\n" % FID).encode(), b""
        return 0, b"", b""
    c.adapter = adapter
    c.workers = lambda fl, w="": {"observed_at": 1, "workers": rows}
    c.watch_ready = lambda *a: None
    c.execute("0f0e0d0c-0b0a-4908-8706-050403020100")
    with c.store.connect() as db:
        row = db.execute("SELECT status, result FROM operations").fetchone()
    return row["status"], json.loads(row["result"]), stops
row = {"window_id": "@694", "scratch": False, "issue": None, "key": None, "repo": None, "identity": FID}
st, r, stops = run([row])
if st != "succeeded" or r.get("window_id") != "@694":
    sys.exit("the HOME window was not recognised: %s %s" % (st, json.dumps(r)))
st, r, stops = run([])
if st != "unknown" or stops != ["fid:" + FID]:
    sys.exit("an unmatched HOME window was left open: %s stops=%s" % (st, stops))
PY
) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='从池领（或冷开）的 HOME 会话没有 key：按回执的 @fleet_id 认出、结果带 window_id；仍认不出就 stop fid: 关掉，不留孤儿'
}

# new-login-unseparated (issue #2294, EPIC #2293 C1): a login opened the old way
# had the team pool copied into its own accounts/ and FLEET_CRED_SEPARATE=0 —
# its first session could read every subscription token. Now fleet-login-new.sh
# plans step 7b (credsep install --fresh) before the login's services and its
# first session, and the pool lands in the store: the login holds markers only.
drill_new_login_unseparated() {
  CAP=20
  local d="$WORK/newlogin" t0 out rc C R st
  mkdir -p "$d/pool" "$d/homes" "$d/homes2" "$d/db" "$d/run" "$d/daemons" "$d/inst"
  printf 'tok-POOL-1\n' > "$d/pool/p1"; printf 'CCQUOTA_ACCOUNT=p1\n' > "$d/pool/p1.conf"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBRK brk@t\n' > "$d/key.pub"
  printf 'brkfresh:%s:%s:%s\n' "$(id -u)" "$(id -g)" "$d/homes/brkfresh" > "$d/pw"
  t0=$(now)
  # 1. the plan the hub's account op runs (its fixed argv: --share-pool)
  out=$(FLEET_LOGIN_HOMES="$d/homes2" bash "$BIN/fleet-login-new.sh" brkfresh --full-name B --pubkey "$d/key.pub" \
        --share-pool --pool-src "$d/pool" 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="the dry run failed (rc $rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  # case, not `printf | grep -q`: under pipefail a grep that quits early can SIGPIPE the printf
  case "$out" in *"fleet-credsep.sh install --login brkfresh --fresh"*) ;;
    *) WHY="the plan opens the login with no credsep step: the pool lands where its sessions read it"; return 1 ;; esac
  case "$out" in *"sudo cp -p $d/pool/p1"*) WHY="the plan still copies the pool into the login's own dir"; return 1 ;; esac
  case "$out" in *"background services as system"*"--fresh"*) WHY="the services start before the credentials are separated (先代理、后搬凭据、再开会话)"; return 1 ;; esac
  # 2. the separation itself (root's half, sandboxed): nothing for a session to read
  C="$d/homes/brkfresh/.config/claude-fleet" R="$d/db/brkfresh"
  mkdir -p "$C"
  out=$(FLEET_CREDSEP_ROOT_BASE="$d/db" FLEET_CREDSEP_RUN_BASE="$d/run" FLEET_CREDSEP_LOG_BASE="$d/log" \
        FLEET_CREDSEP_LIB="$d/lib" FLEET_CREDSEP_DAEMON_DIR="$d/daemons" FLEET_CREDSEP_ROLE="$(id -un)" \
        FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_PW="$d/pw" \
        FLEET_CREDSEP_JOIN_WAIT=0 FLEET_NODE_STATE="$d/node" \
        bash "$BIN/fleet-credsep.sh" install --login brkfresh --fresh --pool-src "$d/pool" --install-dir "$d/inst" 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="install --fresh failed (rc $rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  grep -rq 'tok-POOL' "$d/homes/brkfresh" && { WHY="a pool token is readable in the new login's home: $(grep -rl tok-POOL "$d/homes/brkfresh")"; return 1; }
  [ -z "$(find "$d/homes/brkfresh" \( -name .credentials.json -o -name auth.json -o -name node.env \) -print)" ] \
    || { WHY="a credential file in the new login's home"; return 1; }
  [ "$(cat "$R/accounts/p1" 2>/dev/null)" = tok-POOL-1 ] && [ "$(cat "$C/accounts/p1")" = store:p1 ] \
    || { WHY="the pool is not in the store / the login has no marker: $(ls -a "$R/accounts" "$C/accounts" 2>&1 | tr '\n' ' ')"; return 1; }
  st=$(FLEET_CONF_DIR="$C" bash "$BIN/fleet-credsep.sh" status 2>&1)
  SECS=$(since "$t0")
  case "$st" in separated*) ;; *) WHY="status after the open: $st"; return 1 ;; esac
  WHAT="新账号开号：计划里第 7b 步 credsep install --fresh 排在服务和第一个会话之前；订阅池只进 store（账号里只有 store:<label> 标记），status=separated"
}

# ---- machine-lane-reissued (#2501): a login the machine's node program serves
# re-registers (an old `fleet host on`) and the hub reissues its token — the
# machine's lane must stay up (no reissue while the link serves it; a grace for
# the old token), say why when it does not, and be fixable without an admin.
drill_machine_lane_reissued() {
  CAP=180; local t0 out rc api agt sup
  api='TestReissueKeepsTheMachineLane TestLoginNodeEnrollsOnceUntrusted'
  agt='TestLaneStateRecordsAWrongLogin'
  sup="$ROOT/bin/fleet-node-supervisor-selftest.py"
  t0=$(now)
  for out in $api; do
    grep -q "^func $out(" "$ROOT"/tokenledger/hub/api/*_test.go 2>/dev/null || { WHY="the hub half's test $out is gone"; return 1; }
  done
  grep -q "^func $agt(" "$ROOT/tokenledger/agent/lane_state_test.go" 2>/dev/null \
    || { WHY="the node half's test $agt is gone"; return 1; }
  grep -q 'machineServing(id)' "$ROOT/tokenledger/hub/api/fleet_login_node.go" \
    || { WHY="deviceNode reissues a login its machine's node program serves"; return 1; }
  grep -q 'prev_token_hash' "$ROOT/tokenledger/hub/store/store.go" \
    || { WHY="a reissued token has no grace (EndpointByTokenHash)"; return 1; }
  out=$(cd "$ROOT/bin" && python3 -W ignore::ResourceWarning -m unittest -q \
        'fleet-node-supervisor-selftest.H_Accounts.test_refused_lane_is_named_and_rejoin_renews_the_token' 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="the supervisor half is red: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  [ -f "$sup" ] || { WHY="${sup#$ROOT/} is gone"; return 1; }
  go_half "^($(printf '%s %s' "$api" "$agt" | tr ' ' '|'))\$" ./hub/api github.com/verkyyi/claude-fleet/tokenledger/agent; case $? in
    0) WHAT='机器连接服务着的登录重登记：入口不换发（409 machine_managed）；换发了的旧令牌宽限 10 分钟、过后 WRONG_LOGIN 说明重登记与修法；被拒账号写 lane.json、机器心跳带 logins_refused、Machines 卡片红字；守护 status 名出 lane、--check 3；account adopt --rejoin 不要管理员换回新令牌' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；守护一半已在这里跑绿' ;;
    3) WHAT='没有 go：守护一半跑绿，三条 Go 测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
  SECS=$(since "$t0")
}

# A session that finished with NO PR (issue #1832, EPIC #2463 C7): an issue
# session whose issue was closed without a PR, reap policy `merged` (#2446) —
# no PR will ever merge, so the PR-keyed cleanup never saw it and it sat as a
# `done` row forever. The idle pass must close it two hours after its last
# turn, history first, and say so (`cleaned:done-no-pr`); one an hour old is
# kept and said (`skip:done-recent`).
drill_done_no_pr_stranded() {
  CAP=20; BREAK_SOCK="$WORK/sock-dnp"; local d="$WORK/dnp" t0 out w1 w2 wt x w i p a kv sid=22222222-2222-4222-8222-222222222222
  mkdir -p "$d/conf" "$d/gh" "$d/home"
  git init -q -b master "$d/main" 2>/dev/null || git init -q "$d/main"
  ( cd "$d/main" && git config user.email t@t && git config user.name t && git commit -qm i --allow-empty ) \
    || { WHY="cannot build the repo"; return 1; }
  git -C "$d/main" update-ref refs/remotes/origin/master HEAD
  wt="$d/app-issue-12"; git -C "$d/main" worktree add -qb issue-12 "$wt" 2>/dev/null || { WHY="cannot add the worktree"; return 1; }
  git -C "$d/main" worktree add -qb issue-13 "$d/app-issue-13" 2>/dev/null
  mkdir -p "$d/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
  printf '{"type":"user","message":{"role":"user","content":"x"}}\n' \
    > "$d/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')/$sid.jsonl"
  printf 'FLEET_REAP_MIN_AGE=0\n' > "$d/conf/dnp.conf"
  fx_repo "$d/conf" "dnp" acme/app FLEET_MAIN="$d/main"
  printf '#!/bin/sh\ncase "$1" in issue) echo %s ;; *) echo %s ;; esac\n' "'{\"state\":\"CLOSED\"}'" "'[]'" > "$d/gh/gh"
  chmod +x "$d/gh/gh"
  nt -f /dev/null new-session -d -s dnp -n home 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  w1=$(nt new-window -d -P -F '#{window_id}' -t dnp -c "$wt" 'exec sleep 600')
  w2=$(nt new-window -d -P -F '#{window_id}' -t dnp -c "$d/app-issue-13" 'exec sleep 600')
  for x in "$w1:12:$wt:9000" "$w2:13:$d/app-issue-13:3600"; do
    IFS=: read -r w i p a <<EOF2
$x
EOF2
    for kv in "@issue=$i" "@fleet_id=$(printf '%08d-0000-4000-8000-000000000000' "$i")" "@worktree=$p" "@claude_state=done" "@reap_policy=merged" "@repo=acme/app" \
              "@claude_state_ts=$(( $(date +%s) - a ))" "@cc_agent=claude"; do
      nt set-option -w -t "$w" "${kv%%=*}" "${kv#*=}"
    done
  done
  run() { ( cd "$d" && env -u TMUX -u TMUX_PANE PATH="$d/gh:$WORK/tbin:$PATH" HOME="$d/home" FLEET_CONF_DIR="$d/conf" \
            FLEET_SKIP_GLOBAL_CONF=1 FLEET_HISTORY_LEDGER="$d/ledger.tsv" CLAUDE_PROJECTS_DIR="$d/projects" \
            BREAK_SOCK="$BREAK_SOCK" bash "$BIN/fleet-cleanup-idle.sh" dnp ); }
  t0=$(now)
  out=$(run 2>&1)
  nt set-option -w -t "$w1" @reap_due "$(( $(date +%s) - 1 ))" 2>/dev/null
  out="$out
$(run 2>&1)"
  SECS=$(since "$t0")
  case "$out" in *"cleaned:done-no-pr $w1 issue-12"*) ;; *) WHY="the stranded session was not closed: [$(printf '%s' "$out" | tr '\n' ' ')]"; return 1 ;; esac
  nt list-windows -t dnp -F '#{window_id}' | grep -qx "$w1" && { WHY="its window is still open"; return 1; }
  grep -q "$sid" "$d/ledger.tsv" 2>/dev/null || { WHY="closed without its history row"; return 1; }
  case "$out" in *"skip:done-recent $w2 issue-13"*) ;; *) WHY="the hour-old session was not said kept: [$(printf '%s' "$out" | tr '\n' ' ')]"; return 1 ;; esac
  nt list-windows -t dnp -F '#{window_id}' | grep -qx "$w2" || { WHY="the hour-old session was closed"; return 1; }
  WHAT='issue 已关、无 PR、策略 merged 的 done 会话：满 2 小时先记账再关（cleaned:done-no-pr），1 小时的留着并说 skip:done-recent'
}

# The cleanup daemon's idle pass times out (issue #3352): on 2026-10-11 mac-c's
# `fleet-cleanup-idle.sh` hit its 120 s box every tick and the daemon ended the
# tick there — ahead of the merged-PR pass, so #3302 / #3143 / #3321 sat merged
# and open for over half an hour, said nowhere. The real daemon on an isolated
# server: an idle pass that overruns its box, a merged issue-12 with its window
# and worktree. The merged PR must still be handed to the janitor that tick, and
# the timeout said.
drill_idle_timeout_starves_merged() {
  CAP=30; BREAK_SOCK="$WORK/sock-itm"; local d="$WORK/itm" t0 out f
  mkdir -p "$d/conf" "$d/fake" "$d/bin" "$d/leases" "$d/tmp/.claude-dash/fleets/acme-app"
  git init -q -b master "$d/main" 2>/dev/null || git init -q "$d/main"
  ( cd "$d/main" && git config user.email t@t && git config user.name t && git commit -qm i --allow-empty ) \
    || { WHY="cannot build the repo"; return 1; }
  git -C "$d/main" worktree add -qb issue-12 "$d/app-issue-12" 2>/dev/null || { WHY="cannot add the worktree"; return 1; }
  for f in "$BIN"/*; do ln -s "$f" "$d/bin/" 2>/dev/null; done
  rm -f "$d/bin/fleet-cleanup.sh" "$d/bin/fleet-cleanup-idle.sh" "$d/bin/fleet-diskguard.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> %q\necho cleaned:fake\n' "$d/janitor" > "$d/bin/fleet-cleanup.sh"
  printf '#!/bin/bash\nexec sleep 30\n' > "$d/bin/fleet-cleanup-idle.sh"
  printf '#!/bin/bash\nexit 0\n' > "$d/bin/fleet-diskguard.sh"
  printf '#!/bin/sh\nexit 0\n' > "$d/fake/gh"
  chmod +x "$d/bin/fleet-cleanup.sh" "$d/bin/fleet-cleanup-idle.sh" "$d/bin/fleet-diskguard.sh" "$d/fake/gh"
  printf 'FLEET_CLEANUP_CANDIDATE_TIMEOUT=2\n' > "$d/conf/itm.conf"
  fx_repo "$d/conf" "itm" acme/app FLEET_MAIN="$d/main"
  printf 'issue-12\t#40\tMERGED\t✓\tready\n' > "$d/tmp/.claude-dash/fleets/acme-app/prmap"
  : > "$d/tmp/.claude-dash/fleets/acme-app/prmap.ts"
  nt -f /dev/null new-session -d -s itm -n home 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  f=$(nt new-window -d -P -F '#{window_id}' -t itm -c "$d/app-issue-12" 'exec sleep 600')
  nt set-option -w -t "$f" @issue 12
  nt set-option -w -t "$f" @claude_state "done"
  t0=$(now)
  out=$( cd "$d" && env -u TMUX -u TMUX_PANE PATH="$d/fake:$WORK/tbin:$PATH" HOME="$WORK/home" TMPDIR="$d/tmp" \
           FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_DISPATCH_LEASE_DIR="$d/leases" \
           FLEET_TRASH_SWEEP_BUDGET=0 BREAK_SOCK="$BREAK_SOCK" bash "$d/bin/fleet-cleanup-daemon.sh" itm 2>&1 )
  SECS=$(since "$t0")
  grep -qx 40 "$d/janitor" 2>/dev/null \
    || { WHY="the merged PR never reached the janitor: [$(printf '%s' "$out" | tail -4 | tr '\n' ' ')]"; return 1; }
  case "$out" in *'idle cleanup deferred (rc=124)'*) ;; *) WHY="the idle timeout was not said: [$(printf '%s' "$out" | tail -4 | tr '\n' ' ')]"; return 1 ;; esac
  WHAT='闲置那一遍超时（rc=124）：同一拍里合并 PR 那一遍照样先跑、交给清理，超时照记一行'
}

drill_task_report_fence() {
  CAP=15; local out t0
  t0=$(now)
  out=$(bash "$BIN/fleet-task-control-selftest.sh" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='旧 receive/await/children 明确退役；任务记录读不到仍为 UNKNOWN，不伪造完成或取消'
}

drill_accepted_await_by_number() {
  CAP=30; local t0 out; t0=$(now)
  out=$(bash "$BIN/fleet-await-selftest.sh" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='旧 await 按单号或 Task 均立即退役，不启动会话、不写队列'
}

drill_dispatch_identity_fallback() {
  CAP=15; local out t0
  t0=$(now)
  out=$(bash "$BIN/fleet-dispatch-selftest.sh" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='固定 provider 的接受身份不变：拒绝替换 T，也不在入口结果未知后补开本机'
}

drill_place_declined_not_retried() {
  CAP=120; local t0 d="$WORK/pdecl" out err rc gohalf old_ts now_s
  mkdir -p "$d/g"
  t0=$(now)
  # node half: the hub's `after …` field and each declined try survive fleet_hub_place
  printf '#!/bin/sh\nprintf "ccquota place: mac-d declined (exit 1): fleet discover: fork/exec fleet-control.py: invalid argument — trying the next machine\\n" >&2\nprintf "REMOTE mac-a op2 done @9\\tchose mac-a\\tafter mac-d:op1:1\\n"\n' > "$d/place"
  chmod +x "$d/place"
  out=$(bash -c '. "$1/fleet-lib.sh"; fleet_hub_on(){ return 0; }; fleet_uuid(){ echo 11111111-1111-4111-8111-111111111111; }
        _fleet_hub_env(){ :; }; FLEET_HUB_PLACE_CMD="$2" fleet_hub_place s o/r 7 auto' _ "$BIN" "$d/place" 2>"$d/err"); rc=$?
  err=$(cat "$d/err")
  [ "$rc" = 0 ] && [ "$out" = "REMOTE mac-a op2 done @9	chose mac-a	after mac-d:op1:1" ] \
    || { WHY="fleet_hub_place lost the hub's next-machine answer (rc=$rc): $out"; return 1; }
  case "$err" in *'mac-d declined (exit 1): fleet discover'*) ;; *) WHY="the declined try is not said on stderr: $err"; return 1 ;; esac
  # the claim a never-seen send keeps is told apart: stale, no session anywhere
  old_ts=$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600)))')
  now_s=$(date +%s)
  printf '{"seq": 1, "ts": "%s", "child": "issue-11317", "node": "mac-d", "op": "o1", "state": "unknown"}\n' "$old_ts" > "$d/scratch-3.dispatch"
  printf '#ts\037%s\n' "$now_s" > "$d/g/remote_s"; printf '%s\n' "$now_s" > "$d/g/hub_ok"
  out=$(printf '' | python3 "$BIN/fleet-children.py" show --dir "$d" --parent scratch-3 --hub-cache "$d/g/remote_s" --json)
  case "$out" in *'"claim": "stale"'*) ;; *) WHY="fleet-children does not call a claim with no session stale: $out"; return 1 ;; esac
  gohalf='hub half: the Go gate (tokenledger.yml) runs the next-machine tests'
  go_half 'TestNodePlace(DeclinedTriesNextMachine|AllDeclinedRefuses|AskerIsTriedLast|NamedOrClaimedIsTriedOnce)$|TestClientPlaceDeclinedTriesNextMachine$' ./hub/api; case $? in
    0) gohalf='hub half: go test 换下一台 / 全拒 / 本机最后 / 指名不换 / client ok' ;;
    1) return 1 ;;
    2) gohalf='hub half: no go module cache / toolchain here — the Go gate (tokenledger.yml) runs the next-machine tests' ;;
  esac
  SECS=$(since "$t0")
  WHAT="一台拒绝后入口换下一台（本机最后），行尾 after 段与逐台 stderr 传到节点；没开成又哪台都没会话的认领标 stale；$gohalf"
}

# ---- issue T672: a full machine hands the session on; every start asks the hub --

drill_place_full_no_next() {
  CAP=120; local t0 d="$WORK/pfull" out rc gohalf f
  mkdir -p "$d"
  t0=$(now)
  # node half: this machine's own refusal rides the ONE ask as --not-here, and a hub
  # that hears it answers another machine (the fake answers LOCAL without it).
  cat > "$d/place" <<'PL'
#!/bin/sh
printf '%s\n' "$*" >> "$PLOG"
case " $* " in *" --not-here "*) printf 'REMOTE mac-a op9 done @7\tchose mac-a; mac-b excluded: 本机准入不过：fleet at capacity\n' ;;
  *) printf 'LOCAL mac-b\tchose mac-b\n' ;; esac
PL
  chmod +x "$d/place"
  out=$(PLOG="$d/log" FLEET_CONF_DIR="$d/conf" bash -c '. "$1/fleet-lib.sh"; fleet_hub_on(){ return 0; }; fleet_uuid(){ echo 11111111-1111-4111-8111-111111111111; }
        _fleet_hub_env(){ :; }; FLEET_PLACE_NOT_HERE="fleet at capacity: 4/4" FLEET_HUB_PLACE_CMD="$2" fleet_hub_place s o/r 7 auto' _ "$BIN" "$d/place" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] && case "$out" in 'REMOTE mac-a '*) true ;; *) false ;; esac \
    || { WHY="a full machine's ask did not go elsewhere (rc=$rc): $out"; return 1; }
  [ "$(grep -c . "$d/log")" = 1 ] && grep -q -- '--not-here fleet at capacity: 4/4' "$d/log" \
    || { WHY="not one ask carrying --not-here: $(cat "$d/log")"; return 1; }
  # both spawners hand their held verdict to the ask, and refuse when all are full
  for f in dash-issue-session.sh dash-raw-session.sh; do
    grep -q 'FLEET_PLACE_NOT_HERE="$CAP_HELD"' "$BIN/$f" || { WHY="$f no longer tells the hub it is full"; return 1; }
  done
  grep -q 'the hub was never reached' "$BIN/fleet-lib.sh" || { WHY="fleet_hub_place lost rc 11 (never reached ⇒ open here)"; return 1; }
  gohalf='hub half: the Go gate runs TestNodePlaceNotHere*'
  go_half '^TestNodePlaceNotHere(GoesElsewhere|AllFullNamesEach)$' ./hub/api; case $? in
    0) gohalf='hub half: go test 本机不收 → 别台 / 全满列逐台原因 / 刚报暂停的不再派' ;;
    1) return 1 ;;
  esac
  SECS=$(since "$t0")
  WHAT="本机准入不过随那一次放置请求 --not-here 交给入口，入口换下一台；全满拒绝并列逐台原因；$gohalf"
}

drill_place_slow_bypass() {
  CAP=60; local t0 d="$WORK/pslow" out
  mkdir -p "$d"
  t0=$(now)
  # a seeded scratch (dispatch --spawn's road) asks the hub like any other: no
  # here-only rule left for --prompt, and the words ride as --body-file
  grep -q "a seeded scratch (--prompt)" "$BIN/dash-raw-session.sh" \
    && { WHY="dash-raw-session.sh still keeps a seeded scratch here, past the hub"; return 1; }
  grep -q 'FLEET_PLACE_BODY_FILE=' "$BIN/dash-raw-session.sh" || { WHY="a seeded scratch's words no longer travel"; return 1; }
  # a shipped agent file travels (T604): --as fleet-worker is not refused elsewhere
  grep -q 'fleet_agent_file_travels "$AS_ARG"' "$BIN/dash-raw-session.sh" "$BIN/dash-issue-session.sh" \
    || { WHY="--as fleet-worker is refused on another machine again"; return 1; }
  # the release's own ccquota first: a stale copy on PATH knows none of its flags
  mkdir -p "$d/rel" "$d/path"
  printf '#!/bin/sh\necho rel\n' > "$d/rel/ccquota"; printf '#!/bin/sh\necho path\n' > "$d/path/ccquota"; chmod +x "$d/rel/ccquota" "$d/path/ccquota"
  out=$(PATH="$d/path:$PATH" bash -c '. "$1/fleet-lib.sh"; _FLEET_LIB_DIR=$2; eval "$(_fleet_ccquota)"' _ "$BIN" "$d/rel")
  [ "$out" = rel ] || { WHY="the hub helpers run the ccquota on PATH ($out), not the release's"; return 1; }
  # every ask is timed, and the p90 is read off the log
  printf '#!/bin/sh\nprintf "LOCAL mac-b\\tchose mac-b\\n"\n' > "$d/place"; chmod +x "$d/place"
  for _ in 1 2 3; do
    FLEET_CONF_DIR="$d/conf" bash -c '. "$1/fleet-lib.sh"; fleet_hub_on(){ return 0; }; fleet_uuid(){ echo 11111111-1111-4111-8111-111111111111; }
      _fleet_hub_env(){ :; }; FLEET_HUB_PLACE_CMD="$2" fleet_hub_place s o/r scratch auto' _ "$BIN" "$d/place" >/dev/null 2>"$d/err"
  done
  grep -q '^fleet: place_ms=[0-9]* (LOCAL mac-b' "$d/err" || { WHY="the ask is not timed on stderr: $(cat "$d/err")"; return 1; }
  out=$(FLEET_CONF_DIR="$d/conf" bash -c '. "$1/fleet-lib.sh"; fleet_hub_place_ms 20' _ "$BIN")
  case "$out" in 'n=3 p50='*' p90='*) ;; *) WHY="fleet_hub_place_ms does not read the log: $out"; return 1 ;; esac
  # the warm road: every hub caller tries the agent's forwarder first
  grep -q 'hubfwd.Transport' "$ROOT/tokenledger/agent/cli/place.go" "$ROOT/tokenledger/agent/cli/lease.go" \
    && grep -q 'fleet_hub_sock' "$BIN/fleet-task-record.sh" && grep -q 'def hub_sock' "$BIN/fleet_hub_rest.py" \
    && grep -q 'serveHubFwd' "$ROOT/tokenledger/agent/agent.go" "$ROOT/tokenledger/agent/node_machine.go" \
    && grep -q 'def hub_fwd_sock' "$BIN/fleet-cred-proxy.py" \
    || { WHY="a hub caller (place / lease / task-record / python) or the agent's forwarder lost the warm road"; return 1; }
  go_half '^Test(ForwarderOneConnectionManyAsks|TransportFallsBackDirect|TransportHTTPSHubOverSocket)$' ./shared/hubfwd; [ $? = 1 ] && return 1
  SECS=$(since "$t0")
  WHAT="带种子的会话（dispatch --spawn）与 --as fleet-worker 一样先问入口；入口调用走 agent 保温的转发口（多次一条连接）；每次放置记 place_ms，日志读 p90（${out}）"
}

drill_norepo_never_placed() {
  CAP=30; local t0 out
  t0=$(now)
  # the record-less rule only: a no-repo session bound to its task is the hub's
  grep -q '{ \[ "\$NOREPO" = 1 \] && \[ -z "\$TASK_REF" \]; }' "$BIN/dash-raw-session.sh" \
    || { WHY="dash-raw-session.sh keeps every no-repo session here again, past the hub"; return 1; }
  grep -q "\[ \"\$NOREPO\" = 1 \] && _prepo=''" "$BIN/dash-raw-session.sh" \
    || { WHY="a no-repo session asks the hub with the fleet's repo — only that repo's machines"; return 1; }
  # a plugin's shipped agent file (the EPIC driver) travels like the core's
  out=$(bash -c '. "$1/fleet-lib.sh"; for n in epic-driver fleet-epic:epic-driver fleet-worker; do
      fleet_agent_file_travels "$n" || echo "no:$n"; done
    for n in nosuch fleet-epic:nosuch ../x a:b:c; do fleet_agent_file_travels "$n" && echo "yes:$n"; done; :' _ "$BIN")
  [ -z "$out" ] || { WHY="fleet_agent_file_travels: $out"; return 1; }
  go_half '^TestNodePlaceNoRepoScratch$' ./hub/api; [ $? = 1 ] && return 1
  SECS=$(since "$t0")
  WHAT="带任务记录的不绑仓库会话问入口、不按仓库筛候选、开到别台带 no_repo；epic-driver 这类插件模板随发布旅行；无记录的仍本机开"
}

# ---- one primary state source (issue #2537, EPIC #2535 C2) ------------------------
# The agent's own OSC 7501 report (bin/fleet-status-7501.py, its pipe mode here)
# outranks the hooks (bin/set-claude-state.sh); the screen classifier that guessed
# below them retired with issue #2543. Each drill is the 2026-10-09 misreading it
# is named after, on an isolated server.
sp_env() {   # <args…> — the sandbox's hooks and lib, against $BREAK_SOCK
  env PATH="$WORK/spbin:$WORK/tbin:$PATH" HOME="$WORK/home" BREAK_SOCK="$BREAK_SOCK" TMUX="$BREAK_SOCK,1,0" \
    FLEET_CONF_DIR="$WORK/spconf" FLEET_SKIP_GLOBAL_CONF=1 "$@"
}
sp_start() {   # <session> — a fresh worker window; sets SPW / SPP
  mkdir -p "$WORK/spbin" "$WORK/spconf/global"
  nt -f /dev/null new-session -d -s "$1" -n issue-7 -x 100 -y 30 "printf 'working on it\n'; exec sleep 600" || return 1
  SPW=$(nt display-message -p -t "$1:issue-7" '#{window_id}'); SPP=$(nt display-message -p -t "$SPW" '#{pane_id}')
  nt set-option -w -t "$SPW" @issue 7 \; set-option -w -t "$SPW" @cc_agent claude
}
sp_state() { printf '%s/%s/%s' "$(o "$SPW" @claude_state)" "$(o "$SPW" @claude_needs)" "$(o "$SPW" @claude_state_src)"; }
sp_say() {   # <state> [kind] [words] — the agent's OSC 7501, read off its output
  local m=''; [ -n "${3:-}" ] && m=":msg=$(printf '%s' "$3" | base64 | tr -d '\n')"
  printf '\033]7501;state=%s:app=claude-code%s%s\033\\' "$1" "${2:+:kind=$2}" "$m" \
    | sp_env TMUX_PANE="$SPP" python3 "$BIN/fleet-status-7501.py" pipe
}
sp_hook() {  # <stdin> <args…> — one hook edge on the pane
  local in="$1"; shift
  printf '%s' "$in" | sp_env TMUX_PANE="$SPP" sh "$BIN/set-claude-state.sh" "$@" >/dev/null 2>&1
}

drill_status_agent_not_up() {
  CAP=5; BREAK_SOCK="$WORK/sock-sn"; local t0 st
  sp_start sn || { WHY="cannot start the isolated tmux server"; return 1; }
  # the last agent's word is still on the window (it exited), the new one never speaks
  nt set-option -w -t "$SPW" @agent_status '{"state":"exited","rc":0}' \; set-option -w -t "$SPW" @agent_status_ts "$(date +%s)" \
     \; set-option -w -t "$SPW" @claude_state_src 7501 \; set-option -w -t "$SPW" @claude_state ''
  t0=$(now)
  sp_hook '{"hook_event_name":"UserPromptSubmit"}' working
  st=$(sp_state)
  [ "$st" = working//hook ] || { WHY="with no live 7501 report the prompt's hook did not land: [$st] — the window reads unknown"; return 1; }
  nt set-option -wu -t "$SPW" @agent_status \; set-option -wu -t "$SPW" @agent_status_ts
  sp_env python3 "$BIN/fleet-state-reconcile.py" --registry "$WORK/spreg" --cache-dir "$WORK/spcache" \
    --log "$WORK/sp-reconcile.log" -- sn >/dev/null 2>&1
  grep -q "$(printf '%s\t' "$SPW")issue-7.*none" "$WORK/spcache/reconcile.sources" 2>/dev/null \
    || { WHY="reconcile.sources does not say the window has no 7501: $(cat "$WORK/spcache/reconcile.sources" 2>/dev/null | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0"); WHAT="主来源缺席：hooks 照常接管；对账报告写明这个窗口 7501=none"
}

drill_status_perm_overwritten() {
  CAP=5; BREAK_SOCK="$WORK/sock-sp"; local t0 st
  sp_start sp || { WHY="cannot start the isolated tmux server"; return 1; }
  t0=$(now)
  sp_say blocked permission 'Bash: git push origin main'
  sp_hook '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' busy
  st=$(sp_state)
  [ "$st" = needs/perm/7501 ] || { WHY="waiting on permission, the PreToolUse hook left [$st] — it reads 在跑"; return 1; }
  # two minutes of silence: the hooks speak again
  nt set-option -w -t "$SPW" @agent_status_ts "$(( $(date +%s) - 130 ))"
  sp_hook '{"hook_event_name":"PostToolUse"}' working
  st=$(sp_state)
  [ "$st" = working//hook ] || { WHY="130 s after the last report the hook still could not speak: [$st]"; return 1; }
  SECS=$(since "$t0"); WHAT="等权限：hook 让开，状态 needs/perm 来源 7501；静默两分钟后才接管"
}

drill_status_migrated_looping() {
  CAP=5; BREAK_SOCK="$WORK/sock-sm"; local t0 st
  sp_start sm || { WHY="cannot start the isolated tmux server"; return 1; }
  nt set-option -wu -t "$SPW" @claude_state_src
  # the migrate re-stamps what the old window said
  sp_env bash -c '. "$1/fleet-lib.sh"; fleet_state_carry "" "$2" looping' _ "$BIN" "$SPW"
  st=$(sp_state)
  [ "$st" = looping//carried ] || { WHY="the carried state was not stamped as a bootstrap value: [$st]"; return 1; }
  t0=$(now)
  sp_say working
  st=$(sp_state)
  [ "$st" = working//7501 ] || { WHY="the new agent's first report left [$st] — it reads 循环 while it works"; return 1; }
  # a carry that arrives late changes nothing
  sp_env bash -c '. "$1/fleet-lib.sh"; fleet_state_carry "" "$2" looping' _ "$BIN" "$SPW"
  st=$(sp_state)
  [ "$st" = working//7501 ] || { WHY="a late carry overwrote the agent's word: [$st]"; return 1; }
  SECS=$(since "$t0"); WHAT="刚迁移：搬来的 looping 只是启动值，新 agent 第一条 7501 一到就是 working，迟到的搬运不覆盖"
}

drill_status_question_lost() {
  CAP=5; BREAK_SOCK="$WORK/sock-sq"; local t0 st words='要合并 #12 吗？'
  sp_start sq || { WHY="cannot start the isolated tmux server"; return 1; }
  t0=$(now)
  sp_say blocked question "$words"
  sp_hook '{"hook_event_name":"Stop"}' 'done'
  st=$(sp_state)
  [ "$st" = needs/ask/7501 ] || { WHY="the Stop right after the question left [$st] — 在问你 flashed to 完成"; return 1; }
  [ "$(o "$SPW" @claude_needs_detail)" = "$words" ] || { WHY="the question's words are gone: [$(o "$SPW" @claude_needs_detail)]"; return 1; }
  SECS=$(since "$t0"); WHAT="问问题：needs/ask 和原话在 Stop 之后还在"
}

# epic-driver-unknown-command (T646): an EPIC charter opened with the bare
# `/fleet-epic-run`; Claude Code read it as a command (a plugin's is only
# `/fleet-epic:fleet-epic-run`), answered 「Unknown command」 itself and the turn
# ended — the agent said `done`, and the panel filed a driver that never ran under
# 做完待收. Played here on the agent's own word (7501 pipe) over the transcript that
# day left: the window must read needs/nostart with Claude Code's words, a reaper
# must not read it done, and once a reply exists the same `done` is a done.
drill_epic_driver_unknown_command() {
  CAP=10; BREAK_SOCK="$WORK/sock-eu"; local t0 st sid=31ec8459-8f2a-4f3c-b44b-f5bcddc3f0e1 tp grp
  sp_start eu || { WHY="cannot start the isolated tmux server"; return 1; }
  mkdir -p "$WORK/eu-cc/projects/-x"; tp="$WORK/eu-cc/projects/-x/$sid.jsonl"
  printf '%s\n' '{"type":"agent-setting","agentSetting":"fleet-epic:epic-driver"}' \
    '{"type":"system","subtype":"informational","content":"Unknown command: /fleet-epic-run","level":"warning"}' > "$tp"
  nt set-option -w -t "$SPW" @task T9 \; set-option -w -t "$SPW" @cc_session_id "$sid"
  eu_say() { printf '\033]7501;state=%s:app=claude-code\033\\' "$1" \
    | sp_env CLAUDE_CONFIG_DIR="$WORK/eu-cc" TMUX_PANE="$SPP" python3 "$BIN/fleet-status-7501.py" pipe; }
  t0=$(now)
  eu_say 'done'
  st=$(sp_state)
  [ "$st" = needs/nostart/7501 ] || { WHY="a first turn that never reached the model left [$st] — it reads 做完待收"; return 1; }
  case "$(o "$SPW" @claude_needs_detail)" in *'Unknown command: /fleet-epic-run'*) : ;;
    *) WHY="the window does not say why: [$(o "$SPW" @claude_needs_detail)]"; return 1 ;; esac
  grp=$(cd "$BIN" && python3 -c 'import fleet_view as v; print(v.group_of("needs", False, False, False))' 2>/dev/null)
  [ "$grp" = ask ] || { WHY="the panel files it under [$grp], not 等你"; return 1; }
  [ "$(cd "$BIN" && python3 -c 'import fleet_reap_notice as r; print(r.reap_state("needs", "{\"state\":\"done\"}", "nostart"))')" = needs ] \
    || { WHY="a reaper reads the agent's done over needs/nostart and may close it"; return 1; }
  # someone sends the right words: the model answers, and a done is a done again
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"tick 1"}]}}' >> "$tp"
  eu_say working; eu_say 'done'
  st=$(sp_state)
  [ "$st" = done//7501 ] || { WHY="after a reply the turn's done left [$st]"; return 1; }
  [ "$(o "$SPW" @task_started)" = 1 ] || { WHY="@task_started not stamped once the model answered"; return 1; }
  grep -q '^FLEET_EPIC_RUN_LINE=' "$BIN/dash-raw-session.sh" \
    || { WHY="dash-raw-session.sh no longer rewrites an older charter's /fleet-epic-run line"; return 1; }
  SECS=$(since "$t0"); WHAT="首轮没进模型（Unknown command）：needs/nostart 带原话、归「等你」、回收不当做完；有了回复才算 done；旧章程首行改成话"
}

# cross-send-refused-unseen (issue #2729): the orchestrator's message to a worker
# on another machine went out as `<uuid>/orchestrator`, which the hub's worker_id
# grammar refuses; the agent moved it to refused/ and the sender, seeing only the
# file gone, said 「queued · not delivered yet」 for hours. The drill plays the hub
# as the agent sees it: any relay whose `from` the hub's grammar refuses goes to
# refused/<file> + .why, any other is "stored" (deleted). A keyless session's send
# (its key is its identity, issue #4341) must be stored; a refusal must come back as
# exit 1 + FAILED in the book.
drill_cross_send_refused_unseen() {
  CAP=10; BREAK_SOCK="$WORK/sock-xs"; local t0 c="$WORK/xs" u po rc ob
  mkdir -p "$c/conf/fleets/xs" "$c/conf/control"
  : > "$c/conf/fleets/xs/conf"
  fx_repo "$c/conf" "xs" acme/app FLEET_MAIN="$c/main"
  "$REAL_TMUX" -S "$BREAK_SOCK" -f /dev/null new-session -d -s xs -n plan 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  po=$("$REAL_TMUX" -S "$BREAK_SOCK" new-window -d -P -F '#{pane_id}' -t xs -n orch 'exec sleep 600')
  "$REAL_TMUX" -S "$BREAK_SOCK" set-option -w -t "$po" @fleet_role worker \; set-option -w -t "$po" @norepo 1 \; \
    set-option -w -t "$po" @fleet_id 0dbf19b9-aaaa-4bbb-8ccc-002729002729
  xs() { env FLEET_CONF_DIR="$c/conf" FLEET_SKIP_GLOBAL_CONF=1 CCQUOTA_FLEET=1 FLEET_PEER_RECEIPT_SECS=0 FLEET_HUB_RECEIPT_WAIT=1 "$@"; }
  (cd "$BIN" && xs python3 -c 'import sys, fleet_control as c; c.Control(sys.argv[1]).inventory()' "$c/conf") >/dev/null 2>&1
  u=$(xs bash -c '. "$1/fleet-lib.sh"; fleet_uuid xs' _ "$BIN")
  [ -n "$u" ] || { WHY="no fleet UUID could be minted"; return 1; }
  printf '11111111-2222-3333-4444-555555555555/issue-42\tmac-a\t\n' > "$c/conf/control/hub-workers.tsv"
  ob="$c/conf/control/hub-outbox"; mkdir -p "$ob"
  # the hub, as the agent sees it: refuse what its grammar refuses ($1=all: everything)
  hub() { ( for _ in $(seq 1 50); do
      g=$(ls "$ob"/*.json 2>/dev/null | head -1)
      if [ -n "$g" ]; then
        if [ "$1" != all ] && (cd "$BIN" && python3 -c 'import json,sys, fleet_hub_common as h; sys.exit(0 if h.WORKER_ID_RE.fullmatch(json.load(open(sys.argv[1]))["from"]) else 1)' "$g"); then
          rm -f "$g"
        else
          mkdir -p "$ob/refused"; mv "$g" "$ob/refused/"; printf 'INVALID_ARGUMENT: from: worker_id must be …\n' > "$ob/refused/${g##*/}.why"
        fi
        exit 0
      fi
      sleep 0.1
    done ) & }
  t0=$(now)
  hub grammar
  xs env TMUX="$BREAK_SOCK,0,0" TMUX_PANE="$po" bash "$BIN/fleet-peer-send.sh" "wid:11111111-2222-3333-4444-555555555555/issue-42" 'hi' >/dev/null 2>&1; rc=$?
  wait
  [ ! -e "$ob/refused" ] || { WHY="the hub refused the keyless session's relay: $(cat "$ob"/refused/*.why 2>/dev/null | head -1)"; return 1; }
  [ "$rc" = 3 ] || { WHY="the keyless session's send ended $rc, want 3 (stored, waiting for the receipt)"; return 1; }
  hub all
  xs env TMUX="$BREAK_SOCK,0,0" TMUX_PANE="$po" bash "$BIN/fleet-peer-send.sh" "wid:11111111-2222-3333-4444-555555555555/issue-42" 'hi again' >/dev/null 2>&1; rc=$?
  wait
  [ "$rc" = 1 ] || { WHY="a refused relay ended $rc, want 1 — the sender still thinks it waits"; return 1; }
  tail -1 "$c/conf/fleets/xs/delivery.ndjson" 2>/dev/null | grep -q '"state": "FAILED"' \
    || { WHY="the delivery book does not say FAILED: $(tail -1 "$c/conf/fleets/xs/delivery.ndjson" 2>/dev/null)"; return 1; }
  SECS=$(since "$t0")
  WHAT="没有键的会话用身份发、入口收下；被拒的当场退出 1，账本记 FAILED、原因在 stderr"
}

# cross-report-queued-unseen (issue T756): a child placed on ANOTHER machine said
# `report waiting` to its orchestrator. The hub carried it and the parent's machine
# ledgered it within a second or two — but a waiting report was tier silent, and
# the cross-machine branch skipped the receipt wait for silent and printed 「已排队 ·
# not delivered」, exit 3, unconditionally; the parent's window never got it (silent
# = ledger only), and the receipt wait itself was 4 s against a 4–7 s hub round trip.
# Two machines here: two conf dirs (two fleet UUIDs), two tmux servers, and the hub +
# both agents played by a pump that hands the child machine's outbox relay to the
# parent machine's real `fleet-hub-node.sh deliver` and its receipt back to the
# child's. The parent pane runs a fake Claude with an inbox: the report must reach
# it, the child must say `reported` within 10 s; with the hub silent the child says
# queued and the next tick says so in ⌘P 消息.
drill_cross_report_queued_unseen() {
  CAP=30; local t0 out; t0=$(now)
  out=$(python3 "$BIN/fleet-parent-retirement-selftest.py" \
    RetirementTests.test_old_hub_queue_and_receipts_never_become_reminders \
    RetirementTests.test_old_queue_payload_preserved_and_failed_once 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='跨机旧回报积压永久结算 FAILED，原文保留，迟到回执不复活、不转提醒，重试不重复结算'
}

# A migrate opened the new window with its identity but not its @fleet_role /
# @reap_policy; and a window with no policy bound to a closed ticket was «never»
# — under worker sleep (gone since T548) not even looked at (#2970).
drill_migrate_loses_policy() {
  CAP=10; local t0 out
  t0=$(now)
  grep -q '^MIGRATE_CARRY="[^"]*@reap_policy' "$BIN/fleet-migrate.sh" \
    && grep -q 'fleet_win_stamp_cmd @fleet_role "\$role"' "$BIN/fleet-migrate.sh" \
    || { WHY="fleet-migrate.sh does not carry @reap_policy / @fleet_role to the new window"; return 1; }
  out=$(python3 - "$BIN" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("idle", sys.argv[1] + "/fleet-cleanup-idle.py")
m = importlib.util.module_from_spec(spec); sys.path.insert(0, sys.argv[1]); spec.loader.exec_module(m)
c = m.Cleaner.__new__(m.Cleaner)
def snap(**kw):
    d = {k: "" for k in ("@issue", "@epic", "@raw", "@reap_policy")}; d.update(kw); return d
res = []
for only in (False, True):
    c.args = types.SimpleNamespace(policy_only=only, repo="acme/repo")
    res += [c.route(snap(**{"@issue": "12"})), c.route(snap(**{"@raw": "1", "@epic": "acme/repo#9"})),
            c.route(snap(**{"@issue": "12", "@reap_policy": "keep"}))]
print(" ".join(str(r) for r in res))
PY
)
  SECS=$(since "$t0")
  [ "$out" = "no-pr no-pr None no-pr no-pr None" ] \
    || { WHY="a no-policy window bound to a ticket is not routed to the closed-ticket reap (got: $out)"; return 1; }
  WHAT="迁移带上 @fleet_role / @reap_policy；无策略、绑了单（或 EPIC）的窗口走「单已关才收」，sleep on 也一样，keep 不收"
}

# A selftest's tmux server outlived its test (a failure, a timeout, a missed
# kill-server) and its dead sockets piled up beside the fleets' (#2970).
drill_selftest_tmux_leak() {
  CAP=15; local tt t0 s
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  grep -q 'TMUX_TMPDIR="\${tt_dir' "$BIN/run-selftests.sh" && grep -q '^  tt_sweep$' "$BIN/run-selftests.sh" \
    || { WHY="run-selftests.sh gives a test no private TMUX_TMPDIR it sweeps"; return 1; }
  tt=$(mktemp -d /tmp/brkst.XXXXXX) || { WHY="mktemp"; return 1; }
  s="$tt/tmux-$(id -u)"
  TMUX_TMPDIR="$tt" "$REAL_TMUX" -L "hubs$$" -f /dev/null new-session -d 'sleep 60' 2>/dev/null \
    || { rm -rf "$tt"; WHY="could not start the leaked server"; return 1; }
  touch -t 202001010000 "$s/hubs$$"; : > "$s/stitle$$"; : > "$s/fleet-gone$$"
  t0=$(now)
  FLEET_SELFTEST_REAP_SOCKDIR="$s" FLEET_SELFTEST_REAP_ROOTS="$tt/none" bash "$BIN/fleet-selftest-reap.sh" >/dev/null 2>&1
  SECS=$(since "$t0")
  if TMUX_TMPDIR="$tt" "$REAL_TMUX" -L "hubs$$" has-session 2>/dev/null; then
    TMUX_TMPDIR="$tt" "$REAL_TMUX" -L "hubs$$" kill-server 2>/dev/null; rm -rf "$tt"
    WHY="the leaked -f /dev/null server is still running"; return 1
  fi
  [ ! -e "$s/stitle$$" ] || { rm -rf "$tt"; WHY="the dead socket is still there"; return 1; }
  [ -e "$s/fleet-gone$$" ] || { rm -rf "$tt"; WHY="a fleet* socket was removed"; return 1; }
  rm -rf "$tt"
  WHAT="测试漏掉的服务器（-f /dev/null、无客户端、超龄）被收掉，死 socket 删掉，fleet* 不动；跑测试的入口给每个测试一个自己的 socket 目录、跑完清空"
}

# A window went without its ID closing — a reaper that only marked it retired, a
# kill — and the hub kept the ID open for good: 272 open beside ~17 windows (BCYB).
# The node now tells the hub which IDs its windows carry (`fleet-id.sh live`, the
# cleanup tick after the push); a scan no tmux server answered tells it nothing.
drill_id_window_gone_open() {
  CAP=20; local t0 c L F1 F2 hub out rc
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  c="$WORK/idgone"; L="brkidg$$"; mkdir -p "$c/fleets/$L" "$c/ids"; : > "$c/fleets/$L/conf"
  F1=$(python3 -c 'import uuid; print(uuid.uuid4())'); F2=$(python3 -c 'import uuid; print(uuid.uuid4())')
  printf '{"ev":"opened","title":"gone","id":"%s","seq":1,"ts":1}\n' "$F2" > "$c/ids/$F2.ndjson"
  "$REAL_TMUX" -L "$L" -f /dev/null new-session -d -s "$L" 'sleep 120' 2>/dev/null || { WHY="tmux"; return 1; }
  "$REAL_TMUX" -L "$L" set-window-option -t "$L:" @fleet_id "$F1" 2>/dev/null
  hub="$WORK/idgone-hub.sh"
  cat > "$hub" <<HUB
#!/bin/bash
cat > "$c/body.\$1"; printf '200\n{"closed":[{"id":"$F2","short":"X","reason":"hub:gone"}],"reopened":[],"kept":1,"live":1,"open":{}}\n'
HUB
  t0=$(now)
  out=$(FLEET_CONF_DIR="$c" FLEET_ID_HUB_POST="bash $hub" FLEET_ID_PULL=0 env -u TMUX -u TMUX_PANE bash "$BIN/fleet-id.sh" live 2>&1); rc=$?
  "$REAL_TMUX" -L "$L" kill-server 2>/dev/null
  [ "$rc" = 0 ] && grep -q "\"$F1\"" "$c/body.POST" 2>/dev/null && ! grep -q "$F2" "$c/body.POST" \
    || { WHY="the live list does not name the window's ID alone (rc=$rc $out · $(cat "$c/body.POST" 2>/dev/null))"; return 1; }
  [ -f "$c/ids/.hub/live.json" ] || { WHY="the hub's answer was not kept for the doctor"; return 1; }
  rm -f "$c/body.POST"
  out=$(FLEET_CONF_DIR="$c" FLEET_ID_HUB_POST="bash $hub" env -u TMUX -u TMUX_PANE bash "$BIN/fleet-id.sh" live 2>&1); rc=$?
  [ "$rc" = 75 ] && [ ! -e "$c/body.POST" ] || { WHY="with no fleet server up it still reported (rc=$rc) — a down fleet would close every ID"; return 1; }
  grep -q 'fleet-id.sh" live' "$BIN/fleet-cleanup-daemon.sh" || { WHY="the cleanup tick never runs the reconcile"; return 1; }
  grep -Eq 'self\.end_id\(snap\["@fleet_id"\](, why)?\)' "$BIN/fleet-cleanup-idle.py" || { WHY="the idle reaper's kill-window still leaves the ID open"; return 1; }
  SECS=$(since "$t0")
  WHAT="节点每拍把活窗口的 ID 报给 hub（不在的由 hub 关成 hub:gone，再出现就恢复）；没有服务器回答就不报；空闲回收关窗口时写上 closed"
}

# A test's / a drill's tmux server run with the real FLEET_CONF_DIR lazily opened
# IDs on the login's ledger that no window of the fleet ever carried (BCYB: 53).
drill_id_test_server_lazy() {
  CAP=15; local t0 c L F
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  c="$WORK/idlazy"; L="brkidl$$"; mkdir -p "$c/ids"
  F=$(python3 -c 'import uuid; print(uuid.uuid4())')
  "$REAL_TMUX" -L "$L" -f /dev/null new-session -d -s "$L" 'sleep 120' 2>/dev/null || { WHY="tmux"; return 1; }
  "$REAL_TMUX" -L "$L" set-window-option -t "$L:" @fleet_id "$F" 2>/dev/null
  local sp pid pane
  sp=$("$REAL_TMUX" -L "$L" display-message -p '#{socket_path}'); pid=$("$REAL_TMUX" -L "$L" display-message -p '#{pid}')
  pane=$("$REAL_TMUX" -L "$L" display-message -p -t "$L:" '#{pane_id}')
  t0=$(now)
  printf '{"source":"startup","session_id":"brk-lazy-1"}' | FLEET_CONF_DIR="$c" FLEET_ID_PUSH=0 TMUX="$sp,$pid,0" TMUX_PANE="$pane" \
    bash "$BIN/fleet-id.sh" hook >/dev/null 2>&1
  if [ -e "$c/ids/$F.ndjson" ]; then "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; WHY="a server no fleet of this login runs opened an ID"; return 1; fi
  mkdir -p "$c/fleets/$L"
  printf '{"source":"startup","session_id":"brk-lazy-2"}' | FLEET_CONF_DIR="$c" FLEET_ID_PUSH=0 TMUX="$sp,$pid,0" TMUX_PANE="$pane" \
    bash "$BIN/fleet-id.sh" hook >/dev/null 2>&1
  "$REAL_TMUX" -L "$L" kill-server 2>/dev/null
  grep -q '"lazy": *true' "$c/ids/$F.ndjson" 2>/dev/null || { WHY="a fleet's own window opened before its ledger no longer gets one"; return 1; }
  SECS=$(since "$t0")
  WHAT="不是本登录 fleet 的 tmux 服务器（测试、演练）上的会话不在真账本上懒开 ID；fleet 自己的窗口照旧补开"
}

# A drill's tmux server died (kill-server, SIGKILL) and left its socket file, named
# `fleet-…` — which the hourly sweep skipped as a fleet's own (BCYB: 19
# `fleet-drill-drill<pid>`). A configured fleet's socket is still never touched.
drill_drill_socket_left() {
  CAP=20; local tt s t0 pid c
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  tt=$(mktemp -d /tmp/brkds.XXXXXX) || { WHY="mktemp"; return 1; }
  s="$tt/tmux-$(id -u)"; c="$tt/conf"; mkdir -p "$c/fleets/fleet-mine$$"
  for n in "fleet-drill-x$$" "fleet-mine$$" "fleet-young$$"; do
    TMUX_TMPDIR="$tt" "$REAL_TMUX" -L "$n" -f /dev/null new-session -d 'sleep 60' 2>/dev/null || { rm -rf "$tt"; WHY="tmux $n"; return 1; }
    pid=$(TMUX_TMPDIR="$tt" "$REAL_TMUX" -L "$n" display-message -p '#{pid}' 2>/dev/null)
    kill -9 "$pid" 2>/dev/null
  done
  sleep 0.3
  [ -S "$s/fleet-drill-x$$" ] || { rm -rf "$tt"; WHY="SIGKILL left no socket to sweep (cannot drill)"; return 1; }
  touch -t 202001010000 "$s/fleet-drill-x$$" "$s/fleet-mine$$"
  t0=$(now)
  FLEET_CONF_DIR="$c" FLEET_SELFTEST_REAP_SOCKDIR="$s" FLEET_SELFTEST_REAP_ROOTS="$tt/none" bash "$BIN/fleet-selftest-reap.sh" >/dev/null 2>&1
  SECS=$(since "$t0")
  [ ! -e "$s/fleet-drill-x$$" ] || { rm -rf "$tt"; WHY="a dead drill socket named fleet-… is still there"; return 1; }
  [ -e "$s/fleet-mine$$" ] || { rm -rf "$tt"; WHY="a configured fleet's socket was removed"; return 1; }
  [ -e "$s/fleet-young$$" ] || { rm -rf "$tt"; WHY="a fresh fleet-… socket was removed inside the age gate"; return 1; }
  rm -rf "$tt"
  WHAT="演练死掉留下的 fleet-… 死 socket 过了年龄线就删；配置过的 fleet 的 socket、刚死的不碰"
}

# A PVC carries old process/update state into a new container (#3022).
drill_node_container_restart() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_image_update_never_resumes_saved_switch LinuxNode.test_new_container_does_not_adopt_old_pid >"$WORK/container-restart.out" 2>&1; then
    WHY="container adopted an old PID or switched the image runtime: $(tail -n 2 "$WORK/container-restart.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="新容器不接管上次的 PID；镜像负责升级时不恢复旧的切换"
}

# A managed login whose env never asked for a lease. Linux (issue #3211): the pool
# synced into the shared proxy, yet no accounts/hub:<label> marker, `ready` creds
# false, the hub's placement «not ready: creds» on every dispatch — prepare writes
# CCQUOTA_FLEET_CREDS=1 for a new login and adds it to an older store. Mac (issue
# #3276): adopt built logins/<login>.env from the plist and the store's node.env,
# neither of which said it — the node program never leased and the first prompt 403'd.
drill_linux_login_no_lease() {
  CAP=30; local t0
  t0=$(now)
  python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_every_login_leases_its_credentials >"$WORK/linux-lease.out" 2>&1 \
    || { WHY="a Linux login's env carries no CCQUOTA_FLEET_CREDS=1: $(tail -n 2 "$WORK/linux-lease.out")"; return 1; }
  python3 "$BIN/fleet-node-supervisor-selftest.py" H_Accounts.test_store_login_leases_its_credentials >"$WORK/mac-lease.out" 2>&1 \
    || { WHY="a Mac login's logins/<login>.env carries no CCQUOTA_FLEET_CREDS=1: $(tail -n 2 "$WORK/mac-lease.out")"; return 1; }
  SECS=$(since "$t0")
  WHAT="Linux：新登录和旧存储的登录都带 CCQUOTA_FLEET_CREDS=1；Mac 接管：有凭据存储的登录带上、更早接管的补上；令牌不动，没存储的不碰"
}

# Several logins on one Linux machine (EPIC #3208 C1, issue #3209): the image's
# passwd is gone at every start, so the volume's declarations are the truth.
# Each drill runs bin/fleet-node-linux-selftest.py's LinuxTenants leg on a fake
# passwd in a temp dir; the root smoke (extras/managed-node/smoke.py) does it for real.
linux_tenant_leg() {
  python3 "$BIN/fleet-node-linux-selftest.py" "LinuxTenants.$1" >"$WORK/$1.out" 2>&1
}

drill_linux_uid_reuse() {
  CAP=15; local t0
  t0=$(now)
  linux_tenant_leg test_uid_reuse || { WHY="a login changed number, a retired number came back, or a foreign-owned home was chowned: $(tail -n 3 "$WORK/test_uid_reuse.out")"; return 1; }
  SECS=$(since "$t0")
  WHAT="开 globex 与 drill2 → 清空 passwd 再 boot：号码不变；删 drill2 再开 drill3 / drill2：拿新号码，不给 10003；家属主不对 boot 停下、不 chown"
}

drill_linux_removed_login_lingers() {
  CAP=15; local t0
  t0=$(now)
  linux_tenant_leg test_removed_login_lingers || { WHY="something of a removed login stayed: $(tail -n 3 "$WORK/test_removed_login_lingers.out")"; return 1; }
  SECS=$(since "$t0")
  WHAT="login remove：node leave、account forget、credsep purge、杀进程、家进 attic（600）、userdel / groupdel、声明删掉、号码进 .retired；再删一次答 4"
}

drill_linux_tenant_cross_read() {
  CAP=15; local t0
  t0=$(now)
  linux_tenant_leg test_tenant_cross_read || { WHY="a home stayed readable or was handed to another login: $(tail -n 3 "$WORK/test_tenant_cross_read.out")"; return 1; }
  SECS=$(since "$t0")
  WHAT="放宽成 0755 的家 boot 后回到 0700；新登录落在别人号码的家目录上被拒、不 chown"
}

# ---- linux-image-pins-old (#3212): the Linux node's runtime was the image's —
# a restart put its old version back, so the machine never followed stable.
# Now the image only seeds the disk runtime; a restart keeps what the updater
# switched to, a newer image is taken only at rest, and the loop restarts the
# supervisor from the new `current` instead of ending the container.
drill_linux_image_pins_old() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_restart_never_goes_back_to_image \
       LinuxNode.test_loop_restarts_supervisor_from_new_current LinuxNode.test_image_self_updates_on_its_volume \
       >"$WORK/linux-pins.out" 2>&1; then
    WHY="the Linux runtime still follows the image: $(tail -n 2 "$WORK/linux-pins.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="镜像 A、盘上已切到 B：重启两次仍是 B；更新器切换中不播种；空闲时更新的镜像 C 才播种（.prev=B）；supervisor 退出后从新 current 再起"
}

# ---- user-pod-runtime-pileup (#4283): a person's pod owns its runtime by the
# image — no updater retires a version — and each new image's 1.3 GB copy stayed
# on the PVC until the disk guard refused every session. A boot keeps two.
drill_user_pod_runtime_pileup() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_image_owned_runtime_never_piles_up \
       >"$WORK/linux-pileup.out" 2>&1; then
    WHY="an image-owned runtime still keeps every version it was ever seeded: $(tail -n 2 "$WORK/linux-pileup.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="镜像管的运行时换五次镜像后盘上只剩 current + .prev；同镜像重启也清掉旧版本和中断的 .seed-partial，不碰非版本目录；更新器管的不删"
}

# The hub asks a Linux managed machine's root node program to do something
# other than open / close one fresh login (EPIC #3208 C2, issue #3210). The node
# half is tokenledger/agent (the two fixed argvs, BAD_ARGS for the rest,
# a Mac's program declares nothing); the opener half its own exit 3 to another op.
drill_linux_hub_other_root_op() {
  CAP=120; local t0 f="$ROOT/tokenledger/agent/node_machine_accounts.go"
  t0=$(now)
  grep -q 'func validateLinuxAccountOp' "$f" && grep -q 'func linuxAccountArgv' "$f" \
    || { WHY="the machine's account half has no whitelist (validateLinuxAccountOp / linuxAccountArgv)"; return 1; }
  linux_tenant_leg test_hub_op_owns_its_login \
    || { WHY="a login another op made was opened again: $(tail -n 3 "$WORK/test_hub_op_owns_its_login.out")"; return 1; }
  _drill_go_tests "TestMachineOpensLoginsWithFixedArgv TestMachineRefusesOtherRootOps TestMachineAccountOpsOffAddsNothing" \
    "$ROOT/tokenledger/agent/node_machine_accounts_test.go" \
    "别的 op、root / fleet / fleetcred、全数字、换行全名、坏加入码一律 BAD_ARGS、什么都不跑；只两条固定 argv；Mac 的整机程序不报 CapLoginJoin、回 NOT_ADMIN；别的 op 开过的登录答 3" \
    github.com/verkyyi/claude-fleet/tokenledger/agent || return 1
  SECS=$(since "$t0")
}

# ---- linux-entry-weak-door (#3213): the ACK node's public door is the entry port
# alone — never the system sshd's 22 — and the pod tells the hub the load
# balancer's address, so the knock lands on the door and not on the NAT egress.
drill_linux_entry_weak_door() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_entry_door_is_the_entry_port_only \
       >"$WORK/linux-door.out" 2>&1; then
    WHY="the ACK door is wider than the entry port, or the hub is not told where it is: $(tail -n 3 "$WORK/linux-door.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="公网 Service 只有 22022（Local）、系统 22 只在无头 Service；FLEET_ENTRY=1，entry=<负载均衡>:22022 到得了 entry reach；入口 sshd 只认 root 的 keys，无密码、无 root、不读 ~/.ssh"
}

# ---- linux-egress-metadata (#3281): flannel enforces no NetworkPolicy, so the ACK
# node's own netns carries the egress guard — an init container with NET_ADMIN cuts
# the cloud metadata address, the cluster's pod / service ranges and the private
# ranges; the fleet container never holds NET_ADMIN, so its root cannot undo them.
drill_linux_egress_metadata() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_egress_guard_cuts_metadata_and_cluster \
       >"$WORK/linux-egress.out" 2>&1; then
    WHY="the ACK pod can reach the cloud metadata or the cluster, or root there can lift the guard: $(tail -n 3 "$WORK/linux-egress.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="init 容器 egress-guard（只 NET_ADMIN+NET_RAW）写 OUTPUT：lo、回包、kube-dns 53 放行，元数据 / pod / Service / 私网段 REJECT；fleet 容器无 NET_ADMIN；坏网段不渲染"
}

# ---- linux-github-unreachable (#3348): the ACK node's CN egress cannot reach
# github.com's git transport; git goes through the Singapore relay (GitHub hosts
# :443 from the cluster egress only), a mirrored repo is fetched in-cluster, and
# every login gets the mirrors and the toolchain without a hand step.
drill_linux_github_unreachable() {
  CAP=20; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_dev_network_github_relay_mirror_and_toolchain \
       >"$WORK/linux-github.out" 2>&1; then
    WHY="a login on the ACK node has no road to GitHub, or the relay lets more than GitHub through: $(tail -n 3 "$WORK/linux-github.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="gh-relay 只放集群出口的 CONNECT 到 GitHub:443；/etc/gitconfig 让 github.com 走中转、镜像仓库从集群镜像拉而推去 GitHub；/etc/fleet-devnet.env 给每个登录镜像源；egress 只开镜像 Service 一个口；镜像带工具链"
}

# ---- cred-in-user-pod (#3547, EPIC #3500 C2): a user pod in the cluster held the
# subscription tokens its node program leased; now its sessions route to the one
# cluster credential proxy, nothing is leased into it, the volume is purged at each
# start, and the pod goes out only through the one egress.
drill_cred_in_user_pod() {
  CAP=20; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_central_pod_holds_no_credential \
       >"$WORK/cred-user-pod.out" 2>&1; then
    WHY="a user pod still leases or keeps a subscription credential, or reaches the internet directly: $(tail -n 3 "$WORK/cred-user-pod.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="render --cred-central / --egress-proxy / --egress-closed：每个登录 CCQUOTA_FLEET_CREDS=0、走 fleet-credproxy；启动时盘上的 token、Codex auth、池子删光（节点令牌、relay 通行证留着）；守卫最后一句 REJECT；出口只放白名单主机、只认 pod 网段"
}

# ---- egress-private-via-proxy (#4311): with every public host and port open, the
# egress's address check is the wall — a name resolving to metadata, the VPC, a
# private range or loopback (even one answer of several) gets 403, never a tunnel.
drill_egress_private_via_proxy() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 -I "$ROOT/deploy/k8s/egress/base/fleet-egress.py" --selftest private >"$WORK/egress-private.out" 2>&1; then
    WHY="fleet-egress opens a tunnel to a private / metadata address: $(tail -n 3 "$WORK/egress-private.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="fleet-egress.py 主机、端口都放开后，解析到元数据 / VPC / 私网 / 回环（含一个答案混私网的重绑）仍 403 blocked_address，任何端口"
}

# ---- egress-required-via-direct (#4311): a FLEET_EGRESS_REQUIRE_VIA host (the LLM
# endpoints) leaves only through its parent; an uncovered one refuses the start,
# a refusing parent is a 502 and the direct resolver is never asked.
drill_egress_required_via_direct() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 -I "$ROOT/deploy/k8s/egress/base/fleet-egress.py" --selftest require-via >"$WORK/egress-reqvia.out" 2>&1; then
    WHY="a REQUIRE_VIA host leaves directly, or an uncovered policy starts: $(tail -n 3 "$WORK/egress-reqvia.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="REQUIRE_VIA 的域名没有上级映射启动即拒；上级拒绝就 502、从不直连解析，443 和别的端口一样"
}

# ---- linux-create-relay-403 (#3213): the hub's create op opens a login whose
# account is still `creating`; the relay pass is refused (403) and must not undo it.
drill_linux_create_relay_403() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_relay_refused_while_account_creating_keeps_login \
       >"$WORK/linux-relay403.out" 2>&1; then
    WHY="a relay 403 still rolls back a new login: $(tail -n 3 "$WORK/linux-relay403.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="开号时 relay-credential 答 403：登录照常 adopt、不写 relay.token；答 500 仍停下"
}

# ---- linux-login-locked (#3304): useradd left the shadow field `!` (locked); the
# entry sshd runs `UsePAM no`, and OpenSSH without PAM refuses a locked account
# even with its key. open / boot leave `*`, an older `!` is put right by the next boot.
drill_linux_login_locked() {
  CAP=15; local t0
  t0=$(now)
  linux_tenant_leg test_login_locked || { WHY="a Linux login is left locked (shadow \`!\`): $(tail -n 3 "$WORK/test_login_locked.out")"; return 1; }
  SECS=$(since "$t0")
  WHAT="开号、boot 重建后 shadow 第二列是 *；旧的 ! 下次 boot / open 改正；已是 * 不再 usermod"
}

# ---- linux-restore-crashloop (#3289): a session restore that did not bring every
# pinned session back raised out of bootstrap and the container exited — CrashLoop
# on the same snapshot. Now the snapshot is set aside and the machine goes ready;
# and an empty skip list no longer swallows the pinned map (the root cause).
drill_linux_restore_crashloop() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_failed_restore_keeps_the_machine_ready \
       >"$WORK/linux-restore.out" 2>&1; then
    WHY="a failed session restore still takes the Linux node down: $(tail -n 3 "$WORK/linux-restore.out")"; return 1
  fi
  grep -q 'FILENAME == skipf' "$BIN/fleet-sessions-snapshot.sh" \
    || { WHY="sessions-snapshot restore reads its skip list by NR == FNR again (an empty one swallows the map)"; return 1; }
  SECS=$(since "$t0")
  WHAT="restore 退 1：快照改名 sessions.snapshot.failed-<UTC>、写 ready、不退出；空跳过表不再吞掉钉住的表"
}

# ---- restart-done-not-pinned (#3511): a planned restart's pin skipped every
# `done` session — a newcomer's no-repo sessions had answered and did not come back.
drill_restart_done_not_pinned() {
  CAP=40; local t0
  t0=$(now)
  suite_holds fleet-sessions-snapshot-selftest.sh 'A: the no-repo done session was not pinned' || return 1
  grep -q 'RESTORE_KEEP_DONE=1' "$BIN/fleet-sessions-snapshot.sh" \
    || { WHY="the snapshot restore no longer asks fleet-restore to bring done sessions back"; return 1; }
  SECS=$(since "$t0")
  WHAT="save 钉住所有开着的会话（done、no-repo 也算，exited 不算）；kill-server 后 restore 带 RESTORE_KEEP_DONE=1，同名、同目录、同一段对话回来（fleet-sessions-snapshot-selftest.sh 真跑，这里按名守住）"
}

# ---- task-window-duplicate (T847): a second window opened on a record that still
# had one shared its ID; the copy's reap closed it and the hub ended the record.
drill_task_window_duplicate() {
  CAP=40; local t0
  t0=$(now)
  suite_holds task-one-window-selftest.sh 'D5: no window opened' 'B2: the ID stays open while the original runs' \
    'E3: the spawner was called for a running record' 'F9: the hub'"'"'s record is back' || return 1
  grep -q '_ttask=$TASK_REF' "$BIN/dash-raw-session.sh" \
    && grep -q 'fleet_task_running "$_ttask" "$_tfid"' "$BIN/dash-raw-session.sh" \
    || { WHY="dash-raw-session.sh lost Task or current continuation FID duplicate checks"; return 1; }
  grep -q 'fleet_fid_shared' "$BIN/fleet-cleanup-idle.py" \
    || { WHY="the idle reaper no longer keeps an ID another window carries"; return 1; }
  SECS=$(since "$t0")
  WHAT="同一条记录不开第二个窗口（本机 / hub 在线都算）；副本回收只关窗、不结束共享的 ID；误关的 revive 回来（task-one-window-selftest.sh 真跑，这里按名守住）"
}

# ---- linux-recreate-route-lost (#3421): credsep's root settings live in the image
# layer; a recreated pod rewrote only the primary login's relay route, so a login
# `login open` made went `route: direct` (unsupported_region from the CN egress).
drill_linux_recreate_route_lost() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_recreate_rewrites_every_logins_route \
       >"$WORK/linux-route.out" 2>&1; then
    WHY="a recreated pod leaves a login without its relay route: $(tail -n 3 "$WORK/linux-route.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="每次启动、装之前：每个已入网登录的 <LIB>/<login>.conf 写回 relay 与允许主机，其它行不动；没入网的不写；第二次一字不写"
}

# ---- linux-no-primary-regrows (#3526): the image opened its own `fleet` login at
# every start (FLEET_NODE_LOGIN=fleet) — an idle login no hub can assign, ~54
# processes and a warm pool on a person's machine; deleted, it came back on the
# next recreate. With `none` nothing is opened: only linux-tenants/ is rebuilt.
drill_linux_no_primary_regrows() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_no_primary_login_never_grows_back \
       >"$WORK/linux-no-primary.out" 2>&1; then
    WHY="a node with no primary login opens one again on a recreate: $(tail -n 3 "$WORK/linux-no-primary.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="FLEET_NODE_LOGIN=none（镜像与清单都是）：重建时装机不带 --login，只按 linux-tenants/ 起已登记的登录，一个也不新开；某人的家坏了机器照样就绪"
}

# ---- linux-image-local-owner (#3421): tar as root kept node's uid 1001 on
# /usr/local; the shared proxy's launcher read `untrusted`, the pod never Ready.
drill_linux_image_local_owner() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_image_usr_local_is_roots \
       >"$WORK/linux-owner.out" 2>&1; then
    WHY="the image can leave /usr/local to a tarball's uid: $(tail -n 3 "$WORK/linux-owner.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="镜像里每个 tar --no-same-owner，构建断言 /usr/local 是 root 的；启动把 credsep LIB 的上级收回 root、去 go-w"
}

# ---- linux-restart-ui-crashloop (#3421): a restart kept a login's tmux server;
# install-apply's UI refresh FAILed on it, activate raised, CrashLoop.
drill_linux_restart_ui_crashloop() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_restart_with_ui_fail_only_is_applied \
       >"$WORK/linux-ui.out" 2>&1; then
    WHY="a ui-only PARTIAL apply still stops the Linux node: $(tail -n 3 "$WORK/linux-ui.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="apply PARTIAL 只坏 ui：照样打标记、机器起来；别的步骤坏照旧停；ui: FAIL 行带出失败的 server 与原话"
}

# ---- linux-stale-lane-door-down (#3333): a deleted drill login left
# agent/<login>/lane.json (refused, WRONG_LOGIN); the readiness probe failed on
# any refused lane, the LoadBalancer (externalTrafficPolicy: Local) dropped the
# pod and the 22022 door died for every login. Now readiness is machine-wide
# only, a gone login's lane is ignored, and removing a login moves its agent dir.
drill_linux_stale_lane_door_down() {
  CAP=15; local t0
  t0=$(now)
  if ! python3 "$BIN/fleet-node-linux-selftest.py" StaleLane >"$WORK/linux-stale-lane.out" 2>&1; then
    WHY="one login's refused lane still takes the Linux node's door down: $(tail -n 3 "$WORK/linux-stale-lane.out")"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="一个登录的 lane 被拒：pod 照样 Ready（就绪只看整机）；删掉的登录留下的 lane 不算；account forget / login remove 把 agent/<login> 挪进 attic"
}

# rp_rig <name> — a sandbox fleet <name> (acme/app) with its own tmux server: sets
# d (its dir) and BREAK_SOCK; rp_env runs a command in it.
rp_rig() {
  d="$WORK/$1"; BREAK_SOCK="$WORK/sock-$1"
  mkdir -p "$d/conf/fleets/$1" "$d/conf/control" "$d/shim" "$d/main"
  : > "$d/conf/fleets/$1/conf"
  fx_repo "$d/conf" "$1" acme/app FLEET_MAIN="$d/main"
  nt -f /dev/null new-session -d -s "$1" -n home 'exec sleep 600'
}
rp_env() { env PATH="$WORK/tbin:$d/shim:$PATH" HOME="$WORK/home" BREAK_SOCK="$BREAK_SOCK" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
             CCQUOTA_FLEET=1 FLEET_HUB_RECEIPT_WAIT=0 FLEET_ORPHAN_ALERT_CMD="${RP_ALERT:-true}" FLEET_PEER_RECEIPT_SECS=0 "$@"; }

# Parent delivery is retired for every old address: absent, remote or live.
# Explicit old own-session calls still preserve their own result history.
drill_report_parent_gone() {
  CAP=30; local d w p out mode t0 fid=11111111-2222-4333-8444-555555555555
  rp_rig rpg || { WHY="cannot start isolated tmux"; return 1; }
  w=$(nt new-window -d -P -F '#{window_id}' -t rpg -n own 'exec sleep 120')
  p=$(nt display-message -p -t "$w" '#{pane_id}')
  nt set-option -w -t "$w" @fleet_id "$fid"
  t0=$(now)
  for mode in gone remote online; do
    nt set-option -w -t "$w" @origin "$mode"
    nt set-option -w -t "$w" @origin_wid "other-fleet/$mode"
    out=$(rp_env env TMUX="$BREAK_SOCK,0,0" TMUX_PANE="$p" FLEET_ID_PUSH=0 \
      bash "$BIN/fleet-report-parent.sh" -L rpg --state waiting --summary "$mode history" 2>&1) || {
      WHY="own result failed for $mode: $out"; return 1;
    }
    case "$out" in *RECORDED:*RETIRED:*) ;; *) WHY="unexpected delivery for $mode: $out"; return 1 ;; esac
  done
  out=$(rp_env python3 "$BIN/fleet_id.py" get "$fid" --json)
  python3 -c 'import json,sys; r=json.loads(sys.argv[1])["results"]; assert [x["summary"] for x in r] == [x+" history" for x in ("gone","remote","online")],r' "$out" || {
    WHY='own result history lost across old Parent addresses'; return 1;
  }
  [ ! -e "$d/conf/global/orphan-reports.ndjson" ] && [ ! -d "$d/conf/control/hub-outbox" ] || {
    WHY='retired report created orphan notification or relay'; return 1;
  }
  out=$(rp_env bash "$BIN/fleet-report-parent.sh" -L rpg --win "$w" --state reaped 2>&1)
  case "$out" in RETIRED:*) ;; *) WHY="old hook not retired: $out"; return 1 ;; esac
  SECS=$(since "$t0")
  WHAT='旧父地址消失、跨机或在线均不投递；自身结果仍保存，旧hook不写回报或通知'
}

drill_cred_migration_client() {
  CAP=120; local t0
  t0=$(now)
  _drill_go_tests 'TestCredPolicyMigrationSkipsClients' "$ROOT/tokenledger/hub/api/fleet_cred_policy_test.go" \
    '迁移排除纯客户端、保留离线及混合执行节点，角色变化重审且旧授权不变' || return 1
  SECS=$(since "$t0")
}

# ---- site-console-indexed (#3583, EPIC #3569 共同约定 6): the console and the
# intro page shared one address, so a crawler that read the intro page walked
# straight into the console's pages. Now: the console is /app, every answer
# under it says X-Robots-Tag: noindex, the old addresses 301 there, and "/" is
# the site (signed out) or /app (signed in) — the client's paths untouched.
drill_site_console_indexed() {
  CAP=120; local t0 f="$ROOT/tokenledger/hub/api/app_mount.go"
  t0=$(now)
  grep -q 'X-Robots-Tag", "noindex' "$f" \
    || { WHY="app_mount.go no longer marks the console noindex"; return 1; }
  grep -q 's.appMount(s.routes())' "$ROOT/tokenledger/hub/api/server.go" \
    || { WHY="the router is no longer behind appMount: the console is back at the root"; return 1; }
  _drill_go_tests 'TestAppIsNoindex TestAppOldPathsMoveUnderApp TestAppRoot TestClientPathsUnchanged' \
    "$ROOT/tokenledger/hub/api/app_mount_test.go" \
    '控制台在 /app、每页 noindex；旧地址 301 过去；/ 未登录是官网、登录了 302 /app；客户端路径逐字节不变（go test）' || return 1
  SECS=$(since "$t0")
}

drill_db_move_policy_seed() {
  CAP=120; local t0
  t0=$(now)
  _drill_go_tests 'TestMoveDatabasePolicySeed' "$ROOT/tokenledger/hub/store/dbmove_test.go" \
    'Postgres 门验证新库可迁移、已有授权拒绝覆盖、源库 legacy 模式保留' ./hub/store || return 1
  [ -n "${CCQUOTA_DB_URL:-}" ] || WHAT='没有测试 Postgres：按名核对搬迁回归测试在，tokenledger-pg 门执行'
  SECS=$(since "$t0")
}

# Nothing starts a session by itself (issue #3120, EPIC #3111 C9): the red-master
# macOS watcher once spawned a fixer for the breakage it filed (④). The autofill
# dispatcher (③) left with its template and shell (#3576) — nothing of it is left
# to come back. The rest of the list (① ② ⑤) is the other members' to drill.
drill_nothing_starts_by_itself() {
  CAP=30; local sb t0 n
  sb="$WORK/nsbi"; mkdir -p "$sb/bin" "$sb/shim" "$sb/conf" "$sb/mainA/.github/workflows" "$sb/mainA/bin" "$sb/dg"
  for f in "$BIN"/* "$BIN"/.*.py; do [ -e "$f" ] && ln -s "$f" "$sb/bin/${f##*/}"; done
  # every spawner a session could start through counts instead of opening
  for f in dash-issue-session.sh dash-raw-session.sh; do
    rm -f "$sb/bin/$f"; printf '#!/bin/sh\necho "$0 $*" >> "%s/spawned"\n' "$sb" > "$sb/bin/$f"; chmod +x "$sb/bin/$f"
  done
  : > "$sb/mainA/.github/workflows/selftests-macos.yml"; : > "$sb/mainA/bin/fleet-stable.sh"
  # a backlog of autofill-labelled issues, and master's macOS run red
  cat > "$sb/shim/gh" <<SH
#!/bin/sh
case "\$*" in
  *actions/workflows/*) printf '30\t3333333ccc\tfailure\tpush\n29\t1111111aaa\tsuccess\tpush\n' ;;
  *actions/runs/30/jobs*) printf '901\tfailure\tmacOS / shard 2\n' ;;
  *actions/runs/*/jobs*) printf '902\tsuccess\tmacOS / shard 2\n' ;;
  'issue list'*) echo '[{"number":12,"labels":[{"name":"autofill"},{"name":"priority:p0"}],"assignees":[]}]' ;;
esac
SH
  printf '#!/bin/sh\necho "$*" >> "%s/alerted"\n' "$sb" > "$sb/alert"
  chmod +x "$sb/shim/gh" "$sb/alert"
  t0=$(now)
  # ④ the diskguard tick reads master's red macOS run: alerts, files nothing, spawns nobody
  cat > "$sb/dg.sh" <<SH
FLEET_DISKGUARD_SOURCE=1 . "$sb/bin/fleet-diskguard.sh"
BIN="$sb/bin" GDIR="$sb/dg"
fleet_sockets() { echo fleet; }
fleet_conf_file() { echo "$sb/fleet.conf"; }
fleet_load_conf() { :; }
fleet_repos() { echo o/a; }
fleet_load_repo_conf() { FLEET_MAIN="$sb/mainA"; }
macos_watch
SH
  : > "$sb/fleet.conf"
  env PATH="$sb/shim:$PATH" FLEET_CONF_DIR="$sb/conf" \
    FLEET_MACOS_ALERT_CMD="$sb/alert" bash "$sb/dg.sh" >/dev/null 2>&1
  until_ok 15 grep -q 'alerted' "$sb/dg/macos-watch.log" 2>/dev/null \
    || { WHY="the diskguard tick never alerted the red master run"; return 1; }
  SECS=$(since "$t0")
  grep -q 'breakage' "$sb/alerted" 2>/dev/null || { WHY="nobody was told about the red master"; return 1; }
  n=0; [ -f "$sb/spawned" ] && n=$(wc -l < "$sb/spawned" | tr -d ' ')
  [ "$n" = 0 ] || { WHY="$n session(s) started by themselves: $(head -2 "$sb/spawned" | tr '\n' ' ')"; return 1; }
  WHAT="④ 红主干：diskguard 节拍提醒（不开单），0 个会话自己开出来"
}

# ---- release-push-lost (#3146, EPIC #3139 C7): the hub now tells every machine
# the moment stable moves (`release {sha}` → the node program's update-now, a
# login's install-sync --now). A push that is dropped — the link was down, the
# write failed, an older agent never listed CapRelease — must cost no more than
# the old wait: the machine's update clock (FLEET_NODE_UPDATE_EVERY, 300 s)
# still runs the update, and a pushed update-now runs it at once and is consumed.
drill_release_push_lost() {
  CAP=120; local t0 sb got
  t0=$(now)
  sb="$WORK/rpl"; mkdir -p "$sb/state"
  got=$(cd "$ROOT/bin" && FLEET_NODE_STATE="$sb/state" python3 -c 'import importlib.util, os
s = importlib.util.spec_from_file_location("fns", "fleet-node-supervisor.py"); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
d = object.__new__(m.Supervisor); d.p = m.Paths(); d.state = {"tasks": {"update": {"last_start": 1000.0}}}
tk = [t for t in m.default_table(d.p)["tasks"] if t["name"] == "update"][0]
out = []
out.append("lost-early=%s" % d.task_due(tk, 1000.0 + 60))            # a push lost: not yet …
out.append("lost-clock=%s" % d.task_due(tk, 1000.0 + tk["every"]))   # … the clock runs it
open(os.path.join(d.p.state, "update-now"), "w").write("a" * 40 + "\n")
out.append("pushed=%s" % d.task_due(tk, 1000.0 + 1))                  # a push: at once
out.append("took=%s" % m.update_now_take(d.p)[:7])
out.append("left=%s" % os.path.exists(os.path.join(d.p.state, "update-now")))
out.append("every=%s" % tk["every"])
print(" ".join(out))' 2>&1)
  case "$got" in
    *'lost-early=False lost-clock=True pushed=True took=aaaaaaa left=False every=300'*) ;;
    *) WHY="the update task's clock / update-now: $got"; return 1 ;;
  esac
  grep -q '<integer>1800</integer>' "$ROOT/launchd/com.claude-fleet.install-sync.plist.tmpl" \
    || { WHY="install-sync's 30-minute clock is gone — a lost push to a login would never be followed"; return 1; }
  bash "$BIN/fleet-install-sync.sh" --now --status >/dev/null 2>&1; [ $? -le 1 ] \
    || { WHY="fleet-install-sync.sh does not take --now"; return 1; }
  _drill_go_tests 'TestReleasePushOnPromoteBeatAndReconnect TestReleasePushOffAddsNothing TestReleasePromoteCallsOnPromote' \
    "$ROOT/tokenledger/hub/api/fleet_release_push_test.go" \
    '推送丢了：机器的 update 定时（300 秒）照样切到；推送到了：update-now 当拍就跑、跑时消掉；入口在发布、每条连接第一拍发 release，重复 / 旧的 seq 不发，不带能力的节点什么都不收（go test）' || return 1
  local what=$WHAT
  _drill_go_tests 'TestReleasePushWritesUpdateNow TestReleaseMachineHelloCapability TestReleasePushRunsInstallSync' \
    "$ROOT/tokenledger/agent/node_release_test.go" "$what" github.com/verkyyi/claude-fleet/tokenledger/agent || return 1
  SECS=$(since "$t0")
}
# ---- client-verify-no-ccquota / client-update-silent-fail (#3162): a client
# takes the hub's signed release with no ccquota. Before: install-sync checked
# every release with `ccquota release fetch`; the MacBook's ccquota (prod-46f5adf)
# had no `release` command and the #3047 fallback found no ccquota artifact for
# a client to borrow — fetch-failed every 30 minutes from 07:20, nobody told.
# Now bin/fleet-release-fetch.py checks it with python3 + `ssh-keygen -Y verify`
# (the hub's SSHSIG over the manifest, against the key pinned at install), and a
# stable seen but not taken past FLEET_INSTALL_SYNC_FETCH_ALARM_SECS (2h) is one
# notification and a red doctor row. A sandbox hub that really signs
# (fleet-release-hub-fixture.py), a real bare repo + install, a real tick.
relc_rig() { # <dir> — sets RC_C1 RC_C2 RC_HUB RC_PID; the install at C1, the hub's stable C2
  local d="$1"
  mkdir -p "$d/home/.local/bin" "$d/conf" "$d/hub/rel" "$d/tmp"
  # the MacBook's ccquota: too old to know `release`; any call is logged
  printf '#!/bin/sh\necho "$*" >> %s/ccquota.calls\necho "Error: unknown command \\"release\\" for \\"ccquota\\"" >&2\nexit 1\n' "$d" \
    > "$d/home/.local/bin/ccquota"; chmod +x "$d/home/.local/bin/ccquota"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    mkdir -p "$d/seed/bin"
    printf '#!/bin/sh\necho "apply: ok — stub"\n' > "$d/seed/bin/fleet-install-apply.sh"
    printf '#!/bin/sh\necho "  PASS  gh  ok"\n' > "$d/seed/bin/fleet-doctor.sh"
    printf '#!/bin/sh\nexit 0\n' > "$d/seed/bin/fleet-install-sync.sh"   # the install carries its daemon
    chmod +x "$d/seed/bin/"*
    echo one > "$d/seed/f"; git -C "$d/seed" add -A && git -C "$d/seed" commit -qm one || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c1"
    echo two > "$d/seed/f"; git -C "$d/seed" commit -qam two && git -C "$d/seed" push -q origin HEAD:master || exit 1
    git -C "$d/seed" rev-parse HEAD > "$d/c2"
    git clone -q "$d/origin.git" "$d/install" 2>/dev/null && git -C "$d/install" reset -q --hard "$(cat "$d/c1")"
  ) || return 1
  RC_C1=$(cat "$d/c1"); RC_C2=$(cat "$d/c2")
  mkdir -p "$d/hub/rel/$RC_C2/.release"
  git -C "$d/seed" archive "$RC_C2" | tar -x -C "$d/hub/rel/$RC_C2"
  printf '{"seq": 7, "prev": "%s", "artifacts": []}\n' "$RC_C1" > "$d/hub/rel/$RC_C2/.release/manifest.json"
  printf '%s\n' "$RC_C2" > "$d/hub/rel/stable"
  python3 "$BIN/fleet-release-hub-fixture.py" "$d/hub" 2>"$d/hub.err" &
  RC_PID=$!
  local i; for i in $(seq 1 100); do [ -s "$d/hub/port" ] && break; sleep 0.05; done
  [ -s "$d/hub/port" ] || return 1
  RC_HUB="http://127.0.0.1:$(cat "$d/hub/port")"
}
relc_tick() { # <dir> [VAR=val …] — one install-sync tick as a client: no ccquota but the old one
  local d="$1"; shift
  env -u FLEET_CCQUOTA -u FLEET_NOTIFY_CMD -u FLEET_DIST_SOURCE -u CCQUOTA_HUB_URL \
    HOME="$d/home" PATH="$d/home/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$d/tmp" \
    FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_HUB_URL="$RC_HUB" FLEET_INSTALL_SYNC_HOST=0 \
    FLEET_NODE_STATE="$d/no-node" FLEET_NODE_FOLLOW=0 FLEET_INSTALL_SYNC_CLIENT_FOLLOW=0 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$@" \
    bash "$BIN/fleet-install-sync.sh" --root "$d/install" >"$d/tick.out" 2>&1
}
relc_st() { sed -n "s/^$2: //p" "$1/conf/global/install-sync.state" 2>/dev/null | head -1; }

drill_client_verify_no_ccquota() {
  CAP=30; local t0 d
  command -v ssh-keygen >/dev/null 2>&1 || { WHY="no ssh-keygen here"; return 1; }
  d="$WORK/relc1"
  relc_rig "$d" || { WHY="could not build the rig: $(cat "$d/hub.err" 2>/dev/null)"; return 1; }
  t0=$(now)
  relc_tick "$d"
  SECS=$(since "$t0"); kill "$RC_PID" 2>/dev/null
  [ "$(relc_st "$d" result)" = switched ] \
    || { WHY="a client with no working ccquota did not take the release: $(relc_st "$d" result) — $(relc_st "$d" reason)"; return 1; }
  [ "$(git -C "$d/install" log -1 --format=%s)" = "fleet-release: $RC_C2 seq=7" ] \
    || { WHY="HEAD is not the imported release: $(git -C "$d/install" log -1 --format=%s)"; return 1; }
  [ ! -s "$d/ccquota.calls" ] || { WHY="ccquota was still asked: $(head -1 "$d/ccquota.calls")"; return 1; }
  WHAT="客户端只有一份不认识 release 的旧 ccquota：install-sync 用 python3 + ssh-keygen -Y verify 验入口的 SSHSIG，照常切到新版，ccquota 一次没被调用"
}

drill_client_update_silent_fail() {
  CAP=30; local t0 d sent
  command -v ssh-keygen >/dev/null 2>&1 || { WHY="no ssh-keygen here"; return 1; }
  d="$WORK/relc2"
  relc_rig "$d" || { WHY="could not build the rig: $(cat "$d/hub.err" 2>/dev/null)"; return 1; }
  touch "$d/hub/badsig"
  printf '#!/bin/sh\nprintf "%%s\\n---\\n" "$*" >> %s/notified\n' "$d" > "$d/notify"; chmod +x "$d/notify"
  # this login first saw stable C2 three hours ago, and has not taken it since
  mkdir -p "$d/conf/global"
  printf 'last_check: %s\nresult: fetch-failed\nhead: %s\nstable: %s\nstable_since: %s\nnotified: -\n' \
    "$(date +%s)" "$RC_C1" "$RC_C2" $(( $(date +%s) - 3 * 3600 )) > "$d/conf/global/install-sync.state"
  t0=$(now)
  relc_tick "$d" FLEET_NOTIFY_CMD="$d/notify"
  SECS=$(since "$t0")
  [ "$(relc_st "$d" result)" = fetch-failed ] || { kill "$RC_PID" 2>/dev/null; WHY="a release that does not verify was not fetch-failed: $(relc_st "$d" result)"; return 1; }
  sent=$(cat "$d/notified" 2>/dev/null)
  case "$sent" in *fetch-failed*) ;; *) kill "$RC_PID" 2>/dev/null; WHY="3h behind stable on fetch-failed and nobody was told (notify: ${sent:-none})"; return 1 ;; esac
  relc_tick "$d" FLEET_NOTIFY_CMD="$d/notify"; kill "$RC_PID" 2>/dev/null
  [ "$(grep -c '^---$' "$d/notified")" = 1 ] || { WHY="the same stuck episode was announced twice"; return 1; }
  sh "$BIN/fleet-install-follow.sh" --self --dir "$d/install" --conf-dir "$d/conf" > "$d/follow.out" 2>&1
  grep -q '^alarm: *1' "$d/follow.out" || { WHY="the doctor's install row stays quiet: $(tr '\n' '|' < "$d/follow.out")"; return 1; }
  WHAT="入口发布版 3 小时验不过（停在 fetch-failed）：一拍发一次通知（同一回只一次），install-follow 标 alarm → doctor 的 install 行 FAIL"
}

# A child's result handed to the person is never seen (issue #3369): orphan() wrote
# global/orphan-reports.ndjson and one alert, but no sidebar row nor the entry read
# it. bin/fleet-orphan-reports.py is the one reader: the inventory carries the
# unread rows (column 31 → `orphan_reports`), the sidebar draws one row each, the
# hub's overview lists them; read ⇒ gone everywhere.
drill_orphan_report_unseen() {
  CAP=30; local d="$WORK/oru" t0 id cell got
  mkdir -p "$d/conf/global"
  printf '{"ts": %s, "child_key": "issue-41", "state": "MERGED", "pr": "77", "summary": "landed the fix", "repo": "acme/app"}\n' \
    "$(date +%s)" > "$d/conf/global/orphan-reports.ndjson"
  t0=$(now)
  id=$(FLEET_CONF_DIR="$d/conf" python3 "$BIN/fleet-orphan-reports.py" list | cut -f1)
  cell=$(FLEET_CONF_DIR="$d/conf" python3 "$BIN/fleet-orphan-reports.py" cell)
  got=$(cd "$BIN" && CELL="$cell" python3 -c 'import os, fleet_hub_common as h
p = ["@5", "", "1", "/w/x", "idle", "claude", "a1", "", "acme/app", "scratch-7", "", "", "", "busy=", "born=", "cfg=", "title=", "reap=", "detail=", "role=", "epic=", "epicstale=", "backfill=", "ctxleft=", "ctxband=", "ctxts=", "model=", "effort=", "agentstatus=", "test="]
o = h.inventory_row(p + ["orphanrep=" + os.environ["CELL"]])[1].get("orphan_reports") or [{}]
print(o[0].get("child"), o[0].get("state"), o[0].get("pr"), o[0].get("summary"))' 2>&1)
  SECS=$(since "$t0")
  [ -n "$id" ] && [ "$got" = "issue-41 MERGED 77 landed the fix" ] \
    || { WHY="the unread report does not reach the inventory: id=[$id] worker=[$got]"; return 1; }
  FLEET_CONF_DIR="$d/conf" python3 "$BIN/fleet-orphan-reports.py" read "$id"
  [ -z "$(FLEET_CONF_DIR="$d/conf" python3 "$BIN/fleet-orphan-reports.py" cell)" ] \
    || { WHY="a read report is still carried"; return 1; }
  WHAT="交给你的子会话结果：侧栏和入口都读得到（盘点第 31 列），读过就不再出现"
}

# far-agent-switch (issue #4184): 换 Codex / 换 Claude on a session that lives on
# ANOTHER machine. The 看台's menu used to drop it (far None), and the hub had no
# tool for it. Now the far row's menu offers it, and the node's adapter
# (fleet-control-read.sh transfer — what the hub's worker_transfer runs there)
# refuses a recycled window, the agent it already runs and a mid-turn source
# with one line, dispatching nothing; a settled one is dispatched exactly once,
# detached on the fleet's own server, to the same fleet-transfer.sh.
drill_codex_home_trust() {
  CAP=15
  local started; started=$(now)
  python3 "$BIN/fleet-codex-home-trust-selftest.py" >"$WORK/codex-home-trust.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/codex-home-trust.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='HOME trust fill-only, durable through symlink; explicit choices and opt-out preserved'
}

drill_transfer_norepo() {
  CAP=60
  local started; started=$(now)
  suite_holds fleet-transfer-norepo-selftest.sh 'fleet-transfer-selftest.sh" --norepo' \
    test_two_cron_jobs_deliver_independently_once_and_preserve_expiry || return 1
  SECS=$(since "$started"); WHAT='managed HOME provenance; panel and busy refusals leave source alive (run for real by fleet-transfer-norepo-selftest.sh, held here by name)'
}

drill_transfer_preparation_retry() {
  CAP=20
  local started; started=$(now)
  python3 "$BIN/fleet-transfer-preparation-selftest.py" >"$WORK/transfer-preparation-retry.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/transfer-preparation-retry.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='explicit retry creates a generation; uncertain sends deduplicate and stale arms/results refuse'
}

drill_transfer_durable_owner() {
  CAP=60
  local started; started=$(now)
  bash "$BIN/fleet-transfer-selftest.sh" --norepo-durable >"$WORK/transfer-durable.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/transfer-durable.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='mixed patrol + durable one-shot: B refuses before preparation; the source receipt (road 1) or the isolated takeover (road 2) moves it; the target loop delivers it once, on time; failures keep one owner'
}

# A durable handover killed mid-way, or meeting a Claude it cannot account for
# (issue #4280): a crash at any step must leave exactly one owner and every
# unrelated native record; an unknown / HOME-bound Claude refuses before a write.
drill_transfer_durable_crash() {
  CAP=30
  local started; started=$(now)
  python3 "$BIN/fleet-transfer-durable-selftest.py" >"$WORK/transfer-durable-crash.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/transfer-durable-crash.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='SIGKILL at write-ahead / table write / withdrawn: the sweep settles one owner, unrelated records intact; unknown Claude refused by pid'
}

# A durable task another (gone or live) session left in HOME (issue #4758):
# it must not hold this session's switch, nor stage with it; it is named and
# left byte for byte. Only this session's own (or an unproven) task refuses.
drill_transfer_durable_orphan() {
  CAP=20
  local started; started=$(now)
  python3 "$BIN/fleet-transfer-durable-selftest.py" Orphan >"$WORK/transfer-durable-orphan.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/transfer-durable-orphan.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='orphan / live-foreign durable task: switch allowed, named on stderr, table untouched; own or unproven task refuses naming id, fire time and the way out'
}

drill_transfer_proxy_home() {
  CAP=45
  local started; started=$(now)
  python3 "$BIN/fleet-transfer-auth-selftest.py" ProxyHomeAuth >"$WORK/transfer-proxy-home.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/transfer-proxy-home.out" | tr '\n' ' ')"; return 1; }
  bash "$BIN/fleet-transfer-proxy-home-selftest.sh" >>"$WORK/transfer-proxy-home.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/transfer-proxy-home.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='owned proxy mapping; forged/missing/unauthorized targets refuse; clean Stop then native successor bound — from a Codex and a Claude source'
}

drill_transfer_pooled_codex_looping() {
  CAP=10
  local started; started=$(now)
  python3 "$BIN/fleet-transfer-source-selftest.py" Settled >"$WORK/transfer-pooled.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/transfer-pooled.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='a pooled (provider fleet) or OpenAI Codex thread between rounds is settled; any other provider still refuses'
}

drill_transfer_proxy_auth() {
  CAP=10
  local started; started=$(now)
  python3 "$BIN/fleet-transfer-auth-selftest.py" >"$WORK/transfer-auth.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/transfer-auth.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='proxy lease checked; no local credentials; refusal leaves source untouched'
}

drill_trial_provider_mismatch() {
  CAP=120
  local started; started=$(now)
  go_half '^TestTrial(Open|Provider)' github.com/verkyyi/claude-fleet/tokenledger/hub/api
  case $? in
    1) return 1 ;;
    2|3) : ;; # the Go CI gate exercises the real route and both pools
  esac
  SECS=$(since "$started"); WHAT='trial open pins the admitted provider; explicit Claude cannot borrow Codex headroom; refused messages spend no trial line'
}

drill_web_quota_dialog() {
  CAP=30
  local started; started=$(now)
  python3 "$BIN/fleet-transfer-source-selftest.py" QuotaDialog >"$WORK/quota-dialog.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/quota-dialog.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='quota dialog dismissed once; native boundary re-proved; drafts, tools, schedules, approvals and changed source held'
}

drill_quota_boundary_recheck() {
  CAP=30
  local started; started=$(now)
  python3 "$BIN/fleet-session-fallback-selftest.py" Continuation.test_unattempted_refusal_rechecks_when_native_cancel_or_delivery_settles >"$WORK/quota-boundary.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/quota-boundary.out" | tr '\n' ' ')"; return 1; }
  python3 "$BIN/fleet-transfer-source-selftest.py" QuotaDialog.test_native_prompt_proof_uses_real_inbox_dispatch_without_probe_seam >>"$WORK/quota-boundary.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/quota-boundary.out" | tr '\n' ' ')"; return 1; }
  python3 "$BIN/fleet-session-fallback-selftest.py" Continuation.test_preflight_refusal_recovers_once_with_exact_receipt >>"$WORK/quota-boundary.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/quota-boundary.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='unattempted boundary/delivery refusals recheck once after settlement; controller attempts never repeat'
}

drill_quota_loop_replacement() {
  CAP=30
  local started; started=$(now)
  python3 "$BIN/fleet-transfer-source-selftest.py" ExternalQuotaLoop >"$WORK/quota-loop.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/quota-loop.out" | tr '\n' ' ')"; return 1; }
  python3 "$BIN/fleet-loop-selftest.py" IdleDispatchTests.test_external_quota_transfer_waits_for_confirmed_controller_start >>"$WORK/quota-loop.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/quota-loop.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='external authorization is not a native export; exact source/exit match; unknown target never activates timer'
}

drill_transfer_disposition() {
  CAP=30
  local started; started=$(now)
  python3 "$BIN/fleet-transfer-disposition-selftest.py" >"$WORK/transfer-disposition.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/transfer-disposition.out" | tr '\n' ' ')"; return 1; }
  SECS=$(since "$started"); WHAT='explicit waiting/completed pickup preserves intent and draft without GO or loop activation'
}

drill_web_quota_continuation() {
  CAP=120
  local started; started=$(now)
  python3 "$BIN/fleet-session-fallback-selftest.py" >"$WORK/web-quota.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/web-quota.out" | tr '\n' ' ')"; return 1; }
  python3 "$BIN/fleet-transfer-source-selftest.py" >"$WORK/web-quota-source.out" 2>&1 \
    || { WHY="$(tail -8 "$WORK/web-quota-source.out" | tr '\n' ' ')"; return 1; }
  go_half '^Test(TrialCodex(DefaultAdmission|ContinuationBudgetIsolation)|CredProxyClaudeCapacityContinuation)$' github.com/verkyyi/claude-fleet/tokenledger/hub/api
  case $? in
    1) return 1 ;;
    2|3) : ;; # the Go CI gate runs the admission and budget assertions
  esac
  SECS=$(since "$started"); WHAT='hard quota only; one formal transfer; unsettled delivery and approvals held; no replay or retry loop; Codex trials share the budget and gates'
}

drill_far_agent_switch() {
  CAP=15; BREAK_SOCK="$WORK/sock-fas"; local d="$WORK/fas" t0 out rc win ids i
  mkdir -p "$d/conf/fleets/fa" "$d/sb" "$d/home"
  : > "$d/conf/fleets/fa/conf"
  fx_repo "$d/conf" "fa" acme/app FLEET_MAIN="$d/main"
  for f in "$BIN"/*; do ln -s "$f" "$d/sb/${f##*/}"; done
  rm -f "$d/sb/fleet-transfer.sh"
  cat > "$d/sb/fleet-transfer.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$d/calls"
echo 'dry-run: save a provenance package, /exit the source, then launch codex in %1 (state=working).'
[ ! -f "$d/busy" ] || echo 'cutover would refuse until the source reaches done.'
exit 0
EOF
  chmod +x "$d/sb/fleet-transfer.sh"
  nt -f /dev/null new-session -d -s fa -n w1 -x 100 -y 30 'exec sleep 600' || { WHY="cannot start the isolated tmux server"; return 1; }
  win=$(nt display-message -p -t fa:w1 '#{window_id}')
  nt set-option -w -t "$win" @fleet_id F1 \; set-option -w -t "$win" @cc_agent claude
  run() { env -u TMUX -u TMUX_PANE PATH="$WORK/tbin:$PATH" HOME="$d/home" FLEET_CONF_DIR="$d/conf" \
            FLEET_SKIP_GLOBAL_CONF=1 BREAK_SOCK="$BREAK_SOCK" bash "$d/sb/fleet-control-read.sh" transfer fa "$win" "$@"; }
  # the 看台's menu on a far row: 换成 Codex is there (it used to be dropped)
  ids=$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fv", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
r = {"far": True, "state": "working", "target": "u/F1", "agent": "claude"}
print(" ".join(a["id"] for a, _ in fv.menu_of(r)))' "$BIN" 2>&1)
  case " $ids " in *" agent "*) ;; *) WHY="a far row's menu has no 换 Codex: [$ids]"; return 1 ;; esac
  t0=$(now)
  touch "$d/busy"
  out=$(run F1 codex 2>&1); rc=$?
  [ "$rc" = 1 ] && case "$out" in *mid-turn*) true ;; *) false ;; esac \
    || { WHY="a mid-turn source answered rc=$rc [$out], want 1 and «mid-turn»"; return 1; }
  rm -f "$d/busy"
  out=$(run F2 codex 2>&1); rc=$?
  [ "$rc" = 5 ] || { WHY="a recycled window answered rc=$rc [$out], want 5"; return 1; }
  out=$(run F1 claude 2>&1); rc=$?
  [ "$rc" = 1 ] && case "$out" in *"already runs claude"*) true ;; *) false ;; esac \
    || { WHY="the agent it already runs answered rc=$rc [$out]"; return 1; }
  [ "$(grep -vc -- --dry-run "$d/calls")" = 0 ] || { WHY="a refusal dispatched a transfer: $(cat "$d/calls")"; return 1; }
  out=$(run F1 codex 2>&1); rc=$?
  [ "$rc" = 0 ] && [ "$out" = 'dispatched → codex' ] || { WHY="a settled source answered rc=$rc [$out]"; return 1; }
  for i in $(seq 1 50); do [ "$(grep -vc -- --dry-run "$d/calls")" = 1 ] && break; sleep 0.1; done
  SECS=$(since "$t0")
  [ "$(grep -vc -- --dry-run "$d/calls")" = 1 ] && grep -qx -- "--session fa --window $win --to codex --from-panel" "$d/calls" \
    || { WHY="the transfer was not dispatched exactly once: $(cat "$d/calls")"; return 1; }
  WHAT="别的机器上的会话也能换 Codex：菜单有这一项；那台机器上回合中 / 窗口换人 / 已是该 agent 一行拒绝、什么都不派，空闲的派一次 fleet-transfer.sh"
}

drill_hubsess_unwatched_poll() {
  CAP=25; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/hub-sessions-watch-selftest.py" --quick 2>&1) \
    || { WHY="unwatched session list: $out"; return 1; }
  SECS=$(since "$t0")
  WHAT='常在线客户端不算打开列表；共享事件广播两秒内更新，真实请求恢复两秒节拍，输入相同不重算'
}

drill_spinner_unwatched_poll() {
  CAP=15; local t0 out
  t0=$(now)
  out=$(bash "$BIN/spinner-wait-selftest.sh" --quick 2>&1) \
    || { WHY="unwatched spinner: $out"; return 1; }
  SECS=$(since "$t0")
  WHAT='无人观看不轮询；状态事件两秒内画一次，真实客户端连接后一秒内恢复动画'
}

drill_spinner_maintenance_starved() {
  CAP=60; local t0
  t0=$(now)
  suite_holds spinner-maintenance-selftest.sh 'spinner-wait-selftest.py" --maintenance' || return 1
  SECS=$(since "$t0")
  WHAT='无人观看且无事件，needs 双次核对、stuck/degenerate、心跳和 daemon-watch 均按原时限运行（由 spinner-maintenance-selftest.sh 真跑，这里按名守住）'
}

drill_spinner_process_budget() {
  CAP=55; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/spinner-budget-selftest.py" --fixture idle 2>&1) \
    || { WHY="complete default spinner budget: $out"; return 1; }
  SECS=$(since "$t0")
  printf '%s\n' "$out"
  WHAT='无工作场景真实观察 44 秒；启动与按原周期维护成本分列，协议读取按 44 秒换算，含准备清理 <60 秒'
}

drill_spinner_process_budget_maintenance() {
  CAP=55; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/spinner-budget-selftest.py" --fixture maintenance 2>&1) \
    || { WHY="complete pending-maintenance spinner budget: $out"; return 1; }
  SECS=$(since "$t0")
  printf '%s\n' "$out"
  WHAT='有待办场景真实观察 44 秒；20/40 秒两次 fresh 核对与身份保护保留，启动/维护归一化且协议读取 ≤44，含准备清理 <60 秒'
}

drill_spinner_protocol_budget() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/spinner-control-selftest.py" 2>&1) \
    || { WHY="resident protocol invalidation: $out"; return 1; }
  SECS=$(since "$t0")
  WHAT='无人客户端行复用；多 socket、双消费者与断连重连保持；协议总账由两个 process-budget 44 秒独立场景共测'
}

drill_codex_resume_history() {
  CAP=120; local t0 out
  t0=$(now)
  out=$(bash "$BIN/dash-issue-session-prompt-selftest.sh" 2>&1) \
    || { WHY="Codex issue 原对话恢复: $out"; return 1; }
  out=$(bash "$BIN/dash-raw-session-selftest.sh" 2>&1) \
    || { WHY="Codex 原对话恢复: $out"; return 1; }
  SECS=$(since "$t0"); WHAT='原生历史恢复保留同一对话；不同 UUID 的历史拒绝复用'
}

drill_codex_hook_retired_root() {
  CAP=15; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-codex-startup-selftest.py" PolicyTests.test_live_hook_paths_survive_retired_release_removal PolicyTests.test_checkout_hooks_do_not_use_an_unrelated_live_install 2>&1) \
    || { WHY="Codex Hook 版本目录回收: $out"; return 1; }
  SECS=$(since "$t0"); WHAT='安装 Hook 走稳定入口；独立 checkout 不借用其他安装'
}

drill_codex_interrupt_idle() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-codex-busy-selftest.py" "$BIN" NativeBusy.test_settled_interrupted_turn_can_be_idle_without_success NativeBusy.test_interrupted_turn_keeps_work_and_unknown_proofs 2>&1) \
    || { WHY="Codex 中断后的空闲证明: $out"; return 1; }
  out=$(python3 "$BIN/fleet-codex-attention-selftest.py" 2>&1) \
    || { WHY="Codex 原生空闲投影: $out"; return 1; }
  SECS=$(since "$t0"); WHAT='原生中断后清除运行提示；停放仍核对工具、goal、身份和原生子线程，不把中断当成功'
}

drill_codex_mcp_busy() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-codex-busy-selftest.py" "$BIN" 2>&1) \
    || { WHY="Codex MCP/helper 回收分类失守: $out"; return 1; }
  SECS=$(since "$t0"); WHAT="精确配置的常驻服务可闲置，真实任务及未知身份保留"
}

drill_c9_live_unproven() {
  CAP=15; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/nogh-live-selftest.py" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='真实 C9 的缺观察、旧代次、共享目标与 IPv6 失败均拒绝；fixture 证据不升格 live'
}

drill_loop_due_display_gate() {
  CAP=120; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-loop-selftest.py" IdleDispatchTests 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='Stop→looping 只有自己的 loop 时到期照投且仅一次；真 bg/tool/提问/草稿/近期输入/转交带原因延后；切换前启动证明路留下的待结投递丢掉，这一轮照样到期、走窗格自己的路只投一次'
}

drill_pending_observation_stale() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-pending-tool-selftest.py" Observation 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='同次观测共享，工具变化重新读取；换代、过期、缺失身份及读取失败均 unknown'
}

drill_native_resume_default_permissions() {
  CAP=30; local out home t0
  t0=$(now)
  home=$(mktemp -d "${TMPDIR:-/tmp}/native-resume-home.XXXXXX") || return 1
  if out=$(env -i HOME="$home" PATH=/usr/bin:/bin bash "$BIN/fleet-codex-selftest.sh" --resume-defaults 2>&1); then
    rm -rf "$home"
  else
    rm -rf "$home"; WHY="$out"; return 1
  fi
  SECS=$(since "$t0")
  WHAT='真实composer的resume不注入权限默认覆盖，显式/锁定策略与hooks保留'
}

# ---- authority-retired-endpoint-blocks (#4831): a retired endpoint's open
# local starts and fleet rows held a repo off the hub forever — only its own
# (now dead) token could settle them. Retire now ends them retired, releases
# its leases and lists its fleet rows apart; another repo stays byte for byte.
drill_authority_retired_endpoint_blocks() {
  CAP=120;  # a cold go test build is ~40 s on a CI runner
  local t0 f="$ROOT/tokenledger/hub/store/retire.go" a="$ROOT/tokenledger/hub/api/fleet_repo_authority.go"
  t0=$(now)
  grep -q 's.settleRetiredTx(tx, endpointID' "$f" \
    || { WHY="RetireEndpointAs no longer settles the endpoint's local starts and leases"; return 1; }
  grep -q '"retired_hosts": retired' "$a" \
    || { WHY="the authority manifest no longer lists a retired endpoint's fleet rows apart"; return 1; }
  _drill_go_tests 'TestRetireSettlesLocalStarts' "$ROOT/tokenledger/hub/store/retire_settle_test.go" x ./hub/store || return 1
  _drill_go_tests 'TestRepoAuthorityRetiredHostBlocksNothing' "$ROOT/tokenledger/hub/api/fleet_repo_authority_test.go" \
    '退役端点：它没收口的 local start 结成 retired、legacy lease 放掉、fleet 行列进 retired_hosts 不再挡；没退役的离线端点照旧挡，另一个仓库一字不变（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- authority-legacy-task-unclosable (#4867): a legacy T record attached to
# a worker had no state that ends it, so it blocked the repo's authority switch
# forever. settle ends it closed only when its issue is closed AND its worker
# holds nothing; an open issue or a live worker still blocks.
drill_authority_legacy_task_unclosable() {
  CAP=120;  # a cold go test build is ~40 s on a CI runner
  local t0 f="$ROOT/tokenledger/hub/store/fleet_repo_authority.go" b="$BIN/fleet-task-record.sh"
  t0=$(now)
  grep -q "owner, TaskClosed, TaskRefused" "$f" \
    || { WHY="the legacy-owner blocker query no longer honours TaskClosed"; return 1; }
  grep -q 'call POST /v1/node/tasks/settle' "$b" \
    || { WHY="fleet-task-record.sh has no settle command"; return 1; }
  _drill_go_tests 'TestSettleLegacyTaskWorkerLive' "$ROOT/tokenledger/hub/store/fleet_task_settle_test.go" x ./hub/store || return 1
  _drill_go_tests 'TestNodeTaskSettleLegacy' "$ROOT/tokenledger/hub/api/fleet_task_settle_test.go" \
    '旧式 T 记录：issue 已关且 worker 不占 lease / local start / inventory 才结成 closed 不再挡；issue 还开着或 worker 还活着照样挡；默认 dry，迟到的写不重开（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- task-state-behind-result (EPIC T644 C6): a record's end lived only on
# its ID (fleet_id_results) and was projected onto the record at read time, so
# every reader of the row — a list, a count, the 「没结束」 set — saw ended tasks
# as running (71 on 2026-10-20). Now the result writes the record in the same
# transaction, and the reconcile catches the old ones once.
drill_task_state_behind_result() {
  CAP=120;  # a cold go test build is ~40 s on a CI runner
  local t0 f="$ROOT/tokenledger/hub/store/fleet_ids.go" a="$ROOT/tokenledger/hub/api/fleet_tasks.go" b="$BIN/fleet-task-record.sh"
  t0=$(now)
  grep -q 'writeTaskResult(tx, r.Owner, r.ID' "$f" \
    || { WHY="an ID's result no longer writes its task record (fleet_ids.go applyIDEvent)"; return 1; }
  grep -q 't.Outcome, t.State = o, o' "$a" \
    && { WHY="taskViews projects the ID's result again: the record's columns are the one source"; return 1; }
  grep -q 'call POST /v1/node/tasks/reconcile' "$b" \
    || { WHY="fleet-task-record.sh has no reconcile command"; return 1; }
  _drill_go_tests 'TestTaskEndsWhenItsIDResultLands TestReconcileTaskStates' "$ROOT/tokenledger/hub/store/fleet_task_state_test.go" \
    '任务记录与它编号的结果：结果落地同一事务写实，单条 / 列表 / children 三处一致；回填幂等、dry 与 apply 同数，切换前没人占的旧记录收为已取消、可退回（go test）' ./hub/store || return 1
  SECS=$(since "$t0")
}

# ---- authority-open-issue-legacy-task (T479, #4830's cutover): the drain
# stops workers whose issues stay open, so #4867's settle (issue closed) never
# ended their legacy records and freeze never passed. settle --drained ends one
# on the worker half alone; a live worker is kept.
drill_authority_open_issue_legacy_task() {
  CAP=120;  # a cold go test build is ~40 s on a CI runner
  local t0 b="$BIN/fleet-task-record.sh"
  t0=$(now)
  grep -q -- '--drained) drained=true' "$b" \
    || { WHY="fleet-task-record.sh settle has no --drained"; return 1; }
  _drill_go_tests 'TestNodeTaskSettleDrained' "$ROOT/tokenledger/hub/api/fleet_task_settle_test.go" \
    '旧式 T 记录 drain：issue 还开着、worker 已停（无 lease / local start / inventory）的结成 closed，不问 GitHub、issue 不动；worker 还活着的照样挡（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- authority-orphan-worker-start (#4864): a worker_start that can never
# settle — refused by the spawner but filed unknown, sent to a retired
# endpoint's fleet, or never accepted by its node — held a repo off the hub as
# an `unsettled start` forever. Each now ends failed; a crash stays unknown.
drill_authority_orphan_worker_start() {
  CAP=180;  # two cold go test builds
  local t0 out
  t0=$(now)
  grep -q 'not spawner_refused(err)' "$BIN/fleet_control.py" \
    || { WHY="fleet_control.py files a spawner's own refusal as attempted (unknown) again"; return 1; }
  out=$(python3 "$BIN/fleet-hub-selftest.py" -k test_start_scratch_opens_a_raw_session 2>&1) || { WHY="$out"; return 1; }
  _drill_go_tests 'TestRetireFailsOrphanWorkerStarts' "$ROOT/tokenledger/hub/store/retire_settle_test.go" x ./hub/store || return 1
  _drill_go_tests 'TestFleetWriteRefusedStartSettles' "$ROOT/tokenledger/hub/api/fleet_write_test.go" \
    '孤儿 worker_start：spawner 的 refuse 记 failed（崩溃仍 unknown），Hub 送达/对账/读日志同规则结清；退役端点的 start 结成 failed；节点说没收过的过宽限结成 failed（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- orphan-unknown-outcome-start (#4932): an online node answering
# UNKNOWN_OUTCOME for a worker_start whose worker never appeared kept it an
# `unsettled start` forever. The hub now settles it failed on its own books —
# past the grace, a later inventory without it, no lease, no open local start.
drill_orphan_unknown_outcome_start() {
  CAP=180;  # two cold go test builds
  local t0
  t0=$(now)
  grep -q 'settleNeverAppeared(o, now)' "$ROOT/tokenledger/hub/api/fleet.go" \
    || { WHY="reconcileOperation no longer settles a never-appeared start"; return 1; }
  _drill_go_tests 'TestSettleNeverAppearedStart' "$ROOT/tokenledger/hub/store/fleet_start_settle_test.go" x ./hub/store || return 1
  _drill_go_tests 'TestFleetWriteNeverAppearedStartSettles' "$ROOT/tokenledger/hub/api/fleet_write_test.go" \
    '在线节点的 UNKNOWN_OUTCOME 启动：过宽限、清单读于宽限后且没有它的 worker / lease / 未收口 local start 才结成 failed（WORKER_NEVER_APPEARED）；清单里有、宽限内、说不出是哪个 worker 照旧 unknown（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- orphan-start-unnamed (#4945): a no-repo worker_start whose node named no
# window stays unknown under #4932 — the hub cannot check it. The node now
# names the window it looked for (fid:), and an admin vouches for the rest:
# operation_settle ends it failed (SETTLED_BY_OPERATOR), audited who and why.
drill_orphan_start_unnamed() {
  CAP=180;  # two cold go test builds
  local t0
  t0=$(now)
  grep -q '" (fid:%s)" % fid' "$ROOT/bin/fleet_control.py" \
    || { WHY="the node's UNKNOWN_OUTCOME no longer names the window it looked for"; return 1; }
  _drill_go_tests 'TestSettleStartByOperator' "$ROOT/tokenledger/hub/store/fleet_start_settle_test.go" x ./hub/store || return 1
  _drill_go_tests 'TestFleetOperationSettleByAdmin' "$ROOT/tokenledger/hub/api/fleet_write_test.go" \
    '核实不了的不绑仓库启动：自动路照旧 unknown；管理员 operation_settle 只在 24 小时后、只对说不出 worker 的 worker_start 结成 failed（SETTLED_BY_OPERATOR），审计写谁、为什么；核实得了的 409（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- orphan-start-node-abandon (#4978): a stale worker_start the hub never
# heard the end of (its fleet row replaced, a reconcile that never reached the
# node) blocked its owner's cutover with no road of their own. The node now
# says it never ran it — no row in its control journal, or failed, and no
# window or process names it — and the hub abandons it on its own books, audited.
drill_orphan_start_node_abandon() {
  CAP=180;  # two cold go test builds
  local t0
  t0=$(now)
  grep -q 'operations=settle_operations(apply)' "$ROOT/bin/fleet_repo_authority.py" \
    || { WHY="the node's --settle no longer settles its stale worker_starts"; return 1; }
  ( cd "$ROOT/bin" && python3 -m unittest fleet_repo_authority_settle_test.SettleOperationsTests >/dev/null 2>&1 ) \
    || { WHY="SettleOperationsTests red: a start this login may hold was abandoned, or one it never ran was kept"; return 1; }
  _drill_go_tests 'TestAbandonStaleStart' "$ROOT/tokenledger/hub/store/fleet_start_settle_test.go" x ./hub/store || return 1
  _drill_go_tests 'TestAuthorityOperationNodeAbandonsStaleStart' "$ROOT/tokenledger/hub/api/fleet_repo_authority_test.go" \
    '节点自己结失效的 worker_start：只列给本 login 的节点，24 小时内、别的节点、管理员门都拒；结成 failed（START_ABANDONED），写 operation_abandon 审计，不再挡切换（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- authority-superseded-fleet-row (#4877): fleet rows are never deleted,
# so an old row of the same machine + login that a newer row replaced stayed
# present=0 and asked for a capable observation that never comes. The manifest
# now lists it in superseded_hosts; a row with no successor still blocks.
drill_authority_superseded_fleet_row() {
  CAP=120;  # a cold go test build is ~40 s on a CI runner
  local t0 a="$ROOT/tokenledger/hub/api/fleet_repo_authority.go"
  t0=$(now)
  grep -q 'supersededBy(f, store.NormRepo(f.Repo), fs, eps)' "$a" \
    || { WHY="repoAuthorityInventory no longer skips a superseded fleet row"; return 1; }
  grep -q '"superseded_hosts": superseded' "$a" \
    || { WHY="the authority manifest no longer lists superseded fleet rows apart"; return 1; }
  _drill_go_tests 'TestSupersededByRules TestRepoAuthoritySupersededFleetRowBlocksNothing' "$ROOT/tokenledger/hub/api/fleet_repo_authority_test.go" \
    '被取代的旧 fleet 行：同一台机器（fleet machine / endpoint / 硬件 machine_id + os_user）之后报过 present 行，它列进 superseded_hosts 不再挡；没有后继的 absent 行、present 而不 capable 的行照旧挡；主机是人的，另一个仓库的 manifest 列的是同一批（go test）' || return 1
  SECS=$(since "$t0")
}

# ---- authority-other-owner-blocks (#4896): task authority was one row per
# repo with one owner, so a person still on legacy in a shared repo held
# everyone else's cutover (their host was "foreign", their starts blocked), and
# one person's freeze froze the others. Now it is a person's: each gate reads
# the starting person's own row, each blocker counts only their own work.
drill_authority_other_owner_blocks() {
  CAP=180;  # two cold go test builds
  local t0 f="$ROOT/tokenledger/hub/store/fleet_repo_authority.go" a="$ROOT/tokenledger/hub/api/fleet_repo_authority.go"
  t0=$(now)
  grep -q 'return "task-authority:owner:" + owner' "$f" \
    || { WHY="task authority is no longer keyed by its owner"; return 1; }
  grep -q 'if ep == nil || s.nodeTaskOwner(ep) != a.Owner {' "$a" \
    || { WHY="the authority inventory counts another person's host again"; return 1; }
  _drill_go_tests 'TestOwnerAuthorityDryRunAndPerOwnerCutover' "$ROOT/tokenledger/hub/store/fleet_repo_authority_test.go" x ./hub/store || return 1
  _drill_go_tests 'TestOwnerAuthorityTwoPeopleOneRepo' "$ROOT/tokenledger/hub/api/fleet_repo_authority_test.go" \
    '同一个仓库两个人：A 的 legacy 会话、local start 不进 B 的 blocker；B 冻结 / 切到 hub 后 A 照常 legacy 开会话，A 的 gate 不动、A 的机器收不到推送（go test）' || return 1
  # The node half (#4901): the selection is the login's, never a repo overlay's.
  grep -q 'FLEET_VIEW_LANDED_SECS FLEET_TASK_AUTHORITY"' "$BIN/fleet-lib.sh" \
    || { WHY="FLEET_TASK_AUTHORITY is a per-repo key again"; return 1; }
  _drill_authority_logins || return 1
  SECS=$(since "$t0")
}

# The node half of both #4896 rows (#4901): one machine, two logins, one repo —
# alice's cutover writes her fleet.conf [node] only, bob opens / restarts /
# settles on legacy throughout, each settle touches only its own node's starts.
_drill_authority_logins() {
  local out
  out=$(bash "$BIN/fleet-task-authority-login-selftest.sh" 2>&1) || { WHY="$out"; return 1; }
  WHAT="${WHAT:+${WHAT}；}同一台机器两个 login、同一个仓库：A 切到 hub 只写 A 的 fleet.conf [node]，B 照常 legacy 开会话、重启、settle，各自只结清本节点的 start（fleet-task-authority-login-selftest）"
}

# ---- authority-owner-cutover (#4896): one person's whole road, alone — dry
# run writes nothing, freeze stops only their starts, their own legacy session
# drains by a native stop receipt, apply admits only accepted work, rollback
# waits on their accepted work, and every step is CAS + idempotent + audited.
drill_authority_owner_cutover() {
  CAP=180;  # two cold go test builds
  local t0 a="$ROOT/tokenledger/hub/api/fleet_repo_authority.go"
  t0=$(now)
  grep -q '"task_authority_"+action, "owner:"+owner' "$a" \
    || { WHY="a task authority change is no longer audited"; return 1; }
  _drill_go_tests 'TestRepoAuthorityStopBoundToCurrentNative' "$ROOT/tokenledger/hub/store/fleet_repo_authority_test.go" x ./hub/store || return 1
  _drill_go_tests 'TestOwnerAuthorityTwoPeopleOneRepo' "$ROOT/tokenledger/hub/api/fleet_repo_authority_test.go" \
    '一个人的全程：dry-run 零写入，freeze 只挡本人，本人 legacy 会话凭原生停止回执 stop_ack 后 apply，再 freeze → rollback；每步按 revision CAS、幂等、写审计（go test）' || return 1
  _drill_authority_logins || return 1
  SECS=$(since "$t0")
}

drill_repo_authority_case() {
  CAP=90; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet_repo_authority_case_test.py" \
    CaseAuthorityTests.test_gate_and_manifest_use_hub_identity_and_existing_overlay \
    CaseAuthorityTests.test_panel_new_and_issue_start_keep_worktree_and_registration \
    CaseAuthorityTests.test_busy_cpu_still_refuses_panel_and_issue_without_window \
    CaseAuthorityTests.test_panel_new_session_box_uses_real_raw_entry \
    CaseAuthorityTests.test_refusals_reach_panel_and_issue_without_secret_or_false_freeze 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='大小写注册名通过面板/issue/authority；原 overlay/worktree 保留，真实拒绝原因可见'
}

drill_rm_empty_var_prompt() {
  CAP=15; local t0 g out rc
  t0=$(now); g="$BIN/../hooks/bash-guard.py"
  j() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }
  out=$(j 'rm -f $P/*' | python3 "$g" 2>&1 >/dev/null); rc=$?
  [ "$rc" = 2 ] || { WHY="rm -f \$P/* not denied (rc=$rc) — Claude Code would stop for a person"; return 1; }
  case "$out" in *'"${P:?}"/*'*) ;; *) WHY="deny carries no rewrite hint: $out"; return 1 ;; esac
  j 'rm -f "${P:?}"/*' | python3 "$g" >/dev/null 2>&1 \
    || { WHY='rm -f "${P:?}"/* (the rewrite) was refused'; return 1; }
  j 'git rm $P/x' | python3 "$g" >/dev/null 2>&1 || { WHY='git rm $P/x was refused'; return 1; }
  SECS=$(since "$t0")
  WHAT='rm -f $P/* 先被 bash-guard 拒并给出改法；"${P:?}"/* 与 git rm 放行'
}

# stuck-worker-unseen (#4702): a worker the stream resume gives up on — or whose
# launch is refused — tells its parent once, instead of looking finished.
drill_stuck_worker_unseen() {
  CAP=15; local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-stream-resume-selftest.sh" 2>&1) || { WHY="$(printf '%s' "$out" | grep FAIL | head -3)"; return 1; }
  printf '%s' "$out" | grep -q '^PASS  H the budget spent stays local, no Parent report' \
    || { WHY="the give-up report leg did not run: $(printf '%s' "$out" | grep ' H ' | tr '\n' ' ')"; return 1; }
  if grep -q 'fleet-report-parent.sh" --state failed --win "$TMUX_PANE"' "$BIN/fleet-session-wrap.sh"; then
    WHY='wrapper revived Parent reporting'; return 1
  fi
  SECS=$(since "$t0")
  WHAT='原生错误续接仍有次数上限；不可重试或预算用尽只留本地原因，不再向Parent回报'

}

# ---- finished workers nothing closed (issue #4822, a managed Mac 2026-10-19) -------------
# The idle pass runs once per hosted repo; every OTHER repo's pass saw a `done:10m`
# window as not its own and cleared the countdown its own pass had just set — on
# every tick, so it never came due (@3762, six hours).
drill_reap_other_repo_clears() {
  CAP=10; local t0 out
  t0=$(now)
  out=$(python3 - "$BIN" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("idle", sys.argv[1] + "/fleet-cleanup-idle.py")
m = importlib.util.module_from_spec(spec); sys.path.insert(0, sys.argv[1]); spec.loader.exec_module(m)
opts = {"@repo": "acme/two", "@issue": "7", "@reap_policy": "done:10m", "@claude_state": "exited",
        "@claude_state_ts": "100", "@worktree": "/nonexistent/wt", "@reap_key": "idle:abc", "window_name": "w"}
writes = []
def tm(*a):
    if a[0] == "display-message":
        f = a[-1]
        return "\x1f".join(opts.get(x[2:-1], "") for x in f.split("\x1f")) if "\x1f" in f else opts.get(f[2:-1], "")
    writes.append(a); return ""
c = m.Cleaner.__new__(m.Cleaner)
c.args = types.SimpleNamespace(session="s", socket_name="s", main="/nonexistent", repo="acme/one", base="master",
                               limit=4, forge="github", window_repo=True, dry_run=False, policy_only=False)
c.tm, c.now, c.idle = tm, 1000, 1800
c.candidate("@5")
print(sum(1 for w in writes if "-wu" in w))
PY
)
  SECS=$(since "$t0")
  [ "$out" = 0 ] || { WHY="another repo's pass cleared the window's countdown ($out unsets)"; return 1; }
  WHAT="一个仓库的闲置那一遍只管自己仓库的窗口：别的仓库窗口的倒计时原样留着，到点就收"
}

# A `looping` stamp its Stop hook left for a child that has since ended (or for one
# still open after its own PR merged), and `needs` carried onto a pane that came
# back a bare shell: nothing ever read them as finished (@3718 · @4383 · @1058).
drill_reap_stale_stamp() {
  CAP=15; local t0
  t0=$(now)
  python3 "$BIN/fleet-reap-live-selftest.py" "$BIN" LiveTests.test_stale_stamp_with_wrapper_gone \
    LiveTests.test_merged_looping_worker_is_reapable LiveTests.test_reap_state_cli >"$WORK/stale-stamp.out" 2>&1 \
    || { WHY="reap-live still holds a stale stamp: $(grep -E '^(FAIL|AssertionError)' "$WORK/stale-stamp.out" | head -2 | tr '\n' ' ')"; return 1; }
  python3 "$BIN/fleet-cleanup-idle-selftest.py" "$BIN" StuckReaps >"$WORK/stale-stamp2.out" 2>&1 \
    || { WHY="the idle pass still reads only the stamp: $(grep -E '^(FAIL|AssertionError)' "$WORK/stale-stamp2.out" | head -2 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="agent 自己说的 done 压过 looping 印记；包装没了、没 agent 的旧 needs 读成 exited；PR 合了的不再被还开着的子会话留住"
}

# Every release reopens idle sessions on the old version (ver-stale); the resume
# nudge is a new turn, so a session finished on a CLOSED ticket restarted
# done-no-pr's two hours on each release and never came due (#2338: @4390 → @4407 → @4425).
drill_reap_reopen_restarts_clock() {
  CAP=15; local t0 d sock w why
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  d="$WORK/rrc"; sock="$d/s"; mkdir -p "$d/conf/global" "$d/conf/fleets/rrc" "$d/gh"
  : > "$d/conf/fleets/rrc/conf"; fx_repo "$d/conf" rrc acme/app
  printf 'claude fp-new x\n' > "$d/conf/global/agent-cfg.expected"
  printf '#!/bin/sh\ncase "$*" in *"issue view 41"*) echo %s ;; *) exit 1 ;; esac\n' "'{\"state\":\"CLOSED\"}'" > "$d/gh/gh"
  chmod +x "$d/gh/gh"
  "$REAL_TMUX" -S "$sock" -f /dev/null new-session -d -s rrc -n w 'sleep 120' \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  w=$("$REAL_TMUX" -S "$sock" display-message -p -t rrc:w '#{window_id}')
  "$REAL_TMUX" -S "$sock" set-option -w -t "$w" @agent_cfg fp-old \; set-option -w -t "$w" @cc_agent claude \; \
    set-option -w -t "$w" @claude_state 'done' \; set-option -w -t "$w" @claude_state_ts 1 \; \
    set-option -w -t "$w" @issue 41 \; set-option -w -t "$w" @repo acme/app
  t0=$(now)
  why=$(env PATH="$d/gh:$PATH" TMUX="$sock,1,0" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
          bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why rrc "$2"' _ "$BIN" "$w" 2>/dev/null)
  SECS=$(since "$t0")
  "$REAL_TMUX" -S "$sock" kill-server 2>/dev/null
  [ "$why" = reap ] || { WHY="cfg-restart would reopen a finished session on a closed ticket: [$why], want reap"; return 1; }
  WHAT="单已关、做完了的会话不再被换版重开：两小时的「单已关才收」从它最后一轮算起，到点就收"
}

# A ver-stale reopen brought back a session whose work was over (T477 / T372, T569):
# its task record succeeded, the reaper closed the old window 12 s into the reopen,
# and the window the reopen then opened was nobody's to close.
drill_reopen_reap_race() {
  CAP=40; local t0 d sock w why
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  d="$WORK/rrr"; sock="$d/s"; mkdir -p "$d/conf/global" "$d/conf/fleets/rrr"
  : > "$d/conf/fleets/rrr/conf"; fx_repo "$d/conf" rrr acme/app
  printf 'claude fp-new x\n' > "$d/conf/global/agent-cfg.expected"
  printf '#!/bin/sh\n[ "$1" = T477 ] && { echo SUCCEEDED; exit 0; }\nexit 3\n' > "$d/closed"; chmod +x "$d/closed"
  "$REAL_TMUX" -S "$sock" -f /dev/null new-session -d -s rrr -n w 'sleep 120' \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  w=$("$REAL_TMUX" -S "$sock" display-message -p -t rrr:w '#{window_id}')
  "$REAL_TMUX" -S "$sock" set-option -w -t "$w" @agent_cfg fp-old \; set-option -w -t "$w" @cc_agent claude \; \
    set-option -w -t "$w" @claude_state 'done' \; set-option -w -t "$w" @claude_state_ts 1 \; \
    set-option -w -t "$w" @task T477 \; set-option -w -t "$w" @reap_policy merged
  t0=$(now)
  why=$(env TMUX="$sock,1,0" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_TASK_CLOSED_CMD="$d/closed" \
          bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why rrr "$2"' _ "$BIN" "$w" 2>/dev/null)
  "$REAL_TMUX" -S "$sock" kill-server 2>/dev/null
  [ "$why" = reap ] || { WHY="cfg-restart would reopen a session whose task succeeded: [$why], want reap"; return 1; }
  python3 "$BIN/fleet-cleanup-idle-selftest.py" "$BIN" \
    TaskSession.test_a_reopen_in_flight_holds_the_close_and_its_new_window_is_reaped >"$d/race.out" 2>&1 \
    || { WHY="the reaper still races a reopen: $(grep -E '^(FAIL|AssertionError)' "$d/race.out" | head -2 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="做完的会话（任务已收口 / ID 有结果）不再被换版重开；重开进行中回收不动它，重开出来的窗口按窗口照收"
}

# A finished session (T680) sat for hours: the reaper waited for the RECORD to close
# while the result was only on the ID (skip:task-open), then a 10-minute grace, then
# the next tick. One «做完» now — the ID's final result or the record closed — and
# the watcher a result starts closes the window about a minute after its turn.
drill_done_window_lingers() {
  CAP=60; local t0 d="$WORK/dwl"
  mkdir -p "$d"; t0=$(now)
  python3 "$BIN/fleet-cleanup-idle-selftest.py" "$BIN" \
    TaskSession.test_a_final_id_result_is_done_while_the_record_still_reads_open \
    TaskSession.test_now_watcher_closes_about_its_grace_after_the_turn >"$d/out" 2>&1 \
    || { WHY="a finished session still lingers: $(grep -E '^(FAIL|ERROR|AssertionError)' "$d/out" | head -2 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="ID 有了成功 / 失败结果即算做完（记录还停在已接受也一样），结果一落就盯住窗口、回合结束约 1 分钟收起"
}

# A finished task window whose worktree only held untracked tool output (T859:
# .playwright-mcp/, shots/) read as dirty and was never closed. Now untracked-only
# closes it (the worktree stays); a tracked change still keeps it.
drill_done_window_untracked() {
  CAP=60; local t0 d="$WORK/dwu"
  mkdir -p "$d"; t0=$(now)
  python3 "$BIN/fleet-cleanup-idle-selftest.py" "$BIN" \
    TaskSession.test_untracked_only_does_not_hold_a_closed_record_but_a_tracked_change_does >"$d/out" 2>&1 \
    || { WHY="a finished window with untracked files still lingers: $(grep -E '^(FAIL|ERROR|AssertionError)' "$d/out" | head -2 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="任务收口的窗口，工作树只有未跟踪文件也照样收起（工作树原样留着）；已跟踪的改动仍留窗"
}

# A stop whose /exit never landed (T680: T580's old driver, a loop that would not
# end) answered failed:no-exit and left the window running for hours. Now the agent's
# own tree is ended — TERM, a grace, KILL — the row recorded, the window closed.
drill_stop_no_exit_hangs() {
  CAP=30; local t0 d="$WORK/sne" w p out
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  mkdir -p "$d/tt" "$d/conf/fleets/sne"; : > "$d/conf/fleets/sne/conf"; fx_repo "$d/conf" sne acme/app FLEET_MAIN="$d"
  printf '#!/bin/bash\nexec bash -c '"'"': FLEETFAKESNE; trap "" TERM; while :; do sleep 1; done'"'"'\n' > "$d/fs"; chmod +x "$d/fs"
  TMUX_TMPDIR="$d/tt" "$REAL_TMUX" -L sne -f /dev/null new-session -d -s sne -n home 'sleep 120' \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  w=$(TMUX_TMPDIR="$d/tt" "$REAL_TMUX" -L sne new-window -d -P -F '#{window_id}' "$d/fs; while :; do sleep 300; done")
  TMUX_TMPDIR="$d/tt" "$REAL_TMUX" -L sne set-option -w -t "$w" @issue 12
  for _ in $(seq 1 30); do p=$(pgrep -f FLEETFAKESNE | head -n 1); [ -n "$p" ] && break; sleep 0.1; done
  t0=$(now)
  out=$(env TMUX_TMPDIR="$d/tt" FLEET_CONF_DIR="$d/conf" FLEET_HISTORY_LEDGER="$d/ledger.tsv" FLEET_SKIP_GLOBAL_CONF=1 \
          FLEET_CLAUDE_COMM=FLEETFAKESNE FLEET_STOP_EXIT_WAIT=2 FLEET_STOP_CLOSE_WAIT=0 FLEET_STOP_FORCE_GRACE=1 \
          bash "$BIN/fleet-worker-stop.sh" sne issue-12 2>/dev/null)
  SECS=$(since "$t0")
  if TMUX_TMPDIR="$d/tt" "$REAL_TMUX" -L sne list-windows -t sne -F '#{window_id}' 2>/dev/null | grep -qx -- "$w"; then
    TMUX_TMPDIR="$d/tt" FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L sne kill-server 2>/dev/null
    WHY="the window of an agent that ignored /exit and TERM is still open [$out]"; return 1
  fi
  TMUX_TMPDIR="$d/tt" FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L sne kill-server 2>/dev/null
  [ "$out" = stopped:forced ] || { WHY="a stop that /exit could not end answered [$out], want stopped:forced"; return 1; }
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { WHY="agent pid $p survived the forced stop"; return 1; }
  grep -q 'issue-12\|	12	' "$d/ledger.tsv" 2>/dev/null || { WHY="no history row for the forced stop"; return 1; }
  WHAT="/exit 不生效的会话：结束 agent 进程树（TERM → 宽限 → KILL），记历史、关窗，回 stopped:forced"
}

# Memory pressure cannot borrow the legacy archive path. Unwrapped idle or
# completed sessions stay for the normal reaper; admission still refuses when
# no safe park can release resources.
drill_admit_tight_done_windows() {
  CAP=120; local t0 d="$WORK/atdw"
  mkdir -p "$d"; t0=$(now)
  python3 "$BIN/fleet-make-room-selftest.py" "$BIN" \
    MakeRoom.test_memory_refusal_without_safe_parks_still_refuses \
    MakeRoom.test_completed_unwrapped_windows_wait_for_normal_reaper \
    MakeRoom.test_memory_pressure_never_archives_unwrapped_sessions >"$d/out" 2>&1 \
    || { WHY="memory pressure archived an unwrapped window or bypassed admission: $(grep -E '^(FAIL|ERROR|AssertionError)' "$d/out" | head -2 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="内存腾挪无安全停放协议则保留窗口和历史；完成回收归原流程，腾不出仍拒绝新启动"
}

# A session idle and about to be folded was reopened by every release instead
# (T695: one design page waiting on a nod reopened 10 times in a day, a whole
# turn each) — the reopen restarted the idle clock that folds it.
drill_reopen_folding_session() {
  CAP=60; local t0 d="$WORK/rfs"
  mkdir -p "$d"; t0=$(now)
  python3 "$BIN/fleet-make-room-selftest.py" "$BIN" \
    MakeRoom.test_a_reopen_leaves_a_window_a_reaper_counts_down >"$d/out" 2>&1 \
    || { WHY="a release still reopens a window a reaper counts down: $(grep -E '^(FAIL|ERROR|AssertionError)' "$d/out" | head -2 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="回收正在倒计时的闲置会话（@reap_due 新鲜）换版不重开；倒计时停了、被拦下（hold）照旧"
}

# A cross-machine send whose recipient's ID closed and whose machine left the hub's
# map sat QUEUED for days, «对方能收时自动补送» forever, and `status` listed nothing
# (T761: four 6-day-old sends on a managed Mac). Past FLEET_PEER_QUEUE_DEAD_SECS it is
# EXPIRED with one audit line and never said again.
drill_peerq_undeliverable_forever() {
  CAP=30; local t0 d="$WORK/pqu"
  mkdir -p "$d"; t0=$(now)
  bash "$BIN/peer-queue-dead-selftest.sh" >"$d/out" 2>&1 \
    || { WHY="an undeliverable send still waits forever: $(grep -E '^(FAIL|not ok)' "$d/out" | head -2 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="经入口的发送排队过一天判送不到：账本 EXPIRED + 一行审计、不再提醒；status 列得出跨机排队的"
}

# A finished session was reopened by every release (T761: stable moves every 10-30
# minutes; the reopen is a new window, so @cfg_restart_ts started empty each time —
# a reopen notice and an «is done» on the person's panel ~70 times a day).
drill_reopen_every_release() {
  CAP=10; local t0
  t0=$(now)
  grep -q 'held_today "\$ident"' "$BIN/fleet-cfg-restart.sh" && grep -q 'ledger_add "\$ident"' "$BIN/fleet-cfg-restart.sh" \
    || { WHY="fleet-cfg-restart.sh no longer holds a session's second reopen by its identity"; return 1; }
  suite_holds cfg-stale-selftest.sh 'held:day' 'FLEET_CFG_RESTART_DAY=0' \
    'the reopened window (same identity) is not reopened again the same day' || return 1
  SECS=$(since "$t0")
  WHAT="同一会话（@fleet_id）一天只换版重开一次：新窗口带同一 ID、答 held:day；会坏不受限（cfg-stale-selftest.sh 真跑，这里按名守住）"
}

# A stop sent over ssh / the peerlink runs with a bare PATH (/usr/bin:/bin): no tmux
# on it, every list empty, every key refused:not-found while the window stood.
drill_stop_bare_path() {
  CAP=10; local t0 d f n t w out
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  d="$WORK/sbp"; mkdir -p "$d/tt" "$d/conf/fleets/sbp" "$d/pbin" "$d/tbin"
  : > "$d/conf/fleets/sbp/conf"; fx_repo "$d/conf" sbp acme/app FLEET_MAIN="$d"
  # every system tool but tmux on PATH; tmux only in a tool dir
  for f in /usr/bin/* /bin/*; do
    n=${f##*/}; [ "$n" = tmux ] || [ -e "$d/pbin/$n" ] || ln -s "$f" "$d/pbin/$n" 2>/dev/null
  done
  for t in bash python3 ps awk; do [ -e "$d/pbin/$t" ] || ln -s "$(command -v "$t")" "$d/pbin/$t"; done
  ln -s "$REAL_TMUX" "$d/tbin/tmux"
  TMUX_TMPDIR="$d/tt" "$REAL_TMUX" -L sbp -f /dev/null new-session -d -s sbp -n w 'sleep 120' \
    || { WHY="cannot start the isolated tmux server"; return 1; }
  w=$(TMUX_TMPDIR="$d/tt" "$REAL_TMUX" -L sbp display-message -p -t sbp:w '#{window_id}')
  TMUX_TMPDIR="$d/tt" "$REAL_TMUX" -L sbp set-option -w -t "$w" @issue 12
  t0=$(now)
  out=$(env -i HOME="$WORK" PATH="$d/pbin" FLEET_TOOL_DIRS="$d/tbin" TMUX_TMPDIR="$d/tt" \
          FLEET_CONF_DIR="$d/conf" FLEET_HISTORY_LEDGER="$d/ledger.tsv" FLEET_SKIP_GLOBAL_CONF=1 \
          "$d/pbin/bash" "$BIN/fleet-worker-stop.sh" sbp issue-12 2>/dev/null)
  SECS=$(since "$t0")
  TMUX_TMPDIR="$d/tt" "$REAL_TMUX" -L sbp kill-server 2>/dev/null
  [ "$out" = stopped:shell ] || { WHY="a bare-PATH stop answered [$out], want stopped:shell"; return 1; }
  WHAT="裸 PATH（ssh / peerlink）下 fleet-worker-stop.sh 照样找到 fleet 上的窗口并停掉"
}

# A parent that /clear-ed (or handed off, or was re-launched) lost its children's
# reports (EPIC T497 C4): the accepted-task road gated delivery on the parent's
# task generation and its native process, both of which a clear / handoff / restart
# change. With Parent delivery retired, neither clear nor succession may restore
# delivery. The old explicit caller retains only its own result history.
drill_report_parent_cleared() {
  CAP=20; local d="$WORK/rpc" L="rpc$$" sp spid pa ch su wpa pch wch wsu t0 out1 out2
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  mkdir -p "$d/conf/fleets/$L" "$d/tt"; : > "$d/conf/fleets/$L/conf"
  fx_repo "$d/conf" "$L" acme/app FLEET_MAIN="$d"
  rtm() { TMUX_TMPDIR="$d/tt" FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" "$@"; }
  rtm -f /dev/null new-session -d -s "$L" -n home 'sleep 120' || { WHY="cannot start the isolated tmux server"; return 1; }
  sp=$(rtm display-message -p '#{socket_path}'); spid=$(rtm display-message -p '#{pid}')
  pa=$(python3 -c 'import uuid; print(uuid.uuid4())'); ch=$(python3 -c 'import uuid; print(uuid.uuid4())')
  su=$(python3 -c 'import uuid; print(uuid.uuid4())')
  wpa=$(rtm new-window -d -P -F '#{window_id}' 'sleep 120'); rtm set-option -w -t "$wpa" @fleet_id "$pa"
  wch=$(rtm new-window -d -P -F '#{window_id}' 'sleep 120')
  rtm set-option -w -t "$wch" @fleet_id "$ch"; rtm set-option -w -t "$wch" @origin "$pa"; rtm set-option -w -t "$wch" @origin_fid "$pa"
  pch=$(rtm display-message -p -t "$wch" '#{pane_id}')
  rpe() { (cd "$d" && env TMUX_TMPDIR="$d/tt" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_ID_PUSH=0 \
            TMUX="$sp,$spid,0" "$@"); }
  rpe python3 "$BIN/fleet_id.py" open "$pa" --agent claude >/dev/null
  rpe python3 "$BIN/fleet_id.py" open "$ch" --parent "$pa" >/dev/null
  rpe python3 "$BIN/fleet_id.py" native "$pa" --native p0001 --source startup >/dev/null
  rpe python3 "$BIN/fleet_id.py" native "$pa" --native p0002 --source clear >/dev/null   # the parent clears
  t0=$(now)
  out1=$(rpe env TMUX_PANE="$pch" bash "$BIN/fleet-report-parent.sh" --state waiting --summary finished 2>&1)
  rpe bash -c '. "$1/fleet-lib.sh"; fleet_win_retire "$2" "$3" exited' _ "$BIN" "$wpa" "$L"; rtm kill-window -t "$wpa"
  wsu=$(rtm new-window -d -P -F '#{window_id}' 'sleep 120'); rtm set-option -w -t "$wsu" @fleet_id "$su"
  rpe python3 "$BIN/fleet_id.py" open "$su" --prev "$pa" >/dev/null
  out2=$(rpe env TMUX_PANE="$pch" bash "$BIN/fleet-report-parent.sh" --state waiting --summary finished 2>&1)
  SECS=$(since "$t0")
  rtm kill-server 2>/dev/null
  case "$out1" in *RECORDED:*RETIRED:*) ;; *) WHY="clear lost own result or delivered: $out1"; return 1 ;; esac
  case "$out2" in *RECORDED:*RETIRED:*) ;; *) WHY="successor received report or own history lost: $out2"; return 1 ;; esac
  grep -q 'parent_matches(r, parent)' "$BIN/fleet_task_control.py" \
    && { WHY="the accepted-task road still gates delivery on the parent's generation"; return 1; }
  WHAT="旧父会话 clear 或出现接班会话都不恢复投递；显式旧调用仅保存自身结果"
}

# A batch's report went to nobody (T660): orchestrator A spawned a plan-page session
# B (scratch-3), B spawned the EPIC driver C, B closed and a new session was given
# scratch-3. The mint moved C's @origin aside to @origin_retired, and the report's
# earlier-generation branch filed it for the person and exited — before the
# identity road, which knew B's parent A was alive. Those legacy identities remain
# readable, but re-minting cannot restore delivery to an ancestor or new holder.
drill_report_parent_key_reminted() {
  CAP=20; local d="$WORK/rpk" L="rpk$$" sp spid pa pb ch dh wpa wb wch wdh pch pdh t0 o1 o2 org
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  mkdir -p "$d/conf/fleets/$L" "$d/tt"; : > "$d/conf/fleets/$L/conf"
  fx_repo "$d/conf" "$L" acme/app FLEET_MAIN="$d"
  rtm() { TMUX_TMPDIR="$d/tt" FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" "$@"; }
  rtm -f /dev/null new-session -d -s "$L" -n home 'sleep 120' || { WHY="cannot start the isolated tmux server"; return 1; }
  sp=$(rtm display-message -p '#{socket_path}'); spid=$(rtm display-message -p '#{pid}')
  pa=$(python3 -c 'import uuid; print(uuid.uuid4())'); pb=$(python3 -c 'import uuid; print(uuid.uuid4())')
  ch=$(python3 -c 'import uuid; print(uuid.uuid4())'); dh=$(python3 -c 'import uuid; print(uuid.uuid4())')
  wpa=$(rtm new-window -d -P -F '#{window_id}' 'sleep 120'); rtm set-option -w -t "$wpa" @fleet_id "$pa"
  wb=$(rtm new-window -d -P -F '#{window_id}' 'sleep 120'); rtm set-option -w -t "$wb" @fleet_id "$pb"
  wch=$(rtm new-window -d -P -F '#{window_id}' 'sleep 120')
  rtm set-option -w -t "$wch" @fleet_id "$ch"; rtm set-option -w -t "$wch" @origin acme-app:scratch-3; rtm set-option -w -t "$wch" @origin_fid "$pb"
  wdh=$(rtm new-window -d -P -F '#{window_id}' 'sleep 120')
  rtm set-option -w -t "$wdh" @fleet_id "$dh"; rtm set-option -w -t "$wdh" @origin_retired 'acme-app:scratch-3#0'; rtm set-option -w -t "$wdh" @origin_fid "$pb"
  pch=$(rtm display-message -p -t "$wch" '#{pane_id}'); pdh=$(rtm display-message -p -t "$wdh" '#{pane_id}')
  rpe() { (cd "$d" && env TMUX_TMPDIR="$d/tt" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_ID_PUSH=0 \
            TMUX="$sp,$spid,0" "$@"); }
  rpe python3 "$BIN/fleet_id.py" open "$pa" --agent claude >/dev/null
  rpe python3 "$BIN/fleet_id.py" open "$pb" --parent "$pa" >/dev/null
  rpe python3 "$BIN/fleet_id.py" open "$ch" --parent "$pb" >/dev/null
  rpe python3 "$BIN/fleet_id.py" open "$dh" --parent "$pb" >/dev/null
  t0=$(now)
  # B closes; scratch-3 is given to a new session (its generation minted)
  rpe bash -c '. "$1/fleet-lib.sh"; fleet_win_retire "$2" "$3" exited' _ "$BIN" "$wb" "$L"; rtm kill-window -t "$wb"
  rpe bash -c '. "$1/fleet-lib.sh"; fleet_scratch_gen_new "$2" scratch-3 ""' _ "$BIN" "$L"
  org=$(rtm display-message -p -t "$wch" '#{@origin}|#{@origin_retired}')
  o1=$(rpe env TMUX_PANE="$pch" bash "$BIN/fleet-report-parent.sh" --state waiting --summary kept 2>&1)
  o2=$(rpe env TMUX_PANE="$pdh" bash "$BIN/fleet-report-parent.sh" --state waiting --summary kept 2>&1)
  SECS=$(since "$t0")
  rtm kill-server 2>/dev/null
  [ "$org" = "$pb|" ] || { WHY="the re-mint moved an identified child aside: @origin|@origin_retired = [$org], want [$pb|]"; return 1; }
  case "$o1" in *RECORDED:*RETIRED:*) ;; *) WHY="reused key redirected report or lost own result: $o1"; return 1 ;; esac
  case "$o2" in *RECORDED:*RETIRED:*) ;; *) WHY="retired origin redirected report or lost own result: $o2"; return 1 ;; esac
  WHAT="旧父会话编号重领或 origin 已退役都不向祖先投递；自身历史仍保存"
}

# The hub's ID switch flipped under a running session (EPIC T497 C6): the window
# still carried the old launch binding (@launch), and its report went to the task
# record, which the hub refused (409 ID_SWITCH) — the result was lost, and so was
# every report until someone reopened the window. Since C8 the gate is «the window
# has an ID» whatever the switch says: a task's report is a result on its ID,
# with or without a pre-C8 @launch, the switch on or off — twice round.
drill_id_switch_flip_report() {
  CAP=30; local d="$WORK/isf" L="isf$$" sp spid f w p t0 n got out round word
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  mkdir -p "$d/conf/ids" "$d/tt"
  rtm() { TMUX_TMPDIR="$d/tt" FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" "$@"; }
  rtm -f /dev/null new-session -d -s "$L" -n home 'sleep 120' || { WHY="cannot start the isolated tmux server"; return 1; }
  sp=$(rtm display-message -p '#{socket_path}'); spid=$(rtm display-message -p '#{pid}')
  f=$(python3 -c 'import uuid; print(uuid.uuid4())')
  w=$(rtm new-window -d -P -F '#{window_id}' 'sleep 120'); p=$(rtm display-message -p -t "$w" '#{pane_id}')
  rtm set-option -w -t "$w" @fleet_id "$f"; rtm set-option -w -t "$w" @task T42; rtm set-option -w -t "$w" @launch '{"version":1}'
  rse() { (cd "$d" && env -u FLEET_ID_SWITCH TMUX_TMPDIR="$d/tt" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_ID_PUSH=0 \
            TMUX="$sp,$spid,0" "$@"); }
  rse python3 "$BIN/fleet_id.py" open "$f" --agent claude --task T42 >/dev/null
  nres() { rse python3 "$BIN/fleet_id.py" get "$f" --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["results"]))'; }
  t0=$(now); n=0
  for round in 1 2; do
    for word in on off; do
      printf '%s %s\n' "$word" "$(date +%s)" > "$d/conf/ids/.switch"
      out=$(rse env TMUX_PANE="$p" bash "$BIN/fleet-report-parent.sh" --state waiting --outcome succeeded --summary "$word $round" 2>&1)
      n=$((n + 1)); got=$(nres)
      [ "$got" = "$n" ] || { rtm kill-server 2>/dev/null; WHY="switch $word, round $round: $got results on the ID, want $n [$out]"; return 1; }
    done
  done
  SECS=$(since "$t0")
  [ "$(rtm display-message -p -t "$w" '#{@fleet_id}')" = "$f" ] || { rtm kill-server 2>/dev/null; WHY="the window lost its ID across the flips"; return 1; }
  rtm kill-server 2>/dev/null
  WHAT="开关怎么切都一样：任务窗口（带不带切换前的 @launch）的回报都写在它的 ID 上，两轮四次一次不丢；窗口和它的 ID 一直在"
}

# A window a pre-C8 launch supervisor ran (T505's @1156, the T497 driver's @1052:
# FLEET_LAUNCH_CONTEXT / FLEET_LAUNCH_SUPERVISOR in its environment, @launch on the
# window) is reopened on the C8 release — a version-stale reopen, the exit page's
# ↵, a restore — by the new wrapper or by an older wrapper still calling
# `fleet_launch.py supervise`. It comes back as itself: the same window and ID,
# its conversation resumed, no hub asked; the retired proof's options come off.
drill_c8_old_supervisor_reopen() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(cd "$BIN" && python3 fleet_hub_rest_start_test.py \
        CredentialStartTests.test_pre_c8_launch_window_reopens_as_itself \
        CredentialStartTests.test_an_older_wrapper_through_the_retired_supervisor 2>&1) || { WHY="$out"; return 1; }
  grep -q 'retire(pane)' "$BIN/fleet_launch.py" \
    || { WHY="fleet_launch.py supervise no longer retires the window's @launch* before the ordinary road"; return 1; }
  SECS=$(since "$t0")
  WHAT='切换前的旧启动监督窗口在 C8 版本上重开（新包装器 / 旧包装器经 fleet_launch.py supervise）：同一个窗口、同一个 ID 接着 resume，不问 hub，@launch 系列选项拿掉'
}

# A web session parked while a person is looking at it in a terminal (task HHV0):
# its agent would exit under their eyes. The gate's park refuses while a terminal
# client shows the window (a control-mode client — the hub's own — is nobody).
drill_wake_peer_report() {
  CAP=40; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-selftest.py" Park.test_parked_peer_first_turn Park.test_retired_report_queue_never_wakes Park.test_parked_message_queue_drain \
        Park.test_local_child_report_never_wakes_parent Park.test_late_wake_receipt_is_not_a_second_turn \
        Park.test_question_is_never_parked 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='普通 peer 消息仍唤醒同一身份；旧回报队列和 hook 不唤醒停放会话'
}

drill_park_reap_table() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-cleanup-idle-selftest.py" ParkTable \
    HoldsAndWhy.test_waiting_on_its_person_parks_after_its_hours 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='停放与回收同表：每来源、三天期限、历史可接回，doctor 同一时刻'
}

drill_park_reap_current_work() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-lifecycle-selftest.py" Lifecycle.test_new_message_invalidates_old_terminal_and_closed_task \
    Lifecycle.test_new_task_does_not_inherit_previous_report Lifecycle.test_message_during_report_prevents_stale_terminal_commit \
    Lifecycle.test_new_task_or_attempt_during_report_refuses_commit Lifecycle.test_prompt_invalidates_but_tool_and_lifecycle_exit_do_not \
    Lifecycle.test_fresh_report_restores_completion_for_current_work \
    Lifecycle.test_wake_seed_invalidates_old_completion_under_same_gate \
    Lifecycle.test_delivered_message_restarts_idle_clock_before_native_hook 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='新任务/消息使旧完成证据失效；报告提交不能覆盖在它期间接收的新工作'
}

drill_park_reap_admission() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-lifecycle-selftest.py" Lifecycle.test_close_rechecks_admitted_message_under_identity_lock \
    Lifecycle.test_norepo_close_roads_recheck_the_same_pending_message Lifecycle.test_retired_window_is_rechecked_at_message_admission \
    Lifecycle.test_legacy_admission_invalidates_and_rechecks_closed_window Lifecycle.test_shell_descriptor_holds_the_same_identity_lock \
    Lifecycle.test_live_legacy_report_directory_does_not_require_wake_api \
    Lifecycle.test_final_native_guard_preserves_question_draft_and_unknown 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='普通/停放/无仓库关窗与消息准入共用身份锁；关闭先赢则拒绝对旧窗口的准入'
}

drill_park_web_probe_old_api() {
  CAP=30; local t0
  t0=$(now)
  webchat_part probe-contract "P old resident refuses probe without spawning ordinary web" \
    "P explicit probe route preserves ownership through the official spawner" \
    "P ordinary web retains its existing source" || return 1
  SECS=$(since "$t0")
  WHAT='健康旧驻留服务不识别probe路由时拒绝且零创建；新服务同一创建入口验证父身份，普通web不扩收'
}

drill_park_web_owned_probe() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(node "$BIN/fleet-webchat-selftest.mjs" --only=gate 2>&1) || { WHY="$out"; return 1; }
  out=$(bash "$BIN/reap-origin-selftest.sh" 2>&1) || { WHY="$out"; return 1; }
  out=$(python3 "$BIN/fleet-lifecycle-selftest.py" Lifecycle.test_explicit_probe_needs_a_completed_result_not_only_native_idle 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='正式临时web创建带probe来源和父身份；标题和native idle不是完成证据，普通web不扩收'
}

drill_park_reap_report() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-report-durable-selftest.py" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='自身结果写失败保留会话；写成功不等待已退役的 Parent 投递'
}

drill_park_reap_background() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-cleanup-idle-selftest.py" HoldsAndWhy.test_a_background_job_holds_a_done_task_past_old_grace 2>&1) || { WHY="$out"; return 1; }
  out=$(python3 "$BIN/fleet-reap-live-selftest.py" LiveTests.test_old_bg_over_flag_cannot_override_real_work 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='任务终态、旧宽限期及旧 --bg-over 参数均不能关闭真实后台任务或待执行循环'
}

drill_park_reap_exceptions() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-cleanup-idle-selftest.py" \
    ParkTable.test_finished_probe_keeps_its_one_minute_policy \
    ParkTable.test_decide_keeps_idle_policy_except_reported_waiting \
    ParkTable.test_park_refusal_reaches_doctor 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='decide 保留 idle:15m，明确 waiting 才用停放三天；probe 做完一分钟仍走原回收门；拒停原因送到 doctor'
}

drill_park_drops_dialog() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-selftest.py" Park.test_dialog_guard_all_park_routes \
        Park.test_dialog_appears_after_native_proof Park.test_dialog_appears_during_timer_export 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='选择框超 30 分钟及内存紧也拒停；旧 done、loop 和证明期间出现的问题不接收 /exit，题干选项原文保持'
}

drill_park_all_origins() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-selftest.py" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='所有来源共用停放器：同一窗口与身份，真实进程退出后同会话接回；草稿、后台任务、旧外壳不停'
}

drill_park_codex_new_thread() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-selftest.py" Park.test_codex_same_thread_and_paste_exit 2>&1) || { WHY="$out"; return 1; }
  out=$(python3 "$BIN/fleet-codex-busy-selftest.py" "$BIN" CodexBusy.test_park_relay_is_infrastructure_but_its_jobs_are_work CodexBusy.test_managed_home_worker_can_reach_native_busy_probe 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='Codex 优雅退出后保留窗口与身份，接回明确 resume 原 thread 并带入原话'
}

drill_park_codex_loop_idle() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-selftest.py" Park.test_codex_looping_without_mod_status_uses_native_idle_proof 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='Codex 循环没有 Claude mod 状态时仍由原生 idle 证明决定停放，正在工作的原生 thread 不停'
}

drill_wake_loop_reenters_bridge() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-selftest.py" Park.test_parked_resume_does_not_reenter_initial_loop_bridge 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='停放后接回清除首次桥接启动参数，保留原 manifest 与单 owner 定时约定，不重建循环'
}

drill_wake_wrong_transcript() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(bash "$BIN/dash-issue-session-prompt-selftest.sh" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='启用 Codex 停放不能把旧项目目录里的 Claude transcript 当成它的恢复依据'
}

drill_park_old_wrapper() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-session-gate-selftest.py" N 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='旧外壳没有停放页：拒停，不送退出，不动凭据和窗口'
}

drill_park_loses_loop() {
  CAP=45; local t0 out fid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeee03 sid=11111111-2222-4333-8444-555555555503
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-wake-selftest.py" test_wakeup 2>&1) || { WHY="$out"; return 1; }
  # Drive fleet-restore.sh as well: the snapshot says done, but the contract
  # keeps it unfinished. The original wrapper returns without starting Claude.
  BREAK_SOCK="$WORK/sock-park-timer"
  mkdir -p "$WORK/econf/wake" "$WORK/wt-3" "$WORK/gbin"
  printf '#!/bin/sh\necho 0\n' > "$WORK/gbin/gh"; chmod +x "$WORK/gbin/gh"
  python3 - "$WORK/econf/wake/$fid.json" "$fid" "$sid" <<'PY'
import json,sys,time
due=int(time.time())+3600
json.dump(dict(v=1,fid=sys.argv[2],sid=sys.argv[3],agent='claude',phase='active',parked=True,next=due,
               jobs=[dict(id='once',kind='wakeup',expr='',prompt='original timer prompt',until=due+600,
                          next=due,recurring=False)]),open(sys.argv[1],'w'))
PY
  { printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
    printf 'FID\t%s\n' "$fid"; printf 'WIN\tissue-3\t%s\t%s\t3\tdone\t-\t-\n' "$WORK/wt-3" "$sid"
  } > "$WORK/econf/fleets/oc/restore.map"
  auto PATH="$WORK/gbin:$WORK/tbin:$PATH"
  [ "$(o oc:issue-3 @cc_session_id)" = "$sid" ] && [ -n "$(o oc:issue-3 @park_held)" ] \
    || { WHY='parked timer was not restored into the original conversation holding page'; return 1; }
  nt kill-window -t oc:issue-3
  auto PATH="$WORK/gbin:$WORK/tbin:$PATH"
  [ "$(o oc:issue-3 @fleet_id)" = "$fid" ] && [ -n "$(o oc:issue-3 @park_held)" ] \
    || { WHY='the done snapshot suppressed pullback of the killed timer wrapper'; return 1; }
  [ "$(o oc:issue-3 @restore_outcome)" = resumed ] \
    || { WHY='restore called the holding wrapper a failed native launch'; return 1; }
  SECS=$(since "$t0")
  WHAT='进程退出后到点唤醒，同一窗口与会话的首轮是原提示，约定时刻记入动作账本'
}

drill_park_loop_rebootstrap() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-wake-selftest.py" test_codex_park_resume_does_not_bootstrap_second_controller 2>&1) \
    || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='原 Fleet loop 停放接回不复用首次创建控制器的环境，同 thread 原提示一次、原账本继续调度'
}

drill_park_export_refusal_owner() {
  CAP=90; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-export-selftest.py" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='真实导出后复检拒停立即归还原合同与投递权，保留问题且不退出；原 dispatcher 到点只执行一次'
}

drill_park_stopped_timer_revives() {
  CAP=45; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-wake-selftest.py" test_codex_stopped_loop_never_rearms \
    test_codex_stopped_pending_loop_never_rearms test_codex_cancelled_pending_job_keeps_sibling \
    test_codex_cancelled_pending_job_keeps_due_sibling test_cancelled_native_cron_pending_never_wakes 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='显式停止或取消后，旧定时队列不再接回；未取消的任务保留同一账本和会话'
}

drill_park_loses_cron() {
  CAP=45; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-wake-selftest.py" test_cron_three_rounds 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='cron 连续停放接回三次，每轮原提示一次，不重建、不叠加'
}

drill_park_census_overcounts() {
  CAP=15; local t0 out rc
  t0=$(now)
  out=$(bash "$BIN/fleet-park-metrics-selftest.sh" 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="$out"; return 1; }
  WHAT='空闲常驻按验收口径排除观看与后台，仍显示原因；采样不足未知；停放认 HHV0 双标记，C1 快照缺戳才读账本后备'
  SECS=$(since "$t0")
}

drill_park_while_watched() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-session-gate-selftest.py" G 2>&1) || { WHY="$out"; return 1; }
  grep -q 'why="watched"' "$BIN/fleet_session_gate.py" \
    || { WHY="fleet_session_gate.py park no longer refuses a watched window"; return 1; }
  SECS=$(since "$t0")
  WHAT='有人在终端里看着的网页会话不停放；没人看（控制模式的客户端不算人）、闲着才停'
}

drill_park_human_presence_lost() {
  CAP=20; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-selftest.py" Park.test_park_screen_and_keyboard_sentence 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='停放页的单调时钟从零附近起步：首次输入立即记录 presence，未回车不醒，原句仍带入恢复首轮'
}

drill_park_backspace_ghost_draft() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-selftest.py" Park.test_backspace_at_empty_and_line_start_preserves_wake \
    Park.test_saved_del_only_draft_does_not_block_new_editor Park.test_saved_text_with_del_remains_protected \
    Park.test_saved_whitespace_remains_protected 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='真实停放页空输入与行首退格不产生 DEL 草稿；真实 Unicode 草稿仍阻止外部接回，清空后同 SID 接回原句一次'
}

# A parked session that does not come back (task HHV0): the machine went away, the
# resume hangs. The sentence must not wait for ever, nor turn up later as a turn
# after the page said 没送到: past FLEET_GATE_WAKE_SECS (20) the gate takes the seed
# back by the same rename the wrapper claims it with, and returns the sentence.
drill_park_memory_no_archive() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-lifecycle-capacity-selftest.py" Lifecycle.test_memory_never_calls_terminal_reaper_and_missing_rss_stays_unknown 2>&1) || { WHY="$out"; return 1; }
  out=$(python3 "$BIN/fleet-make-room-selftest.py" MakeRoom.test_memory_pressure_never_archives_unwrapped_sessions 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='内存腾挪只安全停放，不借终态回收或旧外壳路径归档；原话、历史、身份保留'
}

drill_park_runtime_capacity() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-lifecycle-capacity-selftest.py" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='确认停放才释放运行容量，接回重新计入；memory make-room 保留 pin/keep/管家及身份，问题不退出'
}

drill_wake_fair_order() {
  CAP=20; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-wake-fairness-selftest.py" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='共享唤醒票据同级先到先得，人工优先有界，过期票据不挡队列'
}

drill_wake_launcher_no_ready() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-wake-guard-selftest.py" Recovery.test_codex_timer_launcher_failure_needs_this_launch_receipt Recovery.test_recovery_page_with_stale_sid_is_not_a_wake_receipt Recovery.test_failed_peer_wake_retry_does_not_report_already_awake 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='Codex launcher 无 native-ready：旧 SID 和 parked 清空不算成功；原话及定时轮次保留，失败可见且只记一次'
}

drill_wake_full_card() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-wake-guard-selftest.py" Recovery.test_major_version_preflight_starts_fresh_and_keeps_words Recovery.test_two_failed_resumes_keep_words_and_disable_reparking Recovery.test_memguard_rule_c_parks_idle_through_the_existing_gate 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='主版本不符自动新开且原话保留、fresh 原因可查；连续失败 doctor WARN；4 GB 空闲窗口由同一门停放'
}

drill_wake_storm() {
  CAP=90; local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-loadgen.sh" 4 300 -- python3 "$BIN/fleet-wake-guard-selftest.py" 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT="十个 fake 会话跨登录共享名额，接回同时最多三个、60 秒内全醒；$out"
}

drill_wake_fail_silent() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-park-selftest.py" Park.test_park_screen_and_keyboard_sentence Park.test_wake_failure_keeps_sentence_for_new_chat 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='停放保留原屏，回车前不醒；接回失败原句仍在，n 的新会话首轮带上它'
}

drill_wake_timeout() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-session-gate-selftest.py" H I 2>&1) || { WHY="$out"; return 1; }
  grep -q 'mv "$w" "$w.taken"' "$BIN/fleet-session-wrap.sh" \
    || { WHY="fleet-session-wrap.sh park_hold no longer claims the wake seed by rename"; return 1; }
  SECS=$(since "$t0")
  WHAT='停放的会话接回超时：这一句退回（wake_timeout），种子被收回，晚到的接回不会再带着它开一轮；按时接回的第一句随启动进去'
}

# An EPIC member whose window closed with no result while its record stayed open
# (EPIC T497 C5): the batch read the record alone, so the member was `running` for
# ever and the batch never finished; a member continued by hand (a new ID, prev the
# old one, no record) was never seen. The tick reads the member's ID chain now.
drill_epic_member_dead_record() {
  CAP=10; local t0 out
  t0=$(now)
  out=$(python3 - "$BIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tick", sys.argv[1] + "/fleet-epic-tick.py")
tick = importlib.util.module_from_spec(spec); spec.loader.exec_module(tick)
a, b = "aaaaaaaa-0000-4000-8000-00000000000a", "bbbbbbbb-0000-4000-8000-00000000000b"
kid = dict(id="T2", outcome="", worker_id="fleet/" + a)
dead = [dict(id=a, short="T-aaaaa", state="exited", prev="", result=None)]
m = tick.judge(dict(key="C1"), [kid], dead)
redo = dead + [dict(id=b, short="T-bbbbb", state="done", prev=a, result=dict(state="merged", pr="9"))]
n = tick.judge(dict(key="C1"), [kid], redo)
print(m["state"], n["state"], n["short"], n["pr"])
PY
)
  SECS=$(since "$t0")
  [ "$out" = "retry succeeded T-bbbbb 9" ] \
    || { WHY="a dead member read [$out], want «retry succeeded T-bbbbb 9» (its closed ID a failure, its continuation the newest baton)"; return 1; }
  WHAT="成员窗口关了没结果、记录还开着：按 ID 读成失败可重试；手动续上的新 ID 被认作它的最新一棒"
}

# One task, several IDs (EPIC T644 C2): the task record had an ID from its first
# moment (C1), but the window opened for it minted its own, and every restart /
# redo opened yet another (a new ID + prev) — so a redo that merged could not
# close the task it redid. Now the window takes the task's ID, a redo here is the
# same ID's next attempt (attempt 1's failure no longer counts), and the recovery
# page's ↵ on the same conversation is a new segment of it.
drill_task_many_ids() {
  CAP=20; local t0 d="$WORK/tmi" out
  mkdir -p "$d/conf"
  t0=$(now)
  out=$(cd "$d" && env FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_ID_PUSH=0 \
        FLEET_ID_HUB_POST="false" python3 - "$BIN" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_id as f
t = "aaaaaaaa-0000-4000-8000-0000000000c2"
first = f.take_task_id(t) or "none"             # the hub silent, no ledger: never taken blind
f.open_id(t, {"task": "T9", "agent": "claude"})
f.record_native(t, "claude", "n1", "startup")
f.record_native(t, "claude", "n1", "resume", "reopen")   # ↵ on the same conversation
f.append(t, {"ev": "result", "state": "failed"})
f.append(t, {"ev": "closed", "reason": "reaped"})
redo = f.take_task_id(t)
n = f.next_attempt(t)
f.record_native(t, "claude", "n2", "startup")
mid = f.status(t, [t])["state"]
f.append(t, {"ev": "result", "state": "merged", "pr": "12"})
rec = f.fold(f.read(t))
print(first, redo, n, " ".join(s["trigger"] for s in rec["segments"]), mid, f.status(t, [t])["state"])
PY
)
  SECS=$(since "$t0")
  [ "$out" = "none here 2 startup reopen redo running done" ] \
    || { WHY="one task's ID read [$out], want «none here 2 startup reopen redo running done»"; return 1; }
  grep -q 'fleet_task_take "$TASK_REF"' "$BIN/dash-raw-session.sh" \
    || { WHY="dash-raw-session.sh no longer opens a task's window on the task's ID"; return 1; }
  WHAT="任务的窗口用任务的编号；同机重做是同一编号的第 2 次（上一次的失败不再算），恢复页 ↵ 是同一编号的新一段"
}

# An EPIC driver reaped mid-batch and continued (C18): the successor is a new ID
# (prev = the driver) whose dispatches carry parent_session only. The batch still
# reads them as its members — the driver is its whole line.
drill_epic_driver_continued() {
  CAP=10; local t0 out
  t0=$(now)
  out=$(python3 - "$BIN" <<'PY'
import importlib.util, sys
sys.path.insert(0, sys.argv[1])
import fleet_id
spec = importlib.util.spec_from_file_location("tick", sys.argv[1] + "/fleet-epic-tick.py")
tick = importlib.util.module_from_spec(spec); spec.loader.exec_module(tick)
d1, d2, c = "aaaaaaaa-0000-4000-8000-0000000000a1", "aaaaaaaa-0000-4000-8000-0000000000a2", "cccccccc-0000-4000-8000-00000000000c"
idx = {d1: {"opened": {"task": "T580", "prev": "", "ts": 1}}, d2: {"opened": {"task": "T580", "prev": d1, "ts": 2}},
       c: {"opened": {"task": "T585", "parent": d2, "ts": 3}}}
line = fleet_id.lineage_of(d1, idx)
root = fleet_id.task_root("T580", idx)
tick.record = lambda *a: {"task": {"id": a[1], "title": "C1 · x", "outcome": ""}}
kids = tick.adopted([dict(id=c, parent=d2, task="T585")], line, set())
print(len(line), root == d1, " ".join(k["id"] for k in kids))
PY
)
  SECS=$(since "$t0")
  [ "$out" = "2 True T585" ] \
    || { WHY="a continued driver's batch read [$out], want «2 True T585» (the line of two, rooted at the record's first ID, the successor's dispatch adopted)"; return 1; }
  WHAT="驱动被回收后 continue 出新 ID：父 = 整条 prev 线，接班窗口派的子记录（只带 parent_session）仍认作本批成员"
}

drill_launch_binary_renamed() {
  CAP=10; local d="$WORK/lbr" t0 out
  mkdir -p "$d/tools" "$d/rel/.release/artifacts"
  printf '#!/bin/sh\necho "2.1.295 (Claude Code)"\n' > "$d/tools/claude"; chmod +x "$d/tools/claude"
  ln "$d/tools/claude" "$d/rel/.release/artifacts/claude-2.1.295-darwin-arm64"
  t0=$(now)
  out=$(cd "$BIN" && python3 - "$d" <<'PY'
import sys
from unittest import mock
import fleet_native_proc as proc
d = sys.argv[1]
receipt = dict(pid=50, ppid=49, birth="b", executable=d + "/tools/claude")
seen = dict(receipt, executable=d + "/rel/.release/artifacts/claude-2.1.295-darwin-arm64")
with mock.patch.object(proc, "process", return_value=seen), \
     mock.patch.object(proc.os, "getppid", return_value=50):
    print(proc.same_process(receipt), proc.native_parent()["actual_provider"])
PY
)
  SECS=$(since "$t0")
  [ "$out" = "True claude" ] \
    || { WHY="a running Claude seen under its release artifact link read [$out], want «True claude»"; return 1; }
  WHAT="版本切换让在跑的 Claude 换了个硬链接名：进程身份照样认得同一个进程、同一个 Claude"
}

# mcp-release-path-pinned (T598, EPIC T497 C19): a window a tool call spawned launches
# its fleet MCP server by its parent's RESOLVED release path, which never changes — the
# server kept that release's scripts for life (a driver opened between C6 and #5026
# dispatched through a half-switched road). fleet-mcp-selftest.sh M2 launches one by
# <root>/<sha>/bin and by fleet.versions/<sha>/bin and asks it to follow the link.
drill_mcp_release_path_pinned() {
  CAP=10; local t0
  t0=$(now)
  suite_holds fleet-mcp-selftest.sh '# --- M2: launched by a release' 'ok "M2 launched by a release' || return 1
  SECS=$(since "$t0")
  WHAT="按某个版本树自己的路径起的 fleet MCP 服务：第一次调用就换到 current 指的版本，之后每次换版都跟上；不是版本树的路径原样不动（fleet-mcp-selftest.sh M2 真跑，这里按名守住）"
}

# T580's two Codex-only breaks of a session's start and its /clear (T629, EPIC T580
# C5) — one witness for both agents (fleet_id.hook, the adapter's sid_source /
# clear_said); each recovery is a leg of bin/fleet-agent-witness-selftest.py run once
# per agent (Claude's SessionStart payload, Codex's runtime against the one fake
# app-server): held here by name, not run twice.
# ① a dispatched Codex task never read as started (#4972)
drill_start_unwitnessed() {
  CAP=10; local t0
  t0=$(now)
  grep -qF '_ledger_hook(pane, socket, sid, "resume" if sid == opened_for else "startup")' "$BIN/fleet-codex-session.py" \
    || { WHY="fleet-codex-session.py no longer witnesses a Codex start through the ledger's hook"; return 1; }
  suite_holds fleet-agent-witness-selftest.py 'start before the first turn' 'def test_claude' 'def test_codex' || return 1
  WHAT='Codex 会话人还没开口时，runtime 从私有 app-server 见到 TUI 线程就记下对话、写 ID 第一段（startup），第一轮的钩子不再加段；Claude 由 SessionStart 写同一段；两种 Agent 各跑一遍（fleet-agent-witness-selftest.py，这里按名守住）'
  SECS=$(since "$t0")
}
# ③ a reopen after a version update read as a new conversation (#4737)
drill_history_recovery_placement() {
  CAP=10; local t0
  t0=$(now)
  python3 "$BIN/fleet-history-recovery-selftest.py" || { WHY='history placement or identity regression'; return 1; }
  WHAT='历史按 FID 读，迁移后的原生 SID、目录与 Codex home 一起保留'
  SECS=$(since "$t0")
}

drill_reopen_new_segment() {
  CAP=10; local t0
  t0=$(now)
  grep -qF 'not _says_clear(agent)' "$BIN/fleet_id.py" \
    || { WHY="fleet_id.next_native no longer asks the adapter table whether an agent says /clear"; return 1; }
  suite_holds fleet-agent-witness-selftest.py "'reopen'" 'test_next_native_asks_the_table' || return 1
  WHAT='换版重开回到同一对话不加段（Codex 续接的线程是本次启动为它开的记 resume），/clear 记新一段；next_native 问表的 clear_said、不问名字；两种 Agent 各跑一遍（fleet-agent-witness-selftest.py）'
  SECS=$(since "$t0")
}

# task-start-unseen (T642): a task session that never came up is said on its ID and
# to its dispatcher, and no reader takes it for running — bin/start-visible-selftest.sh
# drives the wrapper on an isolated tmux server and the tick / await against a stub hub.
drill_task_start_unseen() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(bash "$BIN/start-visible-selftest.sh" 2>&1) || { WHY="$(printf '%s' "$out" | grep FAIL | head -3)"; return 1; }
  SECS=$(since "$t0")
  WHAT='开局几秒就退：ID 上「未起来：<原因>」、本机日志一行、不向父会话发送；同因不重复；起来了答「起来了」；旧 await 明确退役'
}

# ⌘P's resident panel gone (T890): the key's popup runs the connector, which must
# never wait on a server that is not there. Break it for real — a socket file left
# by a killed server (nobody listens) and a server that accepts and never answers —
# and the connector runs the Python panel itself, at once (50 ms connect, 1 s
# answer), with the keypress's --view / --client.
drill_panel_server_dead() {
  CAP=10; local t0 out
  t0=$(now)
  mkdir -p "$WORK/pnl" && chmod 700 "$WORK/pnl"
  out=$(FLEET_PANEL_SOCK_DIR="$WORK/pnl" python3 - "$BIN" 2>&1 <<'PY'
import importlib.util, os, socket, subprocess, sys, time
B = sys.argv[1]
spec = importlib.util.spec_from_file_location("ps", B + "/fleet-panel-server.py")
ps = importlib.util.module_from_spec(spec); spec.loader.exec_module(ps)
def attach(view):
    env = dict(os.environ, FLEET_PANEL_CTX="fl@view-%s|/dev/ttys9|@1|||||80" % view)
    t = time.time()
    out = subprocess.run([sys.executable, B + "/fleet-panel-server.py", "attach", "--", "sh", "-c", 'echo "FELL $*"', "x"],
                         env=env, capture_output=True, text=True, timeout=10).stdout.strip()
    return out, time.time() - t
# a socket nobody listens on
dead = socket.socket(socket.AF_UNIX); dead.bind(str(ps.sock_path("dead"))); dead.close()
out, secs = attach("dead")
assert out == "FELL --view fl@view-dead --client /dev/ttys9" and secs < 2, (out, secs)
# a server that takes the connection and never answers
hung = socket.socket(socket.AF_UNIX); hung.bind(str(ps.sock_path("hung"))); hung.listen(4)
out, secs = attach("hung")
assert out == "FELL --view fl@view-hung --client /dev/ttys9" and secs < 2, (out, secs)
# a probe — `status` / `ensure` connect and close, sending nothing — is not a ⌘P:
# the live server answered one with an exception and died (T890, first day)
class FV:
    view_fleet = staticmethod(lambda vid: "")
srv = ps.Server("p", None, FV())
a, b = socket.socketpair()
b.close()
srv.serve_conn(a)
print("ok")
PY
) || { WHY="a dead resident panel held ⌘P: $out"; return 1; }
  [ "$out" = ok ] || { WHY="dead panel: $out"; return 1; }
  suite_holds fleet-panel-server-selftest.sh 'C no server' 'G its 看台 gone' 'B0 a probe' || return 1
  SECS=$(since "$t0")
  WHAT='常驻面板死了（旧 socket 没人听）或卡住（收下连接不答）：连接器 2 秒内改走原来的 Python 面板，带着按键时的 --view / --client；一个只连不说的探问（status / ensure）不让它倒下；Go 连接器同一条由 agent/panel_test.go 守住'
}

# Home moved, panel changed (EPIC T644 C7): the operator moved the 看台's home from
# one machine to another and the first one's sessions lost their short codes and cached task facts
# — each machine's ID ledger is its own, and the panel read only this machine's.
# Now every machine keeps the hub's records in an ID cache (fleet-id.sh pull) and
# the panel reads that: home A shows B's independent task rows exactly as home B does.
drill_home_moved_panel_differs() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-view-home-selftest.sh" 2>&1) || { WHY="$(printf '%s' "$out" | grep -v '^ok' | tail -4)"; return 1; }
  SECS=$(since "$t0")
  WHAT='家在 A、会话在 B：短码、名字、单一状态位与平铺任务行逐行相同；缓存没有先占位、后台补齐；hub 不答照旧缓存画'
}

# ⌘P's ↑ walked its own loop (T762): it skipped ✦ 消息 and went round to ⚡, so four
# rows were never reached and ↑ was not ↓'s way back. Break it for real — a nav_step
# that skips a row — and the one-order check sees it; the popup steps through
# nav_step only, with no row named in its arrow handler.
drill_panel_order_split() {
  CAP=10; local t0 out
  t0=$(now)
  out=$(FLEET_CONF_DIR="$WORK/panel-order" FLEET_UI_LANG=zh python3 - "$BIN" 2>&1 <<'PY'
import importlib.util, sys
B = sys.argv[1]
spec = importlib.util.spec_from_file_location("fv", B + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
fv.notices_row = lambda q: {"kind": "cmd", "cmd": "notices", "act": "notices", "row": {}, "text": "✦ 消息"}
fv.lang_row = lambda q: None
items = [{"kind": "hdr", "group": "work", "text": "在干活 2"},
         {"kind": "sess", "target": "@1", "text": "a", "group": "work"},
         {"kind": "sess", "target": "@2", "text": "b", "group": "work"},
         {"kind": "sec", "sec": "gone", "text": "已收起 1 个", "n": 1, "older": 0}]
def one_order(step, shown):
    stops = [i for i, e in enumerate(shown) if fv.pickable(e)]
    for k, at in enumerate(stops):
        if step(shown, at, 1) != stops[(k + 1) % len(stops)] or step(shown, at, -1) != stops[k - 1]:
            return False
    return True
shown = fv.panel_rows(items, "", set(), cmds=["new", "quit"])
assert [e.get("cmd") for e in shown[:3]] == ["notices", "new", "home"], shown[:3]
assert shown[-1].get("cmd") == "quit", shown[-1]
assert one_order(fv.nav_step, shown), "the live nav_step is not one order"
def broken(sh, at, d):       # the old ↑: skip ✦ 消息, round to ⚡
    if d > 0:
        return fv.nav_step(sh, at, d)
    sel = [i for i, e in enumerate(sh) if fv.pickable(e)]
    up = [i for i in sel if i < at and sh[i].get("cmd") != "notices"]
    return up[-1] if up else next(i for i, e in enumerate(sh) if e.get("cmd") == "new")
assert not one_order(broken, shown), "a skipping ↑ passed the one-order check"
src = open(B + "/fleet_view.py", encoding="utf-8").read()
h = src[src.index('if ch in (curses.KEY_UP, "\\x10", curses.KEY_DOWN, "\\x0e"):'):]
h = h[:h.index("continue")]
assert "nav_step(" in h and '"notices"' not in h and "bolt_at" not in h, h
print("ok")
PY
) || { WHY="one order broke: $out"; return 1; }
  [ "$out" = ok ] || { WHY="one order: $out"; return 1; }
  suite_holds fleet-view-selftest.sh 'ONE order (T762)' 'fv.nav_step(shown, at, -1)' || return 1
  WHAT='⌘P 只有一份行序：画在屏幕上的顺序就是 ↓ 走的顺序、↑ 原路倒回、首尾相接（nav_step）；把 ↑ 改回「跳过 ✦ 消息、绕到 ⚡」的实测被一份行序检查认出；箭头键只经 nav_step，不点名任何一行（fleet-view-selftest.sh 的 ONE order 腿按名守住）'
  SECS=$(since "$t0")
}

drill_task_cancel_start_race() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-dispatch-current-selftest.py" >"$WORK/task-cancel-start.log" 2>&1 || {
    WHY="cancelled dispatch reached launch: $(tail -4 "$WORK/task-cancel-start.log")"; return 1;
  }
  WHAT='取消后的旧派发不能通过节点与包装器启动前检查；未知授权拒绝启动'
  SECS=$(since "$t0")
}

drill_task_claim_historical_identity() {
  local t0; t0=$(now); CAP=120
  (cd "$ROOT/tokenledger" && go test ./hub/store -run '^TestTaskExecutionClaimRejectsHistoricalIdentity$' -count=1) >"$WORK/task-claim-history.log" 2>&1 || {
    WHY="historical worker identity was claimed: $(tail -8 "$WORK/task-claim-history.log")"; return 1;
  }
  WHAT='旧 worker、Task FID 与会话账本归属不能被新任务领取覆盖'
  SECS=$(since "$t0")
}

drill_restore_execution_identity() {
  local t0; t0=$(now); CAP=60
  python3 "$BIN/fleet-restore-execution-selftest.py" >"$WORK/restore-execution.log" 2>&1 || {
    WHY="restore bypassed execution identity: $(tail -6 "$WORK/restore-execution.log")"; return 1;
  }
  WHAT='隔离 tmux：停止记录、缺失数据库、损坏协议及写身份失败均不启动；旧会话恢复不变，协议随 FID 入快照'
  SECS=$(since "$t0")
}

drill_native_cancel_before_signal() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-native-stop-order-selftest.py" >"$WORK/native-stop-order.log" 2>&1 || {
    WHY="native cancel ordering regression: $(tail -8 "$WORK/native-stop-order.log")"; return 1;
  }
  WHAT='本地无 journal 停止同事务固定双时钟，重放不延长，共同入口只取消一次，未知或外部强停不阻挡退出'
  SECS=$(since "$t0")
}

drill_native_partial_admission() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-task-partial-exit-selftest.py" >"$WORK/native-partial.log" 2>&1 || {
    WHY="partial admission regression: $(tail -8 "$WORK/native-partial.log")"; return 1;
  }
  WHAT='正向启动协议与认证原 start：新 partial 逐根退出，旧历史、缺 child、活根和身份未知均拒绝'
  SECS=$(since "$t0")
}

drill_native_exit_identity() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-task-session-exit-selftest.py" \
    SessionExitTests.test_real_timezone_change_is_not_pid_reuse \
    SessionExitTests.test_real_zombie_birth_is_exit_without_executable_lookup \
    SessionExitTests.test_legally_archived_partial_epoch_can_exit \
    SessionExitTests.test_real_live_pid_with_missing_procfs_cannot_prove_exit \
    SessionExitTests.test_missing_kernel_record_requires_second_absence_probe \
    >"$WORK/native-exit-identity.log" 2>&1 || {
      WHY="native exit identity regression: $(tail -8 "$WORK/native-exit-identity.log")"; return 1;
    }
  WHAT='真实存活 PID 的时区变化或不可见 procfs 不能证明退出；内核僵尸可确认退出；历史部分启动不永久阻挡接续'
  SECS=$(since "$t0")
}

drill_native_exit_submit_replay() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-task-exit-submit-selftest.py" \
    >"$WORK/native-exit-submit.log" 2>&1 || {
      WHY="native exit submission regression: $(tail -8 "$WORK/native-exit-submit.log")"; return 1;
    }
  WHAT='隔离 journal：证明持久化后崩溃、响应丢失原包重发、并发结果更新保包、未知登记不提交'
  SECS=$(since "$t0")
}

drill_task_stop_entry() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-task-stop-entry-selftest.py" >"$WORK/task-stop-entry.log" 2>&1 || {
    WHY="task stop entry regression: $(tail -10 "$WORK/task-stop-entry.log")"; return 1;
  }
  WHAT='Task stop 跨 Web/tmux/CLI 持久撤销，离线可受理，未知不降级，普通关闭不冒充原生退出'
  SECS=$(since "$t0")
}

drill_task_unclaimed_stop_proof() {
  local t0; t0=$(now); CAP=120
  (cd "$ROOT/tokenledger" && go test ./hub/store ./hub/api -run '^TestTaskUnclaimedStop' -count=1) >"$WORK/task-unclaimed-stop.log" 2>&1 || {
    WHY="unclaimed stop proof failed: $(tail -8 "$WORK/task-unclaimed-stop.log")"; return 1;
  }
  WHAT='未领取启动的 canonical stop 独立确认；真实 claim/stop 竞态、丢 ACK、历史与伪造关联均不误报原生退出'
  SECS=$(since "$t0")
}


drill_task_continue_unclaimed() {
  local t0; t0=$(now); CAP=120
  (cd "$ROOT/tokenledger" && go test ./hub/api ./hub/store -run '^TestTaskContinueUnclaimed' -count=1) >"$WORK/task-continue-unclaimed.log" 2>&1 || {
    WHY="unclaimed continuation regression: $(tail -8 "$WORK/task-continue-unclaimed.log")"; return 1;
  }
  WHAT='未 claim 的明确继续：严格停止证明、逐代历史与工作区来源；并发幂等不重复授权，原生退出与未启动不混用'
  SECS=$(since "$t0")
}


drill_task_continuation_start() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-task-continuation-start-selftest.py" >"$WORK/task-continuation-start.log" 2>&1 || {
    WHY="continuation startup regression: $(tail -10 "$WORK/task-continuation-start.log")"; return 1;
  }
  WHAT='同 Task 新 FID 续做；认证原 start 与退出回执找回原工作树和历史，旧窗口不吞新启动'
  SECS=$(since "$t0")
}

drill_task_local_continuation() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-task-local-continuation-selftest.py" \
    >"$WORK/task-local-continuation.log" 2>&1 || {
      WHY="local continuation regression: $(tail -10 "$WORK/task-local-continuation.log")"; return 1;
    }
  WHAT='显式新授权与原ACK证明共同接续；旧FID仍停止，同grant同分配，第二轮退出证明独立'
  SECS=$(since "$t0")
}

drill_codex_no_daemon_fence() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-codex-no-daemon-fence-selftest.py" >"$WORK/codex-no-daemon-fence.log" 2>&1 || {
    WHY="Codex no-daemon admission regression: $(tail -10 "$WORK/codex-no-daemon-fence.log")"; return 1;
  }
  WHAT='受控 no-daemon 经原生栅栏登记Codex client，停止后不exec；非受控argv不变'
  SECS=$(since "$t0")
}

drill_task_unclaimed_node() {
  local t0; t0=$(now); CAP=60
  python3 "$BIN/fleet-task-unclaimed-continuation-selftest.py" >"$WORK/task-unclaimed-node.log" 2>&1 || {
    WHY="unclaimed node regression: $(tail -10 "$WORK/task-unclaimed-node.log")"; return 1;
  }
  WHAT='未领取继续仅退休纯分配；真实登记拒绝，旧FID保留停止事实，新分配仍需明确授权'
  SECS=$(since "$t0")
}


drill_task_continue_authority() {
  local t0; t0=$(now); CAP=120
  (cd "$ROOT/tokenledger" && go test ./hub/api ./hub/store -run '^TestTaskContinue' -count=1) >"$WORK/task-continue.log" 2>&1 || {
    WHY="explicit continuation authority regression: $(tail -8 "$WORK/task-continue.log")"; return 1;
  }
  WHAT='真实 Hub API 与 SQLite：停止证明、同端点、精确幂等、并发 provider、旧回执及失联节点均受新授权约束'
  SECS=$(since "$t0")
}

drill_task_stop_replay_cleanup() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-task-execution-control-selftest.py" \
    ControlExecutionTests.test_canonical_stop_redelivery_retries_failed_and_successful_cleanup \
    ControlExecutionTests.test_stop_replay_does_not_run_parallel_cleanup_and_recovers_executor_death \
    ControlExecutionTests.test_stop_survives_executor_launch_failure_and_retries \
    >"$WORK/task-stop-replay.log" 2>&1 || {
      WHY="canonical stop replay failed: $(tail -5 "$WORK/task-stop-replay.log")"; return 1;
    }
  WHAT='真实 detached executor：清理失败重投、重复投递不并发、SIGKILL 后重试及启动失败恢复；回执不冒充全域退出'
  SECS=$(since "$t0")
}

drill_private_preview_isolation() {
  CAP=180; local t0; t0=$(now)
  term_go 'TestPreviewHostsCookiesAndReturn TestPreviewAuthFlow TestPreviewSignedOutOAuthReturn TestPreviewTrialAndDisabled TestPreviewReplicas TestPreviewIdentityAndGeneration TestPreviewHTTPStreamAndWebSocket TestPreviewSocketPaths' './hub/api ./hub/store ./e2e ./agent' \
    '私人实时预览：Host / cookie / callback / OAuth 返回 / 重放 / 双副本租约 / UID helper / POST / SSE / WS 撤销' || return 1
  SECS=$(since "$t0")
}

# ================================================================ run ====}


# A landing only GitHub could name (issue #3601, EPIC #3570 C8): with every gh call
# failing, a squash-merged session read `unmerged` — never reaped, never landed in
# history. git alone says it now: fleet_land_check's patch-id match → `landed`, and
# a repo with FLEET_FORGE=none never runs gh at all.
drill_land_squash_unseen() {
  CAP=30; local d="$WORK/lsu" t0 out
  mkdir -p "$d/fake"
  printf '#!/bin/sh\necho "gh $*" >> "%s/gh.log"; exit 1\n' "$d" > "$d/fake/gh"; chmod +x "$d/fake/gh"; : > "$d/gh.log"
  t0=$(now)
  out=$(cd "$d" && PATH="$d/fake:$PATH" FLEET_CONF_DIR="$d/conf" TMPDIR="$d" \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t bash -c '
    . "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_sockets() { :; }
    git init -q --bare o.git; git clone -q o.git m 2>/dev/null; cd m; git checkout -q -B main
    echo a > f; git add f; git commit -q -m base; git push -q origin main
    git checkout -q -b issue-7; echo b >> g; git add g; git commit -q -m one; echo c >> g; git commit -q -am two
    tip=$(git rev-parse HEAD); git checkout -q main; echo z >> f; git commit -q -am moved
    git merge -q --squash issue-7 >/dev/null 2>&1; git commit -q -m "squash (#7)"; git push -q origin main
    git worktree add -q ../wt issue-7 2>/dev/null
    printf "%s " "$(fleet_reap_ok ../wt . issue-7 "$tip" origin/main "")"
    fleet_landed acme/app issue-7 . main | cut -d" " -f1' _ "$BIN" 2>/dev/null)
  SECS=$(since "$t0")
  [ "$out" = "landed landed" ] || { WHY="a squash merge with gh failing reads [$out], not landed"; return 1; }
  [ ! -s "$d/gh.log" ] || { WHY="gh was called: $(head -1 "$d/gh.log")"; return 1; }
  WHAT="压成一个提交的合并、gh 一律失败：回收门判 landed，fleet_landed 认得落地，gh 0 次"
}

# The web chat's socket mode (issue #3643, EPIC #3642 C1): both drills run a part of
# bin/fleet-webchat-selftest.mjs, which does the break for real — a stale 0666 socket
# in a 0755 dir; the proxy's 403 person_budget_exceeded through a stub SDK.
# webchat_part <part> <line…> — its --only=<part> run: PASS and every `ok` line asked for
webchat_part() {
  local part="$1" out t0 want
  shift
  t0=$(now)
  out=$(node "$BIN/fleet-webchat-selftest.mjs" "--only=$part" 2>&1)
  SECS=$(since "$t0")
  printf '%s\n' "$out" | grep -q '^PASS fleet-webchat-selftest' \
    || { WHY="the webchat selftest's $part part is red: $(printf '%s\n' "$out" | grep '^FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  for want in "$@"; do
    printf '%s\n' "$out" | grep -qF "ok   $want" || { WHY="no «${want}» line: $(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')"; return 1; }
  done
  WEBCHAT_OUT=$out
}

drill_chat_codex_identity_pending() {
  CAP=30; local out t0
  t0=$(now)
  out=$(python3 "$BIN/fleet-session-gate-selftest.py" N 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT="原生身份未就绪不误判旧版，未知与不可达不投递；明确旧版本仍拒绝，同一身份就绪后恢复"
}

drill_chat_gate_cold_readonly() {
  CAP=30
  webchat_part gate "Y a cold view is checking, never read-only before the gate answers" || return 1
  WHAT="冷连接先发探测中，再由会话门明确允许发送；探测未完成不误报只读"
}

drill_chat_gate_probe_unavailable() {
  CAP=30
  webchat_part gate "Y a failed capability probe is unavailable, never a read-only verdict" \
    "Y capability failure after a writable frame recovers on the same stream" \
    "Y hung capability probe has a bound and stays unavailable" \
    "Y simultaneous readers share one capability probe for the same session" || return 1
  WHAT="能力探测失败明确暂不可达，同一流下一次成功恢复可写；只读权限不放宽"
}

drill_chat_view_stream_silent() {
  CAP=60; local t0 out rc
  t0=$(now)
  [ -f "$ROOT/extras/browser-transport/session-stream.mjs" ] || { WHY='missing silent-stream browser drill'; return 1; }
  if (cd "$ROOT/extras/browser-transport" && node --input-type=module -e 'import { chromium } from "playwright"; import { existsSync } from "node:fs"; process.exit(existsSync(chromium.executablePath()) ? 0 : 1)') >/dev/null 2>&1; then
    out=$(node "$ROOT/extras/browser-transport/session-stream.mjs" 2>&1); rc=$?
    [ "$rc" = 0 ] || { WHY="$out"; return 1; }
    [ "$(printf '%s\n' "$out" | grep -c '^PASS session-stream ')" = 4 ] || { WHY="missing browser cases: $out"; return 1; }
    WHAT='真实 HTTP SSE 不结束也不再传数据：45 秒后重连原会话游标，心跳续活，草稿保留、不自动发送、只读票据仍不可写'
  else
    WHAT='这里没有 Playwright Chromium；browser-attachment 门运行真实 HTTP SSE 悬流演练'
  fi
  SECS=$(since "$t0")
}

drill_chat_view_identity_unavailable() {
  CAP=60; local t0 out
  t0=$(now)
  [ -f "$ROOT/extras/browser-transport/session-write.mjs" ] || { WHY='missing identity recovery browser drill'; return 1; }
  if (cd "$ROOT/extras/browser-transport" && node --input-type=module -e 'import { chromium } from "playwright"; import { existsSync } from "node:fs"; process.exit(existsSync(chromium.executablePath()) ? 0 : 1)') >/dev/null 2>&1; then
    out=$(node "$ROOT/extras/browser-transport/session-write.mjs" 2>&1) || { WHY="$out"; return 1; }
    printf '%s\n' "$out" | grep -q '^PASS session-write codex identity' || { WHY="missing identity recovery case: $out"; return 1; }
    WHAT='登录身份首次503、会话能力为true：仍禁发，身份恢复后保留草稿并允许主动发送；只读票据始终禁发'
  else
    WHAT='这里没有 Playwright Chromium；browser-attachment 门运行身份503恢复演练'
  fi
  SECS=$(since "$t0")
}

drill_codex_release_shadowed() {
  CAP=30; SECS=0
  suite_holds fleet-codex-selftest.sh 'F4 managed release Codex wins over a stale CLI earlier on PATH' || return 1
  WHAT="发行树的固定 Codex 优先于 PATH 前面的旧版；tmux 保护 shim 保持首位，direct webchat 同样选发行版"
}

drill_codex_receipt_race() {
  CAP=30; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-session-gate-selftest.py" O P 2>&1) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT="Codex 取走队列后延迟写回收据：仍等待原 delivery，晚到收据成功；真正消失有界退回，绝不重加"
}

drill_codex_pin_displaces_guard() {
  CAP=30; SECS=0
  suite_holds fleet-codex-selftest.sh 'F4 managed release Codex wins over a stale CLI earlier on PATH' || return 1
  WHAT="发行版 Codex 优先时，agent 子进程仍先解析到 tmux 保护 shim"
}

drill_chat_socket_other_login() {
  CAP=30
  if ! command -v node >/dev/null 2>&1; then SECS=0; WHAT="SKIP：这里没有 node"; return 0; fi
  webchat_part socket "H the socket is 0600" "H its dir is 0700" "H no admin.token, no port file" \
    "H no --socket, no FLEET_WEBCHAT_LOCAL=1: it does not start" "H a second server on a live socket refuses" || return 1
  WHAT="0755 目录里放一个 0666 的旧 socket 再起对话服务：socket 回到 0600、目录 0700，没有 admin.token / 端口；不带 --socket 也没 FLEET_WEBCHAT_LOCAL=1 就不起"
  if printf '%s\n' "$WEBCHAT_OUT" | grep -qF 'ok   H (control)'; then
    printf '%s\n' "$WEBCHAT_OUT" | grep -qF 'ok   H another uid cannot connect even through' \
      || { WHY="another uid connected through the 0600 socket"; return 1; }
    WHAT="${WHAT}；nobody 连不上（放开到 0666 时它连得上）"
  fi
}

drill_chat_budget_bypass() {
  CAP=30
  if ! command -v node >/dev/null 2>&1; then SECS=0; WHAT="SKIP：这里没有 node"; return 0; fi
  webchat_part budget "I the proxy's 403 is one" "I the raw API error never reaches the page" \
    "I /api/conversation says blocked, until" "I still blocked after a restart" "I … and the block is lifted" || return 1
  WHAT="凭据代理 403 person_budget_exceeded：流里一行 code:budget + until，原话不上页面；/api/conversation 说被挡（重启也记得），走通一轮后放开"
}

# chat-file-escape (task T773 ②): a reply's link to a file on the home is the one
# road from the entry to the home's disk — a key, a secret's name, a link out of
# $HOME, a file swapped for one after the ref was given, an HTML file run on the
# entry's site: none of them may get through.
drill_chat_file_escape() {
  CAP=30
  if ! command -v node >/dev/null 2>&1; then SECS=0; WHAT="SKIP：这里没有 node"; return 0; fi
  webchat_part links "Q live: a ref for the three files under" "Q the refs are opaque" "Q an HTML file is only a download" \
    "Q a ref nobody was given: 404" "Q a file that became a link out of \$HOME is refused at the read" "Q refs.json is 0600" "Q an expired ref says so" || return 1
  WHAT="回复里的本机文件链接：钥匙 / .env / 链出 \$HOME / 不存在的不给号；号是不透明的；HTML 只下载（sandbox）；读时再认（换成软链的拒）；过期 410"
}

# chat-claude-bare-path (issue #3648, EPIC #3642 C6): the daemon starts the chat
# service with a bare PATH (no ~/.local/bin); the SDK is installed without its
# native binary, so a service that could not find the login's own claude failed
# EVERY turn with «Native CLI binary for darwin-arm64 not found». serve now finds it
# the way fleet_find_tool does (pin · PATH · ~/.local/bin · brew · /usr/local).
drill_chat_claude_bare_path() {
  CAP=20; local d="$WORK/ccb" t0 out
  t0=$(now)
  mkdir -p "$d/home/.local/bin" "$d/tools" "$d/conf/webchat/deps/node_modules/@anthropic-ai/claude-agent-sdk"
  printf '#!/bin/sh\nexit 0\n' > "$d/home/.local/bin/claude"
  printf '#!/bin/sh\nexit 0\n' > "$d/tools/npm"
  printf '#!/bin/sh\nprintf %%s "$FLEET_WEBCHAT_CLAUDE" > "%s/claude.seen"\n' "$d" > "$d/tools/node"
  chmod +x "$d/home/.local/bin/claude" "$d/tools/npm" "$d/tools/node"
  : > "$d/conf/webchat/deps/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"
  cp "$ROOT/extras/web-chat/package-lock.json" "$d/conf/webchat/deps/"
  env -i HOME="$d/home" PATH="$d/tools:/usr/bin:/bin" FLEET_CONF_DIR="$d/conf" \
    bash "$ROOT/bin/fleet-webchat.sh" serve >/dev/null 2>&1
  out=$(cat "$d/claude.seen" 2>/dev/null)
  [ "$out" = "$d/home/.local/bin/claude" ] \
    || { WHY="serve on a bare PATH handed the server claude=«${out}», not ~/.local/bin/claude"; return 1; }
  out=$(env -i HOME="$d/home" PATH="/usr/bin:/bin" FLEET_CONF_DIR="$d/conf" bash "$ROOT/bin/fleet-webchat.sh" status 2>&1)
  case "$out" in *"claude · $d/home/.local/bin/claude"*) ;; *) WHY="status does not name the claude it runs: $out"; return 1 ;; esac
  WHAT='守护给的 PATH 里没有 ~/.local/bin：serve 照样把本登录的 claude 交给对话服务，status 写明用的哪个'
  SECS=$(since "$t0")
}

# service-orphan-holds-socket (task BZGP, a managed Mac 2026-10-21): an old webchat
# server — a release switch left it, PPID 1, the old code path — kept answering
# on chat.sock, so the managed copy exited 3 every 30 s («已退出·待重启» on the
# bar). serve now stops an orphan of the service first (TERM, then KILL), and
# names any other holder instead of only exiting.
drill_service_orphan_holds_socket() {
  CAP=20; local d t0 hp reaper out
  d=$(mktemp -d /tmp/bzgp.XXXXXX) || { WHY="no temp dir"; return 1; }
  t0=$(now)
  mkdir -p "$d/home" "$d/tools" "$d/conf/webchat/deps/node_modules/@anthropic-ai/claude-agent-sdk"
  chmod 700 "$d/conf/webchat"
  printf '#!/bin/sh\nexit 0\n' > "$d/tools/npm"
  printf '#!/bin/sh\necho started > "%s/node.ran"\n' "$d" > "$d/tools/node"
  chmod +x "$d/tools/npm" "$d/tools/node"
  : > "$d/conf/webchat/deps/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"
  cp "$ROOT/extras/web-chat/package-lock.json" "$d/conf/webchat/deps/"
  printf '%s\n' 'import os, signal, socket, sys' 'signal.alarm(60)' \
    's = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)' \
    'open(sys.argv[2], "w").write("%d\n" % os.getpid())' \
    'while True:' '    c, _ = s.accept(); c.close()' > "$d/old.py"
  ( python3 "$d/old.py" "$d/conf/webchat/chat.sock" "$d/conf/webchat/pid" \
      /old/runtime/extras/web-chat/server.mjs --socket </dev/null >/dev/null 2>&1 & )
  for _ in $(seq 1 50); do [ -s "$d/conf/webchat/pid" ] && break; sleep 0.1; done
  hp=$(cat "$d/conf/webchat/pid" 2>/dev/null)
  [ -n "$hp" ] || { WHY="the old orphan did not come up"; rm -rf "$d"; return 1; }
  reaper=$(ps -o ppid= -p "$hp" | tr -d ' ')
  out=$(env -i HOME="$d/home" PATH="$d/tools:/usr/bin:/bin" FLEET_CONF_DIR="$d/conf" \
        FLEET_SERVICE_TAKEOVER_REAPER="$reaper" FLEET_SERVICE_TAKEOVER_WAIT=2 \
        bash "$ROOT/bin/fleet-webchat.sh" serve 2>&1)
  if kill -0 "$hp" 2>/dev/null; then kill -9 "$hp" 2>/dev/null; WHY="the old orphan still holds the socket: $out"; rm -rf "$d"; return 1; fi
  [ -f "$d/node.ran" ] || { WHY="serve did not start the server after the takeover: $out"; rm -rf "$d"; return 1; }
  case "$out" in *"停掉了旧孤儿（pid ${hp} · "*) ;; *) WHY="serve did not say what it stopped: $out"; rm -rf "$d"; return 1 ;; esac
  rm -rf "$d"
  WHAT='旧版留下的对话服务孤儿（PPID 1）占着 chat.sock：serve 先停掉它（TERM，不走再 KILL）、说清停了谁，再起受管的那份'
  SECS=$(since "$t0")
}

# service-orphan-shell-holds-socket (task CVC4, a managed Mac 2026-10-21): the old
# copy's node child was NOT itself an orphan — its `fleet-webchat.sh serve`
# shell was (PPID 1), the node under it still answering chat.sock — so BZGP's
# takeover called it «不是本服务的孤儿» and the managed copy exited 3 for hours.
# serve now walks the holder's parents: an init-adopted ancestor whose argv is
# the service's shell (fleet-webchat.sh serve, our uid) makes it an orphan too.
drill_service_orphan_shell_holds_socket() {
  CAP=20; local d t0 hp sp reaper out
  d=$(mktemp -d /tmp/cvc4.XXXXXX) || { WHY="no temp dir"; return 1; }
  t0=$(now)
  mkdir -p "$d/home" "$d/tools" "$d/old/bin" "$d/conf/webchat/deps/node_modules/@anthropic-ai/claude-agent-sdk"
  chmod 700 "$d/conf/webchat"
  printf '#!/bin/sh\nexit 0\n' > "$d/tools/npm"
  printf '#!/bin/sh\necho started > "%s/node.ran"\n' "$d" > "$d/tools/node"
  chmod +x "$d/tools/npm" "$d/tools/node"
  : > "$d/conf/webchat/deps/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"
  cp "$ROOT/extras/web-chat/package-lock.json" "$d/conf/webchat/deps/"
  printf '%s\n' 'import os, signal, socket, sys' 'signal.alarm(60)' \
    's = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)' \
    'open(sys.argv[2], "w").write("%d\n" % os.getpid())' \
    'while True:' '    c, _ = s.accept(); c.close()' > "$d/old.py"
  # the old copy: its serve shell, the server its child (not exec'd)
  printf '#!/bin/bash\npython3 "%s" "%s" "%s" /old/runtime/extras/web-chat/server.mjs --socket\n: done\n' \
    "$d/old.py" "$d/conf/webchat/chat.sock" "$d/conf/webchat/pid" > "$d/old/bin/fleet-webchat.sh"
  ( bash "$d/old/bin/fleet-webchat.sh" serve </dev/null >/dev/null 2>&1 & )
  for _ in $(seq 1 50); do [ -s "$d/conf/webchat/pid" ] && break; sleep 0.1; done
  hp=$(cat "$d/conf/webchat/pid" 2>/dev/null)
  [ -n "$hp" ] || { WHY="the old copy did not come up"; rm -rf "$d"; return 1; }
  sp=$(ps -o ppid= -p "$hp" | tr -d ' ')
  reaper=$(ps -o ppid= -p "$sp" | tr -d ' ')
  out=$(env -i HOME="$d/home" PATH="$d/tools:/usr/bin:/bin" FLEET_CONF_DIR="$d/conf" \
        FLEET_SERVICE_TAKEOVER_REAPER="$reaper" FLEET_SERVICE_TAKEOVER_WAIT=2 \
        bash "$ROOT/bin/fleet-webchat.sh" serve 2>&1)
  if kill -0 "$hp" 2>/dev/null; then kill -9 "$hp" "$sp" 2>/dev/null; WHY="the old copy still holds the socket: $out"; rm -rf "$d"; return 1; fi
  for _ in $(seq 1 25); do kill -0 "$sp" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$sp" 2>/dev/null; then kill -9 "$sp" 2>/dev/null; WHY="the old serve shell still runs: $out"; rm -rf "$d"; return 1; fi
  [ -f "$d/node.ran" ] || { WHY="serve did not start the server after the takeover: $out"; rm -rf "$d"; return 1; }
  case "$out" in *"停掉了旧孤儿（pid ${hp} · "*) ;; *) WHY="serve did not say what it stopped: $out"; rm -rf "$d"; return 1 ;; esac
  rm -rf "$d"
  WHAT='旧副本的 serve 壳成了孤儿（PPID 1）、它的 node 子进程还占着 chat.sock：serve 沿父链认出是本服务留下的，停掉 node 和壳、说清停了谁，再起受管的那份'
  SECS=$(since "$t0")
}

# webchat-turn-cut-by-restart (task WD8F, a person's web chat 2026-10-22): the
# web chat's server went at every release and every takeover with a turn half
# answered — the takeover TERMed the old copy after 10 s, a stop SIGKILLs the
# group after 5 — and the page then showed Claude Code's raw <task-notification>
# as the person's bubble and a lone «No response requested.». Now the takeover
# asks the old copy over its own socket (--busy /api/busy) and waits while it
# answers; a turn cut off anyway is said on the next start with 重试; the notice
# is one quiet line; and 新对话 mid-answer puts the turn aside instead of a 409.
drill_webchat_helper_stale_release() {
  CAP=20; local t0
  t0=$(now)
  webchat_part release "Z resident service initially calls release A gate" \
    "Z same process calls release B gate after stable switch" \
    "Z new session uses current release launcher after stable switch" || return 1
  WHAT='同一网页服务跨 stable A→B，后续 gate 与新建都用当前发行版，不丢会话或重复投递'
  SECS=$(since "$t0")
}

drill_webchat_turn_cut_by_restart() {
  CAP=60; local t0
  t0=$(now)
  grep -q -- '--busy /api/busy --busy /api/state' "$ROOT/bin/fleet-webchat.sh" \
    || { WHY="fleet-webchat.sh serve no longer asks the old copy whether it is answering (--busy)"; return 1; }
  suite_holds fleet-service-takeover-selftest.sh 'J: a busy orphan is taken over once idle' 'K: an orphan that cannot say' || return 1
  if ! command -v node >/dev/null 2>&1; then SECS=$(since "$t0"); WHAT="SKIP：这里没有 node（接管等忙的那一半按名守住）"; return 0; fi
  webchat_part aside "U 新对话 mid-answer is not refused (200)" "U …and ends with its answer, never stopped" \
    "U a turn cut off is said on the next start, with its words" "U a task notice reads as one note" \
    "U …never the raw XML as the person's bubble, never the filler" || return 1
  WHAT='旧副本正答着一轮时接管：先问它忙不忙、答完再停（fleet-service-takeover-selftest.sh J/K 按名守住）；回复中途点新对话：200、新对话立刻空着能用、旧一轮在后台答完；被停掉的一轮下次起来说清楚并带原话可重试；后台任务通知折成一行，不再当用户气泡、不再出 No response requested.'
  SECS=$(since "$t0")
}

# service-alert-flaps (task CVC4): a service the daemon restarts every few
# minutes raised and cleared service_failed once each per restart (7 and 7 in
# 37 minutes). The hub now holds a run 10 minutes each way — Go
# (TestServiceAlertHoldsTenMinutes), held by name, run when a toolchain is here.
drill_service_alert_flaps() {
  CAP=120; local t0
  t0=$(now)
  grep -q '^func TestServiceAlertHoldsTenMinutes(' "$ROOT/tokenledger/hub/api/fleet_services_test.go" 2>/dev/null \
    || { WHY="the hub's test TestServiceAlertHoldsTenMinutes is gone"; return 1; }
  go_half '^TestServiceAlertHoldsTenMinutes$' ./hub/api; case $? in
    0) WHAT='失败 / 恢复交替 30 分钟：0 条 service_failed；连着失败满 10 分钟起一条，连着好满 10 分钟落一次' ;;
    1) return 1 ;;
    *) WHAT='这台没有 Go 工具链 / 模块缓存：测试按名核对在，Go 门（tokenledger.yml）跑它' ;;
  esac
  SECS=$(since "$t0")
}

drill_chat_home_moved() {
  CAP=40
  if ! command -v node >/dev/null 2>&1; then SECS=0; WHAT="SKIP：这里没有 node"; return 0; fi
  webchat_part home,idle "J under B: the same session, its cwd B's home" "J under B: the history is on the page" \
    "J the next turn under B resumes the same session" "J nothing of the service is left under A" \
    "K nothing open: it exits 75" "K started again: the same conversation" || return 1
  WHAT="A 家说一句、停掉、状态目录照 service move 搬到 B 家：B 上同一个 session、历史在、下一轮 resume 它，A 下面不剩服务；空闲到点退出 75（有页面连着不退），再起同一条对话"
}

# chat-relay-wrong-person (issue #3644, EPIC #3642 C2): the node half of the chat
# relay admits a stream only after the hub's X-Fleet-Person verifies with THIS
# login's token hash, for this login and this relay, unexpired — anything else
# closes it and the login's socket never sees a byte; nothing the hub sends can
# change the target; an agent without CapChat is never sent an open. All of it is
# Go (tokenledger/e2e chat_relay_test.go, a real agent, a real unix
# socket): held by name, run when a toolchain is here.
drill_chat_relay_wrong_person() {
  CAP=180; local t0 out rc api ctl agt
  api='TestChatRelayWrongPersonNeverReachesTheSocket TestChatRelayTargetIsFixed TestChatRelayNotSentWithoutCapChat TestChatRelayReachesTheLoginsSocket'
  ctl='TestChatPerson'; agt='TestChatPipe'
  t0=$(now)
  for out in $api; do
    grep -q "^func $out(" "$ROOT/tokenledger/e2e/chat_relay_test.go" 2>/dev/null || { WHY="the hub half's test $out is gone"; return 1; }
  done
  grep -q "^func $ctl(" "$ROOT/tokenledger/shared/control/chat_relay_test.go" 2>/dev/null || { WHY="the statement's test $ctl is gone"; return 1; }
  grep -q "^func $agt(" "$ROOT/tokenledger/agent/node_chat_relay_test.go" 2>/dev/null || { WHY="the helper's test $agt is gone"; return 1; }
  # the open carries no target: ChatRelayOpen is relay_id · secret · login, nothing more
  out=$(awk '/^type ChatRelayOpen struct/,/^}/' "$ROOT/tokenledger/shared/control/chat_relay.go" | grep -c 'json:"')
  [ "$out" = 3 ] || { WHY="ChatRelayOpen has $out wire fields, want 3 (relay_id, secret, login)"; return 1; }
  go_half "^($(printf '%s %s %s' "$api" "$ctl" "$agt" | tr ' ' '|'))\$" ./e2e github.com/verkyyi/claude-fleet/tokenledger/shared/control github.com/verkyyi/claude-fleet/tokenledger/agent; case $? in
    0) WHAT='签错 / 过期 / 给别的转发 / 给别的登录 / 寿命过长 / 没有声明 / 先发字节 → 节点断开，socket 0 连接 0 字节；给别的登录的 open 不回拨；请求里塞 target/path/addr/port 只到本登录自己的 socket；没报 CapChat 的节点不收 open（NO_CHAT）' ;;
    1) return 1 ;;
    2) WHAT='这台没有 Go 模块缓存 / 工具链——Go 门（tokenledger.yml）跑这几条；测试按名核对在、open 没有目标字段' ;;
    3) WHAT='没有 go：测试按名核对在、open 没有目标字段，Go 门（tokenledger.yml）跑它们' ;;
  esac
  SECS=$(since "$t0")
}

# chat-first-open-cold (issue #3648, EPIC #3642 C6): the first /chat on a home
# whose service never ran — the relay found no socket and nothing started it
# (#3647's ensure had no caller): the page said «did not answer». The node's relay
# now runs the fixed `service ensure --name webchat --wait 3` for its own login
# and dials again. Go (tokenledger/agent TestChatSockEnsuresOnDemand), run when a
# toolchain is here.
drill_chat_first_open_cold() {
  CAP=120; local t0 out rc f="$ROOT/tokenledger/agent/node_chat_relay.go"
  t0=$(now)
  grep -q '^func TestChatSockEnsuresOnDemand(' "$ROOT/tokenledger/agent/node_chat_relay_test.go" 2>/dev/null \
    || { WHY="the test TestChatSockEnsuresOnDemand is gone"; return 1; }
  grep -q 'a.chatSockOrEnsure(ctx, dctx, login' "$f" 2>/dev/null \
    || { WHY="openChatRelay dials the socket without chatSockOrEnsure: a cold home never starts"; return 1; }
  go_half '^TestChatSockEnsuresOnDemand$' github.com/verkyyi/claude-fleet/tokenledger/agent; case $? in
    0) WHAT='没有 socket：机器节点以本登录跑 service ensure --name webchat --wait 3 再拨一次，起来了就接上；在跑的不 ensure；普通节点只拨一次' ;;
    1) return 1 ;;
    2) WHAT='这台没有 Go 模块缓存 / 工具链——Go 门（tokenledger.yml）跑它；测试按名核对在、转发经 chatSockOrEnsure' ;;
    3) WHAT='没有 go：测试按名核对在、转发经 chatSockOrEnsure，Go 门（tokenledger.yml）跑它' ;;
  esac
  SECS=$(since "$t0")
}

# chat-relay-replica-hop (issue #3847, EPIC #3642 C6 真机一轮): with two entry
# replicas the person's /chat landed on the one not holding their login's link
# («连不上»), and the node's data half, landing on the replica that did not open
# the relay, was verified THERE first — its FleetSig nonce spent — and then
# refused as a replay by the holder (401). Now a chat request is handed whole to
# the holder (chatRelayPeer) and a data half is handed on BEFORE it is verified
# (claimedEndpoint). Go (hub/api + e2e chat_relay_replica_test.go: two replicas, a
# front splitting the halves, a real signing agent), run when a toolchain is here.
drill_chat_relay_replica_hop() {
  CAP=180; local t0 out rc tests f="$ROOT/tokenledger/hub/api/ssh_relay.go"
  tests='TestChatRelayReplicaHop TestChatRelayReplicaNobodyHolds TestChatRelayReplicaSingleNeverProxies TestSSHRelayDataHalfOnOtherReplica'
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$ROOT"/tokenledger/hub/api/*_test.go "$ROOT"/tokenledger/e2e/*_test.go 2>/dev/null || { WHY="the test $out is gone"; return 1; }
  done
  # the data half is handed on before nodeEndpoint verifies (and spends) its signature
  local cl vl
  cl=$(awk '/^func \(s \*Server\) attachRelayData/,/^}/' "$f" | grep -n 'claimedEndpoint(r)' | head -1 | cut -d: -f1)
  vl=$(awk '/^func \(s \*Server\) attachRelayData/,/^}/' "$f" | grep -n 's.nodeEndpoint(w, r)' | head -1 | cut -d: -f1)
  [ -n "$cl" ] && [ -n "$vl" ] && [ "$cl" -lt "$vl" ] \
    || { WHY="attachRelayData verifies before it hands a data half on (a replica spends the nonce the holder needs)"; return 1; }
  grep -q 's.chatRelayPeer(r, home.Machine, home.Login)' "$ROOT/tokenledger/hub/api/fleet_chat.go" 2>/dev/null \
    || { WHY="the chat routes never hand a request to the replica holding the login's link"; return 1; }
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='两副本：人的 /chat 落在不持链的副本 → 整个请求交给持链副本；节点签名的回拨落在另一副本 → 验签前转过去，nonce 只花一次；没人持链照答 home_down；单入口不转' ;;
    1) return 1 ;;
    2) WHAT='这台没有 Go 模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；测试按名核对在、回拨先转后验、对话路由经 chatRelayPeer' ;;
    3) WHAT='没有 go：测试按名核对在、回拨先转后验、对话路由经 chatRelayPeer，Go 门（tokenledger.yml）跑它们' ;;
  esac
  SECS=$(since "$t0")
}

# term_go <tests> <pkgs> <what-ok> — the browser terminal's Go drills (issue
# #3838): each test held by name, run when a toolchain and module cache are here.
term_go() {
  local tests="$1" pkgs="$2" ok="$3" out rc t
  for t in $tests; do
    grep -q "^func $t(" "$ROOT"/tokenledger/hub/api/*_test.go "$ROOT"/tokenledger/hub/store/*_test.go "$ROOT"/tokenledger/e2e/*_test.go "$ROOT"/tokenledger/agent/*_test.go \
      "$ROOT"/tokenledger/shared/control/*_test.go "$ROOT"/tokenledger/shared/attachment/*_test.go \
      "$ROOT"/tokenledger/agent/door/*_test.go 2>/dev/null || { WHY="the test $t is gone"; return 1; }
  done
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    # shellcheck disable=SC2086 # pkgs is a word list
    out=$(cd "$ROOT/tokenledger" && GOFLAGS='' GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" $pkgs 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT=$ok ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT="这台没有 Go 模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；测试按名核对在" ;;
      *) WHY="the terminal relay (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | grep -v '^20[0-9][0-9]/' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
}

# A delayed transcript must not replace a turn started after that read.
drill_chat_late_history() {
  CAP=60; local t0 out rc
  t0=$(now)
  # Production useFleetChat in extras/web-console/src/app/chat/chat.ts and
  # extras/web-chat/ui/src/chat.ts; browser-attachment CI installs Chromium.
  [ -f "$ROOT/extras/browser-transport/chat-history.mjs" ] || { WHY='missing late-history browser drill'; return 1; }
  if (cd "$ROOT/extras/browser-transport" && node --input-type=module -e 'import { chromium } from "playwright"; import { existsSync } from "node:fs"; process.exit(existsSync(chromium.executablePath()) ? 0 : 1)') >/dev/null 2>&1; then
    out=$(node "$ROOT/extras/browser-transport/chat-history.mjs" 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { WHY="late history replaced a new turn: $out"; return 1; }
    WHAT='迟到的旧对话不抹掉已完成的新消息；官网和本地各只提交一次'
  else
    WHAT='无 Playwright/Chromium：browser-attachment 门运行真实页面演练'
  fi
  SECS=$(since "$t0")
}

# chat-copy-order (task Y393): the entry's copy that lands after the home's answer
# never puts the older conversation back, two reads finishing out of order never
# leave the older copy, and a second browser of the person follows the first.
drill_chat_copy_order() {
  CAP=180; local t0 out rc
  t0=$(now)
  grep -q 'homeSeen.current' "$ROOT/extras/web-console/src/app/chat/chat.ts" 2>/dev/null \
    || { WHY="the console lets a copy replace the home's answer"; return 1; }
  grep -q 'WHERE hub_chat_mirrors.updated_at <= excluded.updated_at' "$ROOT/tokenledger/hub/store/chat_mirrors.go" 2>/dev/null \
    || { WHY="an older read's copy replaces a newer one"; return 1; }
  [ -f "$ROOT/extras/browser-transport/chat-copy-order.mjs" ] || { WHY='missing copy-order browser drill'; return 1; }
  if (cd "$ROOT/extras/browser-transport" && node --input-type=module -e 'import { chromium } from "playwright"; import { existsSync } from "node:fs"; process.exit(existsSync(chromium.executablePath()) ? 0 : 1)') >/dev/null 2>&1; then
    out=$(node "$ROOT/extras/browser-transport/chat-copy-order.mjs" 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { WHY="the page went back to an older conversation: $out"; return 1; }
    term_go 'TestChatMirrorKeepsNewest' './hub/store' '' || return 1
    WHAT='迟到的副本不盖住家里的回答；两次读乱序落库只留新的；另一浏览器聚焦即同步、在屏 30 s 内自己跟上'
  else
    term_go 'TestChatMirrorKeepsNewest' './hub/store' '乱序落库只留新的（Go）' || return 1
    WHAT="${WHAT}；无 Playwright/Chromium：browser-attachment 门运行真实页面演练"
  fi
  SECS=$(since "$t0")
}

# Chat has its own admission and never replays a submitted request.
drill_chat_direct_admission() {
  CAP=180; local t0
  t0=$(now)
  term_go 'TestChatAttachmentAdmission TestChatAttachmentRequests' './e2e' \
    '直连与回退共用聊天准入；单条请求单次执行、节点回执单次退额；断线不重放' || return 1
  SECS=$(since "$t0")
}

# chat-mirror-other-person (task V9DJ D): the copy of a person's conversation the
# entry keeps is sealed to them, holds no tool output, opens for nobody else (a
# view-as read included) and is gone once they turn it off.
drill_chat_mirror_other_person() {
  CAP=180; local t0
  t0=$(now)
  term_go 'TestChatMirror' './e2e' \
    '入口那份对话：密文落库、不含工具输出、只本人能读、看他视角被拒、关掉即删' || return 1
  SECS=$(since "$t0")
}

# chat-replica-gone (task V9DJ): the replica holding the home's link went with a
# rolling deploy; the chat is never handed to it and the page hears «reconnecting».
drill_chat_replica_gone() {
  CAP=180; local t0
  t0=$(now)
  term_go 'TestChatReplicaGone' './e2e' \
    '握链接的副本没了：不交给它、5 s 内回 home_reconnecting「正在重连你的家，稍候」，/home 为 reconnecting' || return 1
  SECS=$(since "$t0")
}

drill_term_controller_ready() {
  CAP=180; local t0
  t0=$(now)
  term_go 'TestTermPtyAdmissionBeforeReady TestTermControllerDelayedFrames TestCoreExecTerminalCancellation TestTermPtySignalCleanup' 'github.com/verkyyi/claude-fleet/tokenledger/agent' \
    '控制权准入前不发 ready；拒绝的第二标签页不能输入' || return 1
  SECS=$(since "$t0")
}

# term-other-person (issue #3838, EPIC #3836 C1): a browser terminal reaches only
# the signed-in person's own home login — never another person, an admin as
# themselves or through a view, the operator's door, another origin; and the node
# opens no terminal on a grant signed wrong, expired, for another relay / login /
# service, replayed, or naming a path. The open names no target.
drill_term_other_person() {
  CAP=180; local t0 out
  t0=$(now)
  out=$(awk '/^type TermOpen struct/,/^}/' "$ROOT/tokenledger/shared/control/term_relay.go" | grep -c 'json:"')
  [ "$out" = 3 ] || { WHY="TermOpen has $out wire fields, want 3 (relay_id, secret, login)"; return 1; }
  grep -q 'viewAsAsked(r) != ""' "$ROOT/tokenledger/hub/api/term_relay.go" 2>/dev/null \
    || { WHY="termPerson does not refuse a view-as"; return 1; }
  term_go 'TestTermRelayOtherPersonNeverReachesIt TestTermRelayBadGrantNeverOpensATerminal TestTermRelayReachesOwnWorker TestTermGrant TestAttachmentGrant TestAttachmentRejectsBeforeTarget TestAttachmentGrantReplayAndWrongService' \
    './e2e github.com/verkyyi/claude-fleet/tokenledger/shared/control' \
    '别人 / 管理员本人 / 以他视角 / 运营门 / 别的 Origin / 两个或没有选择器 / 路径当目标 / 不存在的 worker → 拒，命令 0 次启动；签错 / 过期 / 给别的转发 / 别的登录 / 对话的声明 / 命令当目标 / 重放 → 节点断开，不开终端；本人能开（对照）' \
    || return 1
  SECS=$(since "$t0")
}

# door-term-ticket-replay (XX79): a door's pipe takes a ticket the hub signed
# with THAT door's token hash, once — a replay, another door's key, a ticket for
# another door, an expired one or none join nothing; and the home accepts a door
# selection only in a grant it can verify (a door's wss URL and a pipe).
drill_door_term_ticket_replay() {
  CAP=180; local t0
  t0=$(now)
  grep -q 'p.spend(t, now)' "$ROOT/tokenledger/agent/door/pipe.go" 2>/dev/null \
    || { WHY="the door no longer spends a ticket once"; return 1; }
  term_go 'TestDoorPipeTicketReplay TestDoorPipeTicket TestDoorPipeURL TestAttachmentGrantDoor' \
    'github.com/verkyyi/claude-fleet/tokenledger/agent/door github.com/verkyyi/claude-fleet/tokenledger/shared/control' \
    '重放 / 别的门的钥匙 / 给别的门 / 过期 / 没票 → 门 403、不留连接；家只认带门 wss 地址和管子号的选择（fba1）' || return 1
  SECS=$(since "$t0")
}

# door-term-wrong-person (XX79): a pipe joins only its own other half — another
# pipe's valid ticket, a second half of the same role, another origin's page get
# nothing; through the door the real hub and home carry the terminal while the
# hub's own payload counters stay 0.
drill_door_term_wrong_person() {
  CAP=240; local t0
  t0=$(now)
  term_go 'TestDoorPipeOnlyItsOwnOtherHalf TestDoorPipeJoinsTheTwoHalves TestAttachmentDoorCarriesTheTerminal' \
    'github.com/verkyyi/claude-fleet/tokenledger/agent/door ./e2e' \
    '别的管子的票 / 同一半来第二个 / 别的站点 → 接不上、读不到一个字节；走门时入口自己的字节计数为 0' || return 1
  SECS=$(since "$t0")
}

# door-term-down (XX79): a door the home cannot reach costs one attempt
# (door_unavailable, no terminal started) and the next goes through the hub; no
# door set offers none, byte for byte as before.
drill_door_term_down() {
  CAP=240; local t0
  t0=$(now)
  grep -q "msg.error !== 'door_unavailable'" "$ROOT/extras/browser-transport/attachment.ts" 2>/dev/null \
    || { WHY="the page treats door_unavailable as final (no fallback through the hub)"; return 1; }
  term_go 'TestAttachmentDoorDownFallsBackToTheHub TestTermDoorsOffAddsNothing TestTermDoorsSetting TestConsoleCSPDoors' \
    './e2e ./hub/api' \
    '门连不上 → door_unavailable、不开终端，下一次经入口照常；没配门 → 配置里没有门、控制台策略一字不变' || return 1
  SECS=$(since "$t0")
}

# term-relay-orphan (issue #3838): whichever end goes — a half-open browser, a
# malformed or oversized frame, a revoked sign-in, a browser gone mid-attach, the
# agent's link — both streams, the PTY and its command go within 30 s, and a
# terminal never interrupts a chat relay on the same login (nor the reverse).
drill_term_relay_orphan() {
  CAP=240; local t0
  t0=$(now)
  grep -q 'defer s.termRelays.closeNode(nc)' "$ROOT/tokenledger/hub/api/nodes.go" 2>/dev/null \
    || { WHY="a dropped control link does not end its terminals (no termRelays.closeNode)"; return 1; }
  term_go 'TestTermRelayOrphanReleasesEverything TestTermRelayAgentLinkDrop TestTermRelayDoesNotInterruptChat TestTermPtyRunsTheOneCommand TestTermControlFrames TestAttachmentLogoutRevokesDirect TestAttachmentLeaseAndEpoch TestAttachmentReplacementFence TestAttachmentRelayAndLateSelection TestAttachmentBackpressureAndEarlyData TestAttachmentSDPLimits' \
    './e2e github.com/verkyyi/claude-fleet/tokenledger/agent github.com/verkyyi/claude-fleet/tokenledger/shared/control github.com/verkyyi/claude-fleet/tokenledger/shared/attachment' \
    '半开 / 畸形帧 / 超大帧 / 撤销登录 / 接到一半走了 / 控制链路断：30 秒内伪终端和命令进程归零、转发表空；终端饱和、关、发垃圾都不打断同登录的对话，反之亦然' \
    || return 1
  SECS=$(since "$t0")
}

# term-view-kills-session (issue #3838): the browser terminal's tmux view is a
# native `<fleet>@view-wt-web-<id>` that goes with its terminal — never the fleet
# session, a window, or a worker's process — and nothing new starts.
# bin/fleet-term-attach-selftest.sh does it on an isolated tmux server.
drill_term_dead_server_lease() {
  CAP=30; local t0
  t0=$(now)
  suite_holds fleet-webterm-selftest.sh 'F: a confirmed dead server cannot retain its fresh controller lease' || return 1
  SECS=$(since "$t0")
  WHAT="真实隔离 tmux 退出后旧控制租约仍新鲜，也不会阻止个人终端重建；活浏览器不抢"
}

drill_term_personal_renew() {
  CAP=60; local t0 out rc
  t0=$(now)
  out=$(bash "$BIN/fleet-term-attach-selftest.sh" --renew 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="$out"; return 1; }
  WHAT='嵌套壳 exit 返回；个人壳 exit 后普通重连保持 ended，显式 renew 后输入可用，其他 worker 不变'
  SECS=$(since "$t0")
}

# term-last-worker-reaped (RMVE): the session last looked at went; the
# personal terminal goes home, same generation, never «ended».
drill_term_last_worker_reaped() {
  CAP=60; local t0 out rc
  t0=$(now)
  out=$(bash "$BIN/fleet-term-attach-selftest.sh" --worker-gone 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="$out"; return 1; }
  WHAT='上次看的会话被关后再进个人终端：回到家窗口、同一代、家 shell 不变，不说 ended'
  SECS=$(since "$t0")
}

# term-hub-rollout (RMVE): a replica going away tells its terminals and drops
# its row; a holder that refuses connections is passed over, not 503ed.
drill_term_hub_rollout() {
  CAP=240; local t0
  t0=$(now)
  term_go 'TestDrainForgetsReplica TestStateHolderUnreachablePassedOver TestTermHealthNumbers' 'github.com/verkyyi/claude-fleet/tokenledger/hub/api' \
    '副本关停先通知终端并删自己的行；连不上的持有者被跳过，GET 不再 503' || return 1
  SECS=$(since "$t0")
}

# term-renew-admission-refused (T968): an admission refusal did not run renew.
drill_term_renew_admission_refused() {
  CAP=60; local t0 out rc
  t0=$(now)
  out=$(cd "$ROOT/extras/web-console" && node --experimental-strip-types test/terminal-renew.mjs 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="$out"; return 1; }
  WHAT='准入明确拒绝后仍重开同一代；答复丢失只重连确认；不重放输入'
  SECS=$(since "$t0")
}

# term-browser-gives-up (RMVE): the page never stops trying, and an «ended»
# personal terminal is reconnected, then renewed once — the rules' own test.
drill_term_browser_gives_up() {
  CAP=60; local t0 out rc
  t0=$(now)
  command -v node >/dev/null 2>&1 || { WHAT='没有 node：网页的恢复规则由 web-console 门（test/terminal.mjs）跑'; SECS=$(since "$t0"); return 0; }
  out=$(cd "$ROOT/extras/web-console" && node --experimental-strip-types test/terminal.mjs 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="$out"; return 1; }
  grep -q 'failures >= 6' "$ROOT/extras/web-console/src/shared/terminal.ts" && { WHY='the page still gives up after 6 tries'; return 1; }
  out=$(bash "$BIN/fleet-term-attach-selftest.sh" --own-lease 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="$out"; return 1; }
  WHAT='第 51 次仍 ≤15 s 再试；hub_restart 立即重连；ended 先重连、再对同一代 renew 一次；重连只接回自己上一条的租约'
  SECS=$(since "$t0")
}

drill_term_view_auto_select() {
  CAP=60; local t0 out rc
  t0=$(now)
  out=$(bash "$BIN/fleet-term-attach-selftest.sh" --auto-select 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="$out"; return 1; }
  WHAT='目标窗消失时同步关闭本 browser view，不让输入落到自动选中的窗口；home PID 不变'
  SECS=$(since "$t0")
}

drill_term_closed_lease() {
  CAP=30; local t0 out rc
  t0=$(now)
  out=$(bash "$BIN/fleet-term-attach-selftest.sh" --closed-lease 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="$out"; return 1; }
  WHAT='已退出 view 的新鲜租约可立即接回；活控制者仍须 Use here；旧清理不碰同名新 session'
  SECS=$(since "$t0")
}

drill_term_view_kills_session() {
  CAP=120; local t0
  t0=$(now)
  suite_holds fleet-term-attach-selftest.sh || return 1
  SECS=$(since "$t0")
  WHAT='两种入口的真 PTY 打开原生菜单、选会话、切持久壳并返回；挂断 30 秒内本连接 view/registry 清零，home/worker pid 不变；重复连接、占用控制权和未知目标先拒，take 先收旧视图，旧 cleanup 不释放新 epoch（fleet-term-attach-selftest.sh 真跑，这里按名守住）'
}

# land-race (issue #3602, EPIC #3570 C9): two sessions of a FLEET_LAND=fleet repo
# land at once through fleet-land.sh — both land, one after the other, the second
# rebased onto the first and checked again; a red check never moves the base; gh 0 times.
drill_land_race() {
  CAP=60; local d="$WORK/lr" t0 out
  mkdir -p "$d/fake" "$d/conf/fleets/fl/repos"
  printf '#!/bin/sh\necho "gh $*" >> "%s/gh.log"; exit 1\n' "$d" > "$d/fake/gh"; chmod +x "$d/fake/gh"; : > "$d/gh.log"
  : > "$d/conf/fleets/fl/conf"
  t0=$(now)
  out=$(cd "$d" && PATH="$d/fake:$PATH" FLEET_CONF_DIR="$d/conf" TMPDIR="$d" LAND_LEASE_DIR="$d/leases" FLEET_HEAVY=0 \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t bash -c '
    B=$1 d=$PWD
    git init -q --bare o.git; git clone -q o.git m 2>/dev/null; cd m; git checkout -q -B main
    echo a > f; git add f; git commit -q -m base; git push -q origin main
    printf "FLEET_REPO=\"o/r\"\nFLEET_MAIN=\"%s\"\nFLEET_BASE_BRANCH=\"main\"\nFLEET_FORGE=\"none\"\nFLEET_LAND=\"fleet\"\n" "$d/m" > "$d/conf/fleets/fl/repos/o-r.conf"
    printf "FLEET_CHECK_CMD=%s\n" "\"sleep 1; test ! -e BAD\"" >> "$d/conf/fleets/fl/repos/o-r.conf"
    for n in 1 2 3; do git worktree add -q -b issue-$n ../w$n main 2>/dev/null; echo $n > ../w$n/x$n; git -C ../w$n add x$n; git -C ../w$n commit -q -m x$n; done
    touch ../w3/BAD; git -C ../w3 add BAD; git -C ../w3 commit -q -m bad
    "$B/fleet-land.sh" -q o/r issue-1 > ../r1 2>/dev/null & a=$!
    "$B/fleet-land.sh" -q o/r issue-2 > ../r2 2>/dev/null & b=$!
    "$B/fleet-land.sh" -q o/r issue-3 > ../r3 2>/dev/null & c=$!
    wait $a; wait $b; wait $c
    printf "%s %s %s " "$(cat ../r1)" "$(cat ../r2)" "$(cat ../r3)"
    git -C ../o.git ls-tree --name-only main | grep -c "^x[12]$" | tr -d "\n"
    printf " %s" "$(git -C ../o.git ls-tree --name-only main | grep -c "^BAD$")"' _ "$BIN" 2>/dev/null)
  SECS=$(since "$t0")
  [ "$out" = "MERGED MERGED FAILING 2 0" ] || { WHY="three landings at once read [$out], want [MERGED MERGED FAILING 2 0]"; return 1; }
  [ ! -s "$d/gh.log" ] || { WHY="gh was called: $(head -1 "$d/gh.log")"; return 1; }
  WHAT="三个会话同时自己落地：两个依次并进（后者变基后再检查），检查红的那个不进主干，gh 0 次"
}

# worker-inventory-rs (#4508): real adapter with synthetic orphan reports;
# bin/fleet_control.py must preserve the nested RS/US framing through fleet_status.
drill_worker_inventory_rs() {
  CAP=20; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-hub-selftest.py" HubTests.test_inventory_orphan_report_framing 2>&1) \
    || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT='含历史报告 RS/US 的十条 inventory 原样到达 fleet_status，身份、中文、REAPED 报告与观察时间均保留'
}

# stream-cut-stays (#4714): a turn an API error cut off is resumed by itself —
# bin/fleet-stream-resume-selftest.sh on an isolated tmux server, a stub sender.
drill_stream_cut_stays() {
  CAP=15; local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-stream-resume-selftest.sh" 2>&1) || { WHY="$(printf '%s' "$out" | grep FAIL | head -3)"; return 1; }
  SECS=$(since "$t0")
  WHAT='StopFailure(unknown) 20 s 后经会话收件箱发「继续」；人已发话或又失败一次就不发；每窗口 3 次/30 分钟，超了留给人；配额/认证/请求错误不管'
}

# T580's three Codex-only breaks of opening a session (T620, EPIC T580 C4) — each
# now one road for both agents (bin/fleet-launch-lib.sh + the adapter table), and
# each recovery is a leg of bin/fleet-launch-lib-selftest.sh that runs once per
# agent (claude, codex) against fake CLIs: held here by name, not run twice.
# ⑥ `fleet codex` opened Claude (#2405)
drill_open_wrong_agent() {
  CAP=10; local t0
  t0=$(now)
  grep -qF 'exec "$BIN/$(fleet_agent_get "$_fc_agent" launcher)"' "$BIN/fleet-claude.sh" \
    || { WHY="fleet-claude.sh no longer opens the asked agent's launcher off the adapter table"; return 1; }
  suite_holds fleet-launch-lib-selftest.sh 'D⑥ the door opens the agent asked for, both ways' 'for a in $AGENTS; do' || return 1
  WHAT='门（fleet-claude.sh）按适配表开问到的那个 Agent：--agent codex 就是 Codex（像续接的也是），平常开就是 Claude，从不开成另一个；两种 Agent 各跑一遍（fleet-launch-lib-selftest.sh D⑥，这里按名守住）'
  SECS=$(since "$t0")
}
# ⑦ a new fleet Codex had partial permissions, its /resume refused (#4727)
drill_open_partial_access() {
  CAP=10; local t0
  t0=$(now)
  suite_holds fleet-launch-lib-selftest.sh "D⑦ a fresh session has full access from the fleet's defaults, both ways" \
    'bypassPermissions' 'danger-full-access' || return 1
  WHAT='新开的会话从 fleet 默认拿满权限（Claude 的 --settings 带 bypassPermissions，Codex 带满权限）；登录自己的配置已给满权限时 Codex 开局不带命令行覆盖（会话里 /resume 能用）；两种 Agent 各跑一遍（D⑦）'
  SECS=$(since "$t0")
}
# ⑧ starting Codex ran `claude plugin list` (#4731)
drill_open_other_cli() {
  CAP=10; local t0
  t0=$(now)
  suite_holds fleet-launch-lib-selftest.sh "D⑧ starting one agent (as an agent file too) never runs the other's CLI" \
    '--as fleet-worker' || return 1
  WHAT='起一种 Agent（按 agent 文件起也一样）从不去跑另一种的命令行：起 Codex 不跑任何 claude（不跑 claude plugin list），起 Claude 不跑 codex；两种 Agent 各跑一遍（D⑧）'
  SECS=$(since "$t0")
}
# ⑤ a reaper took a Codex's resident MCP / app-server for work, or the other way
# round (#4466 #4538) — reaping is one road now (T631, EPIC T580 C8): the end, the
# agent processes, the leftover-work probe and the left-behind service are the
# adapter table's; the four legs run once per agent in fleet-agent-end-selftest.py.
drill_reap_agent_split() {
  CAP=10; local t0
  t0=$(now)
  grep -qF 'probe=$(fleet_agent_get' "$BIN/fleet-lib.sh" \
    || { WHY="fleet_window_bg_busy no longer asks the adapter table's bg_probe"; return 1; }
  grep -qF 'fleet_launch_end "$rc"' "$BIN/fleet-codex.sh" \
    || { WHY="fleet-codex.sh no longer ends through the one close (fleet_launch_end)"; return 1; }
  suite_holds fleet-agent-end-selftest.py 'def leg_exit' 'def leg_killed' 'def leg_daemon' 'def leg_work' \
    'def test_claude' 'def test_codex' || return 1
  suite_holds fleet-codex-busy-selftest.sh 'fleet-codex-busy-selftest.py' || return 1
  grep -qF 'def test_idle_persistent_mcp_is_not_work' "$BIN/fleet-codex-busy-selftest.py" \
    || { WHY="fleet-codex-busy-selftest.py no longer holds an idle resident MCP is not work"; return 1; }
  WHAT='回收一条路：结束（钩子 / 退出码）、认 Agent 进程、问还有没有活、收它留下的服务都问适配表；正常退出、被杀、后台服务还在、真有活四条腿两种 Agent 各跑一遍（fleet-agent-end-selftest.py，这里按名守住）；常驻 MCP 不算活（fleet-codex-busy-selftest.py）'
  SECS=$(since "$t0")
}

drill_task_worktree_current_generation() {
  local t0; t0=$(now); CAP=10
  suite_holds worktree-autoclean-scratch-selftest.sh \
    'CONTROLLED: old outcomes cannot prune current/pending/released workspaces' \
    'legacy Task worktree scratch-16 should still prune' 'fleet_task_control.py' || return 1
  WHAT='真实 git 工作树：旧Outcome不授权删除当前/待启动/已释放controlled目录；未知KEEP，legacy仍可清理'
  SECS=$(since "$t0")
}

drill_task_history_current_generation() {
  local t0; t0=$(now); CAP=120
  _drill_go_tests 'TestTaskProjectionControlledGeneration TestTaskProjectionKeepsControlledIDHistory TestTaskProjectionControlledSweepsAndUndo TestTaskProjectionSnapshotRejectsAdmissionAndGenerationChange TestTaskProjectionMixedLegacyAliases' \
    "$ROOT/tokenledger/hub/store/fleet_task_projection_test.go" \
    '旧 ID/result/closed/超时补偿保留历史，不改写受控 Task 的当前代次和绑定' ./hub/store || return 1
  SECS=$(since "$t0")
}

drill_task_current_view() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/fleet-task-current-view-selftest.py" >"$WORK/task-current-view.log" 2>&1 || {
    WHY="current view regression: $(tail -10 "$WORK/task-current-view.log")"; return 1;
  }
  WHAT='历史文字不冒充原生问题，Task 代码不随会话或结果改变'
  SECS=$(since "$t0")
}

drill_task_result_overrides_native() {
  local t0; t0=$(now); CAP=30
  bash "$BIN/fleet-view-id-selftest.sh" >"$WORK/task-native-display.log" 2>&1 || {
    WHY="historical result replaced a native observation: $(tail -8 "$WORK/task-native-display.log")"; return 1;
  }
  WHAT='历史 blocked/failed/done/merged 与Task Outcome不改写当前原生状态；已收起会话仍保留历史结果'
  SECS=$(since "$t0")
}

drill_stop_renamed_worker() {
  local t0; t0=$(now); CAP=30
  bash "$BIN/fleet-worker-stop-selftest.sh" --role-only >"$WORK/stop-renamed-worker.log" 2>&1 || {
    WHY="renamed-worker stop or panel protection failed: $(tail -12 "$WORK/stop-renamed-worker.log")"; return 1;
  }
  WHAT='worker改名home/dash/plan/backlog仍可按FID停止；真home/panel改名仍受保护；未标记旧窗口保留旧规则'
  SECS=$(since "$t0")
}

drill_parent_report_retired() {
  local t0; t0=$(now); CAP=60
  python3 "$BIN/fleet-parent-retirement-selftest.py" >"$WORK/parent-retired.log" 2>&1 || {
    WHY="retired parent path delivered or lost history: $(tail -8 "$WORK/parent-retired.log")"; return 1;
  }
  WHAT='旧报告与await入口退役；报告积压原文保留且永久失败、不转通知；普通message仍经原投递入口'
  SECS=$(since "$t0")
}

drill_report_delegation_offline() {
  CAP=30; local t0 out; t0=$(now)
  out=$(python3 "$BIN/fleet-report-delegation-selftest.py" 2>&1) || { WHY="$out"; return 1; }
  WHAT='旧委托写入口立即退役；历史读取不写磁盘、不派发、不补送'
  SECS=$(since "$t0")
}

drill_session_title_placeholder() {
  local t0; t0=$(now); CAP=30
  bash "$BIN/task-line-selftest.sh" >"$WORK/title-placeholder.log" 2>&1 || {
    WHY="first prompt title regression: $(tail -3 "$WORK/title-placeholder.log")"; return 1;
  }
  WHAT='短码任务的首句同时更新窗口和记录；中英文占位名消失，后续消息不改名'
  SECS=$(since "$t0")
}

drill_session_title_lost() {
  local t0; t0=$(now); CAP=30
  python3 "$BIN/session-title-ledger-selftest.py" >"$WORK/title-ledger.log" 2>&1 || {
    WHY="persistent title regression: $(tail -3 "$WORK/title-ledger.log")"; return 1;
  }
  WHAT='创建、自动/人工命名、并发顺序、回收和重开保留同一身份的标题'
  SECS=$(since "$t0")
}

drill_task_parent_write_retired() {
  CAP=120; local t0; t0=$(now)
  _drill_go_tests 'TestTaskParentWriteRetired TestTaskParentHistoricalReplayPreservesBytes' \
    "$ROOT/tokenledger/hub/store/fleet_task_parent_retirement_test.go" \
    '新Task不写Parent，旧token重放保留原记录和非Parent冲突保护' ./hub/store || return 1
  _drill_go_tests 'TestTaskParentNodeWriteRetired TestTaskParentOperationReplayRetired TestTaskParentWriteParamsRetired TestTaskParentAcceptedDispatchReplay' \
    "$ROOT/tokenledger/hub/api/fleet_task_parent_retirement_test.go" \
    '认证身份保留，Parent字段不注入、不影响旧请求重放，用户正文仍完整比较' || return 1
  SECS=$(since "$t0")
}

# ================================================================ run ====}

FAILS=$LINT; PASSES=0
printf 'fleet-break-it: %d rows in docs/dev/BREAK-IT.md\n' "$NROWS"
# BREAK_PART → the ids of this slice (" id id … "); empty = every drill
PART_IDS=''
part=${BREAK_PART:-1/13}
if [ -z "${BREAK_ONLY:-}" ] && [ "$part" != all ]; then
  case "$part" in
    [1-9]/[1-9]|[1-9]/[1-9][0-9]|[1-9][0-9]/[1-9][0-9]) pk=${part%/*} pn=${part#*/} ;;
    *) printf 'fleet-break-it: BREAK_PART=%s is not K/N or all\n' "$part" >&2; exit 2 ;;
  esac
  [ "$pk" -le "$pn" ] || { printf 'fleet-break-it: BREAK_PART=%s: K is past N\n' "$part" >&2; exit 2; }
  mine=''
  for r in $IDS; do type "drill_${r//-/_}" >/dev/null 2>&1 && mine="$mine $r"; done
  # contiguous slices balanced by each drill's measured wall time (issue #2694)
  # shellcheck disable=SC2086  # ids carry no whitespace
  PART_IDS=" $(python3 "$BIN/fleet-break-it-part.py" "$part" "$BIN/break-it-durations.txt" $mine | tr '\n' ' ')"
  # shellcheck disable=SC2086
  set -- $mine; pt=$#
  # shellcheck disable=SC2086
  set -- $PART_IDS
  printf 'fleet-break-it: part %s — %d of %d drills\n' "$part" "$#" "$pt"
fi
unset BREAK_PART
while IFS= read -r r; do
  case "$r" in
    '@'*) [ "${pk:-1}" -gt 1 ] || printf 'REG   %-20s %s\n' '—' "${r#@}"; continue ;;
    '!'*|'') continue ;;
  esac
  if [ -n "${BREAK_ONLY:-}" ]; then case " $BREAK_ONLY " in *" $r "*) ;; *) continue ;; esac; fi
  if [ -n "$PART_IDS" ]; then case "$PART_IDS" in *" $r "*) ;; *) continue ;; esac; fi
  fn="drill_${r//-/_}"
  type "$fn" >/dev/null 2>&1 || continue
  SECS='' CAP='' WHY='' WHAT='' T_D=$(now)
  if "$fn" && [ -n "$SECS" ] && le "$SECS" "$CAP"; then
    PASSES=$((PASSES + 1))
    printf 'PASS  %-20s %5ss ≤%ss  %s  [wall %ss]\n' "$r" "$SECS" "$CAP" "$WHAT" "$(since "$T_D")"
  else
    FAILS=$((FAILS + 1))
    [ -n "$WHY" ] || WHY="recovered in ${SECS:-?}s, over the ${CAP}s bound"
    printf 'FAIL  %-20s %s  [wall %ss]\n' "$r" "$WHY" "$(since "$T_D")"
  fi
done <<EOF
$ROWS
EOF
if [ "$FAILS" -gt 0 ]; then
  printf 'fleet-break-it selftest: %d FAILED, %d passed\n' "$FAILS" "$PASSES" >&2
  exit 1
fi
printf 'fleet-break-it selftest: OK (%d drills green)\n' "$PASSES"
