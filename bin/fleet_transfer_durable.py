#!/usr/bin/env python3
"""Single-owner handover of Claude durable one-shot tasks to Fleet (issue #4280).

A Claude durable task lives in the HOME project's `~/.claude/scheduled_tasks.json`
and is delivered by a live Claude of that project. When the one source session
leaves, the table survives but nothing delivers it on time (a later Claude only
offers to catch it up). This module moves such a task to the Fleet scheduler of
the transferred session, with ONE owner at every instant:

    owner(journal, table) = native  while the record is in the table,
                            fleet   while the journal holds it (withdrawn/active,
                                    or a write-ahead state with the record gone),
                            done    after Fleet's accepted delivery.

The road, all in the journal `$FLEET_CONF_DIR/transfer-durable/<fid>.json`:

  staged       the source's export writes the inert Fleet copy + the native
               snapshot and reads both back (Fleet's `gate` answers wait);
  withdrawing  written BEFORE the source's native CronDelete (write-ahead);
  withdrawn    the CronDelete receipt of every id, a later CronList without
               them, and the table without them all agree (`confirm`);
  active       the source process is verified gone and the target (Codex, or
               the source itself resumed by a rollback) is bound to the Fleet
               loop that carries the job — the only state Fleet delivers in;
  complete     Fleet's delivery was accepted.

On this road Fleet never writes the native table: every native change is the
source's own CronDelete / CronCreate, checked against its tool results and a
read-only look at the table. Failure keeps one owner: before the receipt the
record never left; after it, a rollback resumes the source through the same
Fleet loop (the job goes with it), and a source still running is asked for an
explicit CronCreate (`restoring` → `rolled_back` once its receipt and the table
agree). Anything the evidence cannot settle is left as it is and shown
(`status`, `attention`), never resent.

Road 2 — the source cannot cooperate (dead, stuck, out of quota): the transfer
controller stages from the native table (the records the source process created,
by pid + procStart), the source exits, and `handed` withdraws them itself, ONLY
inside the isolation boundary: Fleet holds the launch gate (fleet-session-wrap
starts no Claude in this HOME meanwhile) and every live Claude process of this
login is accounted for — registered, and not in this HOME project (the only
writers of its table). An unknown or HOME-bound Claude refuses, naming its pid.
The rewrite is a plain read-modify-write (re-read just before an atomic
rename); every other record stays byte for byte. The scheduler lock is only a
hint here: a holder that is alive and not the source refuses too.
"""
from contextlib import contextmanager
import errno
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fleet_cron import fields, next_fire  # noqa: E402

# Native formats this reader has verified (the table / lock layout and the
# scheduler's lock + creator rules). Anything else refuses, never guesses.
SUPPORTED = ('2.1.295',)
MARGIN = 180          # a task due sooner stays with its current owner
CLAIM_SECS = 900      # a staged / withdrawing journal no transfer claimed goes stale
GATE_WAIT = 1800      # a launch waits at most this long behind the gate
TERMINAL = ('rolled_back', 'returned', 'complete')
SCHED_TOOLS = ('CronList', 'CronCreate', 'CronDelete', 'ScheduleWakeup')


class Refused(ValueError):
    """A precondition that keeps the native owner; nothing was changed."""


# --- processes ---------------------------------------------------------------

def proc_start(pid):
    """`ps -o lstart` in UTC — the native lock's procStart format; '' = gone."""
    try:
        return subprocess.check_output(
            ['ps', '-p', str(int(pid)), '-o', 'lstart='], text=True,
            env=dict(os.environ, LC_ALL='C', TZ='UTC'), stderr=subprocess.DEVNULL,
            timeout=5).strip()
    except (subprocess.CalledProcessError, ValueError, TypeError):
        return ''


def alive(pid, start):
    """A pid that is gone, or now names a different process (reused), is dead.
    Never judged by session id: a /clear changes the id, not the process."""
    try:
        os.kill(int(pid), 0)
    except (ProcessLookupError, ValueError, TypeError):
        return False
    except PermissionError:
        pass
    return bool(start) and proc_start(pid) == start


def crash(point):
    # Selftest seam: SIGKILL this process at a named step (never set in use).
    if os.environ.get('FLEET_DURABLE_TEST_CRASH') == point:
        os.kill(os.getpid(), 9)


