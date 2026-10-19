#!/bin/bash
# Hermetic #4464 regression: run the production bound-issue gate of
# bin/fleet-cleanup.sh (issue_open_gate) against a fake forge. No live tmux or writes.
# selftest-deps: bin/fleet-cleanup.sh bin/fleet-lib.sh
# Since issue #4898 there is no ticket store: an issue session's issue is read on
# GitHub (fleet_ticket_state); a task session (issue #4897) is decided by its
# worktree's record T<n>, and no issue is read.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

bin_dir = Path(sys.argv[1])
# Exercise the actual gate in isolation; downstream destructive gates stay in
# fleet-cleanup-selftest.sh, which also checks their ordering and refusals.
source = (bin_dir / 'fleet-cleanup.sh').read_text()
gate = source[source.index('issue_open_gate() {'):].split('\n}\n', 1)[0] + '\n}\n'
with tempfile.TemporaryDirectory(prefix='cleanup-ticket-') as tmp:
    root = Path(tmp)
    conf = root / 'conf'
    repos = conf / 'fleets/fs/repos'
    repos.mkdir(parents=True)
    (conf / 'fs.conf').write_text('FLEET_SESSION=fs\n')
    (repos / 'acme-widgets.conf').write_text('FLEET_REPO=acme/widgets\n')
    (root / 'home').mkdir()
    (root / 'fake').mkdir()
    ghlog = root / 'gh.log'
    gh = root / 'fake/gh'
    gh.write_text('''#!/bin/bash
echo "$*" >> "$GHLOG"
[ "${GH_FAIL:-0}" != 1 ] || exit 1
printf '%s\\t\\t\\n' "${GH_STATE:-CLOSED}"
''')
    gh.chmod(0o755)
    tmux = root / 'fake/tmux'
    tmux.write_text('#!/bin/sh\nexit 1\n')
    tmux.chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('FLEET_', 'CCQUOTA_', 'TMUX', 'CF_'))}
    env.update(HOME=str(root / 'home'), FLEET_CONF_DIR=str(conf), FLEET_SESSION='fs',
               PATH=str(root / 'fake') + ':' + os.environ['PATH'], GHLOG=str(ghlog),
               BIN=str(bin_dir), WT=str(root), TMPDIR=tmp)
    harness = root / 'gate.sh'
    harness.write_text('''set -uo pipefail
. "$BIN/fleet-lib.sh"
AUTO=1; DRY=1; REPO=acme/widgets; ISSUE=42; BRANCH=issue-42; PR=99
WIN=${TEST_WIN:-}; href=${TEST_HEAD:-issue-42}; st=${TEST_PR_STATE:-MERGED}
closes=${TEST_CLOSES:-acme/widgets#42}
note() { echo "$*" >&2; }
done_token() { echo "$*"; }
''' + gate + '\nif issue_open_gate; then echo passed; fi\n')

    def run(name, expected='skip:issue-open', **extra):
        ghlog.write_text('')
        p = subprocess.run(['bash', str(harness)], env=dict(env, **extra), text=True, capture_output=True, timeout=15)
        assert p.returncode == 0 and p.stdout.strip() == expected, (name, p.returncode, p.stdout, p.stderr)
        print('ok', name)

    run('matching closing ref on a merged PR: the fast path, no read', expected='passed', GH_STATE='OPEN')
    assert not ghlog.read_text(), 'the fast path did an unnecessary read'
    run('OPEN + side-fix refuses', GH_STATE='OPEN', TEST_CLOSES='acme/widgets#43')
    run('CLOSED advances', expected='passed', TEST_CLOSES='acme/widgets#43')
    run('a merged PR is not a closed issue', GH_STATE='MERGED', TEST_CLOSES='acme/widgets#43')
    run('a read failure refuses', GH_FAIL='1', TEST_CLOSES='acme/widgets#43')
    run('an ambiguous branch refuses', TEST_HEAD='issue-42-sidefix')
    # A session that carries a hub task record (issue #4897): the worktree's
    # mark names T<n>, and the RECORD's word decides — the issue is never read.
    main = root / 'main'
    subprocess.run(['git', 'init', '-q', str(main)], check=True)
    subprocess.run(['git', '-C', str(main), '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'b',
                    '--allow-empty'], check=True)
    wt = root / 'main-issue-42'
    subprocess.run(['git', '-C', str(main), 'worktree', 'add', '-qb', 'issue-42', str(wt)], check=True)
    gitdir = subprocess.run(['git', '-C', str(wt), 'rev-parse', '--absolute-git-dir'], check=True,
                            text=True, capture_output=True).stdout.strip()
    Path(gitdir, 'fleet-task').write_text('T42\n')
    seam = root / 'task-closed'
    seam.write_text('#!/bin/sh\necho "$1" >> "$GHLOG.task"\ncase "$TASK_ANSWER" in 0) echo SUCCEEDED ;; 1) echo WAITING ;; esac\n'
                    'exit "$TASK_ANSWER"\n')
    seam.chmod(0o755)
    for answer, expected in (('0', 'passed'), ('1', 'skip:task-open'), ('3', 'skip:task-open')):
        run('task record answer %s decides, no issue read' % answer, expected=expected,
            WT=str(wt), FLEET_TASK_CLOSED_CMD=str(seam), TASK_ANSWER=answer)
        assert not ghlog.read_text(), ('a task session read its issue', ghlog.read_text())
        assert Path(str(ghlog) + '.task').read_text().split()[-1] == 'T42'
PY
