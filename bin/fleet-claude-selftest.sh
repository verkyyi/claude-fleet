#!/bin/bash
# fleet-claude-selftest.sh — the launcher's CONFIG contract (issues #472, #473).
#
# bin/fleet-claude.sh is the single door every fleet session walks through, so what
# it reads decides what a worker actually runs. Two rails are pinned here:
#
#   #472 — it must overlay the PER-FLEET conf on top of the global one. It used to
#          read the global fleet.conf ONLY, and nothing else carried the per-fleet
#          conf into a spawned window (a `tmux new-window` command string does not
#          inherit the spawner's env), so every @scope=fleet key that only this
#          script reads was silently inert: two fleets configured FLEET_MODEL="fable"
#          and every session they spawned ran `--model opus`. The miss failed
#          quietly UPWARD — toward the most expensive model — which is exactly the
#          shape of bug a test has to hold down.
#
#   #473 — FLEET_MCP_CONFIG selects which MCP servers a fleet's sessions boot:
#          unset → everything (unchanged), `none` → nothing, else → only those.
#
#   #476 — and it must not EAT THE SEED PROMPT. `--mcp-config <configs...>` is
#          VARIADIC: in the separated form it reaches past its own value and
#          swallows the following positional. Every issue-bound spawn passes the
#          seed prompt positionally (`fleet-claude.sh "$(cat …)"`), so #473 shipped
#          with every worker dying at launch on `MCP config file not found:
#          /fleet-history` — while a raw ⌃s scratch, which passes NO positional, kept
#          working. That asymmetry is why it got through: the pre-landing check and
#          this selftest both exercised the no-positional path only. The fix is the
#          =form (`--mcp-config=<v>`), which cannot reach past the flag.
#
# Both must stay INERT by default (an unset key changes no argv) and must yield to
# an explicit caller flag, the rule --model already follows.
#
# Hermetic: a temp bin with the real script + lib symlinked, its own fleet.conf and
# FLEET_CONF_DIR, and fake `claude` / `tmux` / `fleet-account.sh` on PATH. No tmux
# server, no network, no real config touched. Exit 0 = pass.
#
#   J7BN — FLEET_MODEL deepseek / deepseek-pro: bin/fleet-claude.sh asks
#          bin/fleet-session-cred.sh for a deepseek (central) pass and points Claude
#          Code at the credential proxy's /deepseek road; no proxy ⇒ refused.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
SUT="$BIN/fleet-claude.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$SUT" "$LIB"; do [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }; done

st_sandbox "${TMPDIR:-/tmp}/fleet-claude.XXXXXX"
trap 'exit 130' INT TERM HUP

pass=0

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf/fleets/f1" "$WORK/conf/fleets/f2"
ln -s "$SUT" "$WORK/bin/fleet-claude.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"

# fake `fleet-account.sh`: no accounts registered → transparent passthrough, the
# single-account default this script is built to preserve.
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/fleet-account.sh"; chmod +x "$WORK/bin/fleet-account.sh"

# fake `claude`: the SUT execs it, so its argv IS the assertion surface.
cat > "$WORK/fakebin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$WORK/argv"
printf '%s\n' "\${CLAUDE_CODE_SUBAGENT_MODEL:-}" > "$WORK/subm"
exit 0
EOF
chmod +x "$WORK/fakebin/claude"

# fake `tmux`: only display-message is used (fleet_current_session). The session it
# names is whatever \$SESS_FILE holds — empty file ⇒ "outside a fleet".
SESS_FILE="$WORK/sess"; printf 'f1' > "$SESS_FILE"
cat > "$WORK/fakebin/tmux" <<EOF
#!/bin/sh
case "\$1" in
  display-message) case "\$*" in *'@agent_spawn'*) cat "$WORK/spawnopt" 2>/dev/null ;; *) cat "$SESS_FILE" ;; esac ;;
  set-option) printf '%s\n' "\$*" >> "$WORK/tmuxlog" ;; *) : ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin/tmux"
export PATH="$WORK/fakebin:$PATH"
export FLEET_CONF_DIR="$WORK/conf"
export TMUX_PANE="%0"

