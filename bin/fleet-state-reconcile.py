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

When the signals contradict each other the pass says so instead of guessing
(issue #1270): a `working` hook stamp older than FLEET_HOOK_TRUST_SECS (15) on a
window tmux has seen silent for more than FLEET_RUNG_TMUX_IDLE_SECS (10), while
the registry has a verdict, writes one `rung_health window=@N hook=working
tmux_idle=Ns registry=<idle|gone|busy>` line to the log and takes the higher
rung's word — registry idle/gone demotes at once, registry busy keeps `working`.
Each contradiction is logged once while it lasts (cache-dir/reconcile.rung);
fleet-doctor's `state` line counts them.

Two things a long FLEET TOOL CALL taught it (issue #1880, EPIC #2074 C4): a
registry record names the session its Claude started under, which may be a
viewer's grouped `<fleet>@view-<id>` session (#1489) — the lookup strips that, so
a `busy` record is found and outranks the screen; and a window whose fleet MCP
server (fleet-mcp.py) still runs a tool as its child is work, never demoted,
whatever an absent record or an empty input line say (`kept working …` in the
log, `kept=` in the heartbeat).

Which source said it (issue #2537, EPIC #2535 C2): @claude_state has one PRIMARY
source, the agent's own OSC 7501 report (@agent_status, @agent_status_ts —
bin/fleet-status-7501.py); the hooks and every guess — this pass included — only
speak while it is absent (fleet_primary_fresh: silent for FLEET_STATE_PRIMARY_SECS,
120). A `working` window whose agent spoke within that window is never demoted
here. Every pass also writes down where each agent window's state came from
(@claude_state_src: 7501 | hook | classifier | carried | wrapper, '' = unlabelled)
into cache-dir/reconcile.sources (one row per window) and the heartbeat's
`src=` / `primary=` (Claude windows whose state the agent said itself, of all
live Claude windows) — fleet-doctor's `state` row prints it as the primary
source's coverage. Each log line carries a `source=` column.

Usage: fleet-state-reconcile.py [--dry-run] [--cache-dir DIR] [--idle-secs N]
                                [--exited-secs N] [--hook-trust-secs N]
                                [--tmux-idle-secs N] -- <fleet-session>...
Exit status is always 0; problems go to stderr and the heartbeat's skipped= field.
"""
import argparse
import calendar
import json
import os
import re
import runpy
import subprocess
import sys
import time
from pathlib import Path

PRIMARY_SECS_DEFAULT = 120

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


def registry_target(target):
    """The record's tmux target under the FLEET's session name (issue #1880).

    Claude Code records the session name of the client it started under. A shell
    or proxy viewer attaches a grouped `<fleet>@view-<id>` session of its own
    (issue #1489), so a window opened while one was active is recorded as
    `<fleet>@view-<id>:@N.%P` — and the lookup by `<fleet>:@N.%P` missed it. The
    miss was silent: the window fell to the no-record screen fallback, which read
    a long tool call's empty input line as an idle prompt and demoted a `working`
    window mid-call (2026-10-07: 84 s into a `pr_verdict --wait`).
    """
    return re.sub(r'^([^:]*?)@view-[^:]*:', r'\1:', target)


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
        found[registry_target(str(target))] = record
    return found


def tool_call_in_flight(session, window):
    """A fleet tool call still running under the window (issue #1880).

    fleet_window_tool_busy (bin/fleet-lib.sh): the fleet's MCP server runs every
    tool as a subprocess, so a fleet-mcp.py under the pane with a live child is a
    call in flight — an `await`, a `pr_verdict --wait`, in the foreground or moved
    to a background task. The agent is silent for its whole length (no hook stamp,
    an empty input line), which is exactly what every rule below reads as idle;
    it is work, and is never demoted. The lib absent ⇒ False (decided as before).
    """
    lib = BIN / 'fleet-lib.sh'
    if not lib.is_file():
        return False
    try:
        return subprocess.run(['bash', '-c', '. "$1" >/dev/null 2>&1; TMUX=; fleet_window_tool_busy "$2" "$3"',
                               '_', str(lib), session, window], stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def kept(session, row, reason, log):
    """Log a `working` window the rules would have demoted but a fleet tool call holds."""
    line = '%s  %-10s kept working (fleet tool call in flight; was: %s)' % (
        time.strftime('%H:%M:%S'), session + ':' + row['window'], reason)
    try:
        with open(log, 'a') as out:
            out.write(line + '\n')
    except OSError:
        pass


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
                    '#{@cc_agent}|#{@worker_lifecycle}|#{@hub}|#{@issue}|#{@raw}|#{window_activity}|'
                    '#{@claude_state_src}|#{@agent_status_ts}|#{window_name}').split('|', 13)
        if len(fields) != 14:
            continue
        rows.append(dict(zip(('pane', 'pane_pid', 'dead', 'state', 'state_ts', 'agent',
                              'lifecycle', 'hub', 'issue', 'raw', 'activity', 'src', 'status_ts',
                              'name'), fields), window=wid))
    return rows


def primary_fresh(session, row, now, secs):
    """The agent's own report is fresh: spoken within `secs`, its last word not
    the relay's `exited` — the Python half of fleet_primary_fresh (issue #2537)."""
    if secs < 1 or not row.get('status_ts', '').isdigit():
        return False
    if now - int(row['status_ts']) >= secs:
        return False
    try:
        status = tm(session, 'display-message', '-p', '-t', row['window'], '#{@agent_status}')
    except (subprocess.SubprocessError, OSError):
        return False
    return '"state":"exited"' not in status


def sources(session, rows, now, secs, stats):
    """Tally where every agent window's state came from (issue #2537)."""
    for row in rows:
        if row['hub'] == '1' or not (row['issue'].isdigit() or row['raw'] == '1'):
            continue
        if row['state'] in ('', 'exited'):
            continue
        src = row['src'] or '-'
        stats['src'][src] = stats['src'].get(src, 0) + 1
        fresh = row.get('status_ts', '').isdigit() and now - int(row['status_ts']) < secs
        age = (now - int(row['status_ts'])) if row.get('status_ts', '').isdigit() else -1
        stats['rows'].append('%s\t%s\t%s\t%s\t%s\t%s\t%s' % (
            session, row['window'], row['name'], row['state'], src,
            'fresh' if fresh else ('stale' if age >= 0 else 'none'), age))
        if row['agent'] != 'codex':
            stats['claude'] += 1
            if src == '7501':
                stats['primary'] += 1


def demote(session, row, reason, dry, log):
    stamp = str(int(time.time()))
    line = '%s  %-10s working -> done (%s) source=%s' % (time.strftime('%H:%M:%S'), session + ':' + row['window'],
                                                          reason, row.get('src') or '-')
    if dry:
        print('would demote ' + line)
        return True
    # One server-side command: re-check the state so a UserPromptSubmit that landed
    # between our read and this write is never overwritten by a stale verdict.
    tm(session, 'if-shell', '-F', '-t', row['pane'], '#{==:#{@claude_state},working}',
       'set-option -w -t %s @claude_state done ; set-option -w -t %s @claude_needs "" ; '
       'set-option -w -t %s @claude_state_ts %s ; set-option -w -t %s @claude_state_src classifier'
       % (row['window'], row['window'], row['window'], stamp, row['window']))
    if tm(session, 'display-message', '-p', '-t', row['window'], '#{@claude_state}') != 'done':
        return False
    with open(log, 'a') as out:
        out.write(line + '\n')
    # Refine done|needs|looping out of band, exactly as the spinner's demote does.
    env = dict(os.environ, CLASSIFY_SOCK=session)
    subprocess.run(['sh', '-c', '"$0" "$@" >/dev/null 2>&1 </dev/null &', 'bash',
                    str(BIN / 'classify-sessions.sh'), '--window', row['window']], env=env, timeout=10)
    return True


def contested(row, record, verdict, state_ts, now, args, rows):
    """The registry's word when the hook's `working` is contradicted, else None (issue #1270).

    Signals rank ① the session registry ② the hook stamp (trusted for
    hook_trust_secs) ③ the visible prompt ④ tmux window_activity. A contradiction
    is a `working` stamp past its trust window on a window tmux has seen silent for
    more than tmux_idle_secs — a live Claude turn animates its spinner every second
    — while the registry has a verdict: `idle` and `gone` (no process, none under
    the pane) outrank the hook and demote now, without the idle grace; `busy`
    outranks tmux and keeps `working`. Every other window is decided exactly as
    before this check existed.
    """
    if record is None or args.tmux_idle_secs < 1:
        return None
    try:
        tmux_idle = now - float(row['activity'])
    except ValueError:
        return None
    if now - state_ts < args.hook_trust_secs or tmux_idle <= args.tmux_idle_secs:
        return None
    if verdict in ('idle', 'fresh'):
        return 'idle', int(tmux_idle)
    if verdict == 'busy':
        return record.get('status') or 'busy', int(tmux_idle)
    if verdict == 'gone' and (row['dead'] == '1' or (row['pane_pid'].isdigit()
                                                     and not has_agent_process(rows, row['pane_pid']))):
        return 'gone', int(tmux_idle)
    return None


def rung_health(session, row, registry_says, tmux_idle, state_ts, now, args, stats):
    """Log one `rung_health` event per (window, registry verdict) while it lasts."""
    key = '%s:%s:%s' % (session, row['window'], registry_says)
    stats['contested'] += 1
    stats['seen'][key] = stats['seen_before'].get(key, int(now))
    if key in stats['seen_before']:
        return
    line = '%s  rung_health window=%s hook=working tmux_idle=%ds registry=%s hook_age=%ds session=%s source=%s -> %s' % (
        time.strftime('%H:%M:%S'), row['window'], tmux_idle, registry_says, now - state_ts, session,
        row.get('src') or '-', 'working' if registry_says not in ('idle', 'gone') else 'done')
    stats['rung_health'] += 1
    if args.dry_run:
        print('would log ' + line)
        return
    with open(args.log, 'a') as out:
        out.write(line + '\n')


def trim(log, keep=300):
    try:
        lines = Path(log).read_text().splitlines()
        if len(lines) > keep:
            Path(log).write_text('\n'.join(lines[-keep:]) + '\n')
    except OSError:
        pass


def reconcile(session, args, records, rows, now, stats):
    wins = window_rows(session)
    sources(session, wins, now, args.primary_secs, stats)
    for row in wins:
        if row['hub'] == '1' or row['lifecycle'] or row['state'] != 'working':
            continue
        if not (row['issue'].isdigit() or row['raw'] == '1'):
            continue
        stats['working'] += 1
        # The agent said `working` itself, and recently: nothing below outranks it.
        if primary_fresh(session, row, now, args.primary_secs):
            stats['primary_kept'] += 1
            continue
        try:
            state_ts = float(row['state_ts'] or 0)
        except ValueError:
            state_ts = 0
        target = '%s:%s.%s' % (session, row['window'], row['pane'])
        reason = ''
        record = records.get(target)
        if record is not None:
            verdict, since = claude_verdict(record, state_ts, now, args.idle_secs)
            clash = contested(row, record, verdict, state_ts, now, args, rows)
            if clash:
                registry_says, tmux_idle = clash
                rung_health(session, row, registry_says, tmux_idle, state_ts, now, args, stats)
                if registry_says not in ('idle', 'gone'):
                    continue        # the registry says a turn runs: it outranks a silent pane
                reason = 'rung_health: registry %s, hook stale %ds, tmux idle %ds' % (registry_says, now - state_ts, tmux_idle)
                if tool_call_in_flight(session, row['window']):
                    kept(session, row, reason, args.log); stats['kept'] += 1
                    continue
                if demote(session, row, reason, args.dry_run, args.log):
                    stats['demoted'] += 1
                continue
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
        # Whatever the rule above read — a native idle, an empty prompt, a pid that
        # went away — a fleet tool call still running under the pane is work (#1880).
        if tool_call_in_flight(session, row['window']):
            kept(session, row, reason, args.log); stats['kept'] += 1
            continue
        if demote(session, row, reason, args.dry_run, args.log):
            stats['demoted'] += 1


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--cache-dir', default=os.path.join(os.environ.get('TMPDIR') or f'/tmp/claude-fleet-{os.getuid()}', '.claude-dash', 'global'))
    p.add_argument('--registry', default=os.environ.get('FLEET_CC_SESSIONS_DIR', os.path.expanduser('~/.claude/sessions')))
    p.add_argument('--idle-secs', type=int, default=int(os.environ.get('FLEET_STATE_IDLE_SECS') or 30))
    p.add_argument('--exited-secs', type=int, default=120)
    p.add_argument('--hook-trust-secs', type=int, default=int(os.environ.get('FLEET_HOOK_TRUST_SECS') or 15))
    p.add_argument('--tmux-idle-secs', type=int, default=int(os.environ.get('FLEET_RUNG_TMUX_IDLE_SECS') or 10))
    p.add_argument('--primary-secs', type=int,
                   default=int(os.environ.get('FLEET_STATE_PRIMARY_SECS') or PRIMARY_SECS_DEFAULT))
    p.add_argument('--log', default=str(BIN.parent / 'logs' / 'reconcile.log'))
    p.add_argument('sessions', nargs='*')
    args = p.parse_args()
    if args.idle_secs < 1:
        return 0
    started = time.time(); now = started
    stats = {'windows': 0, 'working': 0, 'demoted': 0, 'kept': 0, 'skipped': [],
             'contested': 0, 'rung_health': 0, 'seen': {}, 'seen_before': {},
             'src': {}, 'rows': [], 'claude': 0, 'primary': 0, 'primary_kept': 0}
    seen_path = Path(args.cache_dir) / 'reconcile.rung'
    try:
        stats['seen_before'] = json.loads(seen_path.read_text())
        if not isinstance(stats['seen_before'], dict):
            stats['seen_before'] = {}
    except (OSError, ValueError):
        pass
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
            hb.write_text('at=%d\nwindows=%d\nworking=%d\ndemoted=%d\ncontested=%d\nrung_health=%d\ndur=%d\nskipped=%s\nkept=%d\n'
                          'src=%s\nprimary=%d/%d\nprimary_kept=%d\n' % (
                int(time.time()), stats['windows'], stats['working'], stats['demoted'], stats['contested'],
                stats['rung_health'], int(time.time() - started), ' '.join(stats['skipped']), stats['kept'],
                ','.join('%s:%d' % kv for kv in sorted(stats['src'].items())), stats['primary'], stats['claude'],
                stats['primary_kept']))
            src_tmp = Path(args.cache_dir) / 'reconcile.sources.tmp'
            src_tmp.write_text('# session\twindow\tname\tstate\tsource\t7501\t7501_age\n'
                               + ''.join(r + '\n' for r in stats['rows']))
            os.replace(src_tmp, Path(args.cache_dir) / 'reconcile.sources')
            tmp = seen_path.with_suffix('.tmp')
            tmp.write_text(json.dumps(stats['seen']))
            os.replace(tmp, seen_path)
        except OSError as exc:
            print('fleet-state-reconcile: heartbeat not written: %s' % exc, file=sys.stderr)
    if stats['skipped']:
        print('fleet-state-reconcile: skipped ' + ', '.join(stats['skipped']), file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
