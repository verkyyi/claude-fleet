#!/usr/bin/env python3
"""A session's reap policy — `@reap_policy`, chosen when it opens (issue #1902).

One window option says when the fleet may close a session on its own:

    merged[:<dur>]   after its work is over (+ the fleet's grace, or <dur>) — a
                     retained legacy policy. Over is
                     the hub task record CLOSED (收口: succeeded / failed /
                     cancelled) for a session that carries one (@task T<n> — a
                     development task with no issue, issue #4897; or an issue
                     worker's accepted task); else its PR merged and the issue
                     closed, the historic rule
    done[:<dur>]     its turn is over and it has sat idle <dur> (default 15m), no
                     /loop pending, no background job
    idle:<dur>       its turn is over and it has sat idle <dur> — whether or not
                     its work is; new ordinary sessions default to 2h. For a no-repo session
                     a finished turn counts (`done` there waits for the agent to exit)
    loop-end         the /loop it was opened with has stopped (then idle 10 min)
    at:<when>        at a moment (ISO-8601 UTC `2026-10-06T18:00:00Z`, or an
                     epoch), once its turn is over
    keep             never closed automatically

New tasks share idle:2h and the existing safe parking gate. Legacy origin
arguments remain readable but grant no role or PIN privileges. Explicit test
identities retain their probe policy. Existing stamped policies, including keep,
are preserved; a pin only changes list order.
No option at all = retain the legacy route for that session's kind. Every automatic close still goes
through the same gates: history recorded and resumable first, a dirty or
unpushed worktree kept on disk, a working window never closed.

CLI (the shell side's one parser — never a second copy):
    fleet_reap_policy.py norm <policy>     canonical form, exit 2 when invalid
    fleet_reap_policy.py default <issue|task|scratch|loop>
    fleet_reap_policy.py label <policy> [--lang zh|en] [--now N]
    fleet_reap_policy.py merged-grace <policy>   seconds, or `keep` / `other` / ``
    fleet_reap_policy.py idle-owned <policy> [--now N]   exit 0 when a finished
                                           session is the idle reaper's to close
    fleet_reap_policy.py origin [--agent-def N] [--origin K] [--origin-wid W]
                                [--test-identity 1] [--stamp O]   the origin word
    fleet_reap_policy.py origin-default <origin> [--kind issue|task|scratch|loop]
    fleet_reap_policy.py park-idle          seconds a web session idles before it parks
    fleet_reap_policy.py effective <policy> [--pin 1] [--agent-def N]
                                [--keep-by session] [--over 1]   the policy in force
"""
import re
import sys
import time
from datetime import datetime, timezone

DONE_DEFAULT = 15 * 60           # 发起人 2026-10-11 (issue #3352，取代拍板 7 的 2 小时): 草稿闲满 15 分钟
LOOP_END_GRACE = 600             # idle after the loop stopped
DUR_RE = re.compile(r"([1-9][0-9]{0,6})([smhd]?)")
UNIT = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
MAX_SECS = 366 * 86400


IDLE_DEFAULT = 2 * 3600          # 回收 B 拍板: 你自己开的会话闲置 2 小时收起

# Ordinary tasks share one default. Old origin words are normalized by origin_of;
# stored policy values are never rewritten. Probes require explicit provenance.
ORIGINS = {
    "person": dict(default="idle:2h", park="idle", reap="parked"),
    "probe": dict(default="done:1m", park="idle", reap="done"),
}
# Existing keep remains keep. C1's measured cache fallback
# keeps unattended parking at 5m unless explicitly configured to 1m.
PARK_IDLE_DEFAULT = 5 * 60
PARK_IDLE_MIN = 60

# The park gate owns eligibility; the reaper only carries its refusal to the
# same explanation line. In particular, a background PARK hold has no close
# countdown (`bg:<epoch>` is still readable for notices from older installs).
PARK_HOLDS = {"watched": "watched", "draft": "draft", "typing": "draft",
              "bg": "park-bg", "asking": "asking", "old_wrapper": "old-wrapper"}


