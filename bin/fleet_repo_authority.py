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
import signal
import time
import uuid

import fleet_hub_rest as hubrest
import fleet_launch as launch

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
START_KEYS = ("reservation", "repo", "owner", "endpoint_id", "worker_id")


def init_new(repo):
    # A new repo selects nothing any more (issue #4901): the authority is the
    # person's. Kept one version for an older caller — says legacy, asks nothing.
    # compat-1v: 下一批删
    repo_identity(repo)
    print("legacy")
    print("task authority: a new repo selects nothing — it is this login's person's (issue #4901)", file=sys.stderr)


def check_start_ack(expected, ack, phase, proof=None):
    if (not isinstance(expected, dict)
            or any(not isinstance(expected.get(k), str) or not expected[k] for k in START_KEYS)
            or not isinstance(ack, dict) or set(ack) - set(START_KEYS) - {'phase', 'native_identity'}
            or any(not isinstance(ack.get(k), str) or not ack[k] for k in START_KEYS)
            or any(ack.get(k) != expected[k] for k in START_KEYS)
            or ack.get('phase') != phase
            or ack.get('native_identity') != proof):
        raise ValueError('authority acknowledgement differs from the exact admission/execution')
    return ack


def reserved_scope(repo, key, worker):
    # Only read BEFORE begin. GET on an observed successor belongs to #4510's
    # recovery fence and deliberately rejects competing history (even stopped).
    row = hubrest.api('GET', '/authority/start', query={'repo': repo, 'reservation': key})
    if (not isinstance(row, dict) or set(row) - set(START_KEYS) - {'phase', 'native_identity'}
            or any(not isinstance(row.get(k), str) or not row[k]
                   for k in ('repo', 'reservation', 'owner', 'endpoint_id'))
            or row['repo'] != repo_identity(repo) or row['reservation'] != key
            or row.get('worker_id') or row.get('native_identity') or row.get('phase') != 'reserved'):
        raise ValueError('independent reserved admission unavailable; no begin authorized')
    return dict(row, worker_id=worker)


def stopped_receipt(path, authority):
    proof = json.loads(Path(path).read_text())
    for key in ("worker_id", "native_session", "birth", "executable"):
        if not isinstance(proof.get(key), str) or not proof[key]:
            raise ValueError("stop acknowledgement needs a saved native identity receipt")
    if type(proof.get("pid")) is not int or proof["pid"] <= 0:
        raise ValueError("invalid native PID")
    owners = [o for o in authority.get("legacy_owners", []) if o.get("worker_id") == proof["worker_id"]]
    if not owners or any(not o.get("native_identity") or any(
            o["native_identity"].get(k) != proof[k] for k in NATIVE_KEYS) for o in owners):
        raise ValueError("native receipt is unbound or differs from the frozen owner; refresh the manifest")
    return prove_stopped(proof)


def prove_stopped(proof):
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
    # The person's authority decides (issue #4901); the repo only names the
    # local start the last gate reserves, and the accepted task it must match.
    repo = repo_identity(repo)
    a = hubrest.api("GET", "/authority", query={"gate": "1"})
    if not isinstance(a, dict) or a.get("mode") not in ("legacy", "frozen", "hub"):
        raise ValueError("task authority is unknown; no local fallback")
    if a["mode"] == "frozen":
        raise ValueError("your dispatch is frozen; drain/cutover must finish first")
    ref = ""
    if a["mode"] == "hub":
        if os.environ.get("FLEET_LAUNCH"):
            c = launch.validate_context(json.loads(os.environ["FLEET_LAUNCH"]))
            t = launch.current_task(c)
            if repo_identity(t.get("repo", "")) != repo:
                raise ValueError("accepted task belongs to another repo")
            ref = t.get("ticket_ref", "")
        elif finish:
            raise ValueError("hub authority requires an accepted, verified launch; no local fallback")
    result = dict(mode=a["mode"], ticket_ref=ref)
    if finish and a["mode"] == "legacy" and not os.environ.get("FLEET_LAUNCH"):
        key = str(uuid.uuid4())
        start = start_call(repo, key, "reserve")
        result["reservation"] = start["reservation"]
    print(json.dumps(result))


def start_call(repo, key, action, **fields):
    return hubrest.api("POST", "/authority/start", query={"repo": repo_identity(repo)},
                      body=dict(action=action, reservation=key, **fields))


