#!/usr/bin/env python3
"""Legacy task reads and cancellation, plus own-session progress history.

Parent coordination, await and receive keep one-version refusal handlers.
None proves native exit or grants execution authority.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import uuid

BIN = Path(__file__).resolve().parent
TERMINAL = ("succeeded", "failed", "cancelled", "refused")


def task_web_link(task):
    """The existing exact Task route; reading it never authorizes execution."""
    hub = os.environ.get('CCQUOTA_HUB_URL') or os.environ.get('FLEET_HUB_URL') or ''
    if not hub:
        root = Path(os.environ.get('FLEET_CONF_DIR') or Path.home() / '.config/claude-fleet')
        try:
            hub = json.loads((root / 'hub.json').read_text()).get('url') or ''
        except (OSError, ValueError, AttributeError):
            pass
    return str(hub).rstrip('/') + '/app/s/' + (task if isinstance(task, str) and re.fullmatch(r'T[1-9][0-9]*', task) else '')


def continue_task(row, lang='zh', *, bin_dir=None):
    """Explicit owner action. Persist the exact request until acknowledged.

    The cache is only a retry envelope, never execution authority. The Hub
    checks current stop/generation, ownership and native exit evidence.
    """
    task = row.get('task') or ''
    en = lang == 'en'
    try:
        if not isinstance(task, str) or not re.fullmatch(r'T[1-9][0-9]*', task):
            raise ValueError('An exact Task reference is required')
        root = Path(os.environ.get('FLEET_CONF_DIR') or Path.home() / '.config/claude-fleet') / 'task-continue'
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (root / (task + '.lock')).open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            pending = root / (task + '.json')
            if pending.exists():
                payload = json.loads(pending.read_text())
                if payload.get('task') != task:
                    raise ValueError('Saved continuation identity does not match')
            else:
                view = call('get', task, bin_dir=bin_dir)
                t = view.get('task') if isinstance(view, dict) else None
                if (not isinstance(t, dict) or (t.get('task') or t.get('id')) != task
                        or not t.get('execution_endpoint') or not t.get('cancel_request')
                        or type(t.get('generation')) is not int or t['generation'] < 2):
                    raise ValueError('No current stopped Task authorization; refresh and inspect the Task')
                if ('cancel_request' in row and row['cancel_request'] != t['cancel_request']
                        or 'generation' in row and row['generation'] != t['generation']):
                    raise ValueError('Task changed since selection; refresh before continuing')
                seed = '%s:%s:%s' % (task, t['cancel_request'], t['generation'])
                payload = dict(task=task, expected_stop_operation_id=t['cancel_request'],
                               expected_generation=t['generation'],
                               idempotency_key='task-continue:' + hashlib.sha256(seed.encode()).hexdigest())
                tmp = pending.with_suffix('.tmp')
                with tmp.open('w') as f:
                    json.dump(payload, f)
                    f.flush()
                    os.fsync(f.fileno())
                tmp.replace(pending)
            writer = Path(bin_dir or BIN) / 'fleet-hub-write.sh'
            result = subprocess.run(['bash', str(writer), 'task_continue', json.dumps(payload)],
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=50)
            try:
                answer = json.loads(result.stdout)
            except ValueError:
                raise ValueError(result.stderr.strip() or 'Owner credential or Hub response unavailable')
            if isinstance(answer, dict) and 'error' in answer:
                # A definite refusal grants nothing. A later explicit action
                # may read a newer stop; a missing/malformed answer stays pinned.
                pending.unlink()
                raise ValueError(str(answer['error']))
            operation = answer.get('operation', {})
            if (answer.get('task') != task or answer.get('authorized_generation') != payload['expected_generation'] + 1
                    or operation.get('action') != 'worker_start'
                    or not isinstance(operation.get('operation_id'), str)
                    or str(uuid.UUID(operation['operation_id'])) != operation['operation_id']):
                raise ValueError('Continuation acknowledgment is not confirmed')
            # Even a refused/unknown launch is a recorded authorization. Do not
            # turn it into a fresh start by silently minting another request.
            pending.unlink()
            status = operation.get('status')
            if status not in ('accepted', 'pending', 'running', 'succeeded'):
                raise ValueError('Continuation recorded; inspect operation ' + operation['operation_id'] + ' (' + str(status) + ')')
            return 0, ('Continuation accepted for the same Task.' if en else '已受理继续同一任务。')
    except (ValueError, OSError, subprocess.SubprocessError, TypeError, AttributeError, KeyError) as exc:
        lead = 'Continuation not confirmed: ' if en else '继续尚未确认：'
        return 1, lead + str(exc) + (' · Open Task: ' if en else ' · 查看任务：') + task_web_link(task)


def call(action, task, payload=None, timeout=15, *, bin_dir=None):
    env = dict(os.environ, FLEET_HUB_TIMEOUT=str(max(1, min(10, int(timeout)))))
    result = subprocess.run(["bash", str(Path(bin_dir or BIN) / "fleet-task-record.sh"), action, task],
                            input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, timeout=timeout, env=env)
    if result.returncode:
        raise ValueError(result.stderr.strip() or "task record unavailable/refused")
    return json.loads(result.stdout)


def code(t, ref=""):
    """How a task is named to a person (EPIC T644 C3): its written code (K5H0) — the
    record's `short`, else this login's book — else its T<n> (an older hub)."""
    t = t if isinstance(t, dict) else {}
    if t.get("short"):
        return t["short"]
    tref = t.get("id") or t.get("task") or ref
    try:
        sys.path.insert(0, str(BIN))
        import fleet_id
        return fleet_id.task_code(tref) or tref
    except Exception:
        return tref
    finally:
        sys.path.pop(0)


def verdict(task):
    if task is None:
        return "UNKNOWN"
    outcome = task.get("outcome")
    return outcome.upper() if outcome in TERMINAL else "WAITING"


def record_view(task, timeout=15):
    """The record and the whole read beside it (started · progress · live)."""
    got = call("get", task, timeout=timeout)
    t = got.get("task")
    if not isinstance(t, dict) or t.get("authority_version") != 1:
        raise ValueError("task record is not authoritative")
    return t, got


def record(task, timeout=15):
    return record_view(task, timeout)[0]


def start_word(task, view):
    """An open record's agent, judged by the ONE reader (fleet_id.start_word, T642):
    the hub's read plus this machine's newest ID opened for it (`fleet-id.sh
    of-task`: its window here, its ledger's segments). {} = nothing says it is not
    up; else {word, why, hint}."""
    rec = view.get("task") if isinstance(view.get("task"), dict) else {}
    tref = rec.get("id") or task   # the windows' @task is T<n> (a code resolves on the hub)
    try:
        p = subprocess.run(["bash", str(BIN / "fleet-id.sh"), "of-task", tref], capture_output=True, text=True,
                           timeout=30, stdin=subprocess.DEVNULL)
        row = json.loads(p.stdout or "{}") if p.returncode == 0 else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        row = {}
    row = row if isinstance(row, dict) else {}
    sys.path.insert(0, str(BIN))
    try:
        import fleet_id
        w = fleet_id.start_word(view=dict(view, task=view.get("task") or {}), row=row)
        if w:
            # respawn takes the task's code (EPIC T644 C3)
            w["hint"] = fleet_id.start_hint(w["word"], code(rec, tref), row.get("id", ""), row.get("short", ""))
        return w
    finally:
        sys.path.pop(0)


def wait_task(_task, _timeout, _interval):
    print("RETIRED: Fleet await is disabled; view each Task directly.")
    return 2


def closed(task, worktree=False):
    """Is the task record closed (收口, issue #4897)? ONE read, never a wait:
    SUCCEEDED / FAILED / CANCELLED / REFUSED → exit 0; WAITING (still open) →
    exit 1; the hub unreadable or the record not authoritative → UNKNOWN, exit 3. The reapers
    (fleet-cleanup-idle.py, fleet-cleanup.sh, worktree-autoclean.sh) read a task
    session's end here — never its PR or an issue. With worktree=True, controlled
    bindings (including released ones) stay retained independently of Outcome."""
    try:
        t = record(task, timeout=10)
    except (ValueError, OSError, subprocess.SubprocessError):
        print("UNKNOWN\ntask: %s" % code(None, task))
        return 3
    state = verdict(t)
    if worktree and any(k in t for k in ("execution_owner", "execution_endpoint")):
        # Presence, including an explicitly released empty owner, comes from
        # the Hub's existing execution binding. Outcome is history, never
        # permission to discard an environment a future continuation may use.
        state = "WAITING" if all(isinstance(t[k], str) for k in
                                  ("execution_owner", "execution_endpoint") if k in t) else "UNKNOWN"
    print("%s\ntask: %s" % (state, code(t, task)))
    # an open record's hold words (E101): the idle reaper parks a session that
    # asked its person and was not answered
    for k in ("asked", "parked"):
        if state == "WAITING" and str(t.get(k) or "").strip():
            print("%s: 1" % k)
    return 3 if state == "UNKNOWN" else 1 if state == "WAITING" else 0


def child_summary(data):
    """One count per outcome (issue #4957): the hub's `summary` when it sends one,
    else counted here off the children — "open" while a child has no outcome."""
    s = data.get("summary")
    if isinstance(s, dict):
        return s
    s = dict(open=0, succeeded=0, failed=0, cancelled=0, refused=0)
    for child in data.get("children") or []:
        o = child.get("outcome") or ""
        s[o if o in s and o else "open"] += 1
    return s


def children(_task, _as_json):
    print("RETIRED: Parent coordination is disabled; view each Task directly.")
    return 2


def option(pane, key, socket=""):
    sock = ["-S" if os.path.isabs(socket) else "-L", socket] if socket else []
    return subprocess.run(["tmux", *sock, "display-message", "-p", "-t", pane, "#{" + key + "}"],
                          capture_output=True, text=True, timeout=5).stdout.strip()


def progress(pane, summary, state, event="", socket=""):
    """The session's own progress word (issue #4957): an EPIC driver's tick. It is
    the window's ID's (EPIC T497 C12): one `progress` event on its ledger, pushed
    to the hub mirror — `fleet-epic-tick.py status` reads its last_tick there.
    Never relayed: a tick is not a child report."""
    if not summary.strip():
        raise ValueError("progress needs a --summary")
    import fleet_id
    fid = option(pane, "@fleet_id", socket) if pane else ""
    if not fleet_id.is_fid(fid):
        raise ValueError("this pane carries no ID (@fleet_id)")
    ev = fleet_id.record_progress(fid, summary.strip(), state, event)
    if ev:
        fleet_id.push_later(fid)
    print("RECORDED\nid: %s\nevent_id: %s" % (fid, event or (ev or {}).get("seq", "-")))
    return 0


def cancel(task, event):
    """A person's cancel of a record no window ever opened (EPIC T497 C13): the
    one change the hub still takes on a record. A record an ID carries is that
    window's — the hub answers so, and the session is closed there."""
    t = record(task)
    if t.get("outcome"):
        print("%s\ntask: %s" % (verdict(t), code(t, task)))
        return 0
    call("mutate", task, dict(kind="transition", idempotency_key=event, generation=t.get("generation", 1),
                              expected_worker="", state="cancelled",
                              evidence="explicit cancel request; no window ever opened it"))
    print("CANCELLED\ntask: %s\nnote: no window opened it; nothing to stop" % code(t, task))
    return 2


def pending_start_task(row):
    """Only an explicit pending, record-only row may cancel a task's start."""
    task = row.get("task") or ""
    if (row.get("pending_start") is True and row.get("pending_start_explicit") is True
            and row.get("record_only") is True
            and not any(row.get(k) for k in ("worker_id", "running", "lost", "gone", "ended"))
            and isinstance(task, str) and re.fullmatch(r"T[1-9][0-9]*", task)):
        return task
    return ""


def cancel_pending_start(task, lang="zh"):
    """The panel/CLI cancellation road; owner authorization stays in the node API.

    Re-read the authoritative record, then let the mutation transaction refuse
    any session opened in between. Never fall through to stopping another ID.
    """
    en = lang == "en"
    changed = ("Task changed or a session opened; refresh the list and stop the live session if present."
               if en else "任务已变化或会话已打开；请刷新列表，若已有会话请对该会话执行停止。")
    try:
        if not re.fullmatch(r"T[1-9][0-9]*", task or ""):
            return 1, changed
        t, view = record_view(task)
        if ((t.get("task") or t.get("id")) != task or t.get("worker_id")
                or t.get("session_key") or view.get("started") or view.get("live")):
            return 1, changed
        if t.get("state") != "cancelled" and t.get("outcome") != "cancelled":
            if (t.get("outcome") or t.get("state") not in ("accepted", "starting")
                    or type(t.get("generation")) is not int or t["generation"] < 1):
                return 1, changed
            got = call("mutate", task, dict(kind="transition", idempotency_key="cancel-start:" + str(uuid.uuid4()),
                       generation=t["generation"], expected_worker="", state="cancelled",
                       evidence="operator cancelled pending start; no session observed"))
            if (not isinstance(got, dict) or (got.get("task") or got.get("id")) != task
                    or (got.get("state") != "cancelled" and got.get("outcome") != "cancelled")):
                return 1, ("Cancellation not confirmed; refresh before retrying." if en else "取消启动尚未确认；请刷新后核对。")
    except (ValueError, OSError, subprocess.SubprocessError, AttributeError, TypeError):
        return 1, (("Cancellation not confirmed. " if en else "取消启动未确认。") + changed)
    return 0, ("Start cancelled; this does not confirm any remote process has exited." if en else
               "已取消启动；这不表示已确认远端进程退出。")


def controlled_stop_task(row):
    """A current binding is a stop target even without a live window."""
    task = row.get('task')
    if (isinstance(task, str) and re.fullmatch(r'T[1-9][0-9]*', task)
            and (row.get('execution_endpoint') or row.get('task_execution'))):
        return task
    return ''


def stop_task(row, lang='zh', *, bin_dir=None):
    """Return (rc, acknowledgment), or None only for a verified legacy route.

    Local durable execution records and explicit window markers take precedence
    over an older Hub list. Unknown authority never authorizes worker_stop.
    """
    en = lang == 'en'
    def request(*args):
        return call(*args, bin_dir=bin_dir) if bin_dir is not None else call(*args)
    try:
        from fleet_task_execution import read_session, _snapshot
        from fleet_hub_common import is_identity
        task = row.get('task') or ''
        marker = row.get('task_execution')
        fid = row.get('fid') or row.get('fleet_id') or str(row.get('worker_id') or '').rpartition('/')[2]
        known = bool(row.get('execution_endpoint'))
        snapshots = []
        if marker:
            snapshots.append(_snapshot(json.loads(marker) if isinstance(marker,str) else marker))
        if is_identity(fid):
            local = read_session(fid)
            if local is not None:
                snapshots.append(local)
        for snapshot in snapshots:
            if (task and task != snapshot['task_ref']) or (fid and snapshot['execution_owner'].split('/')[-1] != fid):
                raise ValueError('Task/session identity changed; refresh before stopping')
            task, known = snapshot['task_ref'], True
        if not task:
            if known:
                raise ValueError('Controlled session has no exact Task identity')
            return None
        if not re.fullmatch(r'T[1-9][0-9]*', task):
            raise ValueError('Task identity is invalid')
        if not known:
            view = request('get', task)
            record = view.get('task') if isinstance(view,dict) else None
            if not isinstance(record,dict) or (record.get('task') or record.get('id')) != task:
                raise ValueError('Task authority is unavailable')
            known = bool(record.get('execution_endpoint') or record.get('cancel_request'))
        if not known:
            return None
        got = request('stop',task,dict(idempotency_key='task-stop:'+str(uuid.uuid4()),
                                   evidence='operator requested Task stop from Fleet'))
        operation = got.get('operation',{}) if isinstance(got,dict) else {}
        if (not isinstance(got,dict) or got.get('stop_requested') is not True
                or type(got.get('execution_exit_confirmed')) is not bool
                or not isinstance(operation,dict) or not is_identity(operation.get('operation_id'))
                or operation.get('action') != 'worker_stop'):
            raise ValueError('Task stop acceptance is not confirmed')
        if got['execution_exit_confirmed']:
            if got.get('scope') != 'native_session':
                raise ValueError('Native session exit scope is not confirmed')
            return 0, ('Stop recorded; the original native session exit is confirmed.' if en else
                       '停止请求已保存；原生会话退出已确认。')
        if got.get('execution_never_started') is True:
            return 0, ('Stop recorded; the original session never started.' if en else
                       '停止请求已保存；已确认原会话尚未启动。')
        return 0, ('Stop recorded; waiting for native session exit confirmation.' if en else
                   '停止请求已保存，等待原生会话退出确认。')
    except (ValueError,OSError,subprocess.SubprocessError,KeyError,TypeError,AttributeError) as exc:
        return 1, (('Stop not confirmed; no legacy stop was sent. ' if en else
                    '停止尚未确认，未降级关闭会话。') + str(exc))


def child_label(r):
    """A child named by ONE code (EPIC T644 C3): its task's (`#K5H0`, the book), else
    its window's ID's (the worker_id's second half, EPIC T497 C11) — never a T<n> beside
    it. Neither known ⇒ T<n>."""
    fid = str(r.get("worker_id") or "").rpartition("/")[2]
    try:
        sys.path.insert(0, str(BIN))
        import fleet_id
        own = fleet_id.task_code(r.get("task") or "") if r.get("task") else ""
        if own:
            return "#" + own
        if fleet_id.is_fid(fid):
            short = fleet_id.fold(fleet_id.read(fid))["opened"].get("short") \
                or fleet_id.short_for(fid, fleet_id.known_ids([fid]))
            return "#" + short
    except Exception:
        pass
    finally:
        sys.path.pop(0)
    return r["task"]


def receive(_file):
    print("RETIRED: Parent report delivery is disabled; nothing was delivered.")
    return 2


def main():
    p = argparse.ArgumentParser(description=__doc__)
    # report / finalize: compat-1v: 下一批删 — an older caller (a pre-C8 launch
    # supervisor finalizing on exit, an older fleet-report-parent.sh).
    p.add_argument("action", choices=("children", "await", "closed", "progress", "cancel", "receive",
                                      "report", "finalize"))
    p.add_argument("--task", default="")
    p.add_argument("--worktree", action="store_true", help="closed: retain controlled Task workspaces")
    p.add_argument("--file", default="")
    p.add_argument("--pane", default=os.environ.get("TMUX_PANE", ""))
    p.add_argument("--socket", default="")
    p.add_argument("--json", action="store_true")
    p.add_argument("--timeout", type=int, default=60)
    p.add_argument("--interval", type=int, default=5)
    p.add_argument("--state", default="waiting")
    p.add_argument("--summary", default="")
    p.add_argument("--outcome", choices=("succeeded", "failed"), default="")
    p.add_argument("--pr", default="")
    p.add_argument("--event", default="")
    p.add_argument("--dry", action="store_true")
    args = p.parse_args()
    try:
        if args.action == "closed": return closed(args.task, worktree=args.worktree)
        if args.action in ("children", "await"):
            print("RETIRED: Parent coordination and Fleet await are disabled; view each Task directly.")
            return 2
        if args.action == "progress": return progress(args.pane, args.summary, args.state, args.event, args.socket)
        if args.action == "receive": return receive(args.file)
        if args.action == "finalize": return 0
        if args.action == "report":
            print("ID_SWITCH\nnote: a report is a result of the window's ID (fleet-report-parent.sh)")
            return 5
        if args.action == "cancel":
            if not args.event: raise ValueError("cancel needs a stable --event")
            return cancel(args.task, args.event)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as e:
        print("UNKNOWN\nnote: %s" % e)
        return 75 if args.action == "receive" else 3


if __name__ == "__main__":
    sys.exit(main())