def park_idle_secs():
    """Seconds a web session sits idle before it parks; 0 = never."""
    import os
    v = os.environ.get("FLEET_SESSION_PARK_IDLE", "").strip()
    if v == "0":
        return 0
    s = dur_secs(v) if v else None
    return max(PARK_IDLE_MIN, s) if s is not None else PARK_IDLE_DEFAULT


def park_idle_unattended_secs():
    """C1 cache probe lost part of the prefix: conservative 5m, 1m opt-in."""
    import os
    v = os.environ.get("FLEET_SESSION_PARK_IDLE_UNATTENDED", "").strip()
    if v == "0":
        return 0
    secs = dur_secs(v) if v else None
    return max(PARK_IDLE_MIN, secs) if secs is not None else PARK_IDLE_DEFAULT


def park_presence_secs():
    import os
    secs = dur_secs(os.environ.get("FLEET_SESSION_PARK_PRESENCE", "15m"))
    return secs if secs is not None else 900


def reap_parked_secs():
    import os
    value = os.environ.get("FLEET_SESSION_REAP_PARKED", "3d").strip()
    # Hub durations arrive as seconds, including the eight digits of 366d.
    seconds = int(value) if re.fullmatch(r"[0-9]{1,8}", value) else dur_secs(value)
    return seconds if seconds is not None and 3600 <= seconds <= MAX_SECS else 3 * 86400


def snapshot_origin(snap):
    return origin_of(snap.get("@agent_def", ""), snap.get("@origin") or snap.get("@origin_fid", ""),
                     snap.get("@origin_wid", ""), snap.get("@test_identity", ""),
                     "web" if snap.get("@session_origin") == "web" else snap.get("@reap_origin", ""))


def uses_park_retention(snap):
    row = ORIGINS[snapshot_origin(snap)]
    policy = snap.get("@reap_policy", "")
    return (snap.get("@park_waiting") == "1" or
            (row["reap"] == "parked" and policy in ("", row["default"], "keep")))


def parked_deadline(snap):
    """The shared C6 clock: only an acknowledged park, no wake in flight.
    An explicit keep has no automatic expiration; PIN changes list order only.
    Waiting reports use the same retention as a person's conversation.
    """
    if (not snap.get("@park_wrap_ver") or not snap.get("@parked") or not snap.get("@park_held")
            or snap.get("@reap_policy") == "keep"):
        return None
    if not uses_park_retention(snap):
        return None
    since = snap.get("@park_since", "")
    if not since.isdigit() or int(since) <= 0:
        return None
    # Activity recorded after a park resets retention, even if a wake failed.
    return max(int(since), *(int(snap.get(k) or 0) if str(snap.get(k) or "").isdigit() else 0
                            for k in ("@claude_state_ts", "@park_presence"))) + reap_parked_secs()


def park_after(snap, now=None):
    now = int(time.time()) if now is None else now
    presence = snap.get("@park_presence", "")
    recent = not presence.isdigit() or now - int(presence) < park_presence_secs()
    return park_idle_secs() if recent else park_idle_unattended_secs()


