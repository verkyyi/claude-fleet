#!/usr/bin/env python3
# selftest-entry
"""A task with no coding agent asked for runs what its ASKER runs (T1381).

A Claude session's `task` / `spawn` opened Codex sessions on a machine whose
fleet.conf said FLEET_AGENT=codex (T1369, T1378, T1379). The order now:
explicit > the agent file's > the issue label's > the asking session's own >
the fleet's FLEET_AGENT > claude.

A  bin/fleet_dispatch.py resolve / its CLI: $FLEET_ORIGIN_AGENT sits between the
   label and the fleet default; an explicit choice, a template, a label and an
   accepted envelope still win; a value that is no provider is nothing.
B  bin/fleet-mcp.py spawn_env stamps the CALLER window's @cc_agent as
   $FLEET_ORIGIN_AGENT — never an inherited one, nothing outside a pane.
C  bin/fleet-lib.sh fleet_dispatch_default reads ahead the same order, and the
   three spawners (fleet-task-record.sh, dash-issue-session.sh,
   dash-raw-session.sh) ask it.
"""
import importlib.util
import json
import os
import subprocess
import sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import fleet_dispatch  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  " + str(detail)))
    fails += 0 if ok else 1


def got(**kw):
    d = fleet_dispatch.resolve(request_id="fixture", **kw)
    return d["resolved_agent"], d["requested_agent"], d["agent_source"]


# ---- A: the order --------------------------------------------------------------------
os.environ.pop("FLEET_ORIGIN_AGENT", None)
check("A: no asker: the fleet default", got(default="codex") == ("codex", "default", "fleet"))
check("A: no asker, no default: claude", got() == ("claude", "default", "default"))
check("A: a Claude asker on a codex fleet: claude", got(default="codex", origin="claude") == ("claude", "default", "fleet"))
check("A: a Codex asker on a claude fleet: codex", got(default="claude", origin="codex") == ("codex", "default", "fleet"))
check("A: explicit wins", got(explicit=["codex"], origin="claude") == ("codex", "codex", "explicit"))
check("A: the agent file's wins", got(template="codex", origin="claude", default="claude")[0] == "codex")
check("A: the label's wins", got(label="codex", origin="claude", default="claude")[0] == "codex")
check("A: no provider is nothing", got(default="codex", origin="") == ("codex", "default", "fleet"))
os.environ["FLEET_ORIGIN_AGENT"] = "claude"
check("A: read from the environment", got(default="codex")[0] == "claude")
os.environ["FLEET_ORIGIN_AGENT"] = "gpt"
check("A: a junk environment value is nothing", got(default="codex")[0] == "codex")
os.environ["FLEET_ORIGIN_AGENT"] = "claude"
accepted = dict(fleet_dispatch.resolve(["codex"], request_id="fixture-acc"), task="T17", generation=1, attempt_id="task:T17:g1")
check("A: an accepted envelope wins", fleet_dispatch.resolve(accepted=accepted)["resolved_agent"] == "codex")
cli = [sys.executable, os.path.join(BIN, "fleet_dispatch.py"), "--with-agent", "--request-id", "fixture-cli"]
for env_agent, args, want in (("claude", ["--default", "codex"], "claude"),
                              ("codex", ["--default", "claude"], "codex"),
                              ("claude", ["--default", "codex", "--agent", "codex"], "codex"),
                              ("", ["--default", "codex"], "codex")):
    env = dict(os.environ, FLEET_ORIGIN_AGENT=env_agent)
    out = subprocess.run(cli + args, env=env, capture_output=True, text=True)
    first = out.stdout.split("\n", 1)[0]
    check("A: CLI asker=%s %s -> %s" % (env_agent or "-", " ".join(args), want), out.returncode == 0 and first == want,
          out.stdout + out.stderr)
    if out.returncode == 0:
        envelope = json.loads(out.stdout.split("\n", 1)[1])
        check("A: CLI envelope validates (%s)" % want, fleet_dispatch.validate(envelope) == envelope)
os.environ.pop("FLEET_ORIGIN_AGENT", None)

# ---- B: the caller's agent, handed on -------------------------------------------------
spec = importlib.util.spec_from_file_location("fleet_mcp", os.path.join(BIN, "fleet-mcp.py"))
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)
mcp.hub_env = lambda ttl: None
mcp.CALLER["claims"] = None
for k in ("TMUX", "TMUX_PANE", "FLEET_FROM_FID", "FLEET_ORIGIN_AGENT"):
    os.environ.pop(k, None)
opts = {"#{@fleet_id}": "", "#{@cc_agent}": "codex"}
mcp.pane_opt = lambda fmt: opts.get(fmt, "")
check("B: outside a pane: nothing", mcp.spawn_env(60) is None)
os.environ.update(TMUX="/tmp/fixture,1,0", TMUX_PANE="%1")
env = mcp.spawn_env(60)
check("B: a Codex caller hands codex on", env is not None and env.get("FLEET_ORIGIN_AGENT") == "codex", env)
opts["#{@cc_agent}"] = "claude"
check("B: a Claude caller hands claude on", (mcp.spawn_env(60) or {}).get("FLEET_ORIGIN_AGENT") == "claude")
opts["#{@cc_agent}"] = ""
os.environ["FLEET_ORIGIN_AGENT"] = "codex"
env = mcp.spawn_env(60)
check("B: an inherited value never travels", env is not None and "FLEET_ORIGIN_AGENT" not in env, env)
opts["#{@cc_agent}"] = "something"
check("B: a word that is no provider is not", "FLEET_ORIGIN_AGENT" not in (mcp.spawn_env(60) or {}))
for k in ("TMUX", "TMUX_PANE", "FLEET_ORIGIN_AGENT"):
    os.environ.pop(k, None)

# ---- C: the shell's read-ahead and its callers ----------------------------------------
lib = os.path.join(BIN, "fleet-lib.sh")
for origin, fleet, want in (("claude", "codex", "claude"), ("codex", "claude", "codex"),
                            ("", "codex", "codex"), ("junk", "codex", "codex")):
    out = subprocess.run(["bash", "-c", '. "$1" >/dev/null 2>&1; FLEET_AGENT=$2 FLEET_ORIGIN_AGENT=$3 fleet_dispatch_default',
                          "_", lib, fleet, origin], capture_output=True, text=True,
                         env=dict(os.environ, FLEET_CONF_DIR=os.environ.get("FLEET_CONF_DIR", "/nonexistent-t1381")))
    check("C: fleet_dispatch_default asker=%s fleet=%s -> %s" % (origin or "-", fleet, want), out.stdout == want, out)
for name in ("fleet-task-record.sh", "dash-issue-session.sh", "dash-raw-session.sh"):
    with open(os.path.join(BIN, name), encoding="utf-8") as f:
        check("C: %s reads ahead through fleet_dispatch_default" % name, "$(fleet_dispatch_default)" in f.read())

print("dispatch-origin-agent selftest: %s" % ("OK" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
