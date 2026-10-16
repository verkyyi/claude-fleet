#!/usr/bin/env python3
"""Explicit per-repo authority migration; no GitHub call or background worker.

The manifest is a read-only inventory. Mutations name that manifest, so both
the hub revision and local repo settings are checked before a cutover.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import fleet_ticket as ticket
import fleet_launch as launch

BIN = Path(__file__).resolve().parent


def setting(session, repo, key):
    result = subprocess.run(["bash", str(BIN / "fleet-repo.sh"), "get", key,
                             "--session", session, repo, "--tsv"],
                            capture_output=True, text=True, check=True)
    fields = result.stdout.rstrip("\n").split("\t")
    if len(fields) != 3 or fields[0] != repo:
        raise ValueError("repo settings did not resolve explicitly")
    return fields[2]


def local_settings(session, repo):
    values = {k: setting(session, repo, k) for k in
              ("FLEET_TASK_AUTHORITY", "FLEET_TICKETS", "FLEET_FORGE", "FLEET_LAND")}
    # Resolve the repo's own overlay, never the fallback fleet conf.
    env = os.environ.get("FLEET_CONF_DIR") or str(Path.home() / ".config/claude-fleet")
    slug = repo.replace("/", "-")
    path = Path(env) / "fleets" / session / "repos" / (slug + ".conf")
    if not path.is_file():
        raise ValueError("repo needs its own registered overlay before migration")
    raw = path.read_bytes()
    rest = b"".join(line for line in raw.splitlines(keepends=True)
                    if not line.lstrip().startswith(b"FLEET_TASK_AUTHORITY="))
    return dict(settings=values, sha256=hashlib.sha256(raw).hexdigest(),
                base_sha256=hashlib.sha256(rest).hexdigest()), path


def manifest(session, repo):
    local, _ = local_settings(session, repo)
    data = ticket.api("GET", "/authority", query={"repo": repo, "rollback": "1"})
    return dict(version=1, repo=repo, session=session, local=local, hub=data,
                scope="fixture/source until separately live-accepted",
                preserved=["FLEET_TICKETS", "FLEET_FORGE", "FLEET_LAND", "existing ticket/PR references"])


def update_local(path, mode):
    # Only the selected repo is touched. The old ticket home/code hosting/land
    # modes remain byte-for-byte, and old issue integers are never reinterpreted.
    lines = path.read_text().splitlines(keepends=True)
    lines = [line for line in lines if not line.lstrip().startswith("FLEET_TASK_AUTHORITY=")]
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.append('FLEET_TASK_AUTHORITY="%s"\n' % mode)
    tmp = path.with_name(path.name + ".authority.tmp")
    try:
        with open(tmp, "x") as out:
            os.chmod(tmp, path.stat().st_mode & 0o777)
            out.write("".join(lines))
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def stopped_receipt(path):
    proof = json.loads(Path(path).read_text())
    for key in ("worker_id", "native_session", "birth", "executable"):
        if not isinstance(proof.get(key), str) or not proof[key]:
            raise ValueError("stop acknowledgement needs a saved native identity receipt")
    if type(proof.get("pid")) is not int or proof["pid"] <= 0:
        raise ValueError("invalid native PID")
    # Permission/probe failure is UNKNOWN. Only ESRCH or a positively observed
    # different identity confirms the witnessed process stopped.
    try:
        os.kill(proof["pid"], 0)
    except ProcessLookupError:
        pass
    else:
        observed = launch.process(proof["pid"])
        if all(observed[k] == proof[k] for k in ("pid", "birth", "executable")):
            raise ValueError("native execution is still alive")
    proof["execution_stopped"] = True
    return proof


def gate(repo, finish):
    a = ticket.api("GET", "/authority", query={"repo": repo, "gate": "1"})
    if a["mode"] == "frozen":
        raise ValueError("repo dispatch is frozen; drain/cutover must finish first")
    ref = ""
    if a["mode"] == "hub":
        if os.environ.get("FLEET_LAUNCH"):
            c = launch.validate_context(json.loads(os.environ["FLEET_LAUNCH"]))
            t = launch.current_task(c)
            if t.get("repo") != repo:
                raise ValueError("accepted task belongs to another repo")
            ref = t.get("ticket_ref", "")
        elif finish:
            raise ValueError("hub authority requires an accepted, verified launch; no local fallback")
    print(json.dumps(dict(mode=a["mode"], ticket_ref=ref)))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("repo")
    p.add_argument("--session", default=os.environ.get("FLEET_SESSION", ""))
    actions = p.add_mutually_exclusive_group()
    for a in ("dry-run", "freeze", "apply", "rollback", "gate", "finish"):
        actions.add_argument("--" + a, action="store_true")
    actions.add_argument("--stop-receipt")
    actions.add_argument("--adopt", help="one explicit gh:owner/repo#N reference")
    p.add_argument("--title", default="")
    p.add_argument("--body-file")
    p.add_argument("--manifest")
    args = p.parse_args(argv)
    repo = ticket.norm_repo(args.repo)
    if not repo or repo != args.repo:
        raise ValueError("select one normalized owner/repo explicitly")
    if args.gate or args.finish:
        gate(repo, args.finish)
        return
    if not args.session or "/" in args.session or args.session in (".", ".."):
        raise ValueError("--session is required")
    action = next((x for x in ("freeze", "apply", "rollback") if getattr(args, x)), "")
    if args.stop_receipt:
        action = "stop_ack"
    if args.adopt:
        action = "adopt"
    if not action:
        print(json.dumps(manifest(args.session, repo), indent=2))
        return
    if not args.manifest:
        raise ValueError("save --dry-run to a private file, then supply --manifest FILE")
    before = json.loads(Path(args.manifest).read_text())
    if before.get("version") != 1 or before.get("repo") != repo or before.get("session") != args.session:
        raise ValueError("manifest names a different repo/session/version")
    local, path = local_settings(args.session, repo)
    # Lock only this repo's overlay. Re-read after acquiring it to refuse edits
    # made since the manifest; never rewrite repo B or a fleet-wide setting.
    with open(str(path) + ".authority.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        local, path = local_settings(args.session, repo)
        expected = before["local"]
        a = before["hub"]["authority"]
        wanted = {"freeze": "frozen", "apply": "hub", "rollback": "legacy"}.get(action)
        # Exact repeats may already have written the single authority line.
        if local != expected and not (wanted and local["base_sha256"] == expected["base_sha256"]
                                      and local["settings"] == dict(expected["settings"], FLEET_TASK_AUTHORITY=wanted)):
            raise ValueError("repo settings changed since manifest; take a fresh dry-run")
        key = "repo-" + hashlib.sha256(json.dumps([repo, action, a["revision"]]).encode()).hexdigest()
        data = dict(action=action, expected_revision=a["revision"], idempotency_key=key)
        if action == "freeze":
            home = local["settings"]["FLEET_TICKETS"]
            data["legacy_tickets"] = home or ("hub" if local["settings"]["FLEET_FORGE"] == "none" else "github")
        if action == "stop_ack":
            proof = stopped_receipt(args.stop_receipt)
            data.update(worker_id=proof["worker_id"], evidence=json.dumps(proof, sort_keys=True))
        endpoint = "/authority"
        if action == "adopt":
            data = dict(source=args.adopt, title=args.title,
                        body=Path(args.body_file).read_text() if args.body_file else "",
                        expected_revision=a["revision"])
            endpoint += "/adopt"
        result = ticket.api("POST", endpoint, body=data, query={"repo": repo})
        if wanted:
            current = ticket.api("GET", "/authority", query={"repo": repo, "gate": "1"})
            if current["revision"] != result["revision"] or current["mode"] != wanted:
                raise ValueError("a newer authority transition superseded this manifest; refresh it")
            # The central freeze/selection commits FIRST. A failed local write
            # is safe and replayable with the same manifest/key.
            update_local(path, wanted)
        print(json.dumps(dict(result=result, manifest=manifest(args.session, repo)), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ticket.Fail, ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        print("repo authority: " + str(exc), file=sys.stderr)
        sys.exit(getattr(exc, "rc", 1))
