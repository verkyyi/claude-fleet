#!/usr/bin/env python3
"""The spinner's existing frame/maintenance loop, with one transport per fleet.

The shell entry only loads the install's config and execs this process. Deadlines
use the kernel monotonic clock (including time spent doing maintenance). No extra
scheduler/daemon, no per-frame files, and no subprocess for clocks or formatting.
"""
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

BIN = Path(__file__).absolute().parent
_spec = importlib.util.spec_from_file_location('render_watch', BIN / 'fleet-render-watch.py')
watch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(watch)
clock = watch.monotonic

# Fleet window scans follow fleet_lw's grouped-view rule: discard @view- rows,
# then deduplicate by window id. Targets are window IDs, never mutable positions.
FIELDS = ('window_id', 'session_name', 'window_name', '@claude_state', '@worker_lifecycle',
          '@claude_needs', '@claude_state_ts', '@cc_agent', 'window_activity',
          '@sidebar_worker', 'pane_id', '@degenerate_ts')
WFMT = '\t'.join('#{' + name + '}' for name in FIELDS) + '\t.'
GLYPHS = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
CYAN = '#3d6a85 #4a82a5 #5aa0c8 #6bb8e0 #7dcfff #a6e0ff #7dcfff #6bb8e0 #5aa0c8 #4a82a5'.split()
INDIGO = '#5a4a8a #6a5a9e #7d6bb5 #9078c8 #a78bde #bb9af7 #a78bde #9078c8 #7d6bb5 #6a5a9e'.split()
ANIMATED = {'working', 'looping', 'preparing', 'waking'}


def number(value, default=0):
    return int(value) if str(value).isascii() and str(value).isdigit() else default


def setting(key, default):
    return number(os.environ.get(key, ''), default)


def atomic(path, text):
    try:
        tmp = path.with_name(path.name + '.%s.tmp' % os.getpid())
        tmp.write_text(text)
        os.replace(tmp, path)
    except OSError:
        pass


def trace(name):
    if os.environ.get('SPIN_TRACE') == '1':
        print('spinner-check %.6f %s' % (clock(), name), file=sys.stderr, flush=True)


def windows(control):
    trace('windows')
    rows, seen = [], set()
    for line in control.command('list-windows', '-a', '-F', WFMT).splitlines():
        fields = line.split('\t')
        if len(fields) != len(FIELDS) + 1:
            continue  # malformed names/fields cannot become write targets
        row = dict(zip(FIELDS, fields))
        wid = row['window_id']
        if '@view-' in row['session_name'] or wid in seen:
            continue
        seen.add(wid)
        row['state'] = row['@worker_lifecycle'] or row['@claude_state']
        rows.append(row)
    return rows


def degenerate(screen, minimum=12):
    """Byte-equivalent to fleet-degenerate.awk; same phase and false-hit rails."""
    def periodic(s, p):
        return len(s) <= p or s[p:] == s[:-p]

    def period(s):
        for p in range(1, min(8, len(s)) + 1):
            if periodic(s, p):
                return p
        tag = re.match(rb'^</?[A-Za-z][^<>]*>', s)
        if tag and len(tag[0]) <= 32 and periodic(s, len(tag[0])):
            return len(tag[0])
        return 0

    run = best = p = 0
    prev = unit = best_unit = b''
    for row in screen.encode().split(b'\n'):
        s = re.sub(rb'[ \t\r]+', b'', row)
        if not s:
            continue
        if run and periodic(s, p) and periodic(prev[-p:] + s[:p], p):
            run += 1
        else:
            p, run, unit = period(s), 0, b''
            if p:
                unit = s[:p]
                run = int(bool(re.search(rb'[A-Za-z0-9]', unit)))
        prev = s
        if run > best:
            best, best_unit = run, unit
    return (best, best_unit.decode(errors='replace')) if best >= (minimum if minimum >= 2 else 12) else None


def daemon_evidence():
    """Absence-only fast path, not another daemon policy/threshold registry.

    The watch reads scheduling stamps from this install AND progress/pid evidence
    from global/. If the entire state tree is empty it can do nothing. Any file
    (even another checkout's), or an unreadable directory, delegates to the ONE
    watcher. Recheck every 30s so a new stamp immediately ends this fast path.
    """
    base = Path(os.environ.get('TMPDIR', '/tmp/claude-fleet-%s' % os.getuid())) / '.claude-dash'
    try:
        if not base.exists():
            return False
        return any(p.is_file() for p in base.glob('**/*'))
    except OSError:
        return True