# --- files -------------------------------------------------------------------

def read(path):
    path = Path(path)
    if path.is_symlink():
        raise Refused('refusing to follow a symlink: ' + str(path))
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None


def atomic(path, value, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise Refused('refusing to write through a symlink: ' + str(path))
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as out:
            os.fchmod(out.fileno(), mode)
            json.dump(value, out, ensure_ascii=False, indent=2)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def native_paths(home):
    home = Path(home).resolve()
    return home / '.claude/scheduled_tasks.json', home / '.claude/scheduled_tasks.lock'


def tasks(value):
    if value is None:
        return []
    if not isinstance(value, dict) or not isinstance(value.get('tasks'), list):
        raise Refused('unknown native durable task table')
    entries = value['tasks']
    if any(not isinstance(r, dict) or not isinstance(r.get('id'), str) for r in entries):
        raise Refused('unknown native durable task record')
    if len({r['id'] for r in entries}) != len(entries):
        raise Refused('duplicate native task identities')
    return entries


def table(store):
    return {t['id']: t for t in tasks(read(store))}


def _zone_key(name):
    """An IANA key ZoneInfo accepts, or None: `/UTC`, `…/zoneinfo//UTC` and
    `:/etc/localtime` all occur (issue #4309) — ZoneInfo refuses an absolute key."""
    from zoneinfo import ZoneInfo
    name = (name or '').lstrip(':')
    if '/zoneinfo/' in name:
        name = name.split('/zoneinfo/', 1)[1]
    name = name.lstrip('/')
    if not name:
        return None
    try:
        ZoneInfo(name)
    except Exception:  # ValueError, ZoneInfoNotFoundError, a bad path
        return None
    return name


def local_zone(tz=None, localtime='/etc/localtime'):
    """The IANA zone native cron uses (the process's local time)."""
    tz = os.environ.get('TZ', '') if tz is None else tz
    if tz.lstrip(':').startswith('/'):
        try:
            tz = os.path.realpath(tz.lstrip(':'))
        except OSError:
            pass
    key = _zone_key(tz) if '/' in tz else None
    if key:
        return key
    try:
        target = os.readlink(localtime)
    except OSError:
        target = ''
    return _zone_key(target) or 'UTC'


def transcript_version(transcript):
    """The Claude Code version the source transcript records last."""
    version = None
    with open(transcript, encoding='utf-8') as lines:
        for line in lines:
            if '"version"' not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and isinstance(row.get('version'), str):
                version = row['version']
    return version


# --- eligibility (read-only) -------------------------------------------------

def holder(lock, source):
    """('none'|'dead'|'source'|'other', lock record) — by pid + procStart."""
    owner_ = read(lock)
    if owner_ is None:
        return 'none', None
    if not isinstance(owner_, dict) or not isinstance(owner_.get('sessionId'), str):
        raise Refused('unknown native scheduler lock format')
    if not alive(owner_.get('pid'), owner_.get('procStart')):
        return 'dead', owner_
    if owner_.get('pid') == source['pid'] and owner_.get('procStart') == source['start']:
        return 'source', owner_
    return 'other', owner_


def describe(owner_):
    return 'pid %s (session %s, since %s)' % (owner_.get('pid'), owner_.get('sessionId'),
                                              owner_.get('procStart'))


def job_for(record, zone=None):
    return dict(id=record['id'], prompt=record['prompt'], cron=record['cron'],
                timezone=zone or local_zone(), expires_at=None, stop_when='', recurring=False)


def check_records(records, home, source, now):
    for r in records:
        if r.get('createdInProject') != str(home):
            raise Refused('native durable task belongs to another project: ' + r['id'])
        if r.get('recurring'):
            raise Refused('only durable one-shots move; recurring durable task ' + r['id'])
        if not isinstance(r.get('prompt'), str) or not r['prompt'].strip():
            raise Refused('native durable task has no prompt: ' + r['id'])
        if not isinstance(r.get('cron'), str):
            raise Refused('native durable task has no cron: ' + r['id'])
        if fields(r['cron'])[1][0] & {0, 30}:
            # Native one-shots at :00/:30 fire up to 90 s early at a time it
            # picks; Fleet cannot reproduce that choice.
            raise Refused('native early-jitter one-shot cannot move: ' + r['id'])
        mine = r.get('createdByPid') == source['pid'] and r.get('createdByProcStart') == source['start']
        if not mine and alive(r.get('createdByPid'), r.get('createdByProcStart')):
            raise Refused('native durable task %s is run by its live creator pid %s'
                          % (r['id'], r.get('createdByPid')))
        job = job_for(r)
        created = r.get('createdAt')
        if type(created) not in (int, float):
            raise Refused('native durable task has no creation time: ' + r['id'])
        due = next_fire(job, now)
        if due is None or next_fire(job, created / 1000) != due:
            raise Refused('native durable task %s missed or changed its round' % r['id'])
        if due <= now + MARGIN:
            raise Refused('native durable task %s is due inside the cutover margin' % r['id'])


def inspect(home, source_pid, version, now=None):
    """The HOME's durable records, checked for the live source's native road.

    Read-only; every condition this road cannot verify raises Refused.
    """
    now = time.time() if now is None else now
    home = Path(home).resolve()
    store, lock = native_paths(home)
    records = tasks(read(store))
    if not records:
        return dict(records=[])
    if version not in SUPPORTED:
        raise Refused('native durable handover requires a verified Claude ' + '/'.join(SUPPORTED)
                      + ' (source is ' + str(version or 'unknown') + ')')
    start = proc_start(source_pid)
    if not start:
        raise Refused('the source process is gone; its durable tasks cannot use the native road')
    source = dict(pid=int(source_pid), start=start)
    kind, owner_ = holder(lock, source)
    if kind == 'other':
        raise Refused('native scheduler lock is held by another live process: ' + describe(owner_)
                      + '; durable tasks stay where they are, switch refused')
    if kind != 'source':
        raise Refused('native scheduler lock is not held by the live source; switch refused')
    check_records(records, home, source, now)
    return dict(records=records, source=source)


# --- the journal -------------------------------------------------------------

def root():
    return Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))) / 'transfer-durable'


