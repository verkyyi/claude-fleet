#!/bin/bash
# fleet-agent-route-selftest.sh — which agent a worker runs (issue #2562).
#
#   A  fleet_labels_agent: agent:codex / agent:claude → codex / claude; neither →
#      nothing; both → rc 2.
#   B  fleet_epic_charter_agent: the member's own row `(codex)` > the charter's
#      `<!-- fleet:epic … agent= -->` > nothing; a member in another repo is
#      matched by (repo, N), never by its bare number.
#   C  fleet_codex_ready: a `valid` LOGIN row → ready; anything else → not.
#   D  the label leg — bin/dash-issue-session.sh (git/gh/tmux faked): an issue
#      labelled agent:codex opens with `--agent codex`; no label → no --agent
#      (FLEET_AGENT's launcher default, byte for byte); an explicit --agent beats
#      the label; both labels are refused; Codex with no valid login is refused
#      and opens nothing — never a quiet Claude.
#   E  bin/fleet-issue-file.sh --spawn --label agent:codex hands the spawn
#      `--agent codex` (no read of the brand-new issue); both labels exit 2 and
#      file nothing.
#
# Exit 0 = pass; non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-route-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# ===== A: labels ============================================================
[ "$(fleet_labels_agent "$(printf 'bug\nagent:codex\n')")" = codex ] || fail "A agent:codex → codex"
[ "$(fleet_labels_agent "$(printf 'agent:claude\npriority:p1\n')")" = claude ] || fail "A agent:claude → claude"
[ -z "$(fleet_labels_agent "$(printf 'bug\nenhancement\n')")" ] || fail "A no agent label → nothing"
fleet_labels_agent "$(printf 'agent:codex\nagent:claude\n')" >/dev/null; [ "$?" = 2 ] || fail "A both labels → rc 2"
fleet_labels_allowed | grep -qx 'agent:codex' && fleet_labels_allowed | grep -qx 'agent:claude' \
  || fail "A both agent labels are in the fixed taxonomy (seeded, accepted by the filer)"
ok "A agent:codex / agent:claude route; both at once is refused; both are canonical labels"

# ===== B: the charter =======================================================
CH=$(cat <<'EOF'
> 设计方案页：x
<!-- fleet:epic repo=o/a short=测试 agent=codex -->
## Core — definition of done
- [ ] **C1** #12 — first (claude)
- [ ] **C2** #13 — second
- [x] **C3** o/b#12 — third in another repo (codex)
- [ ] **C4** o/b#14 — fourth
EOF
)
[ "$(fleet_epic_charter_agent o/a "$CH" o/a 12)" = claude ] || fail "B the member row's (claude) beats the charter's agent=codex"
[ "$(fleet_epic_charter_agent o/a "$CH" o/a 13)" = codex ]  || fail "B no row tail → the charter's agent="
[ "$(fleet_epic_charter_agent o/a "$CH" o/b 12)" = codex ]  || fail "B o/b#12 matched by (repo, N), its own (codex)"
[ "$(fleet_epic_charter_agent o/a "$CH" o/b 14)" = codex ]  || fail "B another repo's member with no tail → the charter's"
NOAG=$(printf '<!-- fleet:epic repo=o/a short=测试 -->\n- [ ] **C1** #12 — first\n- [ ] **C2** #13 — x (codex)\n')
[ -z "$(fleet_epic_charter_agent o/a "$NOAG" o/a 12)" ] || fail "B no agent= and no tail → nothing (the fleet default)"
[ "$(fleet_epic_charter_agent o/a "$NOAG" o/a 13)" = codex ] || fail "B a row tail with no charter agent="
ok "B member row > charter agent= > nothing; members matched by (repo, N)"

# ===== C: Codex readiness ===================================================
FLEET_CODEX_READY_CMD="printf 'PROFILE DEFAULT EMAIL PLAN LOGIN DIRECTORY\npersonal * u@e pro valid /h\n'" fleet_codex_ready \
  || fail "C a valid LOGIN row is ready"