def explain(snap, now=None):
    """Doctor's read-only row; the reaper owns @reap_why for other holds."""
    now = int(time.time()) if now is None else now
    origin = snapshot_origin(snap)
    row = ORIGINS[origin]
    reap = row["reap"] if uses_park_retention(snap) or not snap.get("@reap_policy") else snap["@reap_policy"]
    prefix = "origin=%s park=%s reap=%s" % (origin, row["park"], reap)
    why = report_hold(snap.get("@fleet_id", ""), snap.get("@reap_report_pending", "")) or snap.get("@reap_why") or "pending-check"
    if why in ("report-pending", "report-unknown"):
        return prefix + " next=after-report-saved why=" + why
    if snap.get("@parked") and snap.get("@park_held"):
        due = parked_deadline(snap)
        if due is not None:
            return prefix + " next=reap@" + iso(due) + " why=" + why
        code, _, epoch = why.partition(":")
        if epoch.isdigit() and code in ("timer", "bg"):
            return prefix + " next=reap@" + iso(int(epoch)) + " why=" + why
        return prefix + " next=" + ("keep" if snap.get("@reap_policy") == "keep" else "result/policy") + " why=" + why
    if not snap.get("@park_wrap_ver"):
        return prefix + " next=legacy-policy (old wrapper) why=" + why
    if why in set(PARK_HOLDS.values()) | {"park-gate"}:
        return prefix + " next=park-held why=" + why
    stamp = snap.get("@claude_state_ts", "")
    from fleet_reap_notice import reap_state
    state = reap_state(snap.get("@claude_state", ""), snap.get("@agent_status", ""), snap.get("@claude_needs", ""))
    if state == "done" and stamp.isdigit():
        delay = park_after(snap, now)
        watched = snap.get("@park_watched_at", "")
        due = max(int(stamp), int(watched) if watched.isdigit() else 0) + delay
        return prefix + (" next=park@" + iso(due) if delay else " next=park-off") + " why=" + why
    return prefix + " next=after-turn why=" + why


# A probe by its words (BCYB): a session a person or a session opened to measure
# or try something — never work to keep. The same pattern as the hub's
# store.IsProbeTitle (its reconcile closes one as hub:probe).
PROBE_RE = re.compile(r"(可关|探针|空会话|放置演示|放置计时|\bprobe\b)", re.I)


def is_probe_title(title):
    return bool(PROBE_RE.search(title or ""))


def origin_of(agent_def="", origin="", origin_wid="", test_identity="", stamp="", title=""):
    """Compatibility inputs do not turn agent files or ancestry into privileges.

    Old stamps remain on disk; only explicit probe provenance affects defaults.
    """
    return "probe" if test_identity == "1" or stamp == "probe" else "person"


def origin_default(origin, kind=""):
    """Every ordinary new task, including loop seeds, shares safe idle/park."""
    return ORIGINS[origin_of(stamp=origin)]["default"]


def effective(policy, pin="", agent_def="", keep_by="", over=False):
    """Read the chosen policy unchanged; legacy arguments are inert."""
    return (policy or "").strip()


def dur_secs(text):
    """`90` · `30m` · `2h` · `3d` → seconds, or None."""
    m = DUR_RE.fullmatch(text or "")
    if not m:
        return None
    secs = int(m.group(1)) * UNIT[m.group(2)]
    return secs if 0 < secs <= MAX_SECS else None


def iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def at_epoch(text, now=None):
    """`at:` argument → epoch, or None. ISO-8601 with a Z / offset, an epoch, or
    a bare `HH:MM` — that time today here, tomorrow when it has passed."""
    text = (text or "").strip()
    if re.fullmatch(r"[1-9][0-9]{8,10}", text):
        return int(text)
    hm = re.fullmatch(r"([01]?[0-9]|2[0-3])[:：]([0-5][0-9])", text)
    if hm:
        now = int(time.time()) if now is None else now
        lt = time.localtime(now)
        e = int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, int(hm.group(1)), int(hm.group(2)), 0, 0, 0, -1)))
        return e if e > now else e + 86400
    t = text.replace("z", "Z")
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M%z"):
        try:
            return int(datetime.strptime(t, fmt).timestamp())
        except ValueError:
            pass
    return None