def journal_path(fid):
    if not fid or any(c not in '0123456789abcdefABCDEF-' for c in fid):
        raise ValueError('durable handover needs a lifelong identity')
    return root() / (fid + '.json')


@contextmanager
def locked(path, wait=True):
    path = Path(path)
    with path.with_suffix('.lock').open('a') as fd:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except OSError as error:
            if error.errno not in (errno.EAGAIN, errno.EACCES):
                raise
            raise BlockingIOError('durable journal busy') from None
        r = read(path)
        if r is None:
            raise ValueError('no durable handover journal at ' + str(path))
        yield r


def save(path, r, state=None, **extra):
    if state:
        r['state'] = state
        r.setdefault('history', []).append(dict(state=state, at=time.time(), **extra))
    r['updated_at'] = time.time()
    atomic(path, r)
    if read(path) != r:
        raise ValueError('durable handover journal readback failed')


def load(fid):
    r = read(journal_path(fid))
    if r is None:
        raise ValueError('no durable handover journal for ' + fid)
    return r


def new_journal(fid, home, info, session_id, version, jobs, road):
    """Write the inert Fleet copy and the native snapshot; read both back."""
    path = journal_path(fid)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.with_suffix('.lock').open('a') as fd:
        fcntl.flock(fd, fcntl.LOCK_EX)
        old = read(path)
        src = dict(info['source'], session_id=session_id)
        if old is not None and old.get('state') not in TERMINAL:
            if not (old.get('state') == 'staged' and old['source'] == src):
                raise Refused('an unresolved durable handover exists (%s, state %s)'
                              % (path, old.get('state')))
        by_id = {j['id']: j for j in jobs}
        records = {r['id']: r for r in info['records']}
        if set(by_id) != set(records):
            raise ValueError('the Fleet plan must name exactly the native durable tasks')
        for ident, rec in records.items():
            want = job_for(rec, by_id[ident].get('timezone'))
            got = {k: by_id[ident].get(k) for k in want}
            if got != want or want['timezone'] != local_zone():
                raise ValueError('staged Fleet job differs from native durable task ' + ident)
        store, lock = native_paths(home)
        staged = [dict(job_for(records[i]), next_run_at=next_fire(job_for(records[i]), time.time()))
                  for i in sorted(records)]
        r = dict(schema=1, fid=fid, nonce=str(uuid.uuid4()), road=road, home=str(Path(home).resolve()),
                 store=str(store), lock=str(lock), version=version, source=src, jobs=staged,
                 records=records, controller=dict(pid=src['pid'], start=src['start']),
                 deadline=time.time() + CLAIM_SECS, history=[])
        save(path, r, 'staged')
        back = read(path)
        if back['jobs'] != staged or back['records'] != records:
            raise ValueError('staged Fleet job readback failed')
        return path


