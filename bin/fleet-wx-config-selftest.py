#!/usr/bin/env python3
# selftest-entry
"""Offline deployment transaction: no AWS account, real secrets or messages."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("wxconfig", Path(__file__).with_name("fleet-wx-config.py"))
wx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wx)
VALUES = ("new_template_123456789012345", "thing1=platform,thing2=person,time4=time", "subscription_123456789012345")
ORIGINAL = b"# retained\r\nSECRET=do-not-export\r\nCCQUOTA_WX_TPL_NEWREQ=old\nOTHER=x=y\nCCQUOTA_WX_TPL_NEWREQ=old\n"


class FakeRollout(wx.Rollout):
    def __init__(self, directory, failure=""):
        super().__init__(directory, Path(directory) / "deploy.env", VALUES, "admin")
        self.site.parent.mkdir()
        self.site.write_bytes(ORIGINAL)
        self.failure, self.applies, self.sends = failure, 0, 0
        self.initial_live = ["old", "", ""]
        self.live = list(self.initial_live)

    def pods(self):
        return ["hub-a", "hub-b"]

    def live_values(self):
        return {pod: list(self.live) for pod in self.pods()}

    def probe(self, pod, dry, overrides=False):
        if dry:
            assert self.site.read_bytes() == ORIGINAL
            assert overrides
            if self.failure == "preflight":
                raise RuntimeError("preflight failed")
        else:
            assert self.live == list(VALUES)
            self.sends += 1
            if self.failure == "send":
                raise RuntimeError("send failed")
        return {"sent": not dry, "errcode": 0}

    def apply(self):
        self.applies += 1
        if self.failure == "rollback" or (self.failure == "apply" and self.applies == 1):
            raise RuntimeError("apply failed")
        if self.site.read_bytes() == ORIGINAL:
            self.live = list(self.initial_live)
        else:
            self.live = list(VALUES)

    def verify_env(self, expected):
        if self.failure == "verify" and self.applies == 1:
            raise RuntimeError("live environment mismatch")
        assert self.live == list(expected)
        return self.pods()


class TransactionTests(unittest.TestCase):
    def test_rollback_checks_inherited_values_not_missing_file_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            r = FakeRollout(directory, "send")
            r.initial_live = ["old", "inherited-fields", "inherited-subscription"]
            r.live = list(r.initial_live)
            output = io.StringIO()
            with contextlib.redirect_stdout(output), self.assertRaisesRegex(RuntimeError, "send failed"):
                r.execute()
            self.assertEqual(r.live, r.initial_live)
            self.assertIn("restored and running pods verified", output.getvalue())

    def test_inspection_never_changes_or_sends(self):
        with tempfile.TemporaryDirectory() as directory:
            r = FakeRollout(directory)
            r.live_values = lambda: {"hub-a": ["old", "", ""], "hub-b": list(VALUES)}
            r.run = lambda argv, *args, **kwargs: json.dumps({"spec": {"template": {"spec": {"containers": [{"name": "ccquota", "env": [{"name": wx.KEYS[0], "value": "do-not-export"}], "envFrom": []}]}}}}) if "deployment" in argv else "b2xk\n\n\n"
            backup = r.site.parent / "wx-notify-backup-test"
            backup.mkdir()
            (backup / "site.env").write_bytes(ORIGINAL)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                r.inspect()
            report = json.loads(output.getvalue())
            self.assertTrue(report["site_matches_latest_backup"])
            self.assertFalse(report["site_matches_requested"])
            self.assertTrue(report["pods"][0]["matches_site"])
            self.assertTrue(report["pods"][1]["matches_requested"])
            self.assertEqual(report["explicit_env_keys"], [wx.KEYS[0]])
            self.assertTrue(report["pods"][0]["keys"][wx.KEYS[0]]["matches_site"])
            self.assertTrue(report["secret_keys"][wx.KEYS[0]]["matches_site"])
            self.assertEqual(r.site.read_bytes(), ORIGINAL)
            self.assertEqual((r.applies, r.sends), (0, 0))
            self.assertNotIn("do-not-export", output.getvalue())

    def test_whitelist_preserves_unrelated_bytes(self):
        out = wx.replace_keys(ORIGINAL, VALUES)
        unrelated = lambda b: b"".join(line for line in b.splitlines(keepends=True) if not any(line.startswith(k.encode() + b"=") for k in wx.KEYS))
        self.assertEqual(unrelated(out), unrelated(ORIGINAL))
        for key, value in zip(wx.KEYS, VALUES):
            self.assertEqual(out.count(key.encode() + b"="), 1)
            self.assertIn((key + "=" + value + "\n").encode(), out)

    def test_bad_inputs_refused(self):
        for values, admin in [(VALUES, "admin;id"), (("x\nTOKEN=y", *VALUES[1:]), "admin"), ((VALUES[0], "thing1=person,thing1=time", VALUES[2]), "admin")]:
            with self.assertRaises(ValueError):
                wx.validate(values, admin)

    def test_success_and_failures(self):
        for failure in ("", "preflight", "apply", "verify", "send", "rollback"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                r = FakeRollout(directory, failure)
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    if failure:
                        with self.assertRaises(RuntimeError) as error:
                            r.execute()
                        if failure == "rollback":
                            self.assertIn("ROLLBACK FAILED", str(error.exception))
                            self.assertIn("transaction failed: apply failed", output.getvalue())
                            self.assertIn("rollback failed: apply failed", output.getvalue())
                    else:
                        r.execute()
                self.assertNotIn("do-not-export", output.getvalue())
                self.assertEqual(r.sends, int(failure in ("", "send")))
                self.assertEqual(r.applies, 0 if failure == "preflight" else 1 if not failure else 2)
                self.assertEqual(r.site.read_bytes(), ORIGINAL if failure else wx.replace_keys(ORIGINAL, VALUES))
                backups = list(r.site.parent.glob("wx-notify-backup-*/site.env"))
                self.assertEqual(len(backups), 0 if failure == "preflight" else 1)
                for backup in backups:
                    self.assertEqual(backup.read_bytes(), ORIGINAL)
                    self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(backup.parent.stat().st_mode & 0o777, 0o700)

    def test_subprocess_errors_do_not_export_stderr(self):
        r = wx.Rollout("/unused", "/unused/deploy.env", VALUES, "admin")
        with self.assertRaises(RuntimeError) as error:
            r.run(["sh", "-c", "echo secret-token >&2; exit 1"], "safe stage")
        self.assertEqual(str(error.exception), "safe stage failed")

    def test_ssm_payload_compiles_and_has_only_named_keys(self):
        command = ["bash", str(Path(__file__).with_name("fleet-hub-aws-deploy.sh")), "script", "wx-notify", *VALUES, "admin"]
        script = subprocess.check_output(command, text=True)
        subprocess.run(["bash", "-n"], input=script, text=True, check=True)
        source = script.split("<<'WX_CONFIG_PY'\n", 1)[1].rsplit("\nWX_CONFIG_PY", 1)[0]
        compile(source, "<ssm>", "exec")
        self.assertNotIn("do-not-export", script)
        command[-1] = "admin\n'; echo injected; #"
        bad = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(bad.returncode, 0)
        self.assertEqual(bad.stdout, "")


if __name__ == "__main__":
    unittest.main()
