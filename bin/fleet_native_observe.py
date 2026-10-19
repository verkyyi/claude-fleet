#!/usr/bin/env python3
"""Explicit recovery of an existing Codex authority observation.

Preflight and apply only read the original execution. Neither path starts,
resumes, signals, interrupts, delivers input, or replays a native hook.
The private manifest carries identity, never argv, environment or credentials.
"""
import argparse
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import stat
import struct
import subprocess
import sys

import fleet_launch as launch
import fleet_repo_authority as authority
import fleet_runtime as runtime
from fleet_sleep_argv import process_argv

BIN = Path(__file__).resolve().parent
START_KEYS = ("reservation", "repo", "owner", "endpoint_id", "worker_id")
ENV_KEYS = {"FLEET_AUTHORITY_CONTEXT", "FLEET_CODEX_LAUNCHER_PID", "FLEET_CODEX_REMOTE",
            "CODEX_HOME", "TMUX", "TMUX_PANE", "FLEET_LAUNCH_CONTEXT", "FLEET_CODEX_SUBSCRIPTION",
            "FLEET_CRED_SID", "FLEET_SESSION_WRAP", "FLEET_CONF_DIR"}
WINDOW_KEYS = ("@fleet_id", "@repo", "@cc_agent", "@cc_launcher_pid", "@worktree",
               "@launch", "@launch_receipt", "@handoff_armed", "@subscription_identity")


class RecoveryFailure(ValueError):
    def __init__(self, stage):
        self.stage = stage
        super().__init__(stage)


class Refusal(ValueError):
    """Only fixed, locally authored diagnostics may be displayed."""


def require(ok, reason):
    if not ok:
        raise Refusal(reason)


def inline_override(text):
    """Read the launcher's JSON-string/inline-table TOML subset on Python 3.9.

    Only emitted config overrides are supported, not general TOML or profiles.
    Unknown syntax fails closed; never eval or load a deleted config file.
    """
    key, separator, value = text.partition('=')
    require(separator and re.fullmatch(r'[A-Za-z0-9_.-]+', key), 'unsupported native override')
    def parse(position, depth=0):
        require(depth < 20, 'native override nesting is unsupported')
        while position < len(value) and value[position].isspace():
            position += 1
        require(position < len(value), 'incomplete native override')
        char = value[position]
        if char == '"':
            item, count = json.JSONDecoder().raw_decode(value[position:])
            return item, position + count
        if char in '[{':
            mapping = char == '{'
            end = '}' if mapping else ']'
            result = {} if mapping else []
            position += 1
            while True:
                while position < len(value) and value[position].isspace(): position += 1
                if value[position:position + 1] == end: return result, position + 1
                if mapping:
                    match = re.match(r'[A-Za-z0-9_-]+', value[position:])
                    if match:
                        name, position = match[0], position + len(match[0])
                    else:
                        name, position = parse(position, depth + 1)
                    while position < len(value) and value[position].isspace(): position += 1
                    require(value[position:position + 1] == '=' and isinstance(name, str) and name not in result,
                            'unsupported native table')
                    position += 1
                item, position = parse(position, depth + 1)
                if mapping: result[name] = item
                else: result.append(item)
                while position < len(value) and value[position].isspace(): position += 1
                if value[position:position + 1] == end: return result, position + 1
                require(value[position:position + 1] == ',', 'unsupported native list')
                position += 1
        match = re.match(r'(true|false|-?[0-9]+)(?=\s*[,}\]]|\s*$)', value[position:])
        require(match, 'unsupported native scalar')
        return json.loads(match[0]), position + len(match[0])
    result, position = parse(0)
    require(not value[position:].strip(), 'trailing native override syntax')
    return key, result


