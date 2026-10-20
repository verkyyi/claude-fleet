#!/usr/bin/env python3
# The one reap road, for both agents (T631, EPIC T580 C8). How a session's end is
# heard, which processes are agents, how a finished turn's leftover work is asked and
# which service an agent leaves behind are the adapter table's (`end`, `procs` /
# `proc_js`, `bg_probe`, `daemon` / `cred_home`); everything around them is one copy —
# bin/fleet-launch-lib.sh fleet_launch_end, bin/session-end-hook.sh --agent-exit,
# bin/fleet-reap-live.py, fleet_window_bg_busy and _fleet_agent_cred_daemons
# (bin/fleet-lib.sh). The same four legs run once as Claude and once as Codex:
#   exit      a walk-away runs the one close by the road the table names: Codex's
#             launcher calls --agent-exit after an exit 0; Claude's exec'd launcher
#             never does (its SessionEnd hook is the word — session-end-hook-selftest.sh
#             T631 runs the hook half for both)
#   killed    a non-zero exit closes nothing; while it runs the reaper sees the agent
#             (its process names / CLI argv off the table), once gone it does not
#   daemon    a service the agent leaves behind (Codex's app-server) is swept once its
#             session is over and kept while it lives; an agent with none has nothing
#             swept; an idle resident service is not work
#   work      a finished turn's real leftover work keeps the window at reap; an answer
#             that is not a clean «idle» keeps a `native` probe's window (#4318)
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_agent_adapter as adapter  # noqa: E402

REAP_LIVE = runpy.run_path(str(BIN / "fleet-reap-live.py"))
ENV = dict(os.environ, FLEET_SKIP_GLOBAL_CONF="1")


def sh(script, *args, env=None):
    return subprocess.run(["bash", "-c", script, "_", *map(str, args)], capture_output=True,
                          text=True, env=env or ENV, timeout=60)