def observe_native(payload, codex_identity=None):
    raw = os.environ.get("FLEET_AUTHORITY_CONTEXT")
    if not raw or payload.get("hook_event_name") != "SessionStart":
        return
    c = json.loads(raw)
    if os.environ.get('FLEET_CODEX_LAUNCHER_PID'):
        from fleet_native_registration import observe
        return observe(payload, codex_identity)
    native = launch.native_parent()
    if not launch.valid_uuid(payload.get("session_id")) or not launch.root_native(native, c["supervisor"]):
        raise ValueError("local reservation does not own this native execution")
    if native.get('actual_provider') == 'codex':
        raise ValueError('Codex authority requires its verified launcher binding')
    # Keep the original four-field authority context contract unchanged (#4510).
    expected = json.loads(os.environ.get('FLEET_AUTHORITY_ADMISSION', '{}'))
    if any(expected.get(k) != c[k] for k in ('reservation', 'worker_id')) \
            or expected.get('repo') != repo_identity(c['repo']):
        raise ValueError('admission context differs')
    binding = c.get("worktree")
    intent = c.get("native_worktree")
    pane = os.environ["TMUX_PANE"]
    if intent:
        if native["actual_provider"] != "claude":
            raise ValueError("local native worktree creation requires Claude")
        previous_raw = launch.option(pane, "@authority_receipt")
        previous = json.loads(previous_raw) if previous_raw else {}
        if previous.get("reservation") == c["reservation"]:
            if previous.get("native_worktree") != intent:
                raise ValueError("late local hook cannot replace native creation intent")
            previous_proof = previous.get("native_identity", {})
            if any(previous_proof.get(key) != native[key] for key in ("pid", "birth", "executable")) \
                    or previous_proof.get("native_session") != payload["session_id"]:
                raise ValueError("late local hook cannot replace native identity")
            binding = previous.get("worktree", binding)
        binding = launch.observe_native_worktree(pane, payload, intent, binding)
    elif "worktree" in c:
        launch.bind_native_worktree(payload, c["worktree"])
        launch.check_worktree_window(pane, c["worktree"])
    proof = {k: native[k] for k in ("pid", "birth", "executable")}
    proof.update(worker_id=c["worker_id"], native_session=payload["session_id"])
    ack = start_call(c["repo"], c["reservation"], "observe", native_identity=proof)
    check_start_ack(expected, ack, 'observed', proof)
    receipt = dict(c, native_identity=proof, hub_confirmation=ack)
    if os.environ.get('FLEET_AUTHORITY_ADMISSION'):
        receipt['admission'] = expected
    if intent:
        receipt["worktree"] = binding
        launch.tmux("set-option", "-w", "-t", pane, "@worktree", binding["root"])
    launch.stamp(pane, "@authority_receipt", receipt)


def restore_native_worktree(receipt, directory, session, provider, fleet_id, repo):
    if not isinstance(receipt, dict):
        raise ValueError("invalid saved repository authority receipt")
    if "native_worktree" not in receipt:
        raise ValueError("saved repository receipt has no native creation intent")
    proof = receipt.get("native_identity", {})
    if not isinstance(proof, dict) or not isinstance(receipt.get("worker_id"), str):
        raise ValueError("invalid saved native repository identity")
    worker = receipt.get("worker_id", "").split("/")
    if (provider != "claude" or repo_identity(receipt.get("repo", "")) != repo_identity(repo)
            or len(worker) != 2 or not all(launch.valid_uuid(part) for part in worker)
            or worker[1] != fleet_id or proof.get("worker_id") != receipt["worker_id"]
            or not launch.valid_uuid(receipt.get("reservation"))
            or not launch.valid_uuid(session) or proof.get("native_session") != session
            or type(proof.get("pid")) is not int or proof["pid"] <= 0
            or not isinstance(proof.get("birth"), str) or not proof["birth"]
            or not isinstance(proof.get("executable"), str) or not os.path.isabs(proof["executable"])):
        raise ValueError("restore row differs from its native repository authority receipt")
    intent = launch.validate_native_worktree(receipt["native_worktree"])
    binding = launch.validate_worktree(receipt.get("worktree"))
    launch.check_native_repository(intent)
    if (directory != binding["root"] or directory != str(launch.native_worktree_path(intent))
            or binding["common_dir"] != intent["common_dir"] or launch.worktree_identity(directory) != binding):
        raise ValueError("restored local native worktree lost its saved Git binding")
    return intent