# global fleet.conf — the sibling both the lib and the SUT source
printf 'FLEET_MODEL="opus"\n' > "$WORK/fleet.conf"

run() {   # run the SUT with a fresh env; extra args are passed through to it
  rm -f "$WORK/argv"
  ( unset FLEET_MODEL FLEET_SUBAGENT_MODEL FLEET_MCP_CONFIG CLAUDE_CODE_SUBAGENT_MODEL FLEET_MODEL_FALLBACK
    bash "$WORK/bin/fleet-claude.sh" "$@" ) >/dev/null 2>&1
  cat "$WORK/argv" 2>/dev/null
}
has()  { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# --- #472: the per-fleet conf overlays the global one ------------------------
printf 'FLEET_MODEL="fable"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
has "$argv" "--model fable" || st_fail "per-fleet FLEET_MODEL did not reach the launcher" "$argv"
st_pass "a per-fleet FLEET_MODEL overrides the global one (#472)"

# a second fleet gets ITS value, not the first one's
printf 'FLEET_MODEL="sonnet"\n' > "$WORK/conf/fleets/f2/conf"
printf 'f2' > "$SESS_FILE"
argv="$(run)"
has "$argv" "--model sonnet" || st_fail "the second fleet did not get its own model" "$argv"
st_pass "each fleet resolves its own conf"

# no per-fleet value → the global one still applies
: > "$WORK/conf/fleets/f2/conf"
argv="$(run)"
has "$argv" "--model opus" || st_fail "global FLEET_MODEL stopped applying" "$argv"
st_pass "an empty per-fleet conf falls through to the global value"

# outside a fleet (no session resolvable) → global only, no crash
: > "$SESS_FILE"
argv="$(run)"
has "$argv" "--model opus" || st_fail "no-session path broke the launch" "$argv"
st_pass "no resolvable session is a clean no-op, not a failure"
printf 'f1' > "$SESS_FILE"

# an explicit --model from the caller still wins
argv="$(run --model haiku)"
has "$argv" "--model haiku" || st_fail "caller --model was dropped" "$argv"
case "$argv" in *"--model fable"*) st_fail "the conf model was added ALONGSIDE the caller's" "$argv" ;; esac
st_pass "an explicit --model from the caller still wins"

# --- #473: FLEET_MCP_CONFIG ---------------------------------------------------
printf 'FLEET_MODEL="fable"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
case "$argv" in *--strict-mcp-config*|*--mcp-config*) st_fail "unset FLEET_MCP_CONFIG changed the argv" "$argv" ;; esac
st_pass "FLEET_MCP_CONFIG unset leaves the launch untouched (default is unchanged)"

printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="none"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
has "$argv" "--strict-mcp-config" || st_fail "FLEET_MCP_CONFIG=none did not pin MCP off" "$argv"
case "$argv" in *'{"mcpServers":{}}'*) : ;; *) st_fail "none did not expand to an empty server set" "$argv" ;; esac
st_pass "FLEET_MCP_CONFIG=none boots no MCP server at all"

printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG=%s\n' "'{\"mcpServers\":{\"playwright\":{\"command\":\"npx\"}}}'" > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
has "$argv" "--strict-mcp-config" || st_fail "an inline-JSON allowlist did not set --strict-mcp-config" "$argv"
case "$argv" in *'"playwright"'*) : ;; *) st_fail "the inline allowlist was not passed through" "$argv" ;; esac
st_pass "an inline-JSON allowlist passes through with --strict-mcp-config"

printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="%s/mcp.json"\n' "$WORK" > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
has "$argv" "--mcp-config=$WORK/mcp.json" || st_fail "a file path was not passed through verbatim" "$argv"
st_pass "a file path passes through verbatim, in the =form (the CLI takes either value shape)"

