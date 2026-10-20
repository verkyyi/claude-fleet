#!/usr/bin/env python3
"""Explicit task-authority migration; no GitHub call or background worker.

The authority is this login's PERSON's (issue #4901, the hub's #4896): the hub
keeps one row per person, and this login's selection is fleet.conf [node]'s
FLEET_TASK_AUTHORITY. A repo is only a parameter — it names a local start's
worktree, or narrows a manifest's lists — and never takes part in a fence.

The manifest is a read-only inventory. Mutations name that manifest, so both
the hub revision and this login's setting are checked before a cutover.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import fleet_hub_rest as hubrest
import fleet_native_proc as proc

BIN = Path(__file__).resolve().parent


def repo_identity(value):
    # Authority takes an explicit owner/repo, not a URL/path. GitHub casing is
    # identity-equivalent; the local registration's spelling is NOT a path to rename.
    if not isinstance(value, str):
        raise ValueError("repo must be an explicit owner/repo string")
    repo = hubrest.norm_repo(value)
    if not repo or repo != value.lower() or any(p in (".", "..") for p in repo.split("/")):
        raise ValueError("select one owner/repo explicitly (no URL, path or surrounding whitespace)")
    return repo


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or str(Path.home() / ".config/claude-fleet"))


AUTH_LINE = re.compile(rb"^[ \t]*(export[ \t]+)?FLEET_TASK_AUTHORITY=")


NODE_GUARD = (b'if [ "${FLEET_SHELL:-0}" != 1 ]; then', b"fi  # ---- [node] end ----", b":")


def login_settings():
    # This login's selection (issue #4901): fleet.conf [node]'s line, the one the
    # sync and the cutover write. The rest of the file's settings are digested
    # apart — blank lines, comments and the [node] guard aside, which the first
    # write may add — so an exact repeat of a stage is still recognised.
    path = conf_dir() / "fleet.conf"
    raw = path.read_bytes() if path.is_file() else b""
    mode, rest = "", []
    for line in raw.splitlines(keepends=True):
        bare = line.strip()
        if AUTH_LINE.match(line):
            mode = line.split(b"=", 1)[1].strip().strip(b"\"'").decode("utf-8", "replace")
        elif bare and not bare.startswith(b"#") and bare not in NODE_GUARD:
            rest.append(line)
    return dict(settings=dict(FLEET_TASK_AUTHORITY=mode), sha256=hashlib.sha256(raw).hexdigest(),
                base_sha256=hashlib.sha256(b"".join(rest)).hexdigest()), path


def overlay_lines():
    # compat-1v: 下一批删 — repo overlays still spelling the old per-repo line
    # (fleet-conf.sh migrate comments them out; fleet_task_authority reads one).
    found = []
    for f in sorted(conf_dir().glob("fleets/*/repos/*.conf")):
        try:
            if any(AUTH_LINE.match(line) for line in f.read_bytes().splitlines()):
                found.append(str(f))
        except OSError:
            pass
    return found


def manifest(repo=None):
    local, path = login_settings()
    query = {"rollback": "1"}
    if repo:
        query["repo"] = repo_identity(repo)
    data = hubrest.api("GET", "/authority", query=query)
    owner = (data.get("authority") or {}).get("owner", "") if isinstance(data, dict) else ""
    return dict(version=2, scope="owner", owner=owner, conf=str(path), repo=repo_identity(repo) if repo else "",
                local=local, hub=data, scope_note="fixture/source until separately live-accepted",
                preserved=["FLEET_FORGE", "FLEET_LAND", "existing ticket/PR references"])


def update_local(mode):
    # Only this login's [node] line is written, through the config file's one
    # writer; every repo's ticket home / forge / land stays byte for byte, and old
    # issue integers are never reinterpreted.
    env = dict(os.environ, FLEET_CONF_DIR=str(conf_dir()))
    subprocess.run(["bash", str(BIN / "fleet-conf.sh"), "set-node", "FLEET_TASK_AUTHORITY",
                    'FLEET_TASK_AUTHORITY="%s"' % mode], env=env, check=True, capture_output=True, text=True)


def conf_lock():
    path = conf_dir() / "fleet.conf.authority.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    return open(str(path), "a")


def sync(repo=None):
    # This login follows its person's selection (issues #4730, #4901): the hub
    # says "re-read" (once per repo a capable host hosts — any of them will do);
    # the mode is read back here with this node's own credential, never taken
    # from the push. Unknown leaves the setting alone; legacy with no line (and
    # no old overlay line to outvote) stays byte for byte.
    a = hubrest.api("GET", "/authority", query={"gate": "1"})
    mode = a.get("mode") if isinstance(a, dict) else None
    if mode not in ("legacy", "frozen", "hub"):
        raise ValueError("task authority is unknown; this login's setting left as it is")
    changed = []
    with conf_lock() as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        local, path = login_settings()
        current = local["settings"]["FLEET_TASK_AUTHORITY"]
        if current != mode and not (mode == "legacy" and not current and not overlay_lines()):
            update_local(mode)
            changed.append(path.name)
    print(json.dumps(dict(repo=repo_identity(repo) if repo else "", owner=a.get("owner", ""), mode=mode,
                          revision=a.get("revision"), changed=changed)))


NATIVE_KEYS = ("worker_id", "native_session", "pid", "birth", "executable")


def init_new(repo):
    # A new repo selects nothing any more (issue #4901): the authority is the
    # person's. Kept one version for an older caller — says legacy, asks nothing.
    # compat-1v: 下一批删
    repo_identity(repo)
    print("legacy")
    print("task authority: a new repo selects nothing — it is this login's person's (issue #4901)", file=sys.stderr)


def prove_stopped(proof):
    # Permission/probe failure is UNKNOWN. Only ESRCH or a positively observed
    # different identity confirms the witnessed process stopped.
    try:
        os.kill(proof["pid"], 0)
    except ProcessLookupError:
        pass
    else:
        observed = proc.process(proof["pid"])
        if proc.same_identity(observed, proof):
            raise ValueError("native execution is still alive")
    proof["execution_stopped"] = True
    return proof


def gate(repo, finish):
    # The person's authority decides (issue #4901): frozen refuses every start,
    # unknown is never a fallback. Nothing is claimed or reserved any more (EPIC
    # T497 C8, design §6 B): a window's start is admitted by its own ID, which
    # every spawner stamps before its agent runs. <finish> is the spawner's last
    # look before the window opens — the same question, asked again.
    repo_identity(repo)
    a = hubrest.api("GET", "/authority", query={"gate": "1"})
    if not isinstance(a, dict) or a.get("mode") not in ("legacy", "frozen", "hub"):
        raise ValueError("task authority is unknown; no local fallback")
    if a["mode"] == "frozen":
        raise ValueError("your dispatch is frozen; drain/cutover must finish first")
    print(json.dumps(dict(mode=a["mode"], ticket_ref="")))


def start_call(repo, key, action, **fields):
    return hubrest.api("POST", "/authority/start", query={"repo": repo_identity(repo)},
                      body=dict(action=action, reservation=key, **fields))


# The environment of the layers C8 retired (the launch proof, the local start
# reservation, the ID switch's admission): a session they started hands none on.
RETIRED_ENV = ("FLEET_LAUNCH", "FLEET_LAUNCH_CONTEXT", "FLEET_LAUNCH_SUPERVISOR", "FLEET_LAUNCH_NATIVE",
               "FLEET_LAUNCH_WORKTREE", "FLEET_LAUNCH_CREATE", "FLEET_LAUNCH_DELIVERY",
               "FLEET_AUTHORITY_CONTEXT", "FLEET_AUTHORITY_ADMISSION", "FLEET_AUTHORITY_START",
               "FLEET_AUTHORITY_EXPECTED", "FLEET_AUTHORITY_RESUME_SID", "FLEET_ID_DISPATCH")


def supervise(argv):
    """A window's agent start (EPIC T497 C8). The gate is «the window has an ID»
    — its @fleet_id, stamped by the spawner before the agent runs — so nothing is
    reserved, claimed or observed: the launcher is exec'd as it is, without the
    environment a retired layer may have handed a session started before it."""
    env = {k: v for k, v in os.environ.items() if k not in RETIRED_ENV}
    os.execvpe(argv[0], argv, env)


SETTLE_MIN_AGE = 600  # a start that moved within this is still on its way: left alone


def held_text():
    """Every place a live local start can be held on this login: each fleet
    window's @authority_receipt, and each of its processes' environment and
    argv (a spawner's FLEET_AUTHORITY_START, a supervisor child's
    FLEET_AUTHORITY_CONTEXT, a pane's launch line). None = could not look,
    and nothing may then be called unheld."""
    try:
        wins = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh"; fleet_list_windows_all "#{@authority_receipt}"',
                               "_", str(BIN)], capture_output=True, text=True, check=True, timeout=30).stdout
        if sys.platform.startswith("linux"):
            procs = []
            for d in Path("/proc").iterdir():
                if d.name.isdigit():
                    for name in ("environ", "cmdline"):
                        try:
                            procs.append((d / name).read_bytes().decode("utf-8", "replace"))
                        except OSError:
                            pass  # gone, or another login's: not ours to hold
            procs = "\n".join(procs)
        else:
            procs = subprocess.run(["ps", "-Eaxww", "-o", "command="], capture_output=True,
                                   text=True, check=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return wins + "\n" + procs


def start_age(updated, now):
    # The journal's RFC3339Nano, UTC — read by the one ISO reader.
    import fleet_iso
    return now - fleet_iso.parse(updated, utc=True).timestamp()


def settle_plan(start, held, now):
    """One start of this node -> (action, why); action "" = left alone."""
    key, phase = start.get("reservation"), start.get("phase")
    try:
        if start_age(start.get("updated") or "", now) < SETTLE_MIN_AGE:
            return "", "recent"
    except ValueError:
        return "", "unknown"
    if phase in ("reserved", "starting"):
        if held is None:
            return "", "unknown"
        if key in held:
            return "", "held"
        if phase == "reserved":
            return "cancel", "no live window holds it"
        if start.get("native_identity") or not start.get("worker_id"):
            return "", "unknown"
        return "unobserved", "begun, no native, no live window holds it"
    if phase == "observed":
        native = start.get("native_identity")
        if not isinstance(native, dict) or any(native.get(k) in (None, "") for k in NATIVE_KEYS):
            return "", "unknown"
        try:
            prove_stopped(dict(native))
        except ValueError as exc:
            return "", "alive" if "still alive" in str(exc) else "unknown"
        except (OSError, KeyError, TypeError, subprocess.SubprocessError):
            return "", "unknown"
        return "stopped", "native process proven stopped"
    return "", "unknown"


def authority_log(line):
    conf = os.environ.get("FLEET_CONF_DIR") or str(Path.home() / ".config/claude-fleet")
    path = Path(conf) / "logs" / "authority.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a") as out:
        out.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + " " + line + "\n")


def hosted_repos():
    """Every repo a fleet of this login hosts, canonical and once each: the
    local starts a person's settle walks when no repo is named (issue #4901)."""
    script = '. "$1/fleet-lib.sh"; fleet_each_conf | while IFS=$\'\\t\' read -r s c; do [ -n "$s" ] && fleet_repos "$s"; done'
    out = subprocess.run(["bash", "-c", script, "_", str(BIN)], capture_output=True, text=True, check=True).stdout
    repos = []
    for line in out.split():
        r = hubrest.norm_repo(line)
        if r and r not in repos:
            repos.append(r)
    return repos


def settle(repo, apply):
    """One repo's settle (below), else every hosted repo's, printed as one doc;
    either way with this node's stale worker_starts (settle_operations)."""
    if repo:
        doc = settle_one(repo, apply)
        doc["operations"] = settle_operations(apply)
        print(json.dumps(doc, indent=2))
        return
    docs = [settle_one(r, apply) for r in hosted_repos()]
    counts = {}
    for d in docs:
        for k, v in d["counts"].items():
            counts[k] = counts.get(k, 0) + v
    print(json.dumps(dict(repo="", endpoint_id=docs[0]["endpoint_id"] if docs else "", apply=apply,
                          counts=counts, repos=docs, operations=settle_operations(apply)), indent=2))


def local_operation(op_id):
    """This login's control journal's word on op_id: None = never accepted
    here, else its local status. Raises OSError when there is no journal to
    read — then nothing may be called never accepted."""
    import sqlite3
    path = conf_dir() / "control" / "state.sqlite3"
    if not path.is_file():
        raise OSError("no control journal at %s" % path)
    try:
        db = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=10)
        try:
            row = db.execute("SELECT status FROM operations WHERE id=?", (op_id,)).fetchone()
        finally:
            db.close()
    except sqlite3.Error as exc:
        raise OSError(str(exc)) from exc
    return None if row is None else row[0]