def stage(fid, home, source_pid, session_id, version, jobs, transcript):
    """Road 1: run from the live source's own export."""
    info = inspect(home, source_pid, version)
    if not info['records']:
        raise ValueError('no native durable task to stage')
    path = new_journal(fid, home, info, session_id, version, jobs, 'native')
    with locked(path) as r:
        r['transcript'] = str(transcript)
        save(path, r)
    return path


def owner(r, present=None):
    """native | fleet | done | none | both — the invariant the selftest samples."""
    ids = {j['id'] for j in r['jobs']} | set(r.get('restored_ids', []))
    if present is None:
        present = bool(ids & set(table(r['store'])))
    state = r['state']
    if state == 'complete':
        return 'both' if present else 'done'
    claims = state in ('withdrawn', 'active') or (state in ('withdrawing', 'restoring') and not present)
    if claims and present:
        return 'both'
    return 'fleet' if claims else ('native' if present else 'none')


def _absent(r):
    present = {j['id'] for j in r['jobs']} & set(table(r['store']))
    if present:
        raise Refused('a migrated native task is still in the table: ' + ', '.join(sorted(present)))


def _source_alive(r):
    return alive(r['source']['pid'], r['source']['start'])


def _scheduler_calls(transcript, since):
    from fleet_loop_mark import claude_tool_results
    import fleet_iso
    for name, inp, resp, use_ts, res_ts in claude_tool_results(
            Path(transcript).read_text().splitlines(), SCHED_TOOLS, strict=True):
        at = fleet_iso.parse(res_ts).timestamp() if res_ts else 0
        if at >= since:
            yield name, inp, resp


def _listed(resp, ids):
    text = resp if isinstance(resp, str) else json.dumps(resp, ensure_ascii=False)
    return {i for i in ids if i in text}


# --- road 1: the source's native receipts ------------------------------------

def begin(fid):
    """Write-ahead, run by the live source right before its native CronDelete."""
    path = journal_path(fid)
    with locked(path) as r:
        if r['state'] == 'withdrawing':
            return
        if r['state'] != 'staged' or r['road'] != 'native':
            raise Refused('durable handover is %s, not a staged native road' % r['state'])
        if not _source_alive(r):
            raise Refused('the source process is gone')
        if {i: table(r['store']).get(i) for i in r['records']} != r['records']:
            raise Refused('a staged native task changed since staging; export again')
        save(path, r, 'withdrawing')


def _receipts(r, transcript):
    """(ids with a CronDelete receipt, the CronList after them or None)."""
    since = max(h['at'] for h in r['history'] if h['state'] == 'withdrawing')
    ids = {j['id'] for j in r['jobs']}
    deleted, listed = set(), None
    for name, inp, resp in _scheduler_calls(transcript, since):
        if name == 'CronDelete' and inp.get('id') in ids:
            deleted.add(inp['id'])
            listed = None
        elif name == 'CronList':
            listed = resp
        else:
            listed = None   # any other scheduler change voids the earlier list
    return deleted, listed


def confirm(fid, transcript):
    """Every id's CronDelete receipt, then a CronList without them, then the table."""
    path = journal_path(fid)
    with locked(path) as r:
        if r['state'] == 'withdrawn':
            return
        if r['state'] != 'withdrawing' or r['road'] != 'native':
            raise Refused('no native withdrawal in progress (%s)' % r['state'])
        ids = {j['id'] for j in r['jobs']}
        deleted, listed = _receipts(r, transcript)
        if deleted != ids:
            raise ValueError('no native CronDelete receipt for: ' + ', '.join(sorted(ids - deleted)))
        if listed is None:
            raise ValueError('need a native CronList after the CronDelete, with no scheduler call after it')
        if _listed(listed, ids):
            raise ValueError('the native CronList still lists a withdrawn durable task')
        _absent(r)
        save(path, r, 'withdrawn')