def process_scope(pid, credential=False):
    """Read ONLY non-secret launch bindings from this explicitly selected PID.

    Darwin's kernel bundles argv and environ. Drop argv and every non-allowlisted
    field here; none of that raw buffer may reach a manifest, log or exception.
    """
    if sys.platform == "darwin":
        mib = (ctypes.c_int * 3)(1, 49, int(pid))
        size = ctypes.c_size_t(1024 * 1024)
        buf = ctypes.create_string_buffer(size.value)
        if ctypes.CDLL(None, use_errno=True).sysctl(mib, 3, buf, ctypes.byref(size), None, 0):
            raise ValueError("native launch scope is unreadable")
        raw = buf.raw[:size.value]
        argc = struct.unpack_from("i", raw)[0]
        require(0 < argc < 65536, "native argv count is invalid")
        offset = raw.index(b"\0", 4) + 1
        while raw[offset:offset + 1] == b"\0":
            offset += 1
        parts = raw[offset:].split(b"\0", argc)
        require(len(parts) == argc + 1, "native launch scope is incomplete")
        entries = parts[-1].split(b"\0")
    else:
        entries = Path("/proc/%d/environ" % pid).read_bytes().split(b"\0")
    result = {}
    for entry in entries:
        key, sep, value = entry.partition(b"=")
        name = key.decode("ascii", "ignore")
        if sep and (name in ENV_KEYS or (credential and name == 'FLEET_CODEX_SESSION_CRED')):
            require(name not in result, "ambiguous native launch scope")
            result[name] = value.decode("utf-8")
    return result


def kernel(pid):
    proof = launch.process(pid)
    uid = subprocess.check_output(["ps", "-p", str(pid), "-o", "uid="], text=True, timeout=3).strip()
    require(uid == str(os.getuid()), "process belongs to another login")
    return proof


def process_cwd(pid):
    if sys.platform != "darwin":
        return str(Path("/proc/%d/cwd" % pid).resolve(strict=True))
    out = subprocess.check_output(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                                  text=True, stderr=subprocess.DEVNULL, timeout=5)
    paths = [x[1:] for x in out.splitlines() if x.startswith("n")]
    require(len(paths) == 1, "native cwd is unknown")
    return str(Path(paths[0]).resolve(strict=True))


def script_is(argv, name):
    return len(argv) > 1 and Path(argv[1]).name == name


def binding(pane, socket):
    require(bool(re.fullmatch(r"%[0-9]+", pane)), "select an explicit pane ID")
    get = lambda key: launch.option(pane, key, socket)
    row = {k: get(k) for k in WINDOW_KEYS}
    row.update(pane=pane, socket=get("socket_path"), window=get("window_id"), pane_pid=get("pane_pid"))
    require(row["socket"] and row["window"] and row["pane_pid"].isdigit(), "pane is unavailable")
    require(row["@cc_agent"] == "codex" and row["@cc_launcher_pid"].isdigit(), "no original Codex launcher")
    require(not row["@launch"] and not row["@launch_receipt"],
            "accepted task recovery requires its own generation contract; execution retained")
    require(not row["@handoff_armed"], "transfer is armed; execution retained")
    require(launch.valid_uuid(row["@fleet_id"]), "worker identity is unavailable")
    require(os.path.isabs(row["@worktree"]), "original worktree is unavailable")
    return row


def worker_identity(row):
    # The existing resolver, without its normal lazy identity-file write.
    script = '. "$1/fleet-lib.sh"; s=$(fleet_current_session); fleet_uuid "$s" --read-only'
    env = dict(os.environ, TMUX=row['socket'] + ',0,0', TMUX_PANE=row['pane'])
    result = subprocess.run(['bash', '-c', script, '_', str(BIN)], env=env,
                            capture_output=True, text=True, timeout=8, check=True)
    fleet = result.stdout.strip()
    require(launch.valid_uuid(fleet), 'fleet identity is unavailable')
    return fleet + '/' + row['@fleet_id']