FLEET_CODEX_READY_CMD="printf 'PROFILE DEFAULT EMAIL PLAN LOGIN DIRECTORY\ndefault * - - no_credentials /h\n'" fleet_codex_ready \
  && fail "C no_credentials is not ready"
FLEET_CODEX_READY_CMD="false" fleet_codex_ready && fail "C a failed read is not ready"
ok "C fleet_codex_ready reads the LOGIN column"

# ===== D: the spawn routes by label =========================================
mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/dash"
cat > "$WORK/fakebin/git" <<'GITFAKE'
#!/bin/bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
case "${1:-}" in
  rev-parse) case "$*" in *--abbrev-ref*) echo issue-77 ;; *--show-toplevel*) pwd -P ;; *) echo deadbeef ;; esac ;;
esac
exit 0
GITFAKE
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$*" in
  *"issue view"*"--json labels"*) printf '{"labels":%s}\n' "${GH_LABELS:-[]}" ;;
  "issue view"*) echo 'Some Issue' ;;
  "issue create"*) echo 'https://github.com/acme/widgets/issues/77' ;;
esac
exit 0
GHFAKE
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
case "${1:-}" in
  display-message) case "$*" in *-p*) case "$*" in *window_id*) echo @9 ;; *session_name*) echo testsess ;; *) echo '' ;; esac ;; esac ;;
  show-options) echo '' ;;
  new-window) printf '%s\n' "$*" >> "$NEWWIN_LOG"; echo @9 ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

READY="printf 'H\nx * e p valid d\n'"
NOLOGIN="printf 'H\nx * e p no_credentials d\n'"
run_spawn() { # GH_LABELS / CODEX_CMD from env; $@ = spawn args
  rm -rf "$WORK/dash/.claude-dash/fleets"; : > "$WORK/newwin"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
  FLEET_PRESPAWN_DEDUP=0 NEWWIN_LOG="$WORK/newwin" FLEET_CODEX_READY_CMD="${CODEX_CMD:-$READY}" \
    "$SPAWN" 77 --origin hub "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
}

GH_LABELS='[{"name":"bug"},{"name":"agent:codex"}]' run_spawn; rc=$?
[ "$rc" = 0 ] || fail "D the agent:codex spawn exited $rc" "$(cat "$WORK/spawn.err")"
grep -qF -- "fleet-session-wrap.sh' --agent codex" "$WORK/newwin" \
  || fail "D agent:codex must open a Codex session" "$(cat "$WORK/newwin")"

GH_LABELS='[{"name":"bug"}]' run_spawn
[ -s "$WORK/newwin" ] || fail "D the unlabelled spawn opened nothing" "$(cat "$WORK/spawn.err")"
grep -q -- '--agent' "$WORK/newwin" && fail "D no agent label ⇒ no --agent (FLEET_AGENT decides)" "$(cat "$WORK/newwin")"

GH_LABELS='[{"name":"agent:codex"}]' run_spawn --agent claude
grep -qF -- "fleet-session-wrap.sh' --agent claude" "$WORK/newwin" \
  || fail "D an explicit --agent beats the label" "$(cat "$WORK/newwin")"

GH_LABELS='[{"name":"agent:codex"},{"name":"agent:claude"}]' run_spawn; rc=$?
[ "$rc" = 1 ] && [ ! -s "$WORK/newwin" ] || fail "D both labels must be refused, nothing opened (rc=$rc)" "$(cat "$WORK/newwin")"
grep -q 'agent:codex and agent:claude' "$WORK/spawn.err" || fail "D the refusal names both labels" "$(cat "$WORK/spawn.err")"

GH_LABELS='[{"name":"agent:codex"}]' CODEX_CMD="$NOLOGIN" run_spawn; rc=$?
[ "$rc" = 1 ] && [ ! -s "$WORK/newwin" ] || fail "D Codex with no login must be refused, nothing opened (rc=$rc)" "$(cat "$WORK/newwin")"
grep -q 'ccquota codex login' "$WORK/spawn.err" || fail "D the refusal says ccquota codex login" "$(cat "$WORK/spawn.err")"

