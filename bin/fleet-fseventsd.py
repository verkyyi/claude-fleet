#!/usr/bin/env python3
"""macOS machine watchdog: TERM fseventsd; launchd starts its replacement.

Root's minute task, also callable through the core's fixed machine-job table.
Only numeric settings are read from the machine's conf/fleet.conf. No tenant
config or commands enter this privileged path. CMPRS is attribution, not an
exact per-process swap counter; the displayed swap is system-wide.
"""
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fleet_tick_lock import acquire as acquire_tick_lock
from fleet_ps import rows as process_rows

DEFAULTS = {
    "FLEET_FSEVENTSD_WATCHDOG": 1,
    "FLEET_FSEVENTSD_RESTART_MB": 1024,
    "FLEET_FSEVENTSD_SWAP_MB": 8192,
    "FLEET_FSEVENTSD_COOLDOWN": 3600,
}
DAEMONS = {
    "/usr/sbin/fseventsd",
    "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/"
    "FSEvents.framework/Versions/A/Support/fseventsd",
}


def run(argv):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        return p.stdout if p.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def settings(conf):
    values = dict(DEFAULTS)
    try:
        lines = conf.read_text().splitlines()
    except OSError:
        lines = []
    for line in lines:
        m = re.fullmatch(r"\s*(?:export\s+)?(FLEET_FSEVENTSD_\w+)=['\"]?(\d+)['\"]?\s*(?:#.*)?", line)
        if m and m[1] in values:
            values[m[1]] = int(m[2])
    for key in values:
        value = os.environ.get(key, "")
        if value.isascii() and value.isdigit():
            values[key] = int(value)
    values["FLEET_FSEVENTSD_COOLDOWN"] = max(3600, values["FLEET_FSEVENTSD_COOLDOWN"])
    return values


def size_mb(value):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)([BKMGTP])", value)
    if not m:
        return None
    return float(m[1]) * (1024 ** ("BKMGTP".index(m[2]) - 2))


def swap_used(text):
    m = re.search(r"\bused\s*=\s*(\d+(?:\.\d+)?[BKMGTP])\b", text)
    return size_mb(m[1]) if m else None


def compressed_holder(text, pid):
    """Require a complete, parseable top table and a unique positive leader."""
    rows = []
    started = False
    for line in text.splitlines():
        cols = line.split()
        if cols == ["PID", "COMMAND", "CMPRS"]:
            started = True
            continue
        if not started or not cols:
            continue
        if len(cols) < 3 or not cols[0].isdigit():
            return None, False
        amount = size_mb(cols[-1])
        if amount is None:
            return None, False
        rows.append((int(cols[0]), amount))
    own = [n for p, n in rows if p == pid]
    if len(own) != 1:
        return None, False
    others = [n for p, n in rows if p != pid]
    return own[0], bool(others and own[0] > max(others) and own[0] > 0)


def probe(swap_limit=8192):
    sample = dict(pid=None, rss_mb=None, swap_mb=None, compressed_mb=None, biggest=False)
    if platform.system() != "Darwin":
        return sample
    sample["swap_mb"] = swap_used(run(["/usr/sbin/sysctl", "-n", "vm.swapusage"]))
    try:
        census = process_rows("uid,pid,rss,comm")
    except OSError:
        return sample
    for line in census.splitlines():
        cols = line.split(None, 3)
        if len(cols) != 4 or cols[0] != "0" or cols[3] not in DAEMONS:
            continue
        if not cols[1].isdigit() or not cols[2].isdigit():
            continue
        rss = int(cols[2]) / 1024
        if sample["rss_mb"] is None or rss > sample["rss_mb"]:
            sample.update(pid=int(cols[1]), rss_mb=rss)
    # The expensive system-wide attribution is needed only above the swap line.
    if sample["pid"] and swap_limit > 0 and sample["swap_mb"] is not None and sample["swap_mb"] >= swap_limit:
        text = run(["/usr/bin/top", "-l", "1", "-stats", "pid,command,cmprs"])
        sample["compressed_mb"], sample["biggest"] = compressed_holder(text, sample["pid"])
    return sample


