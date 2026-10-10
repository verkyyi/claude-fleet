#!/bin/bash
# fleet-issue-file-selftest.sh — hermetic tests for the ONE issue-filer channel
# bin/fleet-issue-file.sh (issue #332). No network, no real repo, no tmux server:
# gh + tmux are faked and the script runs from a temp bin so it sources the real
# fleet-lib.sh copy. Asserts the channel's contract:
#   A. title-only: `gh issue create` is called and the body carries the invisible
#      `<!-- fleet:from … -->` provenance marker; the URL is echoed on stdout.
#   B. --label + --priority: each valid label reaches `gh issue create`, and
#      --priority pN is mapped to the priority:pN label.
#   C. off-taxonomy label: REJECTED up front (exit 3) with NO `gh issue create`.
#   D. bad --priority: rejected (exit 2), no create.
#   E. missing --title: rejected (exit 2), no create.
#   F. --parent N: links the new issue as a sub-issue of N (the sub_issues POST
#      carries the child's numeric database id, not its #number).
#   G. --spawn: hands the new number to dash-issue-session.sh with the --title;
#      a spawn refusal (non-zero) still leaves the issue FILED (exit 0, URL echoed).
#   H. --from ROLE: forces the provenance marker's role word.
#   I. fixed taxonomy (issue #333): validation is against the FIXED
#      fleet_labels_allowed set, NOT the live `gh label list` — a canonical label
#      absent from the repo's live labels is still ACCEPTED, and the channel makes
#      NO `gh label` read at all (deterministic, offline, no minting).
#   J. default milestone (issue #433): with FLEET_DEFAULT_MILESTONE set and NO
#      --milestone, the channel idempotently ensures the milestone exists and
#      passes `--milestone <default>` to `gh issue create`.
#   K. explicit --milestone WINS over the default (no ensure call for the default).
#   L. unset FLEET_DEFAULT_MILESTONE: unregressed — no ensure, no --milestone.
#   M. ensure-failure is BEST-EFFORT (issue #297): the milestone can't be created
#      and isn't present, so the issue still FILES (exit 0) WITHOUT a --milestone.
#   O. one issue per breakage (issue #2078): three concurrent --breakage-key K
#      filers → ONE `gh issue create` (its body carries `<!-- fleet:breakage
#      key=K -->`), the other two exit 5 with that issue's URL and leave one
#      「同一故障」 comment each on it (no spawn, no bind); a lock gone + the marker
#      in an open issue (another machine) is found by fleet_breakage_find → 5.
#   P. a different key files its own issue; a stale lock (older than
#      FLEET_BREAKAGE_LOCK_SECS) is nobody's.
#   Q. the degenerate: no --breakage ⇒ no lock dir, no open-issue list, no
#      check-run read — the argv and body are what they were.
#   R. fleet_breakage_probe: red is per workflow on its last FINISHED run
#      (cancelled passed over, a stale one too old to count); the key is the red
#      streak's FIRST commit, that run's first failed job by completion time, and
#      the error line sans line numbers — two logs that differ only in `:88:2:`
#      vs `:91:4:` give one key; a different error line gives another; green is rc 1.
#   S. the real 2026-10-07 tokenledger-pg logs (issue #2175): #2163's and
#      #2170's sightings (11:22:55 and 11:29:30Z, head a6dd7c9b then an
#      unfinished bb7da505) and the one after bb7da505 went red too all give ONE
#      key; the two pg logs normalize to the same `--- FAIL:` line.
#   T. auto (issue #2175): no flag + a red base + a text naming it ⇒ filed as
#      breakage (marker, dedup → exit 5); --no-breakage files plain; a red word
#      on a green base, or a text naming neither base nor check, files plain.
#   V. which rule dispatched it (issue #2786): from the orchestrator's pane
#      (@fleet_role orchestrator ⇒ the marker says role=orchestrator) the five
#      shapes filed with --rule 1…5 carry 「按规则 N 派发」 + `<!-- fleet:rule n=N
#      v=… -->` 5/5; one with no rule files all the same with 「未注明规则」 and a
#      logs/rules.log line; a rule the table lacks is refused (exit 2, no create);
#      a filing from anywhere else gets no rule line at all (byte for byte).
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail
export FLEET_GH_WRITE_GAP=0   # no write pacing here: the queue has its own test (fleet-gh-write-selftest.sh)

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-issue-file.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$SRC" ] || { echo "selftest: $SRC missing" >&2; exit 2; }
[ -f "$LIB" ] || { echo "selftest: $LIB missing" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fif-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin"
GH_LOG="$WORK/ghlog"; SPAWN_LOG="$WORK/spawns"; BIND_LOG="$WORK/binds"; BODY="$WORK/body"

# real channel + lib run from $WORK/bin so BIN resolves the copies and ../fleet.conf
# is absent (env FLEET_REPO wins) — fully hermetic.
cp "$SRC" "$WORK/bin/fleet-issue-file.sh"; cp "$LIB" "$WORK/bin/fleet-lib.sh"
cp "$BIN/fleet-gh-lib.sh" "$WORK/bin/fleet-gh-lib.sh"   # its write queue (issue #1264)
cp "$BIN/fleet-role.py" "$BIN/fleet_rules.py" "$WORK/bin/"   # --rule's table (issue #2786)
export FLEET_RULES_DEFAULT="$BIN/../conf/role-rules.default.md" FLEET_RULES_LOG="$WORK/rules.log"
chmod +x "$WORK/bin/fleet-issue-file.sh"
# Stub the spawn choke point the channel hands to on --spawn: log its args, honour
# SPAWN_RC so a cap-refusal (non-zero) can be simulated.
cat > "$WORK/bin/dash-issue-session.sh" <<'SPAWNSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SPAWN_LOG"
[ "${SPAWN_RC:-0}" != 0 ] && printf 'dash-issue-session: test capacity refusal\n' >&2
[ -n "${SPAWN_NOTE:-}" ] && printf '%s\n' "$SPAWN_NOTE" >&2
exit "${SPAWN_RC:-0}"
SPAWNSTUB
chmod +x "$WORK/bin/dash-issue-session.sh"
# Stub the in-place binder the channel hands to on --bind (issue #520): log its
# args, honour BIND_RC so a refusal can be simulated.
cat > "$WORK/bin/fleet-bind.sh" <<'BINDSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "$BIND_LOG"
exit "${BIND_RC:-0}"
BINDSTUB
chmod +x "$WORK/bin/fleet-bind.sh"

# --- fake gh: issue create (log body + args, echo a URL) · api (issue id lookup +
# sub_issues POST log). GH_CREATE_FAIL=1 fails create. The filer no longer reads
# labels (it validates against the fixed fleet_labels_allowed taxonomy, #333), so
# any `gh label` call is logged — a regression that re-introduces a round-trip is
# then caught by test I. --
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
case "$1" in
  label)
    printf 'label %s\n' "$*" >> "$GH_LOG"
    ;;
  issue)
    if [ "$2" = create ]; then
      printf '%s\n' "$*" >> "$GH_LOG"
      # capture the --body verbatim so the marker can be asserted
      shift 2; b=''
      while [ "$#" -gt 0 ]; do case "$1" in --body) shift; b="$1";; esac; shift; done
      printf '%s' "$b" > "$BODY"
      [ "${GH_CREATE_FAIL:-0}" = 1 ] && exit 1
      # BRK_STORE (test O–Q): a store of filed issues, numbered up, with a pause so
      # concurrent filers all reach the create before any number exists.
      if [ -n "${BRK_STORE:-}" ]; then
        sleep 0.3; n=$(( $(ls "$BRK_STORE"/issue-* 2>/dev/null | wc -l) + 201 ))
        printf '%s' "$b" > "$BRK_STORE/issue-$n"; printf 'https://github.com/acme/widgets/issues/%s\n' "$n"; exit 0
      fi
      printf 'https://github.com/acme/widgets/issues/%s\n' "${NEW_NUM:-777}"
    elif [ "$2" = comment ]; then
      printf '%s\n' "$*" >> "$GH_LOG"
      shift 2; n="$1"; b=''
      while [ "$#" -gt 0 ]; do case "$1" in --body) shift; b="$1";; esac; shift; done
      [ -n "${BRK_STORE:-}" ] && { printf '%s' "$b" | tr '\n' ' ' >> "$BRK_STORE/comments-$n"; printf '\n' >> "$BRK_STORE/comments-$n"; }
      printf 'https://github.com/acme/widgets/issues/%s#issuecomment-1\n' "$n"
    fi
    ;;
  run)
    # `gh run view --job <id> --log-failed`: the failed job's log (tests R–T) —
    # $BRK_LOGS_DIR/<job id> when there is one, else $BRK_LOG.
    printf '%s\n' "$*" >> "$GH_LOG"
    j=''; while [ "$#" -gt 0 ]; do [ "$1" = --job ] && j="${2:-}"; shift; done
    if [ -n "${BRK_LOGS_DIR:-}" ] && [ -f "$BRK_LOGS_DIR/$j" ]; then cat "$BRK_LOGS_DIR/$j"
    elif [ -n "${BRK_LOG:-}" ]; then cat "$BRK_LOG"; fi
    ;;
  api)
    printf 'api %s\n' "$*" >> "$GH_LOG"
    # --- milestones (issue #433): POST create vs GET list. The path can sit after
    # `--method POST` so it isn't $2 — match anywhere in the args. MS_CREATE_FAIL=1
    # fails the idempotent create; MS_MISSING=1 makes the list omit it (together =
    # ensure-failure). Otherwise the list echoes MS_TITLE so the filer confirms it.
    if printf '%s ' "$@" | grep -q 'milestones'; then
      if printf '%s ' "$@" | grep -q -- '--method POST'; then
        [ "${MS_CREATE_FAIL:-0}" = 1 ] && exit 1        # create failed (perms/etc.)
      else
        [ "${MS_MISSING:-0}" = 1 ] || printf '%s\n' "${MS_TITLE:-Triage}"
      fi
      exit 0
    fi
    # --- the breakage probe's REST reads (tests O–R), answered post-jq the way the
    # lib's --jq programs shape them; the open-issue list comes from BRK_STORE.
    p=''; for a in "$@"; do case "$a" in repos/*) p="$a";; esac; done
    case "$p" in
      repos/acme/widgets)                    echo main; exit 0 ;;
      */actions/runs\?*)                     [ -n "${BRK_RUNS_FILE:-}" ] && cat "$BRK_RUNS_FILE"; exit 0 ;;
      */actions/runs/*/jobs*)                r=${p#*/actions/runs/}; r=${r%%/*}
                                             [ -n "${BRK_JOBS_DIR:-}" ] && [ -f "$BRK_JOBS_DIR/$r" ] && cat "$BRK_JOBS_DIR/$r"; exit 0 ;;
      repos/*/issues\?*)                     for f in "${BRK_STORE:-/nonexistent}"/issue-*; do [ -e "$f" ] || continue
                                               printf '%s\t%s\n' "${f##*-}" "$(tr '\n' ' ' < "$f")"; done; exit 0 ;;
    esac
    case "$2" in
      repos/*/issues/*) case "$2" in */sub_issues) : ;; *) echo "${CHILD_ID:-999888}" ;; esac ;;
    esac
    ;;
