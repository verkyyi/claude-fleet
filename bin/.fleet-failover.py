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
ATTENTION = runpy.run_path(str(BIN / 'fleet-codex-attention.py'))
LOOP = runpy.run_path(str(BIN / 'fleet-loop.py'))
save, read, locked = (ACCOUNT[n] for n in ('save', 'read', 'locked'))


def run(argv, timeout=15, **kwargs):
    return subprocess.check_output([str(x) for x in argv], timeout=timeout,
                                   stderr=subprocess.PIPE, text=True, **kwargs).strip()


def tm(session, *args):
    return run(['tmux', '-L', session, *args], timeout=5)


def opt(source, key):
    return tm(source['session'], 'display-message', '-p', '-t', source['pane'], '#{' + key + '}')


def stamp(source, status):
    # A late failed controller must not MARK a replacement conversation; but
    # CLEARING a completed episode's marker is safe whoever now holds the window,
    # so an empty status skips the identity guard and always lands. Without this,
    # a bound migration (window now on the target's new session) left the old
    # marker to veto hibernation forever (#755/#809).
    if status:
        current = inspect(source['session'], source['window'])
        if any(current.get(k) != source.get(k) for k in ('pid','session_id','agent')):
            return
    tm(source['session'], 'set-option', '-w', '-t', source['window'], '@quota_failover', status)


def inspect(session, window):
    return json.loads(run(['bash', BIN / 'fleet-transfer.sh', '--session', session,
                          '--window', window, '--to', 'codex', '--inspect'], timeout=30))


def native_thread(source):
    data = source['codex_identity']
    rpc = RPC(data.get('remote', ''), timeout=5)
    try:
        t = ATTENTION['thread_read'](rpc, dict(data, session_id=source['session_id']), include_turns=True)
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
            elapsed = run(['ps','-p',str(source['pid']),'-o','etime='])
            days, clock = elapsed.split('-',1) if '-' in elapsed else ('0',elapsed)
            parts=[int(x) for x in clock.split(':')]
            age=int(days)*86400 + sum(n*60**i for i,n in enumerate(reversed(parts)))
            if (Path(expected['home'])/'auth.json').stat().st_mtime > time.time()-age+2:
                raise ValueError('unbound source login changed after launch; retain it until an exact account binding is available')
            with_env = json.dumps({k: expected[k] for k in ('account','profile','home')})
            old = os.environ.get('FLEET_CODEX_SUBSCRIPTION')
            os.environ['FLEET_CODEX_SUBSCRIPTION'] = with_env
            try:
                ACCOUNT['verify_codex_runtime'](source['codex_identity'].get('remote', ''), source=source)
            finally:
                if old is None: os.environ.pop('FLEET_CODEX_SUBSCRIPTION', None)
                else: os.environ['FLEET_CODEX_SUBSCRIPTION'] = old
        return matches[0]
    actual = run(['bash', BIN / 'fleet-account.sh', 'whoami', '--verified', '--session', source['session'], source['window']])
    # whoami reports an account label, never credentials. Refuse stale stamps.
    matches = [r for r in data['accounts'] if r['agent'] == 'claude' and r['label'] == actual]
    if len(matches) != 1:
        raise ValueError('source Claude subscription cannot be verified')
    return matches[0]


def quiet_processes(source, background=None):
    # The same exact executable/endpoint and restartable-MCP contract as
    # hibernation, for BOTH agents (#784/#808/#830): a quota-triggered wake must
    # be able to migrate a done worker whose only children are contract-listed
    # MCP servers, exactly as sleep can hibernate it. A pre-#784 blanket veto
    # here left every MCP-carrying Claude worker unable to fail over OR sleep.
    sleep = runpy.run_path(str(BIN / 'fleet-sleep.py'))
    if source['agent'] == 'codex':
        rpc = RPC(source['codex_identity'].get('remote', ''), timeout=5)
        try: sleep['quiet_native_children'](rpc, source['session_id'])
        finally: rpc.close()
    if background is None:
        return sleep['quiet_processes'](source)
    return sleep['quiet_processes'](source, background=background)


def bg_grace():
    """FLEET_FAILOVER_BG_GRACE seconds a HARD wall waits on background work (#871).

    0 = never override (the pre-#871 veto); a malformed value keeps the default."""
    try: return max(0, int(os.environ.get('FLEET_FAILOVER_BG_GRACE', '600')))
    except ValueError: return 600