# --- #1078: the shipped minimal worker set, conf/mcp-worker.json ---------------
# conf/fleet.conf.reference + docs/dev/INSTALL.md RECOMMEND pointing FLEET_MCP_CONFIG at this
# file, so pin both halves: the file itself (present, valid, ONLY an mcpServers
# object — the shape bin/fleet-codex-policy.py also accepts — and containing only
# the fleet-peer bridge), and that pointing the key at it launches strict with
# that file and the seed intact. "Survives /fleet-sync-install" == tracked in git, because the
# live install IS a checkout that sync fast-forwards.
WORKER_MCP="$BIN/../conf/mcp-worker.json"
[ -f "$WORKER_MCP" ] || st_fail "conf/mcp-worker.json is missing — the recommended FLEET_MCP_CONFIG target"
python3 - "$WORKER_MCP" <<'PY' || st_fail "conf/mcp-worker.json does not contain only the fleet tool service"
import json, sys
d = json.load(open(sys.argv[1]))
assert isinstance(d, dict) and set(d) == {"mcpServers"}, d
servers = d["mcpServers"]
assert set(servers) == {"fleet"}, servers                     # issue #1807: the one tool service
server = servers["fleet"]
assert server["command"] == "bash" and server["args"] == ["-c", 'exec python3 "${FLEET_MCP_BIN:-$HOME/.claude/fleet/bin}/fleet-mcp.py"'], server
PY
if git -C "$BIN/.." rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$BIN/.." ls-files --error-unmatch conf/mcp-worker.json >/dev/null 2>&1 \
    || st_fail "conf/mcp-worker.json is not tracked — /fleet-sync-install would never deliver it"
fi
printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="%s"\n' "$WORKER_MCP" > "$WORK/conf/fleets/f1/conf"
argv="$(run /fleet-history)"
has "$argv" "--strict-mcp-config" || st_fail "FLEET_MCP_CONFIG=conf/mcp-worker.json did not launch strict" "$argv"
has "$argv" "--mcp-config=$WORKER_MCP" || st_fail "conf/mcp-worker.json was not the ONLY config passed" "$argv"
[ "$(printf '%s\n' "$argv" | grep -c -- '--mcp-config')" = 1 ] || st_fail "more than one --mcp-config alongside mcp-worker.json" "$argv"
has "$argv" "/fleet-history" || st_fail "the seed prompt was swallowed with mcp-worker.json" "$argv"
st_pass "conf/mcp-worker.json ships (tracked, the fleet server only) and FLEET_MCP_CONFIG→it launches strict with only that file"

# an explicit caller flag wins over the conf
printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="none"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run --mcp-config "$WORK/other.json")"
case "$argv" in *'{"mcpServers":{}}'*) st_fail "the conf overrode the caller's --mcp-config" "$argv" ;; esac
has "$argv" "--mcp-config $WORK/other.json" || st_fail "caller --mcp-config was dropped" "$argv"
st_pass "an explicit --mcp-config from the caller wins over the conf"

argv="$(run --strict-mcp-config)"
case "$argv" in *'{"mcpServers":{}}'*) st_fail "the conf added its own config despite --strict-mcp-config" "$argv" ;; esac
st_pass "an explicit --strict-mcp-config from the caller is left alone"

# --- #476: the seed prompt must survive, in EVERY config form ----------------
# `--mcp-config <v>` (separated) is variadic and ate the positional that follows —
# which is the seed prompt on every issue-bound spawn. Assert the prompt arrives
# intact, and that the flag is emitted in the =form that makes that structural.
SEED='/fleet-history'
for cfg in none '{"mcpServers":{}}' "$WORK/mcp.json"; do
  printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG=%s\n' "'$cfg'" > "$WORK/conf/fleets/f1/conf"
  argv="$(run "$SEED")"
  has "$argv" "$SEED" || st_fail "the seed prompt was swallowed with FLEET_MCP_CONFIG=$cfg" "$argv"
  case "$argv" in
    *"--mcp-config="*) : ;;
    *) st_fail "--mcp-config must use the =form or it eats the positional (FLEET_MCP_CONFIG=$cfg)" "$argv" ;;
  esac
done
st_pass "the seed prompt survives every FLEET_MCP_CONFIG form (=form, not separated)"

# a multi-word prompt with spaces stays ONE argument
printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="none"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run 'Work GitHub issue #2109 in this repo')"
case "$argv" in *"Work GitHub issue #2109 in this repo"*) : ;; *) st_fail "a multi-word prompt was mangled" "$argv" ;; esac
st_pass "a multi-word seed prompt passes through intact"