def operation_plan(op, held, now, min_age):
    """One stale worker_start of this node -> (local, why); local "" = kept.
    Abandoned only when this login never ran it: its journal has no such
    operation or journalled it failed, and no window or process names it."""
    op_id = op.get("operation_id") or ""
    try:
        if start_age(op.get("created") or "", now) < min_age:
            return "", "recent"
    except ValueError:
        return "", "unknown"
    if held is None:
        return "", "unknown"
    if op_id in held:
        return "", "held"
    try:
        local = local_operation(op_id)
    except OSError:
        return "", "unknown"
    if local is None:
        return "not_accepted", "this machine has no record of it"
    if local == "failed":
        return "failed", "this machine journalled it failed"
    return "", "local " + str(local)


def settle_operations(apply):
    """Abandon this node's stale worker_starts (issue #4978): an open start of
    one of this login's fleets, older than the hub's min age, that this login
    never ran (operation_plan) ends START_ABANDONED, audited on the hub. A hub
    from before it answers None."""
    try:
        data = hubrest.api("GET", "/authority/operation")
    except hubrest.Fail as exc:
        if "HTTP 404" in str(exc):
            return None
        raise
    ops = data.get("operations") if isinstance(data, dict) else None
    min_age = data.get("min_age_seconds") if isinstance(data, dict) else None
    if not isinstance(ops, list) or not isinstance(min_age, int) or min_age <= 0:
        raise ValueError("the Hub answered no list of this node's starts")
    held, now = held_text(), time.time()
    counts, plan = {}, []
    for op in ops:
        if not isinstance(op, dict) or not isinstance(op.get("operation_id"), str):
            continue
        local, why = operation_plan(op, held, now, min_age)
        row = dict(operation_id=op["operation_id"], fleet_id=op.get("fleet_id") or "", status=op.get("status") or "",
                   action="abandon" if local else "keep", why=why)
        if local and apply:
            try:
                ack = hubrest.api("POST", "/authority/operation", {"operation_id": op["operation_id"], "local": local})
                if not isinstance(ack, dict) or ack.get("operation_id") != op["operation_id"] or ack.get("status") != "failed":
                    raise ValueError("abandon acknowledgement differs")
                row["result"] = "abandoned"
            except (hubrest.Fail, ValueError) as exc:
                row["result"] = "failed: " + error_reason(exc)
            authority_log("settle operation=%s fleet=%s local=%s result=%s" % (
                row["operation_id"], row["fleet_id"] or "-", local, row["result"]))
        bucket = row.get("result", "abandon" if local else why)
        if bucket.startswith("failed"):
            bucket = "failed"
        counts[bucket] = counts.get(bucket, 0) + 1
        plan.append(row)
    return dict(apply=apply, counts=counts, operations=plan)