def process_start(pid):
    """(state, lstart) — lstart fingerprints the process against pid reuse."""
    try: fields = run(['ps', '-p', str(pid), '-o', 'stat=', '-o', 'lstart=']).split(None, 1)
    except (subprocess.CalledProcessError, OSError): return '', ''
    return fields[0], (fields[1] if len(fields) > 1 else '')


def process_cwd(pid):
    try: return os.readlink('/proc/%d/cwd' % pid)
    except OSError: pass
    try: out = run(['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'])
    except (subprocess.CalledProcessError, OSError): return ''
    return next((line[1:] for line in out.splitlines() if line.startswith('n')), '')


def background_inventory(source):
    """Every non-infrastructure process the source owns, as [{pid,argv,cwd,start}].

    The one inventory of "what a migration will terminate" (EPIC #875 contract 3):
    the same walk as hibernation's veto, collecting instead of raising on an
    unverified child. Any OTHER veto (a foreign Codex endpoint, an active
    subagent) still raises."""
    pids = []
    quiet_processes(source, background=pids)
    argv = runpy.run_path(str(BIN / 'fleet_sleep_argv.py'))['process_argv']
    entries = []
    for pid in pids:
        state, start = process_start(pid)
        if not start or state.startswith('Z'): continue
        try: args = [str(x) for x in argv(pid)]
        except OSError: args = []
        entries.append(dict(pid=pid, argv=args, cwd=process_cwd(pid), start=start))
    return entries


background_note = TRANSFER['background_note']


def background_override(r, hard):
    """A hard wall that has waited out the grace no longer yields to background work."""
    grace = bg_grace()
    since = r.get('hard_at') or (r.get('created_at') if r.get('hard') else None)
    return bool(hard and grace and since and time.time() - since >= grace)


def terminate_background(request, bundle=None):
    """Stop the processes validate() recorded, after the source exited (#871).

    Only a pid whose start fingerprint still matches is signalled — a reused pid
    is never touched. The resume prompt then names every recorded command."""
    entries = read(Path(request) / 'background.json', [])
    if not entries: return
    live = []
    for e in entries:
        state, start = process_start(e['pid'])
        if start and start == e.get('start') and not state.startswith('Z'):
            try: os.kill(e['pid'], 15); live.append(e); e['stopped'] = 'SIGTERM'
            except ProcessLookupError: e['stopped'] = 'exited'
        else: e['stopped'] = 'exited'
    deadline = time.time() + 5
    while live and time.time() < deadline:
        time.sleep(0.2)
        live = [e for e in live if process_start(e['pid'])[1] == e['start']
                and not process_start(e['pid'])[0].startswith('Z')]
    for e in live:
        try: os.kill(e['pid'], 9); e['stopped'] = 'SIGKILL'
        except ProcessLookupError: pass
    save(Path(request) / 'background.json', entries)
    if bundle:
        note = background_note(entries)
        for name in ('pickup.md', 'handoff.md'):
            with (Path(bundle) / name).open('a', encoding='utf-8') as out: out.write(note)


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


def codex_quiet(thread):
    if thread.get('status', {}).get('type') not in ('idle','systemError'):
        raise ValueError('source Codex turn or approval is still active')
    if any(i.get('status') not in (None,'completed','failed','declined','interrupted')
           for t in (thread.get('turns') or [])[-1:] for i in t.get('items', [])):
        raise ValueError('source Codex tool is still active')


def looping_settled(source, thread):
    """A `looping` Codex source whose round ended cleanly is as settled as `done`.

    `looping` means THIS round ended and the loop is waiting for its next
    delivery. A proactive request pauses that delivery (quota_loop →
    waiting-quota), so the usageLimitExceeded turn a hard move waits for can
    never arrive (#786: 442 retries over 38h). Callers have already required an
    idle thread with no live item (codex_quiet); a completed last turn is then
    the end of a round, never an interrupted or failed one.
    """
    turns = thread.get('turns') or []
    return (source.get('agent') == 'codex' and source.get('state') == 'looping'
            and bool(turns) and turns[-1].get('status') == 'completed')


def settled(session, pane):
    """fleet-transfer.sh's manual source_ready for a `looping` Codex source."""
    source = inspect(session, pane)
    thread = native_thread(source)
    codex_quiet(thread)
    if not looping_settled(source, thread):
        raise ValueError('source is not a looping Codex worker between rounds')