class EndRoad(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="agent-end-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()   # lsof names /private/var, not /var
        self.env = dict(ENV, FLEET_CONF_DIR=str(self.root / "conf"))

    # --- exit ---------------------------------------------------------------------
    def launch_end(self, agent, rc):
        """fleet_launch_end <rc> as <agent>'s launcher, in a pane; the close it asks
        for is recorded instead of run."""
        fake = self.root / ("bin-" + agent)
        fake.mkdir(exist_ok=True)
        log = fake / "close"
        log.unlink(missing_ok=True)
        (fake / "session-end-hook.sh").write_text('printf "%%s " "$@" > %s\n' % log)
        r = sh('BIN=$1; LAUNCH_AGENT=$2; . "$3/fleet-launch-lib.sh"; fleet_launch_end "$4"; echo "pid=$$"',
               fake, agent, BIN, rc, env=dict(self.env, TMUX="isolated,1,0", TMUX_PANE="%1"))
        self.assertEqual(r.returncode, 0, r.stderr)
        pid = r.stdout.strip().rsplit("pid=", 1)[-1]
        return (log.read_text().strip() if log.exists() else ""), pid

    def leg_exit(self, agent):
        said, pid = self.launch_end(agent, 0)
        if adapter.get(agent, "end") == "exit":
            self.assertEqual(said, "--agent-exit %s %s" % (agent, pid))
        else:
            self.assertEqual(adapter.get(agent, "end"), "hook")
            self.assertEqual(said, "", "an exec'd agent's walk-away is its SessionEnd hook's")

    # --- killed -------------------------------------------------------------------
    def leg_killed(self, agent):
        for rc in (1, 130, 137):
            self.assertEqual(self.launch_end(agent, rc)[0], "", "rc %d must close nothing" % rc)
        for comm in adapter.get(agent, "procs").split():
            self.assertTrue(REAP_LIVE["agent_name"](comm, ""), comm)
            self.assertTrue(REAP_LIVE["agent_name"]("/opt/bin/" + comm, ""), comm)
        js = {"claude": "node /x/claude-code/cli.js", "codex": "node /x/@openai/codex/bin/codex.js"}[agent]
        self.assertEqual(REAP_LIVE["agent_name"]("node", js), agent)
        # gone: the pane's shell, a server it left, are not the agent
        self.assertIsNone(REAP_LIVE["agent_name"]("bash", "bash -c echo " + agent))
        self.assertIsNone(REAP_LIVE["agent_name"]("node", "node server.js"))

    # --- daemon -------------------------------------------------------------------
    def daemon_rows(self):
        r = sh('. "$1/fleet-lib.sh"; _fleet_agent_cred_daemons', BIN, env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return [line.split("\t") for line in r.stdout.splitlines() if line]

    def start_daemon(self, argv0, home):
        """A PPID=1 process named <argv0> holding a file open in <home>."""
        (home / "tmp").mkdir(parents=True, exist_ok=True)
        up = self.root / ("up-" + home.name)
        prog = self.root / (argv0 + ".py")
        prog.write_text("import sys, time\nf = open(sys.argv[1], 'w')\n"
                        "open(sys.argv[2], 'w').write('up')\ntime.sleep(60)\n")
        out = sh('( python3 "$1" "$2" "$3" </dev/null >/dev/null 2>&1 & echo $! )',
                 prog, home / "tmp" / "sock", up).stdout.strip()
        pid = int(out)
        self.addCleanup(lambda: subprocess.run(["kill", str(pid)], capture_output=True))
        until = time.monotonic() + 10
        while not up.exists() and time.monotonic() < until:
            time.sleep(0.05)
        return pid

    def leg_daemon(self, agent):
        dm, ch = adapter.get(agent, "daemon"), adapter.get(agent, "cred_home")
        st = self.root / "conf" / "cred-proxy"
        mine = lambda pid: [r for r in self.daemon_rows() if r[0] == str(pid)]
        if not dm:
            self.assertEqual(ch, "", "a cred_home with no daemon names nothing to sweep")
            # a process that looks like a service under another dir is never ours
            pid = self.start_daemon("fake-%s-app-server" % agent, st / ("%s-homes" % agent) / "s1")
            self.assertEqual(mine(pid), [])
        else:
            if shutil.which("lsof") is None and not Path("/proc").is_dir():
                self.skipTest("no lsof and no /proc: a daemon's home cannot be read")
            home = st / ch / "s1"
            (st / "sessions").mkdir(parents=True, exist_ok=True)
            (st / "sessions" / "s1").write_text("{}")
            pid = self.start_daemon("fake-%s-%s" % (agent, dm), home)
            self.assertEqual(mine(pid), [], "a live session's daemon is kept")
            (home / ".revoked").write_text("")
            rows = mine(pid)
            self.assertEqual([(r[2], r[3]) for r in rows], [(agent + "home", "s1")],
                             "an ended session's daemon is swept")
        # an idle resident service is not work: the probe answers a clean idle
        self.assertNotEqual(self.bg_busy(agent, py_rc=1), 0)

    # --- work ---------------------------------------------------------------------
    def bg_busy(self, agent, py_rc, py_out="", reap=True):
        """fleet_window_bg_busy on a window of <agent>, its python walk answering
        <py_rc> (0 busy · 1 idle · 2 unknown); the argv it was asked with in self.asked."""
        asked = self.root / "asked"
        asked.unlink(missing_ok=True)
        script = '''. "$1/fleet-lib.sh"
A=$2 ASKED=$3 RC=$4 OUT=$5
_fleet_tmux() { printf '%s\\n' "$A"; }
fleet_pane_claude_pid() { echo 4242; }
python3() { printf '%s\\n' "$*" > "$ASKED"; [ -n "$OUT" ] && printf '%s\\n' "$OUT" >&2; return "$RC"; }
fleet_window_bg_busy fleet @1 '' "$6"
'''
        r = sh(script, BIN, agent, asked, py_rc, py_out, "1" if reap else "",
               env=dict(self.env, TMUX="isolated,1,0"))
        self.asked = asked.read_text() if asked.exists() else ""
        return r.returncode

    def leg_work(self, agent):
        probe = adapter.get(agent, "bg_probe")
        self.assertEqual(self.bg_busy(agent, py_rc=0), 0, "real leftover work keeps the window")
        self.assertEqual(self.bg_busy(agent, py_rc=0, reap=False), 0)
        self.assertEqual("--pid 4242" in self.asked, probe == "pid", self.asked)
        unknown = self.bg_busy(agent, py_rc=2)
        if probe == "native":
            self.assertEqual(unknown, 0, "an unknown native answer never authorizes a reap")
            self.assertEqual(self.bg_busy(agent, py_rc=1, py_out="Traceback"), 0)
            self.assertNotEqual(self.bg_busy(agent, py_rc=2, reap=False), 0, "a Stop hook asks jobs only")
        else:
            self.assertNotEqual(unknown, 0)

    def legs(self, agent):
        for leg in (self.leg_exit, self.leg_killed, self.leg_daemon, self.leg_work):
            with self.subTest(agent=agent, leg=leg.__name__):
                leg(agent)

    def test_claude(self):
        self.legs("claude")

    def test_codex(self):
        self.legs("codex")

    def test_every_agent_has_an_end_road(self):
        self.assertEqual(sorted(adapter.ADAPTERS), ["claude", "codex"], "a new agent: add its test_")
        for agent, row in adapter.ADAPTERS.items():
            self.assertIn(row["end"], ("hook", "exit"), agent)
            self.assertIn(row["bg_probe"], ("pid", "native"), agent)
            self.assertTrue(row["procs"], agent)
            self.assertEqual(bool(row["daemon"]), bool(row["cred_home"]), agent)
        self.assertEqual(REAP_LIVE["ADAPTER"]["all_procs"](), ("claude", "codex", "codex-real"))
        # the shell copy says the same
        for agent in adapter.ADAPTERS:
            for col in ("end", "procs", "bg_probe", "daemon", "cred_home"):
                r = sh('. "$1/fleet-agent-adapter.sh"; fleet_agent_get "$2" "$3"', BIN, agent, col)
                self.assertEqual(r.stdout, adapter.get(agent, col), (agent, col))


if __name__ == "__main__":
    unittest.main()