def proxy_account(scope, pid, context, argv, thread):
    require(thread.get('modelProvider') == 'fleet', 'native proxy provider changed')
    config = {}
    args = iter(argv)
    for arg in args:
        value = next(args, '') if arg in ('-c', '--config') else (
            arg.split('=', 1)[1] if arg.startswith('--config=') else
            arg[2:] if arg.startswith('-c') else '')
        if not value:
            continue
        key, separator, _ = value.partition('=')
        # The server receives every caller override after the launcher's flags.
        # A dotted/table/quoted spelling may replace the effective endpoint or
        # secret source. Refuse syntax we cannot interpret instead of proving an
        # earlier fleet table that the native process no longer uses.
        require(separator and re.fullmatch(r'[A-Za-z0-9_.-]+', key), 'unsupported native override')
        require(not key.startswith('model_provider') or key in ('model_provider', 'model_providers.fleet'),
                'unsupported native override')
        if key == 'model_provider':
            config['provider'] = inline_override(value)[1]
        elif key == 'model_providers.fleet':
            config['fleet'] = inline_override(value)[1]
    provider = config.get('fleet', {})
    require(isinstance(provider, dict) and config.get('provider') == 'fleet'
            and provider.get('env_key') == 'FLEET_CODEX_SESSION_CRED'
            and provider.get('wire_api') == 'responses'
            and set(provider) <= {'name', 'base_url', 'env_key', 'wire_api'}, 'original proxy configuration is unavailable')
    conf = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))).resolve()
    require(Path(scope.get('FLEET_CONF_DIR') or conf).resolve() == conf, 'native configuration scope differs')
    sid, wrap = scope.get('FLEET_CRED_SID', ''), scope.get('FLEET_SESSION_WRAP', '')
    require(re.fullmatch(r'[A-Za-z0-9_-]+', sid) and wrap.isdigit(), 'native proxy session scope is unavailable')
    state = conf / 'cred-proxy'
    record = state / 'sessions' / sid
    fields = dict(line.split('=', 1) for line in record.read_text().splitlines() if '=' in line)
    require(set(fields) <= {'hub_id', 'qsid', 'route', 'provider', 'wrap', 'account'}, 'unknown proxy session record schema')
    expected_record = dict(fields, sid=sid, wrap=wrap)
    account_module = runpy.run_path(str(BIN / '.fleet-account.py'))
    real, mirrored = account_module['codex_real_home'](scope['CODEX_HOME'], recovery=expected_record)
    require(mirrored, 'native proxy mirror is unproven')
    wrapper = kernel(int(wrap))
    require(script_is(process_argv(wrapper['pid']), 'fleet-session-wrap.sh')
            and launch.descendant(pid, wrapper['pid']), 'native credential wrapper is unproven')
    # The secret is read only into memory and passed on stdin to the current ctl
    # client. It never enters argv, a manifest, a tmux option, or an error.
    token = process_scope(pid, credential=True).get('FLEET_CODEX_SESSION_CRED', '')
    expected = dict(sid=sid, wrap_pid=wrapper['pid'], worker_id=context['worker_id'],
                    account=fields.get('account'), hub_id=fields.get('hub_id'))
    request = dict(version=1, provider='codex', cred=token, expected=expected)
    result = subprocess.run(['bash', str(BIN / 'fleet-cred-proxy.sh'), 'credential-inspect'],
                            input=json.dumps(request), capture_output=True, text=True, timeout=15)
    require(result.returncode == 0, 'original proxy credential could not be verified')
    proof = json.loads(result.stdout)['scope']
    require(proof.get('worker_id') == context['worker_id'], 'proxy worker scope changed')
    require(provider.get('base_url') == 'http://127.0.0.1:%d/codex' % proof['port'], 'native proxy port changed')
    return dict(kind='proxy', scope=proof, wrapper=wrapper, real_home=real, record=fields,
                provider=provider)


def check_ack(start, proof, ack):
    require(isinstance(ack, dict) and set(ack) <= set(START_KEYS) | {'phase', 'native_identity'}
            and all(ack.get(k) == start.get(k) and start.get(k) for k in START_KEYS),
            "Hub acknowledgement belongs to another reservation/owner/repo/endpoint")
    require(ack.get("phase") == "observed" and ack.get("native_identity") == proof,
            "Hub has not confirmed this exact native execution")


def read_start(context, proof):
    start = authority.hubrest.api("GET", "/authority/start",
                                 query={"repo": context["repo"], "reservation": context["reservation"]})
    require(isinstance(start, dict) and set(start) <= set(START_KEYS) | {'phase', 'native_identity'}
            and all(start.get(k) == context[k] for k in ("repo", "worker_id", "reservation"))
            and all(isinstance(start.get(k), str) and start[k] for k in START_KEYS),
            "original reservation scope is unavailable")
    require(start.get("phase") in ("starting", "observed"), "reservation is no longer observable")
    if start.get("phase") == "observed":
        check_ack(start, proof, start)
    else:
        require(not start.get("native_identity"), "reservation has an unknown native proof")
    return start