def restore_request(r):
    """What the still-running source must do to take its task back natively."""
    return ('[Fleet transfer rollback] The switch did not happen and you keep running. Re-create each '
            'durable task you deleted for it, exactly: ' + '; '.join(
                'CronCreate(cron=%s, prompt=%s, recurring=false, durable=true)'
                % (json.dumps(j['cron']), json.dumps(j['prompt'], ensure_ascii=False)) for j in r['jobs'])
            + '. Then run: python3 ' + str(Path(__file__).resolve()) + ' confirm-restored ' + r['fid']
            + ' <this session transcript>. Do not create any other timer.')


def confirm_restored(fid, transcript):
    """The source's CronCreate receipts recreate every task; the table has them."""
    path = journal_path(fid)
    with locked(path) as r:
        if r['state'] == 'rolled_back':
            return
        if r['state'] != 'restoring':
            raise Refused('no native restore in progress (%s)' % r['state'])
        since = max(h['at'] for h in r['history'] if h['state'] == 'restoring')
        want = {(j['cron'], j['prompt']) for j in r['jobs']}
        made = {(inp.get('cron'), inp.get('prompt')) for name, inp, resp in _scheduler_calls(transcript, since)
                if name == 'CronCreate' and inp.get('durable') is True and not inp.get('recurring')}
        if not want <= made:
            raise ValueError('no native CronCreate receipt for every task')
        held = {t['id']: (t.get('cron'), t.get('prompt')) for t in table(r['store']).values()}
        if not want <= set(held.values()):
            raise ValueError('the native table does not hold every re-created task')
        r['restored_ids'] = sorted(i for i, key in held.items() if key in want)
        save(path, r, 'rolled_back', why='source re-created its tasks natively')


# --- road 2: the uncooperative source; Fleet rewrites inside isolation -------

def claude_processes():
    """Every live Claude process of this login, by the walk fleet-lib.sh uses
    (fleet_pane_claude_pids): comm `claude`, or node/bun running its cli."""
    me = os.getuid()
    rows = subprocess.check_output(['ps', '-axo', 'pid=,uid=,stat=,comm='], text=True,
                                   env=dict(os.environ, LC_ALL='C'), timeout=10, errors='replace')
    cmds = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True,
                                   env=dict(os.environ, LC_ALL='C'), timeout=10, errors='replace')
    command = {}
    for line in cmds.splitlines():
        head = line.strip().split(None, 1)
        if head and head[0].isdigit():
            command[int(head[0])] = ' ' + (head[1] if len(head) > 1 else '') + ' '
    extra = os.environ.get('FLEET_CLAUDE_COMM', '')
    found = []
    for line in rows.splitlines():
        part = line.split(None, 3)
        if len(part) < 4 or not part[0].isdigit() or int(part[1]) != me or 'Z' in part[2]:
            continue
        pid, base = int(part[0]), part[3].rsplit('/', 1)[-1]
        cmd = command.get(pid, '')
        if (base == 'claude' or (re_node(base) and ('claude-code/cli.js' in cmd or '/claude ' in cmd))
                or (extra and base in ('bash', 'sh', 'zsh', 'dash') and extra in cmd)):
            found.append(pid)
    return sorted(found)


def re_node(base):
    return base == 'bun' or (base.startswith('node') and base[4:].isdigit()) or base == 'node'


def isolation(home, exclude=()):
    """Refuse unless every live Claude of this login is registered and runs
    outside this HOME project — i.e. none can rewrite its task table."""
    registry = Path(os.environ.get('FLEET_CC_SESSIONS_DIR', str(Path.home() / '.claude/sessions')))
    unknown = []
    for pid in claude_processes():
        if pid in exclude:
            continue
        try:
            cwd = json.loads((registry / ('%d.json' % pid)).read_text()).get('cwd', '')
        except (OSError, ValueError):
            unknown.append('pid %d (no session registry: unknown or old)' % pid)
            continue
        if not cwd or Path(cwd).resolve() == Path(home).resolve():
            unknown.append('pid %d (runs in this HOME)' % pid)
    if unknown:
        raise Refused('a live Claude outside the handover could rewrite the native task table: '
                      + '; '.join(unknown) + '; switch refused, nothing changed')


