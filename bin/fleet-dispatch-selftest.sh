#!/bin/bash
# fleet-dispatch-selftest.sh — hermetic smoke test for bin/fleet-dispatch.sh.
#
# Asserts the dispatcher's core contract (issue #70) against a FAKE gh + tmux
# (no network, no tmux server, no real spawns):
#   • PRIORITY ORDER   priority:p0 spawns before p1 before unlabeled.
#   • RATE-LIMIT       at most min(headroom, MAX_PER_TICK) spawns per tick.
#   • PER-FLEET CAP    FLEET_MAX_SESSIONS bounds the fill independent of global.
#   • ELIGIBILITY      assigned / epic / blocked issues are never spawned. (This is
#                      also the cross-machine pre-filter for issue #258: with
#                      FLEET_PRESPAWN_DEDUP the spawn claims AT SPAWN, so a peer's
#                      claim shows as an assignee and #30 below — assigned — is the
#                      "claimed elsewhere is skipped" case.)
#   • ANTI-COLLISION   an issue with a live window is skipped even if it is the
#                      highest-priority pick — matched by @issue binding AND by a
#                      bare "issue-<N>" window name (dash-issue-session's own dedup).
#
# The scenario: one fleet "s1" running two workers — issue-10 (bound via @issue)
# and issue-15 (slug-named window, @issue cleared) — cap 5, 2 spawns/tick.
# Backlog: #10 p0 (live via @issue), #15 p0 (live via slug name), #20 p1,
# #30 p0-assigned, #40 epic, #50 unlabeled. Live count = 2 → slots = min(6,3,2)=2.
# Expected spawns, in order: #20 then #50 (#10/#15 skipped, #30/#40 ineligible).
#
# Needs `jq` (the fake gh applies the dispatcher's real --jq filter through it) —
# SKIPs cleanly if jq is absent, so it never fails a jq-less box.
#
# Exit 0 = pass. Non-zero = fail (prints the captured log + spawn record).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-dispatch.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'selftest: jq not installed — SKIP (the fake gh needs it to apply --jq)\n' >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fd-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf" "$WORK/leases"
SPAWN_LOG="$WORK/spawns"; : > "$SPAWN_LOG"
CANNED="$WORK/issues.json"

# The dispatcher + lib run from $WORK/bin so BIN resolves the fake spawn + gate
# scripts sitting next to them (both are invoked as "$BIN/<name>").
cp "$SRC" "$WORK/bin/fleet-dispatch.sh"
cp "$BIN/fleet-lib.sh" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-dispatch.sh"

# --- fake dash-issue-session.sh: record "<num>" per spawn, never really spawn ---
cat > "$WORK/bin/dash-issue-session.sh" <<FAKE
#!/bin/bash
printf '%s\n' "\$1" >> "$SPAWN_LOG"
exit 0
FAKE
chmod +x "$WORK/bin/dash-issue-session.sh"

# --- fake fleet-diskguard.sh: gate always open ---
cat > "$WORK/bin/fleet-diskguard.sh" <<'FAKE'
#!/bin/bash
[ "${1:-}" = --gate ] && exit 0
exit 0
FAKE
chmod +x "$WORK/bin/fleet-diskguard.sh"

# --- fake gh: only `issue list … --jq <expr>`, applied to $CANNED via real jq ---
cat > "$WORK/fakepath/gh" <<FAKE
#!/bin/bash
expr=''
while [ "\$#" -gt 0 ]; do
  case "\$1" in --jq) shift; expr="\$1" ;; esac
  shift
done
[ -n "\$expr" ] && jq -r "\$expr" "$CANNED"
exit 0
FAKE
chmod +x "$WORK/fakepath/gh"

# --- fake tmux: answers the three list-windows forms the dispatcher/lib use ----
# s1 owns plan/dash/backlog hubs + two worker windows: issue-10 (@issue=10) and
# issue-15 (slug-named, @issue cleared). Check @issue FIRST — the @issue form's
# -F string also contains window_name. A literal tab separates the @issue form.
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
args="$*"
case "$args" in
  *'@issue'*)     printf '%b' "\tplan\n\tdash\n\tbacklog\n10\tissue-10\n\tissue-15\n" ;;  # @issue<tab>name
  *session_name*) printf 's1 plan\ns1 dash\ns1 backlog\ns1 issue-10\ns1 issue-15\n' ;;    # global count
  *window_name*)  printf 'plan\ndash\nbacklog\nissue-10\nissue-15\n' ;;                    # one session
  *)              : ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- per-fleet conf: autofill ON, per-fleet cap 5, 2 spawns/tick ---
cat > "$WORK/conf/s1.conf" <<CONF
FLEET_REPO="fake/repo"
FLEET_AUTOFILL=1
FLEET_MAX_SESSIONS=5
FLEET_GLOBAL_MAX_SESSIONS=8
FLEET_AUTOFILL_MAX_PER_TICK=2
CONF

# --- canned backlog ---
cat > "$CANNED" <<'JSON'
[
  {"number":10,"labels":[{"name":"priority:p0"}],"assignees":[]},
  {"number":15,"labels":[{"name":"priority:p0"}],"assignees":[]},
  {"number":20,"labels":[{"name":"priority:p1"}],"assignees":[]},
  {"number":30,"labels":[{"name":"priority:p0"}],"assignees":[{"login":"someone"}]},
  {"number":40,"labels":[{"name":"epic"},{"name":"priority:p0"}],"assignees":[]},
  {"number":50,"labels":[],"assignees":[]}
]
JSON

# --- run ----------------------------------------------------------------------
LOG="$WORK/log"
PATH="$WORK/fakepath:$PATH" \
FLEET_CONF_DIR="$WORK/conf" \
FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
  bash "$WORK/bin/fleet-dispatch.sh" s1 >"$WORK/stdout" 2>"$LOG" || {
    printf 'selftest: dispatcher exited non-zero\n' >&2; cat "$LOG" >&2; exit 1;
  }

got=$(tr '\n' ' ' < "$SPAWN_LOG" | sed 's/ *$//')
want="20 50"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- log ---\n' >&2; cat "$LOG" >&2
         printf -- '--- spawns: [%s] want [%s] ---\n' "$got" "$want" >&2; exit 1; }

[ "$got" = "$want" ] || fail "spawn set/order wrong"

# defence-in-depth explicit assertions (redundant with the exact match, but they
# pin the WHY if the match ever drifts):
grep -qxF 20 "$SPAWN_LOG" || fail "#20 (p1) should have spawned"
grep -qxF 50 "$SPAWN_LOG" || fail "#50 (unlabeled) should have spawned as the 2nd slot"
grep -qxF 10 "$SPAWN_LOG" && fail "#10 has a live @issue window — must NOT spawn"
grep -qxF 15 "$SPAWN_LOG" && fail "#15 has a live issue-15 window (slug) — must NOT spawn"
grep -qxF 30 "$SPAWN_LOG" && fail "#30 is assigned (== claimed elsewhere, #258) — must NOT spawn"
grep -qxF 40 "$SPAWN_LOG" && fail "#40 is an epic — must NOT spawn"

printf 'selftest PASS: spawned [%s] in priority order under caps + eligibility + anti-collision\n' "$got"
exit 0
