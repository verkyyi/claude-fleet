#!/bin/bash
# fleet-launch-lib-selftest.sh — opening a session is ONE road for every agent
# (T620, EPIC T580 C4).
#
# bin/fleet-claude.sh (the one door) and bin/fleet-codex.sh share their launch
# steps through bin/fleet-launch-lib.sh, and what really differs per agent is the
# adapter table bin/fleet_agent_adapter.py (+ its generated shell copy
# bin/fleet-agent-adapter.sh). Pinned:
#
#   A  the table: the shell copy is exactly `--emit-sh`; every column of every agent
#      reads the same from Python and from shell; an unknown agent / column / a name
#      with a space is refused; the seed column (claude: as typed; codex: a prose
#      seed and an unknown `/name` as typed, the latter said on stderr)
#   B  the readers ask the table: no agent-name branch left in the door, the library,
#      the wrapper or the two spawners
#   C  the SAME window marks after a fresh launch, once per agent — @cc_agent, the
#      table's model setting → its model flag + @cc_model, @agent_cfg (+ _src), the
#      fleet tool service mounted, and only that agent's binary ran
#   D  BREAK-IT ⑥⑦⑧ both ways: ⑥ the door opens the agent asked for, never the other
#      (`--agent codex` is Codex even resume-shaped; a plain start is Claude); ⑦ a
#      fresh session has full access from the fleet's defaults, and on a login whose
#      own config already gives it a Codex start carries no CLI override (its in-TUI
#      /resume works); ⑧ starting one agent never runs the other's CLI (a Codex start
#      as an agent file runs no `claude` at all — no `claude plugin list`)
#   E  the resume spelling is the table's (claude --resume <id>, codex resume <id>),
#      and the agent's pending-id option names the thread a resume was opened for
#   F  the credential proxy refuses alike: 404 ⇒ @launch_refused cred_unknown, any
#      other failure ⇒ cred — exit 1, the agent never runs
#   G  the mint starts early (T683, a cold start ≤ 5 s): it runs beside the composed
#      configuration (it sees the composer's manifest appear while it is still
#      minting), its credential reaches the agent, its --wrap is the launcher (the
#      pid the agent runs as / under), fd 7 is not left to the agent — and
#      FLEET_LAUNCH_EARLY=0 mints in place with the same result; both agents
#   H  the agent yields to the 看台 (T691): fleet_launch_yield is `taskpolicy -c
#      utility|background` on a Mac, `nice -n 5|15` elsewhere, nothing for 0/off;
#      on Linux the agent itself runs at nice 5 and with FLEET_AGENT_YIELD=0 at its
#      parent's nice — both agents, the argv the agent sees unchanged; Claude's
#      commands and hooks go through bin/fleet-tool-yield.sh (CLAUDE_CODE_SHELL_PREFIX,
#      FLEET_TOOL_YIELD), never over a prefix of the person's own
#
# Hermetic: a temp install root (every bin/ file a symlink, the real conf/ hooks/
# commands/ mod/), a temp HOME and FLEET_CONF_DIR, fake claude / codex / tmux.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
for f in fleet-claude.sh fleet-codex.sh fleet-launch-lib.sh fleet_agent_adapter.py fleet-agent-adapter.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s missing\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo 'selftest: SKIP — no python3'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-launch-lib.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
AGENTS=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_agent_adapter as a; print(" ".join(a.ADAPTERS))' "$BIN")
COLS=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_agent_adapter as a; print(" ".join(a.COLUMNS))' "$BIN")
# shellcheck source=fleet-agent-adapter.sh
. "$BIN/fleet-agent-adapter.sh"

# ---- A: the table -------------------------------------------------------------------
python3 "$BIN/fleet_agent_adapter.py" --emit-sh | cmp -s - "$BIN/fleet-agent-adapter.sh" \
  || fail "A bin/fleet-agent-adapter.sh is not \`fleet_agent_adapter.py --emit-sh\` — regenerate it"