def supervise(argv):
    # All existing restart/transfer roads already use the session wrapper. This
    # is a one-shot admission and its native wait, not another runtime observer.
    script = '''. "$1/fleet-lib.sh"
s=$(fleet_current_session)
pool_socket=${TMUX:-}; pool_socket=${pool_socket%%,*}; pool_socket=${pool_socket##*/}
for pool_owner in "${FLEET_LAUNCH_SESSION:-}" "$pool_socket"; do
    if [ -n "$pool_owner" ] && [ "$s" = "${pool_owner}-pool" ]; then
        s=$pool_owner
        break
    fi
done
fleet_load_conf "$s"
r=$(fleet_window_repo "$s" "$TMUX_PANE")
if [ -z "$r" ] || { [ "${CCQUOTA_FLEET:-0}" != 1 ] && [ -z "$(fleet_task_authority "$s" "$r")" ]; }; then exit 0; fi
u=$(fleet_uuid "$s") || exit 1
f=$(fleet_window_fid "$s" "$TMUX_PANE") || exit 1
printf '%s\\t%s/%s' "$r" "$u" "$f"
'''
    result = subprocess.run(["bash", "-c", script, "_", str(BIN)], capture_output=True, text=True, check=True)
    pane = os.environ["TMUX_PANE"]
    native_raw = launch.option(pane, "@native_worktree")
    saved = launch.option(pane, "@authority_receipt")
    saved_receipt = json.loads(saved) if saved else None
    if not native_raw and isinstance(saved_receipt, dict) and saved_receipt.get("native_worktree"):
        raise ValueError("native recovery lost its creation intent")
    if not result.stdout:
        if native_raw:
            raise ValueError("native creation requires explicit repository admission")
        os.execvpe(argv[0], argv, os.environ)
    repo, worker = result.stdout.strip().split("\t")
    # The hub answers in the canonical owner/repo; the window's @repo keeps the
    # registered spelling. The context carries the canonical one, or every check
    # against the admission refuses a repo with capitals (issue #4789).
    repo = repo_identity(repo)
    previous = None
    intent = None
    if native_raw:
        previous = saved_receipt
        if previous:
            if (previous.get("repo") or "").lower() != repo or previous.get("worker_id") != worker or not previous.get("native_worktree"):
                raise ValueError("native recovery belongs to another repository or worker")
            if launch.same_process(previous["native_identity"]):
                raise ValueError("original native execution is alive; reconnect instead")
        argv, provider, _ = launch.held_argv(argv, "", False, previous["native_identity"] if previous else None)
        worktree = launch.prepare_worktree(pane, previous)
        intent = launch.prepare_native_worktree(pane, provider, worktree, previous)
        argv += ["--worktree", intent["name"], "--name", intent["name"]]
    else:
        worktree = launch.prepare_worktree(pane)
    key = os.environ.get("FLEET_AUTHORITY_START") or str(uuid.uuid4())
    if not os.environ.get("FLEET_AUTHORITY_START"):
        start_call(repo, key, "reserve")
    expected = reserved_scope(repo, key, worker)
    if os.environ.get('FLEET_AUTHORITY_EXPECTED'):
        # A controlled continuation already witnessed its source admission and
        # fresh reserve. A credential/scope change must fail BEFORE begin/native.
        prior = json.loads(os.environ['FLEET_AUTHORITY_EXPECTED'])
        check_start_ack(prior, expected, 'reserved')
    try:
        admission = start_call(repo, key, "begin", worker_id=worker)
    except (hubrest.Fail, ValueError):
        # A refused begin leaves the reservation reserved; cancel is CAS from
        # reserved only. An accepted begin whose ACK differs (below) is retained.
        try:
            start_call(repo, key, "cancel")
        except (hubrest.Fail, ValueError):
            pass
        raise
    check_start_ack(expected, admission, 'starting')
    c = dict(repo=repo, worker_id=worker, reservation=key, supervisor=os.getpid())
    if worktree:
        c["worktree"] = worktree
    if intent:
        c["native_worktree"] = intent
    env = dict(os.environ, FLEET_AUTHORITY_CONTEXT=json.dumps(c),
               FLEET_AUTHORITY_ADMISSION=json.dumps(admission))
    env.pop("FLEET_AUTHORITY_START", None)
    env.pop('FLEET_AUTHORITY_EXPECTED', None)
    if intent:
        for variable in ("FLEET_LAUNCH_CREATE", "FLEET_LAUNCH_WORKTREE", "FLEET_LAUNCH_CONTEXT"):
            env.pop(variable, None)
    # The terminal delivers these signals to the child too. Keep the waiter
    # alive to save a confirmed native stop; an interrupted waiter is UNKNOWN.
    for sig in (signal.SIGINT, signal.SIGQUIT):
        signal.signal(sig, lambda *_: None)
    directory = intent["root"] if intent else worktree["root"] if worktree else None
    child = subprocess.Popen(argv, env=env, **({"cwd": directory} if directory else {}))
    rc = child.wait()
    try:
        raw = launch.option(os.environ["TMUX_PANE"], "@authority_receipt")
        if not (raw or "").strip():
            # The agent exited before its native start was observed (a refused
            # launch, issue #4764; a warm Codex window that never got its first
            # turn — Codex runs SessionStart only then — issue #4792). Close the
            # start on the hub: only a `starting` with no native bound may end
            # as `abandoned`, and a late observe is then fenced, so nothing
            # unregistered ever gets authority. Never a bare JSON parse error.
            try:
                check_start_ack(admission, start_call(repo, key, "unobserved", worker_id=worker), "abandoned")
                closed = "start closed as abandoned"
            except (hubrest.Fail, ValueError) as exc:
                closed = "start left open: " + error_reason(exc)
            raise ValueError("no local native receipt: the agent exited (rc=%s) before its start was observed; %s (why: logs/authority.log)" % (rc, closed))
        receipt = json.loads(raw)
        if any(receipt.get(k) != v for k, v in c.items()):
            raise ValueError("local native receipt was replaced or never observed")
        proof = prove_stopped(receipt["native_identity"])
        start_call(repo, key, "stopped", native_identity={k: proof[k] for k in NATIVE_KEYS}, execution_stopped=True)
    except (hubrest.Fail, ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        print("repo authority: execution retained: " + error_reason(exc), file=sys.stderr)
    return rc


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
    """One repo's settle (below), else every hosted repo's, printed as one doc."""
    if repo:
        print(json.dumps(settle_one(repo, apply), indent=2))
        return
    docs = [settle_one(r, apply) for r in hosted_repos()]
    counts = {}
    for d in docs:
        for k, v in d["counts"].items():
            counts[k] = counts.get(k, 0) + v
    print(json.dumps(dict(repo="", endpoint_id=docs[0]["endpoint_id"] if docs else "", apply=apply,
                          counts=counts, repos=docs), indent=2))


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


def ticket_ref(repo, number):
    c = launch.validate_context(json.load(sys.stdin))
    t = launch.task_call(c)
    if any(t.get(k) != c[v] for k, v in (("owner", "owner"), ("generation", "generation"),
                                      ("execution_owner", "worker_id"))):
        raise ValueError("ticket identity needs the accepted owner/generation")
    ref = t.get("ticket_ref")
    match_ticket_ref(repo, number, ref)
    print(ref)


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
    actions.add_argument("--stop-receipt")
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
    if args.stop_receipt:
        action = "stop_ack"
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
        if action == "stop_ack":
            proof = stopped_receipt(args.stop_receipt, a)
            data.update(worker_id=proof["worker_id"], evidence=json.dumps(proof, sort_keys=True))
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
        if sys.argv[1:2] == ["--restore-native-worktree"]:
            restored = restore_native_worktree(json.load(sys.stdin), *sys.argv[2:])
            if restored:
                print(json.dumps(restored))
            sys.exit(0)
        if sys.argv[1:2] == ["--ticket-ref"]:
            ticket_ref(*sys.argv[2:])
            sys.exit(0)
        if sys.argv[1:2] == ["--match-ticket-ref"]:
            print(match_ticket_ref(*sys.argv[2:]))
            sys.exit(0)
        main()
    except (hubrest.Fail, ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        print("repo authority: " + error_reason(exc), file=sys.stderr)
        sys.exit(getattr(exc, "rc", 1))
