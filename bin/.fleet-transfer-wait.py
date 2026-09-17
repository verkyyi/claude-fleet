#!/usr/bin/env python3
"""Detached, bounded wait for /fleet-handoff --to codex's final Stop hook."""

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time


def tm(session, *args):
    return subprocess.check_output(["tmux", "-L", session, *args], stderr=subprocess.PIPE,
                                   timeout=10).decode().rstrip("\n")


def option(r, key):
    return tm(r["session"], "display-message", "-p", "-t", r["pane"], "#{" + key + "}")


def stamp(r, key, value):
    tm(r["session"], "set-option", "-w", "-t", r["window"], key, str(value))


def save(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def state(request, status, detail=""):
    save(request / "state.json", {"state": status, "detail": detail})


def release(r, request):
    # Never clear another controller's marker, even if this window was reused.
    try:
        if option(r, "@agent_transfer_request") == str(request):
            for key in ("@agent_transfer_ready", "@agent_transfer_pending_until", "@agent_transfer_request"):
                tm(r["session"], "set-option", "-wu", "-t", r["window"], key)
    except (OSError, subprocess.SubprocessError):
        pass
    lock = Path(r["lock"])
    if (lock / "request").exists() and (lock / "request").read_text() == str(request):
        (lock / "request").unlink()
        (lock / "pid").unlink(missing_ok=True)
        lock.rmdir()


def arm(a):
    notes = Path(a.notes).read_text(encoding="utf-8")
    if not notes.strip():
        raise ValueError("after-turn handoff notes are empty")
    timeout = a.idle_wait
    defer = a.defer
    if not 1 <= timeout <= 240 or not 0 <= defer <= 240:
        raise ValueError("wait bounds: idle 1..240 seconds, typing deferral 0..240 seconds")
    root = (Path(a.conf_dir) / "handoffs").resolve()
    if any(root == Path(p).resolve() or Path(p).resolve() in root.parents for p in (a.worktree, a.main)):
        raise ValueError("handoff storage must be outside the repository and worktree")
    r = vars(a).copy()
    r.update(deadline=time.time() + timeout, defer=defer)
    lock = Path(a.lock)
    lock.mkdir()  # Atomic double-arm refusal; a killed worker's lock needs inspection.
    request = None
    try:
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        request = Path(tempfile.mkdtemp(prefix=a.session + "-pending-", dir=root))
        (lock / "request").write_text(str(request))
        (request / "notes.md").write_text(notes, encoding="utf-8")
        # Create before the tmux shell redirects output: its inherited umask may
        # be 022, while conversation-adjacent files here must remain 0600.
        (request / "wait.log").touch(mode=0o600)
        save(request / "request.json", r)
        state(request, "waiting", "Waiting for the source turn's Stop hook.")
        stamp(r, "@agent_transfer_request", request)
        stamp(r, "@agent_transfer_pending_until", int(r["deadline"]))
        # tmux run-shell outlives the source tool call. Carry only the path/config
        # settings needed to resolve the SAME installation and source registry;
        # never serialize the caller's full environment or authentication values.
        keep = ("PATH", "HOME", "FLEET_CC_SESSIONS_DIR", "FLEET_CC_PROJECTS_DIR", "CLAUDE_PROJECTS_DIR",
                "FLEET_TRANSFER_EXIT_WAIT", "FLEET_TRANSFER_BOOT_WAIT")
        env = {k: os.environ[k] for k in keep if k in os.environ}
        env["FLEET_CONF_DIR"] = a.conf_dir
        cmd = ["env", *(k + "=" + v for k, v in env.items()), sys.executable,
               str(Path(__file__).absolute()), "wait", str(request)]
        body = shlex.join(cmd) + " >> " + shlex.quote(str(request / "wait.log")) + " 2>&1"
        tm(a.session, "run-shell", "-b", "( " + body + " ) >/dev/null 2>&1 || :")
    except BaseException:
        if request:
            state(request, "failed", "Could not arm the detached waiter; notes preserved.")
            release(r, request)
        else:
            lock.rmdir()
        raise
    print("after-turn request: " + str(request))
    print("Armed for this source session. End this turn now; inspect state.json / wait.log for the result.")


def wait(request):
    r = json.loads((request / "request.json").read_text())
    (Path(r["lock"]) / "pid").write_text(str(os.getpid()))
    try:
        # Wall time is in the durable request; monotonic time also bounds the loop
        # if the wall clock moves backwards after launch.
        end = time.monotonic() + max(0, min(240, r["deadline"] - time.time()))
        while time.monotonic() < end:
            if option(r, "@agent_transfer_request") != str(request):
                raise ValueError("transfer request was replaced or cancelled")
            if (option(r, "window_id") != r["window"] or option(r, "pane_dead") == "1"
                    or Path(option(r, "@worktree")).resolve() != Path(r["worktree"])):
                raise ValueError("source pane or worktree changed")
            os.kill(r["pid"], 0)
            if json.loads(Path(r["registry"]).read_text()).get("sessionId") != r["sid"]:
                raise ValueError("source session changed after arming")
            if option(r, "@handoff_armed") == "1":
                raise ValueError("a Claude context cycle became pending")
            ready = (option(r, "@agent_transfer_ready") == str(request)
                     and option(r, "@claude_state") == "done")
            if ready and r["defer"]:
                clients = tm(r["session"], "list-clients", "-F", "#{client_activity} #{window_id}")
                for line in clients.splitlines():
                    fields = line.split()
                    if (len(fields) == 2 and fields[1] == r["window"] and fields[0].isdigit()
                            and time.time() - int(fields[0]) <= r["defer"]):
                        ready = False
            if ready:
                break
            time.sleep(0.5)
        else:
            raise ValueError("source did not reach a clean Stop without operator activity before the deadline")
        state(request, "transferring")
        cmd = ["bash", str(Path(__file__).parent / "fleet-transfer.sh"),
               "--session", r["session"], "--window", r["window"], "--to", "codex",
               "--handoff", str(request / "notes.md"), "--armed-request", str(request),
               "--expected-source", "%s:%s:%s" % (r["pane"], r["pid"], r["sid"])]
        env = dict(os.environ)
        env.pop("TMUX_PANE", None)
        env.pop("TMUX", None)  # All calls use the explicit fleet socket.
        # The actual controller rechecks the live process, session and snapshot;
        # the snapshot includes the final handoff turn, never the arming-time tail.
        subprocess.run(cmd, env=env, check=True, timeout=180)
        manifest = option(r, "@handoff_manifest")
        state(request, "started", manifest)
        tm(r["session"], "display-message", "-t", r["pane"], "Claude → Codex started; handoff: " + manifest)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        state(request, "failed", str(error))
        print("fleet-transfer: " + str(error), file=sys.stderr)
        try:
            tm(r["session"], "display-message", "-t", r["pane"], "Agent transfer incomplete; inspect " + str(request))
        except (OSError, subprocess.SubprocessError):
            pass
        return 1
    finally:
        release(r, request)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    a = sub.add_parser("arm")
    for key in ("session", "window", "pane", "sid", "worktree", "main", "registry", "transcript", "notes", "conf-dir", "lock"):
        a.add_argument("--" + key, required=True)
    a.add_argument("--pid", type=int, required=True)
    a.add_argument("--idle-wait", type=int, required=True)
    a.add_argument("--defer", type=int, required=True)
    w = sub.add_parser("wait")
    w.add_argument("request", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "arm":
            arm(args)
            return 0
        return wait(args.request)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("fleet-transfer: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
