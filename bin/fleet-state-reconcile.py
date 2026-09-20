#!/usr/bin/env python3
"""Reconcile stale `working` window states against native agent truth (issue #806).

`@claude_state` is written on hook edges and never re-read: a turn that ends
without a Stop hook (a model-cap or subscription wall, a kill, a transfer's
/exit, a dropped connection) pins the window at `working` forever. The spinner's
activity demoter (#101) cannot see an idle Claude TUI that repaints its footer
every minute, so the fact has to come from the agent itself:

  * Claude Code keeps ~/.claude/sessions/<pid>.json (status busy|idle|shell,
    statusUpdatedAt, tmux target, pid, procStart) — written by the TUI, no hook.
  * A bound Codex worker reports thread status over its private app-server RPC.

A `working` window whose agent has been natively idle since AFTER the working
stamp, for at least FLEET_STATE_IDLE_SECS, is demoted to `done` and handed to the
classifier to refine (done|needs|looping). A window with no agent process under
its pane at all is demoted with reason `exited`. This pass only demotes; it never
promotes, never touches needs/blocked, panels, or a window in a sleep transition.

Usage: fleet-state-reconcile.py [--dry-run] [--cache-dir DIR] [--idle-secs N]
                                [--exited-secs N] -- <fleet-session>...
Exit status is always 0; problems go to stderr and the heartbeat's skipped= field.
"""
import argparse
import calendar
import json
import os
import runpy
import subprocess
import sys
import time
from pathlib import Path

BIN = Path(__file__).absolute().parent
AGENT_COMMS = ('claude', 'codex', 'codex-real')
INPUT = runpy.run_path(str(BIN / 'fleet-input.py'))


def prompt_idle(session, pane, agent):
    """True only when the pane provably shows an empty prompt (issue A3).

    fleet-input.py distinguishes an empty prompt from a busy/streaming one and
    from an unrecognized frame, so this never mistakes the footer repaint that
    keeps window_activity fresh for real work. Fail closed: any doubt is False.
    """
    try:
        return INPUT['snapshot'](session, pane, agent=agent).get('state') == 'empty'
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def tm(session, *args, timeout=5):
    return subprocess.check_output(['tmux', '-L', session, *args], text=True,
                                   stderr=subprocess.DEVNULL, timeout=timeout).rstrip('\n')


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (ProcessLookupError, ValueError, TypeError):
        return False
    except PermissionError:
        return True


LSTART = '%a %b %d %H:%M:%S %Y'


def process_start(pid):
    """Epoch of the process's start per ps (local time), 0 when unreadable."""
    try:
        text = subprocess.check_output(['ps', '-p', str(pid), '-o', 'lstart='], text=True,
                                       stderr=subprocess.DEVNULL, timeout=5)
        return time.mktime(time.strptime(' '.join(text.split()), LSTART))
    except (subprocess.SubprocessError, OSError, ValueError, OverflowError):
        return 0


def record_start(record):
    """Epoch the registry recorded for its process: startedAt (ms), else procStart (UTC)."""
    try:
        ms = int(record.get('startedAt', 0))
        if ms > 0:
            return ms / 1000
    except (TypeError, ValueError):
        pass
    start = record.get('procStart')
    if isinstance(start, str) and start:
        try:
            return calendar.timegm(time.strptime(' '.join(start.split()), LSTART))
        except (ValueError, OverflowError):
            return 0
    return 0


def process_tree():
    rows = {}
    try:
        out = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True, timeout=10)
    except (subprocess.SubprocessError, OSError):
        return rows
    for line in out.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            rows[int(fields[0])] = (int(fields[1]), Path(fields[2]).name.lstrip('-'))
    return rows


def has_agent_process(rows, root):
    # The pane process itself may be the agent (a bare `exec codex`), not only a child.
    if rows.get(int(root), (0, ''))[1] in AGENT_COMMS:
        return True
    pending = [int(root)]; seen = set()
    while pending:
        parent = pending.pop()
        if parent in seen:
            continue
        seen.add(parent)
        for pid, (pp, comm) in rows.items():
            if pp == parent and pid != parent:
                if comm in AGENT_COMMS:
                    return True
                pending.append(pid)
    return False