def gate_path():
    return root() / 'launch.gate'


def take_gate(r):
    gate = read(gate_path())
    ctl = r['controller']
    if gate and gate.get('fid') != r['fid'] and alive(gate.get('pid'), gate.get('start')):
        raise Refused('another durable handover holds the launch gate (pid %s)' % gate.get('pid'))
    atomic(gate_path(), dict(home=r['home'], fid=r['fid'], pid=ctl['pid'], start=ctl['start']))


def release_gate(r):
    gate = read(gate_path())
    if gate and gate.get('fid') == r['fid']:
        os.unlink(gate_path())


def gate_wait(cwd):
    """fleet-session-wrap's call before every Claude launch."""
    waited, said = 0, False
    while True:
        gate = read(gate_path())
        if (not gate or Path(cwd).resolve() != Path(gate.get('home', '/')).resolve()
                or not alive(gate.get('pid'), gate.get('start'))):
            return 0
        if waited >= GATE_WAIT:
            print('fleet: the durable handover gate is still held after %ds; starting anyway' % waited)
            return 1
        if not said:
            print('fleet: waiting for a durable task handover in this HOME to settle…', flush=True)
            said = True
        time.sleep(1)
        waited += 1


def source_records(home, source_pid):
    """The records in HOME's table that this exact source process created."""
    start = proc_start(source_pid)
    store, _ = native_paths(home)
    return [r for r in tasks(read(store))
            if start and r.get('createdByPid') == int(source_pid) and r.get('createdByProcStart') == start]


def precheck_takeover(home, source_pid, version):
    """Read-only: may road 2 take the source's durable tasks? [] = nothing to take."""
    if not source_records(home, source_pid):
        return []
    return _takeover_checks(Path(home).resolve(), source_pid, version)[0]


def _takeover_checks(home, source_pid, version):
    store, lock = native_paths(home)
    start = proc_start(source_pid)
    if not start:
        raise Refused('the source process is gone; stage before it exits')
    source = dict(pid=int(source_pid), start=start)
    records = source_records(home, source_pid)
    if not records:
        raise ValueError('the source created no native durable task')
    if version not in SUPPORTED:
        raise Refused('native durable handover requires a verified Claude ' + '/'.join(SUPPORTED)
                      + ' (source is ' + str(version or 'unknown') + ')')
    kind, owner_ = holder(lock, source)
    if kind == 'other':
        raise Refused('native scheduler lock is held by another live process: ' + describe(owner_)
                      + '; switch refused, nothing changed')
    check_records(records, home, source, time.time())
    isolation(home, exclude=(source['pid'],))
    return records, source


def stage_takeover(fid, home, source_pid, session_id, version, controller):
    """Before the source exits: stage the records the source process created."""
    home = Path(home).resolve()
    records, source = _takeover_checks(home, source_pid, version)
    jobs = [job_for(r) for r in records]
    path = new_journal(fid, home, dict(records=records, source=source), session_id, version, jobs, 'fence')
    with locked(path) as r:
        r['controller'] = dict(pid=int(controller), start=proc_start(controller))
        save(path, r)
    return path


def takeover_plan(fid):
    """The Fleet loop plan a road-2 switch carries: the journal's staged jobs."""
    r = load(fid)
    plans = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))) / 'transfer-plans'
    plans.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = plans / (fid + '.takeover.json')
    atomic(path, dict(jobs=[{k: v for k, v in j.items() if k != 'next_run_at'} for j in r['jobs']]))
    return path


def _rewrite_without(r):
    """Plain read-modify-write: re-read right before the atomic rename, and only
    the staged records go."""
    store = Path(r['store'])
    for _ in range(5):
        before = store.read_bytes()
        current = json.loads(before)
        new = dict(current, tasks=[t for t in tasks(current) if r['records'].get(t['id']) != t])
        if store.read_bytes() != before:
            continue
        atomic(store, new, stat.S_IMODE(store.stat().st_mode))
        crash('table-written')
        return
    raise ValueError('the native task table kept changing; not withdrawing')


