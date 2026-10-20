#!/bin/bash
# fleet-agent-route-selftest.sh — which agent a worker runs (issue #2562).
#
#   A  fleet_labels_agent: agent:codex / agent:claude → codex / claude; neither →
#      nothing; both → rc 2.
#   B  fleet_epic_charter_agent: the member's own row `(codex)` > the charter's
#      `<!-- fleet:epic … agent= -->` > nothing; a member in another repo is
#      matched by (repo, N), never by its bare number.
#   C  fleet_codex_ready: a `valid` LOGIN row → ready; anything else → not; a
#      SEPARATED login (credsep.json, issue #3097) is ready whatever ccquota says —
#      its Codex credential is the store's, reached through the proxy.
#   D  the label leg — bin/dash-issue-session.sh (git/gh/tmux faked): an issue
#      labelled agent:codex opens with `--agent codex`; no label → no --agent
#      (FLEET_AGENT's launcher default, byte for byte); an explicit --agent beats
#      the label; both labels are refused; Codex with no valid login is refused
#      and opens nothing — never a quiet Claude. Issue #3097 (⌘T in a 看台): from
#      a run-shell's context ($TMUX set, no $TMUX_PANE) on a separated login with
#      no_credentials, a Codex spawn opens Codex and a Claude spawn opens Claude.
#   E  a new task (fleet-control-read.sh start … new codex, its record T<n>) opens
#      through dash-raw-session.sh with `--agent codex --task T<n>` on a
#      central-only credential login, and refuses (4) with no endpoint before
#      opening anything; nothing is filed on GitHub (issue #4898).
#
# Exit 0 = pass; non-zero = fail.
set -uo pipefail
export FLEET_SKIP_GLOBAL_CONF=1 FLEET_CODEX_READY_CHECK=1

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
SPAWN="$BIN/dash-issue-session.sh"
st_sandbox "${TMPDIR:-/tmp}/agent-route-selftest.XXXXXX"

pass=0

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# ===== A: labels ============================================================
[ "$(fleet_labels_agent "$(printf 'bug\nagent:codex\n')")" = codex ] || st_fail "A agent:codex → codex"
[ "$(fleet_labels_agent "$(printf 'agent:claude\npriority:p1\n')")" = claude ] || st_fail "A agent:claude → claude"
[ -z "$(fleet_labels_agent "$(printf 'bug\nenhancement\n')")" ] || st_fail "A no agent label → nothing"
fleet_labels_agent "$(printf 'agent:codex\nagent:claude\n')" >/dev/null; [ "$?" = 2 ] || st_fail "A both labels → rc 2"
st_pass "A agent:codex / agent:claude route; both at once is refused"

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
[ "$(fleet_epic_charter_agent o/a "$CH" o/a 12)" = claude ] || st_fail "B the member row's (claude) beats the charter's agent=codex"
[ "$(fleet_epic_charter_agent o/a "$CH" o/a 13)" = codex ]  || st_fail "B no row tail → the charter's agent="
[ "$(fleet_epic_charter_agent o/a "$CH" o/b 12)" = codex ]  || st_fail "B o/b#12 matched by (repo, N), its own (codex)"
[ "$(fleet_epic_charter_agent o/a "$CH" o/b 14)" = codex ]  || st_fail "B another repo's member with no tail → the charter's"
NOAG=$(printf '<!-- fleet:epic repo=o/a short=测试 -->\n- [ ] **C1** #12 — first\n- [ ] **C2** #13 — x (codex)\n')
[ -z "$(fleet_epic_charter_agent o/a "$NOAG" o/a 12)" ] || st_fail "B no agent= and no tail → nothing (the fleet default)"
[ "$(fleet_epic_charter_agent o/a "$NOAG" o/a 13)" = codex ] || st_fail "B a row tail with no charter agent="
st_pass "B member row > charter agent= > nothing; members matched by (repo, N)"

# ===== C: Codex readiness ===================================================
mkdir -p "$WORK/c-conf"; export FLEET_CONF_DIR="$WORK/c-conf"   # never this login's own credsep.json
FLEET_CODEX_READY_CMD="printf 'PROFILE DEFAULT EMAIL PLAN LOGIN DIRECTORY\npersonal * u@e pro valid /h\n'" fleet_codex_ready \
  || st_fail "C a valid LOGIN row is ready"
