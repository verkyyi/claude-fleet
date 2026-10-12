#!/usr/bin/env python3
"""fleet_job.py — `fleet job`'s talk with the hub (issue #3552, EPIC #3500 C7).

bin/fleet-job.sh resolves the repo, the commit and this login's node pair, then
runs this with the pair on stdin (one line: <hub url> TAB <token> TAB <key file
or empty>) — never in argv:

  run    <repo> <ref> <kind> <cmd> <outdir> [--detach]
  status <job>
  logs   <job> <outdir> [--follow]

The hub answers POST /v1/node/jobs (the create, for this login's own pod) and
GET /v1/node/jobs/<job>?offset=N (its state and the next chunk of its log). The
log is the Job's one channel back (bin/fleet-job-runner.sh): the command's
output is printed as it comes, the marked block at its end is unpacked into
<outdir> (`.fleet-job/<job>/` in the worktree), and `::fleet-job:: exit N` is
the exit this returns.

Exit: the Job's own exit (run / logs --follow), 0 (status, a detached run) · 1
the hub refused or failed, or the Job failed without saying its exit · 2 usage.
Seams: FLEET_JOB_POLL (seconds between reads, 2), FLEET_HUB_CURL (curl).
"""
import base64
import io
import json
import os
import subprocess
import sys
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MARK = '::fleet-job:: '
DONE = ('succeeded', 'failed', 'gone')


def die(rc, msg):
    sys.stderr.write('fleet job: %s\n' % msg)
    sys.exit(rc)


class Hub:
    def __init__(self, url, token, key):
        self.url, self.token, self.key = url.rstrip('/'), token, key

    def auth(self, method, url):
        # signed once this login has a key (fleet_node_auth), else the token
        if self.key and os.path.isfile(self.key) and os.path.isfile(self.key + '.ok'):
            p = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'fleet_node_sig.py'), 'auth',
                                self.key, method, url], capture_output=True, text=True)
            if p.returncode == 0 and p.stdout.strip():
                return p.stdout.strip()
        return 'Bearer ' + self.token

    def call(self, method, path, body=None):
        url = self.url + path
        cfg = 'header = "Authorization: %s"\n' % self.auth(method, url)
        argv = [os.environ.get('FLEET_HUB_CURL') or 'curl', '-sS', '--max-time', '60', '-K', '-',
                '-o', '-', '-w', '\n%{http_code}', '-X', method, '-H', 'Content-Type: application/json']
        if body is not None:
            argv += ['--data-binary', json.dumps(body)]
        p = subprocess.run(argv + [url], input=cfg, capture_output=True, text=True)
        if p.returncode != 0 or not p.stdout:
            return 0, {'error': 'hub unreachable (curl exit %d)' % p.returncode}
        text, _, code = p.stdout.rpartition('\n')
        try:
            obj = json.loads(text) if text.strip() else {}
        except ValueError:
            obj = {'error': text.strip()[:200]}
        return int(code or 0), obj


class Log:
    """The Job's log as it arrives: printed, its artifact block unpacked."""

    def __init__(self, outdir):
        self.outdir, self.rest, self.block, self.exit = outdir, '', None, None

    def feed(self, text, final=False):
        self.rest += text
        lines = self.rest.split('\n')
        self.rest = '' if final else lines.pop()
        for ln in lines:
            self.line(ln)

    def line(self, ln):
        if self.block is not None:
            if ln == MARK + 'artifacts-end':
                self.unpack(''.join(self.block))
                self.block = None
            else:
                self.block.append(ln)
            return
        if ln.startswith(MARK + 'artifacts ') and ln[len(MARK) + 10:].strip().isdigit():
            self.block = []
            return
        if ln.startswith(MARK + 'exit '):
            try:
                self.exit = int(ln[len(MARK) + 5:].strip())
            except ValueError:
                pass
        sys.stdout.write(ln + '\n')
        sys.stdout.flush()

    def unpack(self, b64):
        os.makedirs(self.outdir, exist_ok=True)
        try:
            with tarfile.open(fileobj=io.BytesIO(base64.b64decode(b64)), mode='r:gz') as t:
                for m in t.getmembers():
                    # only plain files and dirs, never out of outdir
                    name = os.path.normpath(m.name)
                    if name.startswith(('/', '..')) or not (m.isfile() or m.isdir()):
                        continue
                    t.extract(m, self.outdir)
            sys.stderr.write('fleet job: outputs → %s\n' % self.outdir)
        except (ValueError, tarfile.TarError, OSError) as e:
            sys.stderr.write('fleet job: outputs could not be unpacked: %s\n' % e)


def follow(hub, job, outdir, wait=True):
    """Print the Job's log from its start; with wait, until it has ended."""
    log, off, state, o = Log(outdir), 0, '', {}
    poll = float(os.environ.get('FLEET_JOB_POLL') or 2)
    misses = 0
    while True:
        code, o = hub.call('GET', '/v1/node/jobs/%s?offset=%d' % (job, off))
        if code != 200:
            misses += 1
            if code in (0, 502, 503) and misses < 10:
                time.sleep(poll)
                continue
            die(1, '%s: %s (HTTP %d)' % (job, o.get('error') or o, code))
        misses = 0
        state = o.get('state', '')
        chunk = o.get('log') or ''
        log.feed(chunk)
        off = int(o.get('offset') or off)
        if not chunk and (state in DONE or not wait):
            break
        if not chunk:
            time.sleep(poll)
    log.feed('', final=True)
    reason = (' (%s)' % o['reason']) if o.get('reason') else ''
    sys.stderr.write('fleet job: %s %s%s\n' % (job, state, reason))
    if log.exit is not None:
        return log.exit
    return 0 if state == 'succeeded' else 1


def main(argv):
    if not argv:
        die(2, 'usage: fleet_job.py run|status|logs … (see the header)')
    url, _, rest = sys.stdin.readline().rstrip('\n').partition('\t')
    token, _, key = rest.partition('\t')
    if not url or not token:
        die(1, 'no node token here')
    hub = Hub(url, token, key)
    cmd, args = argv[0], argv[1:]
    if cmd == 'run' and len(args) >= 5:
        repo, ref, kind, line, outdir = args[:5]
        code, o = hub.call('POST', '/v1/node/jobs', {'repo': repo, 'ref': ref, 'kind': kind, 'cmd': line})
        if code != 200:
            die(1, 'the hub refused (HTTP %d): %s' % (code, o.get('error') or o))
        job = o['job']
        sys.stderr.write('fleet job: %s · %s · %s@%s on %s\n' % (job, kind, repo, ref[:12], o.get('cluster', '?')))
        if '--detach' in args[5:]:
            print(job)
            return 0
        return follow(hub, job, os.path.join(outdir, job))
    if cmd == 'status' and len(args) == 1:
        code, o = hub.call('GET', '/v1/node/jobs/%s' % args[0])
        if code != 200:
            die(1, '%s: %s (HTTP %d)' % (args[0], o.get('error') or o, code))
        print('%s %s%s' % (args[0], o.get('state', '?'), (' (%s)' % o['reason']) if o.get('reason') else ''))
        return 0
    if cmd == 'logs' and len(args) >= 2:
        rc = follow(hub, args[0], os.path.join(args[1], args[0]), wait='--follow' in args[2:])
        return rc if '--follow' in args[2:] else 0
    die(2, 'usage: fleet_job.py run|status|logs … (see the header)')


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