def registry(directory):
    """{tmux target: record} for every live registry record that names its pane."""
    found = {}
    try:
        entries = list(Path(directory).glob('*.json'))
    except OSError:
        return found
    for path in entries:
        try:
            record = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue
        target = record.get('tmux') if isinstance(record, dict) else None
        if not target or not str(record.get('pid', '')).isdigit():
            continue
        found[target] = record
    return found


def claude_verdict(record, state_ts, now, idle_secs):
    """('idle', idle_since) when the registry proves no turn is running.

    Both the idle status and the working stamp must be at least idle_secs old: a
    stamp newer than the idle status is either a turn the TUI has not yet marked
    busy (the stamp is fresh) or the classifier promoting a screen it misread
    after Claude had already stopped (the stamp is old, the TUI still idle).
    """
    pid = int(record['pid'])
    if not alive(pid):
        return ('gone', 0)
    recorded, actual = record_start(record), process_start(pid)
    if recorded and actual and abs(actual - recorded) > 120:
        return ('gone', 0)          # the pid was reused; the record is not this process
    if record.get('status') != 'idle':
        return ('busy', 0)
    try:
        since = int(record.get('statusUpdatedAt', 0)) / 1000
    except (TypeError, ValueError):
        return ('unknown', 0)
    if now - since < idle_secs or now - state_ts < idle_secs:
        return ('fresh', since)
    return ('idle', since)


def codex_idle(identity, state_ts):
    """(True, completed_at) when the bound thread is idle with a completed last turn."""
    remote = identity.get('remote', '')
    sid = identity.get('session_id', '')
    if not remote.startswith('unix:///') or not sid:
        return (False, 0)
    client = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client'](remote, timeout=3)
    try:
        thread = client.call('thread/read', {'threadId': sid, 'includeTurns': True})['thread']
    finally:
        client.close()
    if thread.get('id') != sid or thread.get('status', {}).get('type') != 'idle':
        return (False, 0)
    turns = thread.get('turns') or []
    if not turns or turns[-1].get('status') != 'completed':
        return (False, 0)
    completed = turns[-1].get('completedAt')
    if type(completed) not in (int, float) or completed <= 0:
        return (False, 0)
    return (True, completed)


def window_rows(session):
    rows = []
    for wid in tm(session, 'list-windows', '-t', session, '-F', '#{window_id}').splitlines():
        if not wid:
            continue
        fields = tm(session, 'display-message', '-p', '-t', wid,
                    '#{pane_id}|#{pane_pid}|#{pane_dead}|#{@claude_state}|#{@claude_state_ts}|'
                    '#{@cc_agent}|#{@worker_lifecycle}|#{@hub}|#{@issue}|#{@raw}|#{window_name}').split('|', 10)
        if len(fields) != 11:
            continue
        rows.append(dict(zip(('pane', 'pane_pid', 'dead', 'state', 'state_ts', 'agent',
                              'lifecycle', 'hub', 'issue', 'raw', 'name'), fields), window=wid))
    return rows


def demote(session, row, reason, dry, log):
    stamp = str(int(time.time()))
    line = '%s  %-10s working -> done (%s)' % (time.strftime('%H:%M:%S'), session + ':' + row['window'], reason)
    if dry:
        print('would demote ' + line)
        return True
    # One server-side command: re-check the state so a UserPromptSubmit that landed
    # between our read and this write is never overwritten by a stale verdict.
    tm(session, 'if-shell', '-F', '-t', row['pane'], '#{==:#{@claude_state},working}',
       'set-option -w -t %s @claude_state done ; set-option -w -t %s @claude_needs "" ; '
       'set-option -w -t %s @claude_state_ts %s' % (row['window'], row['window'], row['window'], stamp))
    if tm(session, 'display-message', '-p', '-t', row['window'], '#{@claude_state}') != 'done':
        return False
    with open(log, 'a') as out:
        out.write(line + '\n')
    # Refine done|needs|looping out of band, exactly as the spinner's demote does.
    env = dict(os.environ, CLASSIFY_SOCK=session)
    subprocess.run(['sh', '-c', '"$0" "$@" >/dev/null 2>&1 </dev/null &', 'bash',
                    str(BIN / 'classify-sessions.sh'), '--window', row['window']], env=env, timeout=10)
    return True


def trim(log, keep=300):
    try:
        lines = Path(log).read_text().splitlines()
        if len(lines) > keep:
            Path(log).write_text('\n'.join(lines[-keep:]) + '\n')
    except OSError:
        pass


