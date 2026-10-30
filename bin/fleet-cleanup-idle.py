#!/usr/bin/env python3
"""Reclaim idle raw windows only after recording and verifying a resumable history."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

from fleet_reap_notice import clear, notice, option, reap_state, tmux
import fleet_reap_policy


def retired_dir():
    """fleet_retired_dir (fleet-lib.sh, issue #1840): the fleet's own closes."""
    seam = os.environ.get("FLEET_PULLBACK_RETIRED_DIR")
    if seam:
        return Path(seam)
    conf = os.environ.get("FLEET_CONF_DIR") or str(Path.home() / ".config/claude-fleet")
    return Path(conf) / "global" / "retired"

BIN = Path(__file__).absolute().parent


# The park gate waits FLEET_GATE_PARK_SECS for the wrapper's hold AFTER its own
# proof, snapshot and export (task PMGT): killed first, it never rolls back its
# @parked stamp and a live session reads parked. Leave it its whole budget.
_park_secs = os.environ.get("FLEET_GATE_PARK_SECS", "")
PARK_TIMEOUT = (int(_park_secs) if re.fullmatch(r"\d{1,7}", _park_secs) else 15) + 45


class RateLimited(Exception):
    pass


def run(*args, cwd=None):
    gh = args[:1] == ("gh",)
    # the session gate's park gets its whole budget (PARK_TIMEOUT, task PMGT)
    timeout = PARK_TIMEOUT if "park" in args else 15
    try:
        return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.PIPE,
                                       timeout=timeout).strip()
    except subprocess.TimeoutExpired as exc:
        if gh:
            # GitHub not answering in 15 s — the same stop as a limit
            raise RateLimited("GitHub unavailable; stopping this tick") from exc
        raise
    except subprocess.CalledProcessError as exc:
        if gh and re.search(r"rate.?limit|HTTP 429", exc.stderr, re.I):
            # gh's own words (issue #4822): a secondary limit and an exhausted
            # quota read alike here, and only the line says which it was.
            said = next((l.strip() for l in exc.stderr.splitlines() if l.strip()), "")
            raise RateLimited("GitHub rate limit; stopping this tick" + (": " + said[:200] if said else "")) from exc
        raise


MERGED_GRACE_DEFAULT = 60       # T680: 做完约 1 分钟收起 (was 600)


def merged_grace_default():
    """FLEET_CLEANUP_MERGED_GRACE — fleet-cleanup.sh's grace after a merge, the
    same seconds for a task session whose work is over (issue #4897, T680)."""
    v = os.environ.get("FLEET_CLEANUP_MERGED_GRACE", str(MERGED_GRACE_DEFAULT))
    return int(v) if v.isdigit() and len(v) <= 8 else MERGED_GRACE_DEFAULT


def minutes():
    value = os.environ.get("FLEET_REAP_IDLE_DONE_MIN", "30")
    return int(value) if re.fullmatch(r"\d{1,6}", value) else 30


# fleet-history.sh resume's verdicts that reopen a conversation in place, one per
# place a transcript lives (the adapter table's `transcript` column): RESUME = the
# login's project dir, CODEX-RESUME = the agent's own home (T631, EPIC T580 C8).
RESUMABLE = ("RESUME", "CODEX-RESUME")
DONE_NO_PR_DEFAULT = 2 * 3600    # 发起人拍板 3


def done_no_pr_secs():
    """How long a finished session with no PR sits before it is closed (issue
    #1832; 发起人拍板 3: two hours). Its own number since issue #3352: the
    scratch default (`done`, fleet_reap_policy.DONE_DEFAULT) went to 15 minutes,
    a finished ticket's session did not."""
    value = os.environ.get("FLEET_REAP_DONE_NO_PR_SECS", "")
    return int(value) if re.fullmatch(r"\d{1,7}", value) else DONE_NO_PR_DEFAULT


# An ID's newest result that waits on its person (E101).
WAIT_RESULTS = ("waiting", "blocked")