def reason(sample, cfg):
    rss, swap = sample["rss_mb"], sample["swap_mb"]
    if not sample["pid"] or rss is None:
        return ""
    if cfg["FLEET_FSEVENTSD_RESTART_MB"] > 0 and rss >= cfg["FLEET_FSEVENTSD_RESTART_MB"]:
        return "rss"
    if cfg["FLEET_FSEVENTSD_SWAP_MB"] > 0 and swap is not None and swap >= cfg["FLEET_FSEVENTSD_SWAP_MB"] and sample["biggest"]:
        return "swap+compressed-holder"
    return ""


def restart():
    # Fixed daemon and uid, never a sampled/reused PID or an arbitrary command.
    subprocess.run(["/usr/bin/killall", "-TERM", "-u", "root", "fseventsd"],
                   check=True, capture_output=True, timeout=15)


def alert(message):
    subprocess.run(["/bin/bash", str(Path(__file__).with_name("fleet-alerts.sh")),
                    "event", "fseventsd", message], check=True,
                   capture_output=True, timeout=15)


def write_json(path, value):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def tick(state, cfg, now=None):
    if not cfg["FLEET_FSEVENTSD_WATCHDOG"]:
        return "disabled"
    state.mkdir(mode=0o755, parents=True, exist_ok=True)
    # Lock and timestamp survive supervisor/core restarts and hand-run ticks.
    fd = acquire_tick_lock(state / "lock")
    if fd is None:
        print("fleet-job: skip: busy fseventsd", file=sys.stderr)
        return "busy"
    with os.fdopen(fd, "w"):
        now = time.time() if now is None else now
        sample = probe(cfg["FLEET_FSEVENTSD_SWAP_MB"])
        why = reason(sample, cfg)
        write_json(state / "status.json", dict(sample, at=now, reason=why))
        if not why:
            return "healthy"
        stamp = state / "last-attempt.json"
        try:
            last = json.loads(stamp.read_text())["at"]
            if not isinstance(last, (float, int)):
                raise ValueError("invalid watchdog cooldown")
        except FileNotFoundError:
            last = None
        # A damaged cooldown fails closed; it never authorizes another signal.
        if last is not None and now - last < max(3600, cfg["FLEET_FSEVENTSD_COOLDOWN"]):
            return "cooldown"
        write_json(stamp, {"at": now})  # reserve the attempt BEFORE sending TERM
        event = dict(sample, at=now, reason=why, result="restarted")
        try:
            restart()
        except (OSError, subprocess.SubprocessError) as e:
            event.update(result="failed", error=type(e).__name__)
        with (state / "restarts.ndjson").open("a") as log:
            log.write(json.dumps(event) + "\n")
        message = "fseventsd watchdog %s (%s): RSS %s MiB, system swap %s MiB, compressed %s MiB; launchd restarts after TERM; cooldown %ss" % (
            event["result"], why, sample["rss_mb"], sample["swap_mb"], sample["compressed_mb"], max(3600, cfg["FLEET_FSEVENTSD_COOLDOWN"]))
        # Retain the alert as machine evidence even if the event transport fails.
        write_json(state / "alert.json", dict(event, message=message))
        print(message, flush=True)
        alert(message)
        return event["result"]


def doctor():
    sample = probe(0)
    def amount(n):
        return "unknown" if n is None else "%g MiB" % n
    return "fseventsd RSS %s; system swap %s" % (amount(sample["rss_mb"]), amount(sample["swap_mb"]))


def main():
    if platform.system() != "Darwin":
        return 0
    if sys.argv[1:] == ["doctor"]:
        print(doctor())
        return 0
    if sys.argv[1:] != ["tick"] or os.geteuid() != 0:
        print("usage: fleet-fseventsd.py tick (root) | doctor", file=sys.stderr)
        return 2
    node = Path(os.environ.get("FLEET_NODE_STATE", "/var/db/fleet-node"))
    conf = Path(os.environ.get("FLEET_CONF_DIR", str(node / "conf"))) / "fleet.conf"
    return 1 if tick(node / "fseventsd", settings(conf)) == "failed" else 0


if __name__ == "__main__":
    sys.exit(main())