def hook_boundary(argv):
    """Report fixed paths without executing/reloading the old hook table."""
    missing, known = [], 0
    for i, arg in enumerate(argv):
        value = argv[i + 1] if arg in ("-c", "--config") and i + 1 < len(argv) else (
            arg.split("=", 1)[1] if arg.startswith("--config=") else "")
        if not value.startswith("hooks."):
            continue
        _, groups = inline_override(value)
        for group in groups:
            for hook in group.get("hooks", []):
                if hook.get("type") != "command":
                    continue
                words = shlex.split(hook.get("command", ""))
                paths = [word for word in words if word.startswith("/")]
                require(paths, "fixed hook path cannot be verified")
                known += 1
                missing.extend(path for path in paths if not Path(path).is_file())
    return dict(state="missing" if missing else "paths-present" if known else "unknown",
                missing=sorted(set(missing)), future_turns_verified=False)


def local_matches(pane, socket, context, proof, identity):
    snapshot = {key: launch.option(pane, key, socket) for key in
                ('@authority_receipt', '@codex_identity', '@codex_session_id')}
    raw = snapshot['@authority_receipt']
    if raw:
        saved = json.loads(raw)
        require(all(saved.get(k) == v for k, v in context.items()) and saved.get("native_identity") == proof,
                "local authority receipt belongs to another execution")
    raw = snapshot['@codex_identity']
    if raw:
        saved = json.loads(raw)
        require(all(saved.get(k) == v for k, v in identity.items()), "local Codex identity changed")
    sid = snapshot['@codex_session_id']
    require(not sid or sid == proof["native_session"], "local SID changed")
    return snapshot