def settle_one(repo, apply):
    """Close this node's own dead local starts with the existing actions
    (issue #4832): reserved and unheld -> cancel, begun with no native and
    unheld -> unobserved, observed whose native is proven stopped -> stopped.
    Everything else stays, counted by why. Dry unless apply."""
    repo = repo_identity(repo)
    try:
        data = hubrest.api("GET", "/authority/start", query={"repo": repo, "list": "1"})
    except hubrest.Fail as exc:
        if "one explicit reservation" not in str(exc):
            raise
        data = None  # a Hub from before the list: it asks for one reservation
    starts = data.get("starts") if isinstance(data, dict) else None
    endpoint = data.get("endpoint_id") if isinstance(data, dict) else None
    if not isinstance(starts, list) or not isinstance(endpoint, str) or not endpoint:
        raise ValueError("the Hub cannot list this node's starts (needs a Hub with issue #4832)")
    held, now = held_text(), time.time()
    counts, plan = {}, []
    for start in starts:
        if (not isinstance(start, dict) or start.get("endpoint_id") != endpoint
                or hubrest.norm_repo(start.get("repo") or "") != repo or not start.get("reservation")):
            action, why = "", "unknown"  # never another node's, never a malformed row
        else:
            action, why = settle_plan(start, held, now)
        row = dict(reservation=start.get("reservation") if isinstance(start, dict) else None,
                   phase=start.get("phase") if isinstance(start, dict) else None,
                   worker_id=(start.get("worker_id") or "") if isinstance(start, dict) else "",
                   action=action or "keep", why=why)
        if action and apply:
            want = {"cancel": "cancelled", "unobserved": "abandoned", "stopped": "stopped"}[action]
            fields = {}
            if action == "unobserved":
                fields["worker_id"] = start["worker_id"]
            if action == "stopped":
                fields.update(native_identity={k: start["native_identity"][k] for k in NATIVE_KEYS},
                              execution_stopped=True)
            try:
                ack = start_call(repo, start["reservation"], action, **fields)
                if not isinstance(ack, dict) or ack.get("reservation") != start["reservation"] or ack.get("phase") != want:
                    raise ValueError("authority acknowledgement differs")
                row["result"] = want
            except (hubrest.Fail, ValueError) as exc:
                row["result"] = "failed: " + error_reason(exc)
            authority_log("settle repo=%s reservation=%s phase=%s worker=%s action=%s result=%s" % (
                repo, row["reservation"], row["phase"], row["worker_id"] or "-", action, row["result"]))
        bucket = row.get("result", action or why)
        if bucket.startswith("failed"):
            bucket = "failed"
        counts[bucket] = counts.get(bucket, 0) + 1
        plan.append(row)
    return dict(repo=repo, endpoint_id=endpoint, apply=apply, counts=counts, starts=plan)