def takeover(r, path):
    """After the source exited: gate, isolation, write-ahead, rewrite, read back."""
    if _source_alive(r):
        raise Refused('the source process is still alive')
    take_gate(r)
    kind, owner_ = holder(r['lock'], r['source'])
    if kind == 'other':
        raise Refused('native scheduler lock is held by another live process: ' + describe(owner_))
    isolation(r['home'])
    current = table(r['store'])
    if any(current.get(i) != rec for i, rec in r['records'].items()):
        raise Refused('a staged native task changed since staging; not withdrawing')
    others = {i: t for i, t in current.items() if i not in r['records']}
    save(path, r, 'withdrawing')
    crash('withdrawing')
    _rewrite_without(r)
    after = table(r['store'])
    if set(after) & set(r['records']) or {i: after.get(i) for i in others} != others:
        raise ValueError('native task table readback after the withdrawal disagrees')
    try:
        isolation(r['home'])
    except Refused as error:
        r['attention'] = 'a Claude appeared during the withdrawal: ' + str(error)
    save(path, r, 'withdrawn')
    crash('withdrawn')


# --- the transfer controller -------------------------------------------------

def claim(fid, controller):
    """Before the source exits: the receipt is in and the controller owns the journal."""
    path = journal_path(fid)
    with locked(path) as r:
        if r['state'] == 'active':
            return   # an earlier switch already gave it to Fleet; it moves with the loop
        if r['road'] == 'fence':
            if r['state'] != 'staged':
                raise Refused('durable takeover is %s, not staged' % r['state'])
        elif r['state'] != 'withdrawn':
            raise Refused('durable handover is %s: the source has not confirmed its native '
                          'CronDelete; switch refused' % r['state'])
        else:
            _absent(r)
        r['controller'] = dict(pid=int(controller), start=proc_start(controller))
        r['deadline'] = time.time() + 1800
        save(path, r)


def handed(fid):
    """After the source exited: the native side has nothing left to run (road 2:
    after Fleet withdrew it, inside the isolation boundary)."""
    path = journal_path(fid)
    with locked(path) as r:
        if r['state'] == 'active':
            return
        if r['road'] == 'fence' and r['state'] == 'staged':
            takeover(r, path)
        if r['state'] != 'withdrawn':
            raise Refused('durable handover is %s, not withdrawn' % r['state'])
        if _source_alive(r):
            raise Refused('the source process is still alive')
        _absent(r)


def activate(fid, target):
    """The target (or the resumed source) is bound to the Fleet loop carrying the job."""
    path = journal_path(fid)
    with locked(path) as r:
        if r['state'] == 'active':
            return
        if r['state'] != 'withdrawn':
            raise Refused('durable handover is %s, not withdrawn' % r['state'])
        if _source_alive(r):
            raise Refused('the source process is still alive')
        _absent(r)
        r['target'] = target
        r.pop('attention', None)
        save(path, r, 'active')
        release_gate(r)


def abort(fid, reason='switch did not happen'):
    """Before activation. A still-running source is asked to take it back."""
    path = journal_path(fid)
    try:
        return _abort(path, reason)
    finally:
        r = read(path)
        if r:
            release_gate(r)


def _abort(path, reason):
    with locked(path) as r:
        state = r['state']
        if state in TERMINAL or state == 'restoring':
            return state
        if state == 'active':
            return state   # Fleet owns it; the loop that carries it decides
        present = {j['id'] for j in r['jobs']} & set(table(r['store']))
        if state == 'staged' or (state == 'withdrawing' and present == set(r['records'])):
            save(path, r, 'rolled_back', why=reason)   # the native record never left
            return 'rolled_back'
        if not _source_alive(r):
            # Gone with no native copy left: only a rollback that resumes the
            # source through the Fleet loop can own it now. Keep it, visibly.
            r['attention'] = ('source gone after its CronDelete; recover with the handoff\'s '
                              'resume-source.sh (the rollback takes the job into the Fleet loop)')
            save(path, r)
            return state
        save(path, r, 'restoring', why=reason)
        return 'restoring'


