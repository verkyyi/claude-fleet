#!/usr/bin/env python3
"""Bounded per-fleet reconciliation invoked by existing quotawatch/banner paths.

fleet-account owns policy; migrate/transfer own cutover. This keeps only durable
per-session attempts, separate from account-level once-per-reset notifications.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import subprocess
import sys
import time

BIN = Path(__file__).absolute().parent
ACCOUNT = runpy.run_path(str(BIN / '.fleet-account.py'))
INPUT = runpy.run_path(str(BIN / 'fleet-input.py'))
TRANSFER = runpy.run_path(str(BIN / '.fleet-transfer.py'))
RPC = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
save, read, locked = (ACCOUNT[n] for n in ('save', 'read', 'locked'))


def run(argv, timeout=15, **kwargs):
    return subprocess.check_output([str(x) for x in argv], timeout=timeout,
                                   stderr=subprocess.PIPE, text=True, **kwargs).strip()


def tm(session, *args):
    return run(['tmux', '-L', session, *args], timeout=5)


def opt(source, key):
    return tm(source['session'], 'display-message', '-p', '-t', source['pane'], '#{' + key + '}')


def stamp(source, status):
    tm(source['session'], 'set-option', '-w', '-t', source['window'], '@quota_failover', status)


def inspect(session, window):
    return json.loads(run(['bash', BIN / 'fleet-transfer.sh', '--session', session,
                          '--window', window, '--to', 'codex', '--inspect'], timeout=30))


def native_thread(source):
    data = source['codex_identity']
    rpc = RPC(data.get('remote', ''), timeout=5)
    try:
        t = rpc.call('thread/read', {'threadId': source['session_id'], 'includeTurns': True})['thread']
    finally:
        rpc.close()
    if (t['id'] != source['session_id'] or t.get('modelProvider') != 'openai'
            or Path(t['cwd']).resolve() != Path(source['worktree']).resolve()):
        raise ValueError('native Codex thread/provider changed')
    return t


def quota_error(thread):
    turns = thread.get('turns') or []
    last = turns[-1] if turns else {}
    return (thread.get('status', {}).get('type') in ('idle', 'systemError')
            and last.get('status') == 'failed'
            and (last.get('error') or {}).get('codexErrorInfo') == 'usageLimitExceeded')


def claude_banner(source):
    screen = tm(source['session'], 'capture-pane', '-p', '-t', source['pane'])
    # Restrict evidence to the current viewport; the bridge's canonical parser
    # distinguishes model caps and source-code strings from subscription walls.
    return run(['bash', '-c', '. "$1"; fleet_limit_banner | fleet_limit_kind',
                'fleet-limit', BIN / 'usage-lib.sh'], input=screen) == 'subscription'


def source_account(source, data):
    if source['agent'] == 'codex':
        binding = source['codex_identity'].get('subscription', {})
        matches = [r for r in data['accounts'] if r['agent'] == 'codex'
                   and r.get('home') == str(Path(source['home']).resolve())
                   and (not binding or r['account'] == binding.get('account'))]
        if len(matches) != 1:
            raise ValueError('source Codex profile/account is not uniquely registered')
        if not binding:
            # Existing sessions predate subscription stamps: verify native auth
            # against ccquota's metadata, without reassigning historical usage.
            expected = matches[0]
            with_env = json.dumps({k: expected[k] for k in ('account','profile','home')})
            old = os.environ.get('FLEET_CODEX_SUBSCRIPTION')
            os.environ['FLEET_CODEX_SUBSCRIPTION'] = with_env
            try:
                ACCOUNT['verify_codex_runtime'](source['codex_identity'].get('remote', ''))
            finally:
                if old is None: os.environ.pop('FLEET_CODEX_SUBSCRIPTION', None)
                else: os.environ['FLEET_CODEX_SUBSCRIPTION'] = old
        return matches[0]
    actual = run(['bash', BIN / 'fleet-account.sh', 'whoami', '--session', source['session'], source['window']])
    # whoami reports an account label, never credentials. Refuse stale stamps.
    matches = [r for r in data['accounts'] if r['agent'] == 'claude' and r['label'] == actual]
    if len(matches) != 1:
        raise ValueError('source Claude subscription cannot be verified')
    return matches[0]


def quiet_processes(source):
    rows = TRANSFER['process_rows']()
    pending = [int(source['pid'])]
    descendants, seen = [], set()
    while pending:
        parent = pending.pop()
        if parent in seen: continue
        seen.add(parent)
        children = [(p, comm) for p, (pp, comm) in rows.items() if pp == parent and p != parent]
        descendants.extend(children); pending.extend(p for p, _ in children)
    if source['agent'] == 'claude':
        if descendants:
            raise ValueError('source still owns tool/background processes')
    else:
        # A Fleet Codex root owns its runtime supervisor, guardian, server and
        # TUI. Anything else (including a tool shell) is unfinished work.
        allowed = {'python3', 'python', 'codex', 'ccquota'}
        if any(comm not in allowed and not re.fullmatch(r'python3\.\d+', comm) for _, comm in descendants):
            raise ValueError('Codex still owns a tool/background process')
        if sum(comm == 'codex' for _, comm in descendants) > 2:
            raise ValueError('Codex still owns additional agent processes')


def unresolved_claude_tools(path):
    pending = set()
    with Path(path).open() as stream:
        for line in stream:
            row = json.loads(line)
            if row.get('isSidechain'): continue
            content = row.get('message', {}).get('content', [])
            for b in content if isinstance(content, list) else []:
                if not isinstance(b, dict): continue
                if b.get('type') == 'tool_use': pending.add(b.get('id'))
                elif b.get('type') == 'tool_result': pending.discard(b.get('tool_use_id'))
    return bool(pending)


def validate(request, session, pane, sid):
    """Recheck immediately before /exit; quota never means arbitrary needs=idle."""
    r = read(request / 'request.json', {})
    expected = r.get('source', {})
    if (session, pane, sid) != (expected.get('session'), expected.get('pane'), expected.get('session_id')):
        raise ValueError('quota request belongs to a different source')
    source = inspect(session, pane)
    for key in ('pid','session_id','agent','worktree','transcript'):
        if source.get(key) != expected.get(key):
            raise ValueError('source identity changed after quota observation')
    if opt(source, '@reported') == '1' or opt(source, '@handoff_armed') == '1':
        raise ValueError('task completed or a context handoff is pending')
    if source['agent'] == 'codex':
        thread = native_thread(source)
        hard = quota_error(thread)
        if thread.get('status', {}).get('type') not in ('idle','systemError'):
            raise ValueError('source Codex turn or approval is still active')
        turns = thread.get('turns') or []
        if any(i.get('status') == 'inProgress' for t in turns[-1:] for i in t.get('items', [])):
            raise ValueError('source Codex tool is still active')
        if source['state'] != 'done' and not hard:
            raise ValueError('source has no terminal quota failure')
    else:
        hard = claude_banner(source)
        if source['state'] != 'done' and not hard:
            raise ValueError('source Claude turn is not complete or quota-blocked')
        if unresolved_claude_tools(source['transcript']):
            raise ValueError('source Claude tool result is unresolved')
    quiet_processes(source)
    for line in tm(session,'list-clients','-F','#{client_activity}|#{window_id}').splitlines():
        activity, win = line.split('|',1)
        if win == source['window'] and time.time()-int(activity) <= 30:
            raise ValueError('operator is active in the source window')
    snapshot = INPUT['snapshot'](session, pane)
    if snapshot['state'] == 'unknown':
        raise ValueError('source prompt/draft is not completely visible; leaving it untouched')
    frozen = read(request / 'input.json')
    if frozen and frozen['digest'] != snapshot['digest']:
        raise ValueError('unsent input changed while preparing the handoff')
    if not frozen:
        save(request / 'input.json', snapshot)
        if snapshot['state'] == 'draft':
            (request / 'unsent-draft.txt').write_text(snapshot['text'], encoding='utf-8')
    if r.get('hard') and not hard:
        raise ValueError('the observed quota failure is no longer current')


def root():
    return Path(os.environ.get('FLEET_CONF_DIR', str(Path.home()/'.config/claude-fleet'))) / 'handoffs' / 'quota-requests'


def request_path(source):
    identity = [source[k] for k in ('session','window','session_id')]
    return root() / hashlib.sha256(json.dumps(identity).encode()).hexdigest()[:32]


def outcome(path, r, state, detail=''):
    r.update(state=state, detail=detail, updated_at=time.time())
    save(path / 'request.json', r)
    try: stamp(r['source'], '' if state in ('bound','cancelled') else state + ': ' + detail[:160])
    except (OSError, ValueError, subprocess.SubprocessError): pass


def move(path, r, target):
    for name in ('input.json','unsent-draft.txt'):
        (path/name).unlink(missing_ok=True)
    save(path/'target.json',target)
    outcome(path,r,'preparing','selected '+target['key'])
    source = r['source']
    try:
        validate(path, source['session'], source['pane'], source['session_id'])
        flags = ['--session',source['session'],'--target-file',str(path/'target.json'),
                 '--quota-request',str(path)]
        if source['agent'] == target['agent'] == 'claude':
            cmd = ['bash',BIN/'fleet-migrate.sh',*flags,source['window']]
        else:
            cmd = ['bash',BIN/'fleet-transfer.sh',*flags,'--window',source['window'],'--to',target['agent']]
        env = dict(os.environ, FLEET_TRANSFER_BOOT_WAIT='30')
        env.pop('TMUX_PANE',None); env.pop('TMUX',None)
        with (path/'transfer.log').open('a') as log:
            result = subprocess.run([str(x) for x in cmd],env=env,stdout=log,stderr=log,timeout=180)
        manifest = opt(source,'@handoff_manifest')
        m = read(manifest,{}) if manifest else {}
        state = read(Path(manifest).parent/'state.json',{}) if manifest else {}
        if (result.returncode == 0 and m.get('quota_request') == str(path)
                and m.get('target',{}).get('session_id') and state.get('state') == 'started'):
            r['manifest'] = manifest
            outcome(path,r,'bound','target '+m['target']['session_id'])
        else:
            raise ValueError('transfer did not confirm the bound target; inspect transfer.log')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Retrying before source exit is safe; a dead/changed source is not.
        try:
            current = inspect(source['session'],source['window'])
            same = all(current[k] == source[k] for k in ('pid','session_id','agent'))
        except (OSError, ValueError, subprocess.SubprocessError): same=False
        if same:
            r['retry_at']=time.time()+60
            outcome(path,r,'waiting', str(error) if isinstance(error,ValueError) else type(error).__name__)
        else:
            outcome(path,r,'ambiguous','source exited/changed; inspect the retained pane and packet before recovery')


def reconcile(session, dry=False):
    if os.environ.get('FLEET_FAILOVER','0') != '1':
        return
    if not re.fullmatch(r'[A-Za-z0-9_-]+',session):
        raise ValueError('invalid fleet socket')
    root().mkdir(parents=True,exist_ok=True,mode=0o700)
    with locked(root()/(session+'.lock'),nonblocking=True):
        data = ACCOUNT['inventory']()
        windows = tm(session,'list-windows','-t',session,'-F','#{window_id}').splitlines()
        cursor = read(root()/(session+'.cursor.json'),{}).get('next',0)
        if windows: windows=windows[cursor%len(windows):]+windows[:cursor%len(windows)]
        deadline=time.monotonic()+60
        considered=0
        for window in windows:
            if time.monotonic() >= deadline: break
            considered += 1
            try:
                source=inspect(session,window)
                if opt(source,'@reported') == '1': continue
                account=source_account(source,data)
                hard=quota_error(native_thread(source)) if source['agent']=='codex' else claude_banner(source)
                path=request_path(source)
                r=read(path/'request.json',{})
                if r.get('state') in ('bound','cancelled','ambiguous'): continue
                over=(account.get('available') and account.get('utilization',0)>=float(os.environ.get('FLEET_ACCOUNT_CEILING','85')))
                blocked=account.get('limited_until',0)>time.time()
                if not hard and not over and not blocked and not r: continue
                if r and not hard and ACCOUNT['eligible'](account):
                    outcome(path,r,'cancelled','source subscription recovered; existing conversation retained')
                    continue
                if not r:
                    r=dict(source=source,source_key=account['key'],created_at=time.time(),state='waiting',hard=hard,attempts=0)
                    path.mkdir(parents=True,exist_ok=True,mode=0o700)
                if dry:
                    print(json.dumps(dict(source=source['session_id'],decision=ACCOUNT['choose'](data,source['agent'],[account['key']]))))
                    continue
                if hard or over:
                    until=int(account.get('reset_at') or time.time()+300)
                    if account['agent']=='codex': ACCOUNT['bench'](account['key'],until,'native quota error' if hard else 'ccquota ceiling')
                    else:
                        subprocess.run(['bash',str(BIN/'fleet-account.sh'),'bench',account['label'],str(until),'subscription failover'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
                if time.time()<r.get('retry_at',0): continue
                allowed=os.environ.get('FLEET_FAILOVER_AGENTS','claude,codex').split(',')
                decision=ACCOUNT['choose'](data,source['agent'],[account['key']],allowed=allowed)
                if not decision['target']:
                    outcome(path,r,'waiting-quota',decision['reason'])
                    continue
                r['attempts']+=1
                move(path,r,decision['target'])
            except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
                # Unsupported panels/old identities are left intact. Diagnostics
                # contain exception classes, never credentials or conversation text.
                print('fleet failover %s/%s: %s' % (session,window,str(error) if isinstance(error,ValueError) else type(error).__name__),file=sys.stderr)
        save(root()/(session+'.cursor.json'),{'next':cursor+considered})


def main():
    os.umask(0o077)
    p=argparse.ArgumentParser(description=__doc__)
    sub=p.add_subparsers(dest='command',required=True)
    q=sub.add_parser('reconcile'); q.add_argument('--session',required=True); q.add_argument('--dry-run',action='store_true')
    q=sub.add_parser('validate'); q.add_argument('request',type=Path)
    for field in ('session','pane','sid'): q.add_argument('--'+field,required=True)
    sub.add_parser('status')
    a=p.parse_args()
    if a.command=='reconcile': reconcile(a.session,a.dry_run)
    elif a.command=='validate': validate(a.request,a.session,a.pane,a.sid)
    else:
        print(json.dumps([read(f,{}) for f in root().glob('*/request.json')],ensure_ascii=False))


if __name__=='__main__':
    try: main()
    except BlockingIOError: pass  # Existing bounded reconciliation owns this fleet.
    except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
        print('fleet-failover: '+(str(error) if isinstance(error,ValueError) else type(error).__name__),file=sys.stderr)
        sys.exit(1)
