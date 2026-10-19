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
import signal
import time
import uuid

import fleet_ticket as ticket
import fleet_launch as launch

BIN = Path(__file__).resolve().parent


def repo_identity(value):
    # Authority takes an explicit owner/repo, not a URL/path. GitHub casing is
    # identity-equivalent; the local registration's spelling is NOT a path to rename.
    if not isinstance(value, str):
        raise ValueError("repo must be an explicit owner/repo string")
    repo = ticket.norm_repo(value)
    if not repo or repo != value.lower() or any(p in (".", "..") for p in repo.split("/")):
        raise ValueError("select one owner/repo explicitly (no URL, path or surrounding whitespace)")
    return repo


def registered_repo(session, repo):
    # Use the fleet's registration reader; never guess an overlay from the Hub's
    # lower-case identity, and never fall back to another repo's fleet settings.
    result = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh"; fleet_target_repo "$2" "$3"',
                             "_", str(BIN), session, repo], capture_output=True, text=True)
    registered = result.stdout.strip()
    if result.returncode or ticket.norm_repo(registered) != repo:
        raise ValueError("repo registration is unknown or ambiguous; check fleet-repo.sh list --session " + session)
    return registered


def setting(session, repo, key):
    result = subprocess.run(["bash", str(BIN / "fleet-repo.sh"), "get", key,
                             "--session", session, repo, "--tsv"],
                            capture_output=True, text=True, check=True)
    fields = result.stdout.rstrip("\n").split("\t")
    if len(fields) != 3 or fields[0] != repo:
        raise ValueError("repo settings did not resolve explicitly")
    return fields[2]


def local_settings(session, repo):
    repo = registered_repo(session, repo_identity(repo))
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
    repo = repo_identity(repo)
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