GH_LABELS='[]' CODEX_CMD="$NOLOGIN" run_spawn
grep -q -- '--agent' "$WORK/newwin" && fail "D a Claude spawn never asks for Codex" "$(cat "$WORK/newwin")"
[ -s "$WORK/newwin" ] || fail "D a Claude spawn opens without a Codex login" "$(cat "$WORK/spawn.err")"
# --title promised no round-trip (#216): the label comes off the collector's copy.
run_title() {
  rm -rf "$WORK/dash/.claude-dash/fleets"; : > "$WORK/newwin"; : > "$WORK/gh.log"
  mkdir -p "$WORK/dash/.claude-dash/fleets/$(fleet_slug acme/widgets)"
  printf '77\tbug,agent:codex\n' > "$WORK/dash/.claude-dash/fleets/$(fleet_slug acme/widgets)/labels"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" GH_LOG="$WORK/gh.log" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
  FLEET_PRESPAWN_DEDUP=0 NEWWIN_LOG="$WORK/newwin" FLEET_CODEX_READY_CMD="$READY" \
    "$SPAWN" 77 --origin hub --title 'Known Title' >"$WORK/spawn.out" 2>"$WORK/spawn.err"
}
run_title
grep -qF -- "fleet-session-wrap.sh' --agent codex" "$WORK/newwin" \
  || fail "D --title: the cached agent:codex label routes to Codex" "$(cat "$WORK/newwin") $(cat "$WORK/spawn.err")"
grep -q 'issue view' "$WORK/gh.log" && fail "D --title must make no gh issue view (#216)" "$(cat "$WORK/gh.log")"
ok "D agent:codex opens Codex; no label = fleet default; --agent wins; both / no login refused; --title reads the cache only"

# ===== E: the filer hands the label to the spawn =============================
SB="$WORK/sb"; mkdir -p "$SB"
cp "$BIN/fleet-issue-file.sh" "$BIN/fleet-lib.sh" "$SB/"
for f in "$BIN"/*.sh "$BIN"/*.py; do [ -e "$SB/$(basename "$f")" ] || ln -s "$f" "$SB/$(basename "$f")"; done
rm -f "$SB/dash-issue-session.sh"
cat > "$SB/dash-issue-session.sh" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" > "$WORK/spawn-args"
FAKE
chmod +x "$SB/dash-issue-session.sh"
file_it() {
  : > "$WORK/spawn-args"; : > "$WORK/gh.log"
  PATH="$WORK/fakebin:$PATH" GH_LOG="$WORK/gh.log" FLEET_CONF_DIR="$WORK/conf" TMUX='' TMUX_PANE='' \
  FLEET_REPO="acme/widgets" FLEET_MILESTONE=none \
    bash "$SB/fleet-issue-file.sh" --title 'mechanical rename' --repo acme/widgets --no-breakage "$@" \
    >"$WORK/file.out" 2>"$WORK/file.err"
}
file_it --label agent:codex --spawn; rc=$?
[ "$rc" = 0 ] || fail "E the filing exited $rc" "$(cat "$WORK/file.err")"
grep -q -- '--agent codex' "$WORK/spawn-args" || fail "E --label agent:codex --spawn must hand the spawn --agent codex" "$(cat "$WORK/spawn-args")"
file_it --spawn
grep -q -- '--agent' "$WORK/spawn-args" && fail "E no agent label ⇒ the spawn gets no --agent" "$(cat "$WORK/spawn-args")"
file_it --label agent:codex,agent:claude --spawn; rc=$?
[ "$rc" = 2 ] || fail "E both agent labels must exit 2 (got $rc)" "$(cat "$WORK/file.err")"
grep -q 'issue create' "$WORK/gh.log" && fail "E both agent labels must file nothing" "$(cat "$WORK/gh.log")"
ok "E the filer passes agent:codex to its spawn as --agent; both labels file nothing"

printf 'fleet-agent-route-selftest: %d passed\n' "$pass"
