#!/usr/bin/env python3
"""Sessions that should have been reaped but were not (issue #3352).

A session's reap policy (@reap_policy, bin/fleet_reap_policy.py) says when the
fleet may close it; the cleanup daemon is what closes it. When the daemon does
not — its idle pass timing out ahead of the merged-PR pass, a refusal nobody
reads — the window just stays, and nobody knows. This is the one reader that
says so: every window of this login's fleets past its policy, by how long, and
why it is still there (the idle pass's last `@reap_skip` token, else the
cleanup daemon's last word about it).

    fleet-reap-overdue.py [--json] [--stuck-secs N] [--now EPOCH]

Due, per policy (the same rules the reapers apply):
  merged[:<dur>] / an issue window with none — its PR MERGED (the prmap cache)
                   + the fleet's grace (FLEET_CLEANUP_MERGED_GRACE, 600 s) or
                   <dur>, counted from the landing the history ledger recorded
  done[:<dur>]     its turn over (done / exited) + <dur> (default 15 min)
  at:<when>        that moment, its turn over
  keep · loop-end · a working window — never overdue here.

Text: one summary line `overdue N · stuck M (> 30 min)`, then one line per
window. --json: {"overdue": N, "stuck": M, "stuck_secs": S, "rows": [...]}.
Exit 0 always — a reader, never a gate; no fleet ⇒ `overdue 0 · stuck 0`
(`--if-fleet`: nothing at all — the doctor's row).
"""
import argparse
import calendar
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_reap_policy  # noqa: E402

FIELDS = ("window_id", "@issue", "@repo", "@reap_policy", "@claude_state", "@claude_state_ts",
          "@reap_skip", "@raw", "@norepo", "@fleet_role", "@cc_agent", "@worktree", "window_name")
FINISHED = ("done", "exited")