def daemon_state_dir(root):
    """fleet_daemon_state_dir's path, including POSIX cksum, without an exec."""
    base = Path(os.environ.get('TMPDIR', '/tmp/claude-fleet-%s' % os.getuid())) / '.claude-dash'
    physical = os.path.realpath(root)
    live = os.path.realpath(os.environ.get('FLEET_LIVE_ROOT', str(Path.home() / '.claude/fleet')))
    if physical == live:
        return base / 'global'
    data = os.fsencode(physical)
    length, crc = len(data), 0
    suffix = bytearray()
    while length:
        suffix.append(length & 255)
        length >>= 8
    for byte in data + suffix:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ (0x04c11db7 if crc & 0x80000000 else 0)) & 0xffffffff
    return base / ('dev-%s%s' % (crc ^ 0xffffffff, len(data)))


class Spinner:
    def __init__(self):
        self.conf = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet')))
        self.logs = BIN.parent / 'logs'
        self.logs.mkdir(parents=True, exist_ok=True)
        self.interval = float(os.environ.get('SPIN_INTERVAL', '.12'))
        if not math.isfinite(self.interval) or self.interval <= 0:
            raise ValueError('SPIN_INTERVAL must be positive')
        self.stuck_age = setting('STUCK_SECS', 120)
        self.needs_secs = setting('FLEET_NEEDS_RECONCILE_SECS', 20)
        self.degen_secs = setting('FLEET_DEGENERATE_SECS', 15)
        self.periods = dict(stuck_check=setting('STUCK_CHECK_SECS', 10),
                            needs_check=self.needs_secs, degen_check=self.degen_secs,
                            hb_stamp=max(self.interval, setting('SPIN_HB_SECS', 20)), daemon_watch=30)
        now = clock()
        self.deadlines = {key: now + value for key, value in self.periods.items() if value}
        if not self.stuck_age:
            self.deadlines.pop('stuck_check', None)
        self.controls = {}
        self.retry = {}
        self.next_discovery = 0
        self.tables = {}
        self.rendered = {}
        self.counts = {}
        self.frame = 0
        self.next_frame = now
        self.next_read = now
        self.observer = watch.Observer()
        self.children = []
        self.stuck_strikes = set()
        self.screens = {}
        self.idle_t0 = None
        self.wake = daemon_state_dir(BIN.parent) / 'wake'
        self.tmux_count = 0
        self.hb_time = None
        self.hb_count = 0
        self.hb_stamp()

    def idle_delay(self, now):
        after = setting('FLEET_DAEMON_IDLE_AFTER', 300)
        if not after:
            return 2
        if self.idle_t0 is None:
            self.idle_t0 = now
        try:
            wake = int(self.wake.read_text().strip())
            if wake > 0 and wake >= self.idle_t0:
                self.idle_t0 = now
        except (OSError, ValueError):
            pass
        return 60 if now - self.idle_t0 >= after else 2

    def discover(self):
        now = clock()
        if now < self.next_discovery:
            return
        self.next_discovery = now + 2
        names = {p.parent.name for p in (self.conf / 'fleets').glob('*/conf') if p.is_file()}
        names |= {p.stem for p in self.conf.glob('*.conf') if p.stem not in ('fleet', 'shell', 'hub-defaults')}
        for name in set(self.controls) - names:
            self.drop(name)
        for name in sorted(names - self.controls.keys()):
            if now < self.retry.get(name, 0):
                continue
            self.tmux_count += 1
            try:
                self.controls[name] = watch.Control(name)
                self.next_read = 0
            except (OSError, ValueError):
                self.retry[name] = now + 6

    def drop(self, name):
        control = self.controls.pop(name, None)
        if control:
            control.close()
        self.tables.pop(name, None)
        self.rendered = {key: value for key, value in self.rendered.items() if key[0] != name}
        self.counts = {key: value for key, value in self.counts.items() if key[0] != name}
        self.retry[name] = clock() + .25
        self.next_discovery = 0

    def hb_stamp(self):
        trace('hb_stamp')
        now = int(time.time())
        rate = ''
        if self.hb_time is not None and now > self.hb_time:
            rate = ' tmux_calls_per_s=%.1f' % ((self.tmux_count - self.hb_count) / (now - self.hb_time))
        atomic(self.logs / 'spinner.heartbeat', str(now) + rate + '\n')
        self.hb_time, self.hb_count = now, self.tmux_count

    def launch(self, args, env=None):
        self.children.append(subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL,
                                             stderr=subprocess.DEVNULL, start_new_session=True))

    def log(self, name, message):
        path = self.logs / name
        try:
            lines = path.read_text().splitlines() if path.exists() else []
            lines.append(time.strftime('%H:%M:%S') + '  ' + message)
            atomic(path, '\n'.join(lines[-300:]) + '\n')
        except OSError:
            pass

    def nudge(self):
        # Reuse the single state-invalidation implementation on a CHANGE only.
        self.launch(['sh', '-c', '. "$1/fleet-idle-activity.sh"; fleet_idle_activity; '
                     '[ "${CCQUOTA_FLEET:-0}" != 1 ] || : > "$FLEET_CONF_DIR/global/hub-nudge"',
                     'spinner', str(BIN)], dict(os.environ, FLEET_CONF_DIR=str(self.conf)))

    def primary_fresh(self, c, wid):
        maximum = setting('FLEET_STATE_PRIMARY_SECS', 120)
        value = c.command('display-message', '-p', '-t', wid, '#{@agent_status_ts}|#{@agent_status}')
        ts, status = value.split('|', 1)
        return maximum > 0 and ts.isdigit() and '"state":"exited"' not in status and time.time() - int(ts) < maximum

    def write_state(self, c, wid, state):
        c.commands([['set-window-option', '-t', wid, key, value] for key, value in (
            ('@claude_state', state), ('@claude_state_src', 'classifier'),
            ('@claude_needs', ''), ('@claude_state_ts', str(int(time.time()))))])
        self.nudge()
        self.next_read = 0

    def stuck_check(self):
        new, screens = set(), {}
        now = int(time.time())
        for name, c in list(self.controls.items()):
            try:
                if not any(r['@claude_state'] == 'working' for r in self.tables.get(name, [])):
                    continue
                for row in windows(c):
                    if row['@claude_state'] != 'working':
                        continue
                    wid, worker = row['window_id'], row['@sidebar_worker']
                    act = row['window_activity']
                    if worker:
                        screen = c.command('capture-pane', '-p', '-t', worker)
                        key = (name, wid, worker)
                        old = self.screens.get(key)
                        act = old[1] if old and old[0] == screen else now
                        screens[key] = (screen, act)
                    if not str(act).isdigit() or now - int(act) < self.stuck_age:
                        continue
                    key = (name, wid)
                    if key not in self.stuck_strikes:
                        new.add(key)
                        continue
                    if self.primary_fresh(c, wid):
                        continue
                    self.write_state(c, wid, 'done')
                    self.log('stuck.log', '%s:%s working -> done (idle %ss; stop-hook missed)' % (name, wid, now-int(act)))
                    self.launch([str(BIN / 'classify-sessions.sh'), '--window', wid], dict(os.environ, CLASSIFY_SOCK=name))
            except (OSError, ValueError):
                continue
        self.stuck_strikes, self.screens = new, screens

    def read_strikes(self, name, ttl):
        try:
            data = json.loads((self.logs / name).read_text())
            # Keep the existing strike file's age/reset contract. The JSON
            # companion adds identity; a legacy strike alone cannot authorize a
            # write, but deleting/aging it still resets the one-shot and daemon.
            epoch, armed = (self.logs / name.replace('-identities', '-strikes')).read_text().split(' ', 1)
            if 0 <= time.time() - int(epoch) <= ttl and ttl > 0:
                return {key: value for key, value in data['rows'].items()
                        if ('|' + key + (':' + value['verdict'] if isinstance(value, dict) else '') + '|') in armed}
        except (OSError, ValueError, KeyError, TypeError):
            pass
        return {}

    def needs_check(self):
        from fleet_pending_tool import observe, parse_panes, PANE_FORMAT
        ttl = setting('FLEET_NEEDS_STRIKE_TTL', self.needs_secs * 3)
        previous = self.read_strikes('.needs-identities', ttl)
        new = {}
        left, candidates, starved, touched = 8, 0, 0, 0
        now = time.time()
        for name, c in list(self.controls.items()):
            try:
                rows = [r for r in windows(c) if r['state'] == 'needs'
                        and r['@claude_needs'] != 'restore' and r['@cc_agent'] in ('', 'claude')
                        and now - number(r['@claude_state_ts']) >= self.needs_secs]
                starved += max(0, len(rows) - left)
                rows = rows[:left]
                left -= len(rows)
                candidates += len(rows)
                if not rows:
                    continue
                # Resolve sidebar worker or active pane from fresh tmux rows.
                targets = {r['@sidebar_worker'] or r['pane_id']: r for r in rows}
                # Previously observed and new candidates share one ps per group;
                # every second check supplies its exact earlier identity.
                groups = ({p: r for p, r in targets.items() if name+':'+r['window_id'] in previous},
                          {p: r for p, r in targets.items() if name+':'+r['window_id'] not in previous})
                for group in groups:
                    if not group:
                        continue
                    expected = {p: previous[name+':'+r['window_id']]['identity'] for p, r in group.items()
                                if name+':'+r['window_id'] in previous}
                    def reader():
                        return [r for r in parse_panes(c.command('list-panes', '-a', '-F', PANE_FORMAT)) if r['pane'] in group]
                    observations = observe(reader, expected=expected or None)
                    for result in observations:
                        row = group.get(result['pane'])
                        if not row or result['code'] not in (0, 1) or time.time() >= result['expires_at']:
                            continue  # unknown/expired/native missing never clears a red
                        sub = row['@claude_needs']
                        verdict, want = '', ''
                        if result['code'] == 1:
                            if sub in ('ask', 'perm') or (sub != 'blocked' and now-number(row['@claude_state_ts']) >= setting('FLEET_NEEDS_PLAIN_SECS', 900)):
                                verdict = 'idle'
                        elif sub in ('ask', 'perm'):
                            want = 'ask' if result['tool'] == 'AskUserQuestion' else 'perm'
                            if want != sub:
                                verdict = 'sub-' + want
                        if not verdict:
                            continue
                        key = name + ':' + row['window_id']
                        record = dict(identity=result['identity'], verdict=verdict, stamp=row)
                        if previous.get(key) != record:
                            new[key] = record
                            continue
                        # A later prompt/blocker/primary word outranks this scan.
                        current = {r['window_id']: r for r in windows(c)}.get(row['window_id'])
                        if current != row or self.primary_fresh(c, row['window_id']) or time.time() >= result['expires_at']:
                            continue
                        if verdict == 'idle':
                            self.write_state(c, row['window_id'], 'done')
                        else:
                            c.commands([['set-window-option', '-t', row['window_id'], '@claude_state_src', 'classifier'],
                                        ['set-window-option', '-t', row['window_id'], '@claude_needs', want]])
                            self.nudge()
                            self.next_read = 0
                        touched += 1
                        self.log('needs.log', '%s needs/%s -> %s' % (key, sub or '-', verdict))
            except (OSError, ValueError, subprocess.SubprocessError):
                continue  # failed transport/oracle retains every candidate
        atomic(self.logs / '.needs-identities', json.dumps(dict(at=time.time(), rows=new)))
        armed = '|' + ''.join(key + ':' + row['verdict'] + '|' for key, row in new.items())
        atomic(self.logs / '.needs-strikes', '%s %s\n' % (int(time.time()), armed))
        if os.environ.get('FLEET_NEEDS_TRACE') == '1':
            self.log('needs.log', '(reconcile) pass  cand=%s acted=%s starved=%s armed=%s' % (candidates, touched, starved, armed))

    def degen_check(self):
        previous = self.read_strikes('.degenerate-identities', self.degen_secs * 3 + 5)
        new = {}
        for name, c in list(self.controls.items()):
            try:
                for row in windows(c):
                    if row['@claude_state'] != 'working' or time.time() - number(row['@degenerate_ts']) < setting('FLEET_DEGENERATE_COOLDOWN_SECS', 300):
                        continue
                    pane = row['@sidebar_worker'] or row['pane_id']
                    hit = degenerate(c.command('capture-pane', '-p', '-t', pane), setting('FLEET_DEGENERATE_LINES', 12))
                    if not hit:
                        continue
                    key = name + ':' + row['window_id']
                    # Socket inode and pane keep a restarted server out of an old strike.
                    st = os.stat(c.path)
                    identity = [st.st_dev, st.st_ino, pane]
                    if previous.get(key) == identity:
                        self.launch(['bash', str(BIN / 'fleet-degenerate.sh'), '-L', name, '--win', row['window_id'],
                                     '--pane', pane, '--rows', str(hit[0]), '--sample', hit[1]])
                    else:
                        new[key] = identity
            except (OSError, ValueError):
                continue
        atomic(self.logs / '.degenerate-identities', json.dumps(dict(at=time.time(), rows=new)))
        atomic(self.logs / '.degenerate-strikes', '%s |%s\n' % (int(time.time()), ''.join(k+'|' for k in new)))

    def daemon_watch(self):
        if (BIN / 'fleet-daemon-watch.sh').is_file() and daemon_evidence():
            self.launch(['bash', str(BIN / 'fleet-daemon-watch.sh')])

    def render(self, watched):
        counts = {}
        for name, c in list(self.controls.items()):
            commands, pending = [], {}
            for row in self.tables.get(name, []):
                wid, session, st, sub = row['window_id'], row['session_name'], row['state'], row['@claude_needs']
                counts.setdefault((name, session), 0)
                if st == 'needs' and row['window_name'] not in ('dash', 'backlog'):
                    counts[name, session] += 1
                frame = self.frame if watched else 0
                glyph, sfg, nfg, style = '  ', '#565f89', '#565f89', 'fg=#565f89'
                if st in ANIMATED:
                    glyph = (GLYPHS[frame] if st in ('working', 'looping') else '↻') + ' '
                    sfg = INDIGO[frame] if st == 'looping' else CYAN[frame]
                    nfg = '#9d7cd8' if st == 'looping' else '#a9b1d6'
                elif st == 'done':
                    glyph, sfg, nfg = '✓ ', '#9ece6a', '#9ece6a'
                elif st == 'sleeping':
                    glyph = 'z '
                elif st in ('failed', 'needs'):
                    glyph = {'ask': '? ', 'perm': '⊘ ', 'blocked': '⊠ '}.get(sub, '! ') if st == 'needs' else '! '
                    sfg = nfg = '#7aa2f7'
                    style = 'fg=#7aa2f7,bold'
                value = (glyph, sfg, nfg, style)
                key = (name, wid)
                if self.rendered.get(key) != value:
                    commands.extend(['set-window-option', '-t', wid, option, v] for option, v in zip(
                        ('@spin', '@sfg', '@nfg', 'window-status-style'), value))
                pending[key] = value
            try:
                c.commands(commands)
                self.rendered.update(pending)
            except (OSError, ValueError):
                self.drop(name)
        total = sum(counts.values())
        for (name, session), count in counts.items():
            values = (count, total - count)
            if self.counts.get((name, session)) == values or name not in self.controls:
                continue
            try:
                self.controls[name].commands([['set-option', '-t', session, '@attn_needs', str(count)],
                                             ['set-option', '-t', session, '@attn_other_windows', str(total-count)]])
                self.counts[name, session] = values
            except (OSError, ValueError):
                self.drop(name)

    def run(self, once=None):
        self.discover()
        if once:
            if not self.controls:
                return 1
            if once == '--needs-check':
                self.needs_secs = self.needs_secs or 20
                self.needs_check()
            elif once == '--degenerate-check':
                self.degen_secs = self.degen_secs or 15
                self.degen_check()
            else:
                raise ValueError('unknown spinner argument: ' + once)
            for child in self.children:
                child.wait(timeout=10)
            return 0
        while True:
            self.discover()
            if not self.controls:
                self.hb_stamp()
                self.observer.close()
                time.sleep(self.idle_delay(time.time()))
                self.next_discovery = 0
                continue
            self.idle_t0 = None
            now = clock()
            for name, c in list(self.controls.items()):
                try:
                    c.pump()
                    marker = Path(c.path + '.dirty')
                    dirty = marker.exists()
                    if dirty:
                        marker.unlink(missing_ok=True)  # before fresh read
                    if c.changed or dirty or now >= self.next_read:
                        self.tables[name] = windows(c)
                        c.changed = False
                except (OSError, ValueError):
                    self.drop(name)
            if now >= self.next_read:
                self.next_read = now + .75
            for check, due in list(self.deadlines.items()):
                now = clock()
                if now >= due:
                    if check != 'hb_stamp':
                        trace(check)
                    getattr(self, check)()
                    period = self.periods[check]
                    self.deadlines[check] = due + (math.floor((clock()-due)/period) + 1) * period
            watched = os.environ.get('FLEET_SPINNER_WATCH') == '0' or self.observer.watched(list(self.controls.values()))
            now = clock()
            if watched and now >= self.next_frame:
                self.frame = (self.frame + 1) % len(GLYPHS)
                self.next_frame = now + self.interval
            self.render(watched)
            self.children = [p for p in self.children if p.poll() is None]
            animating = watched and any(r['state'] in ANIMATED for rows in self.tables.values() for r in rows)
            deadline = min(self.deadlines.values())
            if animating:
                deadline = min(deadline, self.next_frame)
            if os.environ.get('SPIN_TRACE') == '1':
                print('spinner-wait %.6f %.6f' % (clock(), deadline), file=sys.stderr, flush=True)
            try:
                self.observer.wait(list(self.controls.values()), deadline)
            except (OSError, ValueError):
                pass  # next read drops the dead connection; discovery reconnects

    def close(self):
        self.observer.close()
        for c in self.controls.values():
            c.close()
        for child in self.children:
            watch.stop(child)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    spinner = Spinner()
    try:
        return spinner.run(sys.argv[1] if len(sys.argv) > 1 else None)
    finally:
        spinner.close()


if __name__ == '__main__':
    sys.exit(main())