esac
exit 0
GHFAKE

# --- fake tmux: answer session_name via -p; everything else no-ops -------------
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = -L ] || [ "${1:-}" = -S ]; then shift 2; fi
case "${1:-}" in
  display-message) case "$*" in *-p*) case "$*" in *session_name*) echo fifsess ;; *@fleet_role*) echo "${FAKE_FLEET_ROLE:-}" ;; *) echo '' ;; esac ;; esac ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# $@ = args to fleet-issue-file.sh ; env (GH_CREATE_FAIL / LABELS_EMPTY / SPAWN_RC
# / NEW_NUM / CHILD_ID) passes through. Records exit code in $RC, stdout/stderr.
run_fif() {
  : > "$GH_LOG"; : > "$SPAWN_LOG"; : > "$BIND_LOG"; : > "$BODY"
  # FLEET_CONF_DIR points at an empty temp dir so the filer's per-fleet conf load
  # (issue #433, FLEET_DEFAULT_MILESTONE) finds nothing — the knob is driven only
  # by the env we pass, keeping every case hermetic.
  PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" SPAWN_LOG="$SPAWN_LOG" BIND_LOG="$BIND_LOG" BODY="$BODY" \
  FLEET_REPO="acme/widgets" FLEET_CONF_DIR="$WORK/conf" \
    bash "$WORK/bin/fleet-issue-file.sh" "$@" >"$WORK/out" 2>"$WORK/err"
  RC=$?
}

# ============================ A: title-only ================================
run_fif --title "Add a widget"
[ "$RC" -eq 0 ]                         || fail "A title-only should succeed" "$(cat "$WORK/err")"
grep -q 'issue create' "$GH_LOG"        || fail "A gh issue create not called" "$(cat "$GH_LOG")"
grep -q 'github.com/acme/widgets/issues/777' "$WORK/out" || fail "A the URL must be echoed on stdout" "$(cat "$WORK/out")"
grep -q '<!-- fleet:from role=' "$BODY" || fail "A body must carry the fleet:from provenance marker" "$(cat "$BODY")"
ok "A title-only files + echoes the URL + stamps the fleet:from marker"

