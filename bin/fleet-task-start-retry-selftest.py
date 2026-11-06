#!/usr/bin/env python3
# selftest-entry
"""Refused starts retain their Task; module blank titles and recovery actions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_task_control as control
import fleet_start_result as result
import fleet_view as view
import fleet_node_http


class StartRetryTests(unittest.TestCase):
    def test_module_blank_title(self):
        spec = importlib.util.spec_from_file_location("dispatch_test", BIN / "fleet-quick-dispatch.py")
        dispatch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dispatch)
        for lang, want in (("zh", "新会话"), ("en", "New session")):
            dispatch.TEXT = {}
            seen = []
            def run(argv, **kwargs):
                seen.append(argv)
                return subprocess.CompletedProcess(argv, 4, "", "ALL_DECLINED")
            with patch.dict(os.environ, {"FLEET_UI_LANG":lang,"FLEET_DISPATCH_TASK_CMD":"fake-task"}), \
                 patch.object(dispatch, "fleet_of", return_value="fleet"), \
                 patch.object(dispatch, "hosted", return_value=["org/repo"]), \
                 patch.object(dispatch, "failed"), patch.object(dispatch, "task_answer", return_value=(False,"refused")), \
                 patch.object(dispatch.subprocess, "run", side_effect=run):
                dispatch.task_send({"repo":"org/repo","blank":True})
            self.assertEqual(seen[0][seen[0].index("--title")+1],want)

    def test_refusal_saved_on_same_generation(self):
        calls=[]
        with patch.object(fleet_node_http,"usable",return_value=True), \
             patch.object(fleet_node_http,"call",side_effect=lambda *args:(calls.append(args) or (200,"{}"))):
            result.record_failure({"task":"T42","generation":1},"ALL_DECLINED: capacity")
        method,path,body=calls[0]
        self.assertEqual((method,path),("POST","/v1/node/tasks/T42/start-failed"))
        self.assertEqual(json.loads(body),{"generation":1,"reason":"ALL_DECLINED: capacity"})

    def test_panel_retry_and_delete(self):
        row={"task":"T42","generation":1,"board":"id","record_only":True,"start_retry":True}
        self.assertEqual([a["id"] for a,_ in view.menu_of(row)],["retrystart","deletestart"])
        self.assertEqual([a["id"] for a,_,why in view.page_of(row) if not why and a["id"] != "archive"],["retrystart","deletestart"])
        for changed in ({"start_retry":False},{"running":True},{"lost":True},{"worker_id":"fleet/worker"},{"gone":True}):
            self.assertEqual(control.retry_start_task(dict(row,**changed)),"")
        calls=[]
        with patch.object(control.subprocess,"run",side_effect=lambda argv,**kw:(calls.append(argv) or subprocess.CompletedProcess(argv,0,"{}",""))):
            self.assertEqual(control.retry_task_start(row)[0],0)
        self.assertEqual(calls[0][2],"task_retry_start")
        self.assertEqual(json.loads(calls[0][3]),{"task":"T42","expected_generation":1})


if __name__ == "__main__":
    unittest.main()
