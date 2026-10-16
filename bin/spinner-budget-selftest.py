#!/usr/bin/env python3
"""Count the complete default spinner, including startup and all maintenance.

Private HOME/socket; no live lease or daemon stamps. PATH entry wrappers record
PID/PPID, not samples. Direct oracle execs are recorded too; interpreter exec
chains count once per PID. Fixture setup/probes and builtin-only shell forks are
outside the external-process budget, but inside each entry's wall clock. Each
fixture observes 42 real seconds, including the default 20/40s fresh checks and
30s daemon-watch; idle and maintenance are separate BREAK-IT execution slices.
Startup is a fixed cost (at most three processes). Subsequent processes must be
the one fresh ps at each due 20s observation: the original 60s reference window
contains two such observations, so startup + 2 * cost_per_observation stays <=5.
Protocol read/query counts include startup and scale down to floor(60*42/60)=42.
Neither counter changes production periods or excludes work from entry timing.
"""
import argparse
import collections
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import tempfile
import time

BIN = Path(__file__).resolve().parent
OBSERVE_SECONDS = 42
REFERENCE_SECONDS = 60
STARTUP_LIMIT = 3
PERIODS = dict(stuck_check=10, degen_check=15, needs_check=20,
               hb_stamp=20, daemon_watch=30)


def due_times(period, seconds, initial=False):
    return list(range(0 if initial else period, seconds, period))


def check_costs(fixture, commands, checks, read_query):
    """Fixed launch cost plus unchanged per-maintenance-event cost; no free execs."""
    startup = [row for row in commands if row[0] < min(PERIODS.values())]
    recurring = [row for row in commands if row not in startup]
    assert len(startup) <= STARTUP_LIMIT, ('startup processes', startup)
    needs = checks['needs_check']
    observed = [sum(at - .1 <= row[0] <= at + 2 for row in recurring) for at in needs]
    assert sum(observed) == len(recurring), ('process outside a maintenance observation', recurring, needs)
    assert all(row[3] == 'ps' for row in recurring), ('unexpected recurring process', recurring)
    assert all(count <= 1 for count in observed), ('process cost per fresh observation', observed)
    if fixture == 'maintenance':
        assert observed == [1, 1], ('both default safety observations must be fresh', observed)
    else:
        assert observed == [0, 0], ('idle fixture unexpectedly launched maintenance processes', observed)
    reference_checks = len(due_times(PERIODS['needs_check'], REFERENCE_SECONDS))
    projected = len(startup) + reference_checks * max(observed, default=0)
    assert projected <= 5, ('original startup + reference maintenance budget', projected)
    query_limit = 60 * OBSERVE_SECONDS // REFERENCE_SECONDS
    assert read_query <= query_limit, ('read/query budget including startup', read_query, query_limit)
    return dict(observation_seconds=OBSERVE_SECONDS, startup_processes=len(startup),
                startup_limit=STARTUP_LIMIT, processes_per_observation=observed,
                reference_seconds=REFERENCE_SECONDS, reference_observations=reference_checks,
                projected_reference_processes=projected, reference_process_limit=5,
                protocol_read_query=read_query, protocol_read_query_limit=query_limit)


