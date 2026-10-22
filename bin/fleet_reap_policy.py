#!/usr/bin/env python3
"""A session's reap policy — `@reap_policy`, chosen when it opens (issue #1902).

One window option says when the fleet may close a session on its own:

    merged[:<dur>]   after its work is over (+ the fleet's grace, or <dur>) — the
                     default for an issue session and a task session. Over is
                     the hub task record CLOSED (收口: succeeded / failed /
                     cancelled) for a session that carries one (@task T<n> — a
                     development task with no issue, issue #4897; or an issue
                     worker's accepted task); else its PR merged and the issue
                     closed, the historic rule
    done[:<dur>]     its turn is over and it has sat idle <dur> (default 15m), no
                     /loop pending, no background job — a scratch's default
    idle:<dur>       its turn is over and it has sat idle <dur> — whether or not
                     its work is (T694, 回收 B): a person's own session (2h), one
                     waiting for a person's decision (15m). For a no-repo session
                     a finished turn counts (`done` there waits for the agent to exit)
    loop-end         the /loop it was opened with has stopped (then idle 10 min)
    at:<when>        at a moment (ISO-8601 UTC `2026-10-06T18:00:00Z`, or an
                     epoch), once its turn is over
    keep             never closed automatically

Where it came from decides the default (T694, 回收 B) — ONE table, ORIGINS
below, read by every spawner (`origin` + `origin-default`) and by the reapers
(`effective`): person (⌘N / ⌘P, a person's shell) · dispatched (an orchestrator's
or any session's task) · member (a batch member) · driver (an EPIC driver) ·
orchestrator · decide (a session waiting on a person's call) · probe (a test
identity, a scheduled job, a drill). The spawner stamps `@reap_origin` beside
`@reap_policy`; a window with none has its origin read off its stamps
(origin_of). A pinned window and an orchestrator are never closed
automatically; a `keep` the session set for itself (`@reap_keep_by session`)
lapses once its work is over — only a person's `keep` holds.

No option at all = the session's kind decides, exactly as before #1902 (an old
window behaves byte for byte as it did). Every automatic close still goes
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

# Where a session came from → when it may be closed (T694, 回收 B 拍板). The ONE
# table: a spawner stamps it, the reapers read it. `merged` here is «its work is
# over» — the record closed, or its ID carries a final result (T680) — then the
# fleet's grace (≈1 minute); a driver goes at once.
ORIGINS = {
    # `default` is also the compatibility policy stamped by old spawners.
    # `reap` governs new park-capable wrappers; every origin parks by C1 tiers.
    "person":       dict(default="idle:2h", park="idle", reap="parked"),
    "dispatched":   dict(default="merged", park="idle", reap="reported"),
    "member":       dict(default="merged", park="idle", reap="reported"),
    "driver":       dict(default="merged", park="idle", reap="batch"),
    "orchestrator": dict(default="keep", park="idle", reap="never"),
    "decide":       dict(default="idle:15m", park="idle", reap="idle"),
    "probe":        dict(default="done:1m", park="idle", reap="done"),
    "web":          dict(default="keep", park="idle", reap="never"),
}
# Web lifecycle follows HHV0; keep remains keep. C1's measured cache fallback
# keeps unattended parking at 5m unless explicitly configured to 1m.
PARK_IDLE_DEFAULT = 5 * 60
PARK_IDLE_MIN = 60

# The park gate owns eligibility; the reaper only carries its refusal to the
# same explanation line. In particular, a background PARK hold has no close
# countdown (the existing `bg:<epoch>` is a different, completed-work policy).
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
    A person's keep/pin and permanent origins have no automatic expiration.
    Waiting reports use the same retention as a person's conversation.
    """
    row = ORIGINS[snapshot_origin(snap)]
    if (not snap.get("@park_wrap_ver") or not snap.get("@parked") or not snap.get("@park_held")
            or row["reap"] == "never" or snap.get("@pin") == "1"
            or (snap.get("@reap_policy") == "keep" and snap.get("@reap_keep_by") != "session")):
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
    why = snap.get("@reap_why") or "pending-check"
    if snap.get("@parked") and snap.get("@park_held"):
        due = parked_deadline(snap)
        if due is not None:
            return prefix + " next=reap@" + iso(due) + " why=" + why
        code, _, epoch = why.partition(":")
        if epoch.isdigit() and code in ("timer", "unreported", "bg"):
            return prefix + " next=" + ("remind@" if code == "unreported" else "reap@") + iso(int(epoch)) + " why=" + why
        return prefix + " next=" + ("keep" if row["reap"] == "never" or snap.get("@reap_policy") == "keep"
                                    or snap.get("@pin") == "1" else "result/policy") + " why=" + why
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


# The origins whose «done» is a reported result — the dispatched road
# (fleet-cleanup-idle.py dispatched_session): over ⇒ closed, unreported ⇒ nudged.
REPORTING = tuple(origin for origin, row in ORIGINS.items() if row["reap"] in ("reported", "batch"))


# A probe by its words (BCYB): a session a person or a session opened to measure
# or try something — never work to keep. The same pattern as the hub's
# store.IsProbeTitle (its reconcile closes one as hub:probe).
PROBE_RE = re.compile(r"(可关|探针|空会话|放置演示|放置计时|\bprobe\b)", re.I)


def is_probe_title(title):
    return bool(PROBE_RE.search(title or ""))


def origin_of(agent_def="", origin="", origin_wid="", test_identity="", stamp="", title=""):
    """The origin word: the stamped `@reap_origin` when it is one, else read off
    the window — its agent file (orchestrator · epic-driver), a test identity, a
    parent session (@origin other than the hub, @origin_fid, @origin_wid), else a
    person's own."""
    if stamp in ORIGINS:
        return stamp
    name = (agent_def or "").rsplit(":", 1)[-1]
    if name == "orchestrator":
        return "orchestrator"
    if name == "epic-driver":
        return "driver"
    if test_identity == "1" or is_probe_title(title):
        return "probe"
    if (origin and origin != "hub") or origin_wid:
        return "dispatched"
    return "person"


def origin_default(origin, kind=""):
    """The policy a session of <origin> opens with. An issue session dispatched
    keeps its historic `merged`; a /loop seed its `loop-end` unless a driver."""
    if kind == "loop" and origin not in ("driver", "orchestrator", "probe"):
        return "loop-end"
    if kind == "issue" and origin in ("person", "dispatched", "member"):
        return "merged"            # an issue session's historic rule: its PR merged
    return ORIGINS.get(origin, {}).get("default", "")


def effective(policy, pin="", agent_def="", keep_by="", over=False):
    """The policy in force: a pin or an orchestrator is `keep`, whatever is
    stamped; a `keep` the session set for itself lapses to `merged` once its work
    is over (only a person's keep holds)."""
    if pin == "1" or (agent_def or "").rsplit(":", 1)[-1] == "orchestrator":
        return "keep"
    p = (policy or "").strip()
    if p == "keep" and keep_by == "session" and over:
        return "merged"
    return p


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


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
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
