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
#               through unchanged; FLEET_PERSONAL_HOOKS is set to
#               $FLEET_CONF_DIR/personal-hooks, where the layer's programs land
#               (issue #1859), so a command spells `$FLEET_PERSONAL_HOOKS/<name>`
#   · filter    a JSON answer loses `updatedInput` from hookSpecificOutput (and
#               from a PermissionRequest's decision): a personal hook may let a
#               call through or refuse it, never rewrite what the fleet's own
#               hooks already handled (the heavy-job queue's prefix, a guard's
#               rewrite). Anything else it prints passes byte for byte.
#   · cut off   at FLEET_PERSONAL_HOOK_TIMEOUT seconds (default 10): the whole
#               process group is killed, one stderr line, exit 1 — Claude Code's
#               non-blocking error, so a hung hook never holds a session.
#   · switch off a hook that failed FLEET_PERSONAL_HOOK_STRIKES times in a row
#               (default 3) in this session — cut off, could not start, or any
#               exit but 0 / 2 (a deny is the hook doing its job): from then on
#               it is not run and the call passes (exit 0), so one broken line in
#               a person's layer does not tax every tool call on every machine
#               (issue #1862). The session is the wrapper's launch
#               (FLEET_WRAP_LAUNCH_ID, else the hook input's session_id); the
#               record is $FLEET_CONF_DIR/personal-hook-strikes/<session>/<hash>.off,
#               which the recovery page names and fleet-session-wrap.sh clears.
#   · stand down under FLEET_PERSONAL=0 — the recovery page's p, a session
#               opened without the personal layer: the hook is not run, exit 0.
#
# More than one argument after `--` runs them as argv (no shell). Exit: the
# command's own · 1 timed out / could not start · 2 bad usage (the hook then
# blocks, loudly — a malformed wiring is not something to pass silently).
command -v python3 >/dev/null 2>&1 || { echo "fleet-hook-personal: no python3" >&2; exit 1; }
exec python3 -c '
import hashlib, json, os, re, signal, subprocess, sys

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
# the programs the personal layer lands (#1859): a hook spells `$FLEET_PERSONAL_HOOKS/<name>`
os.environ["FLEET_PERSONAL_HOOKS"] = os.path.join(
    os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet"), "personal-hooks")
data = sys.stdin.buffer.read()
if os.environ.get("FLEET_PERSONAL") == "0":
    sys.exit(0)

# The strike record (issue #1862): one file per hook per session.
try:
    strikes = int(os.environ.get("FLEET_PERSONAL_HOOK_STRIKES") or 3)
except ValueError:
    strikes = 3
sess = os.environ.get("FLEET_WRAP_LAUNCH_ID") or ""
if not sess:
    try:
        sess = str(json.loads(data.decode("utf-8")).get("session_id") or "")
    except (ValueError, UnicodeDecodeError, AttributeError):
        sess = ""
sess = re.sub(r"[^A-Za-z0-9._-]", "_", sess)[:80]
rec = None
if sess and strikes > 0:
    conf = os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")
    rec = os.path.join(conf, "personal-hook-strikes", sess,
                       hashlib.sha256(("%s\0%s" % (event, "\0".join(cmd))).encode()).hexdigest()[:12])
    if os.path.exists(rec + ".off"):
        sys.exit(0)


def failed(why):
    """One more strike; at the limit the hook is off for the rest of the session."""
    if rec is None:
        return
    try:
        n = int(open(rec + ".n").read().strip() or 0) + 1
    except (OSError, ValueError):
        n = 1
    try:
        os.makedirs(os.path.dirname(rec), exist_ok=True)
        with open(rec + ".n", "w") as f:
            f.write("%d\n" % n)
        if n >= strikes:
            with open(rec + ".off", "w") as f:
                f.write("%s\t%s\t%s\n" % (event, " ".join(cmd).replace("\t", " ").replace("\n", " "), why))
            sys.stderr.write("fleet-hook-personal: %s hook failed %d times in a row (%s) — off for the rest of this session\n"
                             % (event, n, why))
    except OSError:
        pass


def passed():
    if rec is not None and os.path.exists(rec + ".n"):
        try:
            os.remove(rec + ".n")
        except OSError:
            pass


run = ["/bin/sh", "-c", cmd[0]] if len(cmd) == 1 else cmd
try:
    p = subprocess.Popen(run, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         start_new_session=True)
except OSError as e:
    sys.stderr.write("fleet-hook-personal: %s: %s\n" % (event, e))
    failed("could not start")
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
    failed("timed out after %gs" % limit)
    sys.exit(1)
if p.returncode in (0, 2):
    passed()
else:
    failed("exit %d" % p.returncode)


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