FLEET_CODEX_READY_CMD="printf 'PROFILE DEFAULT EMAIL PLAN LOGIN DIRECTORY\ndefault * - - no_credentials /h\n'" fleet_codex_ready \
  && st_fail "C no_credentials is not ready"
FLEET_CODEX_READY_CMD="false" fleet_codex_ready && st_fail "C a failed read is not ready"
mkdir -p "$WORK/sep" "$WORK/notsep"
printf '{\n "separated": true,\n "root": "/var/db/fleet-cred/x"\n}\n' > "$WORK/sep/credsep.json"
printf '{\n "separated": false\n}\n' > "$WORK/notsep/credsep.json"
FLEET_CONF_DIR="$WORK/sep" FLEET_CODEX_READY_CMD="printf 'H\ndefault * - - no_credentials /h\n'" fleet_codex_ready \
  || st_fail "C a separated login is ready though ccquota says no_credentials (issue #3097)"
FLEET_CONF_DIR="$WORK/notsep" FLEET_CODEX_READY_CMD="printf 'H\ndefault * - - no_credentials /h\n'" fleet_codex_ready \
  && st_fail "C a credsep.json that says separated: false changes nothing"
st_pass "C fleet_codex_ready reads the LOGIN column; a separated login is ready"

mkdir -p "$WORK/central"
printf 'CCQUOTA_FLEET_CREDS=0\n' > "$WORK/central/node.env"
FLEET_CONF_DIR="$WORK/central" FLEET_CRED_PROXY=1 FLEET_CRED_CENTRAL_URL=https://proxy.example \
  FLEET_CODEX_READY_CMD=false fleet_codex_ready || st_fail "C a central-only login needs no local Codex credential"
FLEET_CONF_DIR="$WORK/central" FLEET_CRED_PROXY=0 FLEET_CRED_CENTRAL_URL=https://proxy.example \
  FLEET_CODEX_READY_CMD=false fleet_codex_ready && st_fail "C a disabled proxy cannot supply central credentials"
FLEET_CONF_DIR="$WORK/central" FLEET_CRED_PROXY=1 FLEET_CRED_CENTRAL_URL='' \
  FLEET_CODEX_READY_CMD=false fleet_codex_ready && st_fail "C central credentials need a configured endpoint"
printf 'CCQUOTA_FLEET_CREDS=1\n' > "$WORK/central/node.env"
FLEET_CONF_DIR="$WORK/central" FLEET_CRED_PROXY=1 FLEET_CRED_CENTRAL_URL=https://proxy.example \
  FLEET_CODEX_READY_CMD=false fleet_codex_ready && st_fail "C a locally leased login still needs its local credential"
rm "$WORK/central/node.env"
FLEET_CONF_DIR="$WORK/central" FLEET_CRED_PROXY=1 FLEET_CRED_CENTRAL_URL=https://proxy.example \
  FLEET_CODEX_READY_CMD=false fleet_codex_ready && st_fail "C no node configuration is not central-only"
st_pass "C central-only readiness keeps the local credential checks on other logins"

# ===== D: the spawn routes by label =========================================
mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/dash"
. "$BIN/selftest-repo-fixture.sh"
fx_repo "$WORK/conf" testsess acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master
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
  run-shell)
    if [ "${RUNSHELL_RUN:-0}" = 1 ]; then
      FLEET_AGENT=claude bash -c "${@: -1}"
    fi ;;
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
  NEWWIN_LOG="$WORK/newwin" FLEET_CODEX_READY_CMD="${CODEX_CMD:-$READY}" \
    "$SPAWN" 77 --origin hub "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
}
# ⌘T in a 看台 (issue #3097): the popup runs under `tmux run-shell` — $TMUX set,
# no $TMUX_PANE — on a credential-separated login whose ccquota sees no Codex login
run_shell_spawn() {
  rm -rf "$WORK/dash/.claude-dash/fleets"; : > "$WORK/newwin"
  mkdir -p "$WORK/sepconf"; printf '{\n "separated": true\n}\n' > "$WORK/sepconf/credsep.json"
  fx_repo "$WORK/sepconf" testsess acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master
  ( unset TMUX_PANE
    PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/sepconf" TMUX="$WORK/tt-sock,1,0" \
    FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
    NEWWIN_LOG="$WORK/newwin" FLEET_CODEX_READY_CMD="$NOLOGIN" GH_LABELS='[]' \
      "$SPAWN" 77 --origin hub --print "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err" )
}