[ "$FLEET_AGENTS" = "$AGENTS" ] || fail "A the shell copy lists other agents" "$FLEET_AGENTS / $AGENTS"
for a in $AGENTS; do
  for c in $COLS; do
    py=$(python3 "$BIN/fleet_agent_adapter.py" get "$a" "$c") || fail "A get $a $c refused"
    sh=$(fleet_agent_get "$a" "$c") || fail "A fleet_agent_get $a $c refused"
    [ "$py" = "$sh" ] || fail "A $a.$c reads [$py] in Python, [$sh] in shell"
  done
done
fleet_agent_get nobody launcher >/dev/null && fail "A an unknown agent answered"
fleet_agent_get claude nocol >/dev/null && fail "A an unknown column answered"
fleet_agent_known "claude codex" && fail "A a name with a space is an agent"
fleet_agent_get claude 'seed seed_words' >/dev/null && fail "A a column with a space answered"
python3 "$BIN/fleet_agent_adapter.py" known nobody && fail "A python knows an unknown agent"
[ "$(fleet_agent_or_default nobody)" = claude ] && [ "$(fleet_agent_or_default codex)" = codex ] \
  || fail "A or_default"
ok "A the shell copy is the table's own; Python and shell read every column alike; unknowns refused"
[ "$(python3 "$BIN/fleet_agent_adapter.py" seed claude '/fleet-history x')" = '/fleet-history x' ] || fail "A claude's seed is as typed"
[ "$(python3 "$BIN/fleet_agent_adapter.py" seed codex 'plain words')" = 'plain words' ] || fail "A a prose seed is as typed"
out=$(cd "$WORK" && HOME="$WORK" CODEX_HOME="$WORK/nohome" python3 "$BIN/fleet_agent_adapter.py" seed codex '/no-such-cmd y' 2>"$WORK/seed.err")
[ "$out" = '/no-such-cmd y' ] && grep -q 'no commands/no-such-cmd.md' "$WORK/seed.err" || fail "A an unknown /name is as typed, and said" "$out / $(cat "$WORK/seed.err")"
ok "A the seed column: claude as typed; codex prose and an unknown /name as typed (said)"

# ---- B: the readers ask the table ---------------------------------------------------------
# (the scan in a file: bash 3.2 reads quotes inside a heredoc within $(…))
cat > "$WORK/lint.py" <<'PY'
import re
pat = re.compile(r"""(==|!=|[^=!<>]=)\s*["']?codex["']?(\s|\]|;|$)|(^|\s)codex\)""")
for f in ("fleet-claude.sh", "fleet-launch-lib.sh", "fleet-session-wrap.sh", "dash-raw-session.sh", "dash-issue-session.sh"):
    for n, line in enumerate(open(f, errors="replace"), 1):
        code = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
        if pat.search(code):
            print("%s:%d: %s" % (f, n, line.strip()[:110]))
PY
bad=$(cd "$BIN" && python3 "$WORK/lint.py")
[ -z "$bad" ] || fail "B an agent-name branch outside the adapter table" "$bad"
ok "B the door, the library, the wrapper and the spawners ask the table, never an agent's name"

# ---- the install, the login, the fakes ------------------------------------------------------
INST="$WORK/install"; mkdir -p "$INST/bin"
for f in "$BIN"/* "$BIN"/.[!.]*; do [ -e "$f" ] && ln -s "$f" "$INST/bin/${f##*/}"; done
for d in conf hooks commands mod; do [ -e "$ROOT/$d" ] && ln -s "$ROOT/$d" "$INST/$d"; done
mkdir -p "$WORK/fake" "$WORK/proj"
for a in claude codex; do
  cat > "$WORK/fake/$a" <<EOF
#!/bin/sh
case "\$1" in debug|--version|plugin|mcp) printf '%s\n' "\$*" >> "$WORK/calls.$a"; exit 0 ;; esac
printf '%s\n' "\$*" >> "$WORK/calls.$a"
for x in "\$@"; do printf '[%s]\n' "\$x"; done > "$WORK/argv.$a"
{ env | grep -E '^(CLAUDE_CODE_OAUTH_TOKEN|FLEET_CODEX_SESSION_CRED)='
  printf 'pid=%s ppid=%s\n' "\$\$" "\$PPID"
  if (exec 0<&7) 2>/dev/null; then echo fd7=open; else echo fd7=closed; fi; } > "$WORK/env.$a"
