#!/bin/bash
# selftest-deps: fleet-restore.sh fleet_launch.py fleet_repo_authority.py fleet-lib.sh .fleet-restore-resolve.py
set -euo pipefail
case "${1:-}" in
  '') bash "$0" --accepted-task; bash "$0" --local-authority; exit ;;
  --accepted-task|--local-authority) MODE=$1 ;;
  *) exit 2 ;;
esac
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
export LANG=C LC_ALL=C
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
unset QUIET FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH FLEET_LAUNCH FLEET_DISPATCH FLEET_AUTHORITY_START
mkdir -p "$HOME" "$WORK/bin" "$WORK/shim" "$FLEET_CONF_DIR/fleets/native"
for source in "$BIN"/* "$BIN"/.[!.]*; do
  [ -f "$source" ] && ln -s "$source" "$WORK/bin/${source##*/}"
done
cat > "$WORK/shim/tmux" <<EOF
#!/bin/sh
if [ -f '$WORK/fail-capture' ]; then
  case "\$*" in *'F#{q:@fleet_id}'*) exit 9 ;; esac
fi
exec '$REAL_TMUX' -S '$WORK/tmux.sock' "\$@"
EOF
chmod +x "$WORK/shim/tmux"
export PATH="$WORK/shim:$PATH"
rm "$WORK/bin/fleet-session-wrap.sh"
cat > "$WORK/bin/fleet-session-wrap.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$WORK/argv'
tmux display-message -p -t "\$TMUX_PANE" '#{@native_worktree}' > '$WORK/restored-intent'
tmux display-message -p -t "\$TMUX_PANE" '#{@authority_receipt}' > '$WORK/restored-authority'
printf '❯ \n'
exec sleep 120
EOF
chmod +x "$WORK/bin/fleet-session-wrap.sh"
PYTHONPATH="$BIN" python3 - "$WORK" "$MODE" <<'PY'
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
if sys.argv[2] == '--local-authority':
    proof = {key: receipt[key] for key in ('worker_id', 'native_session', 'pid', 'birth', 'executable')}
    proof['birth'] = 'saved|fixture-process'
    receipt = dict(repo='acme/widgets', worker_id=context['worker_id'], supervisor=12,
                   reservation='66666666-6666-4666-8666-666666666666', native_identity=proof,
                   worktree=receipt['worktree'], native_worktree=intent)
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
if [ "$MODE" = --local-authority ]; then
  tmux set-option -w -t "$WINDOW" @authority_receipt "$(cat "$WORK/receipt")"
else
  tmux set-option -w -t "$WINDOW" @launch "$(cat "$WORK/context")"
  tmux set-option -w -t "$WINDOW" @launch_receipt "$(cat "$WORK/receipt")"
fi
tmux set-option -w -t "$WINDOW" @native_worktree "$(cat "$WORK/intent")"
bash "$WORK/bin/fleet-restore.sh" --snapshot
MAP="$FLEET_CONF_DIR/fleets/native/restore.map"
if [ "$MODE" = --local-authority ]; then
  : > "$FLEET_CONF_DIR/fleets/native/.snapshot-key"
  bash "$WORK/bin/fleet-restore.sh" --snapshot --if-changed
  python3 - "$WORK/receipt" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
receipt = json.loads(path.read_text())
receipt['reservation'] = '77777777-7777-4777-8777-777777777777'
path.write_text(json.dumps(receipt))
PY
  tmux set-option -w -t "$WINDOW" @authority_receipt "$(cat "$WORK/receipt")"
  bash "$WORK/bin/fleet-restore.sh" --snapshot --if-changed
fi
python3 - "$MAP" "$WORK/receipt" "$BIN/.fleet-restore-resolve.py" "$MODE" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
kind = 'AUTHORITY' if sys.argv[4] == '--local-authority' else 'LAUNCH'
rows = [line.split('\t') for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith(kind + '\t')]
assert len(rows) == 1 and json.loads(rows[0][-1]) == json.loads(Path(sys.argv[2]).read_text())
receipt = json.loads(rows[0][-1])
session_id = (receipt['native_identity'] if kind == 'AUTHORITY' else receipt)['native_session']
directory = receipt['worktree']['root']
fleet_id = rows[0][1]
command = [sys.executable, sys.argv[3], receipt['native_worktree']['root'], '--fid', '--sid', '--lead']
def resolve(session, include_map=True, repo='acme/widgets'):
    arguments = command + (['--launch-map', sys.argv[1]] if include_map else [])
    row = f'{fleet_id}|{session}|{repo}|saved|{directory}|-|done|-|-|1||claude\n'
    return subprocess.run(arguments, input=row, text=True, capture_output=True, check=True).stdout