def inspect(pane, socket, pid, sid):
    require(launch.valid_uuid(sid), "an explicit original SID is required")
    row = binding(pane, socket)
    socket = row["socket"]
    native = kernel(pid)
    require(Path(native["executable"]).name == "codex", "selected PID is not native Codex")
    version = subprocess.run([native["executable"], "--version"], stdin=subprocess.DEVNULL,
                             text=True, capture_output=True, timeout=5)
    require(version.returncode == 0 and bool(re.fullmatch(r"codex-cli \S+\s*", version.stdout)),
            "native provider is unverified")
    scope = process_scope(pid)
    require(not scope.get("FLEET_LAUNCH_CONTEXT"), "accepted execution is outside legacy recovery")
    context = json.loads(scope.get("FLEET_AUTHORITY_CONTEXT", "{}"))
    require(set(context) - {"worktree"} == {"repo", "worker_id", "reservation", "supervisor"},
            "original authority scope is missing")
    if "worktree" in context:  # #4573: a linked-worktree window's binding
        require(launch.validate_worktree(context["worktree"]) == launch.worktree_identity(row["@worktree"]),
                "authority worktree differs from the window")
    require(authority.repo_identity(row["@repo"]) == context["repo"]
            and context["worker_id"].split("/")[-1] == row["@fleet_id"]
            and len(context["worker_id"].split("/")) == 2
            and all(launch.valid_uuid(x) for x in context["worker_id"].split("/"))
            and launch.valid_uuid(context["reservation"]), "native scope differs from this worker/repo")
    require(type(context["supervisor"]) is int and context["supervisor"] > 1, "unknown authority supervisor")
    require(worker_identity(row) == context['worker_id'], 'native fleet identity differs')
    require(scope.get("TMUX_PANE") == pane and scope.get("TMUX", "").split(",")[0] == socket
            and scope.get("FLEET_CODEX_LAUNCHER_PID") == row["@cc_launcher_pid"], "native pane/launcher scope changed")
    remote = scope.get("FLEET_CODEX_REMOTE", "")
    require(remote.startswith("unix:///"), "original private RPC is unavailable")
    sock = Path(remote[7:])
    require(stat.S_ISSOCK(sock.stat().st_mode) and sock.stat().st_uid == os.getuid()
            and sock.parent.stat().st_uid == os.getuid() and stat.S_IMODE(sock.parent.stat().st_mode) == 0o700,
            "RPC socket is not private to this login")
    argv = process_argv(pid)
    require(len(argv) >= 4 and argv[-3:] == ["app-server", "--listen", remote], "PID is not the original private app-server")
    guardian = kernel(native["ppid"])
    runtime_process = kernel(guardian["ppid"])
    launcher = kernel(runtime_process["ppid"])
    supervisor = kernel(context["supervisor"])
    root = kernel(int(row["pane_pid"]))
    require(script_is(process_argv(guardian["pid"]), "fleet-codex-runtime.py")
            and "--guard" in process_argv(guardian["pid"])
            and script_is(process_argv(runtime_process["pid"]), "fleet-codex-runtime.py")
            and script_is(process_argv(launcher["pid"]), "fleet-codex.sh")
            and str(launcher["pid"]) == row["@cc_launcher_pid"]
            and script_is(process_argv(supervisor["pid"]), "fleet_repo_authority.py")
            and "--supervise" in process_argv(supervisor["pid"])
            and launcher['ppid'] == supervisor['pid']
            and launch.root_native(native, supervisor["pid"])
            and launch.descendant(supervisor["pid"], root["pid"]), "original process ancestry is unproven")
    children = subprocess.run(['pgrep', '-P', str(runtime_process['pid'])], capture_output=True, text=True, timeout=3)
    clients = []
    for child in children.stdout.split():
        p = kernel(int(child))
        if Path(p['executable']).name != 'codex':
            continue
        args = process_argv(p['pid'])
        require('--remote' in args and args[args.index('--remote') + 1] == remote,
                'native TUI endpoint differs')
        clients.append(p)
    require(len(clients) == 1, 'original native TUI is unknown or ambiguous')
    # Shells rebuild their environment storage; KERN_PROCARGS2 is not a reliable
    # snapshot of a running bash's exported variables. The direct supervisor
    # parent and its unchanged kernel lifetime prove the launcher; its Python
    # runtime and both native children must carry the original scope verbatim.
    for process in (runtime_process, guardian, clients[0]):
        inherited = process_scope(process['pid'])
        require(inherited.get('FLEET_AUTHORITY_CONTEXT') == scope.get('FLEET_AUTHORITY_CONTEXT'),
                'original process authority scope differs: ' + Path(process['executable']).name)
        require(inherited.get('TMUX_PANE') == pane and inherited.get('TMUX', '').split(',')[0] == socket,
                'original process pane scope differs: ' + Path(process['executable']).name)
    cwd = str(Path(row["@worktree"]).resolve(strict=True))
    require(process_cwd(pid) == cwd, "kernel cwd differs from original worktree")
    home = scope.get("CODEX_HOME", "")
    require(os.path.isabs(home) and Path(home).is_dir(), "native home is unavailable")
    subscription = json.loads(scope.get("FLEET_CODEX_SUBSCRIPTION", "{}"))
    proof = {k: native[k] for k in ("pid", "birth", "executable")}
    proof.update(worker_id=context["worker_id"], native_session=sid)
    rpc = runtime.RPC(remote, timeout=3, peer_pid=pid)
    try:
        loaded = rpc.call("thread/loaded/list", {})
        require(loaded.get("data") == [sid] and not loaded.get("nextCursor"), "RPC root thread is unknown or ambiguous")
        thread = runtime.thread(rpc, proof, cwd)
        require(thread.get("status", {}).get("type") in ("active", "idle"), "native thread is not loaded")
        # Native account verification uses read-only RPC and the original pinned
        # profile. It never refreshes tokens or recreates lost temporary configs.
        if subscription:
            require(Path(subscription['home']).resolve() == Path(home).resolve(), 'pinned subscription home differs')
            runpy.run_path(str(BIN / ".fleet-account.py"))["verify_codex_runtime"](
                remote, dict(session_id=sid, worktree=cwd), subscription=subscription, client=rpc, read_only=True)
            account = dict(kind='subscription', subscription={k: subscription[k] for k in ('profile', 'account', 'home')})
        else:
            account = proxy_account(scope, pid, context, argv, thread)
        phase = dict(status=thread.get('status'), turn=runtime.last_turn(rpc, proof))
        require(runtime.thread(rpc, proof, cwd).get("status") == phase['status']
                and runtime.last_turn(rpc, proof) == phase['turn'], "native phase changed during observation")
    finally:
        rpc.close()
    identity = dict(session_id=sid, owner=row["@cc_launcher_pid"], home=home, remote=remote, cwd=cwd)
    if subscription:
        identity['subscription'] = {k: subscription[k] for k in ('account', 'profile', 'home')}
    local_matches(pane, socket, context, proof, identity)
    start = read_start(context, proof)
    if account.get('kind') == 'proxy' and account['scope'].get('kind') == 'central':
        require(account['scope'].get('endpoint_id') == start['endpoint_id'], 'credential and reservation issuing nodes differ')
    processes = dict(native=native, guardian=guardian, runtime=runtime_process, launcher=launcher,
                     supervisor=supervisor, pane=root, tui=clients[0])
    require(all(kernel(p["pid"]) == p for p in processes.values()) and binding(pane, socket) == row,
            "execution changed during preflight")
    return dict(version=1, binding=row, processes=processes, context=context, proof=proof,
                identity=identity, hub=start, hooks=hook_boundary(argv), account=account, phase=phase,
                message_delivery="unverified; use the existing message receipt separately")


