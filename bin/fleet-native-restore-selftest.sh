#!/bin/bash
# selftest-deps: fleet-restore.sh fleet_launch.py fleet-lib.sh .fleet-restore-resolve.py
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'SKIP: tmux unavailable'; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-restore.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
cleanup() {
  local result=$?
  if [ "$result" != 0 ]; then
    cat "$WORK/restore.log" "$WORK/refused.log" "$WORK/conf/fleets/native/restore.map" 2>/dev/null || true
  fi
  "$REAL_TMUX" -S "$WORK/tmux.sock" kill-server 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" SHELL=/bin/sh FLEET_SKIP_GLOBAL_CONF=1
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null PYTHONDONTWRITEBYTECODE=1
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
unset QUIET FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH FLEET_LAUNCH FLEET_DISPATCH FLEET_AUTHORITY_START
mkdir -p "$HOME" "$WORK/bin" "$WORK/shim" "$FLEET_CONF_DIR/fleets/native"
for source in "$BIN"/* "$BIN"/.[!.]*; do
  [ -f "$source" ] && ln -s "$source" "$WORK/bin/${source##*/}"
done
cat > "$WORK/shim/tmux" <<EOF
#!/bin/sh
exec '$REAL_TMUX' -S '$WORK/tmux.sock' "\$@"
EOF
chmod +x "$WORK/shim/tmux"
export PATH="$WORK/shim:$PATH"
rm "$WORK/bin/fleet-session-wrap.sh"
cat > "$WORK/bin/fleet-session-wrap.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$WORK/argv'
tmux display-message -p -t "\$TMUX_PANE" '#{@native_worktree}' > '$WORK/restored-intent'
printf '❯ \n'
exec sleep 120
EOF
chmod +x "$WORK/bin/fleet-session-wrap.sh"
PYTHONPATH="$BIN" python3 - "$WORK" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import fleet_launch as launch

root = Path(sys.argv[1])
repository = root / 'repository'
def git(*arguments):
    subprocess.run(['git', *map(str, arguments)], check=True, capture_output=True)
git('init', '-q', '-b', 'master', repository)
git('-C', repository, 'commit', '--allow-empty', '-qm', 'fixture')
intent = launch.new_native_worktree(str(repository), 'master')
worktree = launch.native_worktree_path(intent)
git('-C', repository, 'worktree', 'add', '-qb', 'worktree-' + intent['name'], worktree)
context = dict(version=1, operation_id='11111111-1111-4111-8111-111111111111', task='T1',
    owner='fixture|owner', generation=1, provider='claude', attempt_id='task:T1:g1',
    worker_id='22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333')
receipt = dict(context, actual_provider='claude', pid=123, birth='saved-fixture-process',
    executable='/fixture/claude', native_session='44444444-4444-4444-8444-444444444444',
    worktree=launch.worktree_identity(str(worktree)), native_worktree=intent, phase='ready')
(root / 'intent').write_text(json.dumps(intent))
(root / 'context').write_text(json.dumps(context))
(root / 'receipt').write_text(json.dumps(receipt))
(root / 'path').write_text(str(worktree))
(root / 'conf/native.conf').write_text(f'FLEET_REPO=acme/widgets\nFLEET_MAIN={repository}\nFLEET_BASE_BRANCH=master\n')
PY
tmux new-session -d -s native -n dash -c "$WORK/repository" 'sleep 120'
WINDOW=$(tmux new-window -d -P -F '#{window_id}' -t native -n saved -c "$(cat "$WORK/path")" 'sleep 120')
tmux set-option -w -t "$WINDOW" @fleet_id 33333333-3333-4333-8333-333333333333
tmux set-option -w -t "$WINDOW" @cc_session_id 44444444-4444-4444-8444-444444444444
tmux set-option -w -t "$WINDOW" @cc_agent claude
tmux set-option -w -t "$WINDOW" @raw 1
tmux set-option -w -t "$WINDOW" @repo acme/widgets
tmux set-option -w -t "$WINDOW" @worktree "$(cat "$WORK/path")"
tmux set-option -w -t "$WINDOW" @launch "$(cat "$WORK/context")"
tmux set-option -w -t "$WINDOW" @launch_receipt "$(cat "$WORK/receipt")"
tmux set-option -w -t "$WINDOW" @native_worktree "$(cat "$WORK/intent")"
bash "$WORK/bin/fleet-restore.sh" --snapshot
MAP="$FLEET_CONF_DIR/fleets/native/restore.map"
python3 - "$MAP" "$WORK/receipt" "$BIN/.fleet-restore-resolve.py" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
rows = [line.split('\t') for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith('LAUNCH\t')]
assert len(rows) == 1 and json.loads(rows[0][3]) == json.loads(Path(sys.argv[2]).read_text())
receipt = json.loads(rows[0][3])
directory = receipt['worktree']['root']
fleet_id = rows[0][1]
command = [sys.executable, sys.argv[3], receipt['native_worktree']['root'], '--fid', '--sid', '--lead']
def resolve(session, include_map=True):
    arguments = command + (['--launch-map', sys.argv[1]] if include_map else [])
    row = f'{fleet_id}|{session}|acme/widgets|saved|{directory}|-|done|-|-|1||claude\n'
    return subprocess.run(arguments, input=row, text=True, capture_output=True, check=True).stdout
assert receipt['native_session'] in resolve('')
assert 'WIN\t' not in resolve('55555555-5555-4555-8555-555555555555')
assert 'WIN\t' not in resolve('', include_map=False)
PY
tmux kill-window -t "$WINDOW"
FLEET_RESTORE_PROBE_SECS=2 bash "$WORK/bin/fleet-restore.sh" > "$WORK/restore.log"
cmp "$WORK/intent" <(tr -d '\n' < "$WORK/restored-intent")
grep -qx -- '--resume 44444444-4444-4444-8444-444444444444' "$WORK/argv"
[ "$(tmux display-message -p -t native:saved '#{@restore_outcome}')" = resumed ]
tmux kill-window -t native:saved
python3 - "$MAP" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
rows = [line.split('\t') for line in path.read_text().splitlines()]
for row in rows:
    if row[0] == 'WIN':
        row[3] = '55555555-5555-4555-8555-555555555555'
path.write_text('\n'.join('\t'.join(row) for row in rows) + '\n')
PY
FLEET_RESTORE_PROBE_SECS=2 bash "$WORK/bin/fleet-restore.sh" > "$WORK/refused.log" 2>&1
[ "$(wc -l < "$WORK/argv" | tr -d ' ')" = 1 ]
[ "$(tmux display-message -p -t native:saved '#{@restore_outcome}')" = failed ]
[ "$(tmux display-message -p -t native:saved '#{@native_worktree}')" = '' ]
echo 'PASS native restore: actual snapshot/restore, exact receipt, no duplicate state, mismatched session refuses before launch'