# --- #524 → T550: the launcher no longer swaps the model off a model cap -------
# The per-(account, model) cap ledger (`model-limited-until`) was read here against
# the account the launcher PICKED. There is no pick since T550 (EPIC T542 C4): the
# pool picks behind the credential proxy, so the launch runs FLEET_MODEL and asks
# fleet-account.sh nothing; relaunching a walled session on the fallback stays
# fleet-model-switch.sh's.
cat > "$WORK/bin/fleet-account.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/account.calls"
case "\$1" in
  active) echo acctA ;;
  token)  echo tok-A ;;
  model-limited-until) echo \$(( \$(date +%s) + 3600 )) ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/fleet-account.sh"
printf 'f1' > "$SESS_FILE"
printf 'FLEET_MODEL="fable"\n' > "$WORK/conf/fleets/f1/conf"
printf 'FLEET_MODEL="opus"\n' > "$WORK/fleet.conf"
: > "$WORK/tmuxlog"; rm -f "$WORK/account.calls"
argv="$(run)"
has "$argv" "--model fable" || st_fail "the launch must run FLEET_MODEL — no cap ledger is read (T550)" "$argv"
[ "$(cat "$WORK/subm")" = fable ] || st_fail "subagents follow the launch model (got '$(cat "$WORK/subm")')"
grep -q '@cc_model fable' "$WORK/tmuxlog" 2>/dev/null || st_fail "the pane must be stamped @cc_model fable (tmux: $(cat "$WORK/tmuxlog" 2>/dev/null))"
[ ! -s "$WORK/account.calls" ] || st_fail "the launcher must ask fleet-account.sh nothing (T550): $(cat "$WORK/account.calls")"
st_pass "no pick, no cap swap: FLEET_MODEL launches, subagents follow, @cc_model stamped (T550)"
argv="$(run --model haiku)"
has "$argv" "--model haiku" || st_fail "caller --model was dropped" "$argv"
st_pass "an explicit caller --model still wins"
printf 'FLEET_MODEL="opus"\n' > "$WORK/conf/fleets/f1/conf"

# --- #563: the launcher pre-trusts THIS fleet's checkout before exec ------------
# Claude Code parks an untrusted project on "trust this folder?" — with nobody in
# the pane, for good. The launcher (the one door every spawn walks through) hands
# FLEET_MAIN + its cwd to bin/fleet-trust.sh, which scopes + writes atomically (its
# own selftest covers that); here we pin the CALL: made by default with the fleet's
# FLEET_MAIN and the launch cwd, skipped under FLEET_PRETRUST=0 or with no
# FLEET_MAIN, and its stderr note names what it trusted. A fake fleet-trust.sh
# records its argv; the real one never runs (no ~/.claude.json is touched). Its
# `node` answers "not a trusted node" (exit 2): the #563 narrow call is pinned here;
# the trusted node's wide form (#2282) is fleet-trust-selftest.sh J.
TRUST_LOG="$WORK/trustlog"
cat > "$WORK/bin/fleet-trust.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TRUST_LOG"
case "\$1" in node) exit 2 ;; grant) printf '%s\n' "\$3" ;; file) echo /fake/home/.claude.json ;; esac
exit 0
EOF
chmod +x "$WORK/bin/fleet-trust.sh"
runt() {   # like run() with no args, but also scrubs the trust knobs from the env and keeps stderr
  rm -f "$WORK/argv" "$TRUST_LOG"
  ( unset FLEET_MODEL FLEET_SUBAGENT_MODEL FLEET_MCP_CONFIG CLAUDE_CODE_SUBAGENT_MODEL FLEET_MODEL_FALLBACK FLEET_MAIN FLEET_PRETRUST
    bash "$WORK/bin/fleet-claude.sh" ) >/dev/null 2>"$WORK/err"
}
printf 'FLEET_MODEL="opus"\n' > "$WORK/fleet.conf"
mkdir -p "$WORK/main"
printf 'FLEET_MODEL="opus"\n' > "$WORK/conf/fleets/f1/conf"; fx_repo "$WORK/conf" f1 acme/app FLEET_MAIN="$WORK/main"
runt
[ -f "$TRUST_LOG" ] || st_fail "#563 the launcher did not call fleet-trust.sh at all" "$(cat "$WORK/err")"
grep -qxF "grant --main $WORK/main $PWD" "$TRUST_LOG" || st_fail "#563 pre-trust must be 'grant --main <FLEET_MAIN> <cwd>'" "$(cat "$TRUST_LOG")"
grep -q "pre-trusted $WORK/main in /fake/home/.claude.json" "$WORK/err" || st_fail "#563 a granted path must be announced on stderr" "$(cat "$WORK/err")"
[ -s "$WORK/argv" ] || st_fail "#563 claude must still be exec'd after pre-trust" "$(cat "$WORK/err")"
st_pass "pre-trust: grant --main <FLEET_MAIN> <cwd> before exec, announced in the pane (#563)"

