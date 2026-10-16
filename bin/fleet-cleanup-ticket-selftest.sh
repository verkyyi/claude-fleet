#!/bin/bash
# Hermetic #4464 regression: run the production bound-ticket gate through the
# real ticket door, with a loopback hub and a fake forge. No live tmux or writes.
# selftest-deps: bin/fleet-cleanup.sh bin/fleet-ticket.sh bin/fleet_ticket.py bin/fleet-lib.sh
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

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
    (root / 'home').mkdir()
    (root / 'fake').mkdir()
    ghlog = root / 'gh.log'
    gh = root / 'fake/gh'
    gh.write_text('''#!/bin/bash
echo "$*" >> "$GHLOG"
[ "${GH_FAIL:-0}" != 1 ] || exit 1
case "$*" in
  *'--jq .state'*) echo "${GH_STATE:-CLOSED}" ;;
  *) printf '{"id":"I_42","number":42,"url":"https://github.com/acme/widgets/issues/42","state":"%s"}\n' "${GH_STATE:-CLOSED}" ;;
esac
''')
    gh.chmod(0o755)
    tmux = root / 'fake/tmux'
    tmux.write_text('#!/bin/sh\nexit 1\n')
    tmux.chmod(0o755)
    response = {}
    requests = []

    class Hub(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            requests.append(self.path)
            raw = json.dumps(response.get('body', {})).encode()
            self.send_response(response.get('status', 200))
            self.end_headers()
            self.wfile.write(raw)

    server = HTTPServer(('127.0.0.1', 0), Hub)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    (conf / 'node.env').write_text(
        f'CCQUOTA_HUB_URL=http://127.0.0.1:{server.server_port}\nCCQUOTA_TOKEN=fixture\n')
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

    def run(name, home='hub', state='open', expected='skip:issue-open', ticket=None, status=200, **extra):
        (repos / 'acme-widgets.conf').write_text(f'FLEET_REPO=acme/widgets\nFLEET_TICKETS={home}\n')
        response.clear()
        response.update(status=status, body={'ticket': ticket if ticket is not None else {
            'id': 'hub:acme/widgets#42', 'repo': 'acme/widgets', 'number': 42, 'state': state}})
        requests.clear()
        ghlog.write_text('')
        p = subprocess.run(['bash', str(harness)], env=dict(env, **extra), text=True, capture_output=True, timeout=15)
        assert p.returncode == 0 and p.stdout.strip() == expected, (name, p.returncode, p.stdout, p.stderr)
        if home == 'hub':
            assert not ghlog.read_text(), (name, 'hub read fell through to gh', ghlog.read_text())
            assert all(x == '/v1/fleet/tickets/acme/widgets/42' for x in requests), (name, requests)
        print('ok', name)

    try:
        run('Hub OPEN + same-number merged forge closing ref stays open', GH_STATE='MERGED')
        run('Hub CLOSED + merged PR advances to later gates', state='closed', expected='passed')
        run('Hub OPEN + side-fix PR cannot finish current task', TEST_CLOSES='acme/widgets#43')
        run('Hub CLOSED + side-fix still needs authoritative completion', state='closed', TEST_CLOSES='acme/widgets#43', expected='passed')
        run('Hub MERGED is not a ticket terminal state', state='merged')
        run('missing ticket fails closed', ticket={})
        run('missing identity fails closed', ticket={'state': 'closed', 'number': 42})
        for key, value in [('id', 'gh:acme/widgets#42'), ('id', 'hub:other/repo#42'),
                           ('id', 'hub:acme/widgets#43'), ('number', 43)]:
            t = {'id': 'hub:acme/widgets#42', 'number': 42, 'state': 'closed'}
            t[key] = value
            run('mismatched ' + str((key, value)), ticket=t)
        run('hub unavailable has no forge fallback', status=503)
        run('unknown provider refuses even matching forge refs', home='typo')
        run('ambiguous branch refuses', state='closed', TEST_HEAD='issue-42-sidefix')
        run('GitHub matching closing refs preserve fast path', home='github', state='open', expected='passed', GH_STATE='OPEN')
        assert not ghlog.read_text(), 'GitHub fast path did an unnecessary read'
        run('GitHub OPEN + side-fix refuses', home='github', GH_STATE='OPEN', TEST_CLOSES='acme/widgets#43')
        run('GitHub CLOSED advances', home='github', expected='passed', TEST_CLOSES='acme/widgets#43')
        run('GitHub MERGED is a PR, not closed issue', home='github', GH_STATE='MERGED', TEST_CLOSES='acme/widgets#43')
        run('GitHub read failure refuses', home='github', GH_FAIL='1', TEST_CLOSES='acme/widgets#43')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
PY