def audit(fixture, output):
    fixture_start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='spinbudget.', dir='/tmp') as tmp:
        root = Path(tmp)
        for directory in ('bin', 'logs', 'home', 'conf/fleets/test', 'tmp', 'shim'):
            (root / directory).mkdir(parents=True)
        (root / 'conf/fleets/test/conf').touch()
        # Copy scripts: even paths derived from __file__ must stay in the sandbox.
        for source in BIN.iterdir():
            if source.is_file():
                shutil.copy2(source, root / 'bin' / source.name)
        (root / 'bin/fleet-client-where.sh').write_text(
            '#!/bin/sh\nprintf \'{"state":"none"}\\n\'\n')
        # Record every protocol command in the sandbox, including the initial
        # argv command list. This adds no process or timing/behaviour override.
        transport = root / 'bin/fleet-render-watch.py'
        source = transport.read_text()
        source = source.replace('        self.proc = subprocess.Popen(args,',
            "        initial_commands = [[]]\n"
            "        for arg in args[4:]:\n"
            "            if arg == ';': initial_commands.append([])\n"
            "            else: initial_commands[-1].append(arg)\n"
            "        for cmd in initial_commands:\n"
            "            print('spinner-protocol ' + json.dumps(cmd), file=sys.stderr, flush=True)\n"
            '        self.proc = subprocess.Popen(args,')
        source = source.replace("        line = ' ; '.join",
            "        for cmd in commands:\n"
            "            print('spinner-protocol ' + json.dumps(cmd), file=sys.stderr, flush=True)\n"
            "        line = ' ; '.join")
        transport.write_text(source)
        fifo = root / 'execs'
        os.mkfifo(fifo)
        fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
        seen = set()
        for directory in os.get_exec_path():
            try:
                entries = list(Path(directory).iterdir())
            except OSError:
                continue
            for source in entries:
                try:
                    executable = source.is_file() and os.access(source, os.X_OK)
                except OSError:
                    continue
                if source.name in seen or not executable:
                    continue
                seen.add(source.name)
                wrapper = root / 'shim' / source.name
                wrapper.write_text('#!/bin/sh\nprintf "%s %s %s\\n" "$$" "$PPID" '
                                   + shlex.quote(source.name) + ' >> ' + shlex.quote(str(fifo))
                                   + '\nexec ' + shlex.quote(str(source)) + ' "$@"\n')
                wrapper.chmod(0o755)
        oracle = root / 'bin/fleet-pending-tool.sh'
        real_oracle = root / 'bin/.oracle-real.sh'
        oracle.rename(real_oracle)
        oracle.write_text('#!/bin/sh\nprintf "%s %s oracle\\n" "$$" "$PPID" >> '
                          + shlex.quote(str(fifo)) + '\nexec '
                          + shlex.quote(str(real_oracle)) + ' "$@"\n')
        oracle.chmod(0o755)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('FLEET_', 'CCQUOTA_', 'CLAUDE_', 'SPIN_'))
               and key not in ('TMUX', 'TMUX_PANE')}
        env.update(HOME=str(root / 'home'), FLEET_CONF_DIR=str(root / 'conf'),
                   TMUX_TMPDIR=tmp, TMPDIR=str(root / 'tmp'),
                   PATH=str(root / 'shim') + ':' + os.environ['PATH'],
                   PS4='+${SECONDS} ${BASH_SUBSHELL} ', SPIN_TRACE='1')
        tmux = shutil.which('tmux')

        def tm(*args):
            return subprocess.check_output([tmux, '-L', 'test', *args], env=env,
                                           text=True, stderr=subprocess.DEVNULL).strip()

        proc = None
        try:
            tm('-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-n', 'work', 'sleep 180')
            panes = 1
            if fixture == 'maintenance':
                tm('set-window-option', '-t', 'test:work', '@claude_state', 'working')
                tm('new-window', '-d', '-t', 'test', '-n', 'needs', 'sleep 180')
                tm('set-window-option', '-t', 'test:needs', '@claude_state', 'needs',
                   ';', 'set-window-option', '-t', 'test:needs', '@claude_needs', 'perm',
                   ';', 'set-window-option', '-t', 'test:needs', '@claude_state_ts',
                   str(int(time.time()) - 600))
                panes = 2
            ready = time.monotonic() + 10
            while tm('list-panes', '-a', '-F', '#{pane_current_command}').splitlines() != ['sleep'] * panes:
                if time.monotonic() > ready:
                    raise AssertionError('fixture panes not ready')
                time.sleep(.05)
            while True:
                try:
                    if not os.read(fd, 65536):
                        break
                except BlockingIOError:
                    break
            assert not tm('list-clients'), 'must be unwatched'
            start = time.monotonic()
            proc = subprocess.Popen(['/bin/sh', '-x', str(root / 'bin/tmux-spinner.sh')],
                                    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                    start_new_session=True)
            os.set_blocking(proc.stderr.fileno(), False)
            commands = [(0, proc.pid, os.getpid(), 'spinner')]
            checks = collections.defaultdict(list)
            protocol = []
            pending = {'exec': b'', 'trace': b''}
            with selectors.DefaultSelector() as selector, (output / (fixture + '-trace.txt')).open('wb') as trace:
                selector.register(fd, selectors.EVENT_READ, 'exec')
                selector.register(proc.stderr, selectors.EVENT_READ, 'trace')
                while time.monotonic() - start < OBSERVE_SECONDS:
                    for key, _ in selector.select(max(0, OBSERVE_SECONDS - (time.monotonic() - start))):
                        data = os.read(key.fd, 65536)
                        if not data:
                            raise AssertionError('spinner exited unexpectedly')
                        elapsed = round(time.monotonic() - start, 3)
                        if key.data == 'trace':
                            trace.write(data)
                        pending[key.data] += data
                        lines = pending[key.data].split(b'\n')
                        pending[key.data] = lines.pop()
                        for raw in lines:
                            line = raw.decode(errors='replace')
                            if key.data == 'exec':
                                pid, ppid, name = line.split(' ', 2)
                                commands.append((elapsed, int(pid), int(ppid), name))
                            else:
                                if line.startswith('spinner-protocol '):
                                    protocol.append((elapsed, json.loads(line[len('spinner-protocol '):])))
                                match = re.match(r'^(?:\+\d* 0? |spinner-check [0-9.]+ )(stuck_check|degen_check|needs_check|hb_stamp|daemon_watch)(?: |$)', line)
                                if match:
                                    checks[match[1]].append(elapsed)
                                if re.match(r'^\+\d* 0? bash .*fleet-daemon-watch.sh$', line):
                                    checks['daemon_watch'].append(elapsed)
            seconds = round(time.monotonic() - start, 3)
            final = tm('list-windows', '-t', 'test', '-F', '#{window_name}=#{@claude_state}')
            unique = {}
            for row in commands:
                unique.setdefault(row[1], row)
            by_protocol = collections.Counter(cmd[0] for _, cmd in protocol)
            queries = {name: count for name, count in by_protocol.items()
                       if name.startswith(('list-', 'show-', 'display-', 'capture-'))}
            categories = dict(read_query=sum(queries.values()),
                              subscription=by_protocol['refresh-client'],
                              connection=by_protocol['attach-session'],
                              configuration=by_protocol['set-hook'],
                              write=by_protocol['set-window-option'] + by_protocol['set-option'])
            assert sum(categories.values()) == len(protocol), ('unclassified protocol command', by_protocol)
            assert categories['connection'] == 1 and categories['subscription'] >= 1, 'protocol instrumentation missing'
            report = dict(fixture=fixture, seconds=seconds, external_processes=len(unique),
                          by_command=dict(collections.Counter(row[3] for row in unique.values())),
                          checks_seconds=dict(checks), commands=commands, final=final,
                          defaults=dict(stuck_check=10, degen_check=15, needs_check=20,
                                        heartbeat=20, daemon_watch=30),
                          seams='private HOME/socket; offline lease; no daemon stamps; no maintenance overrides',
                          count_scope=__doc__)
            report.update(protocol_commands=protocol, protocol_by_command=dict(by_protocol),
                          protocol_categories=categories, read_query=queries)
            (output / (fixture + '.json')).write_text(json.dumps(report, indent=2))
            print(json.dumps({k: v for k, v in report.items() if k not in ('commands', 'protocol_commands', 'count_scope')}, indent=2), flush=True)
            # A cheap spinner which stopped maintaining the fleet must red too.
            origin = checks['hb_stamp'][0]
            for name, period in PERIODS.items():
                expected = due_times(period, OBSERVE_SECONDS, initial=name == 'hb_stamp')
                actual = checks[name]
                assert len(actual) >= len(expected), (name, actual)
                for at, due in zip(actual, expected):
                    assert due - .1 <= at-origin <= due+2, (name, due, at-origin)
            if fixture == 'maintenance':
                assert report['by_command'].get('ps') == 2, 'both safety observations must be fresh'
                assert 'needs=needs' in final, 'missing native identity is unknown, never permission to clear'
            report['budget'] = check_costs(fixture, list(unique.values()), checks, categories['read_query'])
        finally:
            if proc:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(timeout=5)
                proc.stderr.close()
            subprocess.run([tmux, '-L', 'test', 'kill-server'], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.close(fd)
    # The TemporaryDirectory and every fixture process have been cleaned up.
    report['fixture_wall_seconds'] = time.monotonic() - fixture_start
    (output / (fixture + '.json')).write_text(json.dumps(report, indent=2))
    assert report['fixture_wall_seconds'] < 55, ('fixture leaves no entry startup margin', report['fixture_wall_seconds'])
    print('PASS %s: actual %ss observation; budget %s; prepare/observe/cleanup %.3fs' % (
        fixture, OBSERVE_SECONDS, json.dumps(report['budget'], sort_keys=True),
        report['fixture_wall_seconds']), flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--fixture', choices=('idle', 'maintenance'), default='idle',
                        help='one independent slice; both run through the BREAK-IT family')
    args = parser.parse_args()
    if not shutil.which('tmux'):
        raise SystemExit('tmux required for complete spinner budget')
    output = args.output or Path(tempfile.mkdtemp(prefix='spinner-budget-evidence.'))
    output.mkdir(parents=True, exist_ok=True)
    audit(args.fixture, output)
    print('Evidence:', output, flush=True)
