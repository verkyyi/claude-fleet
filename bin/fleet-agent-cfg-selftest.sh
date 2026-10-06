#!/bin/bash
# fleet-agent-cfg-selftest.sh — a session's configuration is fixed at launch and
# fingerprinted (issue #1782, EPIC #1776 C6).
#
# bin/fleet-claude.sh / bin/fleet-codex.sh ask bin/fleet-agent-team.py `session`
# to compose fleet default < team < local at the moment of the launch, hand what
# the login's files lack (--settings / --mcp-config files for Claude, -c values
# for Codex) and stamp the fingerprint as @agent_cfg (+ @agent_cfg_src). Pinned:
#
#   A  same configuration, two launches → the same @agent_cfg; it equals
#      `expected`, and `expected --write` caches exactly those lines
#   B  a team-layer change (a new cached bundle) → a different fingerprint, and
#      @agent_cfg_src names the team version
#   C  hand only what is missing: a fresh login gets the fleet hooks + defaults in
#      one --settings file and the default servers in one --mcp-config file; a
#      login that already has them gets neither flag; a key the PROJECT sets is
#      never filled (--settings outranks it); a FLEET_MCP_CONFIG allowlist → no
#      --mcp-config from here
#   D  a LOCKED item the login overrides (its own `github` server): warn (the
#      default) uses it, names it on stderr and in `check` (exit 1); enforce hands
#      the fleet's definition and the fingerprint follows; an UNLOCKED override
#      (context7) is just the login's, silently. FLEET_MOD=0 + enforce → the mod
#      loads anyway
#   E  Codex: the launch stamps @agent_cfg too (mod = na) and hands a missing key
#      as `-c`; it equals `expected`'s codex line
#   F  degenerate: FLEET_AGENT_CFG=0, or no composer beside bin/ → the argv is
#      byte for byte the launch of before, and nothing is stamped
#
# Hermetic: a temp install root (bin/ symlinks + the real conf/ + hooks/), a temp
# HOME and FLEET_CONF_DIR, fake `claude` / `codex` / `tmux` on PATH.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
for f in fleet-claude.sh fleet-codex.sh fleet-lib.sh fleet-agent-team.py fleet-agent-defaults.py fleet-hooks-merge.py; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s missing\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo 'selftest: SKIP — no python3'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-agentcfg.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# Two install roots: NEW carries the composer, OLD does not (a pre-#1782 install).
for box in new old; do
  mkdir -p "$WORK/$box/bin" "$WORK/$box/conf" "$WORK/$box/mod/fleet/.claude-plugin"
  for f in fleet-claude.sh fleet-codex.sh fleet-lib.sh; do ln -s "$BIN/$f" "$WORK/$box/bin/$f"; done
  printf '#!/bin/sh\nexit 0\n' > "$WORK/$box/bin/fleet-account.sh"; chmod +x "$WORK/$box/bin/fleet-account.sh"
  printf '{"name":"fleet","version":"9.9.9"}\n' > "$WORK/$box/mod/fleet/.claude-plugin/plugin.json"
  ln -s "$ROOT/hooks" "$WORK/$box/hooks"
  for f in agent-defaults claude-settings.default.json agent-locked.list; do ln -s "$ROOT/conf/$f" "$WORK/$box/conf/$f"; done
  printf 'FLEET_MODEL="opus"\n' > "$WORK/$box/fleet.conf"
done
for f in fleet-agent-team.py fleet-agent-defaults.py fleet-hooks-merge.py; do ln -s "$BIN/$f" "$WORK/new/bin/$f"; done
TEAM="$WORK/new/bin/fleet-agent-team.py"

mkdir -p "$WORK/fakebin" "$WORK/proj"
cat > "$WORK/fakebin/claude" <<EOF
#!/bin/sh
for a in "\$@"; do printf '[%s]\n' "\$a"; done > "$WORK/argv"
EOF
cat > "$WORK/fakebin/codex" <<EOF
#!/bin/sh
for a in "\$@"; do printf '[%s]\n' "\$a"; done > "$WORK/argv"
EOF
# fake tmux: set-option -w -t <pane> <opt> <val> → one `<opt> <val>` line
cat > "$WORK/fakebin/tmux" <<EOF
#!/bin/sh
if [ "\$1" = set-option ]; then
  shift; while [ "\$#" -gt 2 ]; do shift; done
  printf '%s %s\n' "\$1" "\${2:-}" >> "$WORK/stamps"
