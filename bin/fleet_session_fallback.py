"""Quota continuation for the shared session gate (T943).

Only an explicit native API quota error authorizes a transfer. The transfer
controller remains the authority on identity, drafts, tools, schedules and exit.
The per-source receipt is write-ahead: unknown completion is never retried.
"""
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

def quota_error(path, sid):
    """Latest main conversation message is a native hard-quota API error."""
    if path is None:
        return None
    last = None
    try:
        # Bounded tail; skip an incomplete first record. Never infer an error
        # from a user's words, a tool result, or another session's transcript.
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 2 * 1024 * 1024))
            if f.tell():
                f.readline()
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(r, dict) or r.get("sessionId") != sid or r.get("isSidechain"):
                    continue
                if r.get("type") in ("assistant", "user"):
                    last = r
    except OSError:
        return None
    if not last or last.get("type") != "assistant" or last.get("isApiErrorMessage") is not True:
        return None
    if last.get("error") not in ("rate_limit", "rate_limit_error", "quota_exceeded"):
        return None
    message = last.get("message")
    content = message.get("content", []) if isinstance(message, dict) else []
    if not isinstance(content, list):
        return None
    text = " ".join(str(x.get("text", "")) for x in content if isinstance(x, dict) and x.get("type") == "text")
    # A per-minute 429, network/auth error and cancellation are not quota.
    if re.search(r"per.minute|requests per|too many requests|cancel|authentication|unauthorized", text, re.I):
        return None
    if not re.search(r"(?:hit|reached|exceeded) your (?:weekly |usage |session )?limit|weekly limit|usage limit|session limit|quota (?:exhausted|exceeded)|claude_pool_unavailable", text, re.I):
        return None
    return dict(source_session=sid, error_id=last.get("uuid", ""), transcript=str(path))

def receipt(gate, fid):
    return gate.read_json(gate.fid_dir(fid) / "quota-continuation.json")


def native_quota_dialog(w):
    # Candidate only. The controller proves the full menu, tools, schedules and
    # normal cancellation; this never makes a generic needs/approval idle.
    try:
        native = json.loads(w.get('agent_status', '{}'))
    except (ValueError, TypeError):
        return False
    return (w['state'] == 'needs' and not w.get('needs') and w['word'] == 'blocked'
            and isinstance(native, dict) and native.get('app') == 'claude-code'
            and not native.get('kind') and native.get('msg') == 'dialog open')


def maybe_start(gate, w, rows):
    """Called under the delivery lock, before any further words can be sent."""
    if w is None or w["agent"] != "claude" or not w["sid"]:
        return
    pending = [r for r in rows if r.get("state") in ("trying", "native", "waking")]
    dialog = native_quota_dialog(w)
    boundary = dialog or w["state"] == "done" or (w["state"] == "exited" and w["word"] == "error")
    old = receipt(gate, w["fid"])
    # Only these two refusals precede *any* controller launch. A later native
    # cancellation or settled delivery may provide a candidate worth proving.
    # Attempted/uncertain controllers never use this road, even if state changes.
    newly_supported = (old and old.get('state') == 'blocked'
                       and old.get('why') in ('boundary', 'delivery_unsettled')
                       and boundary and not pending and not w['parked']
                       and (dialog or not gate.busy_of(w)))
    if old and old.get("source_session") == w["sid"] and old.get("state") != "waiting" and not newly_supported:
        return
    signal = quota_error(gate.claude_transcript(w["sid"]), w["sid"])
    if not signal:
        return
    why = "delivery_unsettled" if pending else "boundary" if (gate.busy_of(w) and not dialog) or w["parked"] or not boundary else ""
    same = old if old and old.get("source_session") == w["sid"] and not newly_supported else {}
    waiting = why == "boundary" and not w["parked"] and gate.busy_of(w) != "asking" and gate.now() - same.get("at", gate.now()) < 30
    signal.update(at=same.get("at", gate.now()), request_id=same.get("request_id") or uuid.uuid4().hex)
    signal.update(state="waiting" if waiting else "blocked" if why else "starting", why=why, fid=w["fid"])
    signal.update(phase='preflight', controller_attempted=False)
    path = gate.fid_dir(w["fid"]) / "quota-continuation.json"
    gate.write_json(path, signal)
    # Queued words belong to the source conversation. Return them to the
    # existing composer recovery flow; never replay them as the pickup prompt.
    for r in rows:
        if r.get("state") == "queued":
            gate.ret(r, "quota_continuation")
    if why:
        return
    try:
        subprocess.Popen([sys.executable, str(gate.BIN / "fleet_session_gate.py"), "quota-transfer",
                          "--fid", w["fid"], "--source-session", w["sid"], "--request-id", signal["request_id"]],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)
    except OSError:
        signal.update(state="blocked", why="preflight_unavailable")
        gate.write_json(path, signal)

def matching_source(gate, w, r):
    if not w or w.get('fid') != r.get('fid') or w['agent'] != 'claude' or w['sid'] != r['source_session']:
        return False
    signal = quota_error(gate.claude_transcript(w['sid']), w['sid'])
    return bool(signal and signal['error_id'] == r.get('error_id'))