def gate(fid):
    """For Fleet's dispatch: deliver | wait | drop."""
    path = journal_path(fid)
    with locked(path) as r:
        if r['state'] in TERMINAL:
            return 'drop'
        if r['state'] != 'active':
            return 'wait'
        if {j['id'] for j in r['jobs']} & set(table(r['store'])):
            save(path, r, 'returned', why='record reappeared in the native table')
            return 'drop'
        return 'deliver'


def complete(fid, delivery=None):
    path = journal_path(fid)
    with locked(path) as r:
        if r['state'] == 'complete':
            return
        if r['state'] != 'active':
            raise Refused('durable handover is %s, not active' % r['state'])
        save(path, r, 'complete', delivery=delivery)


def recover(fid):
    """The quota tick's sweep: settle what the evidence settles, never guess.

    A staged / withdrawing journal whose record is still in the table and whose
    controller is gone (or whose claim deadline passed) is rolled back — native
    never lost it. A source that died between its CronDelete receipts and its
    CronList cannot list again: its receipts plus a table without the records
    stand in. Anything else that left the table is only marked for attention."""
    path = journal_path(fid)
    try:
        with locked(path, wait=False) as r:
            if r['state'] in TERMINAL or r['state'] in ('active', 'restoring'):
                return r['state']
            ctl = r.get('controller') or {}
            if alive(ctl.get('pid'), ctl.get('start')) and time.time() < r.get('deadline', 0):
                return r['state']
            ids = {j['id'] for j in r['jobs']}
            present = ids & set(table(r['store']))
            if r['state'] in ('staged', 'withdrawing') and present == ids:
                save(path, r, 'rolled_back', why='no transfer claimed it; native kept the task')
                release_gate(r)
                return 'rolled_back'
            if (r['state'] == 'withdrawing' and not present and not _source_alive(r)
                    and r.get('transcript') and _receipts(r, r['transcript'])[0] == ids):
                save(path, r, 'withdrawn', why='source died after its CronDelete receipts; table has none')
            note = ('controller gone with the native record withdrawn (%s) — recover with the handoff\'s '
                    'resume-source.sh: the rollback takes the job into the Fleet loop' % r['state'])
            if r.get('attention') != note:
                r['attention'] = note
                save(path, r)
            return r['state']
    except BlockingIOError:
        return 'busy'


def recover_all():
    out = []
    if root().is_dir():
        for path in sorted(root().glob('*-*-*-*-*.json')):
            try:
                out.append((path.stem, recover(path.stem)))
            except (OSError, ValueError) as error:
                out.append((path.stem, 'error: ' + str(error)))
    return out


def status(fid):
    r = read(journal_path(fid))
    if r is None:
        return None
    return dict(state=r['state'], road=r.get('road'), owner=owner(r), jobs=[j['id'] for j in r['jobs']],
                attention=r.get('attention'), updated_at=r.get('updated_at'))


def main(argv):
    action, *args = argv
    if action == 'status':
        print(json.dumps(status(args[0]), ensure_ascii=False))
    elif action == 'recover-all':
        for fid, state in recover_all():
            print(fid, state)
    elif action == 'begin':
        begin(args[0])
    elif action == 'confirm':
        confirm(args[0], args[1])
    elif action == 'confirm-restored':
        confirm_restored(args[0], args[1])
    elif action == 'claim':
        claim(args[0], int(args[1]))
    elif action == 'handed':
        handed(args[0])
    elif action == 'stage-takeover':
        # <fid> <home> <source pid> <source session> <source transcript> <controller pid>
        if not source_records(args[1], int(args[2])):
            return 0
        stage_takeover(args[0], args[1], int(args[2]), args[3], transcript_version(args[4]), int(args[5]))
        print(takeover_plan(args[0]))
    elif action == 'gate-wait':
        return gate_wait(args[0])
    elif action == 'activate':
        activate(args[0], json.loads(args[1]))
    elif action == 'abort':
        state = abort(args[0], args[1] if len(args) > 1 else 'switch did not happen')
        print(state)
        if state == 'restoring':
            print(restore_request(load(args[0])))
    else:
        raise ValueError('unknown durable handover action')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except Refused as error:
        print('fleet-transfer: durable: ' + str(error), file=sys.stderr)
        sys.exit(3)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('fleet-transfer: durable: ' + str(error), file=sys.stderr)
        sys.exit(1)