def same_plan(expected, current):
    require(expected.get("version") == 1, "unsupported recovery manifest")
    for key in ("binding", "processes", "context", "proof", "identity", "hooks", "account", "phase"):
        require(expected.get(key) == current.get(key), "recovery identity changed: " + key)
    require(all(expected["hub"].get(k) == current["hub"].get(k) for k in START_KEYS), "Hub reservation scope changed")
    # A prior attempt may have committed at the Hub and lost its acknowledgement.
    # This is the only permitted phase advancement; inspect verified exact native.
    require(expected["hub"].get("phase") in ("starting", "observed")
            and current["hub"].get("phase") in ("starting", "observed")
            and not (expected["hub"]["phase"] == "observed" and current["hub"]["phase"] != "observed"),
            "reservation phase changed")


def register(plan, ack):
    row, context, proof = plan["binding"], plan["context"], plan["proof"]
    check_ack(plan["hub"], proof, ack)
    require(binding(row["pane"], row["socket"]) == row, "local scope changed after Hub confirmation")
    require(all(kernel(p["pid"]) == p for p in plan["processes"].values()), "native changed after Hub confirmation")
    snapshot = local_matches(row["pane"], row["socket"], context, proof, plan["identity"])
    identity = dict(json.loads(snapshot['@codex_identity'] or '{}'), **plan['identity'])
    receipt = dict(json.loads(snapshot['@authority_receipt'] or '{}'), **context)
    receipt.update(native_identity=proof, hub_confirmation=ack)
    values = {"@authority_receipt": json.dumps(receipt, separators=(",", ":")),
              "@codex_identity": json.dumps(identity, separators=(",", ":")),
              "@codex_session_id": proof["native_session"]}
    # Tmux executes comparison and all three writes in one queue. Snapshot only
    # exact window options, including absent identities, so a late hook or a
    # replacement cannot get overwritten after the slower Hub call.
    guards = dict(snapshot)
    guards.update({k: row[k] for k in WINDOW_KEYS})
    require(all(not any(c in v for c in ("#{", "}", ",")) for k, v in guards.items()
                if k in ("@fleet_id", "@cc_agent", "@cc_launcher_pid", "@repo", "@handoff_armed")),
            "unsafe window identity")
    # Use tmux's literal q: quoting and equality through a short shell-free
    # command sequence; complex JSON guards are compared by an exact format.
    conditions = []
    for key, value in guards.items():
        escaped = value.replace("#", "##").replace(",", "#, ").replace("}", "#}")
        escaped = escaped.replace("#, ", "#,")
        conditions.append("#{==:#{" + key + "}," + escaped + "}")
    condition = conditions[0]
    for other in conditions[1:]:
        condition = "#{&&:" + condition + "," + other + "}"
    commands = " ; ".join(shlex.join(["set-option", "-w", "-t", row["pane"], key, value]) for key, value in values.items())
    if snapshot != values:
        launch.tmux("if-shell", "-F", "-t", row["pane"], condition, commands, socket=row["socket"])
    require(all(launch.option(row["pane"], k, row["socket"]) == v for k, v in values.items()),
            "local registration pending; keep the original manifest for retry")
    require(binding(row['pane'], row['socket']) == row
            and all(kernel(p['pid']) == p for p in plan['processes'].values()), 'local execution changed during registration')