def sync(repo):
    # Every host of the repo follows the hub's selection (issue #4730): a cutover
    # rewrote only the overlay of the host that ran it, so another host's reader
    # of FLEET_TASK_AUTHORITY saw legacy for a repo the hub owned. The hub says
    # "re-read" to each capable host; the mode is read back here with this
    # node's own credential, never taken from the push. Unknown leaves the
    # overlay alone. legacy with no line stays byte for byte.
    repo = repo_identity(repo)
    a = ticket.api("GET", "/authority", query={"repo": repo, "gate": "1"})
    mode = a.get("mode") if isinstance(a, dict) else None
    if mode not in ("legacy", "frozen", "hub"):
        raise ValueError("repo authority is unknown; overlays left as they are")
    env = os.environ.get("FLEET_CONF_DIR") or str(Path.home() / ".config/claude-fleet")
    changed = []
    for repos in sorted((Path(env) / "fleets").glob("*/repos")):
        session = repos.parent.name
        try:
            _, path = local_settings(session, repo)
        except (ValueError, subprocess.SubprocessError):
            continue  # this fleet does not host the repo with its own overlay
        with open(str(path) + ".authority.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            local, path = local_settings(session, repo)
            current = local["settings"]["FLEET_TASK_AUTHORITY"]
            if current == mode or (mode == "legacy" and not current):
                continue
            update_local(path, mode)
            changed.append(session)
    print(json.dumps(dict(repo=repo, mode=mode, revision=a.get("revision"), changed=changed)))


NATIVE_KEYS = ("worker_id", "native_session", "pid", "birth", "executable")
START_KEYS = ("reservation", "repo", "owner", "endpoint_id", "worker_id")


def init_new(repo, tickets):
    # A repo this fleet is about to host starts on the hub when the hub has never
    # seen it (issue #4885): one POST, revision 0 -> 1 mode=hub. Prints the mode
    # the new overlay takes — hub, or legacy when the hub refused (the repo has a
    # history somewhere, so it takes the explicit cutover). Unreachable raises.
    # The key is the repo's own, so a rerun after a failed overlay write replays.
    repo = repo_identity(repo)
    if tickets not in ("hub", "github"):
        raise ValueError("--tickets takes hub or github")
    key = "repo-init-" + hashlib.sha256(repo.encode()).hexdigest()
    try:
        a = ticket.api("POST", "/authority", query={"repo": repo},
                       body=dict(action="init", expected_revision=0, idempotency_key=key,
                                 legacy_tickets=tickets))
    except ticket.Fail as exc:
        if exc.rc == 4:
            raise
        try:
            a = ticket.api("GET", "/authority", query={"repo": repo, "gate": "1"})
        except ticket.Fail as again:
            if again.rc == 4:
                raise
            a = {}
        # Already ours on the hub (an earlier add of this repo) is still hub.
        mode = a.get("mode") if isinstance(a, dict) else None
        print("hub" if mode == "hub" else "legacy")
        if mode != "hub":
            print("repo authority: %s stays legacy — %s" % (repo, error_reason(exc)), file=sys.stderr)
        return
    print("hub" if isinstance(a, dict) and a.get("mode") == "hub" else "legacy")


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
    row = ticket.api('GET', '/authority/start', query={'repo': repo, 'reservation': key})
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
    repo = repo_identity(repo)
    a = ticket.api("GET", "/authority", query={"repo": repo, "gate": "1"})
    if not isinstance(a, dict) or a.get("mode") not in ("legacy", "frozen", "hub"):
        raise ValueError("repo authority is unknown; no local fallback")
    if a["mode"] == "frozen":
        raise ValueError("repo dispatch is frozen; drain/cutover must finish first")
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
    return ticket.api("POST", "/authority/start", query={"repo": repo_identity(repo)},
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
if [ -z "$r" ] || { [ "${CCQUOTA_FLEET:-0}" != 1 ] && [ -z "${FLEET_TASK_AUTHORITY:-}" ]; }; then exit 0; fi
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
    except (ticket.Fail, ValueError):
        # A refused begin leaves the reservation reserved; cancel is CAS from
        # reserved only. An accepted begin whose ACK differs (below) is retained.
        try:
            start_call(repo, key, "cancel")
        except (ticket.Fail, ValueError):
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
            except (ticket.Fail, ValueError) as exc:
                closed = "start left open: " + error_reason(exc)
            raise ValueError("no local native receipt: the agent exited (rc=%s) before its start was observed; %s (why: logs/authority.log)" % (rc, closed))
        receipt = json.loads(raw)
        if any(receipt.get(k) != v for k, v in c.items()):
            raise ValueError("local native receipt was replaced or never observed")
        proof = prove_stopped(receipt["native_identity"])
        start_call(repo, key, "stopped", native_identity={k: proof[k] for k in NATIVE_KEYS}, execution_stopped=True)
    except (ticket.Fail, ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
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


def settle(repo, apply):
    """Close this node's own dead local starts with the existing actions
    (issue #4832): reserved and unheld -> cancel, begun with no native and
    unheld -> unobserved, observed whose native is proven stopped -> stopped.
    Everything else stays, counted by why. Dry unless apply."""
    repo = repo_identity(repo)
    try:
        data = ticket.api("GET", "/authority/start", query={"repo": repo, "list": "1"})
    except ticket.Fail as exc:
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
                or ticket.norm_repo(start.get("repo") or "") != repo or not start.get("reservation")):
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
            except (ticket.Fail, ValueError) as exc:
                row["result"] = "failed: " + error_reason(exc)
            authority_log("settle repo=%s reservation=%s phase=%s worker=%s action=%s result=%s" % (
                repo, row["reservation"], row["phase"], row["worker_id"] or "-", action, row["result"]))
        bucket = row.get("result", action or why)
        if bucket.startswith("failed"):
            bucket = "failed"
        counts[bucket] = counts.get(bucket, 0) + 1
        plan.append(row)
    print(json.dumps(dict(repo=repo, endpoint_id=endpoint, apply=apply, counts=counts, starts=plan), indent=2))


def match_ticket_ref(repo, number, ref):
    repo = repo_identity(repo)
    backend, bound_repo, bound_number = ticket.parse(ref)
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
    p.add_argument("repo")
    p.add_argument("--session", default=os.environ.get("FLEET_SESSION", ""))
    actions = p.add_mutually_exclusive_group()
    for a in ("dry-run", "freeze", "apply", "rollback", "gate", "finish", "sync", "settle"):
        actions.add_argument("--" + a, action="store_true")
    actions.add_argument("--stop-receipt")
    actions.add_argument("--cancel-start", help="revoke one never-begun local reservation; a started/unknown native refuses")
    actions.add_argument("--adopt", help="one explicit gh:owner/repo#N reference")
    actions.add_argument("--init-new", action="store_true",
                         help="a repo about to be hosted: start it on the hub if the hub never saw it")
    p.add_argument("--tickets", default="github", help="with --init-new: where its tickets live")
    p.add_argument("--title", default="")
    p.add_argument("--body-file")
    p.add_argument("--manifest")
    argv = sys.argv[1:] if argv is None else list(argv)
    if "--settle" in argv:
        # --settle [--apply]: its own pair, beside the cutover's --apply.
        rest = [a for a in argv if a not in ("--settle", "--apply")]
        if len(rest) != 1 or rest[0].startswith("-"):
            raise ValueError("usage: fleet_repo_authority.py <owner/repo> --settle [--apply]")
        settle(rest[0], "--apply" in argv)
        return
    args = p.parse_args(argv)
    repo = repo_identity(args.repo)
    if args.session and ("/" in args.session or args.session in (".", "..")):
        raise ValueError("--session must name one fleet")
    if args.gate or args.finish:
        if args.session:
            registered_repo(args.session, repo)
        gate(repo, args.finish)
        return
    if args.sync:
        sync(repo)
        return
    if args.init_new:
        init_new(repo, args.tickets)
        return
    if args.cancel_start:
        print(json.dumps(start_call(repo, args.cancel_start, "cancel"), indent=2))
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
            proof = stopped_receipt(args.stop_receipt, a)
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


def error_reason(exc):
    # A Hub error body is untrusted. Retain its actionable reason, never an
    # echoed credential (including a pair read by ticket.creds from node.env).
    message = str(exc)
    secrets = [v for k, v in os.environ.items()
               if k.endswith(("TOKEN", "SECRET", "PASSWORD", "CRED", "ASSERT")) and v]
    if ticket._CREDS:
        secrets.append(ticket._CREDS[1])
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
    except (ticket.Fail, ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        print("repo authority: " + error_reason(exc), file=sys.stderr)
        sys.exit(getattr(exc, "rc", 1))