def parse(policy):
    """(kind, seconds-or-epoch) or None. kind: merged · done · idle · loop-end · at · keep."""
    p = (policy or "").strip()
    head, _, arg = p.partition(":")
    if head in ("keep", "loop-end") and not arg and ":" not in p:
        return head, 0
    if head == "merged":
        if ":" not in p:
            return "merged", 0
        s = dur_secs(arg)
        return ("merged", s) if s is not None else None
    if head == "done":
        if ":" not in p:
            return "done", DONE_DEFAULT
        s = dur_secs(arg)
        return ("done", s) if s is not None else None
    if head == "idle":
        if ":" not in p:
            return "idle", IDLE_DEFAULT
        s = dur_secs(arg)
        return ("idle", s) if s is not None else None
    if head == "at":
        e = at_epoch(arg)
        return ("at", e) if e is not None else None
    return None


def norm(policy):
    """The canonical spelling, or None. done/merged keep their typed duration."""
    got = parse(policy)
    if got is None:
        return None
    kind, val = got
    p = (policy or "").strip()
    if kind == "at":
        return "at:" + iso(val)
    if kind == "done" and ":" not in p:
        return "done:15m"
    if kind == "idle" and ":" not in p:
        return "idle:2h"
    return p


def default(kind):
    """Legacy CLI values; spawners use origin_default for all new sessions."""
    return {"issue": "merged", "task": "merged", "scratch": "done:15m", "loop": "loop-end"}.get(kind, "")


