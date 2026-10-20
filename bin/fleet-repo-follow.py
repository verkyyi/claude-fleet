#!/usr/bin/env python3
"""fleet-repo-follow.py — a managed machine hosts every repo its person's machines host
(claude-fleet T673, 节点选择 C).

  fleet-repo-follow.py tick   [--session <sess>]... [--force] [--dry-run]
  fleet-repo-follow.py status [--json | --doctor]

Placement only picks among the machines that host a session's repo, so a repo one
machine alone hosts has no second candidate. `tick` reads the person's set from the
hub (GET /v1/node/repos: the union of what the person's machines report, clients and
retired logins left out) and, when the hub types THIS login `managed`, runs
`fleet-repo.sh add <owner/repo>` for each one no fleet here hosts — into the first
fleet. It only ever ADDS: a `fleet-repo.sh remove` is this machine's own and is never
carried to another (a repo removed here comes back only while another machine of the
person still hosts it; take it off there too). A client, an untyped login, a login no
person owns, or no hub ⇒ nothing is added.

One add failing (a clone, a non-GitHub name the hub only knows as owner/name) is
written down with its reason and retried on a later round — the next round first,
then backing off to FLEET_REPO_FOLLOW_MAX_BACKOFF — and never stops the others.

It runs from the base-sync tick (bin/fleet-base-sync.sh, every 60 s) and reads the hub
at most once every FLEET_REPO_FOLLOW_SECS (600; --force reads now). Its record is
$FLEET_CONF_DIR/repo-follow.json, the one thing `status` and the doctor's `repos` /
`跟仓库` / `分到` rows read — the doctor never asks the hub itself.

Env: FLEET_REPO_FOLLOW=0 turns it off · FLEET_REPO_FOLLOW_SECS · FLEET_REPO_FOLLOW_ADD_SECS
(one add's timeout, 900) · FLEET_REPO_FOLLOW_MAX_BACKOFF (21600). Seams (selftest):
FLEET_REPO_FOLLOW_HUB_CMD (a command whose stdout is the hub's JSON) ·
FLEET_REPO_FOLLOW_ADD_CMD (replaces `bash fleet-repo.sh`).
Exit 0 always for tick (a daemon step); status exits 1 when there is no record.
"""
import argparse
import fcntl
import json
import os
import shlex
import subprocess
import sys
import time

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)


def conf_dir():
    return os.environ.get('FLEET_CONF_DIR') or os.path.expanduser('~/.config/claude-fleet')


def state_path():
    return os.path.join(conf_dir(), 'repo-follow.json')


def env_int(name, dflt):
    try:
        return int(os.environ.get(name) or dflt)
    except ValueError:
        return dflt


def load_state():
    try:
        with open(state_path()) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(d):
    p = state_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + '.tmp.%d' % os.getpid()
    with open(tmp, 'w') as f:
        json.dump(d, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write('\n')
    os.replace(tmp, p)


def log(msg):
    try:
        d = os.path.join(conf_dir(), 'logs')
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'repo-follow.log'), 'a') as f:
            f.write('%s %s\n' % (time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), msg))
    except OSError:
        pass