# ============================ B: labels + priority =========================
run_fif --title "Tidy" --label "enhancement,cleanup" --priority p1
[ "$RC" -eq 0 ]                               || fail "B valid labels should succeed" "$(cat "$WORK/err")"
grep -q -- '--label enhancement' "$GH_LOG"    || fail "B --label enhancement should reach create" "$(cat "$GH_LOG")"
grep -q -- '--label cleanup' "$GH_LOG"        || fail "B --label cleanup should reach create" "$(cat "$GH_LOG")"
grep -q -- '--label priority:p1' "$GH_LOG"    || fail "B --priority p1 should map to the priority:p1 label" "$(cat "$GH_LOG")"
ok "B valid labels + --priority pN reach gh issue create"

# ============================ C: off-taxonomy label rejected ===============
run_fif --title "Bad" --label "enhancement,not-a-real-label"
[ "$RC" -eq 3 ]                    || fail "C off-taxonomy label must exit 3 (got $RC)" "$(cat "$WORK/err")"
[ -s "$GH_LOG" ] && grep -q 'issue create' "$GH_LOG" && fail "C must NOT create when a label is off-taxonomy" "$(cat "$GH_LOG")"
grep -qi 'off-taxonomy label' "$WORK/err" || fail "C should explain the off-taxonomy label" "$(cat "$WORK/err")"
ok "C an off-taxonomy label is rejected up front (exit 3, no create)"

# ============================ D: bad priority ==============================
run_fif --title "x" --priority p9
[ "$RC" -eq 2 ]                       || fail "D bad --priority must exit 2 (got $RC)" "$(cat "$WORK/err")"
grep -q 'issue create' "$GH_LOG" && fail "D must NOT create on a bad --priority" "$(cat "$GH_LOG")"
ok "D a bad --priority is rejected (exit 2, no create)"

# ============================ E: missing title =============================
run_fif --body "orphan body"
[ "$RC" -eq 2 ]                       || fail "E missing --title must exit 2 (got $RC)" "$(cat "$WORK/err")"
grep -q 'issue create' "$GH_LOG" && fail "E must NOT create without a title" "$(cat "$GH_LOG")"
ok "E a missing --title is rejected (exit 2, no create)"

# ============================ F: --parent sub-issue link ===================
run_fif --title "Nest me" --parent 42
[ "$RC" -eq 0 ]                                   || fail "F parent link should succeed" "$(cat "$WORK/err")"
grep -q 'api repos/acme/widgets/issues/777 -q .id' "$GH_LOG" || fail "F must resolve the child's database id" "$(cat "$GH_LOG")"
grep -q 'api --method POST repos/acme/widgets/issues/42/sub_issues -F sub_issue_id=999888' "$GH_LOG" \
  || fail "F must POST the child DB id to the parent's sub_issues" "$(cat "$GH_LOG")"
ok "F --parent links the new issue as a sub-issue (child DB id, not #number)"

# ============================ G: --spawn hands off =========================
# happy: the spawn choke point is invoked with the descriptive --title.
run_fif --title "Ship it" --spawn
[ "$RC" -eq 0 ]                        || fail "G --spawn should succeed" "$(cat "$WORK/err")"
grep -q -- '--title Ship it' "$SPAWN_LOG" || fail "G --spawn must pass the descriptive --title" "$(cat "$SPAWN_LOG")"
grep -q '^777' "$SPAWN_LOG"           || fail "G --spawn must hand the new number to the choke point" "$(cat "$SPAWN_LOG")"
ok "G --spawn hands the new number + title to the spawn choke point"

# files-without-spawning: a spawn refusal (non-zero) must NOT fail the create.
SPAWN_RC=1 run_fif --title "Ship it" --spawn
[ "$RC" -eq 0 ]                       || fail "G2 a spawn refusal must still exit 0 (issue filed)" "$(cat "$WORK/err")"
grep -q 'issues/777' "$WORK/out"      || fail "G2 the issue must still be FILED (URL echoed) on a spawn refusal" "$(cat "$WORK/out")"
grep -q 'filed #777 but the spawn was refused' "$WORK/err" \
                                      || fail "G2 a spawn refusal must be reported on stderr — the caller reading only the URL must learn no worker took it (issue #683)" "$(cat "$WORK/err")"
grep -q 'dash-issue-session: test capacity refusal' "$WORK/err" || fail "G2 the spawn reason must pass through unchanged" "$(cat "$WORK/err")"
ok "G2 a spawn refusal files-without-spawning (issue not lost)"

# issue #1507: the spawn's lease note (granted, or WHY not) reaches our caller verbatim.
SPAWN_NOTE='fleet: lease refused: HTTP 403 — fleet c45a2451 is not registered to this node — no lease on #777, falling back to the GitHub claim only' \
  run_fif --title "Ship it" --spawn
[ "$RC" -eq 0 ]                       || fail "G3 a lease note must not fail the create" "$(cat "$WORK/err")"
grep -qF 'fleet: lease refused: HTTP 403 — fleet c45a2451 is not registered to this node — no lease on #777' "$WORK/err" \
                                      || fail "G3 the spawn's lease note must pass through unchanged" "$(cat "$WORK/err")"
grep -q 'spawn was refused' "$WORK/err" && fail "G3 a spawn that went ahead is not 「refused」" "$(cat "$WORK/err")"
SPAWN_NOTE='dash-issue-session: #777 的入口租约已拿到 (m5)' run_fif --title "Ship it" --spawn
grep -qF '#777 的入口租约已拿到 (m5)' "$WORK/err" || fail "G3 the grant line must pass through" "$(cat "$WORK/err")"
ok "G3 --spawn passes the lease line (refused: <why> / 已拿到) through verbatim"

# ============================ H: --from role ===============================
run_fif --title "By worker" --from worker
grep -q '<!-- fleet:from role=worker' "$BODY" || fail "H --from must force the marker role word" "$(cat "$BODY")"
ok "H --from ROLE forces the provenance marker's role"

# ============================ I: fixed taxonomy, no gh read ================
# `scout` is canonical (fleet_labels_allowed) but was NOT in any live label list —
# it must be ACCEPTED (validation is against the FIXED set, #333), and the channel
# must make NO `gh label` call at all (deterministic, offline, no minting).
run_fif --title "Off-list canonical" --label "scout"
[ "$RC" -eq 0 ]                        || fail "I a canonical label must be accepted (got $RC)" "$(cat "$WORK/err")"
grep -q -- '--label scout' "$GH_LOG"   || fail "I the canonical label must reach create" "$(cat "$GH_LOG")"
grep -q '^label ' "$GH_LOG" && fail "I the channel must NOT read gh labels (fixed taxonomy)" "$(cat "$GH_LOG")"
ok "I validation is the fixed taxonomy, not the live label list (no gh label read)"

# ============================ J: default milestone applied ================
# FLEET_DEFAULT_MILESTONE set + NO --milestone → ensure the milestone (idempotent
# create) and pass --milestone <default> to create.
FLEET_DEFAULT_MILESTONE=Triage run_fif --title "Unsorted"
[ "$RC" -eq 0 ]                                        || fail "J default milestone should succeed" "$(cat "$WORK/err")"
grep -q 'api --method POST repos/acme/widgets/milestones' "$GH_LOG" \
  || fail "J must idempotently ensure the milestone (POST milestones)" "$(cat "$GH_LOG")"
