#!/usr/bin/env python3
"""Reclaim idle raw windows only after recording and verifying a resumable history."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

from fleet_reap_notice import clear, notice, option, tmux
import fleet_reap_policy


def retired_dir():
    """fleet_retired_dir (fleet-lib.sh, issue #1840): the fleet's own closes."""
    seam = os.environ.get("FLEET_PULLBACK_RETIRED_DIR")
    if seam:
        return Path(seam)
    conf = os.environ.get("FLEET_CONF_DIR") or str(Path.home() / ".config/claude-fleet")
    return Path(conf) / "global" / "retired"

BIN = Path(__file__).absolute().parent


class RateLimited(Exception):
    pass


def run(*args, cwd=None):
    try:
        return subprocess.check_output(args, cwd=cwd, text=True,
                                       stderr=subprocess.PIPE, timeout=15).strip()
    except subprocess.CalledProcessError as exc:
        if args[0] == "gh" and re.search(r"rate.?limit|HTTP 429", exc.stderr, re.I):
            raise RateLimited("GitHub rate limit; stopping this tick") from exc
        raise


def minutes():
    value = os.environ.get("FLEET_REAP_IDLE_DONE_MIN", "30")
    return int(value) if re.fullmatch(r"\d{1,6}", value) else 30


def norm_repo(value):
    """owner/name from a remote URL or owner/name (fleet_norm_repo's rules)."""
    value = re.sub(r"^git@[^:]*:", "", value or "")
    value = re.sub(r"^https?://[^/]*/", "", value)
    return re.sub(r"/+$", "", re.sub(r"\.git$", "", value))


class Cleaner:
    def __init__(self, args):
        self.args = args
        self.tm = tmux(args.socket_name)
        self.now = int(time.time())
        self.idle = minutes() * 60

    def retire(self, window):
        """An idle reap is the fleet's close, never a kill to pull back (#1840)."""
        try:
            fid = option(self.tm, window, "@fleet_id")
            if re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", fid or ""):
                d = retired_dir()
                d.mkdir(parents=True, exist_ok=True)
                (d / fid).touch()
        except (OSError, subprocess.SubprocessError):
            pass

    def snapshot(self, window):
        names = ("@raw", "@issue", "@repo", "@norepo", "@worktree", "@claude_state", "@claude_state_ts",
                 "@pin", "@cc_agent", "@cc_launcher_pid", "@codex_identity",
                 "@handoff_manifest", "@agent_transfer_until", "window_name",
                 "@reap_policy", "@loop", "@worker_lifecycle")
        return {n: option(self.tm, window, n) for n in names}

    def policy(self, snap):
        """(kind, value) of the window's own @reap_policy (issue #1902), or None
        for a window with none — the historic rule, byte for byte."""
        return fleet_reap_policy.parse(snap["@reap_policy"]) if snap["@reap_policy"] else None

    def busy(self, window, snap):
        """A /loop still pending, or the agent still owning a background job:
        its turn is over but its work is not (fleet-control-read.sh workers_busy)."""
        if snap["@loop"]:
            args = ["python3", str(BIN / "fleet_loop_mark.py"), "status", "--value", snap["@loop"]]
            if snap["@handoff_manifest"]:
                args += ["--manifest", snap["@handoff_manifest"]]
            if subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15).returncode == 0:
                return True
        held = run("bash", "-c", '. "$1/fleet-lib.sh"; if fleet_window_bg_busy "$2" "$3" 1; then echo bg; fi',
                   "idle-reap", str(BIN), self.args.session, window)
        return bool(held)

    def deadline(self, snap, pol):
        """When this window's own policy lets it go (issue #1902)."""
        kind, val = pol
        stamp = int(snap["@claude_state_ts"])
        if kind == "done":
            return stamp + val
        if kind == "loop-end":
            return stamp + fleet_reap_policy.LOOP_END_GRACE
        return val  # at

    def eligible(self, window, snap):
        pol = self.policy(snap)
        if pol is not None:
            # An explicit policy decides which windows this pass may close: done /
            # loop-end / at, an issue session as well as a scratch. keep and merged
            # are never this pass's (merged is fleet-cleanup.sh's). Every gate
            # below still applies.
            if (pol[0] not in ("done", "loop-end", "at") or snap["@pin"] == "1"
                    or snap["@worker_lifecycle"] not in ("", "sleeping")):
                return False
        elif self.args.policy_only:
            return False
        elif snap["@raw"] != "1" or snap["@issue"]:
            return False
        if (snap["@pin"] == "1"
                # An exited session on its recovery page (issue #1784) is as idle
                # as a finished turn: the same grace, the same resumable record.
                or snap["@claude_state"] not in ("done", "exited")
                or snap["window_name"] in ("dash", "plan", "backlog", "home")):
            return False
        # A no-repo session is never closed automatically (issue #791), and in a
        # multi-repo fleet (--window-repo) a pass only closes its OWN repo's windows.
        if snap["@norepo"] == "1":
            return False
        if self.args.window_repo and norm_repo(snap["@repo"]) != norm_repo(self.args.repo):
            return False
        # An issue session with a policy: only this repo's (a one-repo fleet's
        # issue windows carry no @repo, the conf's repo is theirs).
        if pol is not None and snap["@repo"] and norm_repo(snap["@repo"]) != norm_repo(self.args.repo):
            return False
        stamp = snap["@claude_state_ts"]
        if not stamp.isdigit() or not 0 < int(stamp) <= self.now:
            return False
        transfer = snap["@agent_transfer_until"]
        if transfer and (not transfer.isdigit() or int(transfer) > self.now):
            return False
        manifest = snap["@handoff_manifest"]
        if manifest:
            loop = Path(manifest).parent / "loop/state.json"
            if loop.exists() and json.loads(loop.read_text()).get("status") not in ("stopped", "complete", "cancelled"):
                return False
        wt = snap["@worktree"]
        if not wt or Path(wt).resolve() == Path(self.args.main).resolve():
            return False
        if Path.cwd() == Path(wt).resolve() or Path(wt).resolve() in Path.cwd().parents:
            return False
        if os.environ.get("TMUX_PANE") and os.environ.get("TMUX"):
            if self.tm("display-message", "-p", "-t", os.environ["TMUX_PANE"], "#{window_id}") == window:
                return False
        # Require an actual linked checkout registered to this repo, not a cwd
        # guess or a path from another fleet. Keep all of its bytes on disposal.
        records = run("git", "-C", self.args.main, "worktree", "list", "--porcelain").split("\n\n")
        if not any("worktree " + wt in record.splitlines() for record in records):
            return False
        if run("git", "-C", wt, "status", "--porcelain"):
            return False
        # Reuse the transfer lease's PID/TTL semantics rather than only trusting
        # window metadata during a migration gap.
        held = run("bash", "-c", '. "$1/fleet-lib.sh"; if fleet_rotate_lease_held "$2"; then echo held; fi',
                   "idle-reap", str(BIN), wt)
        if held:
            return False
        run("python3", str(BIN / "fleet-reap-live.py"), window,
            "--socket-name", self.args.socket_name)
        return True

    def candidate(self, window):
        snap = self.snapshot(window)
        if not self.eligible(window, snap):
            if not self.args.dry_run and option(self.tm, window, "@reap_key").startswith("idle:"):
                clear(self.tm, window)
            return False
        pol = self.policy(snap)
        wt = snap["@worktree"]
        key = re.search(r"(?:^|-)(scratch|issue)-(\d+)$", Path(wt).name)
        if not key or (key[1] == "issue" and pol is None):
            return False  # No stable ledger/restore key: never close blindly.
        key = key[1] + "-" + key[2]
        if pol is not None and self.busy(window, snap):
            if not self.args.dry_run and option(self.tm, window, "@reap_key").startswith("idle:"):
                clear(self.tm, window)
            return False
        head = run("git", "-C", wt, "rev-parse", "HEAD")
        branch = run("git", "-C", wt, "symbolic-ref", "--short", "HEAD")
        prs = json.loads(run("gh", "pr", "list", "--repo", self.args.repo, "--head", branch,
                             "--state", "all", "--limit", "100", "--json", "state"))
        if not isinstance(prs, list) or any(not isinstance(p, dict) or p.get("state") not in ("OPEN", "CLOSED", "MERGED") for p in prs):
            return False
        if pol is None and any(p["state"] == "MERGED" for p in prs):
            return False  # Merged heads use the merged policy, including grace.
        if prs and not any(p["state"] == "MERGED" for p in prs):
            base = run("git", "-C", wt, "rev-parse", "--verify", "origin/" + self.args.base)
            if head == base:
                return False
            run("git", "-C", wt, "merge-base", "--is-ancestor", head, base)
        if pol is None:
            deadline = int(snap["@claude_state_ts"]) + self.idle
        else:
            deadline = self.deadline(snap, pol)
        due = notice(self.tm, window, "idle:" + head, deadline, self.now, self.args.dry_run)
        if due > self.now:
            return False
        if pol is not None:
            # The metric's numerator (EPIC #1906): due by its own policy now.
            print("reap-due:%s policy=%s" % (window, snap["@reap_policy"]), file=__import__("sys").stderr)
        if self.args.dry_run:
            print("would-reap-idle:" + window)
            return False
        history = str(BIN / "fleet-history.sh")
        run("bash", history, "record-closed", "--repo", self.args.repo, "--session", self.args.session,
            "--key", key, "--worktree", wt, "--win", window,
            "--title", snap["window_name"],
            "--summary", ("Automatically closed after idle done grace" if pol is None else
                          "Automatically closed by its reap policy " + snap["@reap_policy"]))
        resume = run("bash", history, "resume", "--repo", self.args.repo,
                     "--main", self.args.main, key).split("\t")
        if len(resume) < 4 or resume[0] not in ("RESUME", "CODEX-RESUME") or resume[1] != wt:
            return False  # A transcript-less/review-only row cannot authorize reap.
        # A stopped turn that restarted, changed account/session or moved to a
        # different checkout must not inherit the old permission to close.
        if self.snapshot(window) != snap or not self.eligible(window, snap):
            return False
        if pol is not None and self.busy(window, snap):
            return False  # re-checked right before the close
        if run("git", "-C", wt, "rev-parse", "HEAD") != head:
            return False
        self.retire(window)
        self.tm("kill-window", "-t", window)
        print("reaped-idle:" + window + ("" if pol is None else " policy=" + snap["@reap_policy"]))
        return True

    def main(self):
        if not self.idle or not self.args.repo or not (Path(self.args.main) / ".git").is_dir():
            return 0
        count = 0
        windows = self.tm("list-windows", "-t", self.args.session, "-F", "#{window_id}").split()
        for window in windows:
            if count >= self.args.limit:
                break
            try:
                if re.fullmatch(r"@\d+", window) and self.candidate(window):
                    count += 1
            except RateLimited as exc:
                print(str(exc), file=__import__("sys").stderr)
                return 75
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                print(f"idle reap deferred {window}: {exc}", file=__import__("sys").stderr)
        return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("session", "socket-name", "main", "repo", "base"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--limit", type=int, default=4)
    p.add_argument("--window-repo", action="store_true",
                   help="only windows whose @repo is --repo (multi-repo fleet)")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--policy-only", action="store_true",
                   help="only windows with their own @reap_policy (issue #1902; FLEET_SLEEP=on)")
    return Cleaner(p.parse_args()).main()


if __name__ == "__main__":
    raise SystemExit(main())
