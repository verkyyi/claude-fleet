#!/usr/bin/env python3
"""fleet-orchestrator-state.py — the orchestrator's state, carried across a compaction
(issue #2583, EPIC #2581 C2).

Usage: fleet-orchestrator-state.py hook                 (stdin: a Claude Code hook's JSON)
       fleet-orchestrator-state.py save [--transcript T] [--reason R] [--trigger auto|manual]
       fleet-orchestrator-state.py brief [--source S] [--no-mark]
       fleet-orchestrator-state.py path

THE GAP. The orchestrating session (bin/fleet-orchestrator.sh, `@fleet_role
orchestrator`) keeps its working state only in its conversation: which EPIC batches
it follows, which children it waits on, which `[child-report]`s came in, and the
Loop it re-arms with ScheduleWakeup. C1 (#2582) put its ROLE in the system prompt;
a compaction still leaves a summary that is free to drop the rest — and a Loop lives
in the agent process, so once the summary forgets it, nothing wakes the session.

WHAT IT DOES. ONE file, `$FLEET_CONF_DIR/global/orchestrator.state.json` (EPIC
#2581 shared convention 2):

    {v, ts, reason, trigger, fleet_compaction, session,
     batches: [{epic, repo, driver, tick, last_tick, fresh}],
     waiting: [{child, bucket, state, title, pr}], children: "3/5 ✓ · 1!",
     unread_reports: [{child, state, pr, summary, seq}], seq, seen_seq,
     loop: {prompt, delay, next_at, rearm} | null}

  written  PreCompact (every trigger) and SessionEnd — the whole picture: the EPIC
           batch marks (`global/epic-running.d/`, the driver window by its @epic),
           `fleet-children.sh orchestrator --json` (who is still out, and the report
           events past `seen_seq`), the Loop off the transcript (fleet_loop_mark.py's
           walk — the same reading `rearm` makes);
           PostToolUse ScheduleWakeup / CronCreate / CronDelete — the loop only, in
           place; UserPromptSubmit carrying a `[child-report]` — the children half,
           detached (the hub read behind fleet-children.sh may take seconds, and a
           prompt must not wait for it).
  read     SessionStart (`compact`, `resume`, `startup`) — a ≤ 40-line 「你是编排会话，
           当前状态如下」 as additionalContext, ending in the next step: re-arm the Loop
           (ScheduleWakeup with the same prompt and delay). A state older than 2 hours
           is marked 只当参考 — check the children first. Reading it marks the reports
           read (`seen_seq`). On `resume` / `startup` (an exit, a killed process, a
           restart — no SessionEnd may have run) the batches and the Loop are read
           again first (issue #2585); fleet-orchestrator.sh hands that resumed
           conversation its first turn, so it re-arms with nobody typing.
           After a MANUAL compaction the REPL sits idle and additionalContext only
           rides a turn something else starts, so it also starts that turn: stamps
           @compact_stage restored + @compact_restored_ts and hands the pane to
           bin/fleet-compact-resume.sh (the sender the fleet's own compaction uses —
           its dedup, typing hold and skip rules), whose `/fleet-compact-resume` turn
           prints `brief` for this window. The fleet's own compaction (stage
           `compacting` at PreCompact) already gets that turn from refocus-hook.sh;
           an auto compaction runs mid-turn and carries on.

WHO. Only a Claude orchestrator window: `@fleet_role orchestrator`, not `@cc_agent
codex` (convention 5 — hooks/codex-map.json drops this command for Codex too), in
tmux, CLAUDE_CODE_ENTRYPOINT cli. Every other pane: zero output, nothing written,
one tmux read.

Selftest: bin/fleet-orchestrator-state-selftest.sh; BREAK-IT row `orchestrator-compacted`.
Kill switch: FLEET_ORCH_STATE=0 (fleet.conf / the fleet overlay, read through
fleet-hook-conf.sh). Always exits 0 from `hook` and prints nothing but the
SessionStart JSON: a hook must never cost the session its turn or its compaction.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)

MAX_LINES = 40                       # convention 2 / 发起人拍板 2
STALE_SECS = 7200                    # older than this: 只当参考
CHILDREN_SECS = 12                   # bound on the fleet-children.sh read
SENTINEL = '[child-report]'


def conf_dir():
    return os.environ.get('FLEET_CONF_DIR') or os.path.join(os.path.expanduser('~'), '.config', 'claude-fleet')


def state_path():
    return os.path.join(conf_dir(), 'global', 'orchestrator.state.json')


def load():
    try:
        with open(state_path(), encoding='utf-8') as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def store(d):
    p = state_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = '%s.tmp.%d' % (p, os.getpid())
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(d, fh, ensure_ascii=False, indent=1)
        fh.write('\n')
    os.replace(tmp, p)


def tmux(*args):
    try:
        return subprocess.run(['tmux', *args], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ''


def pane():
    return os.environ.get('TMUX_PANE', '') if os.environ.get('TMUX') else ''


def window(p):
    """(role, agent, compact_stage) of the pane's window — ONE tmux read."""
    v = tmux('display-message', '-p', '-t', p, '#{@fleet_role}|#{@cc_agent}|#{@compact_stage}')
    parts = (v.split('|') + ['', '', ''])[:3]
    return parts[0], parts[1], parts[2]