grep -q -- '--milestone Triage' "$GH_LOG"             || fail "J create must carry --milestone Triage" "$(cat "$GH_LOG")"
ok "J FLEET_DEFAULT_MILESTONE defaults a milestone-less filing (ensured + applied)"

# ============================ K: explicit --milestone wins ================
FLEET_DEFAULT_MILESTONE=Triage run_fif --title "Has one" --milestone Roadmap
[ "$RC" -eq 0 ]                                        || fail "K explicit milestone should succeed" "$(cat "$WORK/err")"
grep -q -- '--milestone Roadmap' "$GH_LOG"            || fail "K explicit --milestone must reach create" "$(cat "$GH_LOG")"
grep -q -- '--milestone Triage' "$GH_LOG" && fail "K the default must NOT override an explicit --milestone" "$(cat "$GH_LOG")"
grep -q 'milestones' "$GH_LOG" && fail "K must NOT ensure the default when --milestone is explicit" "$(cat "$GH_LOG")"
ok "K an explicit --milestone wins over FLEET_DEFAULT_MILESTONE (no ensure)"

# ============================ L: unset default = unregressed ===============
run_fif --title "Plain"
[ "$RC" -eq 0 ]                                        || fail "L plain filing should succeed" "$(cat "$WORK/err")"
grep -q -- '--milestone' "$GH_LOG" && fail "L must NOT add a milestone when the knob is unset" "$(cat "$GH_LOG")"
grep -q 'milestones' "$GH_LOG" && fail "L must NOT touch the milestones API when the knob is unset" "$(cat "$GH_LOG")"
ok "L an unset FLEET_DEFAULT_MILESTONE is unregressed (no milestone, no API)"

# ============================ M: ensure-failure is best-effort =============
# The milestone can't be created (MS_CREATE_FAIL) and isn't present (MS_MISSING):
# the issue must still FILE (exit 0), just without a --milestone (issue #297).
MS_CREATE_FAIL=1 MS_MISSING=1 FLEET_DEFAULT_MILESTONE=Triage run_fif --title "Best effort"
[ "$RC" -eq 0 ]                                        || fail "M a milestone-ensure failure must still exit 0" "$(cat "$WORK/err")"
grep -q 'github.com/acme/widgets/issues/777' "$WORK/out" || fail "M the issue must still be FILED (URL echoed)" "$(cat "$WORK/out")"
grep -q -- '--milestone' "$GH_LOG" && fail "M must NOT pass --milestone when ensure failed" "$(cat "$GH_LOG")"
grep -qi 'could not ensure milestone' "$WORK/err"     || fail "M should warn that the milestone was skipped" "$(cat "$WORK/err")"
ok "M an ensure-failure files-without-milestone (fast path never wedged)"

# ============================ N: --bind binds the CALLER (issue #520) =======
# happy: the new number + descriptive title go to fleet-bind.sh, NOT the spawner.
run_fif --title "Own it" --bind
[ "$RC" -eq 0 ]                        || fail "N --bind should succeed" "$(cat "$WORK/err")"
grep -q '^777' "$BIND_LOG"             || fail "N --bind must hand the new number to fleet-bind.sh" "$(cat "$BIND_LOG")"
grep -q -- '--title Own it' "$BIND_LOG" || fail "N --bind must pass the descriptive --title" "$(cat "$BIND_LOG")"
[ -s "$SPAWN_LOG" ]                    && fail "N --bind must NOT spawn a worker" "$(cat "$SPAWN_LOG")"
ok "N --bind hands the new number + title to the in-place binder, no spawn"

# files-without-binding: a bind refusal (non-zero) leaves the issue FILED and says so.
BIND_RC=3 run_fif --title "Own it" --bind
[ "$RC" -eq 0 ]                        || fail "N2 a bind refusal must still exit 0 (issue filed)" "$(cat "$WORK/err")"
grep -q 'issues/777' "$WORK/out"       || fail "N2 the issue must still be FILED (URL echoed) on a bind refusal" "$(cat "$WORK/out")"
grep -qi 'bind' "$WORK/err"            || fail "N2 a bind refusal must be reported on stderr" "$(cat "$WORK/err")"
ok "N2 a bind refusal files-without-binding (issue not lost, reported)"

# --bind and --spawn are mutually exclusive: usage error, nothing filed.
run_fif --title "Both" --bind --spawn
[ "$RC" -eq 2 ]                        || fail "N3 --bind + --spawn must be a usage error (2)" "$(cat "$WORK/err")"
grep -q 'issue create' "$GH_LOG"       && fail "N3 a usage error must not file" "$(cat "$GH_LOG")"
ok "N3 --bind + --spawn is rejected up front (2), nothing filed"

# ============================ O: one issue per breakage (issue #2078) =======
# Three filers of one fingerprint at once: one create, two × exit 5 with that
# issue's URL, two 「同一故障」 comments on it, no spawn.
BRK="$WORK/brk"; mkdir -p "$BRK"
# run_brk <outfile-suffix> <args…> — like run_fif but with the breakage store and
# a per-call stdout/stderr/rc so three can run at once.
run_brk() {
  local sfx="$1"; shift
  PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" SPAWN_LOG="$SPAWN_LOG" BIND_LOG="$BIND_LOG" BODY="$WORK/body-$sfx" \
  FLEET_REPO="acme/widgets" FLEET_CONF_DIR="$WORK/conf" BRK_STORE="$BRK" \
    bash "$WORK/bin/fleet-issue-file.sh" "$@" >"$WORK/out-$sfx" 2>"$WORK/err-$sfx"
  echo $? > "$WORK/rc-$sfx"
}
: > "$GH_LOG"; : > "$SPAWN_LOG"; : > "$BIND_LOG"
for i in 1 2 3; do run_brk "o$i" --title "master 红" --breakage-key k-same --from "w$i" --spawn & done; wait
[ "$(ls "$BRK"/issue-* | wc -l | tr -d ' ')" = 1 ] || fail "O three filers of one key must create ONE issue" "$(cat "$WORK"/err-o? 2>/dev/null)"
n0=$(ls "$BRK"/issue-*); n0=${n0##*-}
grep -q '<!-- fleet:breakage key=k-same -->' "$BRK/issue-$n0" || fail "O the filed body must carry the fleet:breakage marker" "$(cat "$BRK/issue-$n0")"
grep -q '<!-- fleet:from role=w' "$BRK/issue-$n0"            || fail "O the filed body must still carry the fleet:from marker" "$(cat "$BRK/issue-$n0")"
zeros=0; fives=0
for i in 1 2 3; do
  case "$(cat "$WORK/rc-o$i")" in
    0) zeros=$((zeros+1)); grep -qx "https://github.com/acme/widgets/issues/$n0" "$WORK/out-o$i" || fail "O the first filer must print the new URL" "$(cat "$WORK/out-o$i")" ;;
    5) fives=$((fives+1)); grep -qx "https://github.com/acme/widgets/issues/$n0" "$WORK/out-o$i" || fail "O a later filer must print the FIRST issue's URL" "$(cat "$WORK/out-o$i" "$WORK/err-o$i")"
       grep -q 'already has an open issue' "$WORK/err-o$i" || fail "O exit 5 must say so on stderr" "$(cat "$WORK/err-o$i")" ;;
    *) fail "O filer $i exited $(cat "$WORK/rc-o$i")" "$(cat "$WORK/err-o$i")" ;;
  esac