printf 'FLEET_MODEL="opus"\nFLEET_PRETRUST=0\n' > "$WORK/conf/fleets/f1/conf"
runt
[ ! -f "$TRUST_LOG" ] || st_fail "#563 FLEET_PRETRUST=0 must skip the pre-trust call" "$(cat "$TRUST_LOG")"
[ -s "$WORK/argv" ] || st_fail "#563 claude must still launch with pre-trust off"
st_pass "FLEET_PRETRUST=0 opts the fleet out (claude still launches)"

printf 'FLEET_MODEL="opus"\n' > "$WORK/conf/fleets/f1/conf"; rm -rf "$WORK/conf/fleets/f1/repos"   # no FLEET_MAIN anywhere
runt
[ ! -f "$TRUST_LOG" ] || st_fail "#563 no FLEET_MAIN → nothing to trust, no call" "$(cat "$TRUST_LOG")"
st_pass "no FLEET_MAIN resolvable → pre-trust is skipped quietly"

# a refused cwd (exit 3, e.g. a plain launch from ~) is silent; a real write failure is shown
cat > "$WORK/bin/fleet-trust.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TRUST_LOG"
case "\$1" in grant) echo "fleet-trust: refusing \$4: not a worktree" >&2; exit 3 ;; file) echo /fake/home/.claude.json ;; esac
exit 0
EOF
printf 'FLEET_MODEL="opus"\n' > "$WORK/conf/fleets/f1/conf"; fx_repo "$WORK/conf" f1 acme/app FLEET_MAIN="$WORK/main"
runt
grep -q "refusing" "$WORK/err" && st_fail "#563 a refused cwd (exit 3) must be silent in the pane" "$(cat "$WORK/err")"
[ -s "$WORK/argv" ] || st_fail "#563 a refused cwd must not block the launch"
cat > "$WORK/bin/fleet-trust.sh" <<EOF
#!/bin/sh
case "\$1" in grant) echo "fleet-trust: /fake/home/.claude.json is not valid JSON — leaving it alone" >&2; exit 5 ;; file) echo /fake/home/.claude.json ;; esac
exit 0
EOF
runt
grep -q "not valid JSON" "$WORK/err" || st_fail "#563 a real pre-trust failure must be shown in the pane" "$(cat "$WORK/err")"
[ -s "$WORK/argv" ] || st_fail "#563 a pre-trust failure must not block the launch (claude is the authority)"
st_pass "a refused cwd is silent, a real write failure is shown — and neither blocks the launch"