def reconcile(session, args, records, rows, now, stats):
    for row in window_rows(session):
        if row['hub'] == '1' or row['lifecycle'] or row['state'] != 'working':
            continue
        if not (row['issue'].isdigit() or row['raw'] == '1'):
            continue
        stats['working'] += 1
        try:
            state_ts = float(row['state_ts'] or 0)
        except ValueError:
            state_ts = 0
        target = '%s:%s.%s' % (session, row['window'], row['pane'])
        reason = ''
        record = records.get(target)
        if record is not None:
            verdict, since = claude_verdict(record, state_ts, now, args.idle_secs)
            if verdict == 'idle':
                reason = 'native idle %ds; stop-hook missed' % (now - since)
            elif verdict != 'gone':
                continue
        if not reason and row['agent'] == 'codex':
            try:
                identity = json.loads(tm(session, 'display-message', '-p', '-t', row['window'], '#{@codex_identity}') or '{}')
                idle, completed = codex_idle(identity, state_ts)
            except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError) as exc:
                stats['skipped'].append('%s:%s codex %s' % (session, row['window'], type(exc).__name__))
                continue
            if idle and now - completed >= args.idle_secs and now - state_ts >= args.idle_secs:
                reason = 'codex thread idle %ds; stop-hook missed' % (now - completed)
            elif identity.get('remote', '').startswith('unix:///'):
                continue
        if not reason:
            # No usable native record. A pane with no agent under it and a stamp
            # old enough to rule out a launch in progress is provably not working.
            exited = row['dead'] == '1' or (row['pane_pid'].isdigit() and not has_agent_process(rows, row['pane_pid']))
            if exited and now - state_ts >= args.exited_secs:
                reason = 'exited; no agent process under the pane for %ds' % (now - state_ts)
            elif (not exited and record is None and row['agent'] != 'codex'
                  and now - state_ts >= args.idle_secs and prompt_idle(session, row['pane'], row['agent'])):
                # A live Claude process with no registry record (a build that does
                # not write ~/.claude/sessions, or a cleaned record): the screen is
                # the only truth left. An empty prompt past the grace is a finished
                # turn (issue A3) — never the footer repaint window_activity trusts.
                reason = 'prompt idle %ds; no native record for the live process' % (now - state_ts)
            else:
                continue
        if demote(session, row, reason, args.dry_run, args.log):
            stats['demoted'] += 1


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--cache-dir', default=os.path.join(os.environ.get('TMPDIR', '/tmp'), '.claude-dash', 'global'))
    p.add_argument('--registry', default=os.environ.get('FLEET_CC_SESSIONS_DIR', os.path.expanduser('~/.claude/sessions')))
    p.add_argument('--idle-secs', type=int, default=int(os.environ.get('FLEET_STATE_IDLE_SECS') or 30))
    p.add_argument('--exited-secs', type=int, default=120)
    p.add_argument('--log', default=str(BIN.parent / 'logs' / 'reconcile.log'))
    p.add_argument('sessions', nargs='*')
    args = p.parse_args()
    if args.idle_secs < 1:
        return 0
    started = time.time(); now = started
    stats = {'windows': 0, 'working': 0, 'demoted': 0, 'skipped': []}
    records = registry(args.registry)
    rows = process_tree()
    Path(args.log).parent.mkdir(parents=True, exist_ok=True)
    for session in args.sessions:
        try:
            stats['windows'] += len(tm(session, 'list-windows', '-t', session, '-F', '#{window_id}').splitlines())
            reconcile(session, args, records, rows, now, stats)
        except (subprocess.SubprocessError, OSError) as exc:
            stats['skipped'].append('%s %s' % (session, type(exc).__name__))
    trim(args.log)
    if not args.dry_run:
        try:
            Path(args.cache_dir).mkdir(parents=True, exist_ok=True)
            hb = Path(args.cache_dir) / 'reconcile.heartbeat'
            hb.write_text('at=%d\nwindows=%d\nworking=%d\ndemoted=%d\ndur=%d\nskipped=%s\n' % (
                int(time.time()), stats['windows'], stats['working'], stats['demoted'],
                int(time.time() - started), ' '.join(stats['skipped'])))
        except OSError as exc:
            print('fleet-state-reconcile: heartbeat not written: %s' % exc, file=sys.stderr)
    if stats['skipped']:
        print('fleet-state-reconcile: skipped ' + ', '.join(stats['skipped']), file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