done
[ "$zeros" = 1 ] && [ "$fives" = 2 ] || fail "O want 1 × exit 0 and 2 × exit 5, got $zeros / $fives"
[ "$(grep -c '同一故障，来自 w' "$BRK/comments-$n0" 2>/dev/null)" = 2 ] || fail "O the first issue must get exactly 2 「同一故障，来自 …」 comments" "$(cat "$BRK/comments-$n0" 2>/dev/null)"
grep -q 'fleet:no-relay' "$BRK/comments-$n0"  || fail "O the 「同一故障」 comment must be record-only (no-relay)" "$(cat "$BRK/comments-$n0")"
[ "$(grep -c . "$SPAWN_LOG")" = 1 ]           || fail "O only the first filer may spawn (want 1 spawn)" "$(cat "$SPAWN_LOG")"
[ -s "$WORK/conf/global/breakage/k-same/issue" ] || fail "O the lock must record the number for the same-second filers"
ok "O three concurrent filers of one breakage: 1 issue, 2 × exit 5 + URL, 2 comments, 1 spawn"

# The lock gone (another machine, or two minutes on): the marker in an OPEN
# issue is found over the REST list, same number, exit 5, no second create.
rm -rf "$WORK/conf/global/breakage"
run_brk o4 --title "又红了" --breakage-key k-same --from w4
[ "$(cat "$WORK/rc-o4")" = 5 ]                                        || fail "O2 a sighting with no lock must still dedup on the marker (exit 5)" "$(cat "$WORK/err-o4")"
grep -qx "https://github.com/acme/widgets/issues/$n0" "$WORK/out-o4"  || fail "O2 it must print the first issue's URL" "$(cat "$WORK/out-o4")"
[ "$(ls "$BRK"/issue-* | wc -l | tr -d ' ')" = 1 ]                    || fail "O2 no second issue"
grep -q 'issues?state=open' "$GH_LOG"                                 || fail "O2 the dedup must read the REST open-issue list" "$(cat "$GH_LOG")"
ok "O2 lock gone: the marker in an open issue is found over REST → exit 5, same number"

# ============================ P: another key files; a stale lock is nobody's ===
run_brk p1 --title "另一个故障" --breakage-key k-other --from w5
[ "$(cat "$WORK/rc-p1")" = 0 ]                     || fail "P a different key must file its own issue" "$(cat "$WORK/err-p1")"
[ "$(ls "$BRK"/issue-* | wc -l | tr -d ' ')" = 2 ] || fail "P a different key must create a second issue"
# k-stale: a lock with no number, older than the TTL — the holder died. It is
# dropped and the filer goes on (here: nothing open carries k-stale → it files).
mkdir -p "$WORK/conf/global/breakage/k-stale"
touch -t 202001010000 "$WORK/conf/global/breakage/k-stale"
FLEET_BREAKAGE_WAIT=1 run_brk p2 --title "旧锁" --breakage-key k-stale --from w6
[ "$(cat "$WORK/rc-p2")" = 0 ]                     || fail "P2 a stale lock must not block a filing" "$(cat "$WORK/err-p2")"
[ "$(ls "$BRK"/issue-* | wc -l | tr -d ' ')" = 3 ] || fail "P2 the filing behind a stale lock must create"
# A fresh lock with no number and a holder that never answers: no second filing
# (exit 5, nothing printed) — bounded by FLEET_BREAKAGE_WAIT.
mkdir -p "$WORK/conf/global/breakage/k-busy"
FLEET_BREAKAGE_WAIT=1 run_brk p3 --title "正在开" --breakage-key k-busy --from w7
[ "$(cat "$WORK/rc-p3")" = 5 ]                     || fail "P3 a live lock with no number yet must refuse a second filing (5)" "$(cat "$WORK/err-p3")"
[ "$(ls "$BRK"/issue-* | wc -l | tr -d ' ')" = 3 ] || fail "P3 nothing filed behind a live lock"
ok "P another key files; a stale lock is dropped; a live lock without a number refuses (5)"

# ============================ Q: the degenerate — no --breakage ================
rm -rf "$WORK/conf/global/breakage"
run_fif --title "普通单"
[ "$RC" -eq 0 ]                               || fail "Q an ordinary filing must still succeed" "$(cat "$WORK/err")"
grep -q 'issues?state=open\|actions/runs' "$GH_LOG" && fail "Q an ordinary filing must read no breakage path" "$(cat "$GH_LOG")"
grep -q 'fleet:breakage' "$BODY"                && fail "Q an ordinary filing's body carries no breakage marker" "$(cat "$BODY")"
[ -e "$WORK/conf/global/breakage" ]             && fail "Q an ordinary filing creates no lock dir"
ok "Q no --breakage and no red word: no probe, no list, no lock, no marker — unregressed"