ps -o nice= -p \$\$ 2>/dev/null | tr -d ' ' > "$WORK/nice.$a"
printf '%s|%s' "\${CLAUDE_CODE_SHELL_PREFIX-}" "\${FLEET_TOOL_YIELD-}" > "$WORK/prefix.$a"
EOF
  chmod +x "$WORK/fake/$a"
done
cat > "$WORK/fake/tmux" <<EOF
#!/bin/sh
case "\$1" in
  set-option) shift; while [ "\$#" -gt 2 ]; do shift; done; printf '%s\t%s\n' "\$1" "\${2:-}" >> "$WORK/stamps" ;;
esac
exit 0
EOF
chmod +x "$WORK/fake/tmux"
fresh() {   # a fresh login: empty HOME and FLEET_CONF_DIR
  rm -rf "${WORK:?}/home" "${WORK:?}/cfg"; mkdir -p "$WORK/home/.claude/agents" "$WORK/home/.codex" "$WORK/cfg"
}
# launch [VAR=val …] -- <door args…> — the door, as a spawn runs it; rc in $WORK/rc
launch() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -f "$WORK"/argv.* "$WORK"/calls.* "$WORK/stamps" "$WORK/err"
  # shellcheck disable=SC2046  # word-split on purpose: one variable name per word
  ( unset $(env | sed -n 's/^\(FLEET_[A-Za-z0-9_]*\)=.*/\1/p') TMUX CODEX_HOME CLAUDE_CONFIG_DIR CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SHELL_PREFIX
    cd "$WORK/proj" || exit 2
    export PATH="$WORK/fake:/usr/bin:/bin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/cfg" TMUX_PANE=%0 \
           FLEET_PRETRUST=0 FLEET_CODEX_VERSION_CHECK=0 FLEET_STATUS_7501=0 FLEET_CODEX_NATIVE_SKILLS=0
    export ${envs[@]+"${envs[@]}"}
    bash "$INST/bin/fleet-claude.sh" "$@" ) >/dev/null 2>"$WORK/err"
  echo $? > "$WORK/rc"
}
stamp() { awk -F'\t' -v k="$1" '$1 == k { v = $2 } END { print v }' "$WORK/stamps" 2>/dev/null; }
argv()  { cat "$WORK/argv.$1" 2>/dev/null; }
other() { for o in $AGENTS; do [ "$o" = "$1" ] || printf '%s ' "$o"; done; }
model_for() { case "$1" in claude) echo sonnet ;; *) echo gpt-test ;; esac; }

# ---- C: the same window marks, once per agent ------------------------------------------------
for a in $AGENTS; do
  fresh
  m=$(model_for "$a"); menv=$(fleet_agent_get "$a" model_env); mflag=$(fleet_agent_get "$a" model_flag)
  launch "$menv=$m" -- --agent "$a" 'do the thing'
  [ "$(cat "$WORK/rc")" = 0 ] || fail "C $a: the launch failed" "$(cat "$WORK/err")"
  [ -s "$WORK/argv.$a" ] || fail "C $a: its binary never ran" "$(cat "$WORK/err")"
  for o in $(other "$a"); do [ ! -e "$WORK/calls.$o" ] || fail "C $a: the $o CLI ran" "$(cat "$WORK/calls.$o")"; done
  [ "$(stamp @cc_agent)" = "$a" ] || fail "C $a: @cc_agent is [$(stamp @cc_agent)]"
  [ "$(stamp @cc_model)" = "$m" ] || fail "C $a: @cc_model is [$(stamp @cc_model)], want $m"
  argv "$a" | awk -v f="[$mflag]" -v v="[$m]" 'p && $0 == v { found = 1 } { p = ($0 == f) } END { exit !found }' \
    || fail "C $a: no $mflag $m in its argv" "$(argv "$a")"
  [ -n "$(stamp @agent_cfg)" ] && [ -n "$(stamp @agent_cfg_src)" ] || fail "C $a: no @agent_cfg / @agent_cfg_src" "$(cat "$WORK/stamps")"
  case "$(fleet_agent_get "$a" mcp)" in
    flags)  argv "$a" | grep -q 'conf/mcp-worker.json\]$' || fail "C $a: the fleet tool service is not mounted" "$(argv "$a")" ;;
    config) argv "$a" | grep -q '^\[mcp_servers\.fleet=' || fail "C $a: the fleet tool service is not mounted" "$(argv "$a")" ;;
  esac
  [ "$(tail -n 1 "$WORK/argv.$a")" = '[do the thing]' ] || fail "C $a: the seed is not last" "$(argv "$a")"
  ok "C $a: @cc_agent · $menv → $mflag + @cc_model · @agent_cfg · the fleet tools · only its own CLI · the seed last"
