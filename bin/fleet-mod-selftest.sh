#!/bin/bash
# fleet-mod-selftest.sh — the fleet mod's bash half (issue #1335, EPIC #1334).
#
# mod/fleet/ is a Claude Code plugin every fleet-launched Claude session loads
# (bin/fleet-claude.sh adds `--plugin-dir=<install>/mod/fleet`). Three rails:
#
#   A  FLEET_MOD=0 leaves the launch argv BYTE FOR BYTE what it was before the
#      mod existed — compared against the same launcher in a sandbox with no
#      plugin folder at all (the pre-#1335 install), with and without a seed
#      prompt, model and MCP flags in play. The degenerate case is sacred.
#   B  FLEET_MOD on (the default) adds exactly one `--plugin-dir=<dir>` and
#      nothing else; the =form keeps the seed prompt a positional (#476). No
#      plugin folder beside bin/ → nothing added either.
#   C  fleet_mod_alive <win>: a fresh beat (≤45s) is alive; stale, missing,
#      non-numeric, or FLEET_MOD=0 is not; FLEET_MOD_ALIVE_SECS moves the line.
#   D  the plugin itself: `claude plugin validate` + `claude plugin test` on
#      mod/fleet — SKIPPED, with the reason printed, where no `claude` CLI is on
#      PATH (CI). The plugin tests hold the version gate: out of range nothing
#      past the gate registers (mod/fleet/tests/lifecycle.test.ts); the
#      command inbox (#1337): a posted /compact reaches command.run and is
#      answered done, and the poll outlives a /clear (tests/inbox.test.ts); the
#      session reports its own state (tests/state.test.ts, issue #1336); and the
#      measurement bus is fed from inside the session — context + rate limits
#      off session.measure, model + effort off turn.step, a /model off the model
#      poll — all through conf/statusline.sh --from mod (tests/usage.test.ts,
#      issues #1338 / #1459).
#   E  the three tools are the FALLBACK only, with ONE implementation (issue
#      #2057; retired as the primary road in #1812): lifecycle registers them
#      only when FLEET_MCP_SERVER is not 1 (a session launched before the tool
#      service was mounted), from `fleet-mcp.py --spec`; tools.ts forwards every
#      call to `fleet-mcp.py --call` and carries no schema, no argument check
#      and no script of its own; `--spec status spawn await` answers with the
#      service's three closed schemas; register.ts wires every feature — static
#      + the python CLI, so it runs in CI where D cannot.
#
# Hermetic for A-C: a temp bin with the real launcher + lib symlinked, fake
# `claude` / `tmux` / `fleet-account.sh` on PATH, no tmux server touched.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SUT="$BIN/fleet-claude.sh"
LIB="$BIN/fleet-lib.sh"
MOD="$BIN/../mod/fleet"
for f in "$SUT" "$LIB" "$MOD/.claude-plugin/plugin.json"; do
  [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-mod.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# Two sandboxes: OLD has no mod/ (a pre-#1335 install), NEW has one beside bin/.
for box in old new; do
  mkdir -p "$WORK/$box/bin" "$WORK/$box/conf/fleets/f1"
  ln -s "$SUT" "$WORK/$box/bin/fleet-claude.sh"
  ln -s "$LIB" "$WORK/$box/bin/fleet-lib.sh"
  printf '#!/bin/sh\nexit 0\n' > "$WORK/$box/bin/fleet-account.sh"; chmod +x "$WORK/$box/bin/fleet-account.sh"
  printf 'FLEET_MODEL="opus"\n' > "$WORK/$box/fleet.conf"
done
mkdir -p "$WORK/new/mod/fleet/.claude-plugin"
printf '{"name":"fleet"}\n' > "$WORK/new/mod/fleet/.claude-plugin/plugin.json"
NEWMOD="$(cd "$WORK/new/mod/fleet" && pwd)"

mkdir -p "$WORK/fakebin"
# fake `claude`: one bracketed line per argv word, so a byte compare sees every word.
cat > "$WORK/fakebin/claude" <<EOF
#!/bin/sh
for a in "\$@"; do printf '[%s]\n' "\$a"; done > "$WORK/argv"
EOF
# fake `tmux`: display-message answers the session (f1) or the @mod_alive file.
cat > "$WORK/fakebin/tmux" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    '#{@mod_alive}') cat "$WORK/alive" 2>/dev/null; exit 0 ;;
  esac
done
case "\$1" in display-message) printf 'f1\n' ;; esac
exit 0
EOF
chmod +x "$WORK/fakebin/claude" "$WORK/fakebin/tmux"

launch() {   # launch <box> [VAR=val …] -- [launcher args …] → the argv lines
  local box="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -f "$WORK/argv"
  # shellcheck disable=SC2046  # word-split on purpose: one variable name per word
  ( unset $(env | sed -n 's/^\(FLEET_[A-Za-z0-9_]*\)=.*/\1/p') CLAUDE_CODE_SUBAGENT_MODEL TMUX
    export PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/$box/conf" TMUX_PANE="%0" FLEET_PRETRUST=0
    export ${envs[@]+"${envs[@]}"}
    bash "$WORK/$box/bin/fleet-claude.sh" "$@" ) >/dev/null 2>&1
  cat "$WORK/argv" 2>/dev/null
}

