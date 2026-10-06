#!/usr/bin/env python3
"""A session's reap policy — `@reap_policy`, chosen when it opens (issue #1902).

One window option says when the fleet may close a session on its own:

    merged[:<dur>]   after its PR merged (+ the fleet's grace, or <dur>) — the
                     default for an issue session; the historic rule
    done[:<dur>]     its turn is over and it has sat idle <dur> (default 2h), no
                     /loop pending, no background job — a scratch's default
    loop-end         the /loop it was opened with has stopped (then idle 10 min)
    at:<when>        at a moment (ISO-8601 UTC `2026-10-06T18:00:00Z`, or an
                     epoch), once its turn is over
    keep             never closed automatically (it may still sleep)

No option at all = the session's kind decides, exactly as before #1902 (an old
window behaves byte for byte as it did). Every automatic close still goes
through the same gates: history recorded and resumable first, a dirty or
unpushed worktree kept on disk, a working window never closed.

CLI (the shell side's one parser — never a second copy):
    fleet_reap_policy.py norm <policy>     canonical form, exit 2 when invalid
    fleet_reap_policy.py default <issue|scratch|loop>
    fleet_reap_policy.py label <policy> [--lang zh|en] [--now N]
    fleet_reap_policy.py merged-grace <policy>   seconds, or `keep` / `other` / ``
"""
import re
import sys
import time
from datetime import datetime, timezone

DONE_DEFAULT = 2 * 3600          # 发起人拍板 7: 草稿闲满 2 小时
LOOP_END_GRACE = 600             # idle after the loop stopped
DUR_RE = re.compile(r"([1-9][0-9]{0,6})([smhd]?)")
UNIT = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
MAX_SECS = 366 * 86400


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
    """(kind, seconds-or-epoch) or None. kind: merged · done · loop-end · at · keep."""
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
        return "done:2h"
    return p


def default(kind):
    return {"issue": "merged", "scratch": "done:2h", "loop": "loop-end"}.get(kind, "")


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


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "norm":
        out = norm(args[0] if args else "")
        if out is None:
            sys.stderr.write("reap policy must be merged[:<dur>] | done[:<dur>] | loop-end | "
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
    if cmd == "merged-grace":
        print(merged_grace(args[0] if args else ""))
        return 0
    sys.stderr.write("unknown command %s\n" % cmd)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