def validate(request, session, pane, sid):
    """Recheck immediately before /exit; quota never means arbitrary needs=idle."""
    r = read(request / 'request.json', {})
    expected = r.get('source', {})
    if (session, pane, sid) != (expected.get('session'), expected.get('pane'), expected.get('session_id')):
        raise ValueError('quota request belongs to a different source')
    source = inspect(session, pane)
    if opt(source, '@worker_lifecycle'):
        raise ValueError('worker is sleeping or transitioning')
    for key in ('pid','session_id','agent','worktree','transcript'):
        if source.get(key) != expected.get(key):
            raise ValueError('source identity changed after quota observation')
    if opt(source, '@reported') == '1' or opt(source, '@handoff_armed') == '1':
        raise ValueError('task completed or a context handoff is pending')
    if r.get('episode') and evidence(source)[1] != r['episode']:
        raise ValueError('source turn changed after the quota observation')
    if source['agent'] == 'codex':
        thread = native_thread(source)
        hard = quota_error(thread)
        codex_quiet(thread)
        if source['state'] != 'done' and not hard and not looping_settled(source, thread):
            raise ValueError('source has no terminal quota failure')
    else:
        hard = claude_banner(source)
        if source['state'] != 'done' and not hard:
            raise ValueError('source Claude turn is not complete or quota-blocked')
        if unresolved_claude_tools(source['transcript']):
            raise ValueError('source Claude tool result is unresolved')
    # Hibernation and a PROACTIVE move keep the blanket background veto. A hard
    # wall cannot act on its background shells anyway, so after the grace they
    # are recorded (and stopped after /exit) instead of pinning it walled until
    # the reset — 89 vetoed retries over 2h on 2026-09-22 (#871).
    if background_override(r, hard):
        entries = background_inventory(source)
        if entries: save(request / 'background.json', entries)
        else: (request / 'background.json').unlink(missing_ok=True)
    else:
        (request / 'background.json').unlink(missing_ok=True)
        quiet_processes(source)
    for line in tm(session,'list-clients','-F','#{client_activity}|#{window_id}').splitlines():
        activity, win = line.split('|',1)
        if win == source['window'] and time.time()-int(activity) <= 30:
            raise ValueError('operator is active in the source window')
    snapshot = INPUT['snapshot'](session, pane, agent=source['agent'])
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
    identity = [source[k] for k in ('session','window','session_id','pid','agent')]
    return root() / hashlib.sha256(json.dumps(identity).encode()).hexdigest()[:32]


def quota_loop(path, source, state, restored=False):
    """Pause the durable record, including controllers loaded before this release.

    Existing controllers already respect status != active. The tmux flag alone
    cannot pause an older, living Python controller. Never change an ambiguous
    delivery, explicit stop, replacement thread or retired ownership generation.
    """
    manifest = source.get('previous')
    if not manifest or state == 'bound':
        return
    record = Path(manifest).parent / 'loop/state.json'
    if not record.is_file():
        return
    with LOOP['locked'](record, nonblocking=True) as loop:
        if (loop.get('status') not in ('active', 'waiting-quota')
                or loop.get('thread_id') != source['session_id']
                or loop.get('agent', 'codex') != source['agent']
                or loop.get('manifest') != manifest
                or Path(loop['worktree']).resolve() != Path(source['worktree']).resolve()):
            return
        if state in ('cancelled', 'recovered') and loop['status'] != 'waiting-quota':
            return
        LOOP['current'](loop)
        current = inspect(source['session'], source['window'])
        if not same_source(current, source) or opt(current, '@reported') == '1':
            return
        if state in ('cancelled', 'recovered'):
            if loop.get('quota_request') != str(path):
                prior = read(Path(loop.get('quota_request', '')) / 'request.json', {})
                previous = prior.get('source', {})
                if (not restored or prior.get('state') != 'cancelled'
                        or any(previous.get(k) != source.get(k) for k in
                               ('session_id', 'agent', 'worktree', 'previous'))):
                    return
            loop.update(status='active', detail='Quota wait released for the exact loop owner')
            loop.pop('quota_request', None)
            # A reset continuation or new operator turn already resumes the task;
            # do not race it with a second wakeup for an overdue interval.
            loop['schedule']['next_run_at'] = time.time() + loop['schedule']['interval_seconds']
        else:
            loop.update(status='waiting-quota', quota_request=str(path),
                        detail='Waiting for the existing subscription failover request')
        LOOP['save'](record, loop)