FID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


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
        self.why = ""          # why the window in hand is still open (E101: @reap_why)
        self.records = {}      # one record read a tick per task
        self._mem = None       # HHV0: (tight, the longest-idle web window) once a pass

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

    def end_id(self, fid, why="reaped"):
        """A window this reaper killed ends its ID (EPIC T497 C4) — the ledger's
        `closed`, pushed to the hub. Without it the hub kept every reaped session
        open for good (BCYB). worker-stop's road closes its own (`stopped`)."""
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", fid or ""):
            return
        try:
            subprocess.run(["python3", str(BIN / "fleet_id.py"), "close", fid, "--reason", why],
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
        except (OSError, subprocess.SubprocessError):
            pass

    def shared(self, window, fid):
        """Another window still carrying this ID (T847) — `<socket>\t<window>`, else
        "": its reap then closes this window only, never the ID (or the record it
        carries). fleet_fid_shared is the one reader."""
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", fid or ""):
            return ""
        try:
            r = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh" && fleet_fid_shared "$2" "$3" "$4"', "_",
                                str(BIN), fid, self.args.socket_name or "", window],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.SubprocessError):
            return ""
        return r.stdout.strip() if r.returncode == 0 else ""

    def snapshot(self, window):
        names = ("@raw", "@issue", "@repo", "@norepo", "@worktree", "@claude_state", "@claude_state_ts",
                 "@handoff_manifest", "@agent_transfer_until", "window_name",
                 "@reap_policy", "@loop", "@wrap_gone", "pane_dead",
                 "@fleet_role", "@reap_skip", "@test_identity", "@born", "@fleet_id",
                 "@origin", "@origin_fid", "@epic", "@prompt_track", "@prompted", "@agent_status",
                 "@task", "@task_flow", "@task_execution", "@migrating", "@claude_needs", "@pin", "@agent_def", "pane_pid",
                 # T694 (回收 B): where it came from, and what keeps it
                 "@reap_keep_by", "@reap_origin", "@origin_wid", "@reap_unreported",
                 # T810: handed to WebChat — the window is the way back (↵), kept
                 "@handoff_web",
                 # E101: the wrapper's one automatic retry of a temporary error
                 "@auto_resume_at", "@auto_resumed", "@reap_why",
                 # HHV0: a session the web opened, and whether it is parked
                 "@session_origin", "@parked", "@park_wrap_ver", "@park_presence", "@park_watched_at",
                 "@park_held", "@park_since", "@park_wake", "@park_start", "@park_waiting", "@reap_report_pending", "@reap_work_pending")
        # ONE tmux call for the lot (issue #4261): a call per name was 28 execs a
        # window, every window, every tick — ~600 a minute on a busy login. A
        # TAB survives display-message on older tmux, which escapes C0 separators.
        # A value carrying TAB falls back to a call per name; never unescape values.
        out = self.tm("display-message", "-p", "-t", window, "\t".join("#{" + n + "}" for n in names))
        vals = out.split("\t")
        if len(vals) != len(names):
            snap = {n: option(self.tm, window, n) for n in names}
        else:
            snap = {n: v.strip() for n, v in zip(names, vals)}
        work = fleet_reap_policy.current_work(snap["@fleet_id"])
        snap["work_token"] = work.get("token", "")
        snap["work_at"] = str(work.get("at", ""))
        return snap

    def moved(self, window, snap):
        """The window changed since <snap> was read (it came back, was renamed,
        re-stamped) — every close re-reads first. @reap_why is not a change: it is
        this reaper's own note (E101), and another pass of it (the --now watcher
        beside the tick) writes it at its end."""
        now = self.snapshot(window)
        return {k: v for k, v in now.items() if k != "@reap_why"} != \
            {k: v for k, v in snap.items() if k != "@reap_why"}

    @staticmethod
    def finished(snap):
        """done | exited | the stamp — the agent's own finished 7501 word first
        (fleet_reap_notice.reap_state, issue #4822): a `looping` stamp its Stop
        hook left for a child that has since ended is not «still working»; what
        is really pending is busy()'s and fleet-reap-live.py's to say."""
        return reap_state(snap["@claude_state"], snap["@agent_status"], snap.get("@claude_needs", ""))

    def theirs(self, snap):
        """Another hosted repo's window, in a multi-repo fleet's per-repo pass
        (--window-repo): that repo's pass decides it — this one neither closes it
        nor CLEARS the countdown that pass set (issue #4822: every other repo's
        pass wiped it, so a `done:10m` window's notice never came due). A window
        whose repo is unknown is no pass's: skipped, never guessed."""
        return bool(self.args.window_repo) and norm_repo(snap["@repo"]) != norm_repo(self.args.repo)

    def ticket(self, snap):
        """The ticket a session is bound to: its @issue, else — for a batch
        driver — the EPIC its @epic names (`[owner/name]#N`, this repo's only).
        Empty for a plain scratch."""
        if re.fullmatch(r"\d{1,9}", snap["@issue"]):
            return snap["@issue"]
        m = re.fullmatch(r"(?:([\w.-]+/[\w.-]+))?#(\d{1,9})", snap["@epic"])
        if m and (not m[1] or norm_repo(m[1]) == norm_repo(self.args.repo)):
            return m[2]
        return ""

    def policy(self, snap):
        """Read an existing policy without role or PIN overrides.
        A window without a policy keeps its legacy route.
        """
        if snap.get("@handoff_web") == "1":
            return fleet_reap_policy.parse("keep")
        raw = snap["@reap_policy"]
        eff = fleet_reap_policy.effective(raw, snap.get("@pin", ""), snap.get("@agent_def", ""),
                                          snap.get("@reap_keep_by", ""))
        return fleet_reap_policy.parse(eff) if eff else None

    def origin(self, snap):
        """Where the session came from (T694): its @reap_origin, else read off it."""
        return fleet_reap_policy.snapshot_origin(snap)

    @staticmethod
    def automatic_close_held(snap):
        from fleet_task_execution import automatic_close_held
        return automatic_close_held(snap.get("@fleet_id", ""), snap.get("@task_execution", ""),
                                    snap.get("@task", ""))

    def work_over(self, snap):
        """«做完» (T680's one rule): its ID's newest result is final, or its task
        record is closed."""
        if snap.get("@reap_work_pending") or fleet_reap_policy.report_hold(snap.get("@fleet_id", ""), snap.get("@reap_report_pending", "")):
            return False
        if fleet_reap_policy.completion_hold(snap.get("@fleet_id", ""), snap.get("@task", "")):
            return False
        if self.id_over(snap["@fleet_id"]):
            return True
        return bool(re.fullmatch(r"T[1-9][0-9]{0,9}", snap["@task"])) and self.task_closed(snap["@task"]) == 0

    def route(self, snap):
        """Which rule may close this window: 'idle' — the historic raw rule, or
        the window's own done / loop-end / at policy (issue #1902); 'no-pr' — a
        finished session no PR will ever close (issue #1832): an issue window
        with no policy or `merged`, a spawned scratch with none; None — never
        this pass (keep, merged on a scratch). No policy is not «never» (issue
        #2970): a window bound to a ticket — its @issue, or the EPIC its @epic
        drives — goes the no-pr road, which closes it only once that ticket is
        closed."""
        pol = self.policy(snap)
        if pol is not None:
            if pol[0] in ("done", "idle", "loop-end", "at"):
                return "idle"
            return "no-pr" if pol[0] == "merged" and snap["@issue"] else None
        if snap["@raw"] == "1" and not snap["@issue"]:
            return "no-pr" if self.ticket(snap) else "idle"
        return "no-pr"

    def say(self, window, token, detail=""):
        """One result token per window (issue #1832: a road with no token is a
        road nobody sees). A skip is printed when it CHANGES (@reap_skip), so a
        window waiting out its two hours is one log line, not 120."""
        line = token + " " + window + ((" " + detail) if detail else "")
        if token.startswith("skip:") and not self.args.dry_run:
            try:
                if option(self.tm, window, "@reap_skip") == token:
                    return
                self.tm("set-option", "-w", "-t", window, "@reap_skip", token)
            except (OSError, subprocess.SubprocessError):
                pass
        print(line)

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

    def held(self, window, snap, over):
        """Completion never overrides a real background job or pending loop.

        Keep the caller's `over` argument compatible; it is evidence about the
        result, not permission to terminate work (C6 / T965).
        """
        if not self.busy(window, snap):
            return False
        self.why = "bg"
        self.say(window, "skip:bg-job")
        return True

    def deadline(self, snap, pol):
        """When this window's own policy lets it go (issue #1902)."""
        kind, val = pol
        stamp = max(int(snap["@claude_state_ts"]), int(snap.get("work_at") or 0))
        if kind in ("done", "idle"):
            return stamp + val
        if kind == "loop-end":
            return stamp + fleet_reap_policy.LOOP_END_GRACE
        return val  # at

    def transition(self, wt):
        """Take the worktree's transition lock (fleet_transition_lock_take's
        mkdir, claude-fleet T569): a reopen (fleet-migrate.sh holds it from its
        pick to its new window) and this close never run at once — T477's old
        window was closed here mid-reopen, and the window the reopen then opened
        was nobody's. The lock dir on success (drop with untransition), None
        when another transition owns it."""
        if not wt:
            return ""
        try:
            base = run("bash", "-c", '. "$1/fleet-lib.sh"; fleet_rotate_lease_file "$2"',
                       "idle-lock", str(BIN), wt)
        except (OSError, subprocess.SubprocessError):
            return ""
        if not base:
            return ""
        lock = Path(base + ".transfer-lock")
        try:
            lock.mkdir()
        except FileExistsError:
            return None
        except OSError:
            return ""
        (lock / "pid").write_text("%d\n" % os.getpid())
        return str(lock)

    @staticmethod
    def untransition(lock):
        if not lock:
            return
        try:
            if (Path(lock) / "pid").read_text().strip() == str(os.getpid()) and not (Path(lock) / "request").exists():
                (Path(lock) / "pid").unlink()
                Path(lock).rmdir()
        except OSError:
            pass

    def close(self, window, snap, recheck, why="reaped"):
        """The one kill-window of a worktree session: under its transition lock,
        never while a reopen marks it (@migrating), and only once <recheck>()
        still holds — rc False when any of them says no (nothing closed). <why> is
        its ID's close reason (`parked` for a park, E101)."""
        if not getattr(self, "_closing_identity", False):
            import fleet_session_gate
            fid = snap.get("@fleet_id", "")
            if not FID_RE.fullmatch(fid):
                self.why = "no-identity"
                return False
            with fleet_session_gate.lock(fid):
                current = self.snapshot(window)
                if (self.automatic_close_held(current) or self.moved(window, snap) or current.get("@reap_work_pending")
                        or (snap.get("@parked") and not current.get("@park_held"))
                        or current.get("@park_wake") or current.get("@park_start")
                        or fleet_session_gate.close_hold(fid)):
                    self.why = "live"
                    return False
                self._closing_identity = True
                try:
                    return self.close(window, snap, recheck, why)
                finally:
                    self._closing_identity = False
        if snap["@migrating"]:
            self.why = "moving"
            self.say(window, "skip:migrating", snap["@migrating"])
            return False
        lock = self.transition(snap["@worktree"])
        if lock is None:
            self.say(window, "skip:transition")
            return False
        try:
            if (fleet_reap_policy.report_hold(snap.get("@fleet_id", ""))
                    or self.moved(window, snap) or not recheck() or not self.final_live(window)
                    or self.moved(window, snap) or self.automatic_close_held(self.snapshot(window))):
                return False
            other = self.shared(window, snap["@fleet_id"])
            if other:
                self.say(window, "id-shared", other.split("\t")[-1])
            else:
                self.retire(window)
            self.tm("kill-window", "-t", window)
            if not other:
                self.end_id(snap["@fleet_id"], why)
            return True
        finally:
            self.untransition(lock)

    def final_live(self, window):
        """Re-read native input/jobs at the close boundary, while ID is locked."""
        try:
            run("python3", str(BIN / "fleet-reap-live.py"), window,
                "--socket-name", self.args.socket_name or "", "--automatic")
            return True
        except subprocess.CalledProcessError as exc:
            self.why = "live"
            self.say(window, "skip:live", (exc.output or "").strip())
            return False
        except (OSError, subprocess.SubprocessError):
            self.why = "live"
            return False

    def eligible(self, window, snap, task=False):
        pol = self.policy(snap)
        # A task session's `merged` is this pass's (issue #4897): the record
        # closed is what task_session() checked; every gate below still applies.
        if task:
            pass
        elif pol is not None:
            # An explicit policy decides which windows this pass may close: done /
            # loop-end / at, an issue session as well as a scratch. keep and merged
            # are never this pass's (merged is fleet-cleanup.sh's). Every gate
            # below still applies.
            if pol[0] not in ("done", "idle", "loop-end", "at"):
                if pol[0] == "keep":
                    self.why = "keep"
                return False
        elif snap["@raw"] != "1" or snap["@issue"]:
            return False
        # An exited session on its recovery page (issue #1784) is as idle as a
        # finished turn: the same grace, the same resumable record — and so is a
        # window with no agent at all (the wrapper gone, the pane dead:
        # fleet_window_has_agent, issue #2404).
        if ((self.finished(snap) not in ("done", "exited")
                    and snap["@wrap_gone"] != "1" and snap["pane_dead"] != "1")
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
            self.why = "moving"
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
        # A task session whose work is over (its record closed / its ID's final
        # result — task=True) is closed even with UNTRACKED files only (T859): the
        # close keeps the worktree byte for byte, and what an agent leaves there is
        # tool output (.playwright-mcp/, screenshots, a page draft) — it held seven
        # finished windows open for days. A tracked change still keeps it.
        status = run("git", "-C", wt, "status", "--porcelain")
        if status and not (task and all(l.startswith("?? ") for l in status.splitlines())):
            self.why = "dirty"
            return False
        # Reuse the transfer lease's PID/TTL semantics rather than only trusting
        # window metadata during a migration gap.
        held = run("bash", "-c", '. "$1/fleet-lib.sh"; if fleet_rotate_lease_held "$2"; then echo held; fi',
                   "idle-reap", str(BIN), wt)
        if held:
            self.why = "moving"
            return False
        try:
            run("python3", str(BIN / "fleet-reap-live.py"), window,
                "--socket-name", self.args.socket_name)
        except subprocess.CalledProcessError:
            self.why = "live"      # someone looks at it, or a draft in its box
            raise
        return True

    def test_session(self, window, snap):
        """A no-repo session the TEST identity's client placed (issue #2505,
        @test_identity): a placement check, never anyone's work — so, unlike every
        other no-repo session (#791), its own policy closes it (done:10m unless it
        asked for another). Its clock is its last turn, or its birth when it never
        took one; working / asking / holding a job is never closed. No
        worktree, so nothing to record: stopped the graceful way, by identity
        (fleet-worker-stop.sh fid:, as dash-reap.sh's no-repo row)."""
        pol = self.policy(snap)
        if pol is None or pol[0] not in ("done", "idle", "at"):
            return False
        if (snap["@claude_state"] not in ("", "done", "exited", "idle")
                and snap["@wrap_gone"] != "1" and snap["pane_dead"] != "1"):
            return False
        stamp = snap["@claude_state_ts"] if snap["@claude_state_ts"].isdigit() else snap["@born"]
        if stamp.isdigit():
            stamp = str(max(int(stamp), int(snap.get("work_at") or 0)))
        if pol[0] in ("done", "idle") and (not stamp.isdigit() or int(stamp) + pol[1] > self.now):
            return False
        if pol[0] == "at" and pol[1] > self.now:
            return False
        fid = snap["@fleet_id"]
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", fid or ""):
            return False
        if self.busy(window, snap):
            return False
        if self.args.dry_run:
            print("would-reap-test:" + window)
            return False
        if self.moved(window, snap):
            return False
        out = self.stop_norepo(window, snap)
        print("reaped-test:" + window + " policy=" + snap["@reap_policy"] + " " + (out or "no answer"))
        return out.startswith("stopped:")

    def norepo(self, window, snap):
        """No-repo sessions use their explicit policy without ancestry rules.
        Legacy done waits for exit; idle/loop-end/at accept a finished turn.
        Explicit probes retain their test policy. UI panels never enter this road.
        """
        pol = self.policy(snap)
        probe = self.origin(snap) == "probe"
        if probe and not self.work_over(snap):
            self.why = "unreported"
            return False
        kinds = ("done", "idle", "loop-end", "at")
        ended = (("done", "exited") if probe or (pol and pol[0] != "done") else ("exited",))
        if (pol is None or pol[0] not in kinds
                or snap["@fleet_role"] not in ("", "worker")
                or snap["window_name"] in ("dash", "plan", "backlog", "home")
                or (snap["@claude_state"] not in ended
                    and not (probe and (snap["@wrap_gone"] == "1" or snap["pane_dead"] == "1")))):
            if not self.args.dry_run and option(self.tm, window, "@reap_key").startswith("idle:"):
                clear(self.tm, window)
            return False
        stamp = snap["@claude_state_ts"]
        if not stamp.isdigit() or not 0 < int(stamp) <= self.now:
            return False
        transfer = snap["@agent_transfer_until"]
        if transfer and (not transfer.isdigit() or int(transfer) > self.now):
            return False
        if os.environ.get("TMUX_PANE") and os.environ.get("TMUX"):
            if self.tm("display-message", "-p", "-t", os.environ["TMUX_PANE"], "#{window_id}") == window:
                return False
        if self.busy(window, snap):
            return False
        due = notice(self.tm, window, "idle:norepo", self.deadline(snap, pol),
                     self.now, self.args.dry_run)
        if due > self.now:
            return False
        print("reap-due:%s policy=%s" % (window, snap["@reap_policy"]), file=__import__("sys").stderr)
        if self.args.dry_run:
            print("would-reap-idle:" + window)
            return False
        if self.moved(window, snap):
            return False  # it came back (resumed, renamed, re-stamped) since the read
        fid = snap["@fleet_id"]
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", fid or ""):
            return False
        # stopped the graceful way, by identity — test_session's road (#2505)
        out = self.stop_norepo(window, snap)
        print("reaped-idle:" + window + " policy=" + snap["@reap_policy"] + " norepo " + (out or "no answer"))
        return out.startswith("stopped:")

    def empty(self, window, snap):
        """A no-repo session nobody ever typed into (issue #4000): opened with no
        words (⌘N, a plain `fleet` whose last session was gone — dash-raw-session.sh
        stamps @prompt_track) and never a turn since (no @prompted, set-claude-state.sh's
        `working`). Its `done` policy's grace counted from its birth or its last state
        stamp, whichever is later; never while working or asking, while a client
        looks at it, with a draft in its input box or a job running. Nothing in it to
        keep, so no history row — stopped by identity, test_session's road."""
        pol = self.policy(snap)
        if (pol is None or pol[0] not in ("done", "idle")
                or snap["@fleet_role"] not in ("", "worker")
                or snap["window_name"] in ("dash", "plan", "backlog", "home")
                or (snap["@claude_state"] not in ("", "done", "idle", "exited")
                    and snap["@wrap_gone"] != "1" and snap["pane_dead"] != "1")):
            return False
        stamps = [int(v) for v in (snap["@born"], snap["@claude_state_ts"], snap.get("work_at", "")) if v.isdigit()]
        # an `idle:2h` never typed into goes on the old 15 minutes (T694)
        grace = min(pol[1], fleet_reap_policy.DONE_DEFAULT) if pol[0] == "idle" else pol[1]
        if not stamps or max(stamps) + grace > self.now:
            return False
        fid = snap["@fleet_id"]
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", fid or ""):
            return False
        if os.environ.get("TMUX_PANE") and os.environ.get("TMUX"):
            if self.tm("display-message", "-p", "-t", os.environ["TMUX_PANE"], "#{window_id}") == window:
                return False
        try:
            shown = self.tm("list-clients", "-F", "#{window_id}").split()
        except (OSError, subprocess.SubprocessError):
            return False
        if window in shown:
            return False                      # someone is looking at it right now
        if snap["@wrap_gone"] != "1" and snap["pane_dead"] != "1":
            try:
                box = json.loads(subprocess.run(
                    ["python3", str(BIN / "fleet-input.py"), "--socket", self.args.socket_name or "",
                     "--pane", window], capture_output=True, text=True, timeout=15).stdout or "{}")
            except (ValueError, OSError, subprocess.SubprocessError):
                box = {}
            if box.get("state") != "empty":
                return False                  # a draft (or it cannot be read): someone typed
        if self.busy(window, snap):
            return False
        print("reap-due:%s policy=%s empty" % (window, snap["@reap_policy"]), file=__import__("sys").stderr)
        if self.args.dry_run:
            print("would-reap-empty:" + window)
            return False
        if self.moved(window, snap):
            return False
        out = self.stop_norepo(window, snap)
        print("reaped-empty:" + window + " policy=" + snap["@reap_policy"] + " " + (out or "no answer"))
        return out.startswith("stopped:")

    def stop_norepo(self, window, snap):
        """The existing graceful stop, ordered with message admission by ID."""
        import fleet_session_gate
        fid = snap.get("@fleet_id", "")
        if not FID_RE.fullmatch(fid):
            return ""
        with fleet_session_gate.lock(fid):
            if (self.automatic_close_held(self.snapshot(window)) or snap.get("@reap_work_pending") or fleet_session_gate.close_hold(fid) or self.moved(window, snap)
                    or self.busy(window, snap)):
                return ""
            pol = self.policy(snap)
            if pol and pol[0] in ("done", "merged", "loop-end") and fleet_reap_policy.completion_hold(fid, snap.get("@task", "")):
                return ""
            if (not self.final_live(window) or self.moved(window, snap)
                    or self.automatic_close_held(self.snapshot(window))):
                return ""
            self.retire(window)
            return subprocess.run(["bash", str(BIN / "fleet-worker-stop.sh"), self.args.session, "fid:" + fid],
                                  env=dict(os.environ, FLEET_SESSION=self.args.session), stdin=subprocess.DEVNULL,
                                  capture_output=True, text=True, timeout=120).stdout.strip()

    def completed_session(self, window, snap):
        """Honor an existing legacy merged policy without role privileges.

        Controlled sessions cannot reach this archive path. A missing historical
        result neither marks an unanswered question nor starts a closing timer.
        """
        if snap["@issue"] or self.task_ref(snap) or not FID_RE.fullmatch(snap["@fleet_id"] or ""):
            return None
        pol = self.policy(snap)
        if pol is None or pol[0] != "merged":
            return None
        norepo = snap["@norepo"] == "1"
        if not norepo and (snap["@raw"] != "1" or self.theirs(snap)):
            return None
        if (snap["@fleet_role"] in ("home", "panel")
                or snap["window_name"] in ("dash", "plan", "backlog", "home")):
            return None
        finished = (self.finished(snap) in ("done", "exited")
                    or snap["@wrap_gone"] == "1" or snap["pane_dead"] == "1")
        over = finished and self.work_over(snap)
        if not over:
            return None
        stamp = snap["@claude_state_ts"]
        if not stamp.isdigit() or not 0 < int(stamp) <= self.now:
            return False
        stamp = str(max(int(stamp), int(snap.get("work_at") or 0)))
        transfer = snap["@agent_transfer_until"]
        if transfer and (not transfer.isdigit() or int(transfer) > self.now):
            return False
        if os.environ.get("TMUX_PANE") and os.environ.get("TMUX"):
            if self.tm("display-message", "-p", "-t", os.environ["TMUX_PANE"], "#{window_id}") == window:
                return False
        held = lambda: self.held(window, snap, over)
        if held():
            return False
        grace = self.args.grace if self.args.grace is not None else (pol[1] or merged_grace_default())
        deadline, why = int(stamp) + grace, "over"
        summary = "Automatically closed by its merged policy; its work is over"
        due = notice(self.tm, window, why + ":" + snap["@fleet_id"][:8], deadline, self.now,
                     self.args.dry_run, tick=max(1, min(deadline - int(stamp), 60)))
        if due > self.now:
            self.why = "timer:%d" % due
            return False
        print("reap-due:%s policy=%s %s" % (window, snap["@reap_policy"] or "merged", why),
              file=__import__("sys").stderr)
        if self.args.dry_run:
            print("would-reap-%s:%s" % (why, window))
            return False
        if norepo:
            if self.moved(window, snap):
                return False
            out = self.stop_norepo(window, snap)
            print("reaped-%s:%s norepo %s" % (why, window, out or "no answer"))
            return out.startswith("stopped:")
        wt = snap["@worktree"]
        key = re.search(r"(?:^|-)(scratch)-(\d+)$", Path(wt).name) if wt else None
        if not key or not self.eligible(window, snap, task=True):
            return False
        key = key[1] + "-" + key[2]
        run("bash", str(BIN / "fleet-history.sh"), "record-closed", "--repo", self.args.repo,
            "--session", self.args.session, "--key", key, "--worktree", wt, "--win", window,
            "--title", snap["window_name"], "--summary", summary)
        if not self.reopens(window, key, wt):
            return False
        if not self.close(window, snap, lambda: not held()):
            return False
        print("reaped-%s:%s %s" % (why, window, key))
        return True

    def candidate(self, window):
        """One window's pass — and, whatever the road decided, why it is still open
        (E101): @reap_why, one code the node's inventory carries (`reapwhy=`) and the
        hub turns into the list card's 「为什么还没收」 line. Written when it changes,
        cleared when there is none (a working window says none); a closed window
        has no window left to carry it."""
        self.why = ""
        snap = self.snapshot(window)
        # Retire the old missing-result mark; it no longer denotes a question or
        # grants permission to close. Do not rewrite any chosen retention policy.
        if snap.get("@reap_unreported") and not self.args.dry_run and not self.theirs(snap):
            self.tm("set-option", "-wu", "-t", window, "@reap_unreported")
            snap["@reap_unreported"] = ""
        closed = False
        try:
            closed = self.road(window, snap)
            return closed
        finally:
            if not closed:
                self.stamp_why(window, snap)

    def stamp_why(self, window, snap):
        if self.args.dry_run or self.theirs(snap):
            return
        fin = (self.finished(snap) in ("done", "exited") or snap["@wrap_gone"] == "1" or snap["pane_dead"] == "1")
        why = self.why if fin and re.fullmatch(r"[a-z-]{1,16}(?::\d{1,11})?", self.why or "") else ""
        if why == snap.get("@reap_why", ""):
            return
        try:
            if why:
                self.tm("set-option", "-w", "-t", window, "@reap_why", why)
            else:
                self.tm("set-option", "-wu", "-t", window, "@reap_why")
        except (OSError, subprocess.SubprocessError):
            pass

    def error_stop(self, window, snap):
        """A session its agent's error stopped (E101): @claude_state exited with a
        7501 `error` report — FQBW's 502 sat 16 hours in 已结束. Never closed by a
        reaper: it waits for the wrapper's one automatic retry of a temporary error
        (fleet-session-wrap.sh @auto_resume_at), else for its person. None = not one."""
        if snap["@claude_state"] != "exited" or snap["@wrap_gone"] == "1" or snap["pane_dead"] == "1":
            return None
        try:
            rec = json.loads(snap["@agent_status"]) if snap["@agent_status"] else None
        except ValueError:
            rec = None
        if not isinstance(rec, dict) or rec.get("state") != "error":
            return None
        at = snap.get("@auto_resume_at", "")
        if at.isdigit():
            self.why = "error-retry:%s" % at
        elif snap.get("@auto_resumed") == "1":
            self.why = "error-retried"
        else:
            self.why = "error"
        self.say(window, "skip:error-stop", self.why)
        return False

    def id_status(self, fid):
        """fleet_id.py status of the window's ID ({} unreadable)."""
        if not FID_RE.fullmatch(fid or ""):
            return {}
        env = dict(os.environ)
        env.pop("FLEET_ID_LIVE", None)
        try:
            out = subprocess.run(["python3", str(BIN / "fleet_id.py"), "status", fid], env=env,
                                 capture_output=True, text=True, timeout=15).stdout
            got = json.loads(out or "{}")
        except (OSError, ValueError, subprocess.SubprocessError):
            return {}
        return got if isinstance(got, dict) else {}

    def is_waiting(self, snap):
        st = self.id_status(snap.get("@fleet_id", ""))
        if st.get("state") in ("done", "failed"):
            return False
        result = st.get("result") or {}
        task = snap.get("@task", "")
        rc, asked, _ = self.record(task) if task else (3, False, False)
        return rc != 0 and ((isinstance(result, dict) and result.get("state") in WAIT_RESULTS) or asked)

    def waiting(self, window, snap):
        """E101 no longer closes a window to park it. Legacy wrappers wait for
        a safe reopen; new wrappers use the same HHV0 park as every origin."""
        if self.finished(snap) != "done" or self.theirs(snap) or not self.is_waiting(snap):
            return None
        pol = self.policy(snap)
        if pol and pol[0] == "keep":
            self.why = "keep"
            return False
        if snap.get("@reap_unreported") and not self.args.dry_run:
            self.tm("set-option", "-wu", "-t", window, "@reap_unreported")
        self.why = "waiting"
        self.say(window, "skip:waiting", "old-wrapper" if not snap.get("@park_wrap_ver") else "park-gate")
        return False

    @staticmethod
    def dead_park(snap):
        """@parked stamped, never held, and the agent reported after the stamp —
        fleet_session_gate.stale_park's test, read off the snapshot first."""
        stamp = snap.get("@parked", "")
        if (not stamp.isdigit() or snap.get("@park_held") or snap.get("@park_start") or snap.get("@park_wake")
                or not FID_RE.fullmatch(snap.get("@fleet_id", ""))):
            return False
        try:
            st = json.loads(snap.get("@agent_status") or "{}")
        except ValueError:
            return False
        ts = st.get("ts") if isinstance(st, dict) else None
        return (st.get("state") in ("working", "blocked", "done", "idle")
                and isinstance(ts, (int, float)) and ts > int(stamp))

    def parked(self, window, snap):
        """Retire only acknowledged, inactive parks, under the wake lock. History
        and resume verification precede the close; data/worktree stays in place."""
        if not snap.get("@parked"):
            return None
        self.why = "parked"
        if self.automatic_close_held(snap):
            return False
        if self.dead_park(snap) and not self.args.dry_run:
            # a park that died half-way (task PMGT): the gate rolls it back,
            # under the fid lock, after the same check
            command = os.environ.get("FLEET_SESSION_GATE_CMD")
            try:
                run(*(command.split() if command else ["python3", str(BIN / "fleet_session_gate.py")]),
                    "heal", "--fid", snap["@fleet_id"])
            except (subprocess.SubprocessError, OSError):
                pass
        if not snap.get("@park_held") or not snap.get("@park_wrap_ver") or self.theirs(snap):
            return False
        due = fleet_reap_policy.parked_deadline(snap)
        if due is None:
            pol = self.policy(snap)
            if not fleet_reap_policy.uses_park_retention(snap) and (not pol or pol[0] != "keep"):
                return None
            self.why = "keep"
            return False
        self.why = "timer:%d" % due
        if self.now < due or getattr(self, "_park_only", False):
            return False
        import fleet_session_gate
        fid = snap.get("@fleet_id", "")
        if not FID_RE.fullmatch(fid):
            return False
        draft = fleet_session_gate.fid_dir(fid) / "park-input.txt"
        if (draft.exists() and draft.stat().st_size) or (self.moved(window, snap) or snap.get("@park_wake") or snap.get("@park_start")
                or snap.get("@migrating") or self.busy(window, snap)
                or any(r.get("state") in ("queued", "trying", "native", "waking")
                       for r in fleet_session_gate.records(fid))):
            self.why = "live"
            return False
        clients = self.tm("list-clients", "-F", "#{client_control_mode}\t#{window_id}")
        if any(line.split("\t") == ["0", window] for line in clients.splitlines()):
            self.why = "live"
            return False
        wt = snap.get("@worktree", "")
        m = re.search(r"(?:^|-)(scratch|issue)-(\d+)$", Path(wt).name) if wt else None
        if not m or not self.args.repo or not Path(wt).is_dir() or Path(wt).resolve() == Path(self.args.main).resolve():
            self.why = "no-history"
            return False
        key = m[1] + "-" + m[2]
        if self.args.dry_run:
            print("would-reap-parked:" + window)
            return False
        run("bash", str(BIN / "fleet-history.sh"), "record-closed", "--repo", self.args.repo,
            "--session", self.args.session, "--key", key, "--worktree", wt, "--win", window,
            "--title", snap["window_name"], "--summary", "Reaped after parked retention; conversation and worktree kept")
        if not self.reopens(window, key, wt):
            self.why = "no-history"
            return False
        if not self.close(window, snap, lambda: not self.busy(window, snap)):
            return False
        print("reaped-parked:%s %s" % (window, key))
        return True

    @property
    def mem_tight(self):
        return self.mem_state()[0]

    def mem_state(self):
        """Free memory pressure, once a pass. Oldest eligible is tried first;
        a watched / busy oldest window must never starve the following ones."""
        if self._mem is not None:
            return self._mem
        free = os.environ.get("FLEET_PARK_MEM_FREE")
        if free is None:
            free = run("bash", "-c", '. "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_mem_probe | awk \'NF{print $2; exit}\'',
                       "park-mem", str(BIN))
        pct = os.environ.get("FLEET_PARK_MEM_PCT", "15")
        tight = bool((free or "").strip().isdigit() and pct.isdigit() and int(free.strip()) < int(pct))
        trial = os.environ.get("FLEET_TRIAL_DIR") or os.path.join(
            os.environ.get("FLEET_NODE_STATE", "/var/db/fleet-node"), "trial")
        try:
            for line in Path(trial, "mem.tsv").read_text().splitlines():
                f = line.split("\t")
                if len(f) >= 2 and f[0] == str(os.getuid()) and f[1].isdigit() and int(f[1]) > 0:
                    rss = sum(int(x) for x in run("ps", "-U", str(os.getuid()), "-o", "rss=").split() if x.isdigit())
                    if rss // 1024 >= int(f[1]) * 80 // 100:
                        tight = True
        except OSError:
            pass
        self._mem = (tight, "")
        return self._mem

    def web_park(self, window, snap):
        """HHV0's one parker, extended to every origin (C1).

        Name retained for callers from the previous release. Old wrappers keep
        their original close policies. A new wrapper parks without changing its
        identity or credential. No timers are lost: the gate exports C3's wake
        contract before exiting, or holds when it cannot.
        """
        if self.theirs(snap) and snap.get("@norepo") != "1":
            return False
        if not snap.get("@park_wrap_ver"):
            return False if snap.get("@session_origin") == "web" else None
        if snap.get("@parked"):
            self.why = "parked"
            return False
        if snap.get("@wrap_gone") == "1" or snap.get("pane_dead") == "1" or self.finished(snap) != "done":
            return None if snap.get("@session_origin") != "web" else False
        controlled = self.automatic_close_held(snap)
        # Only legacy work may bypass safe parking for its old completion policy.
        if (not controlled and not fleet_reap_policy.uses_park_retention(snap)
                and "@task" in snap and self.work_over(snap)):
            return None
        stamp = snap.get("@claude_state_ts", "")
        if not stamp.isdigit():
            return False
        # A completed probe's one-minute policy precedes the five-minute park
        # tier. Return to the existing reaper; its live/history checks still
        # decide whether it may close. Explicit waiting reports park instead.
        pol = self.policy(snap) if not controlled and fleet_reap_policy.ORIGINS[self.origin(snap)]["reap"] == "done" else None
        # Only when that reaper may close it: a probe whose work is not over is
        # held there as `unreported`, and deferring would leave it neither closed
        # nor parked, its agent alive for good.
        if (pol and pol[0] == "done" and self.deadline(snap, pol) <= self.now
                and not self.is_waiting(snap)
                and (self.origin(snap) != "probe" or self.work_over(snap))):
            return None
        if not hasattr(self, "_park_watched"):
            clients = self.tm("list-clients", "-F", "#{client_control_mode}\t#{window_id}")
            self._park_watched = {f[1] for line in clients.splitlines()
                                  if len(f := line.split("\t")) == 2 and f[0] != "1"}
        if window in self._park_watched:
            self.tm("set-option", "-w", "-t", window, "@park_watched_at", str(self.now))
            self.why = "watched"
            return False
        due = fleet_reap_policy.park_after(snap, self.now)
        self.why = "waiting:%d" % (max(int(stamp), int(snap.get("@park_watched_at") or 0)) + due)
        idle = self.now - max(int(stamp), int(snap.get("@park_watched_at") or 0))
        early = self.mem_tight and not getattr(self, "_park_memory_done", False)
        if (due == 0 and not early) or (idle < due and not early):
            return False
        # The session gate proves native idle/background state and exports its
        # timers. busy() is the CLOSE gate: its Loop hold must not veto parking.
        fid = snap.get("@fleet_id", "")
        if not FID_RE.fullmatch(fid):
            return False
        if self.args.dry_run:
            print("would-park-web:" + window)
            return False
        why = "memory" if early else "idle"
        command = os.environ.get("FLEET_SESSION_GATE_CMD")
        out = run(*(command.split() if command else ["python3", str(BIN / "fleet_session_gate.py")]),
                  "park", "--fid", fid, "--why", why)
        try:
            got = json.loads(out or "{}")
        except ValueError:
            got = {}
        if got.get("ok"):
            if early:
                self._park_memory_done = True
            waiting = self.is_waiting(snap)
            self.tm("set-option", "-w", "-t", window, "@park_waiting", "1" if waiting else "0")
            if snap.get("@reap_unreported"):
                self.tm("set-option", "-wu", "-t", window, "@reap_unreported")
            print("parked-web:%s %s" % (window, why))
            return True
        self.why = fleet_reap_policy.PARK_HOLDS.get(got.get("why"), "park-gate")
        return False

    def road(self, window, snap):
        # Existing automatic archive does not obtain a controlled stop/exit
        # receipt. Retain the binding/history; the same safe park releases native
        # resources and capacity. Unknown control metadata cannot become legacy.
        if self.automatic_close_held(snap):
            self.why = "parked" if snap.get("@parked") else "keep"
            if not snap.get("@parked") and not getattr(self.args, "skip_park", False):
                return bool(self.web_park(window, snap))
            return False
        hold = ("input-pending" if snap.get("@reap_work_pending") else
                fleet_reap_policy.report_hold(snap.get("@fleet_id", ""), snap.get("@reap_report_pending", "")))
        if hold:
            # Holding completion still permits the existing safe park gate.
            if not snap.get("@parked") and not getattr(self.args, "skip_park", False):
                self.web_park(window, snap)
            self.why = hold
            return False
        road = self.parked(window, snap)
        if road is not None:
            return road
        if not snap.get("@parked") and not getattr(self.args, "skip_park", False):
            road = self.web_park(window, snap)
            if road is not None:
                return road
        if getattr(self, "_park_only", False):
            return False
        if self.origin(snap) == "probe" and not self.work_over(snap):
            self.why = "unreported"
            return False
        if snap.get("@park_wrap_ver") and fleet_reap_policy.uses_park_retention(snap):
            # Its old stamped idle policy cannot bypass the new park retention.
            return False
        road = self.error_stop(window, snap)
        if road is not None:
            return road
        road = self.waiting(window, snap)
        if road is not None:
            return road
        road = self.completed_session(window, snap)
        if road is not None:
            return road
        if snap["@test_identity"] == "1" and snap["@norepo"] == "1":
            return self.test_session(window, snap)
        if snap["@norepo"] == "1" and snap["@prompt_track"] == "1" and snap["@prompted"] != "1":
            return self.empty(window, snap)
        if snap["@norepo"] == "1":
            return self.norepo(window, snap)
        if self.theirs(snap):
            return False
        if self.task_ref(snap):
            return self.task_session(window, snap)
        if self.route(snap) == "no-pr":
            return self.no_pr(window, snap)
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
        prs = self.branch_prs(branch, head)
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
            self.why = "timer:%d" % due
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
        if not self.reopens(window, key, wt):
            return False
        # A stopped turn that restarted, changed account/session or moved to a
        # different checkout must not inherit the old permission to close.
        if not self.close(window, snap, lambda: self.eligible(window, snap)
                          and not (pol is not None and self.busy(window, snap))  # re-checked right before the close
                          and run("git", "-C", wt, "rev-parse", "HEAD") == head):
            return False
        print("reaped-idle:" + window + ("" if pol is None else " policy=" + snap["@reap_policy"]))
        return True

    def reopens(self, window, key, wt):
        """The history row just recorded reopens its conversation in this worktree —
        whichever agent ran it (T631, EPIC T580 C8): fleet-history.sh resume's
        verdict is one of RESUMABLE and names `wt`. A transcript-less / review-only
        row cannot authorize a reap — said, not swallowed (issue #1832: it was why a
        done scratch sat for days)."""
        resume = run("bash", str(BIN / "fleet-history.sh"), "resume", "--repo", self.args.repo,
                     "--main", self.args.main, key).split("\t")
        if len(resume) < 4 or resume[0] not in RESUMABLE or resume[1] != wt:
            self.say(window, "skip:no-resume", key + " " + (resume[0] if resume else "?"))
            return False
        return True

    def task_ref(self, snap):
        """A development task's session (issue #4897, EPIC #4895 批 0): a repo
        scratch bound to the hub's record (@task T<n> + @task_flow 1, no issue)
        whose policy is `merged` (or none — a task's default). Its end is the
        RECORD closed, never a PR or an issue. Any other policy (done / loop-end /
        at / keep) goes the ordinary roads."""
        if (snap["@task_flow"] != "1" or snap["@issue"] or snap["@raw"] != "1"
                or not re.fullmatch(r"T[1-9][0-9]{0,9}", snap["@task"])):
            return ""
        pol = self.policy(snap) or ("merged", 0)
        return snap["@task"] if pol[0] == "merged" else ""

    @staticmethod
    def id_over(fid):
        """The window's ID says its work is over (T680, fleet_cfg_work_over's
        first half): the newest result on its ledger here is merged / succeeded /
        failed (fleet_id.py status → done | failed). A report often lands on the ID
        while the record still reads 已接受 — that is «做完» too."""
        if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", fid or ""):
            return False
        env = dict(os.environ)
        env.pop("FLEET_ID_LIVE", None)
        try:
            out = subprocess.run(["python3", str(BIN / "fleet_id.py"), "status", fid], env=env,
                                 capture_output=True, text=True, timeout=15).stdout
            return json.loads(out or "{}").get("state") in ("done", "failed")
        except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
            return False

    def task_closed(self, task):
        """0 closed (收口) · 1 open · 3 unknown — fleet_task_control.py closed,
        or the FLEET_TASK_CLOSED_CMD seam (same contract)."""
        return self.record(task)[0]

    def record(self, task):
        """(rc, asked, parked) of one read of <task>'s record: rc as task_closed;
        asked / parked — its 「问过你」 / 「停放」 hold words (E101: the `asked: 1` /
        `parked: 1` lines fleet_task_control.py closed prints; a seam printing none
        reads as neither). Read once per pass: one window asks it up to three times
        (work_over, the hold words, task_session) and each read is a python + a
        task-record.sh fork chain; this process is one pass, so nothing goes stale."""
        cache = self.__dict__.setdefault("_records", {})
        if task not in cache:
            cache[task] = self._read_record(task)
        return cache[task]

    @staticmethod
    def _read_record(task):
        cmd = os.environ.get("FLEET_TASK_CLOSED_CMD")
        argv = [cmd, task] if cmd else ["python3", str(BIN / "fleet_task_control.py"), "closed", "--task", task]
        try:
            p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return 3, False, False
        lines = (p.stdout or "").splitlines()
        return (p.returncode if p.returncode in (0, 1) else 3), "asked: 1" in lines, "parked: 1" in lines

    def task_session(self, window, snap):
        """Close a task session once its work is over (issue #4897; T680: its ID
        has a final result, or its record is closed): its turn over, nothing
        pending, the grace (--grace, else `merged:<dur>`, else
        FLEET_CLEANUP_MERGED_GRACE, 60 s) past its last turn — history first and
        resumable, the worktree left for worktree-autoclean.sh (which asks the
        record too). An open or unreadable record keeps it."""
        task = self.task_ref(snap)
        wt = snap["@worktree"]
        key = re.search(r"(?:^|-)(scratch)-(\d+)$", Path(wt).name)
        if not key:
            return False
        key = key[1] + "-" + key[2]
        if self.finished(snap) not in ("done", "exited") and snap["@wrap_gone"] != "1" and snap["pane_dead"] != "1":
            return False
        rc = 0 if self.work_over(snap) else (3 if self.task_closed(task) == 3 else 1)
        if rc != 0:
            if not self.args.dry_run and option(self.tm, window, "@reap_key").startswith("task:"):
                clear(self.tm, window)
            self.why = "task-open"
            self.say(window, "skip:task-open" if rc == 1 else "skip:task-unknown", task)
            return False
        if self.held(window, snap, True) or not self.eligible(window, snap, task=True):
            return False
        pol = self.policy(snap)
        if self.args.grace is not None:
            grace = self.args.grace
        else:
            grace = pol[1] if pol and pol[1] else merged_grace_default()
        due = notice(self.tm, window, "task:" + task, int(snap["@claude_state_ts"]) + grace,
                     self.now, self.args.dry_run, tick=min(grace, 60))
        if due > self.now:
            self.why = "timer:%d" % due
            return False
        print("reap-due:%s policy=%s task=%s" % (window, snap["@reap_policy"] or "merged", task),
              file=__import__("sys").stderr)
        if self.args.dry_run:
            print("would-reap-task:" + window + " " + task)
            return False
        history = str(BIN / "fleet-history.sh")
        run("bash", history, "record-closed", "--repo", self.args.repo, "--session", self.args.session,
            "--key", key, "--worktree", wt, "--win", window, "--title", snap["window_name"],
            "--summary", "Automatically closed: task " + task + " is closed")
        if not self.reopens(window, key, wt):
            return False
        if not self.close(window, snap, lambda: self.work_over(snap) and not self.held(window, snap, True)):
            return False  # re-checked right before the close
        print("reaped-task:" + window + " " + task)
        return True

    def branch_prs(self, branch, head):
        """The PRs on <branch> as `[{"state": …}]`. A repo with no GitHub (issue
        #3601, FLEET_FORGE=none) has none — git stands in: one MERGED when the
        branch's work is on the base (fleet_land_check), else none; gh is never run."""
        if self.args.forge == "none":
            return [{"state": "MERGED"}] if self.landed(head or branch) else []
        return json.loads(run("gh", "pr", "list", "--repo", self.args.repo, "--head", branch,
                                 "--state", "all", "--limit", "100", "--json", "state"))

    def landed(self, tip, cwd=None):
        """git's word on whether <tip>'s work is on origin/<base> (fleet_land_check:
        an ancestor, or its whole change squashed / rebased in) — no fetch, no gh."""
        if not tip:
            return False
        return subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh"; fleet_land_check "$2" "$3" "$4" >/dev/null',
                               "idle-land", str(BIN), cwd or self.args.main, tip, "origin/" + self.args.base],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30).returncode == 0

    def on_base(self, tip, cwd):
        """Nothing of <tip>'s is missing from origin/<base>: it IS the base or an
        ancestor of it (issue #3677). fleet_land_check says `open` for a tip that
        never moved off the base — right for "did it land", wrong for "is there
        anything to lose", so the drop asks both."""
        return bool(tip) and subprocess.run(["git", "-C", cwd, "merge-base", "--is-ancestor", tip,
                                             "origin/" + self.args.base], stdout=subprocess.DEVNULL,
                                            stderr=subprocess.DEVNULL, timeout=15).returncode == 0

    def no_pr(self, window, snap):
        """A finished session that no PR will close (issue #1832): done (or
        exited, or its agent gone) for done_no_pr_secs(), its issue CLOSED (a
        scratch has none), no PR on its branch, nothing running for it. Recorded
        in the history first, then its window closed; its worktree is dropped
        only when clean with nothing that is not on the base already — dirty or
        unpushed, it stays on disk (发起人拍板 3: 不干净只关窗口)."""
        if (# an old role's window is an ordinary session (issue #4341)
                snap["@fleet_role"] in ("home", "panel")
                or snap["window_name"] in ("dash", "plan", "backlog", "home")
                or (self.finished(snap) not in ("done", "exited")
                    and snap["@wrap_gone"] != "1" and snap["pane_dead"] != "1")):
            if snap["@reap_skip"] and not self.args.dry_run:
                self.tm("set-option", "-wu", "-t", window, "@reap_skip")
            return False                      # not a finished session: not a candidate
        # A no-repo session is never closed automatically (issue #791); a pass
        # closes only its OWN repo's windows.
        if snap["@norepo"] == "1":
            return False
        if snap["@repo"] and norm_repo(snap["@repo"]) != norm_repo(self.args.repo):
            return False
        if self.args.window_repo and not snap["@repo"]:
            return False                      # repo unknown: skipped, never guessed
        wt = snap["@worktree"]
        issue = self.ticket(snap)
        if wt and Path(wt).resolve() == Path(self.args.main).resolve():
            return False
        m = re.search(r"(?:^|-)(scratch|issue)-(\d+)$", Path(wt).name) if wt else None
        own = snap["@issue"] if re.fullmatch(r"\d{1,9}", snap["@issue"]) else ""
        key = (m[1] + "-" + m[2]) if m else ("issue-" + own if own else "")
        if not key:
            self.say(window, "skip:no-key")
            return False
        stamp = snap["@claude_state_ts"]
        if not stamp.isdigit() or not 0 < int(stamp) <= self.now:
            self.say(window, "skip:state-unknown", key)
            return False
        deadline = int(stamp) + done_no_pr_secs()
        if deadline > self.now:
            self.why = "timer:%d" % deadline
            self.say(window, "skip:done-recent", "%s due=%d" % (key, deadline))
            return False
        transfer = snap["@agent_transfer_until"]
        if transfer and (not transfer.isdigit() or int(transfer) > self.now):
            self.why = "moving"
            self.say(window, "skip:busy", key + " transfer")
            return False
        manifest = snap["@handoff_manifest"]
        if manifest:
            loop = Path(manifest).parent / "loop/state.json"
            if loop.exists() and json.loads(loop.read_text()).get("status") not in ("stopped", "complete", "cancelled"):
                self.say(window, "skip:busy", key + " loop")
                return False
        here = Path.cwd()
        if wt and (here == Path(wt).resolve() or Path(wt).resolve() in here.parents):
            return False
        if os.environ.get("TMUX_PANE") and os.environ.get("TMUX"):
            if self.tm("display-message", "-p", "-t", os.environ["TMUX_PANE"], "#{window_id}") == window:
                return False
        present = bool(wt) and Path(wt).is_dir()
        if present:
            records = run("git", "-C", self.args.main, "worktree", "list", "--porcelain").split("\n\n")
            if not any("worktree " + wt in record.splitlines() for record in records):
                self.say(window, "skip:foreign-worktree", key)
                return False
            held = run("bash", "-c", '. "$1/fleet-lib.sh"; '
                       'metadata=$(fleet_worktree_retire_metadata "$2") || { printf "%s" "$metadata"; exit 0; }; '
                       'if fleet_rotate_lease_held "$2"; then echo held; fi',
                       "idle-reap", str(BIN), wt)
            if held:
                self.why = "moving" if held == "held" else ""
                self.say(window, "skip:busy", key + " " + ("rotation" if held == "held" else held))
                return False
            try:
                branch = run("git", "-C", wt, "symbolic-ref", "-q", "--short", "HEAD")
            except subprocess.CalledProcessError:
                branch = ""                   # detached: no branch, so no PR
            head = run("git", "-C", wt, "rev-parse", "HEAD")
        elif m or own:
            branch, head = key, ""
        else:
            self.say(window, "skip:no-worktree", key)
            return False
        if self.busy(window, snap):
            self.say(window, "skip:busy", key)
            return False
        if subprocess.run(["python3", str(BIN / "fleet-reap-live.py"), window, "--socket-name",
                           self.args.socket_name], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, timeout=30).returncode != 0:
            self.why = "live"
            self.say(window, "skip:live", key)
            return False
        if issue:
            if self.args.forge == "none":
                # No GitHub, no issue to ask (issue #3601): its branch landing is the
                # stand-in until the ticket door answers (EPIC #3570 C2).
                state = "CLOSED" if branch and self.landed(head or branch) else "OPEN"
            else:
                try:
                    got = json.loads(run("gh", "issue", "view", issue,
                                         "--repo", self.args.repo, "--json", "state"))
                    state = got.get("state", "")
                except (ValueError, AttributeError, subprocess.CalledProcessError):
                    state = ""
            if state != "CLOSED":
                self.why = "task-open"
                self.say(window, "skip:issue-open" if state == "OPEN" else "skip:issue-unknown",
                         "%s #%s" % (key, issue))
                return False
        prs = []
        if branch:
            prs = self.branch_prs(branch, head)
            if not isinstance(prs, list):
                return False
            # A PR's head is fleet-cleanup.sh's (merged / closed) or still open —
            # unless its ticket is closed and every PR on it final, with no policy
            # or `merged` (issue #2970): the PR's own reap was missed (a migrate
            # restarted the agent under it), and nothing will come back for it.
            final = (issue and (self.policy(snap) or ("merged",))[0] == "merged"
                     and all(isinstance(p, dict) and p.get("state") in ("MERGED", "CLOSED") for p in prs))
            if prs and not final:
                self.say(window, "skip:has-pr", key + " " + branch)
                return False
        if self.args.dry_run:                 # past its two hours: the one visible tick is all that is left
            print("would-clean:done-no-pr " + window + " " + key)
            return False
        due = notice(self.tm, window, "no-pr:" + (head or key), deadline, self.now)
        if due > self.now:
            return False
        dirty = present and bool(run("git", "-C", wt, "status", "--porcelain"))
        history = str(BIN / "fleet-history.sh")
        run("bash", history, "record-closed", "--repo", self.args.repo, "--session", self.args.session,
            "--key", key, "--worktree", wt or "", "--win", window, "--title", snap["window_name"],
            "--summary", ("Automatically closed: finished, its ticket closed, every PR final (done-no-pr)" if prs
                          else "Automatically closed: finished with no PR (done-no-pr)"))
        if present and not self.reopens(window, key, wt):
            return False
        # Re-checked right before the close: a turn that restarted, moved or
        # committed since the first look has not earned this close.
        if not self.close(window, snap, lambda: not self.busy(window, snap)
                          and not (present and run("git", "-C", wt, "rev-parse", "HEAD") != head)):
            return False
        if not present:
            fate = "worktree=gone"
        elif dirty or run("git", "-C", wt, "status", "--porcelain"):
            fate = "worktree=kept:dirty"
        elif not (self.on_base(head, wt) or self.landed(head, wt)):
            fate = "worktree=kept:unpushed"
        else:
            out = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh"; fleet_worktree_drop "$2" "$3"',
                                  "idle-reap", str(BIN), self.args.main, wt],
                                 capture_output=True, text=True, timeout=60).stdout.strip()
            fate = "worktree=" + (out.split(":", 1)[0] if out else "kept")
        print("cleaned:done-no-pr " + window + " " + key + " " + fate)
        return True

    # Memory pressure only parks through the native gate. All eligible sessions
    # share one tier ordered by last native activity; history, roles and PIN do
    # not affect this order. Parking preserves identity, history and worktrees.
    def room_idle_secs(self):
        v = os.environ.get("FLEET_ADMIT_MAKE_ROOM_IDLE_SECS", "600")
        return int(v) if re.fullmatch(r"\d{1,7}", v) else 600

    def room_tier(self, window, snap, shown, here):
        """1 safely parkable · None held.

        Ordering only: memory pressure never grants permission to archive.
        Old/unknown wrappers wait for the ordinary lifecycle or a safe upgrade.
        """
        if not re.fullmatch(r"[1-9][0-9]*", snap.get("@park_wrap_ver", "")):
            return None
        stamp = snap.get("@claude_state_ts", "")
        transfer = snap.get("@agent_transfer_until", "")
        if (snap.get("@parked") or snap.get("@park_wake") or snap.get("@park_start")
                or snap.get("@wrap_gone") == "1" or snap.get("pane_dead") == "1"
                or snap.get("@fleet_role") in ("home", "panel") or snap.get("@handoff_web") == "1"
                or snap.get("@migrating") or window in shown or window == here
                or (transfer and (not transfer.isdigit() or int(transfer) > self.now))
                or not stamp.isdigit() or not 0 < int(stamp) <= self.now
                or self.finished(snap) not in ("done", "looping")):
            return None
        # Retention protects identity/history, not an idle native process. The
        # single park gate rechecks native input, questions, timers and work.
        return 1  # one tier; plan_room orders by observed native idle age

    @staticmethod
    def tree_rss():
        """{pid: (ppid, rss KB)} for every process — one ps."""
        out = {}
        try:
            text = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,rss="], capture_output=True,
                                  text=True, timeout=15).stdout
        except (OSError, subprocess.SubprocessError):
            return out
        for line in text.splitlines():
            f = line.split()
            if len(f) == 3 and all(x.isdigit() for x in f):
                out[int(f[0])] = (int(f[1]), int(f[2]))
        return out

    @staticmethod
    def pane_mb(procs, pid):
        """The resident MB of <pid> and everything under it (0 unreadable)."""
        if not pid.isdigit():
            return 0
        kids = {}
        for p, (pp, _) in procs.items():
            kids.setdefault(pp, []).append(p)
        todo, kb, seen = [int(pid)], 0, set()
        while todo:
            p = todo.pop()
            if p in seen:
                continue
            seen.add(p)
            kb += procs.get(p, (0, 0))[1]
            todo.extend(kids.get(p, []))
        return kb // 1024

    def plan_room(self):
        """One line a window that may be safely parked: `<tier>\t<last turn>\t<MB>\t<window>`."""
        try:
            shown = set(self.tm("list-clients", "-F", "#{window_id}").split())
        except (OSError, subprocess.SubprocessError):
            return 0                          # cannot tell who looks: fold nothing
        here = ""
        if os.environ.get("TMUX_PANE") and os.environ.get("TMUX"):
            try:
                here = self.tm("display-message", "-p", "-t", os.environ["TMUX_PANE"], "#{window_id}")
            except (OSError, subprocess.SubprocessError):
                here = ""
        procs = self.tree_rss()
        for window in self.tm("list-windows", "-t", self.args.session, "-F", "#{window_id}").split():
            if not re.fullmatch(r"@\d+", window):
                continue
            try:
                snap = self.snapshot(window)
                tier = self.room_tier(window, snap, shown, here)
            except (OSError, ValueError, subprocess.SubprocessError):
                continue
            if tier is not None:
                print("%d\t%s\t%d\t%s" % (tier, snap["@claude_state_ts"], self.pane_mb(procs, snap["pane_pid"]), window))
        return 0

    def fold(self, window):
        """Keep the --fold argument, but memory make-room only safely parks.

        Completion/archive belongs to the ordinary reaper, never this request.
        """
        snap = self.snapshot(window)
        here = ""
        if os.environ.get("TMUX_PANE") and os.environ.get("TMUX"):
            here = self.tm("display-message", "-p", "-t", os.environ["TMUX_PANE"], "#{window_id}")
        shown = set(self.tm("list-clients", "-F", "#{window_id}").split())
        if self.room_tier(window, snap, shown, here) is None:
            self.say(window, "skip:fold-gate")
            return False
        if snap["@norepo"] != "1" and (not snap["@repo"] or norm_repo(snap["@repo"]) != norm_repo(self.args.repo)):
            return False
        if self.args.dry_run:
            print("would-park-room:" + window)
            return False
        before = self.tree_rss()
        pid = snap["pane_pid"]
        command = os.environ.get("FLEET_SESSION_GATE_CMD")
        out = run(*(command.split() if command else ["python3", str(BIN / "fleet_session_gate.py")]),
                  "park", "--fid", snap["@fleet_id"], "--why", "memory")
        result = json.loads(out or "{}")
        current = self.snapshot(window)
        if (not result.get("ok") or current["@fleet_id"] != snap["@fleet_id"]
                or not current.get("@parked") or not current.get("@park_held")
                or current.get("@park_wake") or current.get("@park_start")
                or option(self.tm, window, "@park_relay")):
            return False
        self.tm("set-option", "-w", "-t", window, "@park_waiting", "1" if self.is_waiting(snap) else "0")
        after = self.tree_rss()
        known = pid.isdigit() and int(pid) in before and int(pid) in after
        saved = str(max(0, self.pane_mb(before, pid) - self.pane_mb(after, pid))) if known else "unknown"
        print("parked-room:%s mb=%s" % (window, saved))
        return True

    def main(self):
        if self.args.plan_room:
            return self.plan_room()
        if self.args.fold:
            if not re.fullmatch(r"@\d+", self.args.only):
                return 2
            modern = self.snapshot(self.args.only).get("@park_wrap_ver")
            if not modern and (not self.args.repo or not (Path(self.args.main) / ".git").exists()):
                return 2
            try:
                return 0 if self.fold(self.args.only) else 1
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                print(f"fold deferred {self.args.only}: {exc}", file=__import__("sys").stderr)
                return 1
        self._park_only = (getattr(self.args, "park_only", False) or not self.idle or not self.args.repo
                           or not (Path(self.args.main) / ".git").is_dir())
        count = 0
        windows = self.tm("list-windows", "-t", self.args.session, "-F", "#{window_id}").split()
        if self.args.only:
            windows = [w for w in windows if w == self.args.only]
        if self.mem_tight:
            ages = self.tm("list-windows", "-t", self.args.session, "-F", "#{window_id}\t#{@claude_state_ts}")
            stamps = {f[0]: int(f[1]) for line in ages.splitlines()
                      if len(f := line.split("\t")) == 2 and f[1].isdigit()}
            windows.sort(key=lambda w: stamps.get(w, self.now))
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
    for name in ("session", "socket-name"):
        p.add_argument("--" + name, required=True)
    for name in ("main", "repo", "base"):          # not needed by --plan-room
        p.add_argument("--" + name, default="")
    p.add_argument("--limit", type=int, default=4)
    p.add_argument("--park-only", action="store_true", help="one login-wide parking pass, including zero-repo logins")
    p.add_argument("--skip-park", action="store_true", help="ordinary repo reaping after the login-wide parking pass")
    p.add_argument("--forge", default="github", choices=("github", "none"),
                   help="none = the repo is not on GitHub: no gh, git says what landed (issue #3601)")
    p.add_argument("--window-repo", action="store_true",
                   help="only windows whose @repo is --repo (multi-repo fleet)")
    p.add_argument("--only", default="", help="this one window (@id) — the --now watcher's pass (T680)")
    p.add_argument("--grace", type=int, default=None,
                   help="a task session's grace in seconds, over its policy's (T680: --now --after)")
    p.add_argument("--plan-room", action="store_true",
                   help="list the windows --make-room may park (T695): tier, last turn, MB, window")
    p.add_argument("--fold", action="store_true", help="safely park the --only window to make room (T695)")
    p.add_argument("--dry-run", action="store_true")
    return Cleaner(p.parse_args()).main()


if __name__ == "__main__":
    raise SystemExit(main())
