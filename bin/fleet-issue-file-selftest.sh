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
#   Z. the red THIS time (issue #4774), on the two real misfiles: #4771 (the
#      release train cancelled by its failfast with Linux / shard 5 red, a macOS
#      nightly red since earlier) and #4598 (selftests / shard 16 red in a branch
#      dispatch run the text names, the base's streak red on shard 8): a cancelled
#      run with a failed job is red, a channel of its own (macOS) is skipped, the
#      newest red comes first, the job the text names wins (`shard 1` ≠ `shard 16`),
#      a bare duration (`2.6s`) is not part of the key, and the filer keys a run
#      its text names.
#   T. no auto road (issue #4271, replacing #2175's): no flag + a red base + a
#      text naming it ⇒ an ORDINARY issue, no probe; the #4268 shape (a design
#      ticket mentioning 「红」) files plain and a later one is not swallowed;
#      only --breakage fingerprints; --no-breakage still parses.
#   Y. one issue per fingerprint across shas (issue #4271): three shas red ⇒ 1
#      issue + 3 comments (sha + link), a repeat sha adds none; closed + red on a
#      sha containing the fix ⇒ reopened; on an older sha ⇒ only noted; closed by
#      hand + a newer sha ⇒ reopened.
#   V. the rule table is gone (issue #4340; #2786 wrote it): --rule accepted and
#      ignored for one version, no 「按规则 N 派发」 / fleet:rule / 「未注明规则」
#      line from any pane, the orchestrator's included.
#   W. any pane spawns, a worker's too (issue #4591 lifted #2960's exit 6); a
#      breakage a worker files WITHOUT --spawn (issue #4337) is ONE issue + ONE
#      breakage alert + ONE message to its parent (wid: on another machine), no
#      queue file and no spawn; no parent ⇒ said, filed all the same; one filed
#      with --spawn spawns its fixer, no alert, nothing queued.
#   X. retired automation labels autoland/autofill are rejected before filing
#      (issue #4326), alone or alongside valid labels.
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
cp "$SRC" "$WORK/bin/fleet-issue-file.sh"; cp "$LIB" "$WORK/bin/fleet-lib.sh"; cp "${LIB%/*}/fleet-client-core.sh" "$WORK/bin/fleet-client-core.sh"
cp "$BIN/fleet-gh-lib.sh" "$WORK/bin/fleet-gh-lib.sh"   # its write queue (issue #1264)
cp "$BIN/fleet-ticket.sh" "$BIN/fleet_ticket.py" "$WORK/bin/"   # the ticket door it files through (issue #3595)
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
    elif [ "$2" = reopen ]; then
      printf '%s\n' "$*" >> "$GH_LOG"
      [ -n "${BRK_STORE:-}" ] && [ -f "$BRK_STORE/closed-$3" ] && mv "$BRK_STORE/closed-$3" "$BRK_STORE/issue-$3"
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
    p=''; for a in "$@"; do case "$a" in repos/*|search/*) p="$a";; esac; done
    # --- issue #4271: closed issues under a key, how one was closed, what a sha
    # contains, and what is already on record — all from BRK_STORE.
    if [ -n "${BRK_STORE:-}" ]; then
      case "$p" in
        search/*)                  exit 0 ;;
        repos/*/issues\?state=closed*) for f in "$BRK_STORE"/closed-*; do [ -e "$f" ] || continue; case "$f" in *.at) continue ;; esac
                                     printf '%s\t%s\t%s\n' "${f##*-}" "$(cat "$f.at" 2>/dev/null)" "$(tr '\n' ' ' < "$f")"; done; exit 0 ;;
        repos/*/issues/*/events*)  n=${p#*/issues/}; n=${n%%/*}; cat "$BRK_STORE/fix-$n" 2>/dev/null; exit 0 ;;
        repos/*/issues/*/comments*) n=${p#*/issues/}; n=${n%%/*}; cat "$BRK_STORE/comments-$n" 2>/dev/null; exit 0 ;;
        repos/*/issues/[0-9]*)     n=${p#*/issues/}; case "$n" in *[!0-9]*) ;; *) cat "$BRK_STORE/issue-$n" "$BRK_STORE/closed-$n" 2>/dev/null; exit 0 ;; esac ;;
        repos/*/compare/*)         c=${p#*/compare/}; cat "$BRK_STORE/compare-${c##*...}" 2>/dev/null; exit 0 ;;
        repos/*/commits/*)         c=${p#*/commits/}; cat "$BRK_STORE/date-$c" 2>/dev/null; exit 0 ;;
      esac
    fi
    case "$p" in
      repos/acme/widgets)                    echo main; exit 0 ;;
      */actions/runs\?*)                     [ -n "${BRK_RUNS_FILE:-}" ] && cat "$BRK_RUNS_FILE"; exit 0 ;;
      */actions/runs/*/jobs*)                r=${p#*/actions/runs/}; r=${r%%/*}
                                             [ -n "${BRK_JOBS_DIR:-}" ] && [ -f "$BRK_JOBS_DIR/$r" ] && cat "$BRK_JOBS_DIR/$r"; exit 0 ;;
      */actions/runs/[0-9]*)                 r=${p##*/actions/runs/}   # one run's metadata (issue #4774: a run the text names)
                                             [ -n "${BRK_RUNMETA_DIR:-}" ] && [ -f "$BRK_RUNMETA_DIR/$r" ] && cat "$BRK_RUNMETA_DIR/$r"; exit 0 ;;
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
  display-message) case "$*" in *-p*) case "$*" in *session_name*) echo fifsess ;; *@fleet_role*) echo "${FAKE_FLEET_ROLE:-}" ;; *@origin_wid*) echo "${FAKE_ORIGIN_WID:-}" ;; *) echo '' ;; esac ;; esac ;;
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
SPAWN_NOTE='dash-issue-session: #777 的入口租约已拿到 (mac-b)' run_fif --title "Ship it" --spawn
grep -qF '#777 的入口租约已拿到 (mac-b)' "$WORK/err" || fail "G3 the grant line must pass through" "$(cat "$WORK/err")"
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
printf '503\tselftests / shard 3\n' > "$FX/jobs/9003"   # the newest red: the same job, still red
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
case "$ka" in ci-*) ;; *) fail "R the key is the channel (ci-) + the failed step, got [$ka]" "$pa" ;; esac
case "$ka" in *bbbb222*|*aaaa111*) fail "R no commit in the key (issue #4271), got [$ka]" "$pa" ;; esac
printf '%s' "$pa" | cut -f2 | grep -qx 'bbbb222bbbb222' || fail "R field 2 is still the red streak's FIRST commit (bbbb222)" "$pa"
printf '%s' "$pa" | cut -f6 | grep -qx '9002'          || fail "R field 6 is that run's id (the sighting's link)" "$pa"
[ "$ka" = "$ka2" ]                                   || fail "R two logs that differ only in line numbers must give one key" "$pa"$'\n'"$pa2"
[ "$ka" != "$kb" ]                                   || fail "R a different error line must give a different key" "$pa"$'\n'"$pb"
[ "$ka" = "$kc" ]                                    || fail "R a cancelled run on top is no verdict — same key" "$pa"$'\n'"$pc"
printf '%s' "$pa" | cut -f3 | grep -qx 'selftests / shard 3' || fail "R field 3 is the failed job's name" "$pa"
printf '%s' "$pa" | cut -f4 | grep -qx 'FAIL lint: internal/api/roles.go: duplicate key "/v1/admin/drill" in map literal' \
                                                     || fail "R field 4 is the FAIL line, :line:col stripped, the echoed script and an ok line skipped" "$pa"
