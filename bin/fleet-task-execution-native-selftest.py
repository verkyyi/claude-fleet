#!/usr/bin/env python3
# selftest-entry
"""Actual wrapper/native starts against bounded fake agents and authority."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from fleet_task_execution import ExecutionFence, terminate_registered

BIN = Path(__file__).resolve().parent
FIXTURE = BIN.parent / "tokenledger/hub/store/testdata/task_execution.json"


class NativeExecutionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="task-native-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for filename in ("fleet_task_execution.py", "fleet_hub_common.py", "fleet_native_proc.py",
                         "fleet-session-wrap.sh", "fleet-agent-adapter.sh"):
            shutil.copy2(BIN / filename, self.bin / filename)
        (self.bin / "fleet-task-record.sh").write_text('''if [ "$1" = execution-list ]; then
          printf '{"control_version":1,"task_executions":['
          cat "$AUTHORITY_FILE"
          printf ']}\\n'
        else
          cat "$AUTHORITY_FILE"
        fi
''')
        self.snapshot = json.loads(FIXTURE.read_text())
        self.authority = self.root / "authority.json"
        self.authority.write_text(json.dumps(self.snapshot))
        self.fence = ExecutionFence(self.root / "conf")
        self.fence.bind(self.snapshot, authorized=True)
        self.native = self.root / "native.py"
        self.native.write_text('''import json,os,pathlib,sys,time
sys.path.insert(0, sys.argv[1])
from fleet_native_proc import process
root=pathlib.Path(os.environ['TEST_ROOT'])
(root/'native.json').write_text(json.dumps(process(os.getpid())))
assert 'FLEET_TASK_EXECUTION' not in os.environ
assert 'FLEET_TASK_LAUNCH_ID' not in os.environ
while not (root/'native-exit').exists(): time.sleep(.02)
''')
        self.launcher = self.root / "launcher.py"
        self.launcher.write_text('''#!/usr/bin/env python3
import os,pathlib,sys,time
root=pathlib.Path(os.environ['TEST_ROOT'])
(root/'initializing').touch()
while not (root/'release').exists(): time.sleep(.02)
cmd=[sys.executable,str(root/'bin/fleet_task_execution.py'),'native','--component','agent','--',
     sys.executable,str(root/'native.py'),str(root/'bin')]
os.execv(cmd[0],cmd)
''')
        self.launcher.chmod(0o700)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("FLEET_")
                    and key not in ("TMUX", "TMUX_PANE")}
        self.env.update(HOME=str(self.root), FLEET_CONF_DIR=str(self.root / "conf"),
                        AUTHORITY_FILE=str(self.authority), TEST_ROOT=str(self.root),
                        FLEET_WRAP_LAUNCH=str(self.launcher), FLEET_MCP="0",
                        FLEET_TASK_EXECUTION=json.dumps(self.snapshot),
                        PYTHONPATH=str(BIN))
        self.children = []
        self.addCleanup(self.cleanup_children)

    def cleanup_children(self):
        self.fence.request_stop("T42", "test-cleanup", generation=2)
        terminate_registered(self.fence, "T42")
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
            child.wait(timeout=3)
            child.stderr.close()

    def start(self, *, wrapper=True, env=None):
        args = (["bash", str(self.bin / "fleet-session-wrap.sh")] if wrapper else
                [sys.executable, str(self.bin / "fleet_task_execution.py"), "run", "--snapshot",
                 json.dumps(self.snapshot), "--", str(self.launcher)])
        child = subprocess.Popen(args, env=env or self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        return child

    def wait_file(self, name, child):
        deadline = time.monotonic() + 8
        while not (self.root / name).exists():
            if child.poll() is not None:
                self.fail("launch exited early: " + child.stderr.read())
            self.assertLess(time.monotonic(), deadline, "missing " + name)
            time.sleep(.02)

    def test_stop_during_launcher_initialization_never_execs_native(self):
        child = self.start()
        self.wait_file("initializing", child)
        self.fence.request_stop("T42", "stop", generation=2)
        (self.root / "release").touch()
        self.assertNotEqual(child.wait(timeout=8), 0)
        self.assertFalse((self.root / "native.json").exists())

    def test_fresh_authority_stop_before_native_exec_is_persisted(self):
        child = self.start()
        self.wait_file("initializing", child)
        self.authority.write_text(json.dumps(dict(self.snapshot, generation=2, cancel_request="hub-stop")))
        (self.root / "release").touch()
        self.assertNotEqual(child.wait(timeout=8), 0)
        self.assertFalse((self.root / "native.json").exists())
        self.assertEqual(self.fence.read("T42")["cancel_request"], "hub-stop")

    def test_running_native_stops_and_identical_grant_cannot_start_second(self):
        (self.root / "release").touch()
        first = self.start()
        self.wait_file("native.json", first)
        second = self.start()
        self.assertNotEqual(second.wait(timeout=8), 0)
        self.assertEqual(len(self.fence.launch("T42")["native"]), 1)
        self.fence.request_stop("T42", "stop", generation=2)
        self.assertNotEqual(first.wait(timeout=8), 0)
        proof = json.loads((self.root / "native.json").read_text())
        from fleet_task_execution import _definitely_exited
        self.assertTrue(_definitely_exited(dict(pid=proof["pid"], birth=proof["birth"])))

    def test_same_live_wrapper_can_wake_a_new_epoch_after_native_exit(self):
        (self.root / "release").touch()
        env = dict(self.env, FLEET_SESSION_WRAP=str(os.getpid()))
        first = self.start(wrapper=False, env=env)
        self.wait_file("native.json", first)
        original = self.fence.launch("T42")
        (self.root / "native-exit").touch()
        self.assertEqual(first.wait(timeout=8), 0)
        (self.root / "native-exit").unlink()
        (self.root / "native.json").unlink()
        second = self.start(wrapper=False, env=env)
        self.wait_file("native.json", second)
        current = self.fence.launch("T42")
        self.assertNotEqual(current["launch_id"], original["launch_id"])
        self.assertEqual(current["wrapper"], original["wrapper"])
        self.assertEqual(self.fence.read("T42"), self.snapshot)

    def test_native_refuses_offline_refresh_even_with_current_local_grant(self):
        child = self.start()
        self.wait_file("initializing", child)
        (self.bin / "fleet-task-record.sh").write_text("exit 1\n")
        (self.root / "release").touch()
        self.assertNotEqual(child.wait(timeout=8), 0)
        self.assertFalse((self.root / "native.json").exists())
        self.assertEqual(self.fence.read("T42")["cancel_request"], "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