def sh(script, *args):
    try:
        return subprocess.run(["bash", "-c", script, "overdue", str(BIN), *args], text=True,
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def fleets():
    """[(socket/session, its first repo)], plus the dash cache dir."""
    out = sh('. "$1/fleet-lib.sh" >/dev/null 2>&1; printf "C\\t%s\\n" "$FLEET_C"\n'
             'for s in $(fleet_sockets); do printf "S\\t%s\\t%s\\n" "$s" "$(fleet_repos "$s" | head -1)"; done')
    cache, found = "", []
    for line in out.splitlines():
        parts = line.split("\t")
        if parts[0] == "C" and len(parts) > 1:
            cache = parts[1]
        elif parts[0] == "S" and len(parts) > 2 and parts[1]:
            found.append((parts[1], parts[2]))
    return cache, found


def windows(sock):
    fmt = "|".join("#{%s}" % f for f in FIELDS)
    try:
        out = subprocess.run(["tmux", "-L", sock, "list-windows", "-t", sock, "-F", fmt], text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    rows = []
    for line in out.splitlines():
        vals = line.split("|", len(FIELDS) - 1)
        if len(vals) == len(FIELDS):
            rows.append(dict(zip(FIELDS, vals)))
    return rows


def slug(repo):
    return re.sub(r"[^A-Za-z0-9._-]", "", repo.replace("/", "-"))


def merged_prs(cache, repo):
    """branch → PR number for the repo's MERGED rows (the prmap pr-refresh writes)."""
    got = {}
    try:
        text = (Path(cache) / "fleets" / slug(repo) / "prmap").read_text()
    except OSError:
        return got
    for line in text.splitlines():
        cols = line.split("\t")
        if len(cols) > 2 and cols[2] == "MERGED":
            got[cols[0]] = cols[1].lstrip("#")
    return got


def landed_at(repo):
    """issue → the epoch its landing was recorded (logs/landed_<slug>.tsv)."""
    got = {}
    try:
        text = (BIN.parent / "logs" / ("landed_%s.tsv" % slug(repo))).read_text()
    except OSError:
        return got
    for line in text.splitlines():
        cols = line.split("\t")
        if len(cols) > 1 and cols[1].isdigit():
            try:
                t = calendar.timegm(time.strptime(cols[0], "%Y-%m-%dT%H:%M:%SZ"))
            except ValueError:
                continue
            got.setdefault(cols[1], t)
    return got


_LOG = {}


def daemon_word(key):
    """The cleanup daemon's last line naming this key, and its last line at all."""
    cache = _LOG
    if "lines" not in cache:
        try:
            with open(BIN.parent / "logs" / "cleanup.launchd.log", "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 400000))
                cache["lines"] = f.read().decode("utf-8", "replace").splitlines()
        except OSError:
            cache["lines"] = []
    lines = cache["lines"]
    mine = next((ln for ln in reversed(lines) if key and re.search(r"\b%s\b" % re.escape(key), ln)), "")
    return mine, (lines[-1] if lines else "")


def grace():
    v = os.environ.get("FLEET_CLEANUP_MERGED_GRACE", "600")
    return int(v) if re.fullmatch(r"\d{1,8}", v) else 600


def due_of(w, repo, prs, landed, now):
    """(due epoch, what) or None — when this window's policy let it go."""
    if w["@norepo"] == "1" or w["@fleet_role"] in ("home", "panel") \
            or w["window_name"] in ("dash", "plan", "backlog", "home"):
        return None
    pol = fleet_reap_policy.parse(w["@reap_policy"]) if w["@reap_policy"] else None
    kind = pol[0] if pol else ("merged" if w["@issue"] else None)
    stamp = int(w["@claude_state_ts"]) if w["@claude_state_ts"].isdigit() else 0
    finished = w["@claude_state"] in FINISHED
    if kind == "merged" and w["@issue"]:
        pr = prs.get("issue-" + w["@issue"])
        if not pr or w["@claude_state"] in ("working", "needs"):
            return None
        at = landed.get(w["@issue"])
        if at is None:
            return None
        return at + (pol[1] if pol and pol[1] else grace()), "PR #%s merged" % pr
    if kind == "done" and finished and stamp:
        return stamp + pol[1], "done " + fleet_reap_policy.label(w["@reap_policy"], "en")
    if kind == "at" and finished:
        return pol[1], "at"
    return None


def collect(now, stuck_secs, found=None):
    cache, found = fleets() if found is None else found
    rows = []
    for sock, first_repo in found:
        for w in windows(sock):
            repo = w["@repo"] or first_repo
            if not repo:
                continue
            prs, landed = merged_prs(cache, repo), landed_at(repo)
            got = due_of(w, repo, prs, landed, now)
            if got is None or got[0] > now:
                continue
            due, what = got
            m = re.search(r"(?:^|-)((?:scratch|issue)-\d+)$", Path(w["@worktree"]).name) if w["@worktree"] else None
            key = m[1] if m else ("issue-" + w["@issue"] if w["@issue"] else "")
            mine, last = daemon_word(key)
            said = mine.split(": ", 2)[-1] if mine else ""
            tick = ("cleanup daemon: " + last.split(": ", 2)[-1]) if "deferred" in last else ""
            if what.startswith("PR "):
                # The merged-PR pass owns it: its word, else why the tick stopped;
                # the idle pass's token is about another road.
                said = said if "PR #" in said else ""
                reason = said or tick or w["@reap_skip"]
            else:
                reason = w["@reap_skip"] or said or tick
            rows.append({"session": sock, "window": w["window_id"], "key": key, "repo": repo,
                         "agent": w["@cc_agent"] or "claude", "policy": w["@reap_policy"] or "merged",
                         "due": due, "over": now - due, "why_due": what,
                         "stuck": now - due > stuck_secs, "reason": reason or "not looked at yet"})
    rows.sort(key=lambda r: -r["over"])
    return rows


def ago(secs):
    return "%dh%02dm" % (secs // 3600, secs % 3600 // 60) if secs >= 3600 else "%dm" % (secs // 60)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--stuck-secs", type=int, default=1800)
    ap.add_argument("--now", type=int, default=0)
    ap.add_argument("--if-fleet", action="store_true", help="print nothing on a computer that runs no fleet")
    a = ap.parse_args()
    now = a.now or int(time.time())
    found = fleets()
    if a.if_fleet and not found[1]:
        return 0
    rows = collect(now, a.stuck_secs, found)
    stuck = sum(1 for r in rows if r["stuck"])
    if a.json:
        print(json.dumps({"overdue": len(rows), "stuck": stuck, "stuck_secs": a.stuck_secs, "rows": rows},
                         ensure_ascii=False))
        return 0
    print("overdue %d · stuck %d (> %d min)" % (len(rows), stuck, a.stuck_secs // 60))
    for r in rows:
        print("%s %s %s %s · %s · over %s%s · %s" % (
            r["session"], r["window"], r["key"] or "-", r["agent"], r["why_due"], ago(r["over"]),
            " STUCK" if r["stuck"] else "", r["reason"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