# ============================ R: the fingerprint itself =======================
# Workflow 77 (selftests): red at aaaa…, red since bbbb… (run 9002), cccc… the
# last green. Workflow 78 (docs): its newest run was cancelled, the one before it
# green — not red. Rows are what the lib's --jq shapes: wid rid sha conclusion
# created name age.
FX="$WORK/fx"; mkdir -p "$FX/jobs" "$FX/logs"
printf 'selftests / shard 3\tRun tests\t2026-10-07T04:20:11.1234567Z ##[group]Run bash bin/run-selftests.sh\nselftests / shard 3\tRun tests\t2026-10-07T04:20:11.2234567Z ^[[36;1mbash bin/run-selftests.sh | grep -E "FAIL|error"^[[0m\nselftests / shard 3\tRun tests\t2026-10-07T04:20:11.3234567Z ##[endgroup]\nselftests / shard 3\tRun tests\t2026-10-07T04:20:11.5234567Z ok   all good: 5 assertions passed\nselftests / shard 3\tRun tests\t2026-10-07T04:20:12.0000000Z FAIL  lint: internal/api/roles.go:88:2: duplicate key "/v1/admin/drill" in map literal\n' > "$WORK/log-a"
sed 's/:88:2:/:91:4:/' "$WORK/log-a" > "$WORK/log-a2"
printf 'selftests / shard 3\tRun tests\t2026-10-07T04:30:00.0000000Z FAIL  bash32-array-selftest: bin/x.sh:12: bare array on an empty array\n' > "$WORK/log-b"
printf '501\tselftests / shard 3\n' > "$FX/jobs/9002"
red_runs() {  # red_runs [age of the newest red] [a cancelled run on top: 1]
  [ "${2:-0}" = 1 ] && printf '77\t9004\tdddd444dddd444\tcancelled\t2026-10-07T04:40:00Z\tselftests\t60\n'
  printf '77\t9003\taaaa111aaaa111\tfailure\t2026-10-07T04:35:00Z\tselftests\t%s\n' "${1:-100}"
  printf '78\t8002\taaaa111aaaa111\tcancelled\t2026-10-07T04:35:00Z\tdocs\t100\n'
  printf '77\t9002\tbbbb222bbbb222\tfailure\t2026-10-07T04:10:00Z\tselftests\t1600\n'
  printf '78\t8001\tbbbb222bbbb222\tsuccess\t2026-10-07T04:10:00Z\tdocs\t1600\n'
  printf '77\t9001\tcccc333cccc333\tsuccess\t2026-10-07T04:00:00Z\tselftests\t2200\n'
}
red_runs > "$FX/runs-red"; red_runs 100 1 > "$FX/runs-cancel-on-top"; red_runs 999999 > "$FX/runs-stale"
grep -v failure "$FX/runs-red" > "$FX/runs-green"
probe() {  # probe <runs file> <log> [VAR=val…] → the probe's lines
  local rf="$1" lg="$2"; shift 2
  env PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" BRK_RUNS_FILE="$rf" BRK_JOBS_DIR="$FX/jobs" BRK_LOG="$lg" "$@" \
      bash -c '. "$1/fleet-lib.sh"; fleet_breakage_probe acme/widgets' _ "$WORK/bin"
}
: > "$GH_LOG"
pa=$(probe "$FX/runs-red" "$WORK/log-a");  rca=$?
pa2=$(probe "$FX/runs-red" "$WORK/log-a2")
pb=$(probe "$FX/runs-red" "$WORK/log-b")
pc=$(probe "$FX/runs-cancel-on-top" "$WORK/log-a")
[ "$rca" = 0 ] && [ -n "$pa" ]                       || fail "R the probe must answer on a red workflow" "$(cat "$GH_LOG")"
[ "$(printf '%s\n' "$pa" | grep -c .)" = 1 ]         || fail "R one red workflow = one row (docs: cancelled over a green is not red)" "$pa"
ka=${pa%%	*}; ka2=${pa2%%	*}; kb=${pb%%	*}; kc=${pc%%	*}
case "$ka" in bbbb222-*) ;; *) fail "R the key must start with the red streak's FIRST commit (bbbb222), got [$ka]" "$pa" ;; esac
[ "$ka" = "$ka2" ]                                   || fail "R two logs that differ only in line numbers must give one key" "$pa"$'\n'"$pa2"
[ "$ka" != "$kb" ]                                   || fail "R a different error line must give a different key" "$pa"$'\n'"$pb"
[ "$ka" = "$kc" ]                                    || fail "R a cancelled run on top is no verdict — same key" "$pa"$'\n'"$pc"
printf '%s' "$pa" | cut -f3 | grep -qx 'selftests / shard 3' || fail "R field 3 is the failed job's name" "$pa"
printf '%s' "$pa" | cut -f4 | grep -qx 'FAIL lint: internal/api/roles.go: duplicate key "/v1/admin/drill" in map literal' \
                                                     || fail "R field 4 is the FAIL line, :line:col stripped, the echoed script and an ok line skipped" "$pa"
