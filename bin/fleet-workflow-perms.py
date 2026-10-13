#!/usr/bin/env python3
"""fleet-workflow-perms.py [--root <repo>] [<workflow.yml> ...]
   — a caller job grants every permission its called workflow's jobs ask (issue #3908).

GitHub checks a reusable-workflow call at PARSE time: every job of the called
workflow — including one its `if:` would skip in this call (hub-deploy.yml's
`deploy` under `phase: build`) — may ask only for what the caller job's
`permissions:` grants. One too many and the whole run is `startup_failure`
before any job starts: no log, no red check, nothing the fail-fast or the
breakage probe can see. That stopped every release after #3893 (the `hub-build`
call granted contents + id-token; the nested `deploy` asks issues: write).

For every job `uses: ./.github/workflows/<x>.yml` this compares the caller's
permissions (the job's, else its workflow's top-level) with each nested job's
(the job's, else the called workflow's top-level); a nested job asking more is
one line `<file>:<line> job <caller> → <x>.yml job <nested>: asks <scope>: <level>,
granted <level>`. A caller with no permissions at all (the token's default) is
not judged. No PyYAML: a workflow's `permissions:` blocks are plain indented maps.

Exit: 0 every call fits · 1 a finding · 2 usage / unreadable file
"""
import os
import re
import sys

LEVEL = {"none": 0, "read": 1, "write": 2}
SCOPES = ("actions", "attestations", "checks", "contents", "deployments",
          "discussions", "id-token", "issues", "models", "packages", "pages",
          "pull-requests", "repository-projects", "security-events", "statuses")


def _indent(line):
    return len(line) - len(line.lstrip(" "))


def _code(line):
    """the line without a trailing comment (a quoted '#' stays)"""
    out, q = [], None
    for ch in line:
        if q:
            if ch == q:
                q = None
        elif ch in "'\"":
            q = ch
        elif ch == "#" and (not out or out[-1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()


def _inline(val):
    """permissions written on one line: read-all · write-all · {} · { a: b, ... }"""
    v = val.strip().strip("'\"")
    if v == "read-all":
        return {s: "read" for s in SCOPES}
    if v == "write-all":
        return {s: "write" for s in SCOPES}
    if v.startswith("{") and v.endswith("}"):
        body = v[1:-1].strip()
        perms = {}
        for part in filter(None, (p.strip() for p in body.split(","))):
            k, _, lv = part.partition(":")
            perms[k.strip()] = lv.strip().strip("'\"")
        return perms
    return None


def _block(lines, i, ind):
    """the map under lines[i] (a `permissions:` key at indent ind)"""
    head = _code(lines[i]).split(":", 1)[1]
    if head.strip():
        return _inline(head)
    perms = {}
    j = i + 1
    while j < len(lines):
        c = _code(lines[j])
        if c.strip():
            if _indent(c) <= ind:
                break
            k, _, lv = c.strip().partition(":")
            perms[k.strip()] = lv.strip().strip("'\"")
        j += 1
    return perms


def parse(path):
    """{'top': perms|None, 'jobs': {name: {'perms', 'uses', 'line'}}}"""
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    top, jobs, in_jobs, job = None, {}, False, None
    job_ind = None
    for i, raw in enumerate(lines):
        c = _code(raw)
        if not c.strip():
            continue
        ind = _indent(c)
        if ind == 0:
            in_jobs = c.startswith("jobs:")
            job = None
            if c.startswith("permissions:"):
                top = _block(lines, i, 0)
            continue
        if not in_jobs:
            continue
        if job_ind is None:
            job_ind = ind
        if ind == job_ind and re.match(r"^\s*[A-Za-z0-9_-]+:\s*$", c):
            job = c.strip()[:-1]
            jobs[job] = {"perms": None, "uses": None, "line": i + 1}
            continue
        if job is None or ind != job_ind + 2:
            continue
        key = c.strip()
        if key.startswith("permissions:"):
            jobs[job]["perms"] = _block(lines, i, ind)
        elif key.startswith("uses:"):
            jobs[job]["uses"] = key.split(":", 1)[1].strip().strip("'\"")
            jobs[job]["line"] = i + 1
    return {"top": top, "jobs": jobs}


def check(root, files):
    found = []
    wfdir = os.path.join(root, ".github", "workflows")
    for path in files:
        try:
            wf = parse(path)
        except OSError as e:
            print("fleet-workflow-perms: %s: %s" % (path, e), file=sys.stderr)
            return 2
        for name, job in wf["jobs"].items():
            uses = job["uses"] or ""
            m = re.match(r"^\./\.github/workflows/([^@/]+\.ya?ml)$", uses)
            if not m:
                continue
            granted = job["perms"] if job["perms"] is not None else wf["top"]
            if granted is None:
                continue  # the token's default: not ours to judge
            callee = os.path.join(wfdir, m.group(1))
            try:
                cw = parse(callee)
            except OSError as e:
                print("fleet-workflow-perms: %s: %s" % (callee, e), file=sys.stderr)
                return 2
            for nname, njob in cw["jobs"].items():
                asks = njob["perms"] if njob["perms"] is not None else cw["top"]
                for scope, lv in sorted((asks or {}).items()):
                    have = granted.get(scope, "none")
                    if LEVEL.get(lv, 0) > LEVEL.get(have, 0):
                        found.append("%s:%d job %s → %s job %s: asks %s: %s, granted %s"
                                     % (os.path.relpath(path, root), job["line"], name,
                                        m.group(1), nname, scope, lv, have))
    for line in found:
        print(line)
    return 1 if found else 0


def main(argv):
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    files = []
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--root" and args:
            root = args.pop(0)
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a.startswith("-"):
            print("fleet-workflow-perms: unknown argument %s" % a, file=sys.stderr)
            return 2
        else:
            files.append(a)
    root = os.path.abspath(root)
    if not files:
        d = os.path.join(root, ".github", "workflows")
        files = sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith((".yml", ".yaml")))
    return check(root, files)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