# --- #1807: every session mounts the fleet tool service ------------------------
# A sandbox bin WITH conf/mcp-worker.json + fleet-mcp.py beside it (every check
# above runs without them, so it stays byte for byte what it was). The launcher
# adds --mcp-config=<that file> — additive, never --strict on its own — beside any
# FLEET_MCP_CONFIG, not twice when the allowlist IS that file, never over a
# caller's own MCP flags, never with FLEET_MCP=0; and it tells the server which
# bin/ to run (FLEET_MCP_BIN) and the mod not to register its own copy.
mkdir -p "$WORK/conf"
cp "$BIN/../conf/mcp-worker.json" "$WORK/conf/mcp-worker.json"
cp "$BIN/../conf/mcp-orch.json" "$WORK/conf/mcp-orch.json"
ln -s "$BIN/fleet-mcp.py" "$WORK/bin/fleet-mcp.py"
ln -s "$BIN/fleet-agent-def.py" "$WORK/bin/fleet-agent-def.py"   # --as reads the agent file (#3122)
MW="$(cd "$WORK/bin" && pwd)/../conf/mcp-worker.json"
MO="$(cd "$WORK/bin" && pwd)/../conf/mcp-orch.json"
cat > "$WORK/fakebin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$WORK/argv"
printf '%s|%s\n' "\${FLEET_MCP_BIN:-}" "\${FLEET_MCP_SERVER:-}" > "$WORK/mcpenv"
printf '%s\n' "\${FLEET_MCP_ORCH:-}" > "$WORK/mcporch"
exit 0
EOF
chmod +x "$WORK/fakebin/claude"
printf 'FLEET_MODEL="fable"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run /fleet-history)"
has "$argv" "--mcp-config=$MW" || st_fail "#1807 the default launch did not mount conf/mcp-worker.json" "$argv"
case "$argv" in *--strict-mcp-config*) st_fail "#1807 the mount alone made the launch strict" "$argv" ;; esac
has "$argv" "/fleet-history" || st_fail "#1807 the seed prompt was swallowed by the mount" "$argv"
[ "$(cat "$WORK/mcpenv")" = "$(cd "$WORK/bin" && pwd)|1" ] || st_fail "#1807 FLEET_MCP_BIN / FLEET_MCP_SERVER not exported" "$(cat "$WORK/mcpenv")"
st_pass "#1807 default: --mcp-config=conf/mcp-worker.json (additive, =form, seed intact), FLEET_MCP_BIN + FLEET_MCP_SERVER set"

# #4703 (after #4591): the dispatch group `fleet-orch` (conf/mcp-orch.json) rides EVERY
# launch — any session may spawn; caps and the claim dedup are the bounds. A plain launch,
# a worker, a bare role name, an agent file that does not grant spawn (fleet-worker taking
# it away included), a pane stamped @agent_spawn 0 or none: all mount both servers and say
# FLEET_MCP_ORCH=1 (never inherited — the launcher sets it itself).
both() { # both <what> <argv>
  has "$2" "--mcp-config=$MW" && has "$2" "--mcp-config=$MO" && [ "$(cat "$WORK/mcporch")" = 1 ] \
    || st_fail "#4703 $1 did not mount the dispatch group" "$2 / $(cat "$WORK/mcporch")"
}
both "a plain launch" "$argv"
argv="$( (export FLEET_MCP_ORCH=0; run /fleet-history) )"; both "a worker (FLEET_MCP_ORCH=0 inherited)" "$argv"
mkdir -p "$WORK/ccfg/agents"
printf -- '---\nname: custom-agent\ndescription: d\n---\nbody\n' > "$WORK/ccfg/agents/custom-agent.md"
argv="$( (export CLAUDE_CONFIG_DIR="$WORK/ccfg"; run --as custom-agent 'continue this task') )"; both "a custom agent" "$argv"
rm -f "$WORK/argv"
CLAUDE_CONFIG_DIR="$WORK/ccfg" bash "$WORK/bin/fleet-claude.sh" --as epic-driver > "$WORK/retired.out" 2> "$WORK/retired.err"; retired_rc=$?
[ "$retired_rc" = 3 ] && [ ! -e "$WORK/argv" ] && grep -q 'ROLE_RETIRED' "$WORK/retired.err" \
  || st_fail "retired EPIC driver must refuse before native launch"
printf -- '---\nname: fleet-worker\ndescription: w\ndisallowedTools: mcp__fleet-orch__spawn\n---\nbody\n' > "$WORK/ccfg/agents/fleet-worker.md"
argv="$( (export CLAUDE_CONFIG_DIR="$WORK/ccfg"; run --as fleet-worker /fleet-history) )"; both "a worker file that takes spawn away" "$argv"
for v in 0 1; do
  printf '%s\n' "$v" > "$WORK/spawnopt"
  argv="$(run)"; both "a pane stamped @agent_spawn $v" "$argv"