# --- A: FLEET_MOD=0 ≡ the pre-mod launch, byte for byte ------------------------
for args in '' '/fleet-claim' '--model haiku' ; do
  # shellcheck disable=SC2086  # word-split on purpose: each case is a small argv
  old=$(launch old -- $args)
  # shellcheck disable=SC2086
  new0=$(launch new FLEET_MOD=0 -- $args)
  [ -n "$old" ] || fail "A: the launcher produced no argv for '$args'"
  [ "$old" = "$new0" ] || fail "A: FLEET_MOD=0 changed the argv for '$args'" "$(printf 'old:\n%s\nnew:\n%s' "$old" "$new0")"
done
printf 'FLEET_MODEL="opus"\nFLEET_MCP_CONFIG="none"\n' > "$WORK/old/conf/fleets/f1/conf"
cp "$WORK/old/conf/fleets/f1/conf" "$WORK/new/conf/fleets/f1/conf"
old=$(launch old -- '/fleet-claim')
new0=$(launch new FLEET_MOD=0 -- '/fleet-claim')
[ "$old" = "$new0" ] || fail "A: FLEET_MOD=0 changed the argv with an MCP flag in play" "$(printf 'old:\n%s\nnew:\n%s' "$old" "$new0")"
ok "A FLEET_MOD=0: argv byte-identical to a pre-mod install (bare, seed prompt, --model, MCP)"

# --- B: on by default, exactly one --plugin-dir=… ------------------------------
on=$(launch new -- '/fleet-claim')
want=$(printf '%s\n' "$old" | awk -v m="[--plugin-dir=$NEWMOD]" '$0 == "[/fleet-claim]" { print m } { print }')
[ "$on" = "$want" ] || fail "B: the default launch is not the old argv + one --plugin-dir before the prompt" "$(printf 'want:\n%s\ngot:\n%s' "$want" "$on")"
[ "$(printf '%s\n' "$on" | tail -1)" = '[/fleet-claim]' ] || fail "B: the seed prompt is no longer the last positional" "$on"
on1=$(launch new FLEET_MOD=1 -- '/fleet-claim')
[ "$on1" = "$on" ] || fail "B: FLEET_MOD=1 differs from the default" "$on1"
ok "B FLEET_MOD on (default): exactly one --plugin-dir=<install>/mod/fleet, seed prompt kept last"

nomod=$(launch old FLEET_MOD=1 -- '/fleet-claim')
[ "$nomod" = "$old" ] || fail "B: no plugin folder beside bin/ must add nothing" "$nomod"
ok "B no mod/fleet beside bin/ (pre-#1335 install): nothing added even with FLEET_MOD=1"

# --- C: fleet_mod_alive ---------------------------------------------------------
alive() {   # alive [VAR=val …] → 0/1 from fleet_mod_alive @1
  # shellcheck disable=SC2046  # word-split on purpose: one variable name per word
  ( unset $(env | sed -n 's/^\(FLEET_[A-Za-z0-9_]*\)=.*/\1/p')
    export PATH="$WORK/fakebin:$PATH" TMUX="/tmp/fake,1,0"
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck source=/dev/null
    . "$LIB" >/dev/null 2>&1
    fleet_mod_alive @1 ) >/dev/null 2>&1
}
now=$(date +%s)
printf '%s\n' "$((now - 5))" > "$WORK/alive";  alive || fail "C: a 5s-old beat must be alive"
printf '%s\n' "$((now + 3))" > "$WORK/alive";  alive || fail "C: a beat 3s ahead (clock skew) must be alive"
printf '%s\n' "$((now - 100))" > "$WORK/alive"; alive && fail "C: a 100s-old beat must be stale"
: > "$WORK/alive";                             alive && fail "C: a missing beat must not be alive"
printf 'abc\n' > "$WORK/alive";                alive && fail "C: a non-numeric beat must not be alive"
printf '%s\n' "$((now - 5))" > "$WORK/alive";  alive FLEET_MOD=0 && fail "C: FLEET_MOD=0 must read every beat as not alive"
printf '%s\n' "$((now - 60))" > "$WORK/alive"; alive && fail "C: a 60s-old beat is past the 45s default"
alive FLEET_MOD_ALIVE_SECS=90 || fail "C: FLEET_MOD_ALIVE_SECS=90 must make a 60s-old beat alive"
( unset FLEET_MOD; . "$LIB" >/dev/null 2>&1; fleet_mod_alive '' ) && fail "C: no window must be not alive"
ok "C fleet_mod_alive: fresh/skewed alive; stale/missing/garbage/FLEET_MOD=0 not; knob honoured"

# --- D: the plugin's own checks (claude CLI only) --------------------------------
if ! command -v claude >/dev/null 2>&1; then
  printf 'skip D: no claude CLI on PATH (CI) — run `claude plugin validate mod/fleet && claude plugin test mod/fleet` locally\n'