printf '%s' "$pa" | cut -f5 | grep -q '^selftests|selftests / shard 3$' || fail "R field 5 names the workflow + its failed jobs" "$pa"
grep -q 'run view --job 501 --log-failed' "$GH_LOG"  || fail "R the log is read with gh run view --job <job id> --log-failed" "$(cat "$GH_LOG")"
grep -q 'actions/runs/9002/jobs' "$GH_LOG"           || fail "R the jobs are the streak's FIRST run's (9002)" "$(cat "$GH_LOG")"
grep -q 'graphql' "$GH_LOG"                          && fail "R the probe must be REST only" "$(cat "$GH_LOG")"
pg=$(probe "$FX/runs-green" "$WORK/log-a"); rcg=$?
[ "$rcg" = 1 ] && [ -z "$pg" ]                       || fail "R no red workflow is rc 1 (not red)" "rc=$rcg [$pg]"
ps_=$(probe "$FX/runs-stale" "$WORK/log-a"); rcs=$?
[ "$rcs" = 1 ] && [ -z "$ps_" ]                      || fail "R a red older than FLEET_BREAKAGE_MAX_AGE is not red now" "rc=$rcs [$ps_]"
kk=$(env PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" BRK_RUNS_FILE="$FX/runs-red" BRK_JOBS_DIR="$FX/jobs" BRK_LOG="$WORK/log-a" \
      bash -c '. "$1/fleet-lib.sh"; fleet_breakage_key acme/widgets' _ "$WORK/bin")
[ "$kk" = "$ka" ]                                    || fail "R fleet_breakage_key is the probe's first field" "[$kk] vs [$ka]"
ok "R fingerprint = per-workflow last finished verdict; streak's first commit + its first failed job + error line sans line numbers"

# ============================ S: the real 2026-10-07 tokenledger-pg red =========
# Issue #2175: master went red at c902bf83 (tokenledger run 37611916613: `test`
# failed 11:21:10, `tokenledger-pg` 11:22:24); #2163 filed at 11:22:55 and #2170
# at 11:29:30 — the head was a6dd7c9b (tokenledger never ran on it) and then
# bb7da505 (its run unfinished until 11:31:43). The old probe read the head's
# check-runs and called master green both times. The logs are excerpts of the
# real `gh run view --log-failed` output: a BOM on line 1, the echoed script in
# literal `^[[36;1m` (its own `--- FAIL` in a grep), the go test lines.
pglog() {  # pglog <time> → the tokenledger-pg job log
  printf 'tokenledger-pg\tstore + api tests on Postgres\t\357\273\2772026-10-07T%s.0341145Z ##[group]Run set -o pipefail\n' "$1"
  printf 'tokenledger-pg\tstore + api tests on Postgres\t2026-10-07T%s.0342114Z ^[[36;1mgo test -race -count=1 -v ./internal/store/... ./internal/api/... 2>&1 | tee /tmp/pg.log | grep -E '"'"'^(pg leg|  SKIP-PG|--- FAIL|--- SKIP|ok  |FAIL)'"'"'^[[0m\n' "$1"
  printf 'tokenledger-pg\tstore + api tests on Postgres\t2026-10-07T%s.0413598Z shell: /usr/bin/bash -e {0}\n' "$1"
  printf 'tokenledger-pg\tstore + api tests on Postgres\t2026-10-07T%s.0414807Z ##[endgroup]\n' "$1"
  printf 'tokenledger-pg\tstore + api tests on Postgres\t2026-10-07T%s.7563648Z pg leg: 0 test(s) not run on Postgres\n' "$1"
  printf 'tokenledger-pg\tstore + api tests on Postgres\t2026-10-07T%s.7564433Z ok  \tgithub.com/verkyyi/claude-fleet/tokenledger/internal/store\t151.640s\n' "$1"
  printf 'tokenledger-pg\tstore + api tests on Postgres\t2026-10-07T%s.7565667Z --- FAIL: TestFleetUsers_MachineLoginTakesOverAnOldIdentitysKey (%s)\n' "$1" "$2"
  printf 'tokenledger-pg\tstore + api tests on Postgres\t2026-10-07T%s.7566367Z --- FAIL: TestDropLegacyMachineLogins (%s)\n' "$1" "$3"
  printf 'tokenledger-pg\tstore + api tests on Postgres\t2026-10-07T%s.7567287Z FAIL\tgithub.com/verkyyi/claude-fleet/tokenledger/internal/api\t442.700s\n' "$1"
  printf 'tokenledger-pg\tstore + api tests on Postgres\t2026-10-07T%s.7581745Z ##[error]Process completed with exit code 1.\n' "$1"
}
pglog 11:14:03 1.12s 0.92s > "$FX/logs/112763377741"     # c902bf83's run
pglog 11:24:40 1.31s 0.88s > "$FX/logs/112766631835"     # bb7da505's run
printf 'test\tRun go test -race ./...\t2026-10-07T11:21:08.0158841Z --- FAIL: TestNodePlaceIdleNodeStaysLocal (1.19s)\ntest\tRun go test -race ./...\t2026-10-07T11:21:08.0495450Z FAIL\tgithub.com/verkyyi/claude-fleet/tokenledger/internal/api\t342.280s\n' > "$FX/logs/112763377674"
printf '112763377674\ttest\n112763377741\ttokenledger-pg\n' > "$FX/jobs/37611916613"
printf '112766631871\ttest\n112766631835\ttokenledger-pg\n' > "$FX/jobs/37613311153"
tl_runs() {  # tl_runs <age> [bb7da505 finished: 1] — newest first, as the REST list
  [ "${2:-0}" = 1 ] && printf '100\t37613311153\tbb7da5050000\tfailure\t2026-10-07T11:19:36Z\ttokenledger\t%s\n' "$1"
  printf '200\t37611990000\ta6dd7c9b0000\tsuccess\t2026-10-07T11:07:45Z\tselftests\t%s\n' "$1"
  printf '100\t37611916613\tc902bf830000\tfailure\t2026-10-07T11:07:06Z\ttokenledger\t%s\n' "$1"
  printf '100\t37611854715\t6ff6f3850000\tcancelled\t2026-10-07T11:06:33Z\ttokenledger\t%s\n' "$1"
  printf '100\t37611774149\t38ae532a0000\tsuccess\t2026-10-07T11:05:50Z\ttokenledger\t%s\n' "$1"
}
tl_runs 900 > "$FX/runs-2163"; tl_runs 1300 > "$FX/runs-2170"; tl_runs 1500 1 > "$FX/runs-later"
sp() { env PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" BRK_RUNS_FILE="$1" BRK_JOBS_DIR="$FX/jobs" BRK_LOGS_DIR="$FX/logs" \
         bash -c '. "$1/fleet-lib.sh"; fleet_breakage_probe verkyyi/claude-fleet master' _ "$WORK/bin"; }
s63=$(sp "$FX/runs-2163"); s70=$(sp "$FX/runs-2170"); slt=$(sp "$FX/runs-later")
[ -n "$s63" ] && [ -n "$s70" ] && [ -n "$slt" ]      || fail "S master WAS red at #2163's and #2170's filing — the probe must say so" "[$s63] [$s70] [$slt]"
k63=${s63%%	*}; k70=${s70%%	*}; klt=${slt%%	*}
[ "$k63" = "$k70" ] && [ "$k70" = "$klt" ]           || fail "S #2163, #2170 and a later sighting are ONE breakage" "$s63"$'\n'"$s70"$'\n'"$slt"
case "$k63" in c902bf8-*) ;; *) fail "S the streak started at c902bf83, got [$k63]" "$s63" ;; esac
printf '%s' "$s63" | cut -f5 | grep -q 'tokenledger-pg' || fail "S the names carry the failed tokenledger-pg job" "$s63"
l1=$(env BIN="$WORK/bin" bash -c '. "$BIN/fleet-lib.sh"; fleet_breakage_norm_line' < "$FX/logs/112763377741")
l2=$(env BIN="$WORK/bin" bash -c '. "$BIN/fleet-lib.sh"; fleet_breakage_norm_line' < "$FX/logs/112766631835")
[ "$l1" = '--- FAIL: TestFleetUsers_MachineLoginTakesOverAnOldIdentitysKey' ] && [ "$l1" = "$l2" ] \
                                                     || fail "S both real pg logs normalize to the same first --- FAIL line (BOM, ^[ echo, durations dropped)" "[$l1] [$l2]"
for t in 'tokenledger-pg 红：hub_settings_legacy 两个测试在 Postgres 上报 collation "nocase" 不存在' \
         'master 红：tokenledger-pg 上 TestDropLegacyMachineLogins / TestFleetUsers_MachineLoginTakesOverAnOldIdentitysKey 失败'; do
  pk=$(printf '%s\n' "$s63" | env BIN="$WORK/bin" bash -c '. "$BIN/fleet-lib.sh"; fleet_breakage_pick "$1" master' _ "$t")
  [ "${pk%%	*}" = "$k63" ]                         || fail "S the real issue title must pick the red row: $t" "[$pk]"
done
pk=$(printf '%s\n' "$s63" | env BIN="$WORK/bin" bash -c '. "$BIN/fleet-lib.sh"; fleet_breakage_pick "$1" master' _ '登录页按钮点了没反应，报错 undefined')
[ -z "$pk" ]                                         || fail "S a text naming neither the base branch nor a red check picks nothing" "[$pk]"
ok "S the real 2026-10-07 red: #2163 / #2170 / later = one key at c902bf8; both pg logs → one --- FAIL line; both titles pick it"