def is_orchestrator(p):
    if not p or os.environ.get('CLAUDE_CODE_ENTRYPOINT', 'cli') != 'cli':
        return False, ''
    role, agent, stage = window(p)
    return role == 'orchestrator' and agent != 'codex', stage


def switched_off():
    if os.environ.get('FLEET_ORCH_STATE') == '0':
        return True
    try:
        out = subprocess.run(['bash', os.path.join(BIN, 'fleet-hook-conf.sh'), 'FLEET_ORCH_STATE'],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ''
    return out == '0'


# --- the three halves ------------------------------------------------------------

def batches(now):
    """Every EPIC batch marked running on this login (fleet-epic-heartbeat.sh's marks),
    with the driver window that stamped `@epic <repo>#<N>`."""
    d = os.path.join(conf_dir(), 'global', 'epic-running.d')
    files = []
    try:
        files = sorted(os.path.join(d, f) for f in os.listdir(d) if '.tmp.' not in f)
    except OSError:
        pass
    legacy = os.path.join(conf_dir(), 'global', 'epic-running')   # compat-1v: 下一批删
    if os.path.isfile(legacy):
        files.append(legacy)
    drivers = {}
    seen = set()
    for row in tmux('list-windows', '-a', '-F', '#{window_id}\t#{@epic}\t#{window_name}').splitlines():
        wid, epic, name = (row.split('\t') + ['', '', ''])[:3]
        if wid in seen or '#' not in epic:      # a view session lists a window twice
            continue
        seen.add(wid)
        drivers[epic.rsplit('#', 1)[1]] = name
    out = []
    for f in files:
        kv = {}
        try:
            with open(f, encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    k, _, v = line.partition(': ')
                    kv[k.strip()] = v.strip()
        except OSError:
            continue
        epic = ''.join(c for c in kv.get('epic', '') if c.isdigit())
        if not epic:
            continue
        try:
            at = int(kv.get('epoch') or os.stat(f).st_mtime)
        except (OSError, ValueError):
            at = 0
        try:
            ttl = int(kv.get('ttl') or 2700)
        except ValueError:
            ttl = 2700
        repo = kv.get('repo', '-')
        out.append(dict(epic=int(epic), repo='' if repo == '-' else repo,
                        driver=drivers.get(epic, ''), tick=kv.get('tick', ''),
                        last_tick=at, fresh=now - at <= ttl))
    return out


def children(since):
    """fleet-children.sh orchestrator --json [--since]; None when it cannot answer."""
    # FLEET_ORCH_CHILDREN_CMD: the selftest's seam (a command line, args appended).
    seam = os.environ.get('FLEET_ORCH_CHILDREN_CMD', '').split()
    cmd = (seam or ['bash', os.path.join(BIN, 'fleet-children.sh')]) + ['orchestrator', '--json']
    if since:
        cmd += ['--since', str(since)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=CHILDREN_SECS,
                           stdin=subprocess.DEVNULL)
        d = json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def children_half(prev):
    out = {}
    full = children(0)
    if full is None:
        return out                       # keep what the last save knew
    seq = int(full.get('seq') or 0)
    out['seq'] = seq
    out['children'] = ((full.get('summary') or {}).get('text') or '')
    out['waiting'] = [dict(child=k.get('child', ''), bucket=k.get('bucket', ''),
                           state=k.get('state', ''), title=(k.get('title') or '')[:60],
                           pr=k.get('pr') or '')
                      for k in full.get('children') or [] if k.get('bucket') in ('▸', '⏳', '!')]
    seen = int(prev.get('seen_seq') or 0)
    out['seen_seq'] = seen
    evs = []
    if seq > seen:
        d = children(seen) if seen else full
        if d is not None:
            evs = d.get('events') if seen else [k.get('last') for k in d.get('children') or []]
    evs = [e for e in evs or [] if isinstance(e, dict) and int(e.get('seq') or 0) > seen]
    evs.sort(key=lambda e: int(e.get('seq') or 0))
    out['unread_reports'] = [dict(child=e.get('child', ''), state=e.get('state', ''),
                                  pr=e.get('pr') or '', summary=(e.get('summary') or '')[:140],
                                  seq=int(e.get('seq') or 0)) for e in evs[-8:]]
    return out


def loop_from_transcript(path, now):
    """The pending Loop, read the way `fleet_loop_mark.py rearm` reads it."""
    if not path:
        return None
    try:
        import fleet_loop_mark as lm
        lines = lm.tail_lines(path)
    except (ImportError, OSError):
        return None
    line = lm.rearm(lines, now)
    if not line:
        return None
    last = None
    for _n, inp, _r, use_ts, res_ts in lm.claude_tool_results(lines, ('ScheduleWakeup',)):
        last = (inp, lm._epoch(res_ts) or lm._epoch(use_ts))
    loop = dict(prompt='', delay=0, next_at=0, rearm=line)
    if last and not last[0].get('stop') and last[0].get('prompt'):
        inp, at = last
        try:
            delay = int(inp.get('delaySeconds') or 0)
        except (TypeError, ValueError):
            delay = 0
        loop.update(prompt=inp['prompt'], delay=delay, next_at=(at or now) + delay)
    return loop


def loop_from_call(payload, now, prev):
    """PostToolUse: the one call that just ran, applied in place."""
    name = payload.get('tool_name')
    inp = payload.get('tool_input') if isinstance(payload.get('tool_input'), dict) else {}
    if name == 'ScheduleWakeup':
        if inp.get('stop') is True:
            return None
        try:
            delay = int(inp.get('delaySeconds') or 0)
        except (TypeError, ValueError):
            delay = 0
        import fleet_loop_mark as lm
        return dict(prompt=inp.get('prompt') or '', delay=delay, next_at=now + delay,
                    rearm=lm.loop_input(inp.get('prompt')))
    if payload.get('transcript_path'):     # a cron job: the whole walk decides
        return loop_from_transcript(payload['transcript_path'], now)
    return prev.get('loop')


# --- write / read ------------------------------------------------------------------

def save(transcript='', reason='save', trigger='', stage='', prev=None, children_too=True):
    now = int(time.time())
    prev = load() if prev is None else prev
    d = dict(prev)
    d.update(v=1, ts=now, reason=reason, session=_session())
    if trigger:
        d.update(trigger=trigger, precompact_ts=now, fleet_compaction=stage == 'compacting')
    d['batches'] = batches(now)
    if children_too:
        d.update(children_half(prev))
    if transcript:
        d['loop'] = loop_from_transcript(transcript, now)
    for k, v in (('waiting', []), ('unread_reports', []), ('seq', 0), ('seen_seq', 0), ('loop', None)):
        d.setdefault(k, v)
    store(d)
    return d


def _session():
    return tmux('display-message', '-p', '-t', pane(), '#{?#{session_group},#{session_group},#{session_name}}') if pane() else ''


def hm(epoch):
    try:
        return datetime.datetime.fromtimestamp(int(epoch)).strftime('%H:%M')
    except (TypeError, ValueError, OverflowError, OSError):
        return '?'


def ago(secs):
    secs = max(0, int(secs))
    if secs < 120:
        return '刚刚'
    if secs < 7200:
        return '%d 分钟前' % (secs // 60)
    return '%d 小时前' % (secs // 3600)


def brief(d, source='compact', now=None):
    """The ≤ 40-line summary the session gets back. '' when there is no state."""
    if not d or not d.get('ts'):
        return ''
    now = int(time.time()) if now is None else now
    age = now - int(d['ts'])
    why = {'compact': '上下文刚被压缩', 'resume': '会话刚续开', 'startup': '会话刚重开'}.get(source, '会话刚回来')
    head = ['[fleet orchestrator state] 你是这台 fleet 的编排会话；%s，这是压缩/退出前存下的状态（%s 存，%s）。'
            % (why, hm(d['ts']), ago(age))]
    if age > STALE_SECS:
        head.append('⚠ 这份状态已超过 2 小时，只当参考：先用 mcp__fleet__children 和 mcp__fleet__gh 核对再说。')
    body = ['## 在跟的批次']
    bs = d.get('batches') or []
    for b in bs[:6]:
        body.append('- EPIC #%s%s · 驱动 %s · tick %s · 上次心跳 %s%s' % (
            b.get('epic'), (' (%s)' % b['repo']) if b.get('repo') else '',
            b.get('driver') or '?', b.get('tick') or '-', ago(now - int(b.get('last_tick') or 0)),
            '' if b.get('fresh') else '（心跳已过期，批次可能已停）'))
    if not bs:
        body.append('- （没有在跑的批次）')
    w = d.get('waiting') or []
    body.append('## 在等谁%s' % ('（%s）' % d['children'] if d.get('children') else ''))
    for k in w[:10]:
        body.append('- %s %s %s%s%s' % (k.get('bucket', ''), k.get('child', ''), k.get('state', ''),
                                         (' · ' + k['title']) if k.get('title') else '',
                                         (' · PR #%s' % k['pr']) if k.get('pr') else ''))
    if len(w) > 10:
        body.append('- …还有 %d 个，见 mcp__fleet__children' % (len(w) - 10))
    if not w:
        body.append('- （没有还在外面的子会话）')
    u = d.get('unread_reports') or []
    body.append('## 未读回报（上次接力后到达）')
    for e in u[-8:]:
        body.append('- %s %s%s%s' % (e.get('child', ''), e.get('state', ''),
                                     (' #%s' % e['pr']) if e.get('pr') else '',
                                     (' — ' + e['summary']) if e.get('summary') else ''))
    if not u:
        body.append('- （没有）')
    body.append('## 循环')
    lp = d.get('loop')
    if isinstance(lp, dict) and (lp.get('prompt') or lp.get('rearm')):
        if lp.get('prompt'):
            body.append('- 压缩前在跑：ScheduleWakeup，delaySeconds %s，原定 %s 唤醒。'
                        % (lp.get('delay') or '?', hm(lp.get('next_at'))))
            body.append('- prompt（原样）：%s' % ' '.join(str(lp['prompt']).split())[:300])
        body.append('- /loop 形式：`%s`' % lp.get('rearm', '/loop'))
        step = ('下一步：①先重新 arm 循环——调用 ScheduleWakeup，prompt 原样照抄「prompt（原样）」那行，delaySeconds %s；'
                % (lp.get('delay') or 1200))
    else:
        body.append('- （没有在跑的循环）')
        step = '下一步：①'
    step += '②一句话报出当前批次和未读回报（人在就告诉人）；③接着做压缩前在做的事。'
    tail = [step, '详情（完整字段）：%s' % state_path()]
    room = MAX_LINES - len(head) - len(tail)
    if len(body) > room:
        body = body[:room - 1] + ['- …（更多见状态文件）']
    return '\n'.join(head + body + tail)


def refresh(d, transcript):
    """Back from an exit, a crash or a restart (issue #2585, EPIC #2581 C4): a killed
    process ran no SessionEnd, so the saved picture may predate the batch or the Loop.
    The two local halves are read again — the batch marks, and the Loop off the
    conversation being resumed (kept when it holds none); the children half (a hub
    read, seconds) stays as saved, and so does `ts` (stamped now when nothing was
    ever saved but a batch or a Loop is found)."""
    now = int(time.time())
    d['batches'] = batches(now)
    lp = loop_from_transcript(transcript, now)
    if lp:
        d['loop'] = lp
    if not d.get('ts'):
        if not d['batches'] and not lp:
            return                       # nothing was ever saved, nothing to say
        d.update(v=1, ts=now, reason='refresh', session=_session())
    try:
        store(d)
    except OSError:
        pass


def mark_read(d):
    if d and int(d.get('seq') or 0) > int(d.get('seen_seq') or 0):
        d['seen_seq'] = int(d['seq'])
        try:
            store(d)
        except OSError:
            pass


def kick_resume(p):
    """Start the turn a manual /compact leaves unstarted (fleet-compact-resume.sh)."""
    now = str(int(time.time()))
    tmux('set-window-option', '-t', p, '@compact_stage', 'restored')
    tmux('set-window-option', '-t', p, '@compact_restored_ts', now)
    try:
        subprocess.Popen(['bash', os.path.join(BIN, 'fleet-compact-resume.sh'), p],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def detach(*args):
    try:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), *args],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def hook():
    try:
        payload = json.loads(sys.stdin.read() or '{}')
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        return 0
    ev = payload.get('hook_event_name', '')
    if ev == 'UserPromptSubmit' and SENTINEL not in str(payload.get('prompt', '')):
        return 0                         # the common case: no tmux, no conf read
    p = pane()
    ok, stage = is_orchestrator(p)
    if not ok or switched_off():
        return 0
    tr = payload.get('transcript_path') or ''
    if ev == 'PreCompact':
        save(tr, 'precompact', payload.get('trigger') or 'auto', stage)
    elif ev == 'SessionEnd':
        save(tr, 'end')
    elif ev == 'UserPromptSubmit':
        detach('save', '--reason', 'report')
    elif ev == 'PostToolUse':
        d = load()
        d.update(v=1, ts=int(time.time()), reason='loop',
                 loop=loop_from_call(payload, int(time.time()), d))
        store(d)
    elif ev == 'SessionStart':
        src = payload.get('source', '')
        if src not in ('compact', 'resume', 'startup'):
            return 0
        d = load()
        if src in ('resume', 'startup'):
            refresh(d, tr)
        text = brief(d, src)
        if not text:
            return 0
        mark_read(d)
        print(json.dumps({'hookSpecificOutput': {'hookEventName': 'SessionStart',
                                                 'additionalContext': text}}, ensure_ascii=False))
        if (src == 'compact' and d.get('trigger') == 'manual' and not d.get('fleet_compaction')
                and now_ok(d)):
            kick_resume(p)
    return 0


def now_ok(d):
    """The PreCompact that wrote it is this compaction's (minutes, not hours, ago)."""
    return int(time.time()) - int(d.get('precompact_ts') or 0) <= 900


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('hook')
    s = sub.add_parser('save')
    s.add_argument('--transcript', default='')
    s.add_argument('--reason', default='save')
    s.add_argument('--trigger', default='')
    b = sub.add_parser('brief')
    b.add_argument('--source', default='compact')
    b.add_argument('--no-mark', action='store_true')
    sub.add_parser('path')
    a = ap.parse_args()
    if a.cmd == 'hook':
        try:
            return hook()
        except Exception:                # a hook never costs the session its turn
            return 0
    if a.cmd == 'path':
        print(state_path())
        return 0
    if a.cmd == 'save':
        save(a.transcript, a.reason, a.trigger)
        return 0
    d = load()
    text = brief(d, a.source)
    if not text:
        print('[fleet orchestrator state] 没有存下的状态（%s）——用 mcp__fleet__children 看子会话。' % state_path())
        return 0
    print(text)
    if not a.no_mark:
        mark_read(d)
    return 0


if __name__ == '__main__':
    sys.exit(main())