fi
case "\$1" in display-message) printf 'f1\n' ;; esac
exit 0
EOF
chmod +x "$WORK/fakebin/claude" "$WORK/fakebin/codex" "$WORK/fakebin/tmux"

fresh_home() {   # a login: empty HOME, empty FLEET_CONF_DIR
  rm -rf "${WORK:?}/home" "${WORK:?}/cfg"; mkdir -p "$WORK/home/.claude" "$WORK/home/.codex" "$WORK/cfg"
}
launch() {   # launch <box> <agent-script> [VAR=val …] -- [args …] → argv lines; stamps in $WORK/stamps
  local box="$1" sut="$2"; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -f "$WORK/argv" "$WORK/stamps" "$WORK/err"
  # shellcheck disable=SC2046  # word-split on purpose: one variable name per word
  ( unset $(env | sed -n 's/^\(FLEET_[A-Za-z0-9_]*\)=.*/\1/p') CLAUDE_CODE_SUBAGENT_MODEL TMUX CLAUDE_CONFIG_DIR CODEX_HOME
    cd "$WORK/proj" || exit 2
    export PATH="$WORK/fakebin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/cfg" TMUX_PANE="%0" \
           FLEET_PRETRUST=0 FLEET_CODEX_VERSION_CHECK=0 FLEET_CODEX_SERVER=0
    export ${envs[@]+"${envs[@]}"}
    bash "$WORK/$box/bin/$sut" "$@" ) >/dev/null 2>"$WORK/err"
  cat "$WORK/argv" 2>/dev/null
}
stamp() { sed -n "s/^$1 //p" "$WORK/stamps" 2>/dev/null | tail -1; }
flagfile() { printf '%s\n' "$1" | sed -n "s/^\[--$2=\(.*\)\]$/\1/p"; }
team() {   # team <args…> — the composer as the launcher runs it, in the test login
  ( unset FLEET_AGENT_LOCK FLEET_MOD CLAUDE_CONFIG_DIR CODEX_HOME
    cd "$WORK/proj" && HOME="$WORK/home" FLEET_CONF_DIR="$WORK/cfg" python3 "$TEAM" "$@" )
}

# --- A: stable fingerprint; equals expected ------------------------------------
fresh_home
launch new fleet-claude.sh -- '/fleet-claim' >/dev/null
fp1=$(stamp @agent_cfg); src1=$(stamp @agent_cfg_src)
printf '%s' "$fp1" | grep -Eq '^[0-9a-f]{12}$' || fail "A: @agent_cfg is not 12 hex" "$(cat "$WORK/stamps" "$WORK/err" 2>/dev/null)"
launch new fleet-claude.sh -- '/fleet-claim' >/dev/null
[ "$(stamp @agent_cfg)" = "$fp1" ] || fail "A: two launches of one configuration differ" "$fp1 vs $(stamp @agent_cfg)"
exp=$(team expected --write --root "$WORK/new")
[ "$(printf '%s\n' "$exp" | awk '$1=="claude"{print $2}')" = "$fp1" ] || fail "A: expected ≠ the launch's fingerprint" "$exp / $fp1"
[ "$(cat "$WORK/cfg/global/agent-cfg.expected")" = "$exp" ] || fail "A: expected --write did not cache what it printed"
case "$src1" in "default:"*" team:none local:0 lock:warn") : ;; *) fail "A: @agent_cfg_src shape" "$src1" ;; esac
ok "A same configuration → same @agent_cfg ($fp1), = expected, cached by --write"

# --- B: a team change moves the fingerprint ------------------------------------
printf '{"version":7,"bundle":{"claude_settings":{"cleanupPeriodDays":30}}}\n' > "$WORK/cfg/team-bundle.json"
launch new fleet-claude.sh -- '/fleet-claim' >/dev/null
fp2=$(stamp @agent_cfg)
[ -n "$fp2" ] && [ "$fp2" != "$fp1" ] || fail "B: a team-layer change left the fingerprint at $fp1"
case "$(stamp @agent_cfg_src)" in *" team:v7 "*) : ;; *) fail "B: @agent_cfg_src does not name team v7" "$(stamp @agent_cfg_src)" ;; esac
printf '{"version":7,"bundle":{"claude_settings":{"cleanupPeriodDays":31}}}\n' > "$WORK/cfg/team-bundle.json"
launch new fleet-claude.sh -- '/fleet-claim' >/dev/null
[ "$(stamp @agent_cfg)" != "$fp2" ] || fail "B: a changed team VALUE left the fingerprint"
rm -f "$WORK/cfg/team-bundle.json"
ok "B a team-layer change → a new fingerprint; src names the team version"