printf '%s' "$pa" | cut -f5 | grep -q '^selftests|selftests / shard 3|shard 3|9003|9002|' || fail "R field 5 names the workflow, the failed job, its short name, the runs" "$pa"
grep -q 'run view --job 503 --log-failed' "$GH_LOG"  || fail "R the log is the NEWEST red run's job's, read with gh run view --job <job id> --log-failed (#4774)" "$(cat "$GH_LOG")"
grep -q 'actions/runs/9002/jobs' "$GH_LOG"           || fail "R the streak is walked back to where that job first failed (9002)" "$(cat "$GH_LOG")"
grep -q 'graphql' "$GH_LOG"                          && fail "R the probe must be REST only" "$(cat "$GH_LOG")"
pg=$(probe "$FX/runs-green" "$WORK/log-a"); rcg=$?
[ "$rcg" = 1 ] && [ -z "$pg" ]                       || fail "R no red workflow is rc 1 (not red)" "rc=$rcg [$pg]"
{ printf '77\t9005\teeee555eeee555\tfailure\t2026-10-07T04:50:00Z\tselftests\t30\trelease train (drill portability-selftest.sh)\n'; cat "$FX/runs-green"; } > "$FX/runs-drill"
pd=$(probe "$FX/runs-drill" "$WORK/log-a"); rcd=$?
[ "$rcd" = 1 ] && [ -z "$pd" ]                       || fail "R a drill run (title «(drill …)», issue #3372) is no verdict on master" "rc=$rcd [$pd]"
ps_=$(probe "$FX/runs-stale" "$WORK/log-a"); rcs=$?
[ "$rcs" = 1 ] && [ -z "$ps_" ]                      || fail "R a red older than FLEET_BREAKAGE_MAX_AGE is not red now" "rc=$rcs [$ps_]"
kk=$(env PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" BRK_RUNS_FILE="$FX/runs-red" BRK_JOBS_DIR="$FX/jobs" BRK_LOG="$WORK/log-a" \
      bash -c '. "$1/fleet-lib.sh"; fleet_breakage_key acme/widgets' _ "$WORK/bin")
[ "$kk" = "$ka" ]                                    || fail "R fleet_breakage_key is the probe's first field" "[$kk] vs [$ka]"
ok "R fingerprint = per-workflow last finished verdict; ci- + its first failed job + error line sans line numbers, no commit (the streak's first one reported beside)"

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
sed 's/(1.19s)/(1.27s)/' "$FX/logs/112763377674" > "$FX/logs/112766631871"   # bb7da505's `test`: still red
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
# One row per failed job (issue #4774); the pg row is the one the filings named.
pgrow() { printf '%s\n' "$1" | awk -F'\t' '$3 == "tokenledger-pg"'; }
k63=$(pgrow "$s63" | cut -f1); k70=$(pgrow "$s70" | cut -f1); klt=$(pgrow "$slt" | cut -f1)
[ -n "$k63" ] && [ "$k63" = "$k70" ] && [ "$k70" = "$klt" ] || fail "S #2163, #2170 and a later sighting are ONE breakage" "$s63"$'\n'"$s70"$'\n'"$slt"
[ "$(printf '%s\n' "$slt" | awk -F'\t' '$3 == "test"' | cut -f1)" = "$(printf '%s\n' "$s63" | awk -F'\t' '$3 == "test"' | cut -f1)" ] \
                                                     || fail "S the other failed job (test) is its own row, one key across sightings too" "$s63"$'\n'"$slt"
pgrow "$slt" | cut -f2 | grep -q '^c902bf8'          || fail "S the later sighting's pg row walks back to where it went red (c902bf83)" "$slt"
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
ok "S the real 2026-10-07 red: #2163 / #2170 / later = one key (streak at c902bf8); both pg logs → one --- FAIL line; both titles pick it"

# ============================ Z: the red THIS time (issue #4774) ===============
# #4771 (2026-10-18): release train run 39170235632 on 10bb05b5 went red on Linux /
# shard 5 (selftest-partitions-selftest.sh) and the train's failfast CANCELLED the
# run — the probe passed it over as no verdict, so the only red left was
# selftests-macos.yml's nightly (macOS / shard 1, red since 8937c5a) and #4771 was
# stamped `macOS / shard 1 @ 8937c5a`. The logs are excerpts of the real ones.
mkdir -p "$FX/meta"
u_log5() {  # u_log5 <duration> → Linux / shard 5's log
  local t='Linux / shard 5	UNKNOWN STEP	2026-10-18T22:0'
  printf '%s2:18.6712171Z ^[[36;1mif [ -n "$CHANGED_BASE" ] && [ -n "$PREV_FAILS" ] && has --prev-fails; then^[[0m\n' "$t"
  printf '%s6:13.3237822Z ok   limit classification reads the call'"'"'s own error text (graphql / core / secondary / none)\n' "$t"
  printf '%s8:23.4274349Z PASS fleet-break-it-node: 56 discovered cases, 6 parts, every case once; growth covered\n' "$t"
  printf '%s8:23.4514259Z Traceback (most recent call last):\n' "$t"
  printf '%s8:23.4514457Z   File "<stdin>", line 103, in <module>\n' "$t"
  printf "%s8:23.4515711Z AssertionError: ('fleet-cleanup-idle', 'groups != part', ['PolicyGrammar.test_idle_owned_holds_off_the_reopen'])\n" "$t"
  printf '%s8:23.4771710Z FAIL  selftest-partitions-selftest.sh                   %s (exit 1)\n' "$t" "$1"
  printf '%s8:23.4772841Z ---------------- slowest 10 of 28 ----------------\n' "$t"
  printf '%s8:23.5224409Z ##[error]Process completed with exit code 1.\n' "$t"
}
u_log5 2.6s > "$FX/logs/117802200944"
printf 'train\tUNKNOWN STEP\t2026-10-18T22:09:13.0000000Z ##[error]Process completed with exit code 1.\n' > "$FX/logs/117803738916"
printf 'macOS / shard 1\tUNKNOWN STEP\t2026-10-18T18:40:00.0000000Z FAIL B: a change with no script should pass (nothing to lint), not fail\n' > "$FX/logs/900"
printf '117802200944\tLinux / shard 5\n117803738916\ttrain\n' > "$FX/jobs/39170235632"
printf '900\tmacOS / shard 1\n' > "$FX/jobs/39164519771"
u71_runs() {  # newest first, as the REST list: wid rid sha conclusion created name age title path
  printf '381130352\t39170235632\t10bb05b5aaaa\tcancelled\t2026-10-18T21:50:00Z\trelease train\t900\trelease train\t.github/workflows/release-train.yml\n'
  printf '99\t39164519771\t8937c5a842eb\tfailure\t2026-10-18T18:17:00Z\tselftests (macOS)\t13000\tselftests (macOS)\t.github/workflows/selftests-macos.yml\n'
  printf '381130352\t39164193455\t8937c5a842eb\tsuccess\t2026-10-18T18:10:00Z\trelease train\t13400\trelease train\t.github/workflows/release-train.yml\n'
  printf '99\t39100000000\t7777777bbbbb\tsuccess\t2026-10-17T18:17:00Z\tselftests (macOS)\t99000\tselftests (macOS)\t.github/workflows/selftests-macos.yml\n'
}
u71_runs > "$FX/runs-4771"
up() {  # up <runs file> [VAR=val…] → the probe's lines on verkyyi/claude-fleet
  local rf="$1"; shift
  env PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" BRK_RUNS_FILE="$rf" BRK_JOBS_DIR="$FX/jobs" BRK_LOGS_DIR="$FX/logs" BRK_RUNMETA_DIR="$FX/meta" "$@" \
      bash -c '. "$1/fleet-lib.sh"; fleet_breakage_probe verkyyi/claude-fleet master' _ "$WORK/bin"
}
upick() { env BIN="$WORK/bin" bash -c '. "$BIN/fleet-lib.sh"; fleet_breakage_pick "$1" master' _ "$1"; }
t71='master 红：selftest-partitions-selftest.sh — fleet-cleanup-idle 测试分组与分片表不一致'
b71='列车 39170235632（10bb05b5，master 头）在 Linux / shard 5 红，同一提交单独重跑仍红：AssertionError: (fleet-cleanup-idle, groups != part)'
u1=$(up "$FX/runs-4771"); rcu=$?
[ "$rcu" = 0 ] && [ -n "$u1" ]                       || fail "Z1 a run the train's failfast cancelled with a red shard IS red (#4771)" "rc=$rcu $(cat "$GH_LOG")"
printf '%s\n' "$u1" | cut -f3 | grep -q 'macOS'      && fail "Z1 selftests-macos.yml has its own channel (macos-…): not a ci- row" "$u1"
r1=$(printf '%s\n' "$u1" | head -1)
printf '%s' "$r1" | cut -f3 | grep -qx 'Linux / shard 5' || fail "Z1 the first row is the shard that went red first (Linux / shard 5)" "$u1"
printf '%s' "$r1" | cut -f4 | grep -qx 'FAIL selftest-partitions-selftest.sh (exit 1)' \
                                                     || fail "Z1 its line is the FAIL line with the bare 2.6s gone" "$r1"
printf '%s' "$r1" | cut -f2 | grep -q '^10bb05b5'    || fail "Z1 the sha is where it went red (10bb05b5), not the macOS 8937c5a" "$r1"
printf '%s' "$r1" | cut -f6 | grep -qx '39170235632' || fail "Z1 the run is the train's 39170235632" "$r1"
printf '%s' "$r1" | cut -f5 | tr '|' '\n' | grep -qx 'selftest-partitions-selftest.sh' \
                                                     || fail "Z1 the names carry the selftest the log failed" "$r1"
u_log5 3.1s > "$FX/logs/117802200944"
u1b=$(up "$FX/runs-4771")
[ "${u1b%%	*}" = "${r1%%	*}" ]                   || fail "Z1 a rerun that took 3.1s instead of 2.6s is the same key" "$r1"$'\n'"$u1b"
# Even with the macOS workflow in (no skip): the newest red first, and #4771's
# own words pick the shard, never the nightly.
u2=$(up "$FX/runs-4771" FLEET_BREAKAGE_SKIP_RE=)
printf '%s\n' "$u2" | tail -1 | cut -f3 | grep -qx 'macOS / shard 1' || fail "Z2 no skip: the macOS row is there, after the newer train" "$u2"
pk=$(printf '%s\n' "$u2" | upick "$t71"$'\n'"$b71")
[ "${pk%%	*}" = "${r1%%	*}" ]                   || fail "Z2 #4771's title + body pick Linux / shard 5 (not macOS / shard 1)" "[$pk]"
pk=$(printf '%s\n' "$u2" | upick 'master 红了，原因待查')
[ "${pk%%	*}" = "${r1%%	*}" ]                   || fail "Z2 a text naming no check: the NEWEST red, not the oldest" "[$pk]"

# #4598 (2026-10-17): selftests / shard 16 (fleet-bin-inventory-selftest.sh) red
# in run 39025697982 — a workflow_dispatch on issue-3884, never on master's list —
# while master's own selftests streak had started on shard 8 (transfer-norepo):
# the fingerprint said shard 8. Its text names the run; the filer keys THAT run.
printf 'failure\t14bad884cccc\tselftests\tselftests\n' > "$FX/meta/39025697982"
printf '117376131742\tselftests / shard 16\n' > "$FX/jobs/39025697982"
{ printf 'selftests / shard 16\tUNKNOWN STEP\t2026-10-17T10:41:32.3841558Z 未归类\t9\n'
  printf 'selftests / shard 16\tUNKNOWN STEP\t2026-10-17T10:41:32.4001687Z FAIL  fleet-bin-inventory-selftest.sh                  13.1s (exit 1)\n'
  printf 'selftests / shard 16\tUNKNOWN STEP\t2026-10-17T10:44:46.1443959Z ok   FAIL  hub 400 → exit 1 with its status only; others still land; no token shown\n'
  printf 'selftests / shard 16\tUNKNOWN STEP\t2026-10-17T10:46:40.9332804Z ##[error]Process completed with exit code 1.\n'; } > "$FX/logs/117376131742"
printf 'selftests / shard 8\tUNKNOWN STEP\t2026-10-17T03:00:00.0000000Z FAIL  transfer-norepo-selftest.sh                  41.0s (exit 1)\n' > "$FX/logs/800"
printf 'selftests / shard 1\tUNKNOWN STEP\t2026-10-17T03:00:00.0000000Z FAIL  portability-selftest.sh                  1.0s (exit 1)\n' > "$FX/logs/801"
printf '800\tselftests / shard 8\n801\tselftests / shard 1\n' > "$FX/jobs/39020000000"
printf '310227836\t39020000000\tf4276886dddd\tfailure\t2026-10-17T02:00:00Z\tselftests\t30000\tselftests\t.github/workflows/selftests.yml\n310227836\t39010000000\t6666666eeeee\tsuccess\t2026-10-16T02:00:00Z\tselftests\t99000\tselftests\t.github/workflows/selftests.yml\n' > "$FX/runs-4598"
t98='master 红：fleet-bin-inventory 有 9 个 nogh_live_* 未归类'
b98='我是在 #3884 的全量验收 run 39025697982 里看到的：shard 16，`FAIL fleet-bin-inventory-selftest.sh 13.1s`。'
r98=$(env PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" BRK_JOBS_DIR="$FX/jobs" BRK_LOGS_DIR="$FX/logs" BRK_RUNMETA_DIR="$FX/meta" \
        bash -c '. "$1/fleet-lib.sh"; fleet_breakage_run_rows verkyyi/claude-fleet $(fleet_breakage_text_runs "$2")' _ "$WORK/bin" "$t98"$'\n'"$b98")
printf '%s' "$r98" | cut -f3 | grep -qx 'selftests / shard 16' || fail "Z3 the run #4598 names gives its shard 16 row" "[$r98]"
printf '%s' "$r98" | cut -f2 | grep -q '^14bad884'   || fail "Z3 its sha is that run's (14bad884)" "[$r98]"
# shard 1 is not shard 16: a run red on both picks what the text says.
u4=$(up "$FX/runs-4598")
pk=$(printf '%s\n%s\n' "$u4" "$r98" | upick "$t98"$'\n'"$b98")
printf '%s' "$pk" | cut -f3 | grep -qx 'selftests / shard 16' || fail "Z4 「shard 16」 is not 「shard 1」 or shard 8: the text's shard wins" "[$pk]"
pk=$(printf '%s\n' "$u4" | upick 'master 红：selftests / shard 16')
[ -z "$pk" ] || ! printf '%s' "$pk" | cut -f3 | grep -qx 'selftests / shard 1' \
                                                     || fail "Z4 「shard 16」 must not score as 「shard 1」" "[$pk]"
# The filer: --breakage with each real text keys the red it names.
BRK4="$WORK/brk4"; mkdir -p "$BRK4"; rm -rf "$WORK/conf/global/breakage"
run_u() {  # run_u <sfx> <runs file> <args…>
  local sfx="$1" rf="$2"; shift 2
  PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" SPAWN_LOG="$SPAWN_LOG" BIND_LOG="$BIND_LOG" BODY="$WORK/body-$sfx" \
  FLEET_REPO="verkyyi/claude-fleet" FLEET_BASE_BRANCH=master FLEET_CONF_DIR="$WORK/conf" BRK_STORE="$BRK4" \
  BRK_RUNS_FILE="$rf" BRK_JOBS_DIR="$FX/jobs" BRK_LOGS_DIR="$FX/logs" BRK_RUNMETA_DIR="$FX/meta" \
    bash "$WORK/bin/fleet-issue-file.sh" "$@" >"$WORK/out-$sfx" 2>"$WORK/err-$sfx"
  echo $? > "$WORK/rc-$sfx"
}
run_u u5 "$FX/runs-4771" --title "$t71" --body "$b71" --breakage --from w1
grep -q "<!-- fleet:breakage key=${r1%%	*} -->" "$WORK/body-u5" \
                                                     || fail "Z5 #4771 filed with --breakage is keyed Linux / shard 5" "$(cat "$WORK/err-u5" "$WORK/body-u5")"
grep -q '<!-- fleet:fault sha=10bb05b5aaaa -->' "$WORK/body-u5" || fail "Z5 its fault sha is 10bb05b5, not 8937c5a" "$(cat "$WORK/body-u5")"
run_u u6 "$FX/runs-4598" --title "$t98" --body "$b98" --breakage --from w1
grep -q "<!-- fleet:breakage key=${r98%%	*} -->" "$WORK/body-u6" \
                                                     || fail "Z6 #4598 filed with --breakage is keyed by the run it names (shard 16), not master's shard 8" "$(cat "$WORK/err-u6" "$WORK/body-u6")"
grep -q '<!-- fleet:fault sha=14bad884cccc -->' "$WORK/body-u6" || fail "Z6 its fault sha is that run's" "$(cat "$WORK/body-u6")"
ok "Z the red THIS time (#4774): #4771 → Linux / shard 5 @ 10bb05b5 (failfast-cancelled = red, macOS skipped, newest first, no bare duration); #4598 → shard 16 of the run it names"

# ============================ T: no auto road — only a flag makes a breakage ====
# Issue #4271 (replacing #2175's auto road): a red base AND a text naming it is
# still an ordinary issue without --breakage — #4268, a release-gate design
# ticket whose body said 「红」, was taken as macOS / shard 6's breakage and then
# swallowed the next filing as 「同一故障」.
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
nt=$(ls "$BRK2"/issue-* 2>/dev/null | head -1); nt=${nt##*-}
[ "$(cat "$WORK/rc-t1")" = 0 ] && [ -n "$nt" ] && ! grep -q 'fleet:breakage' "$BRK2/issue-$nt" \
                                                     || fail "T1 no flag: a text saying master is red files an ORDINARY issue (#4271)" "$(cat "$WORK/err-t1" "$BRK2/issue-$nt" 2>/dev/null)"
grep -q 'actions/runs' "$GH_LOG"                     && fail "T1 no flag: no probe is run" "$(cat "$GH_LOG")"
run_auto t2 "$FX/runs-2170" --title '发版门槛看复测结果' --body 'cn 这一关认的是旧 stable 上的红判定；master 红的时候也一样' --from orchestrator
[ "$(cat "$WORK/rc-t2")" = 0 ] && ! grep -q 'fleet:breakage' "$WORK/body-t2" \
                                                     || fail "T2 the #4268 shape (a design ticket mentioning 「红」) files plain" "$(cat "$WORK/err-t2")"
run_auto t3 "$FX/runs-2170" --title '另一个普通单，也提到 master 红' --from orchestrator
[ "$(cat "$WORK/rc-t3")" = 0 ] && [ "$(ls "$BRK2"/issue-* | wc -l | tr -d ' ')" = 3 ] \
                                                     || fail "T3 a later ordinary filing is not swallowed as 「同一故障」" "$(cat "$WORK/err-t3")"
rm -rf "$WORK/conf/global/breakage"
run_auto t4 "$FX/runs-2163" --title 'master 红：tokenledger-pg' --breakage --from w4
grep -q "<!-- fleet:breakage key=$k63 -->" "$WORK/body-t4" \
                                                     || fail "T4 explicit --breakage still fingerprints the red base" "$(cat "$WORK/err-t4" "$WORK/body-t4")"
grep -q '<!-- fleet:fault sha=c902bf830000 -->' "$WORK/body-t4" \
                                                     || fail "T4 the probe's streak commit is recorded as the first sighting" "$(cat "$WORK/body-t4")"
run_auto t5 "$FX/runs-2170" --title 'x' --no-breakage
[ "$(cat "$WORK/rc-t5")" = 0 ]                       || fail "T5 --no-breakage still parses" "$(cat "$WORK/err-t5")"
ok "T no auto road: 「master 红」 in an ordinary filing files plain and swallows nothing; only --breakage fingerprints"

# ============================ Y: one issue per fingerprint, across shas (#4271) ===
# Y1 the same fingerprint red on three new shas: ONE issue, three appended
#    comments (each naming its sha + link); the same sha again adds nothing.
# Y2 its fix merged and the issue closed: red again on a sha that CONTAINS the fix
#    ⇒ the old issue is reopened (exit 5), no new one.
# Y3 closed, red on an OLDER sha without the fix (a probe on the old stable) ⇒
#    noted on the closed issue, not reopened, nothing filed.
# Y4 closed by hand (no commit): a sha newer than the close reopens it.
rm -rf "$WORK/conf/global/breakage"; BRK3="$WORK/brk3"; mkdir -p "$BRK3"
run_y() {  # run_y <sfx> <args…>
  local sfx="$1"; shift
  rm -rf "$WORK/conf/global/breakage"
  PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" SPAWN_LOG="$SPAWN_LOG" BIND_LOG="$BIND_LOG" BODY="$WORK/body-$sfx" \
  FLEET_REPO="acme/widgets" FLEET_CONF_DIR="$WORK/conf" BRK_STORE="$BRK3" \
    bash "$WORK/bin/fleet-issue-file.sh" "$@" >"$WORK/out-$sfx" 2>"$WORK/err-$sfx"
  echo $? > "$WORK/rc-$sfx"
}
yk=(--title 'macOS 检查红了：x-selftest' --breakage-key macos-x-selftest --from macos-watch)
run_y y0 "${yk[@]}" --fault-sha 0000000aaaa --fault-link https://github.com/acme/widgets/actions/runs/100
[ "$(cat "$WORK/rc-y0")" = 0 ]                       || fail "Y0 the first sighting files" "$(cat "$WORK/err-y0")"
ny=$(ls "$BRK3"/issue-*); ny=${ny##*-}
for i in 1 2 3; do
  run_y "y$i" "${yk[@]}" --fault-sha "${i}${i}${i}${i}${i}${i}${i}bbbb" --fault-link "https://github.com/acme/widgets/actions/runs/10$i"
  [ "$(cat "$WORK/rc-y$i")" = 5 ] && grep -qx "https://github.com/acme/widgets/issues/$ny" "$WORK/out-y$i" \
                                                     || fail "Y1 sha $i: exit 5 + the first issue's URL" "$(cat "$WORK/err-y$i")"
done
run_y y4 "${yk[@]}" --fault-sha 3333333bbbb --fault-link https://github.com/acme/widgets/actions/runs/103
[ "$(ls "$BRK3"/issue-* | wc -l | tr -d ' ')" = 1 ]  || fail "Y1 three shas red: ONE issue" "$(ls "$BRK3")"
[ "$(grep -c '同一故障' "$BRK3/comments-$ny")" = 3 ] || fail "Y1 three shas red: exactly 3 appended comments (the repeat adds none)" "$(cat "$BRK3/comments-$ny")"
for i in 1 2 3; do
  grep -q "${i}${i}${i}${i}${i}${i}${i}\` 上仍红 — https://github.com/acme/widgets/actions/runs/10$i" "$BRK3/comments-$ny" \
                                                     || fail "Y1 comment $i names its sha and link" "$(cat "$BRK3/comments-$ny")"
done
grep -q 'already on record' "$WORK/err-y4"           || fail "Y1 a sha already on record says so" "$(cat "$WORK/err-y4")"
ok "Y1 one fingerprint red on 3 shas: 1 issue, 3 comments with sha + link; the same sha again adds nothing"

# Y2: fixed by commit fff…, closed; red on 4444444 which contains it ⇒ reopen.
mv "$BRK3/issue-$ny" "$BRK3/closed-$ny"; echo 2026-10-14T01:00:00Z > "$BRK3/closed-$ny.at"
echo fffffff1234 > "$BRK3/fix-$ny"
echo ahead > "$BRK3/compare-4444444cccc"; echo behind > "$BRK3/compare-5555555dddd"
run_y y5 "${yk[@]}" --fault-sha 5555555dddd
[ "$(cat "$WORK/rc-y5")" = 5 ] && [ -f "$BRK3/closed-$ny" ] && [ "$(ls "$BRK3"/issue-* 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
                                                     || fail "Y3 red on an older sha without the fix: not reopened, nothing filed" "$(cat "$WORK/err-y5"; ls "$BRK3")"
grep -q '不含修复 `fffffff`，不重开' "$BRK3/comments-$ny" || fail "Y3 the old-version red is noted on the closed issue" "$(cat "$BRK3/comments-$ny")"
grep -q 'not reopened' "$WORK/err-y5"                || fail "Y3 stderr says not reopened" "$(cat "$WORK/err-y5")"
run_y y6 "${yk[@]}" --fault-sha 4444444cccc --fault-link https://github.com/acme/widgets/actions/runs/104
[ "$(cat "$WORK/rc-y6")" = 5 ] && [ -f "$BRK3/issue-$ny" ] && [ "$(ls "$BRK3"/issue-* | wc -l | tr -d ' ')" = 1 ] \
                                                     || fail "Y2 red on a sha containing the fix: the OLD issue is reopened, no new one" "$(cat "$WORK/err-y6"; ls "$BRK3")"
grep -q "issue reopen $ny" "$GH_LOG"                 || fail "Y2 reopened through gh issue reopen" "$(cat "$GH_LOG")"
grep -q '重开：修复 `fffffff` 之后的版本 `4444444` 复测仍红' "$BRK3/comments-$ny" || fail "Y2 the reopen comment names the fix and the sha" "$(cat "$BRK3/comments-$ny")"
grep -q ': reopened ' "$WORK/err-y6"                 || fail "Y2 stderr says reopened (macos-watch alerts on it)" "$(cat "$WORK/err-y6")"
ok "Y2/Y3 closed: red on a version with the fix reopens the old issue; on an older one it is only noted"

# Y4: closed by hand (no fix commit) — a sha committed after the close reopens it.
mv "$BRK3/issue-$ny" "$BRK3/closed-$ny"; rm -f "$BRK3/fix-$ny"
echo 2026-10-14T02:00:00Z > "$BRK3/date-6666666eeee"
run_y y7 "${yk[@]}" --fault-sha 6666666eeee
[ "$(cat "$WORK/rc-y7")" = 5 ] && [ -f "$BRK3/issue-$ny" ] || fail "Y4 closed by hand, red on a newer sha: reopened" "$(cat "$WORK/err-y7"; ls "$BRK3")"
ok "Y4 closed by hand: a newer red sha reopens it"

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

# --- V. the rule table is gone (issue #4340; #2786 before it) --------------------
# --rule is accepted and ignored for one version: the filing goes through, its body
# carries no 「按规则 N 派发」, no fleet:rule marker, no 「未注明规则」 — from the
# orchestrator's pane or anywhere else; a number no table ever had files the same.
for args in '--rule 1' '--rule 999' ''; do
  # shellcheck disable=SC2086
  FAKE_FLEET_ROLE=orchestrator TMUX_PANE=%9 run_fif --title "形状" --body "要做的事" $args
  [ "$RC" -eq 0 ] || fail "V an orchestrator filing ($args) should file" "$(cat "$WORK/err")"
  grep -q '按规则\|fleet:rule\|未注明规则' "$BODY" && fail "V ($args) still writes a rule line" "$(cat "$BODY")"
done
run_fif --title "别处" --body "y" --rule 2
[ "$RC" -eq 0 ] && ! grep -q '按规则\|fleet:rule\|未注明规则' "$BODY" || fail "V elsewhere: --rule ignored" "$(cat "$BODY" "$WORK/err")"
ok "V rules: --rule accepted and ignored; no rule line from any pane (one version)"

# --- W. any pane spawns, a worker's too (issue #4591 lifted #2960) -----------------
for who in worker 'worker||0' orchestrator steward home '' ; do
  FAKE_FLEET_ROLE="$who" TMUX_PANE=%9 run_fif --title "派" --spawn
  [ "$RC" -eq 0 ] && grep -q 'issue create' "$GH_LOG" && grep -q '^777' "$SPAWN_LOG" || fail "W1 [$who] files and spawns (got $RC)" "$(cat "$WORK/err")"
done
run_fif --title "派" --spawn
[ "$RC" -eq 0 ] && grep -q '^777' "$SPAWN_LOG" || fail "W1 no pane (a daemon, the operator's shell) spawns" "$(cat "$WORK/err")"
FAKE_FLEET_ROLE=worker TMUX_PANE=%9 run_fif --title "旁支活" --parent 5
[ "$RC" -eq 0 ] && grep -q 'issue create' "$GH_LOG" && [ ! -s "$SPAWN_LOG" ] \
  || fail "W2 a worker files without --spawn as before" "$(cat "$WORK/err")"
ok "W1-2 spawn: every pane — a worker's too — files and spawns; without --spawn nothing starts"
# A breakage a worker files without --spawn (issue #4337): filed, the person
# alerted, the parent told — nobody spawned, nothing queued.
ALERT_LOG="$WORK/alerts"; SEND_LOG="$WORK/sends"; export ALERT_LOG SEND_LOG
cat > "$WORK/bin/fleet-alerts.sh" <<'ALERTSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_LOG"
ALERTSTUB
cat > "$WORK/bin/fleet-peer-send.sh" <<'SENDSTUB'
#!/bin/bash
printf '%s <<<%s>\n' "$*" "$(cat | tr '\n' ' ')" >> "$SEND_LOG"
echo "sent → $1"
SENDSTUB
chmod +x "$WORK/bin/fleet-alerts.sh" "$WORK/bin/fleet-peer-send.sh"
PWID=42f8e358-7cc0-5856-a353-8983a4b4c9a1/78b97cf6-7383-4634-b4d7-72915e63fd74
: > "$SPAWN_LOG"; : > "$ALERT_LOG"; : > "$SEND_LOG"
FAKE_FLEET_ROLE=worker FAKE_ORIGIN_WID="$PWID" TMUX_PANE=%9 run_brk w4 --title "master 又红" --breakage-key k-worker
nw=$(cat "$WORK/out-w4"); nw=${nw##*/}
[ "$(cat "$WORK/rc-w4")" = 0 ] && [ -n "$nw" ] && [ "$(grep -c '<!-- fleet:breakage key=k-worker -->' "$BRK"/issue-* | awk -F: '{s+=$2} END {print s}')" = 1 ] \
  && [ ! -s "$SPAWN_LOG" ] && [ ! -e "$WORK/conf/fleets/fifsess/breakage-spawn" ] \
  && [ "$(grep -c . "$ALERT_LOG")" = 1 ] && grep -q "^event breakage fleet: base red — acme/widgets#$nw filed (master 又红)" "$ALERT_LOG" \
  && [ "$(grep -c . "$SEND_LOG")" = 1 ] && grep -q "^wid:$PWID - <<<\[breakage\] the base is red — filed acme/widgets#$nw: master 又红 " "$SEND_LOG" \
  && grep -q "parent told: sent → wid:$PWID" "$WORK/err-w4" \
  || fail "W4 a worker's breakage: one issue + one alert + the parent told, no spawn, no queue" \
       "$(cat "$WORK/err-w4" "$ALERT_LOG" "$SEND_LOG"; ls -R "$WORK/conf/fleets" 2>&1)"
: > "$ALERT_LOG"; : > "$SEND_LOG"
FAKE_FLEET_ROLE=worker TMUX_PANE=%9 run_brk w4b --title "又一处红" --breakage-key k-worker-orphan
[ "$(cat "$WORK/rc-w4b")" = 0 ] && [ "$(grep -c . "$ALERT_LOG")" = 1 ] && [ ! -s "$SEND_LOG" ] && [ ! -s "$SPAWN_LOG" ] \
  && grep -q 'no parent session to tell' "$WORK/err-w4b" \
  || fail "W4b no parent: filed + alerted, said on stderr, nothing sent" "$(cat "$WORK/err-w4b" "$ALERT_LOG" "$SEND_LOG")"
: > "$SPAWN_LOG"
FAKE_FLEET_ROLE='orchestrator|||orchestrator' TMUX_PANE=%9 run_brk w5 --title "另一处红" --breakage-key k-orch --spawn
nw=$(cat "$WORK/out-w5"); nw=${nw##*/}
[ "$(cat "$WORK/rc-w5")" = 0 ] && grep -q "^$nw" "$SPAWN_LOG" && [ ! -f "$WORK/conf/fleets/fifsess/breakage-spawn/acme-widgets-$nw" ] \
  || fail "W5 the orchestrator's breakage spawns its fixer itself, nothing queued" "$(cat "$WORK/err-w5")"
: > "$SPAWN_LOG"; : > "$ALERT_LOG"; : > "$SEND_LOG"
FAKE_FLEET_ROLE=worker TMUX_PANE=%9 run_brk w6 --title "第三处红" --breakage-key k-worker-spawn --spawn
nw=$(cat "$WORK/out-w6"); nw=${nw##*/}
[ "$(cat "$WORK/rc-w6")" = 0 ] && grep -q "^$nw" "$SPAWN_LOG" && [ ! -e "$WORK/conf/fleets/fifsess/breakage-spawn" ] \
  && [ ! -s "$ALERT_LOG" ] && [ ! -s "$SEND_LOG" ] \
  || fail "W6 a worker's breakage with --spawn spawns its fixer itself, no alert, nothing queued" "$(cat "$WORK/err-w6")"
ok "W4-6 breakage: a worker's without --spawn ⇒ one issue + one alert + its parent told, no queue; with --spawn (any pane) it spawns"

# ============================ X: retired labels rejected (issue #4326) =====
for retired in autoland autofill; do
  for requested in "$retired" "enhancement,$retired"; do
    : > "$GH_LOG"
    run_fif --title "Retired automation" --label "$requested" --priority p2
    [ "$RC" -eq 3 ] || fail "X $requested must be rejected (rc 3, got $RC)" "$(cat "$WORK/err")"
    grep -q "off-taxonomy label(s): $retired" "$WORK/err" \
      || fail "X the rejection must name $retired" "$(cat "$WORK/err")"
    grep -q 'issue create' "$GH_LOG" && fail "X rejected labels must not file an issue" "$(cat "$GH_LOG")"
  done
done
ok "X autoland/autofill are rejected before filing, alone or with valid labels"

printf '\nselftest OK: %s assertions passed (channel: validate · provenance · create · milestone · parent · spawn · bind · breakage · worker seat)\n' "$pass"
exit 0