GH_LABELS='[{"name":"bug"},{"name":"agent:codex"}]' run_spawn; rc=$?
[ "$rc" = 0 ] || st_fail "D the agent:codex spawn exited $rc" "$(cat "$WORK/spawn.err")"
grep -qF -- "fleet-session-wrap.sh' --agent codex" "$WORK/newwin" \
  || st_fail "D agent:codex must open a Codex session" "$(cat "$WORK/newwin")"

GH_LABELS='[{"name":"bug"}]' run_spawn
[ -s "$WORK/newwin" ] || st_fail "D the unlabelled spawn opened nothing" "$(cat "$WORK/spawn.err")"
grep -q -- '--agent claude' "$WORK/newwin" || st_fail "D no agent label freezes default" "$(cat "$WORK/newwin")"

GH_LABELS='[{"name":"agent:codex"}]' run_spawn --agent claude
grep -qF -- "fleet-session-wrap.sh' --agent claude" "$WORK/newwin" \
  || st_fail "D an explicit --agent beats the label" "$(cat "$WORK/newwin")"

GH_LABELS='[{"name":"agent:codex"},{"name":"agent:claude"}]' run_spawn; rc=$?
[ "$rc" = 1 ] && [ ! -s "$WORK/newwin" ] || st_fail "D both labels must be refused, nothing opened (rc=$rc)" "$(cat "$WORK/newwin")"
grep -q 'agent:codex and agent:claude' "$WORK/spawn.err" || st_fail "D the refusal names both labels" "$(cat "$WORK/spawn.err")"

GH_LABELS='[{"name":"agent:codex"}]' CODEX_CMD="$NOLOGIN" run_spawn; rc=$?
[ "$rc" = 1 ] && [ ! -s "$WORK/newwin" ] || st_fail "D Codex with no login must be refused, nothing opened (rc=$rc)" "$(cat "$WORK/newwin")"
grep -q 'ccquota codex login' "$WORK/spawn.err" || st_fail "D the refusal says ccquota codex login" "$(cat "$WORK/spawn.err")"

GH_LABELS='[]' CODEX_CMD="$NOLOGIN" run_spawn
grep -q -- '--agent codex' "$WORK/newwin" && st_fail "D a Claude spawn never asks for Codex" "$(cat "$WORK/newwin")"
[ -s "$WORK/newwin" ] || st_fail "D a Claude spawn opens without a Codex login" "$(cat "$WORK/spawn.err")"
# --title promised no round-trip (#216): the label comes off the collector's copy.
run_title() {
  rm -rf "$WORK/dash/.claude-dash/fleets"; : > "$WORK/newwin"; : > "$WORK/gh.log"
  mkdir -p "$WORK/dash/.claude-dash/fleets/$(fleet_slug acme/widgets)"
  printf '77\tbug,agent:%s\n' "${CACHED_AGENT:-codex}" > "$WORK/dash/.claude-dash/fleets/$(fleet_slug acme/widgets)/labels"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" GH_LOG="$WORK/gh.log" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
  NEWWIN_LOG="$WORK/newwin" FLEET_CODEX_READY_CMD="$READY" \
    "$SPAWN" 77 --origin hub --title 'Known Title' "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
}
run_title
grep -qF -- "fleet-session-wrap.sh' --agent codex" "$WORK/newwin" \
  || st_fail "D --title: the cached agent:codex label routes to Codex" "$(cat "$WORK/newwin") $(cat "$WORK/spawn.err")"
grep -q 'issue view' "$WORK/gh.log" && st_fail "D --title must make no gh issue view (#216)" "$(cat "$WORK/gh.log")"
# Controlled stale cache: no explicit provider follows the old hint; an explicit
# provider wins in both the title fast path and detached re-entry (#4392).
CACHED_AGENT=claude run_title --agent codex
 grep -qF -- "fleet-session-wrap.sh' --agent codex" "$WORK/newwin" || st_fail "D stale Claude label overrides explicit Codex"
CACHED_AGENT=claude RUNSHELL_RUN=1 run_title --agent codex --async
 grep -qF -- "fleet-session-wrap.sh' --agent codex" "$WORK/newwin" || st_fail "D async lost explicit Codex" "$(cat "$WORK/spawn.err")"