done
rm -f "$WORK/spawnopt"
st_pass "#4703 every launch mounts the dispatch group (plain, worker, role name, agent file with or without spawn, @agent_spawn 0/1)"

printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="none"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
has "$argv" "--strict-mcp-config" && has "$argv" "--mcp-config=$MW" || st_fail "#1807 FLEET_MCP_CONFIG=none dropped the fleet server" "$argv"
printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="%s"\n' "$MW" > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
[ "$(printf '%s\n' "$argv" | grep -o -- 'mcp-worker.json' | wc -l | tr -d ' ')" = 1 ] || st_fail "#1807 the allowlist IS the file, yet it was mounted twice" "$argv"
st_pass "#1807 beside an allowlist (none too) it rides along; an allowlist that IS the file is not mounted twice"

printf 'FLEET_MODEL="fable"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run --mcp-config "$WORK/other.json")"
case "$argv" in *"--mcp-config=$MW"*) st_fail "#1807 mounted over a caller's own --mcp-config" "$argv" ;; esac
argv="$( (export FLEET_MCP=0; run) )"
case "$argv" in *--mcp-config*) st_fail "#1807 FLEET_MCP=0 still mounted it" "$argv" ;; esac
[ "$(cat "$WORK/mcpenv")" = "|" ] || st_fail "#1807 FLEET_MCP=0 still exported the mount env" "$(cat "$WORK/mcpenv")"
st_pass "#1807 a caller's own MCP flag or FLEET_MCP=0: nothing mounted, nothing exported"

# --- J7BN: a DeepSeek model profile (FLEET_MODEL deepseek / deepseek-pro) --------
# Claude Code on DeepSeek's Anthropic-compatible API, through the credential proxy's
# /deepseek road: the mint asks fleet-session-cred.sh for --provider deepseek (a hub
# pass — central only), the base URL ends in /deepseek, every tier is a DeepSeek
# model, no --model reaches claude; without the proxy it refuses with one line.
cat > "$WORK/bin/fleet-session-cred.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/mintargs"
printf 'central\t4321\tfcp-h2.fake.pass\n'
EOF
chmod +x "$WORK/bin/fleet-session-cred.sh"
cp "$WORK/fakebin/claude" "$WORK/claude.before"
cat > "$WORK/fakebin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$WORK/argv"
env | grep -E '^(ANTHROPIC_|CLAUDE_CODE_(OAUTH_TOKEN|SUBAGENT_MODEL|AUTO_COMPACT_WINDOW|DISABLE_NONESSENTIAL_TRAFFIC)=)' | sort > "$WORK/env"
exit 0
EOF
for prof in deepseek DeepSeek-Pro; do
  printf 'FLEET_MODEL="%s"\n' "$prof" > "$WORK/conf/fleets/f1/conf"
  rm -f "$WORK/env" "$WORK/mintargs"; : > "$WORK/tmuxlog"
  # the first carries a caller's --model (a migrate's @cc_model) — ours, never claude's
  ma=(); [ "$prof" = deepseek ] && ma=(--model deepseek)
  argv="$( (export FLEET_CRED_SID=sid-ds; run ${ma[@]+"${ma[@]}"} /fleet-history) )"
  case "$prof" in DeepSeek-Pro) w=deepseek-v4-pro p=deepseek-pro ;; *) w=deepseek-flash p=deepseek ;; esac
  # Claude Code's own ids (no unrecognized_model); DeepSeek's on the wire via modelOverrides
  want="ANTHROPIC_BASE_URL=http://127.0.0.1:4321/deepseek
ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-5-5
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5-5[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5-5[1m]
ANTHROPIC_MODEL=claude-opus-5-5[1m]
CLAUDE_CODE_AUTO_COMPACT_WINDOW=786432
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
CLAUDE_CODE_OAUTH_TOKEN=fcp-h2.fake.pass
CLAUDE_CODE_SUBAGENT_MODEL=claude-haiku-5-5"
  [ "$(cat "$WORK/env" 2>/dev/null)" = "$want" ] || st_fail "J7BN $prof: the launch env" "$(cat "$WORK/env" 2>/dev/null)"
  case "$argv" in *--model*) st_fail "J7BN $prof: a --model reached claude" "$argv" ;; esac
  [ "$(printf '%s\n' "$argv" | tr ' ' '\n' | grep -c '^--settings=')" = 1 ] || st_fail "J7BN $prof: exactly one --settings" "$argv"
  sf=$(printf '%s\n' "$argv" | tr ' ' '\n' | sed -n 's/^--settings=//p')
  python3 -c 'import json,sys; mo=json.load(open(sys.argv[1]))["modelOverrides"]; sys.exit(0 if mo=={"claude-opus-5-5":sys.argv[2],"claude-sonnet-5-5":sys.argv[2],"claude-haiku-5-5":"deepseek-flash"} else 1)' "$sf" "$w" \
    || st_fail "J7BN $prof: modelOverrides in the one --settings" "$(cat "$sf" 2>/dev/null)"
  has "$argv" "/fleet-history" || st_fail "J7BN $prof: the seed was lost" "$argv"
  grep -q -- '--provider deepseek' "$WORK/mintargs" && ! grep -q -- '--account' "$WORK/mintargs" \
    || st_fail "J7BN $prof: the mint did not ask for a deepseek pass" "$(cat "$WORK/mintargs" 2>/dev/null)"
  grep -q "@cc_model $p" "$WORK/tmuxlog" || st_fail "J7BN $prof: @cc_model not stamped $p" "$(cat "$WORK/tmuxlog")"