assert session_id in resolve('')
assert 'WIN\t' not in resolve('55555555-5555-4555-8555-555555555555')
assert 'WIN\t' not in resolve('', include_map=False)
if kind == 'AUTHORITY':
    assert 'WIN\t' not in resolve('', repo='other/repo')
    mapping = Path(sys.argv[1])
    original = mapping.read_text()
    without = '\n'.join(line for line in original.splitlines() if not line.startswith('AUTHORITY\t')) + '\n'
    for broken in (original + '\t'.join(rows[0]) + '\n', without + f'AUTHORITY\t{fleet_id}\t{{}}\n',
                   without + f'AUTHORITY\t{fleet_id}\tinvalid-json\n', original + f'LAUNCH\t{fleet_id}\t{{}}\t{{}}\n'):
        mapping.write_text(broken)
        assert 'WIN\t' not in resolve(''), broken
    mapping.write_text(original)
PY
cp "$MAP" "$WORK/good-map"
python3 - "$BIN/.fleet-restore-resolve.py" "$WINDOW" <<'PY'
import json
import shlex
import subprocess
import sys

command = [sys.executable, sys.argv[1], '--snapshot-metadata']
fleet_id = '33333333-3333-4333-8333-333333333333'
sample = json.dumps({'value': 'pipe| quote\' " slash\\ newline\n tab\t 中文 $(false) `false` #{window_id}'})
subprocess.run(['tmux', 'set-option', '-w', '-t', sys.argv[2], '@fixture_metadata', sample], check=True)
encoded = subprocess.check_output(['tmux', 'display-message', '-p', '-t', sys.argv[2],
    'F' + fleet_id + ' L#{q:@fixture_metadata} R#{q:@fixture_metadata} A#{q:@fixture_metadata}'], text=True)
result = subprocess.run(command, input=encoded, capture_output=True, text=True, check=True)
assert result.stdout.splitlines() == ['\t'.join(('LAUNCH', fleet_id, sample, sample)),
                                    '\t'.join(('AUTHORITY', fleet_id, sample))]
empty = subprocess.run(command, input='F L R A\n', capture_output=True, text=True, check=True)
assert not empty.stdout
valid = shlex.join(('F' + fleet_id, 'L' + sample, 'R', 'A')) + '\n'
for broken in ('F L R\n', 'F L R A extra\n', 'F L R "A\n', 'F L{} R A\n',
               'F' + fleet_id + ' X{} R A\n', shlex.join(('F' + fleet_id, 'Lbad\trow', 'R', 'A')) + '\n'):
    result = subprocess.run(command, input=valid + broken, capture_output=True, text=True)
    assert result.returncode and not result.stdout, (broken, result)
PY
: > "$WORK/fail-capture"
if bash "$WORK/bin/fleet-restore.sh" --snapshot > "$WORK/capture-failed.log" 2>&1; then
  echo 'FAIL: metadata capture failure was accepted' >&2
  exit 1
fi
rm "$WORK/fail-capture"
cmp "$MAP" "$WORK/good-map"
tmux set-option -w -t "$WINDOW" @fleet_id invalid-identity
if bash "$WORK/bin/fleet-restore.sh" --snapshot > "$WORK/parse-failed.log" 2>&1; then
  echo 'FAIL: malformed metadata was accepted' >&2
  exit 1
fi
cmp "$MAP" "$WORK/good-map"
tmux set-option -w -t "$WINDOW" @fleet_id 33333333-3333-4333-8333-333333333333
tmux kill-window -t "$WINDOW"
FLEET_RESTORE_PROBE_SECS=2 bash "$WORK/bin/fleet-restore.sh" > "$WORK/restore.log"
cmp "$WORK/intent" <(tr -d '\n' < "$WORK/restored-intent")
grep -qx -- '--resume 44444444-4444-4444-8444-444444444444' "$WORK/argv"
if [ "$MODE" = --local-authority ]; then
  cmp "$WORK/receipt" <(tr -d '\n' < "$WORK/restored-authority")
  [ "$(tmux display-message -p -t native:saved '#{@launch}')" = '' ]
fi
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
if [ "$MODE" = --local-authority ]; then
  for invalid in empty missing-intent duplicate conflicting extra-field; do
    tmux kill-window -t native:saved
    python3 - "$WORK/good-map" "$MAP" "$invalid" <<'PY'
from pathlib import Path
import sys
rows = [line.split('\t') for line in Path(sys.argv[1]).read_text().splitlines()]
for row in rows:
    if row[0] != 'AUTHORITY':
        continue
    if sys.argv[3] == 'empty':
        row[2] = ''
    elif sys.argv[3] == 'missing-intent':
        row[2] = '{}'
    elif sys.argv[3] == 'duplicate':
        rows.append(row.copy())
    elif sys.argv[3] == 'extra-field':
        row.append('unexpected')
    else:
        rows.append(['LAUNCH', row[1], '', ''])
    break
Path(sys.argv[2]).write_text('\n'.join('\t'.join(row) for row in rows) + '\n')
PY
    FLEET_RESTORE_PROBE_SECS=2 bash "$WORK/bin/fleet-restore.sh" > "$WORK/refused.log" 2>&1
    [ "$(wc -l < "$WORK/argv" | tr -d ' ')" = 1 ]
    [ "$(tmux display-message -p -t native:saved '#{@restore_outcome}')" = failed ]
  done
fi
echo "PASS native restore $MODE: actual snapshot/restore, exact receipt, no duplicate state, mismatched session refuses before launch"