def _dur_words(secs, zh):
    for unit, n, z, e in (("d", 86400, "天", "d"), ("h", 3600, "小时", "h"), ("m", 60, "分钟", "m")):
        if secs % n == 0:
            return "%d %s" % (secs // n, z) if zh else "%d%s" % (secs // n, e)
    return "%d 秒" % secs if zh else "%ds" % secs


def label(policy, lang="zh", now=None):
    """What the sidebar row says — the prototype's words."""
    got = parse(policy)
    if got is None:
        return ""
    zh = lang != "en"
    kind, val = got
    if kind == "merged":
        if not val:
            return "合并后回收" if zh else "after merge"
        return ("合并后留 " + _dur_words(val, True)) if zh else ("merge+" + _dur_words(val, False))
    if kind == "done":
        if val == DONE_DEFAULT:
            return "做完就回收" if zh else "when done"
        return ("做完闲 " + _dur_words(val, True)) if zh else ("done+" + _dur_words(val, False))
    if kind == "idle":
        return ("闲 " + _dur_words(val, True) + "收起") if zh else ("idle " + _dur_words(val, False))
    if kind == "loop-end":
        return "循环停了回收" if zh else "after loop"
    if kind == "keep":
        return "常驻" if zh else "keep"
    now = int(time.time()) if now is None else now
    lt = time.localtime(val)
    same_day = time.localtime(now)[:3] == lt[:3]
    hm = time.strftime("%H:%M", lt)
    if zh:
        return ("到点 " + hm) if same_day else ("到点 " + time.strftime("%m-%d ", lt) + hm)
    return ("at " + hm) if same_day else ("at " + time.strftime("%m-%d ", lt) + hm)


def merged_grace(policy):
    """For the merged-PR janitor: seconds of grace for `merged:<dur>`, `` for the
    fleet's own grace (plain `merged` or no policy), `keep`, or `other` (a policy
    the idle pass owns — never the merged rule)."""
    if not (policy or "").strip():
        return ""
    got = parse(policy)
    if got is None:
        return ""          # garbled: fall back to the historic rule
    kind, val = got
    if kind == "merged":
        return str(val) if val else ""
    return "keep" if kind == "keep" else "other"


def idle_owned(policy, now=None):
    """Is a FINISHED session with this policy waiting on the idle reaper (issue
    #4764)? done / loop-end, or an `at:` already reached. The idle reopen
    (fleet_cfg_restart_why) leaves such a window alone: a reopen restarts its
    idle clock, so `done:<dur>` would never come due."""
    got = parse(policy)
    if got is None:
        return False
    kind, val = got
    if kind in ("done", "idle", "loop-end"):
        return True
    if kind == "at":
        return val <= (int(time.time()) if now is None else now)
    return False


def report_path(fid):
    """Read-only path; policy parsing/doctor need no node runtime imports."""
    import os
    from pathlib import Path
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", fid or ""):
        return None
    conf = Path(os.environ.get("FLEET_CONF_DIR") or Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "claude-fleet")
    return Path(os.environ.get("FLEET_GATE_DIR") or conf / "session-gate") / fid / "report.json"


def report_proof(fid):
    """Local completion evidence, beside the existing identity gate's receipts.

    A missing record is a legacy session. Unreadable evidence always holds it.
    This is not a parked state, nor a second delivery queue.
    """
    import json
    path = report_path(fid)
    if path is None:
        return {}
    try:
        rec = json.loads(path.read_text())
        if not isinstance(rec, dict):
            return {"phase": "unknown"}
        if rec.get("phase") == "complete" and (
                report_path(str(rec.get("token", ""))) is None
                or not isinstance(rec.get("result_seq"), int) or rec["result_seq"] < 1):
            return {"phase": "unknown"}
        return rec
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return {"phase": "unknown"}


def report_hold(fid, pending=""):
    phase = report_proof(fid).get("phase", "")
    if pending or phase == "pending":
        return "report-pending"
    return "report-unknown" if phase not in ("", "complete", "superseded") else ""


def current_work(fid):
    """Local input generation; absent means a session from before this contract."""
    import json
    path = report_path(fid)
    if path is None:
        return {}
    try:
        work = json.loads(path.with_name("work.json").read_text())
        if not isinstance(work, dict) or not isinstance(work.get("after_seq"), int) or not work.get("token"):
            return {"unknown": True}
        return work
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return {"unknown": True}


def completion_hold(fid, task="", rec=None):
    """Old task closure/result cannot authorize the current turn's teardown.

    This only invalidates completion; idle/park retention remains its own rule.
    Compare ledger sequence numbers, never wall clocks or window names.
    """
    if report_hold(fid):
        return "report-pending"
    if report_path(fid) is None:
        return ""
    import fleet_id
    rec = rec if rec is not None else fleet_id.fold(fleet_id.read(fid))
    result = fleet_id.last_result(rec) or {}
    if rec.get("attempt", 1) > 1 and not result:
        return "new-attempt"
    work = current_work(fid)
    if work.get("unknown"):
        return "work-unknown"
    if work and result.get("seq", 0) <= work["after_seq"]:
        return "new-work"
    bound = result.get("task") or (report_proof(fid).get("task") if result else "") or rec.get("opened", {}).get("task")
    if task and bound and task != bound:
        return "task-changed"
    return ""


def work_changed_locked(fid, task=""):
    """Caller holds the existing identity gate, before handing new words over."""
    import uuid
    import fleet_id
    from fleet_session_gate import fid_dir, write_json
    events = fleet_id.read(fid)
    work = dict(token=str(uuid.uuid4()), task=task, at=int(time.time()),
                after_seq=max((e.get("seq", 0) for e in events), default=0),
                attempt=fleet_id.fold(events)["attempt"])
    write_json(fid_dir(fid) / "work.json", work)
    proof = report_proof(fid)
    if proof.get("phase") == "pending":
        proof["phase"] = "superseded"
        write_report_proof(fid, proof)
    return work


def write_report_proof(fid, proof):
    import os
    from fleet_session_gate import fid_dir, write_json
    folder = fid_dir(fid)
    write_json(folder / "report.json", proof)
    fd = os.open(str(folder), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def report_begin(fid, task):
    import uuid
    from fleet_session_gate import lock
    token = str(uuid.uuid4())
    with lock(fid):
        import fleet_id
        write_report_proof(fid, dict(phase="pending", token=token, task=task, at=time.time(),
                                    work=current_work(fid).get("token", ""),
                                    attempt=fleet_id.fold(fleet_id.read(fid))["attempt"]))
    return token


def report_finish(fid, token, state, summary, agent, pr):
    """Publish completion only after the caller saved the required report.

    rc 3 (durably queued) is as reliable as rc 0. A failed write leaves the
    pending proof intact, including when an older result or task was terminal.
    """
    from fleet_session_gate import lock, window
    import fleet_id
    with lock(fid):
        proof = report_proof(fid)
        if proof.get("phase") != "pending" or proof.get("token") != token:
            return False
        w = window(fid)
        if (proof.get("work", "") != current_work(fid).get("token", "")
                or proof.get("attempt") != fleet_id.fold(fleet_id.read(fid))["attempt"]
                or (w and w.get("task", "") != proof.get("task", ""))):
            proof["phase"] = "superseded"
            write_report_proof(fid, proof)
            return False
        ev = dict(ev="result", state=state, summary=summary, agent=agent, task=proof.get("task", ""))
        if pr:
            ev["pr"] = pr
        got = fleet_id.append(fid, ev)
        proof.update(phase="complete", result_seq=got["seq"])
        write_report_proof(fid, proof)
    fleet_id.push_later(fid)
    return True


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "work-token" and len(args) == 1:
        work = current_work(args[0])
        print(work.get("token", "unknown" if work.get("unknown") else ""))
        return 0
    if cmd in ("report-begin", "report-finish", "report-ready", "completion-ready"):
        if not args or report_path(args[0]) is None:
            return 2
        try:
            if cmd == "report-begin" and len(args) == 2:
                print(report_begin(*args))
                return 0
            if cmd == "report-finish" and len(args) == 6:
                return 0 if report_finish(*args) else 1
            if cmd == "report-ready":
                return 1 if report_hold(args[0]) else 0
            if cmd == "completion-ready":
                return 1 if completion_hold(args[0], args[1] if len(args) > 1 else "") else 0
        except (OSError, ValueError):
            return 1
        return 2
    if cmd == "norm":
        out = norm(args[0] if args else "")
        if out is None:
            sys.stderr.write("reap policy must be merged[:<dur>] | done[:<dur>] | idle[:<dur>] | loop-end | "
                             "at:<ISO time> | keep (dur: 90, 30m, 2h, 3d)\n")
            return 2
        print(out)
        return 0
    if cmd == "default":
        out = default(args[0] if args else "")
        if not out:
            return 2
        print(out)
        return 0
    if cmd == "label":
        lang, now = "zh", None
        if "--lang" in args:
            lang = args[args.index("--lang") + 1]
        if "--now" in args:
            now = int(args[args.index("--now") + 1])
        out = label(args[0] if args else "", lang, now)
        if out:
            print(out)
        return 0 if out else 1
    if cmd == "park-idle":
        print(park_idle_secs())
        return 0
    if cmd == "idle-owned":
        now = int(args[args.index("--now") + 1]) if "--now" in args else None
        return 0 if idle_owned(args[0] if args else "", now) else 1
    if cmd in ("origin", "origin-default", "effective"):
        kv, pos, i = {}, [], 0
        while i < len(args):
            if args[i].startswith("--") and i + 1 < len(args):
                kv[args[i][2:]] = args[i + 1]
                i += 2
            else:
                pos.append(args[i])
                i += 1
        if cmd == "origin":
            print(origin_of(kv.get("agent-def", ""), kv.get("origin", ""), kv.get("origin-wid", ""),
                            kv.get("test-identity", ""), kv.get("stamp", ""), kv.get("title", "")))
            return 0
        if cmd == "origin-default":
            out = origin_default(pos[0] if pos else "", kv.get("kind", ""))
            if not out:
                return 2
            print(out)
            return 0
        print(effective(pos[0] if pos else "", kv.get("pin", ""), kv.get("agent-def", ""),
                        kv.get("keep-by", ""), kv.get("over", "") == "1"))
        return 0
    if cmd == "merged-grace":
        print(merged_grace(args[0] if args else ""))
        return 0
    sys.stderr.write("unknown command %s\n" % cmd)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