run_spawn --agent codex --agent claude; rc=$?
[ "$rc" = 2 ] && [ ! -s "$WORK/newwin" ] || st_fail "D conflicting explicit providers opened work"
run_spawn --agent unknown; rc=$?
[ "$rc" = 2 ] && [ ! -s "$WORK/newwin" ] || st_fail "D unknown provider opened work"
printf 'fixture: stale Claude cache + explicit Codex: title/async Codex; invalid/conflict: no launch\n'
run_shell_spawn --agent codex; rc=$?
[ "$rc" = 0 ] || st_fail "D #3097: a Codex spawn from run-shell on a separated login exited $rc" "$(cat "$WORK/spawn.err")"
grep -qF -- "fleet-session-wrap.sh' --agent codex" "$WORK/newwin" \
  || st_fail "D #3097: …it must open Codex" "$(cat "$WORK/newwin") $(cat "$WORK/spawn.err")"
run_shell_spawn --agent claude; rc=$?
[ "$rc" = 0 ] || st_fail "D #3097: a Claude spawn from run-shell exited $rc" "$(cat "$WORK/spawn.err")"
grep -qF -- "fleet-session-wrap.sh' --agent claude" "$WORK/newwin" \
  || st_fail "D #3097: …it must open Claude" "$(cat "$WORK/newwin") $(cat "$WORK/spawn.err")"
st_pass "D agent:codex opens Codex; no label = fleet default; --agent wins; both / no login refused; --title reads the cache only; run-shell + separated opens both agents"

# ===== E: a new task opens on its record =====================================
SB="$WORK/sb"; mkdir -p "$SB"
cp "$BIN/fleet-lib.sh" "$BIN/fleet-client-core.sh" "$SB/"
for f in "$BIN"/*.sh "$BIN"/*.py; do [ -e "$SB/$(basename "$f")" ] || ln -s "$f" "$SB/$(basename "$f")"; done
rm -f "$SB/dash-raw-session.sh"
cat > "$SB/dash-raw-session.sh" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" > "$WORK/spawn-args"
FAKE
chmod +x "$SB/dash-raw-session.sh"
rm "$SB/fleet-diskguard.sh"
printf '#!/bin/bash\nexit 0\n' > "$SB/fleet-diskguard.sh"
printf 'CCQUOTA_FLEET_CREDS=0\n' > "$WORK/central/node.env"
run_new() {
  mkdir -p "$WORK/central/fleets/testsess"
  : > "$WORK/central/fleets/testsess/conf"
  fx_repo "$WORK/central" "testsess" acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master"
  : > "$WORK/spawn-args"; : > "$WORK/gh.log"
  PATH="$WORK/fakebin:$PATH" GH_LOG="$WORK/gh.log" FLEET_CONF_DIR="$WORK/central" TMUX='' TMUX_PANE='' \
  FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master \
  FLEET_CRED_PROXY=1 FLEET_CRED_CENTRAL_URL="$1" FLEET_CODEX_READY_CMD=false FLEET_CONTROL_TASK=T9 \
    bash "$SB/fleet-control-read.sh" start testsess new codex acme/widgets '' '' 'Central Codex task' \
    <<< 'Reply OK' > "$WORK/new.out" 2> "$WORK/new.err"
}
run_new https://proxy.example; rc=$?
[ "$rc" = 0 ] && grep -q -- '--agent codex' "$WORK/spawn-args" && grep -q -- '--task T9' "$WORK/spawn-args" \
  || st_fail "E central-only new task reaches the Codex spawner on its record" "$(cat "$WORK/new.err" "$WORK/spawn-args")"
grep -q 'issue create' "$WORK/gh.log" && st_fail "E a new task files no issue" "$(cat "$WORK/gh.log")"
run_new ''; rc=$?
[ "$rc" = 4 ] && [ ! -s "$WORK/spawn-args" ] && [ ! -s "$WORK/gh.log" ] \
  || st_fail "E missing central endpoint refuses before opening anything" "$(cat "$WORK/new.err")"
st_pass "E a new task opens Codex on its record with central-only credentials; no endpoint refuses before opening"

printf 'fleet-agent-route-selftest: %d passed\n' "$pass"
