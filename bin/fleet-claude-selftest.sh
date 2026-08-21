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
#          /fleet-claim` — while a raw ⌃s scratch, which passes NO positional, kept
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
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SUT="$BIN/fleet-claude.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$SUT" "$LIB"; do [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-claude.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- argv ---\n%s\n' "$2" >&2; exit 1; }

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
exit 0
EOF
chmod +x "$WORK/fakebin/claude"

# fake `tmux`: only display-message is used (fleet_current_session). The session it
# names is whatever \$SESS_FILE holds — empty file ⇒ "outside a fleet".
SESS_FILE="$WORK/sess"; printf 'f1' > "$SESS_FILE"
cat > "$WORK/fakebin/tmux" <<EOF
#!/bin/sh
case "\$1" in display-message) cat "$SESS_FILE" ;; *) : ;; esac
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
  ( unset FLEET_MODEL FLEET_SUBAGENT_MODEL FLEET_MCP_CONFIG CLAUDE_CODE_SUBAGENT_MODEL
    bash "$WORK/bin/fleet-claude.sh" "$@" ) >/dev/null 2>&1
  cat "$WORK/argv" 2>/dev/null
}
has()  { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# --- #472: the per-fleet conf overlays the global one ------------------------
printf 'FLEET_MODEL="fable"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
has "$argv" "--model fable" || fail "per-fleet FLEET_MODEL did not reach the launcher" "$argv"
ok "a per-fleet FLEET_MODEL overrides the global one (#472)"

# a second fleet gets ITS value, not the first one's
printf 'FLEET_MODEL="sonnet"\n' > "$WORK/conf/fleets/f2/conf"
printf 'f2' > "$SESS_FILE"
argv="$(run)"
has "$argv" "--model sonnet" || fail "the second fleet did not get its own model" "$argv"
ok "each fleet resolves its own conf"

# no per-fleet value → the global one still applies
: > "$WORK/conf/fleets/f2/conf"
argv="$(run)"
has "$argv" "--model opus" || fail "global FLEET_MODEL stopped applying" "$argv"
ok "an empty per-fleet conf falls through to the global value"

# outside a fleet (no session resolvable) → global only, no crash
: > "$SESS_FILE"
argv="$(run)"
has "$argv" "--model opus" || fail "no-session path broke the launch" "$argv"
ok "no resolvable session is a clean no-op, not a failure"
printf 'f1' > "$SESS_FILE"

# an explicit --model from the caller still wins
argv="$(run --model haiku)"
has "$argv" "--model haiku" || fail "caller --model was dropped" "$argv"
case "$argv" in *"--model fable"*) fail "the conf model was added ALONGSIDE the caller's" "$argv" ;; esac
ok "an explicit --model from the caller still wins"

# --- #473: FLEET_MCP_CONFIG ---------------------------------------------------
printf 'FLEET_MODEL="fable"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
case "$argv" in *--strict-mcp-config*|*--mcp-config*) fail "unset FLEET_MCP_CONFIG changed the argv" "$argv" ;; esac
ok "FLEET_MCP_CONFIG unset leaves the launch untouched (default is unchanged)"

printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="none"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
has "$argv" "--strict-mcp-config" || fail "FLEET_MCP_CONFIG=none did not pin MCP off" "$argv"
case "$argv" in *'{"mcpServers":{}}'*) : ;; *) fail "none did not expand to an empty server set" "$argv" ;; esac
ok "FLEET_MCP_CONFIG=none boots no MCP server at all"

printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG=%s\n' "'{\"mcpServers\":{\"playwright\":{\"command\":\"npx\"}}}'" > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
has "$argv" "--strict-mcp-config" || fail "an inline-JSON allowlist did not set --strict-mcp-config" "$argv"
case "$argv" in *'"playwright"'*) : ;; *) fail "the inline allowlist was not passed through" "$argv" ;; esac
ok "an inline-JSON allowlist passes through with --strict-mcp-config"

printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="%s/mcp.json"\n' "$WORK" > "$WORK/conf/fleets/f1/conf"
argv="$(run)"
has "$argv" "--mcp-config=$WORK/mcp.json" || fail "a file path was not passed through verbatim" "$argv"
ok "a file path passes through verbatim, in the =form (the CLI takes either value shape)"

# an explicit caller flag wins over the conf
printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="none"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run --mcp-config "$WORK/other.json")"
case "$argv" in *'{"mcpServers":{}}'*) fail "the conf overrode the caller's --mcp-config" "$argv" ;; esac
has "$argv" "--mcp-config $WORK/other.json" || fail "caller --mcp-config was dropped" "$argv"
ok "an explicit --mcp-config from the caller wins over the conf"

argv="$(run --strict-mcp-config)"
case "$argv" in *'{"mcpServers":{}}'*) fail "the conf added its own config despite --strict-mcp-config" "$argv" ;; esac
ok "an explicit --strict-mcp-config from the caller is left alone"

# --- #476: the seed prompt must survive, in EVERY config form ----------------
# `--mcp-config <v>` (separated) is variadic and ate the positional that follows —
# which is the seed prompt on every issue-bound spawn. Assert the prompt arrives
# intact, and that the flag is emitted in the =form that makes that structural.
SEED='/fleet-claim'
for cfg in none '{"mcpServers":{}}' "$WORK/mcp.json"; do
  printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG=%s\n' "'$cfg'" > "$WORK/conf/fleets/f1/conf"
  argv="$(run "$SEED")"
  has "$argv" "$SEED" || fail "the seed prompt was swallowed with FLEET_MCP_CONFIG=$cfg" "$argv"
  case "$argv" in
    *"--mcp-config="*) : ;;
    *) fail "--mcp-config must use the =form or it eats the positional (FLEET_MCP_CONFIG=$cfg)" "$argv" ;;
  esac
done
ok "the seed prompt survives every FLEET_MCP_CONFIG form (=form, not separated)"

# a multi-word prompt with spaces stays ONE argument
printf 'FLEET_MODEL="fable"\nFLEET_MCP_CONFIG="none"\n' > "$WORK/conf/fleets/f1/conf"
argv="$(run 'Work GitHub issue #2109 in this repo')"
case "$argv" in *"Work GitHub issue #2109 in this repo"*) : ;; *) fail "a multi-word prompt was mangled" "$argv" ;; esac
ok "a multi-word seed prompt passes through intact"

printf 'selftest OK: %s checks — the launcher reads the per-fleet conf and honours FLEET_MCP_CONFIG (issues #472, #473, #476)\n' "$pass"