def recover(gate, fid, sid, request_id):
    """One explicit recheck of a provably unattempted controller, never a reset."""
    path = gate.fid_dir(fid) / 'quota-continuation.json'
    with gate.lock(fid):
        old = receipt(gate, fid) or {}
        if (old.get('source_session') != sid or old.get('request_id') != request_id
                or old.get('fid') != fid):
            return dict(ok=False, why='receipt_changed')
        preflight_state = (old.get('state') in ('starting', 'checking') or
                           (old.get('state') == 'blocked' and old.get('why') in
                            ('preflight_refused', 'preflight_timeout', 'preflight_unavailable')))
        if (not preflight_state or old.get('phase') != 'preflight'
                or old.get('controller_attempted') is not False or old.get('target_session')):
            return dict(ok=False, why='completion_not_retryable')
        if not matching_source(gate, gate.window(fid), old):
            return dict(ok=False, why='source_changed')
        rows = gate.records(fid)
        if any(r.get('state') in ('trying', 'native', 'waking') for r in rows):
            return dict(ok=False, why='delivery_unsettled')
        new_id = uuid.uuid4().hex
        previous = path.parent / 'quota-history' / (new_id + '.json')
        previous.parent.mkdir(mode=0o700, exist_ok=True)
        gate.write_json(previous, old)
        signal = dict(old, state='starting', why='', at=gate.now(), request_id=new_id,
                      previous_receipt=str(previous), recovered_from=request_id)
        gate.write_json(path, signal)
        for r in rows:
            if r.get('state') == 'queued':
                gate.ret(r, 'quota_continuation')
        try:
            subprocess.Popen([sys.executable, str(gate.BIN / 'fleet_session_gate.py'), 'quota-transfer',
                              '--fid', fid, '--source-session', sid, '--request-id', new_id],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True, close_fds=True)
        except OSError:
            signal.update(state='blocked', why='preflight_unavailable')
            gate.write_json(path, signal)
            return dict(ok=False, why='preflight_unavailable', request_id=new_id)
        return dict(ok=True, request_id=new_id)


def run(gate, fid, sid, request_id):
    path = gate.fid_dir(fid) / 'quota-continuation.json'
    with gate.lock(fid):
        r = receipt(gate, fid)
        w = gate.window(fid)
        if (not request_id or not r or r.get('fid') != fid or r.get('source_session') != sid
                or r.get('request_id') != request_id or r.get('state') != 'starting'):
            return
        r.update(state='checking', phase='preflight', controller_attempted=False)
        gate.write_json(path, r)
    if not matching_source(gate, w, r):
        r.update(state='blocked', why='source_changed')
        finish(gate, path, r, expected='checking')
        return
    argv = ['bash', str(gate.BIN / 'fleet-transfer.sh'), '--session', w['sock'], '--window', w['win'],
            '--to', 'codex', '--quota-continuation', '--expected-session-id', sid]
    # Dry-run is read-only, including native quota cancellation. A refused
    # preview has no uncertain writer and may be explicitly rechecked later.
    env = dict(os.environ, FLEET_TRANSFER_RETRYING='1')
    env.pop('TMUX_PANE', None)
    why = ''
    try:
        with (path.parent / ('quota-preflight-' + request_id + '.log')).open('w') as log:
            p = subprocess.run(argv + ['--dry-run'], stdin=subprocess.DEVNULL, stdout=log,
                               stderr=subprocess.STDOUT, env=env, timeout=90)
        if p.returncode:
            why = 'preflight_refused'
    except subprocess.TimeoutExpired:
        why = 'preflight_timeout'
    except OSError:
        why = 'preflight_unavailable'
    if why:
        r.update(state='blocked', why=why)
        finish(gate, path, r, expected='checking')
        return
    # CAS under the delivery lock, then write ahead BEFORE any mutating
    # controller. Superseded previews and crashes cannot create a second writer.
    with gate.lock(fid):
        current = receipt(gate, fid) or {}
        if current.get('request_id') != request_id or current.get('state') != 'checking':
            return
        if not matching_source(gate, gate.window(fid), r):
            r.update(state='blocked', why='source_changed')
            gate.write_json(path, r)
            return
        if any(x.get('state') in ('trying', 'native', 'waking') for x in gate.records(fid)):
            r.update(state='blocked', why='preflight_refused')
            gate.write_json(path, r)
            return
        r.update(state='transferring', phase='controller', controller_attempted=True)
        gate.write_json(path, r)
    why = 'transfer_refused'
    try:
        with (path.parent / 'quota-transfer.log').open('w') as log:
            p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env)
        after = gate.window(fid)
        if after and after['agent'] == 'codex' and after['sid']:
            r.update(state='continued' if p.returncode == 0 else 'recovery',
                     why='' if p.returncode == 0 else 'transfer_incomplete',
                     target_session=after['sid'], completed_at=time.time())
            finish(gate, path, r)
            return
    except OSError:
        why = 'controller_unavailable'
    r.update(state='blocked', why=why)
    finish(gate, path, r)


def finish(gate, path, result, expected='transferring'):
    # A late old controller cannot overwrite a newer source generation.
    with gate.lock(result['fid']):
        current = gate.read_json(path) or {}
        if current.get('request_id') == result['request_id'] and current.get('state') == expected:
            gate.write_json(path, result)

def view(gate, w):
    r = receipt(gate, w["fid"]) if w else None
    if not r:
        return None
    if w["sid"] not in (r.get("source_session"), r.get("target_session")):
        return None
    state = r.get("state")
    if state == "blocked" and not quota_error(gate.claude_transcript(w["sid"]), w["sid"]):
        return None  # an explicit native continuation has moved past the error
    if (state == "waiting" and gate.now() - r.get("at", 0) >= 30) or (state in ("starting", "checking", "transferring") and gate.now() - r.get("at", 0) > 360):
        state = "recovery"  # completion is unknown; never start a second writer
    return dict(state=state, to="codex", message=(
        "Claude 额度已用完，正在换 Codex 继续。" if state in ("waiting", "starting", "checking", "transferring") else
        "已换 Codex 继续。" if state == "continued" else
        "Claude 额度已用完，暂时无法安全接续；记录已保留，可从终端恢复或在新会话里接着说。"))