done

# ---- D: BREAK-IT ⑥ ⑦ ⑧, both ways -------------------------------------------------------------
# ⑥ the door opens what was asked
for a in $AGENTS; do
  fresh; launch -- --agent "$a" --resume 0d9a7c1e-1111-4222-8333-944455556666 x
  [ -s "$WORK/argv.$a" ] || fail "D⑥ --agent $a (resume-shaped) did not open $a" "$(cat "$WORK/err")"
  for o in $(other "$a"); do [ ! -e "$WORK/argv.$o" ] || fail "D⑥ --agent $a opened $o"; done
done
fresh; launch FLEET_AGENT=codex -- --resume 0d9a7c1e-1111-4222-8333-944455556666 x
[ -s "$WORK/argv.claude" ] && [ ! -e "$WORK/argv.codex" ] || fail "D⑥ a Claude resume on a codex fleet must stay Claude"
fresh; launch FLEET_AGENT=codex -- x
[ -s "$WORK/argv.codex" ] && [ ! -e "$WORK/argv.claude" ] || fail "D⑥ FLEET_AGENT=codex must open Codex" "$(cat "$WORK/err")"
ok "D⑥ the door opens the agent asked for, both ways, resume-shaped too; never the other"
# ⑦ full access from the fleet's defaults
fresh; launch -- --agent claude x
sf=$(argv claude | sed -n 's/^\[--settings=\(.*\)\]$/\1/p')
[ -n "$sf" ] && grep -q '"defaultMode": *"bypassPermissions"' "$sf" || fail "D⑦ claude: a fresh login's session has no bypassPermissions" "$(argv claude)"
fresh; launch -- --agent codex x
if ! argv codex | grep -qxF '[--dangerously-bypass-approvals-and-sandbox]'; then
  argv codex | grep -qxF '[approval_policy="never"]' && argv codex | grep -qxF '[sandbox_mode="danger-full-access"]' \
    || fail "D⑦ codex: a fresh login's session has no full access" "$(argv codex)"
fi
fresh; printf 'approval_policy = "never"\nsandbox_mode = "danger-full-access"\n' > "$WORK/home/.codex/config.toml"
launch -- --agent codex x
argv codex | grep -qE '^\[(--dangerously-bypass-approvals-and-sandbox|approval_policy=.*|sandbox_mode=.*)\]$' \
  && fail "D⑦ codex: the login's config gives full access, yet the start overrides it (blocks in-TUI /resume)" "$(argv codex)"
ok "D⑦ a fresh session has full access from the fleet's defaults, both ways; a login that has it gets no Codex CLI override"
# ⑧ one agent's start never runs the other's CLI — as an agent file too
for a in $AGENTS; do
  fresh; cp "$ROOT/conf/agent-defaults/claude/agents/fleet-worker.md" "$WORK/home/.claude/agents/"
  launch -- --agent "$a" --as fleet-worker x
  [ -s "$WORK/argv.$a" ] || fail "D⑧ $a --as fleet-worker did not open" "$(cat "$WORK/err")"
  for o in $(other "$a"); do [ ! -e "$WORK/calls.$o" ] || fail "D⑧ a $a start ran the $o CLI" "$(cat "$WORK/calls.$o")"; done
done
ok "D⑧ starting one agent (as an agent file too) never runs the other's CLI — no \`claude plugin list\` for Codex"

# ---- E: the resume spelling is the table's ------------------------------------------------------
SID=0d9a7c1e-1111-4222-8333-944455556666
for a in $AGENTS; do
  fresh; launch -- --agent "$a" --resume "$SID" x
  rf=$(fleet_agent_get "$a" resume_flag)
  argv "$a" | awk -v f="[$rf]" -v v="[$SID]" 'p && $0 == v { found = 1 } { p = ($0 == f) } END { exit !found }' \
    || fail "E $a: no $rf $SID in its argv" "$(argv "$a")"
  po=$(fleet_agent_get "$a" sid_pending)
  if [ -n "$po" ]; then
    stamp "$po" | grep -qF "\"session_id\":\"$SID\"" || fail "E $a: $po does not name $SID" "$(stamp "$po")"
  fi
