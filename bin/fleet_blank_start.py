#!/usr/bin/env python3
"""fleet_blank_start.py — ⌘P 「新会话」's start under hub authority, its record made
in-process (T992): what `fleet-task-record.sh dispatch --spawn --blank` does for a
blank repo session — the worker template, the dispatch, the record's POST, its
answer read, its code booked — without that script's bash (~0.6 s of a start),
then the same spawner with the same arguments and environment.

    start(repo, agent, fleet, title, via) → (rc, stdout lines, stderr)

None ⇒ this road cannot take it (a seam is set, no node token, the hub's answer
not one it knows before anything was recorded): the caller takes the script.
Once the record exists nothing falls back — a second record is never made.
The rules are fleet-task-record.sh's dispatch (its token, payload, contract
check, the code book) and its spawner hand-off (FLEET_DISPATCH, FLEET_TASK_FID,
FLEET_AS_KV, FLEET_DISPATCH_RESOLVED, FLEET_PRESTART); a change there is one here.
"""
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BIN = Path(__file__).absolute().parent
TREF = re.compile(r"^T[1-9][0-9]{0,9}$")
CODE = re.compile(r"^[A-Z][0-9A-Z]{1,25}$")


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet"))


def _mod(name, file):
    spec = importlib.util.spec_from_file_location(name, str(BIN / file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def repo_main(fleet, repo):
    """The repo's FLEET_MAIN from its fleet's repos/<owner>-<name>.conf (a plain
    line, written by fleet-repo.sh); '' when it cannot be read plainly."""
    p = conf_dir() / "fleets" / fleet / "repos" / (repo.replace("/", "-") + ".conf")
    try:
        for line in p.read_text(encoding="utf-8").splitlines():
            m = re.match(r'^(?:export\s+)?FLEET_MAIN=(["\']?)([^"\'$`\\]*)\1\s*$', line)
            if m and m.group(2).startswith("/"):
                return m.group(2)
    except OSError:
        pass
    return ""


def prestart_drop(d):
    """A record that never came: what the prestart made beside it given back (the
    worktree and its branch), as fleet-task-record.sh's prestart_drop."""
    if not d or not os.path.isdir(d):
        return
    for _ in range(300):
        if os.path.exists(os.path.join(d, "done")):
            break
        time.sleep(0.05)
    prep = {}
    try:
        for line in open(os.path.join(d, "prep"), encoding="utf-8"):
            k, _, v = line.rstrip("\n").partition("=")
            prep[k] = v
    except OSError:
        pass
    slug, wt = prep.get("slug", ""), prep.get("wt", "")
    if slug and wt:
        subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh" && m=$(git -C "$3" rev-parse --path-format=absolute '
                        '--git-common-dir 2>/dev/null) && fleet_scratch_free "${m%/.git}" "$2" "$3"', "_",
                        str(BIN), slug, wt], stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
    subprocess.run(["rm", "-rf", d], capture_output=True)


def usable():
    if os.environ.get("FLEET_DISPATCH_TASK_CMD") or os.environ.get("FLEET_HUB_CURL") \
            or os.environ.get("FLEET_BLANK_START", "1") == "0":
        return False
    try:
        sys.path.insert(0, str(BIN))
        import fleet_node_http
        return fleet_node_http.usable() and bool(fleet_node_http.pair())
    except Exception:  # noqa: BLE001
        return False


def start(repo, agent, fleet, title, via, default_agent, print_win=True, reap="merged"):
    if not usable() or not fleet:
        return None
    sys.path.insert(0, str(BIN))
    import fleet_dispatch
    import fleet_node_http
    import fleet_timing
    main = repo_main(fleet, repo)
    if not main:
        return None
    t0 = os.environ.get("FLEET_TIMING_T0") or "%.3f" % time.time()
    env = dict(os.environ, FLEET_TIMING_T0=t0)
    # the spawner's record-free steps, beside the record (unless made ahead)
    if not (env.get("FLEET_PRESTART") and os.path.isdir(env["FLEET_PRESTART"])) \
            and env.get("FLEET_PRESTART_ON", "1") != "0":
        d = tempfile.mkdtemp(prefix="fleet-prestart.")
        with open(os.path.join(d, "err"), "w") as err:
            subprocess.Popen(["bash", str(BIN / "dash-raw-session.sh"), "--prestart", d, "--repo", repo]
                             + (["--agent", agent] if agent else []) + [fleet],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err, env=env,
                             start_new_session=True)
        env["FLEET_PRESTART"] = d
    # the worker template (fleet-agent-def.py launch fleet-worker), as the script
    as_for = "codex" if (agent or default_agent) == "codex" else "claude"
    try:
        kv = list(_mod("fleet_agent_def", "fleet-agent-def.py").launch("fleet-worker", main, "claude", True, as_for))
    except Exception:  # noqa: BLE001 — no worker template: the script decides what that means
        return None
    kv_text = "\n".join("%s\t%s" % (k, v) for k, v in kv)
    template = next((v for k, v in kv if k == "agent"), "")
    okey = os.environ.get("FLEET_BLANK_ORIGIN_KEY", "") or "hub"
    tok = "orch:%s:%s-%d%d" % (okey, hashlib.sha1(("%s\n" % title).encode()).hexdigest()[:16], int(time.time()),
                               os.getpid())
    try:
        d = fleet_dispatch.resolve([agent] if agent else [], template, "", default_agent, None, tok)
    except (ValueError, TypeError):
        return None
    payload = dict(authority_version=1, token=d["request_id"], title=title, via=via, repo=repo.lower(),
                   requested_agent=d["requested_agent"], resolved_agent=d["resolved_agent"],
                   request_payload=dict(dispatch=d, title=title, body="", repo=repo.lower(),
                                        reap="" if reap == "merged" else reap,
                                        template="fleet-worker", rule="", draft="", pr_note=""))
    made_here = env.get("FLEET_PRESTART") if env.get("FLEET_PRESTART") != os.environ.get("FLEET_PRESTART") else ""

    def refused(why):
        prestart_drop(made_here)
        return 1, [], why
    try:
        code, text = fleet_node_http.call("POST", "/v1/node/tasks", json.dumps(payload, ensure_ascii=False))
    except fleet_node_http.Unreachable as e:
        return refused("fleet-task-record: hub unreachable (%s)" % e)
    if code not in (200, 202):
        try:
            why = " ".join(str(json.loads(text).get("error", "")).split())[:300]
        except (ValueError, AttributeError):
            why = ""
        return refused("fleet-task-record: the hub refused (HTTP %s)%s" % (code, ": " + why if why else ""))
    try:
        t = json.loads(text)
    except ValueError:
        t = {}
    tid = t.get("id") if isinstance(t, dict) else None
    if not (isinstance(tid, str) and TREF.match(tid)):
        return refused("fleet-task-record: the hub's answer names no accepted record")
    if t.get("authority_version") != 1 or t.get("requested_agent") != d["requested_agent"] \
            or t.get("resolved_agent") != d["resolved_agent"]:
        return refused("hub did not accept the requested provider contract")
    d.update(task=tid, generation=t["generation"], attempt_id=t["attempt_id"])
    short, fid = t.get("short") or "", t.get("fid") or ""
    if CODE.match(short or ""):
        codes = Path(os.environ.get("FLEET_ID_DIR") or conf_dir() / "ids") / "task-codes.tsv"
        try:
            have = codes.read_text().splitlines() if codes.exists() else []
            if not any(l.split("\t")[:1] == [tid] for l in have):
                codes.parent.mkdir(parents=True, exist_ok=True)
                with open(codes, "a") as f:
                    f.write("%s\t%s\t%s\n" % (tid, short, fid))
        except OSError:
            pass
    try:
        fleet_timing.add("session", [("record", (time.time() - float(t0)) * 1000.0)], ts=float(t0))
    except (ValueError, TypeError):
        pass
    head = ([short] if short else []) + [tid]
    env.update(FLEET_DISPATCH=json.dumps(d, separators=(",", ":")), FLEET_DISPATCH_FRESH=str(int(time.time())),
               FLEET_DISPATCH_RESOLVED="%s\t%s\t%s" % (agent or "", template, default_agent or ""),
               FLEET_AS_KV=kv_text, FLEET_AS_KV_FOR="fleet-worker\t%s\t%s" % (as_for, main))
    if re.match(r"^[0-9a-f-]{36}$", fid or ""):
        env["FLEET_TASK_FID"] = "%s=%s" % (tid, fid)
    argv = ["bash", str(BIN / "dash-raw-session.sh"), "--repo", repo, "--task", tid, "--name", title,
            "--reap", reap or "merged", "--as", "fleet-worker"] + (["--agent", agent] if agent else []) \
        + ["--origin", "hub"] + (["--print"] if print_win else []) + ["--placeholder", fleet]
    p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=180)
    return p.returncode, head + (p.stdout or "").splitlines(), p.stderr or ""


def main(argv):
    """`start --repo R [--agent A] --fleet F --title T [--reap P]` — the drill's
    panel road (fleet-start-drill.sh --road panel): the lines the spawner prints."""
    o = {argv[i]: argv[i + 1] for i in range(1, len(argv) - 1, 2)} if argv[:1] == ["start"] else None
    if not o or not o.get("--repo") or not o.get("--fleet"):
        print("usage: fleet_blank_start.py start --repo R [--agent A] --fleet F --title T [--reap P]", file=sys.stderr)
        return 2
    got = start(o["--repo"], o.get("--agent"), o["--fleet"], o.get("--title") or "新会话", "drill",
                o.get("--default") or "claude", True, o.get("--reap") or "merged")
    if got is None:
        print("fleet_blank_start: this road cannot take it here", file=sys.stderr)
        return 3
    rc, lines, err = got
    print("\n".join(lines))
    sys.stderr.write(err)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