def apply(plan):
    row, proof = plan["binding"], plan["proof"]
    current = inspect(row["pane"], row["socket"], proof["pid"], proof["native_session"])
    same_plan(plan, current)
    c = current["context"]
    # Always pass the Hub recovery fence, including retries with a prior ACK.
    # Exact replays make no journal write. An old Hub refuses this new action.
    try:
        ack = authority.start_call(c["repo"], c["reservation"], "recover-observe",
                                   worker_id=c["worker_id"], native_identity=proof)
        check_ack(current["hub"], proof, ack)
    except Exception:
        raise RecoveryFailure('hub-unconfirmed/local-unchanged') from None
    try:
        again = inspect(row["pane"], row["socket"], proof["pid"], proof["native_session"])
        same_plan(current, again)
        register(again, ack)
        final = inspect(row['pane'], row['socket'], proof['pid'], proof['native_session'])
        same_plan(again, final)
    except Exception:
        raise RecoveryFailure('hub-confirmed/local-pending') from None
    return dict(state="observed", hub_confirmation=ack, local_registered=True,
                hooks=again["hooks"], execution_preserved=True, message_delivery=again["message_delivery"])


@contextlib.contextmanager
def target_lock(plan):
    # Different reviewed manifests for one target still share a lock. No lock or
    # file is made by preflight; this is synchronization, not an execution ledger.
    row = plan['binding']
    key = hashlib.sha256(json.dumps([row['socket'], row['@fleet_id']]).encode()).hexdigest()
    conf = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet')))
    directory = conf / 'native-observe-locks'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(directory.lstat().st_uid == os.getuid() and stat.S_ISDIR(directory.lstat().st_mode)
            and stat.S_IMODE(directory.stat().st_mode) == 0o700, 'unsafe recovery lock directory')
    fd = os.open(directory / key, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        require(info.st_uid == os.getuid() and stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600,
                'unsafe recovery lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--preflight", action="store_true")
    actions.add_argument("--apply", metavar="PRIVATE_MANIFEST")
    parser.add_argument("--pane")
    parser.add_argument("--socket", default="")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--sid")
    args = parser.parse_args()
    if args.preflight:
        require(args.pane and args.pid and args.sid, "preflight requires --pane, --pid and --sid")
        print(json.dumps(inspect(args.pane, args.socket, args.pid, args.sid), indent=2))
        return 0
    require(not args.pane and not args.pid and not args.sid and not args.socket, "apply takes only its reviewed manifest")
    path = Path(args.apply)
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW)) as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size < 65536,
                'manifest must be a private 0600 file owned by this login')
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        plan = json.load(stream)
        with target_lock(plan):
            print(json.dumps(apply(plan), indent=2))
    return 0


def diagnostic(error):
    if isinstance(error, RecoveryFailure):
        return error.stage + '; preserve the execution and review before any retry'
    if isinstance(error, authority.hubrest.Fail):
        if 'HTTP 401' in str(error) or 'HTTP 403' in str(error):
            return 'hub/auth: current node authorization refused'
        if error.rc == 4:
            return 'hub/transport: current paired credential source or endpoint unavailable'
        return 'hub/response: original scoped reservation not confirmed'
    if isinstance(error, runtime.Unknown):
        return 'rpc/identity: original thread could not be verified'
    if isinstance(error, (EOFError, TimeoutError, ConnectionError)):
        return 'rpc/transport: original private endpoint unavailable'
    if isinstance(error, (OSError, subprocess.SubprocessError)):
        return 'process/local: kernel, private file, or local command unavailable'
    return 'validation: observation not confirmed; original execution retained'


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        # Upstream errors can contain private URLs, credentials or RPC bodies.
        # Keep detailed plans private; expose only fixed stage/reason classes.
        print(json.dumps(dict(state=getattr(error, 'stage', 'retained'), local_registered=False,
                              reason=str(error) if isinstance(error, Refusal) else diagnostic(error))), file=sys.stderr)
        sys.exit(1)
