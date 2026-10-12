#!/usr/bin/env python3
"""fleet-machine-tasks.py — a node's machine-level work, run ONCE (issue #3546,
EPIC #3500 C1).

Every login on a shared node used to probe the same machine for itself — memory
pressure, total memory, load per core — on every capacity read and every spawn's
admission. The node daemon now does it once (its `machine-reading` task, every
15 s) and publishes the answer; a login whose fleet.conf says
FLEET_MACHINE_TASKS=off reads it (fleet_machine_reading in bin/fleet-lib.sh)
instead of probing.

  table                 print conf/node-tasks.tsv: which loop is the machine's and
                        which a login's
  table --check [ROOT]  exit 1, one line per finding, when a launchd template or a
                        node-daemon task / child has no row, a row names nothing,
                        or a template's class disagrees with the daemon's
                        MACHINE_UNITS (BREAK-IT per-login-machine-loops)
  probe                 the machine's reading as JSON on stdout
  tick [--out DIR]      write DIR/machine.json (default <FLEET_NODE_STATE>/cluster),
                        0644 through a fresh temporary file and one rename; DIR is
                        made 0755 when missing. A login trusts that file only in a
                        directory root owns and nobody else may write.

The file: one key per line, every value a string but `v` and `ts` —
  {"v": 1, "ts": <epoch>, "mem_probe": "<fleet_mem_probe line>",
   "mem_total_mb": "<n>", "load_per_core": "<x.yy>"}
An empty value is a probe that did not answer; the reader then probes itself.

The reading is fleet-lib.sh's OWN probes (fleet_mem_probe, fleet_mem_total_mb,
_fleet_load_per_core), run once with the switch off for this call — never a
second implementation of any of them.
"""
import json
import os
import re
import subprocess
import sys
import time

BIN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BIN)
KEYS = ("mem_probe", "mem_total_mb", "load_per_core")


def table_path(root=ROOT):
    return os.path.join(root, "conf", "node-tasks.tsv")


def read_table(root=ROOT):
    """[(name, kind, class, what)] — the rows of conf/node-tasks.tsv."""
    rows = []
    with open(table_path(root)) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            p = line.split("\t")
            rows.append(tuple((p + ["", "", "", ""])[:4]))
    return rows


def machine_units(root=ROOT):
    """The launchd units the table marks `machine`: never run once per login."""
    return sorted(n for n, k, c, _ in read_table(root) if k == "unit" and c == "machine")


def check(root=ROOT):
    out = []
    try:
        rows = read_table(root)
    except OSError as e:
        return ["no table: %s" % e]
    seen = set()
    for n, k, c, w in rows:
        if k not in ("unit", "machine"):
            out.append("%s: kind %r is not unit|machine" % (n, k))
        if c not in ("machine", "login"):
            out.append("%s: class %r is not machine|login" % (n, c))
        if k == "machine" and c != "machine":
            out.append("%s: a machine-table task is the machine's (class machine)" % n)
        if not w.strip():
            out.append("%s: no `what` — say why it is %s" % (n, c or "?"))
        if (n, k) in seen:
            out.append("%s: two %s rows" % (n, k))
        seen.add((n, k))
    units = set()
    ld = os.path.join(root, "launchd")
    for f in sorted(os.listdir(ld)) if os.path.isdir(ld) else []:
        m = re.match(r"^com\.claude-fleet\.(.+)\.plist\.tmpl$", f)
        if m:
            units.add(m.group(1))
    sup = os.path.join(root, "bin", "fleet-node-supervisor.py")
    try:
        with open(sup) as f:
            src = f.read()
    except OSError:
        src = ""
    tasks = set(re.findall(r'"name":\s*"([a-z0-9-]+)"', src))
    for u in sorted(units - {n for n, k, _, _ in rows if k == "unit"}):
        out.append("%s: launchd template with no row — machine or login?" % u)
    for t in sorted(tasks - {n for n, k, _, _ in rows if k == "machine"}):
        out.append("%s: node-daemon task with no row" % t)
    for n, k, c, _ in rows:
        if k == "unit" and n not in units:
            out.append("%s: row names no launchd template" % n)
        if k == "machine" and src and n not in tasks:
            out.append("%s: row names no node-daemon task" % n)
    return out


def probe():
    """The machine's reading, computed here by fleet-lib.sh's own probes."""
    env = dict(os.environ)
    env.pop("FLEET_MACHINE_TASKS", None)
    env["FLEET_SKIP_GLOBAL_CONF"] = "1"
    script = ('. "$1" >/dev/null 2>&1 || exit 1; FLEET_MACHINE_TASKS=; '
              'printf "%s\\n" "$(fleet_mem_probe 2>/dev/null)" "$(fleet_mem_total_mb 2>/dev/null)" '
              '"$(_fleet_load_per_core 2>/dev/null)"')
    try:
        p = subprocess.run(["/bin/bash", "-c", script, "_", os.path.join(BIN, "fleet-lib.sh")],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           env=env, timeout=20)
        vals = p.stdout.decode("utf-8", "replace").split("\n")
    except (OSError, subprocess.SubprocessError):
        vals = []
    vals = [v.strip() for v in vals] + ["", "", ""]
    r = {"v": 1, "ts": int(time.time())}
    for k, v in zip(KEYS, vals):
        # a value travels into an awk / shell reader: one line, no quote, no backslash
        r[k] = v if re.fullmatch(r"[0-9. ]*", v) else ""
    return r


def render(r):
    return "{\n" + ",\n".join('"%s": %s' % (k, json.dumps(r[k])) for k in ("v", "ts") + KEYS) + "\n}\n"


def write(out_dir, r):
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir, 0o755)
    dst = os.path.join(out_dir, "machine.json")
    tmp = os.path.join(out_dir, ".machine.json.%d" % os.getpid())
    try:
        os.unlink(tmp)
    except OSError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
    try:
        os.write(fd, render(r).encode())
        os.fchmod(fd, 0o644)
    finally:
        os.close(fd)
    os.rename(tmp, dst)
    return dst


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0 if argv else 2
    cmd = argv[0]
    if cmd == "table":
        if len(argv) > 1 and argv[1] == "--check":
            found = check(argv[2] if len(argv) > 2 else ROOT)
            for f in found:
                print("node-tasks: " + f)
            return 1 if found else 0
        for row in read_table():
            print("\t".join(row[:3]))
        return 0
    if cmd == "probe":
        sys.stdout.write(json.dumps(probe(), sort_keys=True) + "\n")
        return 0
    if cmd == "tick":
        out = os.path.join(os.environ.get("FLEET_NODE_STATE", "/var/db/fleet-node"), "cluster")
        if len(argv) > 2 and argv[1] == "--out":
            out = argv[2]
        dst = write(out, probe())
        if os.environ.get("FLEET_MACHINE_TASKS_VERBOSE") == "1":
            print(dst)
        return 0
    sys.stderr.write("fleet-machine-tasks: unknown %r (see --help)\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