done
ok "E the resume spelling is the table's per agent; the pending-id option names the thread"

# ---- F: the credential proxy refuses alike ------------------------------------------------------
rm "$INST/bin/fleet-session-cred.sh"
for rc in 5 1; do
  printf '#!/bin/sh\nexit %s\n' "$rc" > "$INST/bin/fleet-session-cred.sh"; chmod +x "$INST/bin/fleet-session-cred.sh"
  want=cred; [ "$rc" = 5 ] && want=cred_unknown
  for a in $AGENTS; do
    fresh; launch FLEET_CRED_SID=sid-test -- --agent "$a" x
    [ "$(cat "$WORK/rc")" = 1 ] || fail "F $a: mint rc $rc ⇒ exit $(cat "$WORK/rc"), want 1" "$(cat "$WORK/err")"
    [ ! -e "$WORK/argv.$a" ] || fail "F $a: the agent ran after a refused mint"
    [ "$(stamp @launch_refused)" = "$want" ] || fail "F $a: @launch_refused [$(stamp @launch_refused)], want $want"
    grep -q "^fleet-$a: " "$WORK/err" || fail "F $a: the refusal is not said in its own name" "$(cat "$WORK/err")"
  done
done
ok "F a refused session credential: exit 1, @launch_refused cred / cred_unknown, the agent never runs — both agents"

# ---- G: the mint starts early ------------------------------------------------------------------
cat > "$INST/bin/fleet-session-cred.sh" <<EOF
#!/bin/sh
case "\$1" in
  mint) printf '%s\n' "\${FLEET_SESSION_WRAP:-}" > "$WORK/mint.wrap"
        i=0; while [ \$i -lt 60 ]; do   # up to 6 s for the composer's manifest
          ls "$WORK/cfg/agentcfg/"*.json >/dev/null 2>&1 && { echo saw > "$WORK/mint.beside"; break; }
          sleep 0.1; i=\$((i + 1)); done
        printf 'direct\t4321\tfcp1.selftest\n' ;;
  codex-home) mkdir -p "$WORK/chome"; printf '%s\n' "$WORK/chome" ;;
  standing) exit 0 ;;
esac
EOF
chmod +x "$INST/bin/fleet-session-cred.sh"
for early in 1 0; do
  for a in $AGENTS; do
    fresh; rm -f "${WORK:?}/mint.wrap" "${WORK:?}/mint.beside" "${WORK:?}/env.$a"
    launch FLEET_CRED_SID=sid-test FLEET_LAUNCH_EARLY=$early -- --agent "$a" x
    [ "$(cat "$WORK/rc")" = 0 ] && [ -s "$WORK/argv.$a" ] || fail "G $a early=$early: the launch failed" "$(cat "$WORK/err")"
    grep -qE '^(CLAUDE_CODE_OAUTH_TOKEN|FLEET_CODEX_SESSION_CRED)=fcp1\.selftest$' "$WORK/env.$a" \
      || fail "G $a early=$early: the minted credential did not reach the agent" "$(cat "$WORK/env.$a")"
    grep -qx fd7=closed "$WORK/env.$a" || fail "G $a early=$early: the agent inherited fd 7" "$(cat "$WORK/env.$a")"
    if [ "$early" = 1 ]; then   # (in place, the script's own $PPID default names it, as ever)
      w=$(cat "$WORK/mint.wrap" 2>/dev/null)
      [ -n "$w" ] && grep -qE "^pid=$w |ppid=$w\$" "$WORK/env.$a" \
        || fail "G $a: the early mint's --wrap [$w] is not the launcher" "$(cat "$WORK/env.$a")"
      [ -s "$WORK/mint.beside" ] || fail "G $a: the mint did not run beside the composed configuration"
    fi
  done
