#!/bin/bash
# Account attribution must come from the live Claude process, never a stale stamp.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/collect-account.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fake" "$WORK/accounts" "$WORK/conf" "$WORK/cache"
for f in fleet-lib.sh usage-lib.sh fleet-account-truth.sh fleet-account-truth.py fleet-context.sh; do
  [ ! -f "$BIN/$f" ] || cp "$BIN/$f" "$WORK/bin/"
done
printf 'token-A\n' > "$WORK/accounts/acctA"
printf 'token-B\n' > "$WORK/accounts/acctB"
# Extract the real phase, without launching unrelated collector phases/daemons.
python3 - "$BIN/tmux-dash-collect.sh" "$WORK/phase.sh" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
f=re.search(r'^ph_banner\(\) \{\n.*?^\}',s,re.M|re.S)
assert f
open(sys.argv[2],'w').write(f.group(0)+'\n')
PY
cat > "$WORK/fake/tmux" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$TMLOG"
if [ "${1:-}" = -L ]; then [ "$2" = fixture ] || exit 1; shift 2; fi
case "$1" in
  list-windows)
    if [[ "$*" = *pane_pid* ]]; then
      printf '@1 %%1 101 acctB\n@2 %%2 102\n@3 %%3 103 acctB\n@4 %%4 104 acctB\n@5 %%5 105\n@6 %%6 106 acctB\n@7 %%7 107 acctA\n'
    else
      printf 'fixture:1\037@1\037acctB\nfixture:2\037@2\037\nfixture:3\037@3\037acctB\nfixture:4\037@4\037acctB\nfixture:5\037@5\037\n'
    fi ;;
  display-message)
    case "$*" in
      *session_name*) echo fixture ;;
      *pane_pid*) printf '@1 %%1 101\n' ;;
      *@ctx_pct*) echo 10 ;;
    esac ;;
  capture-pane) case "$*" in *'%6'*|*'%7'*) exit 0 ;; esac; printf 'Usage limit reached · continuing automatically at 1:50am · esc to cancel\n' ;;
  set-window-option) : ;;
  *) exit 1 ;;
esac
FAKE
cat > "$WORK/fake/ps" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$PSLOG"
case "$*" in
  *comm=*) printf '101 1 zsh\n201 101 claude\n102 1 zsh\n202 102 claude\n103 1 zsh\n203 103 codex\n104 1 zsh\n204 104 claude\n105 1 zsh\n205 105 claude\n106 1 zsh\n206 106 claude\n107 1 zsh\n207 107 claude\n' ;;
  *command=*) printf '101 zsh\n201 claude\n102 zsh\n202 claude\n103 zsh\n203 codex\n104 zsh\n204 claude\n105 zsh\n205 claude\n106 zsh\n206 claude\n107 zsh\n207 claude\n' ;;
