#!/usr/bin/env python3
"""Real hook/tmux regression for activity hidden between idle probes (#4412)."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

BIN = Path(__file__).resolve().parents[2] / "bin"
spec = importlib.util.spec_from_file_location("idle_cost", BIN / "fleet-idle-cost.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
REAL_TMUX = os.environ.get("IDLE_EDGE_REAL_TMUX") or shutil.which("tmux")
FORMAT = ("#{socket_path}|#{window_id}|=#{@fleet_role}|#{@claude_state}|"
          "#{@claude_state_ts}|#{@worker_lifecycle}")


def run(argv, env):
    return subprocess.check_output(argv, env=env, text=True, stderr=subprocess.PIPE,
                                   timeout=15).strip()


def tm(env, label, *args):
    return run([REAL_TMUX, "-L", label, *args], env)


def worker(env, label):
    wid = tm(env, label, "new-window", "-d", "-P", "-F", "#{window_id}",
             "-t", label, "-n", "worker", "sleep 120")
    tm(env, label, "set-option", "-w", "-t", wid, "@fleet_role", "worker")
    return wid


def hook(env, label, wid, state):
    sock, pid, pane = tm(env, label, "display-message", "-p", "-t", wid,
                         "#{socket_path}|#{pid}|#{pane_id}").split("|")
    e = dict(env, TMUX=f"{sock},{pid},0", TMUX_PANE=pane)
    run(["sh", str(BIN / "set-claude-state.sh"), "--via", "7501", state], e)


def pulse(env, label, wid):
    hook(env, label, wid, "working")
    hook(env, label, wid, "done")


def exercise(root):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("FLEET_", "CCQUOTA_", "TMUX", "CLAUDE_"))}
    env.update(HOME=str(root / "home"), FLEET_CONF_DIR=str(root / "conf"),
               FLEET_MACHINE_SESSIONS_DIR=str(root / "sessions"),
               FLEET_SKIP_GLOBAL_CONF="1", TMUX_TMPDIR=str(root),
               FLEET_CI_WORKER_PAT="idle-edge-no-ci-process")
    for d in ("home", "sessions", "bin"):
        (root / d).mkdir()
    (root / "sessions/.idle-home").touch()
    date = root / "bin/date"
    date.write_text('#!/bin/sh\nif [ "$*" = +%s ]; then echo 1700000000\n'
                    'else exec /bin/date "$@"; fi\n')
    date.chmod(0o755)
    env["PATH"] = str(root / "bin") + os.pathsep + env["PATH"]
    os.environ.update(env)  # IdleGuard discovers these isolated -L sockets.
    labels = ["idle-edge-a", "idle-edge-b"]

    try:
        for label in labels:
            conf = root / "conf/fleets" / label / "conf"
            conf.parent.mkdir(parents=True)
            conf.write_text(f"FLEET_SESSION={label}\n")
            tm(env, label, "-f", "/dev/null", "new-session", "-d", "-s", label,
               "-n", "home", "sleep 120")
        caller = worker(env, labels[0])
        other = worker(env, labels[1])
        assert caller == other, "fixture must reuse the window id across sockets"
        for label, wid in zip(labels, (caller, other)):
            hook(env, label, wid, "done")
        sock = tm(env, labels[0], "display-message", "-p", "-t", caller, "#{socket_path}")
        a = SimpleNamespace(configs="\n".join(labels), conf_dir=env["FLEET_CONF_DIR"],
                            sessions_dir=env["FLEET_MACHINE_SESSIONS_DIR"], login="home",
                            self_socket=sock, self_window=caller, window_format=FORMAT)

        def guard():
            g = m.IdleGuard(a, m.Sampler([]))
            assert g.check(set()) == "", "fixture must begin idle"
            return g

        g = guard()
        assert g.check(set()) == "", "quiet stays idle"
        pulse(env, labels[0], caller)
        assert g.check(set()) == "", "only the exact caller is excluded"
        print("PASS quiet and caller-only transitions", flush=True)

        g, concurrent = guard(), guard()
        before = g.local()
        pulse(env, labels[1], other)
        assert g.local() == before, "fixed-second fixture must restore identical rows"
        with ThreadPoolExecutor(max_workers=2) as pool:
            reasons = list(pool.map(lambda observer: observer.check(set()), (g, concurrent)))
        assert all("busy interval" in r for r in reasons), (
            "same-second non-caller pulse certified idle, or an observer consumed activity", reasons)
        print("PASS same-second pulse, cross-socket same id, concurrent observers", flush=True)

        g = guard()
        before = g.local()
        transient = worker(env, labels[0])
        pulse(env, labels[0], transient)
        tm(env, labels[0], "kill-window", "-t", transient)
        assert g.local() == before
        assert "busy interval" in g.check(set()), "reaped worker activity certified idle"
        print("PASS worker created and reaped between probes", flush=True)

        g = guard()
        tm(env, labels[0], "kill-server")
        tm(env, labels[0], "-f", "/dev/null", "new-session", "-d", "-s", labels[0],
           "-n", "home", "sleep 120")
        replacement = worker(env, labels[0])
        assert replacement == caller
        pulse(env, labels[0], replacement)
        assert "busy interval" in g.check(set()), "new server inherited the old caller exclusion"
        print("PASS caller exclusion does not survive server replacement", flush=True)

        # The CLI uses a barrier at its third tmux scan: preflight, baseline,
        # then an event entirely between baseline and the returned next rows.
        # No timing race or faster polling; the snapshots still come from tmux.
        (root / "probe-bin").mkdir()
        shim = root / "probe-bin/tmux"
        shim.write_text("#!" + sys.executable + "\nimport os, sys\nos.execv(sys.executable, "
                        + repr([sys.executable, str(Path(__file__).resolve()), "--tmux"])
                        + " + sys.argv[1:])\n")
        shim.chmod(0o755)
        real_ps = shutil.which("ps")
        ps = root / "bin/ps"
        ps.write_text('#!/bin/sh\nif [ "$*" = "-axo pid=,ppid=,uid=,etime=,time=,command=" ]; then\n'
                      + '  "' + real_ps + '" "$@" | awk \'$3 == ' + str(os.getuid()) + '\'\n'
                      + 'else exec "' + real_ps + '" "$@"; fi\n')
        ps.chmod(0o755)
        cli_env = dict(env, IDLE_EDGE_REAL_TMUX=REAL_TMUX, IDLE_EDGE_ROOT=str(root),
                       IDLE_EDGE_EVENT_PATH=env["PATH"],
                       PATH=str(root / "probe-bin") + os.pathsep + env["PATH"],
                       FLEET_IDLE_SELF_SOCKET=sock, FLEET_IDLE_SELF_WIN=caller)
        last = root / "conf/idle-cost/last.json"
        last.parent.mkdir(parents=True, exist_ok=True)
        kept = b'{"state":"idle","rate":123,"test":"previous valid reading"}\n'
        for case in ("pulse", "reap", "caller", "quiet"):
            last.write_bytes(kept)
            (root / "probe-count").write_text("0")
            result = subprocess.run(["bash", str(BIN / "fleet-idle-cost.sh"), "--secs", "1", "--json"],
                                    env=dict(cli_env, IDLE_EDGE_ACTION=case), text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            if case in {"pulse", "reap"}:
                assert result.returncode == 3, (case, result.returncode, result.stdout, result.stderr)
                assert json.loads(result.stdout)["state"] == "busy", result.stdout
                assert last.read_bytes() == kept, "busy CLI replaced the last valid reading"
            else:
                assert result.returncode == 0, (case, result.stdout, result.stderr)
                assert json.loads(result.stdout)["state"] == "idle", result.stdout
            print("PASS CLI " + case + " (exit %s; last reading preserved on busy)" % result.returncode,
                  flush=True)
    finally:
        for label in labels:
            subprocess.run([REAL_TMUX, "-L", label, "kill-server"], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


def tmux_barrier():
    env = dict(os.environ)
    args = sys.argv[2:]
    result = subprocess.run([REAL_TMUX, *args], env=env, stdout=subprocess.PIPE)
    if args[:2] == ["-L", "idle-edge-a"] and "list-windows" in args:
        root = Path(env["IDLE_EDGE_ROOT"])
        counter = root / "probe-count"
        n = int(counter.read_text()) + 1
        counter.write_text(str(n))
        if n == 3:
            case = env["IDLE_EDGE_ACTION"]
            # Only the observer passes through the barrier; hooks run with the
            # real tmux directly, just as in production.
            env["PATH"] = env["IDLE_EDGE_EVENT_PATH"]
            if case == "pulse":
                pulse(env, "idle-edge-b", "@1")
            elif case == "caller":
                pulse(env, "idle-edge-a", "@1")
            elif case == "reap":
                wid = worker(env, "idle-edge-a")
                pulse(env, "idle-edge-a", wid)
                tm(env, "idle-edge-a", "kill-window", "-t", wid)
    sys.stdout.buffer.write(result.stdout)
    return result.returncode


if __name__ == "__main__":
    if sys.argv[1:] and sys.argv[1] == "--tmux":
        sys.exit(tmux_barrier())
    if not REAL_TMUX:
        sys.exit("tmux required")
    with tempfile.TemporaryDirectory(prefix="idle-edge-") as tmp:
        exercise(Path(tmp).resolve())
