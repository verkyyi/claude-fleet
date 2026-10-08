#!/usr/bin/env python3
"""The Codex first sentence is SUBMITTED, not left in the composer (issue #2430).

A fleet pane hands Codex its seed as the launch's last argument
(`codex --remote <sock> … "<seed>"`, bin/fleet-codex-runtime.py). Codex is meant
to submit it; on 2026-10-08 a seed sat in the box (`› 验收：只回复 OK`) while the
window read `done`, and nothing in the fleet ever looked. This is the look: for
the first FLEET_CODEX_SEED_SECS (30) of the TUI's life, once a second, the pane's
composer is read with the one reader (bin/fleet-input.py, no keys sent). When it
holds the seed — the whole seed, or the start of it — for SEEN (3) reads in a row
and the window is not working, ONE Enter goes in (at most two in all). It stops
the moment the composer is seen empty after the seed, the window says working, or
the time is up. A multi-line seed (a prose expansion) is never matched, so it is
never touched; an unknown screen (a dialog, a trust prompt) is never typed into.

    SeedConfirm(pane, seed).tick()   -> True while it still has work
    fleet-codex-seed.py --pane %3 --seed-file f [--secs N]   (the selftest's door)

FLEET_CODEX_SEED_CONFIRM=0 turns it off.
"""
import argparse
import os
import runpy
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SEEN = 3
MAX_ENTERS = 2


def seed_of(argv):
    """The seed a launch's argv carries: its last word, when it is not an option
    and the launch is not a resume/fork (those carry none). '' otherwise."""
    if not argv or any(a in ('resume', 'fork') for a in argv[:2]):
        return ''
    last = argv[-1]
    if not last or last.startswith('-'):
        return ''
    # the word before it is an option that takes a value: not a seed
    if len(argv) >= 2 and argv[-2] in ('-c', '--config', '-m', '--model', '-p', '--profile', '--remote',
                                       '-C', '--cd', '-s', '--sandbox', '-a', '--ask-for-approval',
                                       '--enable', '--disable', '-i', '--image', '--add-dir'):
        return ''
    return last


class SeedConfirm:
    def __init__(self, pane, seed, socket='', secs=None, clock=time.monotonic):
        self.pane, self.socket, self.clock = pane, socket, clock
        self.seed = seed.strip() if seed and '\n' not in seed.strip() else ''
        if secs is None:
            try:
                secs = float(os.environ.get('FLEET_CODEX_SEED_SECS', '30'))
            except ValueError:
                secs = 30.0
        self.deadline = clock() + secs
        self.seen = 0
        self.saw_seed = False
        self.enters = 0
        self.done = not (self.pane and self.seed)
        self.reader = runpy.run_path(str(HERE / 'fleet-input.py')) if not self.done else None

    def tm(self, *args):
        base = ['tmux'] + (['-L', self.socket] if self.socket else [])
        return subprocess.run(base + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, timeout=5)

    def state(self):
        r = self.tm('display-message', '-p', '-t', self.pane, '#{@claude_state}')
        return r.stdout.strip() if r.returncode == 0 else ''

    def holds_seed(self, text):
        t = (text or '').strip()
        return bool(t) and (t == self.seed or (len(t) >= 2 and self.seed.startswith(t)))

    def tick(self):
        if self.done:
            return False
        if self.clock() >= self.deadline:
            self.done = True
            return False
        if self.state() in ('working', 'busy', 'looping'):
            self.done = True
            return False
        try:
            snap = self.reader['snapshot'](self.socket, self.pane, 'codex')
        except Exception:
            return True                      # a pane that cannot be read now: ask again
        if snap.get('state') == 'draft' and self.holds_seed(snap.get('text')):
            self.saw_seed = True
            self.seen += 1
            if self.seen >= SEEN:
                if self.enters >= MAX_ENTERS:
                    self.done = True
                    return False
                self.tm('send-keys', '-t', self.pane, 'Enter')
                self.enters += 1
                self.seen = 0
                log('seed left in the composer of %s: Enter %d' % (self.pane, self.enters))
            return True
        self.seen = 0
        if snap.get('state') == 'empty' and (self.saw_seed or self.enters):
            self.done = True                 # it went in
            return False
        return True


def log(line):
    d = os.environ.get('FLEET_CONF_DIR') or os.path.expanduser('~/.config/claude-fleet')
    try:
        os.makedirs(os.path.join(d, 'logs'), exist_ok=True)
        with open(os.path.join(d, 'logs', 'codex-seed.log'), 'a', encoding='utf-8') as f:
            f.write('%s %s\n' % (time.strftime('%Y-%m-%dT%H:%M:%S'), line))
    except OSError:
        pass


def for_launch(argv):
    """The confirm a pane launch gets: None off a pane, with no seed, or off."""
    if os.environ.get('FLEET_CODEX_SEED_CONFIRM', '1') == '0':
        return None
    pane = os.environ.get('TMUX_PANE', '')
    seed = seed_of(argv)
    if not (os.environ.get('TMUX') and pane and seed):
        return None
    c = SeedConfirm(pane, seed)
    return None if c.done else c


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n', 1)[0])
    ap.add_argument('--pane', required=True)
    ap.add_argument('--seed-file', required=True)
    ap.add_argument('--socket', default='')
    ap.add_argument('--secs', type=float, default=None)
    a = ap.parse_args()
    with open(a.seed_file, encoding='utf-8') as f:
        c = SeedConfirm(a.pane, f.read(), socket=a.socket, secs=a.secs)
    while c.tick():
        time.sleep(float(os.environ.get('FLEET_CODEX_SEED_TICK', '1')))
    print('enters=%d saw=%d' % (c.enters, int(c.saw_seed)))
    sys.exit(0)