# ============================ T: auto — no flag, a red base the text names =====
rm -rf "$WORK/conf/global/breakage"; BRK2="$WORK/brk2"; mkdir -p "$BRK2"
run_auto() {  # run_auto <sfx> <runs file> <args…>
  local sfx="$1" rf="$2"; shift 2
  PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" SPAWN_LOG="$SPAWN_LOG" BIND_LOG="$BIND_LOG" BODY="$WORK/body-$sfx" \
  FLEET_REPO="verkyyi/claude-fleet" FLEET_BASE_BRANCH=master FLEET_CONF_DIR="$WORK/conf" BRK_STORE="$BRK2" \
  BRK_RUNS_FILE="$rf" BRK_JOBS_DIR="$FX/jobs" BRK_LOGS_DIR="$FX/logs" \
    bash "$WORK/bin/fleet-issue-file.sh" "$@" >"$WORK/out-$sfx" 2>"$WORK/err-$sfx"
  echo $? > "$WORK/rc-$sfx"
}
: > "$GH_LOG"
run_auto t1 "$FX/runs-2163" --title 'master 红：tokenledger-pg 上 TestDropLegacyMachineLogins 失败' --from w1
[ "$(cat "$WORK/rc-t1")" = 0 ]                       || fail "T1 an auto breakage filing must file" "$(cat "$WORK/err-t1")"
nt=$(ls "$BRK2"/issue-*); nt=${nt##*-}
grep -q "<!-- fleet:breakage key=$k63 -->" "$BRK2/issue-$nt" || fail "T1 no flag, red base, text names it ⇒ the breakage marker" "$(cat "$BRK2/issue-$nt")"
grep -q 'auto, issue #2175' "$WORK/err-t1"           || fail "T1 the filer says it went auto" "$(cat "$WORK/err-t1")"
rm -rf "$WORK/conf/global/breakage"
run_auto t2 "$FX/runs-2170" --title 'tokenledger-pg 红：hub_settings_legacy 两个测试' --from w2 --spawn
[ "$(cat "$WORK/rc-t2")" = 5 ]                       || fail "T2 a second auto sighting dedups (exit 5)" "$(cat "$WORK/err-t2")"
grep -q -- '--no-breakage' "$WORK/err-t2"            || fail "T2 an auto exit 5 names the way out (--no-breakage)" "$(cat "$WORK/err-t2")"
[ "$(ls "$BRK2"/issue-* | wc -l | tr -d ' ')" = 1 ]  || fail "T2 no second issue"
run_auto t3 "$FX/runs-2170" --title 'master 红：tokenledger-pg 另一个问题' --no-breakage
[ "$(cat "$WORK/rc-t3")" = 0 ] && ! grep -q 'fleet:breakage' "$WORK/body-t3" \
                                                     || fail "T3 --no-breakage files plain" "$(cat "$WORK/err-t3")"
run_auto t4 "$FX/runs-green" --title 'master 红了？其实是绿的' --repo acme/widgets
[ "$(cat "$WORK/rc-t4")" = 0 ] && ! grep -q 'fleet:breakage' "$WORK/body-t4" \
                                                     || fail "T4 a red word on a green base files plain" "$(cat "$WORK/err-t4")"
[ -s "$WORK/err-t4" ] && grep -q breakage "$WORK/err-t4" && fail "T4 auto on a green base says nothing" "$(cat "$WORK/err-t4")"
run_auto t5 "$FX/runs-2170" --title '登录按钮报错 undefined'
[ "$(cat "$WORK/rc-t5")" = 0 ] && ! grep -q 'fleet:breakage' "$WORK/body-t5" \
                                                     || fail "T5 a red base the text does not name files plain" "$(cat "$WORK/err-t5")"
ok "T auto: no flag + red base the text names ⇒ breakage (marker, exit 5 dedup); --no-breakage / green base / unrelated text file plain"

# --- U. a title is the issue's use (issue #2545): a long title, or one opening on a
# script name, files all the same with ONE hint line; a short use says nothing.
run_auto u1 "$FX/runs-green" --title '托管机器上旧版 fleet host on 以登录身份重登记，入口换发令牌、那条 lane 被拒'
[ "$(cat "$WORK/rc-u1")" = 0 ] && grep -q 'hint: the title is [0-9]* columns' "$WORK/err-u1" \
                                                     || fail "U1 a long title files, with a hint" "$(cat "$WORK/err-u1")"
run_auto u2 "$FX/runs-green" --title 'fleet-issue-file.sh 对超长标题给提示'
[ "$(cat "$WORK/rc-u2")" = 0 ] && grep -q 'hint: the title opens on a script name' "$WORK/err-u2" \
                                                     || fail "U2 a script-name title files, with a hint" "$(cat "$WORK/err-u2")"
run_auto u3 "$FX/runs-green" --title '每日推送没跑成'
[ "$(cat "$WORK/rc-u3")" = 0 ] && ! grep -q 'hint:' "$WORK/err-u3" \
                                                     || fail "U3 a short use files with no hint" "$(cat "$WORK/err-u3")"
ok "U title hint: long / script-name titles file with one hint line, a short use says nothing"

# --- V. which rule dispatched it (issue #2786) -------------------------------------
marked=0
for n in 1 2 3 4 5; do
  FAKE_FLEET_ROLE=orchestrator TMUX_PANE=%9 run_fif --title "形状 $n" --body "要做的事 $n" --rule "$n"
  [ "$RC" -eq 0 ] || fail "V1 --rule $n should file" "$(cat "$WORK/err")"
  grep -q '<!-- fleet:from role=orchestrator' "$BODY" || fail "V1 the orchestrator's filing says role=orchestrator" "$(cat "$BODY")"
  grep -qx "按规则 $n 派发" "$BODY" && grep -Eq "^<!-- fleet:rule n=$n v=[0-9a-f]{10} -->$" "$BODY" && marked=$((marked+1))
done
[ "$marked" = 5 ] || fail "V1 5/5 shapes carry their rule mark (got $marked/5)" "$(cat "$BODY")"
: > "$FLEET_RULES_LOG"
FAKE_FLEET_ROLE=orchestrator TMUX_PANE=%9 run_fif --title "没注明" --body "随手一单"
[ "$RC" -eq 0 ] && grep -qx '未注明规则' "$BODY" && grep -q $'\tunmarked\trepo=acme/widgets\ttitle=没注明' "$FLEET_RULES_LOG" \
  || fail "V2 an orchestrator filing with no rule files with 「未注明规则」 + a log line" "$(cat "$BODY" "$FLEET_RULES_LOG" "$WORK/err")"
FAKE_FLEET_ROLE=orchestrator TMUX_PANE=%9 run_fif --title "已带" --body $'x\n<!-- fleet:rule n=1 v=abcdef0123 -->'
grep -q '未注明规则' "$BODY" && fail "V3 a body already carrying a fleet:rule marker gets no 「未注明规则」" "$(cat "$BODY")"
run_fif --title "没这条" --rule 999
[ "$RC" -eq 2 ] && ! grep -q 'issue create' "$GH_LOG" || fail "V4 a rule the table lacks is refused (exit 2, no create; got $RC)" "$(cat "$WORK/err")"
run_fif --title "别处" --body "y"
grep -q '未注明规则\|fleet:rule' "$BODY" && fail "V5 a non-orchestrator filing gets no rule line" "$(cat "$BODY")"
ok "V rules: 5/5 orchestrator shapes marked; no rule ⇒ 「未注明规则」 + log; unknown rule refused; elsewhere untouched"

printf '\nselftest OK: %s assertions passed (channel: validate · provenance · create · milestone · parent · spawn · bind · breakage)\n' "$pass"
exit 0
