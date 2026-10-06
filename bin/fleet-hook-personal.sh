#!/bin/sh
# fleet-hook-personal.sh — run ONE personal hook, add-only (issue #1858, EPIC #1855 C3).
#
#   sh fleet-hook-personal.sh <Event> -- '<the person'"'"'s command>'
#
# fleet-agent-team.py wires every hook of the personal layer through this (the
# `claude.hooks.personal.<Event>.<key>` items; fleet-hooks-merge.py's
# personal_wrap spells the line). It does three things and nothing else:
#
#   · forward   the hook's stdin to the command (sh -c), its stderr and exit
#               code back — a deny (exit 2, or permissionDecision "deny") goes
#               through unchanged
#   · filter    a JSON answer loses `updatedInput` from hookSpecificOutput (and
#               from a PermissionRequest's decision): a personal hook may let a
#               call through or refuse it, never rewrite what the fleet's own
#               hooks already handled (the heavy-job queue's prefix, a guard's
#               rewrite). Anything else it prints passes byte for byte.
#   · cut off   at FLEET_PERSONAL_HOOK_TIMEOUT seconds (default 10): the whole
#               process group is killed, one stderr line, exit 1 — Claude Code's
#               non-blocking error, so a hung hook never holds a session.
#
# More than one argument after `--` runs them as argv (no shell). Exit: the
# command's own · 1 timed out / could not start · 2 bad usage (the hook then
# blocks, loudly — a malformed wiring is not something to pass silently).
command -v python3 >/dev/null 2>&1 || { echo "fleet-hook-personal: no python3" >&2; exit 1; }
exec python3 -c '
import json, os, signal, subprocess, sys

argv = sys.argv[1:]
if len(argv) < 3 or argv[1] != "--":
    sys.stderr.write("usage: fleet-hook-personal.sh <Event> -- <command>\n")
    sys.exit(2)
event, cmd = argv[0], argv[2:]
try:
    limit = float(os.environ.get("FLEET_PERSONAL_HOOK_TIMEOUT") or 10)
    if limit <= 0:
        raise ValueError
except ValueError:
    limit = 10.0
data = sys.stdin.buffer.read()
run = ["/bin/sh", "-c", cmd[0]] if len(cmd) == 1 else cmd
try:
    p = subprocess.Popen(run, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         start_new_session=True)
except OSError as e:
    sys.stderr.write("fleet-hook-personal: %s: %s\n" % (event, e))
    sys.exit(1)
try:
    out, err = p.communicate(data, timeout=limit)
except subprocess.TimeoutExpired:
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass
    p.kill()
    p.wait()
    sys.stderr.write("fleet-hook-personal: %s hook cut off after %gs (FLEET_PERSONAL_HOOK_TIMEOUT)\n" % (event, limit))
    sys.exit(1)


def strip(o):
    """True when an updatedInput was dropped."""
    hso = o.get("hookSpecificOutput") if isinstance(o, dict) else None
    if not isinstance(hso, dict):
        return False
    hit = hso.pop("updatedInput", None) is not None
    dec = hso.get("decision")
    if isinstance(dec, dict) and dec.pop("updatedInput", None) is not None:
        hit = True
    return hit


try:
    o = json.loads(out.decode("utf-8")) if out.strip() else None
except (ValueError, UnicodeDecodeError):
    o = None
if isinstance(o, dict) and strip(o):
    out = (json.dumps(o, ensure_ascii=False) + "\n").encode("utf-8")
    err += ("fleet-hook-personal: %s: updatedInput dropped — a personal hook allows or denies, never rewrites\n"
            % event).encode()
sys.stdout.buffer.write(out)
sys.stdout.flush()
sys.stderr.buffer.write(err)
sys.exit(p.returncode if p.returncode >= 0 else 1)
' "$@"
