#!/bin/bash
# #584: exercise a 24-window probe on a private tmux server. Assert selected
# windows and process/socket call counts; report time without a load-sensitive
# wall-clock gate. The runner supplies the usual shadow-root isolation.
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
for dep in tmux perl python3; do
  command -v "$dep" >/dev/null || { echo "model-switch-scale: $dep absent — SKIP"; exit 0; }
done
python3 - "$BIN" <<'PY'
import collections
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

bin_dir = Path(sys.argv[1])
real_tmux = shutil.which("tmux")
real_ps = shutil.which("ps")
label = f"model-switch-scale-selftest-{os.getpid()}"
work = Path(tempfile.mkdtemp(prefix="model-switch-scale-selftest."))
env = dict(os.environ, TMPDIR=str(work), FLEET_CONF_DIR=str(work / "conf"))

def tm(*args):
    return subprocess.check_output(
        [real_tmux, "-L", label, *args], env=env, text=True,
        stderr=subprocess.PIPE, timeout=15).strip()

def interrupted(signum, frame):
    raise SystemExit(128 + signum)

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, interrupted)

try:
    fakebin = work / "bin"
    fakebin.mkdir()
    (work / "conf").mkdir()
    (fakebin / "claude").symlink_to(shutil.which("perl"))
    # A real process tree and terminal, but no agent or credentials. The alarm
    # bounds fixture lifetime even if this test's parent is killed outright.
    fake = work / "fake.pl"
    fake.write_text(r'''
use strict;
use warnings;
$| = 1;
alarm 120;
my ($model, $wall, $ready, $typed) = @ARGV;
binmode(STDOUT, ":utf8");
print "  \x{23bf}  You've reached your Fable limit. Run /usage-credits to continue or switch models with /model.\n" if $wall;
print "  \x{25c6} $model  [meter] 30%\n";
open(my $r, '>', $ready) or die $!;
close $r;
while (my $line = <STDIN>) {
    open(my $f, '>>', $typed) or die $!;
    print $f $line;
    close $f;
}
''')
    # Panels/hub run the same capped fake process as candidates, so ignoring
    # them requires their metadata gates, not an accidental no-Claude result.
    cases = [(name, "panel") for name in ("dash", "plan", "backlog")]
    cases += [("hub", "hub")]
    cases += [(f"shell-{i}", "shell") for i in range(2)]
    cases += [(f"idle {i}", "idle") for i in range(8)]
    cases += [(f"busy-{i}", "busy") for i in range(4)]
    cases += [(f"recovered-{i}", "recovered") for i in range(4)]
    cases += [(f"unknown-{i}", "unknown") for i in range(2)]
    ids = {}
    for i, (name, kind) in enumerate(cases):
        ready = work / f"ready-{i}"
        typed = work / f"typed-{i}"
        typed.touch()
        model = "Opus 5" if kind == "recovered" else "Fable 5.1"
        if kind == "shell":
            cmd = "sleep 120"
        else:
            wall = "1" if kind in ("panel", "hub", "recovered") else "0"
            cmd = "exec " + shlex.join([
                str(fakebin / "claude"), str(fake), model, wall,
                str(ready), str(typed)])
        if i == 0:
            wid = tm("-f", "/dev/null", "new-session", "-d", "-P", "-F",
                     "#{window_id}", "-s", label, "-n", name,
                     "-x", "200", "-y", "30", cmd)
        else:
            wid = tm("new-window", "-d", "-P", "-F", "#{window_id}",
                     "-t", label, "-n", name, cmd)
        ids[wid] = kind
        tm("set-option", "-w", "-t", wid, "automatic-rename", "off")
        tm("set-option", "-w", "-t", wid, "@cc_account",
           "unknown" if kind == "unknown" else "acctA")
        if kind == "hub":
            tm("set-option", "-w", "-t", wid, "@hub", "1")
        if kind == "busy":
            tm("set-option", "-w", "-t", wid, "@claude_state", "working")
            # Missing stamp is deliberately conservative at any elapsed time.
        if kind != "shell":
            deadline = time.monotonic() + 10
            while not ready.exists():
                assert time.monotonic() < deadline, f"fixture {name} not ready"
                time.sleep(.02)
            # The ready file says the process wrote; capture confirms tmux has
            # consumed it before the timed probe begins.
            while model not in tm("capture-pane", "-p", "-t", wid):
                assert time.monotonic() < deadline, f"fixture {name} not painted"
                time.sleep(.02)

    ledger = work / ".claude-dash/global/account.model-limited"
    ledger.parent.mkdir(parents=True)
    ledger.write_text(f"acctA\tfable\t{int(time.time()) + 3600}\tcap\n")
    before = ledger.read_bytes()
    assert len(tm("list-windows", "-t", label).splitlines()) == 24

    # Count real operations, without mocking their results. Refuse every tmux
    # command except reads on this exact isolated socket during the probe.
    call_log = work / "calls"
    for name, real in (("tmux", real_tmux), ("ps", real_ps)):
        guard = ""
        if name == "tmux":
            guard = f'''[ "$1" = -L ] && [ "$2" = {shlex.quote(label)} ] || exit 90
case "$3" in list-windows|display-message|capture-pane) ;; *) exit 91 ;; esac
'''
        wrapper = fakebin / name
        wrapper.write_text("#!/bin/sh\n" +
            f"printf '{name}' >> {shlex.quote(str(call_log))}\n" +
            f"printf '\\t%s' \"$@\" >> {shlex.quote(str(call_log))}\n" +
            f"printf '\\n' >> {shlex.quote(str(call_log))}\n" + guard +
            f"exec {shlex.quote(real)} \"$@\"\n")
        wrapper.chmod(0o755)
    env["PATH"] = str(fakebin) + os.pathsep + env["PATH"]
    start = time.monotonic()
    result = subprocess.run(
        [str(bin_dir / "fleet-model-switch.sh"), "--session", label,
         "--capped", "--model", "opus", "--dry-run", "--no-fallback"],
        env=env, text=True, capture_output=True, timeout=60, check=True)
    elapsed = time.monotonic() - start
    planned = [line.split()[1] for line in result.stdout.splitlines()
               if line.startswith("  would:")]
    expected = {wid for wid, kind in ids.items() if kind == "idle"}
    assert len(planned) == 8 and set(planned) == expected, result.stdout
    for wid, kind in ids.items():
        if kind in ("busy", "recovered"):
            reason = "mid-turn" if kind == "busy" else "already off fable"
            assert any(wid + " (" in line and reason in line
                       for line in result.stdout.splitlines()), result.stdout
    rows = [line.split("\t") for line in call_log.read_text().splitlines()]
    counts = collections.Counter(row[3] for row in rows if row[0] == "tmux")
    assert counts == {"list-windows": 1, "capture-pane": 22}, counts
    assert sum(row[0] == "ps" for row in rows) == 2, rows
    assert ledger.read_bytes() == before, "dry-run changed the ledger"
    assert all(not path.read_bytes() for path in work.glob("typed-*")), "typed into a pane"
    print(f"model-switch-scale: 24 windows, 8 selected, 4 busy + 4 recovered refused; "
          f"23 tmux calls (1 metadata + 22 captures), 2 ps snapshots; probe {elapsed:.3f}s")
finally:
    subprocess.run([real_tmux, "-L", label, "kill-server"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    shutil.rmtree(work)
PY