def outcome(path, r, state, detail=''):
    r.update(state=state, detail=detail, updated_at=time.time())
    save(path / 'request.json', r)
    # A completed episode clears its window marker unconditionally: after a bound
    # migration the window holds the target's new session, so the previous
    # manifest-equality clear missed it. stamp() lets the empty status through
    # its identity guard for exactly this case (#755/#809).
    try: stamp(r['source'], '' if state in ('bound','cancelled','recovered') else state + ': ' + detail[:160])
    except (OSError, ValueError, subprocess.SubprocessError): pass
    try: quota_loop(path, r['source'], state)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError): pass


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
        if m.get('quota_request') == str(path):
            r['manifest'] = manifest
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
            r.setdefault('failed_targets',{})[target['key']]=time.time()+120
            outcome(path,r,'waiting', str(error) if isinstance(error,ValueError) else type(error).__name__)
        else:
            outcome(path,r,'ambiguous','source exited/changed; inspect the retained pane and packet before recovery')


def same_source(left, right):
    return all(left.get(k) == right.get(k) for k in ('pid','session_id','agent','window','session'))


def evidence(source):
    if source['agent'] == 'codex':
        thread = native_thread(source)
        last = (thread.get('turns') or [{}])[-1]
        return quota_error(thread), 'codex:' + str(last.get('id', ''))
    hard = claude_banner(source)
    with Path(source['transcript']).open('rb') as stream:
        stream.seek(max(0, Path(source['transcript']).stat().st_size - 65536))
        tail = stream.read()
    return hard, 'claude:' + hashlib.sha256(tail).hexdigest()


def recover(path, r):
    """One wakeup after a verified reset; ambiguous writes are never repeated."""
    source = r['source']
    try:
        for name in ('input.json','unsent-draft.txt'):
            (path/name).unlink(missing_ok=True)
        validate(path, source['session'], source['pane'], source['session_id'])
        if read(path/'input.json', {}).get('state') != 'empty':
            raise ValueError('quota recovered; waiting for the unsent draft to be handled')
        # The existing inbox/queue transport has exact pane/session guards. A
        # failed write may already have arrived, so persist before submitting.
        outcome(path, r, 'recovery-sending', 'resuming the original conversation after quota reset')
        subprocess.run(['bash',str(BIN/'fleet-peer-send.sh'),'-L',source['session'],source['pane'],'-'],
            input='[Fleet subscription recovered] Continue the authorized unfinished task in the existing conversation language. Check actual results before repeating any interrupted action. Preserve unsent drafts and pending approvals.',
            text=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=15, check=True)
        outcome(path, r, 'recovered', 'reset observed; continuation delivered through the existing peer transport')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        if r.get('state') == 'recovery-sending':
            outcome(path,r,'ambiguous','reset continuation acknowledgement is uncertain; not resending')
        else:
            outcome(path,r,'waiting',str(error) if isinstance(error,ValueError) else type(error).__name__)


def cancel_obsolete(session, enabled):
    for filename in root().glob('*/request.json'):
        r = read(filename,{})
        source = r.get('source',{})
        if source.get('session') != session:
            continue
        if r.get('state') in ('bound','cancelled','recovered','ambiguous'):
            if r.get('state') in ('cancelled','recovered'):
                # An older controller may have held its record lock when the
                # terminal outcome arrived. Retry that release on later ticks.
                try: quota_loop(filename.parent, source, r['state'])
                except (OSError,ValueError,KeyError,subprocess.SubprocessError): pass
            continue
        try:
            # Retained workers deliberately have no live native identity. Keep
            # their request until wake can reconcile the replacement PID.
            if opt(source, '@worker_lifecycle'):
                continue
            current = inspect(session,source['window'])
            obsolete = not same_source(current,source) or opt(current,'@reported') == '1'
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            # An unavailable identity may be a temporary hook/startup condition.
            # Only a missing window or explicit disable is a cancellation fact.
            obsolete = source.get('window') not in tm(session,'list-windows','-t',session,'-F','#{window_id}').splitlines()
        if not enabled or obsolete:
            outcome(filename.parent,r,'cancelled','feature disabled' if not enabled else 'source closed, replaced or task completed')