done
ok "G the mint runs beside the launch (credential to the agent, --wrap the launcher, no fd 7); FLEET_LAUNCH_EARLY=0 the same — both agents"
# ---- H: the agent yields to the 看台 (T691) ------------------------------------------------------
yl() { ( unset FLEET_AGENT_YIELD; [ -n "$2" ] && export FLEET_AGENT_YIELD="$2"
         OSTYPE=$1; BIN="$BIN"; eval "$(sed -n '/^_fl_yield=()$/,/^}$/p' "$BIN/fleet-launch-lib.sh")"
         fleet_launch_yield; printf '%s' "${_fl_yield[*]-}" ); }
[ "$(yl darwin24 '')" = "/usr/sbin/taskpolicy -c utility" ] || [ ! -x /usr/sbin/taskpolicy ] || fail "H a Mac: [$(yl darwin24 '')]"
[ "$(yl darwin24 background)" = "/usr/sbin/taskpolicy -c background" ] || [ ! -x /usr/sbin/taskpolicy ] || fail "H a Mac, background"
[ "$(yl linux-gnu '')" = "nice -n 5" ] && [ "$(yl linux-gnu background)" = "nice -n 15" ] \
  && [ "$(yl linux-gnu bogus)" = "nice -n 5" ] || fail "H linux: [$(yl linux-gnu '')] [$(yl linux-gnu background)]"
for off in 0 off none; do [ -z "$(yl linux-gnu $off)" ] && [ -z "$(yl darwin24 $off)" ] || fail "H $off still yields"; done
ok "H fleet_launch_yield: taskpolicy -c on a Mac, nice elsewhere, nothing for 0/off"
# …and what Claude runs, one class lower again: CLAUDE_CODE_SHELL_PREFIX (Claude only —
# Codex has no such prefix); FLEET_TOOL_YIELD=0 or a prefix of the person's own: none
IBIN=$(cd "$INST/bin" && pwd)
fresh; launch -- --agent claude x
[ "$(cat "$WORK/prefix.claude")" = "$IBIN/fleet-tool-yield.sh|background" ] || fail "H claude's CLAUDE_CODE_SHELL_PREFIX: [$(cat "$WORK/prefix.claude")]"
fresh; launch FLEET_TOOL_YIELD=utility -- --agent claude x
[ "$(cat "$WORK/prefix.claude")" = "$IBIN/fleet-tool-yield.sh|utility" ] || fail "H FLEET_TOOL_YIELD=utility: [$(cat "$WORK/prefix.claude")]"
fresh; launch FLEET_TOOL_YIELD=0 -- --agent claude x
[ "$(cat "$WORK/prefix.claude")" = "|0" ] || fail "H FLEET_TOOL_YIELD=0 still set a prefix: [$(cat "$WORK/prefix.claude")]"
fresh; launch CLAUDE_CODE_SHELL_PREFIX=/opt/mine.sh -- --agent claude x
[ "$(cat "$WORK/prefix.claude")" = "/opt/mine.sh|" ] || fail "H the person's own prefix was replaced: [$(cat "$WORK/prefix.claude")]"
ok "H Claude's commands go through fleet-tool-yield.sh; 0 or the person's own prefix: untouched"
case "${OSTYPE:-}" in darwin*) ;; *)
  base=$(ps -o nice= -p $$ | tr -d ' ')
  for a in $AGENTS; do
    fresh; launch -- --agent "$a" x
    [ "$(cat "$WORK/nice.$a" 2>/dev/null)" = $((base + 5)) ] || fail "H $a runs at nice [$(cat "$WORK/nice.$a" 2>/dev/null)], want $((base + 5))" "$(cat "$WORK/err")"
    grep -qx '\[x\]' "$WORK/argv.$a" || fail "H $a: the seed did not reach the agent" "$(argv "$a")"
    fresh; launch FLEET_AGENT_YIELD=0 -- --agent "$a" x
    [ "$(cat "$WORK/nice.$a" 2>/dev/null)" = "$base" ] || fail "H $a with FLEET_AGENT_YIELD=0 runs at nice [$(cat "$WORK/nice.$a" 2>/dev/null)]"
  done
  ok "H the agent itself runs at nice +5 (0: its parent's), both agents" ;;
esac

printf 'fleet-launch-lib selftest OK: %s checks (T620, EPIC T580 C4)\n' "$pass"