def hub_answer():
    """The hub's /v1/node/repos, or raises RuntimeError(why)."""
    cmd = os.environ.get('FLEET_REPO_FOLLOW_HUB_CMD')
    if cmd:
        p = subprocess.run(['bash', '-c', cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if p.returncode != 0:
            raise RuntimeError((p.stderr or 'hub seam failed').strip()[:200])
        try:
            return json.loads(p.stdout)
        except ValueError:
            raise RuntimeError('hub seam answered something that is not JSON')
    import fleet_hub_rest as hubrest
    try:
        return hubrest.api('GET', '/repos', root='/v1/node')
    except hubrest.Fail as e:
        raise RuntimeError(e.msg)


def fleet_sessions():
    base = os.path.join(conf_dir(), 'fleets')
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return []
    return [n for n in names if os.path.isfile(os.path.join(base, n, 'conf'))]


def hosted(sessions):
    """Every repo the given fleets host here (fleet_repos — the one reader)."""
    out = []
    for s in sessions:
        p = subprocess.run(['bash', '-c', '. "$1/fleet-lib.sh" >/dev/null 2>&1 && fleet_repos "$2"', '_', BIN, s],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        out += [r.strip() for r in (p.stdout or '').splitlines() if r.strip()]
    return out


def add_repo(sess, repo):
    """(ok, why) for one `fleet-repo.sh add`."""
    seam = os.environ.get('FLEET_REPO_FOLLOW_ADD_CMD')
    argv = shlex.split(seam) if seam else ['bash', os.path.join(BIN, 'fleet-repo.sh')]
    argv += ['add', '--session', sess, repo]
    env = dict(os.environ)
    env.pop('TMUX', None)
    env.pop('TMUX_PANE', None)
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, env=env, timeout=env_int('FLEET_REPO_FOLLOW_ADD_SECS', 900))
    except subprocess.TimeoutExpired:
        return False, 'timeout'
    except OSError as e:
        return False, str(e)
    tok = (p.stdout or '').strip().splitlines()
    tok = tok[-1] if tok else ''
    # refused:hosted = another road added it meanwhile: as good as added.
    if tok == 'refused:hosted' or (p.returncode == 0 and (tok.startswith('added:') or not tok)):
        return True, tok or 'added'
    err = [l for l in (p.stderr or '').strip().splitlines() if l.strip()]
    why = tok or ('rc %d' % p.returncode)
    if err:
        why += ' — ' + err[-1].strip()[:200]
    return False, why


def tick(a):
    if os.environ.get('FLEET_REPO_FOLLOW', '1') == '0':
        return 0
    os.makedirs(conf_dir(), exist_ok=True)
    lock = open(os.path.join(conf_dir(), '.repo-follow.lock'), 'a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # another round is adding — it will finish this one's work
    st = load_state()
    now = int(time.time())
    every = env_int('FLEET_REPO_FOLLOW_SECS', 600)
    if not a.force and not a.dry_run and now - int(st.get('checked') or 0) < every:
        return 0
    try:
        ans = hub_answer()
    except RuntimeError as e:
        st.update(checked=now, error=str(e))
        if not a.dry_run:
            save_state(st)
        log('hub: %s' % e)
        return 0
    st.pop('error', None)
    role = (ans.get('role') or '') if isinstance(ans, dict) else ''
    want = [r for r in (ans.get('repos') or []) if isinstance(r, str) and '/' in r] if isinstance(ans, dict) else []
    sessions = a.session or fleet_sessions()
    have = hosted(sessions)
    have_k = {r.lower() for r in have}
    missing = [r for r in want if r.lower() not in have_k]
    st.update(checked=now, role=role, owner=ans.get('owner') or '', want=want, have=have,
              machines=ans.get('machines') or [])
    failed = st.get('failed') if isinstance(st.get('failed'), dict) else {}
    # A repo no longer missing is no longer failing.
    failed = {k: v for k, v in failed.items() if k.lower() in {m.lower() for m in missing}}
    added = []
    if role != 'managed':
        st['note'] = 'not managed (role=%s) — nothing added' % (role or 'untyped')
    elif not ans.get('owner'):
        st['note'] = 'no person owns this login — nothing to follow'
    elif not sessions:
        st['note'] = 'no fleet on this login to add into'
    else:
        st.pop('note', None)
        cap = env_int('FLEET_REPO_FOLLOW_MAX_BACKOFF', 21600)
        for repo in missing:
            f = failed.get(repo) or {}
            if not a.force and now < int(f.get('next') or 0):
                continue
            if a.dry_run:
                print('would add %s → %s' % (repo, sessions[0]))
                continue
            ok, why = add_repo(sessions[0], repo)
            if ok:
                added.append(repo)
                failed.pop(repo, None)
                log('added %s → %s (%s)' % (repo, sessions[0], why))
            else:
                tries = int(f.get('tries') or 0) + 1
                wait = min(max(every, 60) * (2 ** (tries - 1)), cap) if tries > 1 else 0
                failed[repo] = dict(reason=why, at=now, tries=tries, next=now + wait)
                log('add %s failed (try %d): %s' % (repo, tries, why))
    if added:
        st['have'] = hosted(sessions)
        have_k = {r.lower() for r in st['have']}
    st['missing'] = [r for r in want if r.lower() not in have_k]
    st['failed'] = failed
    st['added'] = added
    if not a.dry_run:
        save_state(st)
    return 0


def ago(secs):
    secs = max(0, int(secs))
    if secs < 120:
        return '%ds' % secs
    if secs < 7200:
        return '%dm' % (secs // 60)
    return '%dh' % (secs // 3600)


def status(a):
    st = load_state()
    if not st:
        if not a.doctor:
            print('repo-follow: no record yet (%s)' % state_path(), file=sys.stderr)
        return 1
    if a.json:
        print(json.dumps(st, ensure_ascii=False, indent=1, sort_keys=True))
        return 0
    now = int(time.time())
    seen = ago(now - int(st.get('checked') or 0))
    rows = []
    missing, failed = st.get('missing') or [], st.get('failed') or {}
    if st.get('error') and not st.get('want'):
        rows.append(('info', '跟仓库', '没对上：读不到 hub（%s，%s 前）' % (st['error'], seen)))
    elif st.get('note'):
        rows.append(('info', '跟仓库', '不跟：%s（%s 前对过）' % (st['note'], seen)))
    elif missing:
        bad = ['%s — %s（第 %s 次）' % (r, failed[r].get('reason', '?'), failed[r].get('tries', 1))
               for r in missing if r in failed]
        txt = '缺 %d 个：%s' % (len(missing), ', '.join(missing))
        if bad:
            txt += '；没加上：' + '; '.join(bad) + '，之后会重试'
        rows.append(('warn', '跟仓库', txt + '（%s 前对过）' % seen))
    else:
        rows.append(('pass', '跟仓库', '齐：本人各台的 %d 个仓库这台都有（%s 前对过；只增不删）'
                     % (len(st.get('want') or []), seen)))
    ms = st.get('machines') or []
    if ms:
        parts = ['%s%s %d' % (m.get('hostname', '?'), '（本机）' if m.get('self') else '', int(m.get('starts_24h') or 0))
                 for m in ms]
        rows.append(('info', '分到', '近 24 小时 hub 分到各台的会话：' + ' · '.join(parts)))
    if a.doctor:
        for lv, name, txt in rows:
            print('%s\t%s\t%s' % (lv, name, txt))
        if missing and not st.get('note'):
            print('gap\t\t%s' % ', '.join(missing))
        return 0
    for lv, name, txt in rows:
        print('%-5s %-6s %s' % (lv.upper(), name, txt))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog='fleet-repo-follow.py')
    sub = ap.add_subparsers(dest='cmd')
    t = sub.add_parser('tick')
    t.add_argument('--session', action='append', default=[])
    t.add_argument('--force', action='store_true')
    t.add_argument('--dry-run', action='store_true')
    s = sub.add_parser('status')
    s.add_argument('--json', action='store_true')
    s.add_argument('--doctor', action='store_true')
    a = ap.parse_args(argv)
    if a.cmd == 'tick':
        return tick(a)
    if a.cmd == 'status':
        return status(a)
    ap.print_help(sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