def reconcile_one(source, account, data, dry=False):
    hard, episode = evidence(source)
    path = request_path(source)
    r = read(path/'request.json',{})
    if r and not same_source(source,r.get('source',{})):
        raise ValueError('request source identity collision')
    if r.get('state') in ('ambiguous','preparing','recovery-sending'):
        if not dry:
            outcome(path,r,'ambiguous','interrupted cutover/delivery; inspect retained packet before recovery')
        return
    if r.get('state') in ('bound','cancelled','recovered'):
        if episode == r.get('episode'):
            return
        r = {}
    elif r and r.get('episode') != episode:
        if not dry: outcome(path,r,'cancelled','source advanced to a different turn')
        r = {}
    over = (account.get('available') is True and account.get('utilization',0) >= float(os.environ.get('FLEET_ACCOUNT_CEILING','85')))
    blocked = account.get('limited_until',0) > time.time()
    if not hard and not over and not blocked and not r:
        if not dry and ACCOUNT['eligible'](account):
            # Exact crash restoration may have rebound a waiting loop after its
            # old PID-bound request was cancelled. Only fresh healthy quota can
            # release it; the loop recovery scanner itself never assumes reset.
            quota_loop(path, source, 'cancelled', restored=True)
        return
    # An idle `done` worker with no active turn is cheaper HIBERNATED than migrated
    # when sleep is on: sleep retires its session — freeing the very quota that
    # tripped the ceiling — and restores it on demand, where a proactive migration
    # spends tokens moving a conversation that is doing nothing. So a proactive
    # trigger (over/blocked, never a hard wall) hands a `done` source to the sleep
    # daemon: no request, no bench, no marker, so check_quota_wait sees nothing and
    # hibernation proceeds. A hard wall still migrates (sleep refuses a hard-walled
    # source, and its account is genuinely out of headroom); a `working` source
    # still migrates (moving it BEFORE it hits the wall is the point); and with
    # sleep off it would neither sleep nor migrate, so it is not deferred.
    # (operator choice, 2026-09-20 — idle done prefers sleep.)
    if (not hard and (over or blocked) and source.get('state') == 'done'
            and os.environ.get('FLEET_SLEEP') == 'on'):
        if dry:
            print(json.dumps(dict(source=source['session_id'],
                  decision={'state':'deferred-to-hibernation','target':None,
                            'reason':'idle done source; hibernation frees this quota, migration spends it'})))
        elif r and r.get('state') not in ('bound','cancelled','recovered'):
            outcome(path,r,'cancelled','idle done source deferred to hibernation')
        return
    allowed = os.environ.get('FLEET_FAILOVER_AGENTS','claude,codex').split(',')
    failed = [key for key,until in r.get('failed_targets',{}).items() if until > time.time()]
    decision = ACCOUNT['choose'](data,source['agent'],[account['key'],*failed],allowed=allowed)
    if dry:
        print(json.dumps(dict(source=source['session_id'],decision=decision)))
        return
    if not r:
        r = dict(source=source,source_key=account['key'],created_at=time.time(),state='waiting',
                 hard=hard,episode=episode,attempts=0,failed_targets={})
        path.mkdir(parents=True,exist_ok=True,mode=0o700)
    if hard and not r.get('hard_at'):
        # The background grace counts from the WALL, not from a proactive request
        # that walled later (#871).
        r['hard_at'] = time.time()
        save(path/'request.json',r)
    if (source['agent'] == 'codex' and hard and not over and not blocked
            and not r.get('benched_until')):
        outcome(path,r,'waiting-evidence','native limit has no account-wide quota confirmation; check model limits or refresh ccquota')
        return
    if r and not hard and ACCOUNT['eligible'](account):
        outcome(path,r,'cancelled','source subscription recovered; existing conversation retained')
        return
    # A stale terminal error is not a new quota episode. Only fresh readings
    # after its reset/cooldown can authorize one continuation on the same agent.
    if (r.get('benched_until') and time.time() >= r['benched_until']
            and ACCOUNT['eligible'](dict(account,limited_until=0))):
        recover(path,r)
        return
    if (hard or over) and not r.get('benched_until'):
        until = int(account.get('reset_at') or time.time()+300)
        until = max(until, int(time.time())+30)
        r['benched_until'] = until
        if account['agent'] == 'codex':
            ACCOUNT['bench'](account['key'],until,'native quota error' if hard else 'ccquota ceiling')
        else:
            subprocess.run(['bash',str(BIN/'fleet-account.sh'),'bench',account['label'],str(until),'subscription failover'],
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
    if time.time() < r.get('retry_at',0):
        return
    if not decision['target']:
        outcome(path,r,'waiting-quota',decision['reason'])
        return
    r['attempts'] += 1
    move(path,r,decision['target'])


def reconcile(session, dry=False):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',session):
        raise ValueError('invalid fleet socket')
    enabled = os.environ.get('FLEET_FAILOVER','0') == '1'
    if not enabled:
        if root().is_dir() and not dry: cancel_obsolete(session,False)
        if not dry: runpy.run_path(str(BIN/'fleet-loop.py'))['recover'](session)
        return
    # No queue files, status stamps or locks are created by a dry run.
    if dry:
        reconcile_windows(session,True)
    else:
        root().mkdir(parents=True,exist_ok=True,mode=0o700)
        with locked(root()/(session+'.lock'),nonblocking=True):
            cancel_obsolete(session,True)
            if os.environ.get('FLEET_CODEX_MODEL_FALLBACK'):
                if runpy.run_path(str(BIN/'fleet-codex-model.py'))['watch'](session):
                    return
            reconcile_windows(session,False)
            runpy.run_path(str(BIN/'fleet-loop.py'))['recover'](session)


def reconcile_windows(session, dry):
    data = ACCOUNT['inventory']()
    windows = tm(session,'list-windows','-t',session,'-F','#{window_id}|#{window_name}').splitlines()
    windows = [line.split('|',1)[0] for line in windows if line.split('|',1)[-1] not in ('dash','plan','backlog','hub')]
    cursor = read(root()/(session+'.cursor.json'),{}).get('next',0)
    if windows: windows=windows[cursor%len(windows):]+windows[:cursor%len(windows)]
    deadline=time.monotonic()+60
    considered=0
    for window in windows:
        if time.monotonic() >= deadline: break
        considered += 1
        try:
            if tm(session,'display-message','-p','-t',window,'#{@worker_lifecycle}'):
                continue
            source=inspect(session,window)
            if opt(source,'@reported') == '1': continue
            account=source_account(source,data)
            reconcile_one(source,account,data,dry)
            if not dry:
                (root()/('unsupported-'+session+'-'+window.replace('@','')+'.json')).unlink(missing_ok=True)
        except (OSError,ValueError,KeyError,TypeError,EOFError,subprocess.SubprocessError) as error:
            reason = str(error) if isinstance(error,ValueError) else type(error).__name__
            if not dry:
                save(root()/('unsupported-'+session+'-'+window.replace('@','')+'.json'),
                     dict(session=session,window=window,state='unsupported',reason=reason,updated_at=time.time()))
    if not dry: save(root()/(session+'.cursor.json'),{'next':cursor+considered})


def main():
    os.umask(0o077)
    p=argparse.ArgumentParser(description=__doc__)
    sub=p.add_subparsers(dest='command',required=True)
    q=sub.add_parser('reconcile'); q.add_argument('--session',required=True); q.add_argument('--dry-run',action='store_true')
    q=sub.add_parser('validate'); q.add_argument('request',type=Path)
    for field in ('session','pane','sid'): q.add_argument('--'+field,required=True)
    q=sub.add_parser('settled'); q.add_argument('--session',required=True); q.add_argument('--pane',required=True)
    q=sub.add_parser('terminate-background'); q.add_argument('request',type=Path)
    q.add_argument('--bundle',type=Path)
    sub.add_parser('status')
    a=p.parse_args()
    if a.command=='reconcile': reconcile(a.session,a.dry_run)
    elif a.command=='validate': validate(a.request,a.session,a.pane,a.sid)
    elif a.command=='settled': settled(a.session,a.pane)
    elif a.command=='terminate-background': terminate_background(a.request,a.bundle)
    else:
        paths = list(root().glob('*/request.json')) + list(root().glob('unsupported-*.json'))
        print(json.dumps([read(f,{}) for f in paths],ensure_ascii=False))


if __name__=='__main__':
    try: main()
    except BlockingIOError: pass  # Existing bounded reconciliation owns this fleet.
    except (OSError,ValueError,KeyError,TypeError,EOFError,subprocess.SubprocessError) as error:
        print('fleet-failover: '+(str(error) if isinstance(error,ValueError) else type(error).__name__),file=sys.stderr)
        sys.exit(1)