done
st_pass "J7BN FLEET_MODEL deepseek / deepseek-pro: proxy /deepseek base URL, the hub pass, DeepSeek tiers, no --model"
# …and on a FLEET_AGENT=codex fleet the profile still launches Claude Code, never
# fleet-codex.sh (a DeepSeek profile is Claude Code on DeepSeek's Anthropic API)
printf '#!/bin/sh\n: > "%s/codex-ran"\n' "$WORK" > "$WORK/bin/fleet-codex.sh"; chmod +x "$WORK/bin/fleet-codex.sh"
printf 'FLEET_AGENT="codex"\nFLEET_MODEL="deepseek"\n' > "$WORK/conf/fleets/f1/conf"
rm -f "$WORK/env" "$WORK/codex-ran"
argv="$( (export FLEET_CRED_SID=sid-ds; run /fleet-history) )"
[ ! -e "$WORK/codex-ran" ] && grep -q '^ANTHROPIC_BASE_URL=http://127.0.0.1:4321/deepseek$' "$WORK/env" 2>/dev/null \
  || st_fail "J7BN deepseek on a FLEET_AGENT=codex fleet must launch Claude Code" "codex-ran=$([ -e "$WORK/codex-ran" ] && echo yes || echo no) $(cat "$WORK/env" 2>/dev/null)"
rm -f "$WORK/bin/fleet-codex.sh" "$WORK/codex-ran"
st_pass "J7BN deepseek on a FLEET_AGENT=codex fleet: Claude Code, never fleet-codex.sh"
rm -f "$WORK/argv"
out=$(printf 'FLEET_MODEL="deepseek"\n' > "$WORK/conf/fleets/f1/conf"
      unset FLEET_CRED_SID FLEET_MODEL; bash "$WORK/bin/fleet-claude.sh" /fleet-history 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && [ ! -e "$WORK/argv" ] && [ "$(printf '%s\n' "$out" | grep -c 'only through the credential proxy')" = 1 ] \
  || st_fail "J7BN deepseek without the proxy must refuse with one line (rc=$rc)" "$out"
st_pass "J7BN deepseek without the credential proxy: refused, one line, claude never started"
rm -f "$WORK/bin/fleet-session-cred.sh"
printf 'FLEET_MODEL="fable"\n' > "$WORK/conf/fleets/f1/conf"
mv "$WORK/claude.before" "$WORK/fakebin/claude"

printf 'selftest OK: %s checks — the launcher reads the per-fleet conf, honours FLEET_MCP_CONFIG, and pre-trusts the checkout (issues #472, #473, #476, #563)\n' "$pass"
