#!/usr/bin/env python3
"""fleet-shell.py — `fleet shell [<machine>] [--print]`: straight to your home
machine's command line, no 看台 (EPIC T651 C5).

    fleet shell              the home machine's login shell in $HOME
    fleet shell mac-a        that machine's instead
    fleet shell --print      the same as one ssh command line, run nothing —
                             for a phone's / iPad's ssh app

The emergency way in, for when the 看台 will not open at all, or for one quick
command on the machine. It opens a command line and nothing else: no session,
no lease, no record written anywhere.

  1. the machine and the line — `fleet-connect.py --argv [<machine>]`, the very
     answer the 看台's loop runs on (fleet-thin.py): the certificate renewed, the
     hub's home (the machine your 看台 opens on) unless one is named, the route
     pinned · remembered · measured;
  2. the hub does not answer and that failed — `fleet-connect.py --argv
     --offline [<machine>]`: the machine entered last (or named) and its
     remembered routes from ~/.ssh/fleet-ssh-config / connect.json, never the
     relay; with the certificate expired only the machine's entry port, which
     takes this computer's own key off the keys file kept ON that machine. A
     machine that cannot be entered that way is said («入口不在时进不去 …»),
     never guessed at;
  3. `ssh -tt` on that line, the remote command `cd && FLEET_NO_VIEW=1 exec
     $SHELL -l` — the login shell with no 看台 started (shell/fleet-login.zsh
     reads FLEET_NO_VIEW, EPIC T651 C4) — after one line: where, and that `fleet`
     there goes back to the 看台. The machine picked being THIS computer and this
     login: the login shell right here, no ssh.

No new port, no standing key: the same certificate and routes the 看台 uses
(EPIC T651 共同约定 4). Exit: the shell's, else 1 when there is no way in.

Seams (tests): FLEET_SHELL_ARGV_CMD (in place of `fleet-connect.py --argv`;
`--offline` and the machine are appended), FLEET_SHELL_HUB_PROBE_CMD (exit 0 =
the hub answers). Standard library only.
"""
import json
import os
import shlex
import subprocess
import sys

BIN = os.path.dirname(os.path.abspath(__file__))
REMOTE = 'cd && FLEET_NO_VIEW=1 exec "${SHELL:-/bin/sh}" -l'
USAGE = "usage: fleet shell [<machine>] [--print]"


def say(text):
    sys.stderr.write("fleet · %s\n" % text)
    sys.stderr.flush()


def argv_answer(machine, offline):
    """fleet-connect --argv's JSON line, or (None, rc)."""
    seam = os.environ.get("FLEET_SHELL_ARGV_CMD")
    cmd = shlex.split(seam) if seam else [sys.executable or "python3", os.path.join(BIN, "fleet-connect.py"), "--argv"]
    if offline:
        cmd.append("--offline")
    if machine:
        cmd.append(machine)
    try:
        # stderr stays the terminal's: a renewal or a scan speaks there
        r = subprocess.run(cmd, stdout=subprocess.PIPE, timeout=300)
    except (OSError, subprocess.SubprocessError) as e:
        say("%s: %s" % (cmd[0], e))
        return None, 1
    try:
        j = json.loads(r.stdout.decode("utf-8", "replace").strip().splitlines()[-1])
    except (ValueError, IndexError):
        j = None
    if r.returncode == 0 and isinstance(j, dict) and ("argv" in j or j.get("local")):
        return j, 0
    if isinstance(j, dict) and isinstance(j.get("opening"), dict):
        say("入口正在为你开第一台机器，还没有能进的命令行；开好后再 fleet shell")
    return None, r.returncode or 1


def hub_answers():
    """True / False — None when there is no hub to ask (the --argv above already
    took the remembered routes then). Any HTTP answer is an answer."""
    seam = os.environ.get("FLEET_SHELL_HUB_PROBE_CMD")
    if seam:
        try:
            return subprocess.call(shlex.split(seam), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=30) == 0
        except (OSError, subprocess.SubprocessError):
            return False
    import importlib.util
    import urllib.error
    import urllib.request
    try:
        spec = importlib.util.spec_from_file_location("fleet_connect", os.path.join(BIN, "fleet-connect.py"))
        fc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fc)
        hub = os.environ.get("FLEET_HUB_URL") or fc.machine_conf_hub() or fc.load_hub_conf().get("url") or ""
    except (Exception, SystemExit):
        hub = ""
    if not hub:
        return None
    try:
        urllib.request.urlopen(hub.rstrip("/") + "/version", timeout=4).close()
        return True
    except urllib.error.HTTPError:
        return True
    except Exception:
        return False


def main(argv):
    machine, print_only = "", False
    for a in argv:
        if a in ("-h", "--help"):
            print(__doc__.split("\n\n")[0].split("\n", 1)[0])
            print(USAGE)
            return 0
        if a == "--print":
            print_only = True
        elif a.startswith("-") or machine:
            say("%s（%s）" % (USAGE, a))
            return 2
        else:
            machine = a
    j, rc = argv_answer(machine, False)
    if j is None:
        if hub_answers() is not False:
            say("没有进命令行的路线（原因见上）")
            return rc
        say("入口连不上：用这台电脑上次记住的路线")
        j, rc = argv_answer(machine, True)
        if j is None:
            return rc
    name = j.get("machine") or machine or "?"
    if j.get("local"):
        if print_only:
            print("local %s" % name)
            return 0
        say("%s 就是这台：本机的命令行（输入 fleet 回看台）" % name)
        os.chdir(os.path.expanduser("~"))
        os.environ["FLEET_NO_VIEW"] = "1"
        sh = os.environ.get("SHELL") or "/bin/sh"
        os.execvp(sh, ["-" + os.path.basename(sh)])
    a, h = list(j["argv"]), int(j["host"])
    cmd = a[:h] + ["-tt", "-o", "ControlMaster=no", "-o", "ControlPath=none"] + [a[h], REMOTE]
    route = (j.get("route") or {}).get("name") or "?"
    if print_only:
        print(" ".join(shlex.quote(c) for c in cmd))
        if (j.get("route") or {}).get("kind") == "relay":
            say("这条走入口中转，要这台电脑上的 fleet；手机上的 ssh App 请用入口端口（<入口>/fleet/keys）")
        else:
            say("钥匙 / 证书是这台电脑的；手机上的 ssh App 换成它自己的钥匙（<入口>/fleet/keys 加上）")
        return 0
    say("进 %s 的命令行（线路 %s）— 输入 fleet 回看台" % (name, route))
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        say("%s: %s" % (cmd[0], e.strerror))
        return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