def match_ticket_ref(repo, number, ref):
    repo = repo_identity(repo)
    backend, bound_repo, bound_number = hubrest.parse(ref)
    if (repo_identity(bound_repo) != repo or str(bound_number) != str(number)
            or ref != "%s:%s#%s" % (backend, bound_repo, number)):
        raise ValueError("accepted ticket reference differs from this window's binding")
    return backend


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    # The repo is a parameter, never the authority's scope (issue #4901): it names
    # a start's worktree (gate / finish / cancel-start), narrows a manifest's
    # lists, or is ignored (sync). The authority is this login's person's.
    p.add_argument("repo", nargs="?", default="")
    p.add_argument("--session", default="", help="ignored: the authority is the login's (issue #4901)")
    actions = p.add_mutually_exclusive_group()
    for a in ("dry-run", "freeze", "apply", "rollback", "gate", "finish", "sync", "settle"):
        actions.add_argument("--" + a, action="store_true")
    actions.add_argument("--cancel-start", help="revoke one never-begun local reservation; a started/unknown native refuses")
    actions.add_argument("--init-new", action="store_true", help=argparse.SUPPRESS)  # compat-1v: 下一批删
    p.add_argument("--tickets", default="github", help=argparse.SUPPRESS)  # compat-1v: 下一批删
    p.add_argument("--manifest")
    argv = sys.argv[1:] if argv is None else list(argv)
    if "--settle" in argv:
        # --settle [--apply] [<owner/repo>]: its own pair, beside the cutover's
        # --apply. No repo = every repo this login hosts.
        rest = [a for a in argv if a not in ("--settle", "--apply")]
        if len(rest) > 1 or (rest and rest[0].startswith("-")):
            raise ValueError("usage: fleet_repo_authority.py [<owner/repo>] --settle [--apply]")
        settle(rest[0] if rest else "", "--apply" in argv)
        return
    args = p.parse_args(argv)
    repo = repo_identity(args.repo) if args.repo else ""
    if args.gate or args.finish or args.cancel_start or args.init_new:
        if not repo:
            raise ValueError("name the repo whose local start this is (owner/repo)")
    if args.gate or args.finish:
        gate(repo, args.finish)
        return
    if args.sync:
        sync(repo)
        return
    if args.init_new:
        init_new(repo)
        return
    if args.cancel_start:
        print(json.dumps(start_call(repo, args.cancel_start, "cancel"), indent=2))
        return
    action = next((x for x in ("freeze", "apply", "rollback") if getattr(args, x)), "")
    if not action:
        print(json.dumps(manifest(repo), indent=2))
        return
    if not args.manifest:
        raise ValueError("save --dry-run to a private file, then supply --manifest FILE")
    before = json.loads(Path(args.manifest).read_text())
    _, path = login_settings()
    if before.get("version") != 2 or before.get("scope") != "owner" or before.get("conf") != str(path):
        raise ValueError("manifest is not this login's person's (an older per-repo one?); take a fresh dry-run")
    # Lock this login's setting. Re-read after acquiring it to refuse edits made
    # since the manifest; never rewrite a repo's overlay or another login's file.
    with conf_lock() as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        local, path = login_settings()
        expected = before["local"]
        a = before["hub"]["authority"]
        wanted = {"freeze": "frozen", "apply": "hub", "rollback": "legacy"}.get(action)
        # Exact repeats may already have written the single authority line.
        if local != expected and not (wanted and local["base_sha256"] == expected["base_sha256"]
                                      and local["settings"] == dict(expected["settings"], FLEET_TASK_AUTHORITY=wanted)):
            raise ValueError("this login's settings changed since manifest; take a fresh dry-run")
        key = "owner-" + hashlib.sha256(json.dumps([before.get("owner", ""), action, a["revision"]]).encode()).hexdigest()
        data = dict(action=action, expected_revision=a["revision"], idempotency_key=key)
        result = hubrest.api("POST", "/authority", body=data)
        if wanted:
            current = hubrest.api("GET", "/authority", query={"gate": "1"})
            if current.get("owner", before.get("owner")) != before.get("owner"):
                raise ValueError("this login now answers for another person; take a fresh dry-run")
            if current["revision"] != result["revision"] or current["mode"] != wanted:
                raise ValueError("a newer authority transition superseded this manifest; refresh it")
            # The central freeze/selection commits FIRST. A failed local write
            # is safe and replayable with the same manifest/key.
            update_local(wanted)
        print(json.dumps(dict(result=result, manifest=manifest(before.get("repo") or None)), indent=2))


def error_reason(exc):
    # A Hub error body is untrusted. Retain its actionable reason, never an
    # echoed credential (including a pair read by hubrest.creds from node.env).
    message = str(exc)
    secrets = [v for k, v in os.environ.items()
               if k.endswith(("TOKEN", "SECRET", "PASSWORD", "CRED", "ASSERT")) and v]
    if hubrest._CREDS:
        secrets.append(hubrest._CREDS[1])
    for secret in sorted(secrets, key=len, reverse=True):
        message = message.replace(secret, "[redacted]")
    if "HTTP 401" in message or "HTTP 403" in message:
        message += "; check this node's Hub authentication/permissions"
    elif "HTTP 5" in message:
        message += "; Hub unavailable, retry after service recovery"
    return " ".join(message.split())


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["--supervise"]:
            sys.exit(supervise(sys.argv[3:]))
        if sys.argv[1:2] == ["--match-ticket-ref"]:
            print(match_ticket_ref(*sys.argv[2:]))
            sys.exit(0)
        main()
    except (hubrest.Fail, ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        print("repo authority: " + error_reason(exc), file=sys.stderr)
        sys.exit(getattr(exc, "rc", 1))