esac
FAKE
cat > "$WORK/fake/token-probe" <<'FAKE'
#!/bin/sh
case "$1" in 201|206|207) echo token-A ;; 202|203) echo token-B ;; 204) echo unregistered-token ;; 205) exit 1 ;; esac
FAKE
cat > "$WORK/bin/fleet-account.sh" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$ACLOG"
exit 0
FAKE
chmod +x "$WORK/fake/"* "$WORK/bin/fleet-account.sh"
export PATH="$WORK/fake:$PATH" FLEET_ACCOUNTS_DIR="$WORK/accounts" FLEET_CONF_DIR="$WORK/conf"
export FLEET_TOKEN_PROBE="$WORK/fake/token-probe" TMPDIR="$WORK"
export TMLOG="$WORK/tmux.log" PSLOG="$WORK/ps.log" ACLOG="$WORK/account.log"
: > "$TMLOG"; : > "$PSLOG"; : > "$ACLOG"
(
  BIN="$WORK/bin"; . "$BIN/fleet-lib.sh"; . "$BIN/usage-lib.sh"
  . "$WORK/phase.sh"
  export SOCKETS=fixture US=$'\037' G="$WORK/cache"
  ph_banner
) > "$WORK/out" 2> "$WORK/err"
fail() { printf 'collect-account FAIL: %s\n' "$1" >&2; exit 1; }
grep -q '^mark-limited acctA ' "$ACLOG" || fail 'stale acctB stamp hid acctA token truth'
[ "$(wc -l < "$ACLOG" | tr -d ' ')" = 2 ] || fail 'unknown/non-Claude windows attributed, or unstamped window skipped'
grep -q '^mark-limited acctB ' "$ACLOG" || fail 'unstamped acctB process was not attributed'
grep -q -- '-L fixture set-window-option -t %1 @cc_account acctA' "$TMLOG" || fail 'stale stamp was not healed on its own socket/pane'
grep -q -- '-L fixture set-window-option -t %2 @cc_account acctB' "$TMLOG" || fail 'empty stamp was not healed'
grep -q -- '-L fixture set-window-option -t %6 @cc_account acctA' "$TMLOG" || fail 'quiet pane stamp was not healed'
! grep -q -- 'set-window-option -t %7' "$TMLOG" || fail 'correct stamp triggered redundant tmux write'
[ "$(wc -l < "$PSLOG" | tr -d ' ')" = 2 ] || fail 'process walk was not batched'
! grep -Eq 'token-A|token-B|unregistered-token' "$WORK/out" "$WORK/err" "$TMLOG" "$ACLOG" || fail 'token leaked to output'
# Context reports only verified identity, remains read-only, and keeps -q stable.
: > "$TMLOG"
out=$(TMUX=fake TMUX_PANE=%1 bash "$WORK/bin/fleet-context.sh" --json)
printf '%s' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["account"]=="acctA"' || fail 'context JSON lacks verified account'
out=$(TMUX=fake TMUX_PANE=%1 bash "$WORK/bin/fleet-context.sh")
case "$out" in *'account   acctA'*'process token'*) ;; *) fail 'context text lacks account provenance' ;; esac
! grep -q set-window-option "$TMLOG" || fail 'context query mutated a stamp'
out=$(TMUX=fake TMUX_PANE=%1 bash "$WORK/bin/fleet-context.sh" -q)
[ "$out" = OK ] || fail 'context quiet verdict changed'
# Exercise both production token readers; no host credentials are inspected.
python3 - "$BIN/fleet-account-truth.py" "$WORK/accounts" <<'PYTEST'
import importlib.util, os, pathlib, subprocess, sys
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('account_truth', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env = dict(os.environ); env.pop('FLEET_TOKEN_PROBE', None)
text = '@1 %1 101\n@2 %2 102\n@3 %3 103\n---PROCESSES---\n101 201\n102 202\n103 203\n'
raw = (b'201 claude CLAUDE_CODE_OAUTH_TOKEN=token-A PATH=/bin\n'
       b'202 node /app/claude-code/cli.js CLAUDE_CODE_OAUTH_TOKEN=token-B\n'
       b'203 claude CLAUDE_CODE_OAUTH_TOKEN=not-registered\n'
       b'999 claude CLAUDE_CODE_OAUTH_TOKEN=token-A\n')
with patch.dict(os.environ, env, clear=True), patch.object(m.sys, 'platform', 'darwin'):
    with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, raw)) as run:
        assert m.resolve(text, sys.argv[2]) == [('@1', '%1', 'acctA', '1'), ('@2', '%2', 'acctB', '1')]
        assert run.call_count == 1, 'macOS environment probe must be batched'
        assert run.call_args.args[0][-1] == '201,202,203'
    with patch.object(m.subprocess, 'run', side_effect=subprocess.TimeoutExpired('ps', 5)):
        assert m.resolve(text, sys.argv[2]) == [], 'timeout must not authorize attribution'
    with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, raw)):
        assert m.resolve(text, sys.argv[2]) == [], 'failed probe must not authorize attribution'
    def environ(path):
        if path == pathlib.Path('/proc/201/environ'):
            return b'PATH=/bin\0CLAUDE_CODE_OAUTH_TOKEN=token-A\0'
        raise PermissionError('unreadable')
    with patch.object(m.sys, 'platform', 'linux'), patch.object(m.Path, 'read_bytes', environ):
        assert m.resolve(text, sys.argv[2]) == [('@1', '%1', 'acctA', '1')]
# Ambiguous or excluded pool files must never invent a verified label.
root = pathlib.Path(sys.argv[2])
(root / 'duplicate').write_text('token-A\n')
(root / '.hidden').write_text('not-registered\n')
(root / 'metadata.conf').write_text('not-registered\n')
with patch.object(m, 'process_tokens', return_value={201:b'token-A',203:b'not-registered'}):
    assert m.resolve(text, root) == []
print('account truth: BSD batch / Linux environ / unknown, failure and duplicate cases passed')
PYTEST
[ "$?" = 0 ] || fail 'production token reader contracts failed'

printf 'fleet-collect-account-selftest: OK\n'