# --- C: hand only what is missing ------------------------------------------------
fresh_home
argv=$(launch new fleet-claude.sh -- '/fleet-claim')
sf=$(flagfile "$argv" settings); mf=$(flagfile "$argv" mcp-config)
[ -f "$sf" ] && [ -f "$mf" ] || fail "C: a fresh login got no --settings / --mcp-config file" "$argv"
[ "$(printf '%s\n' "$argv" | tail -1)" = '[/fleet-claim]' ] || fail "C: the seed prompt is no longer last" "$argv"
python3 - "$sf" "$mf" "$ROOT" <<'PY' || fail "C: the handed files are not the fleet's table/defaults" "$(cat "$sf" "$mf")"
import json, sys
s, m, root = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
t = json.load(open(root + "/hooks/settings-hooks.json"))["hooks"]
n = lambda h: sum(len(g["hooks"]) for v in h.values() for g in v)
assert n(s["hooks"]) == n(t), (n(s["hooks"]), n(t))
assert s["permissions"]["defaultMode"] == "bypassPermissions"
assert set(m["mcpServers"]) == {"context7", "playwright", "github", "fetch"}, m
PY
# the login now HAS all of it (what a sync leaves): nothing handed, same fingerprint
python3 - "$sf" "$mf" "$WORK/home" <<'PY'
import json, sys
s, m, home = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
json.dump(s, open(home + "/.claude/settings.json", "w"))
json.dump({"mcpServers": m["mcpServers"]}, open(home + "/.claude.json", "w"))
PY
fpc=$(stamp @agent_cfg)
argv=$(launch new fleet-claude.sh -- '/fleet-claim')
case "$argv" in *'[--settings='*|*'[--mcp-config='*) fail "C: a login with everything still got a handed file" "$argv" ;; esac
[ "$(stamp @agent_cfg)" = "$fpc" ] || fail "C: filled-by-launch vs filled-by-sync fingerprint differ" "$fpc vs $(stamp @agent_cfg)"
# a project key: drop theme from the login, set it in the project → not filled
python3 - "$WORK/home/.claude/settings.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d.pop("theme"); json.dump(d, open(p, "w"))
PY
argv=$(launch new fleet-claude.sh -- '/fleet-claim'); sf=$(flagfile "$argv" settings)
grep -q '"theme"' "$sf" 2>/dev/null || fail "C: a key the login lacks was not filled" "$argv"
mkdir -p "$WORK/proj/.claude"; printf '{"theme":"dark"}\n' > "$WORK/proj/.claude/settings.json"
argv=$(launch new fleet-claude.sh -- '/fleet-claim')
case "$argv" in *'[--settings='*) fail "C: --settings filled a key the project sets" "$argv" ;; esac
rm -rf "$WORK/proj/.claude"
# an allowlist governs: no --mcp-config from the composer (only the allowlist's)
python3 - "$WORK/home/.claude.json" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["mcpServers"].pop("context7"); json.dump(d, open(p, "w"))
PY
argv=$(launch new fleet-claude.sh FLEET_MCP_CONFIG=none -- '/fleet-claim')
[ "$(printf '%s\n' "$argv" | grep -c '^\[--mcp-config=')" = 1 ] || fail "C: under an allowlist the composer added an --mcp-config" "$argv"
ok "C hands only what the login lacks (hooks/keys/servers); none when synced; never a project's key; allowlist governs"

# --- D: locks ------------------------------------------------------------------------
fresh_home
python3 - "$WORK/home/.claude.json" <<'PY'
import json, sys
json.dump({"mcpServers": {"github": {"type": "stdio", "command": "my-github", "args": []},
                          "context7": {"type": "stdio", "command": "my-c7", "args": []}}}, open(sys.argv[1], "w"))
PY
argv=$(launch new fleet-claude.sh -- '/fleet-claim'); fpw=$(stamp @agent_cfg)
grep -q 'claude.mcp.github used' "$WORK/err" || fail "D: warn did not name the overridden locked server" "$(cat "$WORK/err")"
grep -q 'context7' "$WORK/err" && fail "D: an UNLOCKED override was reported as a lock" "$(cat "$WORK/err")"
mf=$(flagfile "$argv" mcp-config)
python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["mcpServers"]; assert "github" not in m and "context7" not in m, m' "$mf" \
  || fail "D: warn handed a server the login has its own of" "$(cat "$mf")"
