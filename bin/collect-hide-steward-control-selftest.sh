#!/bin/bash
# collect-hide-steward-control-selftest.sh — the "backlog never carries the
# steward-control relay endpoint" rail (issue #174).
#
# The collector (bin/tmux-dash-collect.sh) builds the issues cache the backlog
# reads. A `steward-control`-labeled issue (e.g. the issue-bridge steward hub,
# #169) is a relay endpoint, not a pickable task, so it must be dropped at the
# collector's `gh issue list` — matching the spawn-eligibility exclusion of the
# same label. This drives the REAL collect script against a FAKE gh + tmux
# (no network, no tmux server) so it exercises the actual `--jq` row producer:
#   • EXCLUDES    a steward-control issue (#169) never reaches the issues cache.
#   • KEEPS       normal issues (assigned or not) still land in the cache.
#   • SINGLE CALL the collector makes exactly ONE `gh issue list` (no per-issue
#                 fetch) — the fake gh counts its issue-list invocations.
#
# Needs `jq` (the fake gh applies the collector's real --jq through it) — SKIPs
# cleanly if jq is absent, so it never fails a jq-less box.
#
# Exit 0 = pass. Non-zero = fail (prints the captured cache + gh call count).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/tmux-dash-collect.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$SRC" ] || { printf 'selftest: %s not found\n' "$SRC" >&2; exit 2; }
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

if ! command -v jq >/dev/null 2>&1; then
  printf 'selftest: jq not installed — SKIP (the fake gh needs it to apply --jq)\n' >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chsc-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/emptyconf"
CANNED="$WORK/issues.json"
GH_CALLS="$WORK/gh-issue-list-calls"; : > "$GH_CALLS"

# Run the collector from $WORK/bin so BIN resolves fleet-lib.sh there and there is
# no ../fleet.conf to source (keeps the run hermetic).
cp "$SRC" "$WORK/bin/tmux-dash-collect.sh"
cp "$LIB" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/tmux-dash-collect.sh"

# --- fake gh: only `issue list … --jq <expr>`, applied to $CANNED via real jq.
# Each issue-list call appends a line to $GH_CALLS so we can assert exactly one.
cat > "$WORK/fakepath/gh" <<FAKE
#!/bin/bash
if [ "\$1" = issue ] && [ "\$2" = list ]; then echo call >> "$GH_CALLS"; fi
expr=''
while [ "\$#" -gt 0 ]; do
  case "\$1" in --jq) shift; expr="\$1" ;; esac
  shift
done
[ -n "\$expr" ] && jq -r "\$expr" "$CANNED"
exit 0
FAKE
chmod +x "$WORK/fakepath/gh"

# --- fake tmux: info succeeds (so the collector proceeds); every list/capture is
# empty (no live sessions/windows/clients ⇒ the git/ctx/usage/notify sections are
# all no-ops). The configured FLEET_REPO is still queued + fetched regardless, and
# its slug'd `issues_<slug>` cache is written — that's what the backlog reads via
# fleet_cache (issue #180 dropped the flat `issues` mirror; no fleet is primary).
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
case "$1" in
  info) exit 0 ;;
  *)    exit 0 ;;   # list-sessions/list-windows/list-clients/capture-pane → empty
esac
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- canned backlog: a normal unassigned issue, the steward-control hub (#169),
# and a normal assigned issue. Only #169 must be dropped.
cat > "$CANNED" <<'JSON'
[
  {"number":40,"title":"alpha task","milestone":{"title":"Week 1"},"assignees":[],"labels":[{"name":"priority:p1"}]},
  {"number":169,"title":"steward hub","milestone":null,"assignees":[],"labels":[{"name":"steward-control"}]},
  {"number":50,"title":"bravo task","milestone":null,"assignees":[{"login":"someone"}],"labels":[]}
]
JSON

# --- run the real collector against the fakes ---------------------------------
C="$WORK/.claude-dash"
ISSUES="$C/fleets/fake-repo/issues"   # per-fleet cache (fleet_slug fake/repo → fake-repo, issue #181)
LOG="$WORK/log"
PATH="$WORK/fakepath:$PATH" \
TMPDIR="$WORK" \
GH_TTL=0 \
FLEET_REPO="fake/repo" \
FLEET_REPOS="" \
FLEET_NOTIFY_CMD="" \
FLEET_CONF_DIR="$WORK/emptyconf" \
  bash "$WORK/bin/tmux-dash-collect.sh" >"$WORK/stdout" 2>"$LOG" || {
    printf 'selftest: collector exited non-zero\n' >&2; cat "$LOG" >&2; exit 1;
  }

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- issues cache ---\n' >&2; cat "$ISSUES" 2>/dev/null >&2
         printf -- '--- gh issue-list calls: %s ---\n' "$(wc -l < "$GH_CALLS" | tr -d ' ')" >&2
         printf -- '--- log ---\n' >&2; cat "$LOG" >&2; exit 1; }

[ -s "$ISSUES" ] || fail "slug'd issues cache should have been written"
cache="$(cat "$ISSUES")"

# EXCLUDES: the steward-control issue is gone.
printf '%s\n' "$cache" | grep -qF '#169'       && fail "steward-control issue #169 must be EXCLUDED from the cache"
printf '%s\n' "$cache" | grep -qF 'steward hub' && fail "steward-control row must be EXCLUDED from the cache"

# KEEPS: normal issues survive (assigned and unassigned).
printf '%s\n' "$cache" | grep -qF 'alpha task' || fail "normal unassigned issue #40 should be in the cache"
printf '%s\n' "$cache" | grep -qF 'bravo task' || fail "normal assigned issue #50 should be in the cache"
printf '%s\n' "$cache" | grep -qF '#40'         || fail "issue number column should still render (#40)"

# SINGLE CALL: exactly one `gh issue list` (no per-issue fetch).
n=$(wc -l < "$GH_CALLS" | tr -d ' ')
[ "$n" = 1 ] || fail "collector must make exactly ONE gh issue-list call (made $n)"

printf 'selftest PASS: collector drops steward-control from the issues cache, keeps normal issues, single gh call\n'
exit 0
