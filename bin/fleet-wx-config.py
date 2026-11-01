#!/usr/bin/env python3
"""Change three non-secret WeChat settings on the hub box, never export site.env.

Invoked only by fleet-hub-aws-deploy.sh's wx-notify mode. The same host keeps a
0600 backup. All process output is captured; only allowlisted receipts leave it.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile

KEYS = ("CCQUOTA_WX_TPL_NEWREQ", "CCQUOTA_WX_TPL_NEWREQ_FIELDS", "CCQUOTA_WX_SUB_REVIEW")


def validate(values, admin):
    for value in (values[0], values[2]):
        if not re.fullmatch(r"[A-Za-z0-9_-]{20,100}", value):
            raise ValueError("template IDs must be registered WeChat IDs")
    fields = values[1].split(",")
    if not 2 <= len(fields) <= 5 or any(not re.fullmatch(r"[a-z_]+[0-9]+=(platform|person|time|count)", f) for f in fields):
        raise ValueError("invalid new-request field mapping")
    if len({f.split("=")[0] for f in fields}) != len(fields):
        raise ValueError("duplicate template field")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}", admin):
        raise ValueError("name one administrator GitHub login")


def replace_keys(original, values):
    # Keep unrelated lines byte for byte, including comments and credentials.
    chosen = dict(zip(KEYS, values))
    out, seen = [], set()
    for line in original.splitlines(keepends=True):
        key = line.split(b"=", 1)[0].decode("ascii", errors="replace")
        if key not in chosen:
            out.append(line)
        elif key not in seen:
            out.append((key + "=" + chosen[key] + "\n").encode())
            seen.add(key)
    if out and not out[-1].endswith(b"\n"):
        out.append(b"\n")
    out += [(key + "=" + chosen[key] + "\n").encode() for key in KEYS if key not in seen]
    return b"".join(out)


def atomic_write(path, content, owner):
    fd, tmp = tempfile.mkstemp(prefix=".wx-notify-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        os.fchown(fd, owner.st_uid, owner.st_gid)
        with os.fdopen(fd, "wb") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


class Rollout:
    def __init__(self, repo, conf, values, admin):
        self.repo, self.conf = Path(repo), Path(conf)
        self.site = self.conf.parent / "secrets/site.env"
        self.values, self.admin = values, admin
        self.k = ["k3s", "kubectl", "-n", "fleet-hub"]

    def run(self, argv, stage, timeout=900, env=None):
        try:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, start_new_session=True, env=env)
            try:
                stdout, stderr = p.communicate(timeout=timeout)
            except BaseException:
                # Kill the entire bootstrap/kubectl process group before undoing
                # its work, so a timed-out child cannot race the rollback.
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                p.communicate()
                raise
        except (OSError, subprocess.TimeoutExpired):
            raise RuntimeError(stage + " could not complete") from None
        if p.returncode:
            code = re.search(r"errcode [0-9]+", stderr)
            hint = " (" + code[0] + ")" if code else ""
            for safe in ("administrator has no followed service-account identity", "named administrator not found", "flag provided but not defined"):
                if safe in stderr:
                    hint = " (" + safe + ")"
            raise RuntimeError(stage + " failed" + hint)
        return stdout

    def pods(self):
        data = json.loads(self.run(self.k + ["get", "pods", "-l", "app=ccquota-hub", "-o", "json"], "list hub pods"))
        return [p["metadata"]["name"] for p in data["items"] if not p["metadata"].get("deletionTimestamp") and p["status"].get("phase") == "Running"]

    def probe(self, pod, dry, overrides=False):
        args = self.k + ["exec", pod, "-c", "ccquota", "--"]
        if overrides:
            args += ["env"] + [key + "=" + value for key, value in zip(KEYS, self.values)]
        args += ["ccquota", "hub", "--probe-wx-newreq", self.admin]
        if dry:
            args += ["--probe-wx-dry-run"]
        raw = self.run(args, "WeChat preflight" if dry else "WeChat real send", 90)
        receipt = json.loads(raw)
        if receipt.get("template_id") != self.values[0] or receipt.get("subscription_id") != self.values[2] or receipt.get("sent") != (not dry) or receipt.get("errcode") != 0:
            raise RuntimeError("WeChat probe returned an unexpected receipt")
        return {k: receipt[k] for k in ("template_id", "subscription_id", "sent", "errcode")}

    def apply(self):
        old = self.pods()
        env = os.environ.copy()
        env["FLEET_CORE_CONF"] = str(self.conf)
        # bootstrap reads secrets locally; its output never becomes an artifact.
        self.run(["bash", str(self.repo / "deploy/aws/k3s-box/bootstrap.sh"), "apply"],
                 "bootstrap apply", timeout=600, env=env)
        # envFrom Secret changes do not restart a Deployment on their own.
        self.run(self.k + ["rollout", "restart", "deployment/ccquota-hub"], "restart hub")
        self.run(self.k + ["rollout", "status", "deployment/ccquota-hub", "--timeout=10m"], "wait for hub")
        if old:
            self.run(self.k + ["wait", "--for=delete"] + ["pod/" + p for p in old] + ["--timeout=180s"], "wait for old hub pods", 200)

    def verify_env(self, expected):
        pods = self.pods()
        if not pods:
            raise RuntimeError("no running hub pods")
        # Print only the three named, non-secret values inside each container.
        script = "printf '%s\\n' " + " ".join('"${' + k + '-}"' for k in KEYS)
        for pod in pods:
            got = self.run(self.k + ["exec", pod, "-c", "ccquota", "--", "sh", "-c", script], "verify live template settings").splitlines()
            if got != list(expected):
                raise RuntimeError("live template settings differ from the requested values")
        return pods

    def execute(self):
        validate(self.values, self.admin)
        if self.site.is_symlink() or not self.site.is_file():
            raise RuntimeError("site.env must be an existing regular file")
        pods = self.pods()
        if not pods:
            raise RuntimeError("no running hub pods")
        self.probe(pods[0], dry=True, overrides=True)
        original, owner = self.site.read_bytes(), self.site.stat()
        backup_dir = Path(tempfile.mkdtemp(prefix="wx-notify-backup-", dir=self.site.parent))
        backup = backup_dir / "site.env"
        atomic_write(backup, original, owner)
        old_values = dict(line.split(b"=", 1) for line in original.splitlines() if b"=" in line)
        try:
            atomic_write(self.site, replace_keys(original, self.values), owner)
            self.apply()
            pods = self.verify_env(self.values)
            result = self.probe(pods[0], dry=False)
        except Exception:
            try:
                atomic_write(self.site, original, owner)
                self.apply()
                self.verify_env([old_values.get(k.encode(), b"").decode() for k in KEYS])
                print("wx-notify: failed; original site.env restored and running pods verified", flush=True)
            except Exception:
                raise RuntimeError("ROLLBACK FAILED; inspect the hub and retained backup on the box") from None
            raise
        # The backup stays on this root-only host for deliberate rollback.
        print("wx-notify: applied on all running hub pods; backup retained on the box", flush=True)
        print(json.dumps(result), flush=True)


def main():
    def interrupted(signum, frame):
        # Give an interrupted transaction a chance to restore the old config.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise RuntimeError("wx-notify: interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    p = argparse.ArgumentParser(description=__doc__)
    for key in ("repo", "conf", "newreq", "fields", "review-sub", "admin"):
        p.add_argument("--" + key, required=True)
    a = p.parse_args()
    try:
        Rollout(a.repo, a.conf, (a.newreq, a.fields, a.review_sub), a.admin).execute()
    except (ValueError, OSError, RuntimeError, subprocess.TimeoutExpired):
        # Exception details can contain subprocess output or JSON; never echo it.
        import sys
        error = sys.exc_info()[1]
        print(str(error) if isinstance(error, RuntimeError) else "wx-notify: invalid input or local operation failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