team check --root "$WORK/new" >/dev/null; [ $? = 1 ] || fail "D: check did not exit 1 on a locked override"
argv=$(launch new fleet-claude.sh FLEET_AGENT_LOCK=enforce -- '/fleet-claim'); fpe=$(stamp @agent_cfg)
grep -q 'claude.mcp.github ignored' "$WORK/err" || fail "D: enforce did not say it ignored the override" "$(cat "$WORK/err")"
mf=$(flagfile "$argv" mcp-config)
python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["mcpServers"]; assert "mcp-github.sh" in json.dumps(m["github"]) and "context7" not in m, m' "$mf" \
  || fail "D: enforce did not hand the fleet's github (or handed the unlocked context7)" "$(cat "$mf")"
[ "$fpe" != "$fpw" ] || fail "D: enforce and warn fingerprint alike although the effective github differs"
argv=$(launch new fleet-claude.sh FLEET_MOD=0 -- '/fleet-claim')
case "$argv" in *'[--plugin-dir='*) fail "D: warn + FLEET_MOD=0 still loaded the mod" "$argv" ;; esac
argv=$(launch new fleet-claude.sh FLEET_MOD=0 FLEET_AGENT_LOCK=enforce -- '/fleet-claim')
case "$argv" in *'[--plugin-dir='*) : ;; *) fail "D: enforce + FLEET_MOD=0 did not load the locked mod" "$argv" ;; esac
ok "D locked override: warn uses + names it (check exit 1), enforce hands the fleet's; mod lock honoured"

# --- E: Codex ---------------------------------------------------------------------------
fresh_home
printf 'approval_policy = "never"\n' > "$WORK/home/.codex/config.toml"
argv=$(launch new fleet-codex.sh FLEET_AGENT=codex -- 'hello')
fpx=$(stamp @agent_cfg)
printf '%s' "$fpx" | grep -Eq '^[0-9a-f]{12}$' || fail "E: the Codex launch stamped no @agent_cfg" "$(cat "$WORK/stamps" "$WORK/err" 2>/dev/null; printf '%s\n' "$argv")"
printf '%s\n' "$argv" | grep -qx '\[sandbox_mode="danger-full-access"\]' || fail "E: a missing Codex key was not handed as -c" "$argv"
printf '%s\n' "$argv" | grep -q '^\[approval_policy=' && fail "E: a key the login has was handed again" "$argv"
printf '%s\n' "$argv" | grep -q '^\[mcp_servers.github=' || fail "E: a missing Codex server was not handed" "$argv"
cx=$(team expected --root "$WORK/new" --codex-home "$WORK/home/.codex" | awk '$1=="codex"{print $2}')
[ "$cx" = "$fpx" ] || fail "E: the Codex launch ≠ expected's codex line" "$cx vs $fpx"
[ "$fpx" != "$fp1" ] || fail "E: Codex and Claude fingerprint alike"
team session codex --root "$WORK/new" --codex-home "$WORK/home/.codex" | grep -qx "$(printf 'mod\tna')" || fail "E: Codex mod is not na"
ok "E Codex launch stamps @agent_cfg ($fpx, mod=na), hands missing keys/servers as -c, = expected"

# --- F: degenerate --------------------------------------------------------------------
fresh_home
old=$(launch old fleet-claude.sh -- '/fleet-claim' | sed "s#/old/mod/fleet#/new/mod/fleet#")
[ -s "$WORK/stamps" ] && grep -q '^@agent_cfg' "$WORK/stamps" && fail "F: a composer-less install stamped @agent_cfg"
off=$(launch new fleet-claude.sh FLEET_AGENT_CFG=0 -- '/fleet-claim')
grep -q '^@agent_cfg' "$WORK/stamps" 2>/dev/null && fail "F: FLEET_AGENT_CFG=0 still stamped"
[ "$old" = "$off" ] || fail "F: FLEET_AGENT_CFG=0 changed the argv" "$(printf 'old:\n%s\noff:\n%s' "$old" "$off")"
oldx=$(launch old fleet-codex.sh FLEET_AGENT=codex -- 'hello' | sed "s#/old/mod/fleet#/new/mod/fleet#")
offx=$(launch new fleet-codex.sh FLEET_AGENT=codex FLEET_AGENT_CFG=0 -- 'hello')
[ "$oldx" = "$offx" ] || fail "F: FLEET_AGENT_CFG=0 changed the Codex argv" "$(printf 'old:\n%s\noff:\n%s' "$oldx" "$offx")"
ok "F FLEET_AGENT_CFG=0 / no composer: argv byte for byte the old launch, nothing stamped (Claude + Codex)"

printf 'fleet-agent-cfg-selftest: %d passed\n' "$pass"