else
  v=$(claude plugin validate "$MOD" 2>&1) || fail "D: claude plugin validate mod/fleet failed" "$v"
  case "$v" in *'✘'*) fail "D: claude plugin validate reported an error" "$v" ;; esac
  t=$(claude plugin test "$MOD" 2>&1) || fail "D: claude plugin test mod/fleet failed" "$t"
  case "$t" in *'(fail)'*|*' 0 pass'*) fail "D: claude plugin test reported a failure" "$t" ;; esac
  case "$t" in *'out of range'*) : ;; *) fail "D: the out-of-range (no-register) test did not run" "$t" ;; esac
  case "$t" in *'outlives a /clear'*) : ;; *) fail "D: the command-inbox tests (#1337) did not run" "$t" ;; esac
  case "$t" in *'AskUserQuestion'*) : ;; *) fail "D: the state tests (#1336) did not run" "$t" ;; esac
  case "$t" in *'feeds conf/statusline.sh --from mod'*) : ;; *) fail "D: the measurement-bus feed tests (#1338/#1459) did not run" "$t" ;; esac
  case "$t" in *'a /model lands within one poll'*) : ;; *) fail "D: the model-poll test (#1459) did not run" "$t" ;; esac
  case "$t" in *'fallback tools (#2057)'*) : ;; *) fail "D: the fallback-tools lifecycle test (#2057) did not run" "$t" ;; esac
  case "$t" in *'forwards to fleet-mcp.py --call'*) : ;; *) fail "D: the fallback-tools forwarding tests (tests/tools.test.ts, #2057) did not run" "$t" ;; esac
  case "$t" in *'the first /exit is a hint'*) : ;; *) fail "D: the orchestrator exit-guard tests (tests/exit-guard.test.ts, #2584) did not run" "$t" ;; esac
  case "$t" in *'Enter files exactly once with spawn'*) : ;; *) fail "D: the quick-dispatch tests (tests/qd.test.tsx, #2618) did not run" "$t" ;; esac
  case "$t" in *'the next step folds them in'*) : ;; *) fail "D: the orchestrator queue tests (tests/queue.test.tsx, #2617) did not run" "$t" ;; esac
  ok "D claude plugin validate + test pass (out-of-range gate + command inbox + session state + bus feed + fallback tools + orchestrator exit guard + quick dispatch + orchestrator queue covered)"
fi

# --- E: the fallback tools — one implementation, in bin/fleet-mcp.py (issue #2057) ---
T="$MOD/hooks/tools.ts"
[ -e "$T" ] || fail "E: mod/fleet/hooks/tools.ts missing — a session without the tool service (launched before #1828) needs the mod's fleet_status/spawn/await fallback (#2057)"
# The gate: lifecycle registers only when the launcher did not mount the service.
grep -q "env.get('FLEET_MCP_SERVER')) !== '1') await registerFallbackTools" "$MOD/hooks/lifecycle.ts" \
  || fail "E: lifecycle.ts no longer gates the fallback registration on FLEET_MCP_SERVER != 1"
# The two roads to the service — and nothing else: no schema, no argument check, no script named as a command.
grep -q -- "'--spec'" "$T" && grep -q -- "'--call'" "$T" || fail "E: tools.ts does not go through fleet-mcp.py --spec / --call"
[ "$(grep -cE '\$\.process\.run\(' "$T")" = 1 ] && grep -qE '\$\.process\.run\(callArgv\(' "$T" \
  || fail "E: tools.ts runs something other than fleet-mcp.py --call" "$(grep -nE '\$\.process\.run\(' "$T")"
hits=$(grep -nE 'inputSchema: \{|required: \[|checkArgs|parseRepoList|dash-issue-session\.sh|fleet-await\.sh|fleet-children\.sh' "$T" \
       | grep -vE '^[0-9]+:[[:space:]]*//' | grep -vE "<N>|'fleet-children\.sh'$")
[ -z "$hits" ] || fail "E: tools.ts carries a schema, an argument check or a script of its own — the service has the one copy" "$hits"
# --spec: the service's three, closed, in the fallback's order (python3 is what the mod runs).
spec=$(python3 "$BIN/fleet-mcp.py" --spec status spawn await 2>&1) || fail "E: fleet-mcp.py --spec status spawn await failed" "$spec"
printf '%s' "$spec" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert [r["name"] for r in rows] == ["status", "spawn", "await"], rows
for r in rows:
    assert r["description"] and r["inputSchema"]["additionalProperties"] is False, r
assert set(rows[1]["inputSchema"]["required"]) == {"issue"} and "reap" in rows[1]["inputSchema"]["properties"], rows[1]
' || fail "E: --spec did not print the three closed schemas" "$spec"
python3 "$BIN/fleet-mcp.py" --spec status nope >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] || fail "E: --spec of an unknown tool exited $rc, want 2"
for f in Lifecycle Usage State Progress Compose Tools ExitGuard QuickDispatch Queue; do
  grep -q "^  register$f(on)\$" "$MOD/hooks/register.ts" || fail "E: register.ts no longer wires register$f"
done
ok "E fallback tools: registered only without the service, from --spec; every call forwarded to --call; no second copy of a schema, a check or a script"

printf 'fleet-mod-selftest: %d passed\n' "$pass"
