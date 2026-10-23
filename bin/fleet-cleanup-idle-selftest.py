#!/usr/bin/env python3
# selftest-parts: 4
# selftest-part: 4 DispatchedSession.test_over_closes_after_its_grace_keeping_the_worktree DoneNoPr.test_codex_worker_closes_like_a_claude_one DoneNoPr.test_native_owned_worktree_keeps_window_and_data DoneNoPr.test_unpushed_commit_keeps_the_worktree
# selftest-part: 5 HoldsAndWhy.test_a_background_job_holds_a_done_task_past_old_grace HoldsAndWhy.test_waiting_on_its_person_parks_after_its_hours HomeReap.test_no_policy_and_keep_hold_but_pin_is_only_order TestIdentity.test_closes_a_test_session_past_its_policy_and_nothing_else
# selftest-part: 6 ParkTable.test_finished_probe_keeps_its_one_minute_policy PolicyGrammar.test_origin_table_and_the_policy_in_force RoundTrip.test_real_close_and_restore
# selftest-part: 7 PinIsOrder.test_first_pass_does_not_migrate_pin_to_keep ReapPolicy.test_keep_and_merged_are_never_this_pass StuckReaps.test_the_agents_finished_word_outranks_a_looping_stamp
# selftest-part: 8 ParkTable.test_activity_and_keep_hold_expiration RoundTrip.test_codex_unknown_or_active_native_turn_is_kept TaskSession.test_now_watcher_closes_about_its_grace_after_the_turn
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""Policy tests and a real isolated tmux -> history -> restore round trip."""
import time
RIG_IMPORT_START = time.monotonic()
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
BIN = (Path(sys.argv.pop(1)) if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else Path(__file__).absolute().parent)
sys.path.insert(0, str(BIN))
from fleet_reap_notice import notice
spec = importlib.util.spec_from_file_location("idle", BIN / "fleet-cleanup-idle.py")
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)


class RigBudgetExceeded(RuntimeError):
    """Incomplete fixture evidence, never a production timeout or a PASS."""


class RigCalls:
    """Only this selftest's calls; one allowance for part 4 or its setup example.

    40/50 are measured from this Python process's start/import, NOT the normal
    runner's start. External /usr/bin/time remains the complete-entry gate.
    Original 20s call limits remain ceilings, not fresh per-command allowances.
    No runner alarm, signal handler, production timeout or outer grace changes.
    """
    def __init__(self, start, mode="normal-part4"):
        self.start = start
        self.mode = mode
        self.children = []
        self.errors = []
        self.receipts = []
        self.secondary_errors = []
        self.cleanup_receipts = []
        self.servers = []  # actual foreground tmux handles, distinct from clients

    @staticmethod
    def error_text(exc):
        try:
            return repr(exc)[:1024]
        except BaseException:
            return "<exception repr unavailable>"

    def diagnostic_error(self, phase, exc):
        # No diagnostic I/O here: stderr itself may be the failed resource.
        item = dict(phase=phase, error_type=type(exc).__name__, detail=self.error_text(exc))
        self.secondary_errors.append(item)
        self.errors.append("diagnostic evidence incomplete: " + repr(item))

    def remaining(self, cleanup=False):
        left = self.start + (50 if cleanup else 40) - time.monotonic()
        if left <= 0:
            raise RigBudgetExceeded("shared fixture %s allowance exhausted" %
                                    ("cleanup" if cleanup else "body"))
        return left

    @staticmethod
    def server_absent(pid):
        # Independent visibility check; this never substitutes for an owned wait.
        try:
            os.kill(pid, 0)
            return False
        except ProcessLookupError:
            return True

    def run(self, args, env, *, cleanup=False, check=True):
        limit = min(20, self.remaining(cleanup))
        record = dict(event="idle-rig-child", argv=list(args), owner=os.getpid(),
                      born=time.monotonic(), shared_start=self.start,
                      phase="cleanup" if cleanup else "body", timeout=limit,
                      joined=False, group_policy="inherits entry group; signal direct Popen only")
        # Files avoid a descendant retaining a PIPE and blocking communicate().
        # They are anonymous, close before return and never become cleanup targets.
        out = err = p = None
        stdout = stderr = None
        try:
            out = tempfile.TemporaryFile()
            err = tempfile.TemporaryFile()
            # Retain the original entry group: runner TERM/KILL/backstop still
            # reaches this call. Never create an escape group or signal Perl.
            p = subprocess.Popen(args, env=env, stdout=out, stderr=err)
            self.children.append(p)  # actual Popen, not a sampled/reconstructed PID
            record.update(pid=p.pid, parent_pgid=os.getpgrp())
            try:
                p.wait(timeout=min(limit, self.remaining(cleanup)))
            except BaseException as exc:
                # Only the actual unreaped Popen child; no group/descendant kill.
                # A timeout is incomplete evidence even if this child is joined.
                self.errors.append("call interrupted; descendant exit not inferred: " + self.error_text(exc))
                try:
                    if p.poll() is None:
                        p.terminate()
                        record["term_completed"] = time.monotonic()
                        try:
                            p.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            # Never shorten the five seconds to fit a nominal budget.
                            if time.monotonic() < record["term_completed"] + 5:
                                raise RuntimeError("direct child grace incomplete")
                            record["kill_time"] = time.monotonic()
                            p.kill()
                            p.wait(timeout=2)
                    else:
                        p.wait()
                except BaseException as join_exc:
                    self.errors.append("direct child stop/join incomplete: " + self.error_text(join_exc))
                raise  # same object and traceback; guarded diagnostics run below
            if check and p.returncode:
                # Establish the command failure before any output read/close.
                # finally fills whichever streams were actually recovered.
                raise subprocess.CalledProcessError(p.returncode, args)
        finally:
            original = sys.exc_info()[1]
            record.update(ended=time.monotonic(), rc=None if p is None else p.returncode,
                          joined=p is not None and p.returncode is not None)
            values = {}
            for name, f in (("stdout", out), ("stderr", err)):
                if f is None:
                    continue
                phase = name + ".tell"
                try:
                    size = f.tell()
                    record[name + "_bytes"] = size
                    phase = name + ".seek"
                    f.seek(0)
                    phase = name + ".read"
                    values[name] = f.read(65536).decode("utf-8", "replace")
                    if size > 65536:
                        self.errors.append("command output truncated: %d bytes" % size)
                except BaseException as read_exc:
                    self.diagnostic_error(phase, read_exc)
                finally:
                    try:
                        f.close()
                        record[name + "_closed"] = True
                    except BaseException as close_exc:
                        record[name + "_closed"] = False
                        self.diagnostic_error(name + ".close", close_exc)
            stdout, stderr = values.get("stdout"), values.get("stderr")
            if isinstance(original, (subprocess.TimeoutExpired, subprocess.CalledProcessError)):
                original.output, original.stderr = stdout, stderr
            if p is not None and not record["joined"]:
                self.errors.append("owned direct call exit unproven: %s" % p.pid)
            record["secondary_errors"] = list(self.secondary_errors)
            self.receipts.append(record)
            try:
                print("idle-rig-child " + json.dumps(record, ensure_ascii=True),
                      file=sys.stderr, flush=True)
            except BaseException as log_exc:
                self.diagnostic_error("child-receipt.output", log_exc)
                record["secondary_errors"] = list(self.secondary_errors)
            # Never raise a side error over a pending primary exception. Without
            # one, incomplete evidence still fails and prevents fixture deletion.
            if original is None and self.errors:
                raise RuntimeError("fixture child evidence incomplete: " + repr(self.errors))
        self.remaining(cleanup)
        return subprocess.CompletedProcess(args, p.returncode, stdout, stderr)

    def finish(self):
        original = sys.exc_info()[1]
        record = dict(event="idle-rig-calls-final", start=self.start,
                      ended=time.monotonic(), errors=self.errors,
                      interpreter=dict(executable=sys.executable, version=sys.version,
                                       subprocess_source=subprocess.__file__),
                      secondary_errors=self.secondary_errors,
                      fixture_cleanup=[{key: value for key, value in item.items()
                                        if key not in ("stdout", "stderr")}
                                       for item in self.cleanup_receipts],
                      children=len(self.children),
                      all_joined=all(p.returncode is not None for p in self.children),
                      servers=[s.record for s in self.servers],
                      all_servers_joined=all(s.record.get("joined") is True
                                             for s in self.servers),
                      group_policy="entry group unchanged; no descendant-join inference")
        record["within_internal_cleanup_allowance"] = record["ended"] < self.start + 50
        self.final_receipt = record
        try:
            print("idle-rig-calls-final " + json.dumps(record), file=sys.stderr, flush=True)
        except BaseException as log_exc:
            self.diagnostic_error("calls-final.output", log_exc)
        if (self.errors or not record["all_joined"] or not record["all_servers_joined"]
                or not record["within_internal_cleanup_allowance"]):
            # A pending nonzero failure stays the primary. SystemExit(0) is a
            # success path and cannot turn missing diagnostics into acceptance.
            if original is None or (isinstance(original, SystemExit)
                                    and original.code in (None, 0)):
                raise RuntimeError("fixture command/cleanup evidence incomplete")
        return record


class OwnedRigServer:
    """One isolated fixture server, using tmux's native -D/Popen wait contract.

    -D accepts no command and temporarily disables exit-empty. The original
    new-session client still creates the session; activate() restores and reads
    back the default before any test body. No background observer or new group.
    """
    def __init__(self, calls, label, env):
        self.calls, self.label, self.env = calls, label, env
        self.process = None
        self.streams = {}
        self.socket = None
        self.expected = None
        self.parent_fd = None
        self.closed = False
        self.record = dict(event="idle-rig-server", owner=os.getpid(), label=label,
                           shared_start=calls.start, joined=False,
                           group_policy="entry group unchanged; actual direct Popen only")
        calls.servers.append(self)  # register before files, Popen or polling

    def start(self):
        try:
            self._start()
        except BaseException as exc:
            self.record["start_error"] = self.calls.error_text(exc)
            self.calls.errors.append("foreground startup incomplete: " + self.calls.error_text(exc))
            raise

    def _start(self):
        end = time.monotonic() + min(20, self.calls.remaining())
        if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
            raise RuntimeError("unknown SIGCHLD contract; refuse server creation")
        base = self.env.get("TMUX_TMPDIR")
        if not base or not os.path.isabs(base):
            raise RuntimeError("owned server needs the recorded private TMUX_TMPDIR")
        if (not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW") or
                os.stat not in os.supports_dir_fd or os.unlink not in os.supports_dir_fd or
                os.stat not in os.supports_follow_symlinks):
            raise RuntimeError("descriptor-relative socket ownership contract unavailable")
        self.record["private_root"] = self.private_directory(base)
        # Documented -L layout, NOT a discovered or guessed cleanup target.
        self.expected = os.path.join(base, "tmux-%d" % os.getuid(), self.label)
        if len(os.fsencode(self.expected)) > 1024 or os.path.lexists(self.expected):
            raise RuntimeError("private socket already present/invalid; refuse startup")
        self.record.update(expected_socket=self.expected, executable=shutil.which("tmux", path=self.env.get("PATH")),
                           sigchld="SIG_DFL", born=time.monotonic())
        for name in ("stdout", "stderr"):
            self.streams[name] = tempfile.TemporaryFile()
        args = ["tmux", "-D", "-L", self.label, "-f", "/dev/null"]
        self.calls.remaining()
        self.process = subprocess.Popen(args, env=self.env, stdin=subprocess.DEVNULL,
                                        stdout=self.streams["stdout"], stderr=self.streams["stderr"])
        self.record.update(argv=args, pid=self.process.pid, parent_pgid=os.getpgrp(), process_created=True)
        print("idle-rig-server-start " + json.dumps(self.record), file=sys.stderr, flush=True)
        while not os.path.lexists(self.expected):
            if self.process.poll() is not None:
                raise RuntimeError("foreground server exited before its socket")
            left = min(end - time.monotonic(), self.calls.remaining())
            if left <= 0:
                raise subprocess.TimeoutExpired(args, 20)
            time.sleep(min(0.01, left))
        parent = self.private_directory(os.path.dirname(self.expected))
        if parent["canonical"] != os.path.join(self.record["private_root"]["canonical"],
                                               "tmux-%d" % os.getuid()):
            raise RuntimeError("socket parent is outside the recorded private directory")
        self.record["socket_parent"] = parent
        self.parent_fd = os.open(parent["canonical"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.record["parent_fd"] = self.parent_fd
        self.check_directories()
        if self.process.poll() is not None:
            raise RuntimeError("foreground socket type/lifecycle unknown")
        self.record["startup_socket"] = self.socket_identity(self.expected)

    @staticmethod
    def node_identity(st):
        return dict(dev=st.st_dev, inode=st.st_ino, mode=st.st_mode,
                    uid=st.st_uid, gid=st.st_gid)

    @classmethod
    def private_directory(cls, raw):
        if not os.path.isabs(raw) or len(os.fsencode(raw)) > 1024:
            raise RuntimeError("unknown private directory path")
        canonical = os.path.realpath(raw)
        st = os.lstat(raw)
        identity = cls.node_identity(st)
        if (not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid() or
                st.st_mode & 0o077 or st.st_mode & 0o300 != 0o300 or
                cls.node_identity(os.lstat(canonical)) != identity):
            raise RuntimeError("private directory type/owner/mode/alias unknown")
        return dict(raw=raw, canonical=canonical, **identity)

    def check_directories(self):
        for key in ("private_root", "socket_parent"):
            expected = self.record[key]
            if self.private_directory(expected["raw"]) != expected:
                raise RuntimeError("private socket directory identity changed; retain")
        held = self.node_identity(os.fstat(self.parent_fd))
        if any(held[k] != self.record["socket_parent"][k] for k in held):
            raise RuntimeError("held socket directory does not match its path; retain")

    def socket_identity(self, raw):
        canonical = os.path.realpath(raw)
        if (os.path.basename(raw) != self.label or
                canonical != os.path.join(self.record["socket_parent"]["canonical"], self.label)):
            raise RuntimeError("socket raw/canonical binding changed; retain")
        st = os.stat(self.label, dir_fd=self.parent_fd, follow_symlinks=False)
        identity = self.node_identity(st)
        if (not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.geteuid() or
                self.node_identity(os.lstat(raw)) != identity or
                self.node_identity(os.lstat(canonical)) != identity):
            raise RuntimeError("socket type/owner/aliases changed; retain")
        return dict(raw=raw, canonical=canonical, ctime_ns=st.st_ctime_ns, **identity)

    def bind(self, socket):
        observed = self.record["startup_socket"]
        self.check_directories()
        current = self.socket_identity(socket["raw"])
        if (socket["server_pid"] != self.process.pid or
                any(socket[k] != current[k] for k in current if k in socket) or
                any(current[k] != observed[k] for k in observed if k != "raw")):
            raise RuntimeError("tmux server/socket does not match actual Popen; retain evidence")
        self.record["server_pgid"] = os.getpgid(self.process.pid)
        if self.record["server_pgid"] != self.record["parent_pgid"]:
            raise RuntimeError("foreground server left the entry group; retain evidence")
        # Snapshot the binding: the control caller later adds its finally
        # receipt to its own dictionary; it must not mutate this identity.
        self.socket = dict(socket, **{k: v for k, v in current.items() if k not in socket})
        self.record["socket"] = self.socket
        return dict(self.socket)

    def remove_owned_socket(self):
        """Only after real successful wait and client joins, never by PID alone.

        The held directory confines unlink to this fixture's one basename.
        Checks + unlink are NOT atomic CAS: an uncooperative same-UID writer
        can replace that name between them. The test's private writer contract
        excludes such concurrent mutation; observed drift always refuses.
        """
        item = dict(outcome="pending", phase="exit-and-client-gate", unlink_attempted=False,
                    complete=False, started=time.monotonic())
        self.record["socket_cleanup"] = item
        p = self.process
        if (p is None or p.returncode != 0 or self.record.get("joined") is not True or
                "wait_ended" not in self.record or not self.calls.server_absent(p.pid) or
                self.socket is None or self.parent_fd is None or
                any(child.returncode is None for child in self.calls.children) or self.calls.errors):
            raise RuntimeError("socket unlink lacks successful owned wait/client/exit evidence")
        item.update(server_joined=True, server_pid_absent=True,
                    clients_joined=len(self.calls.children), phase="directory-identity")
        self.check_directories()
        socket = self.socket
        raw_present = os.path.lexists(socket["raw"])
        canonical_present = os.path.lexists(socket["canonical"])
        item.update(raw_present_before=raw_present, canonical_present_before=canonical_present)
        if raw_present != canonical_present:
            raise RuntimeError("socket aliases disagree; refuse unlink")
        if raw_present:
            item["phase"] = "socket-identity"
            current = self.socket_identity(socket["raw"])
            if any(current[k] != socket[k] for k in current):
                raise RuntimeError("original socket identity changed; refuse unlink")
            self.check_directories()
            # Last descriptor-relative no-follow check. This narrows the race;
            # it does not make unlinkat conditional on this dev/inode.
            st = os.stat(self.label, dir_fd=self.parent_fd, follow_symlinks=False)
            if (self.node_identity(st) != {k: socket[k] for k in self.node_identity(st)} or
                    st.st_ctime_ns != socket["ctime_ns"]):
                raise RuntimeError("socket changed before unlink; retain")
            self.calls.remaining(cleanup=True)
            item.update(phase="unlink", unlink_attempted=True)
            os.unlink(self.label, dir_fd=self.parent_fd)
            item["outcome"] = "removed_owned_socket"
        else:
            # Absence must also hold within the retained original parent.
            try:
                os.stat(self.label, dir_fd=self.parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                item["outcome"] = "already_absent"
            else:
                raise RuntimeError("socket absent by path but present in original parent")
        item["phase"] = "after-unlink-or-absence"
        self.check_directories()
        self.record["raw_socket_present"] = os.path.lexists(socket["raw"])
        self.record["canonical_socket_present"] = os.path.lexists(socket["canonical"])
        self.record["server_pid_absent"] = self.calls.server_absent(p.pid)
        if (self.record["raw_socket_present"] or self.record["canonical_socket_present"] or
                not self.record["server_pid_absent"]):
            raise RuntimeError("socket/server evidence changed after cleanup; retain")
        item.update(phase="complete", complete=True, ended=time.monotonic())

    def activate(self):
        # Restore -f /dev/null's original exit-empty default after new-session.
        self.calls.run(["tmux", "-N", "-L", self.label, "set-option", "-s", "exit-empty", "on"], self.env)
        value = self.calls.run(["tmux", "-N", "-L", self.label, "show-options", "-sv", "exit-empty"], self.env)
        self.record["exit_empty"] = value.stdout.strip()
        if self.record["exit_empty"] != "on":
            raise RuntimeError("original exit-empty semantics not restored")

    def close(self):
        if self.closed:
            raise RuntimeError("owned server cleanup invoked twice")
        self.closed = True
        p = self.process
        try:
            if p is None:
                # No Popen exists: no PID/socket deletion is authorized.
                self.record.update(joined=True, process_created=False)
                return self.record
            if self.socket is None:
                raise RuntimeError("server identity not bound; retain socket/fixture")
            socket = self.socket
            self.check_directories()
            if p.poll() is None and os.path.lexists(socket["raw"]):
                current = self.socket_identity(socket["raw"])
                if any(current[k] != socket[k] for k in current):
                    raise RuntimeError("owned socket replaced; refuse socket command")
                client = self.calls.run(["tmux", "-S", socket["raw"], "kill-server"],
                                        self.env, cleanup=True, check=True)
                self.record["kill_client_rc"] = client.returncode
            self.record["wait_started"] = time.monotonic()
            p.wait(timeout=min(20, self.calls.remaining(cleanup=True)))
            self.record.update(wait_ended=time.monotonic(), joined=True, rc=p.returncode)
            # Process exit does not unlink a Unix-domain socket name. Only the
            # creation/parent identity and all real joins permit that next step.
            self.record["server_pid_absent"] = self.calls.server_absent(p.pid)
            if p.returncode != 0 or not self.record["server_pid_absent"]:
                raise RuntimeError("owned server exit not established; retain socket")
            self.remove_owned_socket()
            self.calls.remaining(cleanup=True)
        except BaseException as exc:
            self.record["error"] = self.calls.error_text(exc)
            if "socket_cleanup" in self.record:
                self.record["socket_cleanup"]["error"] = self.calls.error_text(exc)
            self.calls.errors.append("owned server cleanup incomplete: " + self.calls.error_text(exc))
            try:
                # Only the actual still-unreaped child. This is failure cleanup,
                # not acceptance or authority to delete an unknown socket.
                if p is not None:
                    if p.poll() is None:
                        p.terminate()
                        self.record["term_completed"] = time.monotonic()
                        try:
                            p.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            if time.monotonic() < self.record["term_completed"] + 5:
                                raise RuntimeError("foreground child grace incomplete")
                            self.record["kill_time"] = time.monotonic()
                            p.kill()
                            p.wait(timeout=2)
                    else:
                        p.wait()
            except BaseException as stop_exc:
                self.calls.diagnostic_error("server.stop-wait", stop_exc)
            raise  # keep the original failure object/traceback
        finally:
            original = sys.exc_info()[1]
            self.record.update(ended=time.monotonic(), rc=None if p is None else p.returncode,
                               joined=p is None or p.returncode is not None)
            for name, stream in self.streams.items():
                phase = "server." + name + ".tell"
                try:
                    size = stream.tell()
                    self.record[name + "_bytes"] = size
                    phase = "server." + name + ".seek"
                    stream.seek(0)
                    phase = "server." + name + ".read"
                    self.record[name] = stream.read(65536).decode("utf-8", "replace")
                    if size > 65536:
                        raise RuntimeError("foreground server output truncated")
                except BaseException as read_exc:
                    self.calls.diagnostic_error(phase, read_exc)
                finally:
                    try:
                        stream.close()
                        self.record[name + "_closed"] = True
                    except BaseException as close_exc:
                        self.record[name + "_closed"] = False
                        self.calls.diagnostic_error("server." + name + ".close", close_exc)
            if self.parent_fd is not None:
                self.record["parent_fd_close_attempted"] = True
                try:
                    os.close(self.parent_fd)
                    self.parent_fd = None
                    self.record["parent_fd_closed"] = True
                except BaseException as close_exc:
                    self.record["parent_fd_closed"] = False
                    self.calls.diagnostic_error("server.parent-fd.close", close_exc)
            try:
                print("idle-rig-server-final " + json.dumps(self.record), file=sys.stderr, flush=True)
            except BaseException as log_exc:
                self.calls.diagnostic_error("server-final.output", log_exc)
            if original is None and self.calls.errors:
                raise RuntimeError("server evidence incomplete; retain fixture")
        return self.record


# Other parts/all retain their existing call path. The controlled example installs
# its own RigCalls with the example's earlier start; it never resets per Rig/case.
RIG_CALLS = RigCalls(RIG_IMPORT_START) if os.environ.get("SELFTEST_PART") == "4/4" else None


class NoticeTests(unittest.TestCase):
    def test_notice_has_visible_tick_and_resets_on_activity_or_stale_tick(self):
        opts = {"@claude_state": "done", "@claude_state_ts": "100"}
        def tm(*args):
            if args[0] == "display-message":
                return opts.get(args[-1][2:-1], "")
            if args[1] == "-wu":
                opts.pop(args[-1], None)
            else:
                opts[args[-2]] = args[-1]
            return ""
        self.assertEqual(notice(tm, "@1", "raw", 1000, 2000), 2060)
        self.assertEqual(notice(tm, "@1", "raw", 1000, 2060), 2060)
        opts["@claude_state_ts"] = "2050"
        self.assertEqual(notice(tm, "@1", "raw", 1000, 2061), 2121)
        self.assertEqual(notice(tm, "@1", "raw", 1000, 3000), 3060)
        before = dict(opts)
        self.assertEqual(notice(tm, "@1", "raw", 1000, 3060, dry=True), 3060)
        self.assertEqual(opts, before)
        opts["@claude_state"] = "working"
        with self.assertRaises(ValueError):
            notice(tm, "@1", "raw", 1000, 3100)
        self.assertNotIn("@reap_due", opts)

    def test_hold_notice_has_no_countdown_and_yields_to_one(self):
        # Issue #1156: a merged PR whose bound issue is still open is HELD, not due.
        opts = {"@claude_state": "done", "@claude_state_ts": "100"}
        def tm(*args):
            if args[0] == "display-message":
                return opts.get(args[-1][2:-1], "")
            if args[1] == "-wu":
                opts.pop(args[-1], None)
            else:
                opts[args[-2]] = args[-1]
            return ""
        self.assertEqual(notice(tm, "@1", "issue-open:9:8", 0, 500, dry=True, hold="x"), "hold")
        self.assertNotIn("@reap_due", opts)
        self.assertEqual(notice(tm, "@1", "issue-open:9:8", 0, 500, hold="PR #9 merged"), "hold")
        self.assertEqual((opts["@reap_due"], opts["@reap_seen"], opts["@reap_state_ts"],
                          opts["@reap_hold"]), ("hold", "500", "100", "PR #9 merged"))
        # the issue closed → an ordinary countdown takes over, with a fresh visible tick
        self.assertEqual(notice(tm, "@1", "merged:9:abc", 0, 560), 620)
        self.assertNotIn("@reap_hold", opts)
        opts["@claude_state"] = "working"
        with self.assertRaises(ValueError):
            notice(tm, "@1", "issue-open:9:8", 0, 600, hold="x")
        self.assertNotIn("@reap_hold", opts)


class Rig(unittest.TestCase):
    """An isolated tmux server + repo + scratch worktree (no tests of its own)."""
    last_cleanup = None

    def setUp(self):
        self.phase = "setUp"
        self.calls = RIG_CALLS
        self.socket_record = None
        self.server = None
        self.server_creation_attempted = False
        self.cleanup_calls = 0
        self.root_identity = None
        self.previous_cleanup = Rig.last_cleanup
        if self.calls is not None:
            # Admission BEFORE creating another root. A failed/expired entry
            # cannot accumulate unidentifiable later fixtures via unittest.
            self.calls.remaining()
            if self.calls.errors:
                raise RuntimeError("prior fixture evidence incomplete; refuse new fixture")
        self.tmp = tempfile.TemporaryDirectory(prefix="idle-reap-")
        # unittest skips tearDown if setUp fails. Register before identity I/O;
        # a failed identity capture retains this exact directory, never guesses.
        self.addCleanup(self.cleanup_rig)
        self.root = Path(self.tmp.name).resolve()
        root_lstat = os.lstat(self.tmp.name)
        root_stat = self.root.stat()
        if not stat.S_ISDIR(root_lstat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
            raise RuntimeError("unknown fixture directory type")
        self.root_identity = (root_stat.st_dev, root_stat.st_ino)
        if self.calls is not None:
            try:
                self.diagnostic(root_created=dict(raw=self.tmp.name, canonical=str(self.root),
                                dev=root_stat.st_dev, inode=root_stat.st_ino,
                                lstat_dev=root_lstat.st_dev, lstat_inode=root_lstat.st_ino,
                                lstat_mode=root_lstat.st_mode, stat_mode=root_stat.st_mode),
                                shared_start=self.calls.start)
            except BaseException as exc:
                self.calls.diagnostic_error("root-created.output", exc)
                raise
        self.main = self.root / "main"
        self.wt = self.root / "repo-scratch-7"
        self.label = "idle-reap-test-" + str(os.getpid())
        self.env = dict(os.environ)
        self.env.pop("TMUX", None)
        self.env.pop("TMUX_PANE", None)
        self.env.update(FLEET_CONF_DIR=str(self.root / "conf"),
                        FLEET_HISTORY_LEDGER=str(self.root / "ledger.tsv"),
                        CLAUDE_PROJECTS_DIR=str(self.root / "projects"),
                        FLEET_REAP_MIN_AGE="0")
        if self.calls is not None:
            self.calls.remaining()
            resources = []
            for name, value in (("WORK", self.tmp.name),
                                ("TMUX_TMPDIR", self.env.get("TMUX_TMPDIR")),
                                ("FLEET_SELFTEST_ROOT", self.env.get("FLEET_SELFTEST_ROOT"))):
                item = dict(name=name, raw=value, status="missing")
                if value and os.path.isabs(value) and len(os.fsencode(value)) <= 1024:
                    st = os.stat(value)
                    item.update(canonical=os.path.realpath(value), dev=st.st_dev,
                                inode=st.st_ino, status="observed")
                resources.append(item)
            self.diagnostic(resources=resources, call_mode=self.calls.mode,
                            shared_start=self.calls.start)
            required = resources if self.calls.mode == "normal-part4" else resources[:2]
            if any(item["status"] != "observed" for item in required):
                raise RuntimeError("fixture or runner resource identity missing")
        (self.root / "conf").mkdir()
        self.ibin = self.root / "install/bin"
        self.ibin.mkdir(parents=True)
        for p in BIN.iterdir():
            if p.is_file():
                (self.ibin / p.name).symlink_to(p)
        launcher = self.ibin / "fleet-claude.sh"
        launcher.unlink()
        launcher.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > " + shlex.quote(str(self.root / "resume-args")) + "\nexec sleep 90\n")
        launcher.chmod(0o755)
        fake = self.root / "fake"
        fake.mkdir()
        gh = fake / "gh"
        gh.write_text("#!/bin/sh\ncat " + shlex.quote(str(self.root / "prs.json")) + "\n")
        gh.chmod(0o755)
        self.env["PATH"] = str(fake) + ":" + self.env["PATH"]
        (self.root / "prs.json").write_text("[]")
        self.call("git", "init", "-q", "-b", "master", str(self.main))
        self.call("git", "-C", str(self.main), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                  "commit", "-qm", "base", "--allow-empty")
        self.call("git", "-C", str(self.main), "worktree", "add", "-qb", "scratch-7", str(self.wt))
        head = self.call("git", "-C", str(self.main), "rev-parse", "HEAD").strip()
        self.call("git", "-C", str(self.main), "update-ref", "refs/remotes/origin/master", head)
        self.conf = self.root / "conf/fleets" / self.label / "conf"
        self.conf.parent.mkdir(parents=True)
        self.conf.write_text('FLEET_REAP_MIN_AGE=0\n')
        repos = self.conf.parent / "repos"   # every repo is an overlay (#1937, #4806)
        repos.mkdir()
        (repos / "acme-repo.conf").write_text(
            f'FLEET_REPO=acme/repo\nFLEET_MAIN={shlex.quote(str(self.main))}\n')
        (repos / ".order").write_text("acme-repo\n")
        self.tm("-f", "/dev/null", "new-session", "-d", "-s", self.label, "-c", str(self.root), "sleep 90")
        self.win = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", self.label,
                           "-c", str(self.wt), "sleep 90").strip()
        for key, value in {"@raw": "1", "@worktree": str(self.wt), "@claude_state": "done",
                           "@fleet_id": "00000007-0000-4000-8000-000000000007",
                           "@claude_state_ts": str(int(time.time()) - 4000), "@cc_agent": "claude"}.items():
            self.set(key, value)
        self.tdir = self.root / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(self.wt))
        self.tdir.mkdir(parents=True)
        self.sid = "11111111-1111-4111-8111-111111111111"
        self.transcript = self.tdir / (self.sid + ".jsonl")
        self.transcript.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": "research"}}) + "\n")
        self.phase = "rig-ready"

    def tearDown(self):
        # One existing case explicitly tears down and rebuilds this same Rig.
        # Drain now, so the old callback cannot target the next setUp's fixture.
        # unittest also drains after a failed setUp, when tearDown is skipped.
        self.doCleanups()

    def diagnostic(self, **detail):
        print("idle-rig " + json.dumps(dict(
            case=self.id(), phase=self.phase, wall=time.time(),
            socket_label=getattr(self, "label", None),
            socket_dir=getattr(self, "env", {}).get("TMUX_TMPDIR", "/tmp"),
            session=getattr(self, "label", None), root=str(getattr(self, "root", "")),
            previous_cleanup=getattr(self, "previous_cleanup", None), **detail),
            default=str), file=sys.stderr, flush=True)

    def cleanup_rig(self):
        self.phase = "cleanup"
        self.cleanup_calls += 1
        if self.calls is not None:
            return self.cleanup_owned_rig()
        result = dict(case=self.id(), wall=time.time(), socket_label=getattr(self, "label", None))
        try:
            if hasattr(self, "label"):
                # The original PID-scoped private label is deliberately unchanged.
                p = subprocess.run(["tmux", "-L", self.label, "kill-server"], capture_output=True, text=True)
                result.update(rc=p.returncode, stdout=p.stdout, stderr=p.stderr)
        except OSError as exc:
            result["error"] = repr(exc)
            raise
        finally:
            try:
                self.tmp.cleanup()
            finally:
                result["root_removed"] = not Path(self.tmp.name).exists()
                Rig.last_cleanup = result
                self.diagnostic(cleanup=result)

    def socket_identity(self):
        p = self.calls.run(["tmux", "-N", "-L", self.label, "display-message", "-p",
                            "-t", self.label, "#{pid}|#{socket_path}"], self.env)
        server, raw = p.stdout.strip().split("|")
        if not server.isdigit() or not os.path.isabs(raw) or len(os.fsencode(raw)) > 1024:
            raise RuntimeError("unknown isolated tmux identity")
        st = os.stat(raw)
        self.socket_record = dict(server_pid=int(server), raw=raw,
                                  canonical=os.path.realpath(raw), dev=st.st_dev,
                                  inode=st.st_ino)
        self.socket_record = self.server.bind(self.socket_record)
        self.diagnostic(socket_created=self.socket_record)

    def cleanup_owned_rig(self):
        result = dict(case=self.id(), wall=time.time(), socket_label=getattr(self, "label", None),
                      cleanup_calls=self.cleanup_calls, socket=getattr(self, "socket_record", None),
                      root_raw=self.tmp.name, root_identity=self.root_identity,
                      root_removed=False)
        # The same dict is finalized after deletion and emitted by calls.finish.
        # Failure diagnostics run BEFORE deletion, so their failure keeps WORK.
        self.calls.cleanup_receipts.append(result)
        try:
            try:
                self.prepare_owned_rig_cleanup(result)
            finally:
                original = sys.exc_info()[1]
                result["diagnostic_phase"] = "before-root-removal"
                if original is not None:
                    result["error"] = self.calls.error_text(original)
                try:
                    self.diagnostic(cleanup=result)
                except BaseException as diagnostic_exc:
                    self.calls.diagnostic_error("cleanup-finally.output", diagnostic_exc)
                    result["diagnostic_error"] = self.calls.secondary_errors[-1]
                    if original is None:
                        raise
            self.tmp.cleanup()
            result["root_removed"] = not os.path.lexists(self.tmp.name)
            if not result["root_removed"]:
                raise RuntimeError("fixture root remains")
        except BaseException as exc:
            result["error"] = self.calls.error_text(exc)
            self.calls.errors.append("Rig cleanup incomplete: " + self.calls.error_text(exc))
            # A failure to detach is secondary too; never replace this exception.
            try:
                self.tmp._finalizer.detach()
                result["automatic_removal_detached"] = True
            except BaseException as detach_exc:
                self.calls.diagnostic_error("cleanup-finalizer.detach", detach_exc)
                result["automatic_removal_detached"] = False
            raise
        finally:
            Rig.last_cleanup = result

    def prepare_owned_rig_cleanup(self, result):
        if self.server is not None:
            # close() always retains its actual wait/FD receipt, even if it fails.
            result["server"] = self.server.record
            server = self.server.close()
            result.update(rc=server["rc"], server_joined=server["joined"],
                          socket_paths_absent=(server.get("raw_socket_present") is False and
                                               server.get("canonical_socket_present") is False),
                          server_pid_absent=server.get("server_pid_absent"),
                          server_wait="actual foreground Popen.wait; separate path/PID checks")
        else:
            result["socket_cleanup"] = "no server Popen created; no socket command"
        if any(p.returncode is None for p in self.calls.children) or self.calls.errors:
            raise RuntimeError("unjoined/unknown owned call; retain fixture")
        self.calls.remaining(cleanup=True)
        if self.root_identity is None:
            raise RuntimeError("fixture root creation identity missing; retain exact directory")
        ls = os.lstat(self.tmp.name)
        st = self.root.stat()
        if (not stat.S_ISDIR(ls.st_mode) or
                (ls.st_dev, ls.st_ino) != self.root_identity or
                (st.st_dev, st.st_ino) != self.root_identity or
                os.path.realpath(self.tmp.name) != str(self.root)):
            raise RuntimeError("fixture root identity changed; retain")

    def call(self, *args):
        try:
            if self.calls is not None:
                return self.calls.run(args, self.env).stdout
            return subprocess.check_output(args, env=self.env, text=True, stderr=subprocess.PIPE, timeout=20)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            try:
                self.diagnostic(argv=args, rc=getattr(exc, "returncode", None),
                                stdout=exc.stdout, stderr=exc.stderr, error=repr(exc))
            except BaseException as diagnostic_exc:
                if self.calls is not None:
                    self.calls.diagnostic_error("original-failure.output", diagnostic_exc)
            raise

    def tm(self, *args):
        creating = "new-session" in args
        if creating and self.calls is not None:
            self.server_creation_attempted = True
            if self.server is None:
                self.server = OwnedRigServer(self.calls, self.label, self.env)
                self.server.start()
        # A failed foreground startup must not silently fall back to a daemon.
        options = ("-N",) if self.calls is not None else ()
        answer = self.call("tmux", *options, "-L", self.label, *args)
        if creating and self.calls is not None:
            self.socket_identity()
            self.server.activate()
        return answer

    def set(self, key, value):
        self.tm("set-option", "-w", "-t", self.win, key, value)

    def clean(self, *args):
        return self.call("bash", str(self.ibin / "fleet-cleanup-idle.sh"), self.label, *args)

    def exists(self):
        return self.win in self.tm("list-windows", "-t", self.label, "-F", "#{window_id}").split()

    def codexify(self):
        """Bind an idle Codex conversation, including #4318's native proof.

        Only RPC replies are fixtures: identity inspection, process ownership,
        native idle checks, cleanup, history and restore run the real code.
        """
        home = self.root / "codex-home"
        transcript = home / "sessions/2026/09/17" / ("rollout-" + self.sid + ".jsonl")
        transcript.parent.mkdir(parents=True, exist_ok=True)
        transcript.write_text(json.dumps({"type": "session_meta", "payload": {"id": self.sid, "cwd": str(self.wt)}}) + "\n")
        pid = self.tm("display-message", "-p", "-t", self.win, "#{pane_pid}").strip()
        self.set("@cc_agent", "codex")
        self.set("@cc_launcher_pid", pid)
        remote = "unix://" + str(self.root / "native.sock")
        self.set("@codex_identity", json.dumps({"session_id": self.sid, "owner": pid,
                                               "home": str(home), "transcript": str(transcript),
                                               "cwd": str(self.wt), "remote": remote}))
        self.native = self.root / "native.json"
        self.native.write_text(json.dumps({"remote": remote, "thread": {
            "id": self.sid, "cwd": str(self.wt), "path": str(transcript),
            "status": {"type": "idle"},
            "turns": [{"id": "turn-1", "status": "completed", "items": []}]}}))
        rpc = self.ibin / "fleet-codex-rpc.py"
        rpc.unlink()
        rpc.write_text('import json\nfrom pathlib import Path\n'
                       + 'RECORD = Path(' + repr(str(self.native)) + ')\n' + '''
class Client:
    def __init__(self, remote, **kwargs):
        if remote != json.loads(RECORD.read_text())['remote']:
            raise ValueError('foreign fixture endpoint')
    def close(self): pass
    def call(self, method, params):
        thread = json.loads(RECORD.read_text())['thread']
        if method == 'thread/loaded/list': return {'data': [thread['id']]}
        if params.get('threadId') != thread['id']:
            raise ValueError('foreign fixture thread')
        if method == 'thread/read': return {'thread': thread}
        if method == 'thread/goal/get': return {'goal': None}
        raise ValueError('unexpected fixture RPC: ' + method)
''')
        return transcript

    def mature_notice(self):
        self.clean()
        self.set("@reap_due", str(int(time.time()) - 1))


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class RoundTrip(Rig):

    def test_real_close_and_restore(self):
        self.assertEqual(self.clean(), "")
        self.assertTrue(self.exists())
        self.assertGreater(int(self.tm("display-message", "-p", "-t", self.win, "#{@reap_due}")), int(time.time()))
        self.set("@reap_due", str(int(time.time()) - 1))
        self.assertIn("reaped-idle:" + self.win, self.clean())
        self.assertFalse(self.exists())
        self.assertTrue(self.wt.is_dir())
        self.assertTrue(self.transcript.is_file())
        self.assertIn(self.sid, (self.root / "ledger.tsv").read_text())
        self.call("bash", str(self.ibin / "dash-restore-session.sh"), "landed:scratch:scratch-7", self.label)
        until = time.monotonic() + 5
        while not (self.root / "resume-args").exists() and time.monotonic() < until:
            time.sleep(0.05)
        self.assertIn("--resume\n" + self.sid, (self.root / "resume-args").read_text())
        self.assertIn(str(self.wt), self.tm("list-windows", "-t", self.label, "-F", "#{@worktree}"))

    def test_codex_close_and_restore_keeps_exact_identity(self):
        home = self.root / "codex-home"
        transcript = self.codexify()
        self.mature_notice()
        self.assertIn("reaped-idle:", self.clean())
        self.call("bash", str(self.ibin / "dash-restore-session.sh"), "landed:scratch:scratch-7", self.label)
        until = time.monotonic() + 5
        while not (self.root / "resume-args").exists() and time.monotonic() < until:
            time.sleep(0.05)
        args = (self.root / "resume-args").read_text()
        self.assertIn("--agent\ncodex\n--codex-home\n" + str(home), args)
        self.assertIn(self.sid, args)
        self.assertTrue(transcript.exists())

    def test_codex_unknown_or_active_native_turn_is_kept(self):
        self.codexify()
        identity = self.tm("display-message", "-p", "-t", self.win, "#{@codex_identity}")
        unbound = json.loads(identity)
        del unbound["remote"]
        self.set("@codex_identity", json.dumps(unbound))
        self.mature_notice()
        self.assertEqual(self.clean(), "")
        self.assertTrue(self.exists())  # session_meta alone proves no idle turn
        self.set("@codex_identity", identity)
        native = json.loads(self.native.read_text())
        idle_thread = native["thread"]
        for change in ({"status": {"type": "active"}},
                       {"status": {"type": "unknown"}}, {"turns": []},
                       {"path": str(self.root / "other.jsonl")},
                       {"turns": [{"id": "turn-1", "status": "completed", "items": [
                           {"type": "mcpToolCall", "status": "inProgress"}]}]}):
            with self.subTest(change=change):
                self.native.write_text(json.dumps(dict(native, thread=dict(idle_thread, **change))))
                self.assertEqual(self.clean(), "")
                self.assertTrue(self.exists())
        self.native.write_text(json.dumps(native))
        self.mature_notice()
        self.assertIn("reaped-idle:", self.clean())
        self.assertFalse(self.exists())

    def test_unmerged_pr_requires_strict_ancestor_and_activity_recheck(self):
        self.call("git", "-C", str(self.main), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                  "commit", "--allow-empty", "-qm", "advance base")
        head = self.call("git", "-C", str(self.main), "rev-parse", "HEAD").strip()
        self.call("git", "-C", str(self.main), "update-ref", "refs/remotes/origin/master", head)
        (self.root / "prs.json").write_text('[{"state":"OPEN"}]')
        self.mature_notice()
        # Resume a turn after the real history writer returns; the final snapshot
        # must reject this without dropping the worktree or closing the window.
        script = self.ibin / "fleet-history.sh"
        script.unlink()
        script.write_text('#!/bin/bash\nbash ' + shlex.quote(str(BIN / 'fleet-history.sh')) + ' "$@" || exit $?\n'
                          + 'if [ "$1" = record-closed ]; then tmux -L ' + shlex.quote(self.label)
                          + ' set-option -w -t ' + self.win + ' @claude_state working; fi\n')
        self.clean()
        self.assertTrue(self.exists())
        script.unlink()
        script.symlink_to(BIN / "fleet-history.sh")
        self.set("@claude_state", "done")
        self.assertIn("reaped-idle:", self.clean())

    def test_shared_git_gate_protects_bound_live_worktree(self):
        self.set("@claude_state", "working")
        head = self.call("git", "-C", str(self.wt), "rev-parse", "HEAD").strip()
        args = ("bash", "-c", '. "$1/fleet-lib.sh"; v=$(fleet_reap_ok "$2" "$3" scratch-7 "$4" "$4" scratch-7); r=$?; printf "%s:%s" "$v" "$r"',
                "gate", str(self.ibin), str(self.wt), str(self.main), head)
        self.assertEqual(self.call(*args), "live:1")
        self.set("@claude_state", "done")
        self.assertEqual(self.call(*args), "merged-pr:0")

    def test_dirty_active_loop_recent_unknown_and_unmerged_are_kept(self):
        self.mature_notice()
        for state in ("working", "looping", "busy", "needs", ""):
            self.set("@claude_state", state)
            self.clean()
            self.assertTrue(self.exists(), state)
        self.set("@claude_state", "done")
        (self.wt / "dirty").write_text("keep")
        self.clean()
        self.assertTrue(self.exists())
        (self.wt / "dirty").unlink()
        (self.root / "prs.json").write_text('[{"state":"OPEN"}]')
        self.clean()
        self.assertTrue(self.exists())  # tip==base is not a strict ancestor
        (self.root / "prs.json").write_text("not JSON")
        self.clean()
        self.assertTrue(self.exists())
        (self.root / "prs.json").write_text("[]")
        self.set("@claude_state_ts", str(int(time.time())))
        self.clean()
        self.assertTrue(self.exists())
        manifest = self.root / "handoff/manifest.json"
        (manifest.parent / "loop").mkdir(parents=True)
        (manifest.parent / "loop/state.json").write_text('{"status":"waiting-quota"}')
        self.set("@handoff_manifest", str(manifest))
        self.set("@claude_state_ts", str(int(time.time()) - 4000))
        self.clean()
        self.assertTrue(self.exists())

    def test_missing_transcript_and_failed_ledger_do_not_close(self):
        self.mature_notice()
        self.transcript.unlink()
        self.clean()
        self.assertTrue(self.exists())

        self.transcript.write_text('{"type":"user","message":{"role":"user","content":"back"}}\n')
        self.env["FLEET_HISTORY_LEDGER"] = str(self.root)  # cannot append to a directory
        self.clean()
        self.assertTrue(self.exists())

    def test_dry_cap_off_and_rate_limit(self):
        self.mature_notice()
        before = self.tm("show-options", "-w", "-t", self.win)
        self.assertIn("would-reap-idle:", self.clean("--dry-run"))
        self.assertEqual(before, self.tm("show-options", "-w", "-t", self.win))
        self.assertFalse((self.root / "ledger.tsv").exists())
        self.clean("--limit", "0")
        self.assertTrue(self.exists())
        conf = self.conf
        original = conf.read_text()
        conf.write_text(original + "FLEET_REAP_IDLE_DONE_MIN=0\n")
        self.clean()
        self.assertTrue(self.exists())
        conf.write_text(original)
        gh = self.root / "fake/gh"
        log = self.root / "gh-calls"
        gh.write_text("#!/bin/sh\necho call >> " + shlex.quote(str(log))
                      + "\necho 'API rate limit exceeded' >&2\nexit 1\n")
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.clean()
        self.assertEqual(caught.exception.returncode, 75)
        self.assertEqual(log.read_text().splitlines(), ["call"])
        self.assertTrue(self.exists())


class PolicyGrammar(unittest.TestCase):
    """bin/fleet_reap_policy.py — the one parser (issue #1902)."""
    def test_norm_default_label(self):
        import fleet_reap_policy as rp
        self.assertEqual(rp.norm("merged"), "merged")
        self.assertEqual(rp.norm("merged:48h"), "merged:48h")
        self.assertEqual(rp.norm("done"), "done:15m")
        self.assertEqual(rp.norm("done:30m"), "done:30m")
        self.assertEqual(rp.norm("loop-end"), "loop-end")
        self.assertEqual(rp.norm("keep"), "keep")
        self.assertEqual(rp.norm("at:2026-10-06T18:00Z"), "at:2026-10-06T18:00:00Z")
        self.assertEqual(rp.norm("at:1791320000"), "at:" + rp.iso(1791320000))
        self.assertRegex(rp.norm("at:18:00"), r"^at:\d{4}-\d\d-\d\dT\d\d:\d\d:00Z$")
        for bad in ("", "never", "merged:", "done:0", "done:-1h", "keep:1", "at:soon", "at:25:00",
                    "merged:1y", "loop-end:1h", "done:9999999d"):
            self.assertIsNone(rp.norm(bad), bad)
        self.assertEqual((rp.default("issue"), rp.default("scratch"), rp.default("loop")),
                         ("merged", "done:15m", "loop-end"))
        self.assertEqual(rp.parse("done"), ("done", 900))
        self.assertEqual(rp.parse("done:2h"), ("done", 7200))
        self.assertEqual([rp.label(p) for p in ("merged", "done:15m", "loop-end", "keep")],
                         ["合并后回收", "做完就回收", "循环停了回收", "常驻"])
        self.assertEqual(rp.label("done:2h"), "做完闲 2 小时")   # an older window's own stamp
        self.assertEqual(rp.label("merged:48h"), "合并后留 2 天")
        self.assertEqual([rp.merged_grace(p) for p in ("", "merged", "merged:48h", "keep", "done:2h", "junk")],
                         ["", "", "172800", "keep", "other", ""])
        r = subprocess.run(["python3", str(BIN / "fleet_reap_policy.py"), "norm", "nope"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)

    def test_origin_table_and_the_policy_in_force(self):
        """Ordinary defaults ignore legacy origins and preserve chosen policies."""
        import fleet_reap_policy as rp
        self.assertEqual(rp.norm("idle"), "idle:2h")
        self.assertEqual(rp.parse("idle:15m"), ("idle", 900))
        self.assertIsNone(rp.norm("idle:0"))
        self.assertEqual(rp.label("idle:15m"), "闲 15 分钟收起")
        self.assertTrue(rp.idle_owned("idle:2h"))
        self.assertEqual({o: rp.origin_default(o) for o in rp.ORIGINS},
                         {"person": "idle:2h", "probe": "done:1m"})
        self.assertEqual(rp.origin_default("person", "issue"), "idle:2h")
        self.assertEqual(rp.origin_default("dispatched", "loop"), "idle:2h")
        self.assertEqual(rp.origin_default("driver", "loop"), "idle:2h")
        self.assertEqual([rp.origin_of(*a) for a in (
            ("orchestrator",), ("fleet-epic:epic-driver",), ("", "", "", "1"), ("", "scratch-3"),
            ("", "hub"), ("", "", "u/f"), ("", ""), ("", "scratch-3", "", "", "decide"))],
            ["person", "person", "probe", "person", "person", "person", "person", "person"])
        # Titles label sessions; only explicit provenance authorizes probe policy.
        self.assertEqual([rp.origin_of(*a) for a in (
            ("", "hub", "", "", "", "T672 放置计时 D2（空会话，可关）"), ("", "scratch-3", "", "", "", "探针：放置 4xx"),
            ("", "scratch-3", "", "", "", "C5 · 重复的故障演练合并"), ("orchestrator", "", "", "", "", "可关"))],
            ["person", "person", "person", "person"])
        self.assertEqual([rp.effective(*a) for a in (
            ("done:5m", "1"), ("", "", "orchestrator"), ("keep", "", "", "session", True),
            ("keep", "", "", "session", False), ("keep", "", "", "", True), ("merged",))],
            ["done:5m", "", "keep", "keep", "keep", "merged"])
        r = subprocess.run(["python3", str(BIN / "fleet_reap_policy.py"), "origin-default", "person"],
                           capture_output=True, text=True)
        self.assertEqual(r.stdout.strip(), "idle:2h")

    def test_idle_owned_holds_off_the_reopen(self):
        """A finished session the idle reaper will close is not the idle reopen's
        (issue #4764): done / loop-end / an `at:` reached — never merged / keep."""
        import fleet_reap_policy as rp
        now = 1791320000
        self.assertEqual([rp.idle_owned(p, now) for p in
                          ("done", "done:10m", "loop-end", "at:%d" % (now - 60), "at:%d" % (now + 60),
                           "merged", "merged:48h", "keep", "", "junk")],
                         [True, True, True, True, False, False, False, False, False, False])
        for pol, rc in (("done:10m", 0), ("merged", 1)):
            r = subprocess.run(["python3", str(BIN / "fleet_reap_policy.py"), "idle-owned", pol],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, rc, pol)

    def test_restore_map_carries_policy_by_identity(self):
        fid = "12345678-1234-4123-8123-123456789abc"
        line = "keep|" + fid + "||acme/app|w|/nonexistent|7|done|-|-||-|claude|\n"
        out = subprocess.run(["python3", str(BIN / ".fleet-restore-resolve.py"), "", "--lead", "--sid", "--fid", "--reap"],
                             input=line, capture_output=True, text=True).stdout.splitlines()
        self.assertEqual(out[0], "REAP\t" + fid + "\tkeep")
        self.assertEqual(out[1], "FID\t" + fid)
        self.assertTrue(out[2].startswith("WIN\tw\t"))
        with tempfile.NamedTemporaryFile("w", suffix=".map", delete=False) as f:
            f.write("\n".join(out) + "\n")
        wins = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh"; fleet_restore_wins "$2"', "x", str(BIN), f.name],
                              capture_output=True, text=True).stdout
        os.unlink(f.name)
        self.assertTrue(wins.startswith("WIN:" + fid + "\tw\t"), wins)
        # no policy: no REAP row, the rows exactly as before
        out = subprocess.run(["python3", str(BIN / ".fleet-restore-resolve.py"), "", "--lead", "--sid", "--fid", "--reap"],
                             input="|" + line.split("|", 1)[1], capture_output=True, text=True).stdout.splitlines()
        self.assertEqual(out[0], "FID\t" + fid)


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class TaskSession(Rig):
    """A development task's session (issue #4897, EPIC #4895 批 0): a repo scratch
    bound to the hub's record (@task + @task_flow, no issue) whose `merged` means
    the RECORD closed — never its PR. Open or unknown keeps it; closed reaps it
    (history first, the worktree kept for worktree-autoclean.sh)."""
    def setUp(self):
        super().setUp()
        self.answer = self.root / "task-answer"
        seam = self.root / "task-closed"
        seam.write_text("#!/bin/sh\nread rc < " + shlex.quote(str(self.answer)) + "\n"
                        "[ \"$1\" = T42 ] || exit 3\n"
                        "case \"$rc\" in 0) echo SUCCEEDED ;; 1) echo WAITING ;; esac\nexit \"$rc\"\n")
        seam.chmod(0o755)
        self.env["FLEET_TASK_CLOSED_CMD"] = str(seam)
        for key, value in (("@task", "T42"), ("@task_flow", "1"), ("@reap_policy", "merged")):
            self.set(key, value)

    def due(self):
        out = self.clean()
        if self.tm("display-message", "-p", "-t", self.win, "#{@reap_due}").strip().isdigit():
            self.set("@reap_due", str(int(time.time()) - 1))
        return out + self.clean()

    def test_open_or_unknown_record_keeps_the_session(self):
        for rc, token in (("1", "skip:task-open"), ("3", "skip:task-unknown")):
            with self.subTest(rc=rc):
                self.answer.write_text(rc + "\n")
                self.set("@reap_skip", "")
                out = self.due()
                self.assertIn(token + " " + self.win + " T42", out)
                self.assertNotIn("reaped", out)
                self.assertTrue(self.exists())

    def test_closed_record_reaps_after_grace_keeping_the_worktree(self):
        self.answer.write_text("0\n")
        self.set("@claude_state", "working")
        self.assertEqual(self.due().count("reaped"), 0)   # working: never
        self.assertTrue(self.exists())
        self.set("@claude_state", "done")
        out = self.due()
        self.assertIn("reaped-task:" + self.win + " T42", out)
        self.assertFalse(self.exists())
        self.assertTrue(self.wt.is_dir())
        self.assertIn("task T42 is closed", (self.root / "ledger.tsv").read_text())

    def test_untracked_only_does_not_hold_a_closed_record_but_a_tracked_change_does(self):
        """T859: seven finished task windows stayed open for days on a worktree
        whose only «dirt» was the agent's untracked tool output (.playwright-mcp/,
        shots/). A closed record closes with untracked files only — kept on disk;
        a tracked change still keeps the window."""
        self.answer.write_text("0\n")
        tracked = self.wt / "tracked.txt"
        tracked.write_text("v1\n")
        self.call("git", "-C", str(self.wt), "add", "tracked.txt")
        self.call("git", "-C", str(self.wt), "-c", "user.email=t@t", "-c", "user.name=t",
                  "commit", "-qm", "tracked")
        tracked.write_text("v2\n")                       # a tracked change: kept
        out = self.due()
        self.assertNotIn("reaped", out)
        self.assertTrue(self.exists())
        self.call("git", "-C", str(self.wt), "checkout", "--", "tracked.txt")
        (self.wt / ".playwright-mcp").mkdir()
        (self.wt / ".playwright-mcp" / "console.log").write_text("x")
        (self.wt / "shots").mkdir()
        (self.wt / "shots" / "a.png").write_text("png")
        out = self.due()
        self.assertRegex(out, "reaped-(task|over):" + re.escape(self.win) + " ")   # either road
        self.assertFalse(self.exists())
        self.assertTrue((self.wt / "shots" / "a.png").is_file())   # the bytes stay

    def test_a_reopen_in_flight_holds_the_close_and_its_new_window_is_reaped(self):
        """claude-fleet T569: a ver-stale reopen (fleet-migrate.sh --cfg-stale)
        and this close raced on T477 — the reaper closed the old window 12 s into
        the reopen, the reopen opened a new one anyway, and nothing closed THAT.
        A reopen in flight (@migrating, or the worktree's transition lock) holds
        the close; the window it opens is reaped on its own (by window, never «T42
        was reaped once»)."""
        self.answer.write_text("0\n")
        self.set("@migrating", "ver-stale")
        out = self.due()
        self.assertIn("skip:migrating " + self.win, out)
        self.assertNotIn("reaped", out)
        self.assertTrue(self.exists())
        self.tm("set-option", "-wu", "-t", self.win, "@migrating")
        lock = Path(self.call("bash", "-c", '. "$1/fleet-lib.sh"; fleet_rotate_lease_file "$2"', "t",
                              str(BIN), str(self.wt)).strip() + ".transfer-lock")
        self.call("bash", "-c", '. "$1/fleet-lib.sh"; fleet_transition_lock_take "$2"', "t", str(BIN), str(self.wt))
        self.assertTrue(lock.is_dir())
        out = self.due()
        self.assertIn("skip:transition " + self.win, out)
        self.assertTrue(self.exists())
        self.assertTrue(lock.is_dir())                   # another's lock: never dropped here
        shutil.rmtree(lock)
        # the reopen's outcome: the old window gone, a NEW one on the same session
        opts = {k: self.tm("display-message", "-p", "-t", self.win, "#{" + k + "}").strip()
                for k in ("@raw", "@worktree", "@cc_agent", "@task", "@task_flow", "@reap_policy", "@fleet_id")}
        subprocess.run(["tmux", "-L", self.label, "kill-window", "-t", self.win], check=True, timeout=20,
                       env=dict(self.env, FLEET_ALLOW_TMUX_DESTROY="1"))   # the reopen's /exit
        self.win = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", self.label,
                           "-c", str(self.wt), "sleep 90").strip()
        for k, v in dict(opts, **{"@claude_state": "done",
                                  "@claude_state_ts": str(int(time.time()) - 4000)}).items():
            self.set(k, v)
        out = self.due()
        self.assertIn("reaped-task:" + self.win + " T42", out)
        self.assertFalse(self.exists())
        self.assertFalse(lock.exists())                  # its own lock: dropped after the close
        # …and a second reopened window after that close is reaped too
        self.win = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", self.label,
                           "-c", str(self.wt), "sleep 90").strip()
        for k, v in dict(opts, **{"@claude_state": "done",
                                  "@claude_state_ts": str(int(time.time()) - 4000)}).items():
            self.set(k, v)
        out = self.due()
        self.assertIn("reaped-task:" + self.win + " T42", out)
        self.assertFalse(self.exists())

    FID = "5f0e7a1c-2b3d-4e5f-8a9b-0c1d2e3f4a5b"

    def result(self, state):
        """A report on the window's ID (fleet_id.py result, the ledger here)."""
        self.set("@fleet_id", self.FID)
        self.call("python3", str(BIN / "fleet_id.py"), "result", self.FID, "--state", state,
                  "--summary", "t680")

    def test_a_final_id_result_is_done_while_the_record_still_reads_open(self):
        """T680: one «做完» — the ID's final result (merged / succeeded / failed)
        closes the session even while the record is still 已接受; a non-final one
        (blocked) does not — it waits on its person (E101: the waiting road)."""
        self.answer.write_text("1\n")
        self.result("blocked")
        out = self.due()
        self.assertIn("skip:waiting " + self.win, out)
        self.assertTrue(self.exists())
        self.result("merged")
        out = self.due()
        self.assertIn("reaped-task:" + self.win + " T42", out)
        self.assertFalse(self.exists())
        self.assertTrue(self.wt.is_dir())

    def test_now_watcher_closes_about_its_grace_after_the_turn(self):
        """T680: `--now <ID> --after N` closes the finished window N s after its
        turn, not at the next tick — and never while it is still working."""
        self.answer.write_text("1\n")
        self.result("succeeded")
        self.set("@claude_state", "working")
        self.set("@claude_state_ts", str(int(time.time())))
        env = dict(self.env, FLEET_REAP_NOW_EVERY="1", FLEET_REAP_NOW_MAX="40")
        t0 = time.time()
        proc = subprocess.Popen(["bash", str(self.ibin / "fleet-cleanup-idle.sh"), "--now", self.FID,
                                 "--after", "2", "--fg"], env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        time.sleep(3)
        self.assertTrue(self.exists())                   # working: the watcher waits
        self.set("@claude_state", "done")
        self.set("@claude_state_ts", str(int(time.time())))
        t1 = time.time()
        out, _ = proc.communicate(timeout=60)
        self.assertIn("reaped-task:" + self.win + " T42", out)
        self.assertFalse(self.exists())
        self.assertTrue(self.wt.is_dir())
        self.assertGreaterEqual(time.time() - t1, 1.5)   # its grace, after the turn
        self.assertLess(time.time() - t0, 30)
        # the window gone, a second watcher ends at once
        out = self.call("bash", str(self.ibin / "fleet-cleanup-idle.sh"), "--now", self.FID, "--fg")
        self.assertNotIn("reaped", out)

    def test_other_policy_or_no_flow_takes_the_ordinary_roads(self):
        self.answer.write_text("1\n")
        self.set("@task_flow", "")
        self.assertNotIn("task", self.due())             # no flow: not a task session
        self.set("@task_flow", "1")
        self.set("@reap_policy", "done:15m")
        out = self.due()
        self.assertNotIn("skip:task", out)               # done: the idle road decides
        self.assertIn("reaped-idle:" + self.win, out)


class HoldsAndWhy(TaskSession):
    """C6 / T965: real background work always holds its window; a session waiting on its person is
    parked by the common gate and reaped after three days with resumable history;
    a window its agent's error stopped is never closed; and every window the pass
    leaves open carries why (@reap_why), cleared once it is working."""

    def setUp(self):
        super().setUp()
        self.asked = self.root / "asked"
        closed = self.root / "task-closed"           # the record's hold words too (fleet_task_control.py closed)
        closed.write_text("#!/bin/sh\nread rc < " + shlex.quote(str(self.answer)) + "\n"
                          "[ \"$1\" = T42 ] || exit 3\n"
                          "case \"$rc\" in 0) echo SUCCEEDED ;; 1) echo WAITING ;; esac\n"
                          "[ -f " + shlex.quote(str(self.asked)) + " ] && [ \"$rc\" = 1 ] && echo 'asked: 1'\n"
                          "exit \"$rc\"\n")

    test_open_or_unknown_record_keeps_the_session = None
    test_closed_record_reaps_after_grace_keeping_the_worktree = None
    test_untracked_only_does_not_hold_a_closed_record_but_a_tracked_change_does = None
    test_a_reopen_in_flight_holds_the_close_and_its_new_window_is_reaped = None
    test_a_final_id_result_is_done_while_the_record_still_reads_open = None
    test_now_watcher_closes_about_its_grace_after_the_turn = None
    test_other_policy_or_no_flow_takes_the_ordinary_roads = None

    def why(self):
        return self.tm("display-message", "-p", "-t", self.win, "#{@reap_why}").strip()

    def test_a_background_job_holds_a_done_task_past_old_grace(self):
        """A closed task does not authorize dropping its pending work."""
        self.answer.write_text("0\n")
        self.set("@loop", "kind=wakeup next=%d ttl=600" % (int(time.time()) + 6000))   # its job still pending
        self.set("@claude_state_ts", str(int(time.time()) - 1000))
        out = self.due()
        self.assertIn("skip:bg-job " + self.win, out)
        self.assertNotIn("reaped", out)
        self.assertTrue(self.exists())
        self.assertEqual(self.why(), "bg")
        self.answer.write_text("1\n")                    # work not over: the job holds it, as before
        self.set("@claude_state_ts", str(int(time.time()) - 4000))
        self.assertNotIn("reaped", self.due())
        self.assertEqual(self.why(), "task-open")
        self.answer.write_text("0\n")                    # a terminal task never overrides real pending work
        out = self.due()
        self.assertNotIn("reaped", out)
        self.assertTrue(self.exists())
        self.assertEqual(self.why(), "bg")
        self.assertTrue(self.wt.is_dir())

    def test_every_open_window_says_why_and_a_working_one_nothing(self):
        self.answer.write_text("1\n")
        self.due()
        self.assertEqual(self.why(), "task-open")
        self.answer.write_text("0\n")
        self.set("@claude_state_ts", str(int(time.time()) - 5))
        self.assertNotIn("reaped", self.clean())       # inside its 60 s grace
        self.assertRegex(self.why(), r"^timer:\d+$")
        self.set("@claude_state", "working")
        self.clean()
        self.assertEqual(self.why(), "")

    def test_waiting_on_its_person_parks_after_its_hours(self):
        """C6/E101: same window when parked; 3d later history proves resume first."""
        self.answer.write_text("1\n")
        self.result("waiting")
        self.set("@park_wrap_ver", "1")
        self.set("@reap_origin", "decide")
        self.set("@claude_state_ts", str(int(time.time()) - 600))
        self.env["FLEET_PARK_MEM_FREE"] = "50"
        # The native park gate is covered by fleet-park-selftest.py. This seam
        # acknowledges the park in the same real tmux window, never closes it.
        gate = self.root / "gate"
        gate.write_text("#!/bin/sh\n" +
                        "tmux -L " + shlex.quote(self.label) + " set-option -w -t " + self.win + " @parked 1\n" +
                        "tmux -L " + shlex.quote(self.label) + " set-option -w -t " + self.win + " @park_held 1\n" +
                        "tmux -L " + shlex.quote(self.label) + " set-option -w -t " + self.win + " @park_since $(date +%s)\n" +
                        "echo '{\"ok\":true}'\n")
        gate.chmod(0o755)
        self.env["FLEET_SESSION_GATE_CMD"] = str(gate)
        self.env["FLEET_SESSION_REAP_PARKED"] = "3d"
        out = self.clean()
        self.assertIn("parked-web:" + self.win, out)
        self.assertTrue(self.exists())
        self.clean()
        self.assertRegex(self.why(), r"^timer:\d+$")
        old = str(int(time.time()) - 3 * 86400 - 600)
        self.set("@park_since", old)
        self.set("@claude_state_ts", old)
        # A pending wake wins over expiry; no history or close under that wake.
        self.set("@park_wake", "/pending-seed")
        self.assertNotIn("reaped-parked", self.clean())
        self.assertTrue(self.exists())
        self.set("@park_wake", "")
        out = self.clean()
        self.assertIn("reaped-parked:" + self.win + " scratch-7", out)
        self.assertFalse(self.exists())
        self.assertTrue(self.wt.is_dir())
        self.assertIn("Reaped after parked retention", (self.root / "ledger.tsv").read_text())

    def test_the_record_asking_is_waiting_too(self):
        self.answer.write_text("1\n")
        self.set("@claude_state_ts", str(int(time.time()) - 600))
        self.asked.write_text("")
        self.due()
        self.assertEqual(self.why(), "waiting")
        self.asked.unlink()
        self.set("@reap_skip", "")
        self.due()
        self.assertEqual(self.why(), "task-open")

    def test_an_error_stop_is_never_closed_and_says_which(self):
        """FQBW: a 502 left its window on the recovery page, put away for 16 hours."""
        self.answer.write_text("0\n")
        self.set("@claude_state", "exited")
        self.set("@agent_status", '{"state":"error","msg":"API Error: 502 upstream unreachable"}')
        at = int(time.time()) + 300
        for k, v, want in (("@auto_resume_at", str(at), "error-retry:%d" % at),
                           ("@auto_resume_at", "", "error"), ("@auto_resumed", "1", "error-retried")):
            with self.subTest(want=want):
                if v:
                    self.set(k, v)
                else:
                    self.tm("set-option", "-wu", "-t", self.win, k)
                out = self.due()
                self.assertNotIn("reaped", out)
                self.assertTrue(self.exists())
                self.assertEqual(self.why(), want)
        self.set("@agent_status", '{"state":"done"}')       # not an error: the ordinary roads close it
        self.set("@claude_state", "done")
        self.assertIn("reaped-task:" + self.win, self.due())


class DispatchedSession(TaskSession):
    """Legacy explicit merged policies work without role privileges or nudges."""
    PARENT = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    def setUp(self):
        super().setUp()
        self.set("@origin_fid", self.PARENT)
        self.set("@fleet_id", self.FID)
        self.nudges = self.root / "nudges"
        seam = self.ibin / "fleet-peer-send.sh"
        seam.unlink()
        seam.write_text("#!/bin/sh\nprintf '%s\\t%s\\n' \"$1\" \"$2\" >> " + shlex.quote(str(self.nudges)) + "\n")
        seam.chmod(0o755)
        self.set("@task_flow", "")  # exercise the generic legacy merged road

    test_open_or_unknown_record_keeps_the_session = None
    test_closed_record_reaps_after_grace_keeping_the_worktree = None
    test_untracked_only_does_not_hold_a_closed_record_but_a_tracked_change_does = None
    test_a_reopen_in_flight_holds_the_close_and_its_new_window_is_reaped = None
    test_a_final_id_result_is_done_while_the_record_still_reads_open = None
    test_now_watcher_closes_about_its_grace_after_the_turn = None
    test_other_policy_or_no_flow_takes_the_ordinary_roads = None

    def test_over_closes_after_its_grace_keeping_the_worktree(self):
        self.answer.write_text("1\n")
        self.set("@claude_state_ts", str(int(time.time()) - 30))
        self.result("merged")
        self.assertNotIn("reaped", self.clean())          # 30 s < its 60 s grace
        self.assertTrue(self.exists())
        self.set("@claude_state_ts", str(int(time.time()) - 90))
        out = self.due()
        self.assertIn("reaped-over:" + self.win + " scratch-7", out)
        self.assertFalse(self.exists())
        self.assertTrue(self.wt.is_dir())
        self.assertIn("its work is over", (self.root / "ledger.tsv").read_text())

    def test_missing_result_never_marks_reminds_or_closes(self):
        self.answer.write_text("1\n")
        self.set("@claude_state_ts", str(int(time.time()) - 900000))
        for old_mark in ("", str(int(time.time()) - 900000)):
            self.set("@reap_unreported", old_mark)
            out = self.due()
            self.assertNotIn("marked-unreported", out)
            self.assertNotIn("reaped", out)
            self.assertFalse(self.nudges.exists())
            self.assertEqual(self.tm("show-option", "-wqv", "-t", self.win, "@reap_unreported").strip(), "")
            self.assertTrue(self.exists())

    def test_working_holds_but_person_uses_the_same_merged_policy(self):
        self.answer.write_text("1\n")
        self.result("merged")
        self.set("@claude_state", "working")
        self.assertNotIn("reaped", self.due())
        self.assertTrue(self.exists())
        self.set("@claude_state", "done")
        self.tm("set-option", "-wu", "-t", self.win, "@origin_fid")
        self.set("@reap_origin", "person")                # a person's ⌘P task: its record's road
        out = self.due()
        self.assertIn("reaped-over:" + self.win, out)

    def test_existing_keep_holds_regardless_of_who_set_it(self):
        self.answer.write_text("1\n")
        self.result("merged")
        self.set("@reap_policy", "keep")
        self.assertNotIn("reaped", self.due())            # a person's keep holds
        self.assertTrue(self.exists())
        self.set("@reap_keep_by", "session")
        out = self.due()
        self.assertNotIn("reaped", out)
        self.assertTrue(self.exists())

    def test_pin_and_role_do_not_override_explicit_merged(self):
        self.answer.write_text("0\n")
        self.result("merged")
        self.set("@pin", "1")
        self.set("@agent_def", "orchestrator")
        self.assertIn("reaped-over:" + self.win, self.due())
        self.assertFalse(self.exists())

    def test_driver_result_does_not_bypass_loop_end_grace(self):
        self.answer.write_text("1\n")
        self.set("@agent_def", "epic-driver")
        self.set("@reap_policy", "loop-end")
        self.set("@claude_state_ts", str(int(time.time()) - 5))
        self.result("succeeded")
        out = self.clean()
        self.assertNotIn("reaped", out)
        self.assertTrue(self.exists())


class ReapPolicy(Rig):
    """Each reap policy (issue #1902): reaped once due, kept before it, kept while
    working, and its unpushed work stays on disk."""
    def due(self):
        self.clean()
        if self.tm("display-message", "-p", "-t", self.win, "#{@reap_due}").strip().isdigit():
            self.set("@reap_due", str(int(time.time()) - 1))
        return self.clean()

    def policy(self, p):
        out = self.call("bash", str(self.ibin / "fleet-reap-policy.sh"), "set", p, "--win", self.win,
                        "--session", self.label)
        self.assertIn("reap_policy=", out)

    def test_done_waits_its_own_idle_then_reaps_keeping_unpushed_work(self):
        self.policy("done:2h")
        self.assertEqual(self.call("bash", str(self.ibin / "fleet-reap-policy.sh"), "get", "--win", self.win,
                                   "--session", self.label).strip(), "done:2h")
        self.due()                                   # idle 4000 s < 2 h: not yet
        self.assertTrue(self.exists())
        self.assertGreater(int(self.tm("display-message", "-p", "-t", self.win, "#{@reap_due}")), int(time.time()) + 3000)
        self.set("@claude_state", "working")
        self.set("@claude_state_ts", str(int(time.time()) - 9000))
        self.due()
        self.assertTrue(self.exists())               # working: never
        self.set("@claude_state", "done")
        self.call("git", "-C", str(self.wt), "-c", "user.name=T", "-c", "user.email=t@example.invalid",
                  "commit", "-qm", "unpushed", "--allow-empty")
        out = self.due()
        self.assertIn("reaped-idle:" + self.win + " policy=done:2h", out)
        self.assertFalse(self.exists())
        self.assertTrue(self.wt.is_dir())            # the worktree and its branch stay
        self.assertIn("unpushed", self.call("git", "-C", str(self.main), "log", "-1", "--format=%s", "scratch-7"))
        self.assertIn("reap policy done:2h", (self.root / "ledger.tsv").read_text())

    def test_scratch_default_is_fifteen_minutes_for_claude_and_codex(self):
        # Issue #3352 (发起人 2026-10-11, superseding ruling 7's two hours): a
        # scratch's `done` closes it 15 minutes after its turn ended — Claude and
        # Codex alike; 10 minutes in it stays.
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent):
                if agent == "codex":
                    self.tearDown()
                    self.setUp()
                    self.codexify()
                self.policy("done")
                self.assertEqual(self.call("bash", str(self.ibin / "fleet-reap-policy.sh"), "get", "--win", self.win,
                                           "--session", self.label).strip(), "done:15m")
                self.set("@claude_state_ts", str(int(time.time()) - 600))
                self.due()
                self.assertTrue(self.exists())
                self.set("@claude_state_ts", str(int(time.time()) - 1000))
                self.set("@reap_due", "")
                out = self.due()
                self.assertIn("reaped-idle:" + self.win + " policy=done:15m", out)
                self.assertFalse(self.exists())

    def test_keep_and_merged_are_never_this_pass(self):
        for p in ("keep", "merged", "merged:48h"):
            self.policy(p)
            self.set("@claude_state_ts", str(int(time.time()) - 900000))
            self.due()
            self.assertTrue(self.exists(), p)

    def test_at_only_once_the_time_has_come_and_never_while_working(self):
        self.policy("at:" + str(int(time.time()) + 3600))
        self.due()
        self.assertTrue(self.exists())
        self.policy("at:" + str(int(time.time()) - 60))
        self.set("@claude_state", "working")
        self.due()
        self.assertTrue(self.exists())
        self.set("@claude_state", "done")
        self.assertIn("reaped-idle:", self.due())
        self.assertFalse(self.exists())

    def test_loop_end_waits_for_the_loop(self):
        self.policy("loop-end")
        self.set("@loop", "kind=wakeup next=%d ttl=600" % (int(time.time()) + 600))
        self.due()
        self.assertTrue(self.exists())               # a round still pending
        self.set("@loop", "kind=wakeup next=%d ttl=600" % (int(time.time()) - 4000))
        self.assertIn("reaped-idle:", self.due())



@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class TestIdentity(Rig):
    """A no-repo session the TEST identity placed (issue #2505, @test_identity):
    its own policy closes it — done:10m counted from its last turn, or its birth
    when it never took one — while any other no-repo session stays (#791)."""
    def norepo(self, test, **opts):
        win = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", self.label,
                      "-c", str(self.root), "sleep 90").strip()
        fid = "%08x-0000-4000-8000-000000000000" % int(win[1:])
        for key, value in dict({"@norepo": "1", "@fleet_id": fid, "@reap_policy": "done:10m",
                                "@born": str(int(time.time()) - 1200)}, **opts).items():
            self.tm("set-option", "-w", "-t", win, key, value)
        if test:
            self.tm("set-option", "-w", "-t", win, "@test_identity", "1")
            # The placement verifier has saved its completed result. A native
            # empty/idle pane on its own is no longer completion evidence.
            self.call("python3", str(BIN / "fleet_id.py"), "result", fid, "--state", "succeeded",
                      "--summary", "placement verified")
        return win

    def alive(self, win):
        return win in self.tm("list-windows", "-t", self.label, "-F", "#{window_id}").split()

    def test_closes_a_test_session_past_its_policy_and_nothing_else(self):
        old = self.norepo(True)                                   # never took a turn, born 20 min ago
        young = self.norepo(True, **{"@born": str(int(time.time()) - 60)})
        busy = self.norepo(True, **{"@claude_state": "working",
                                    "@claude_state_ts": str(int(time.time()) - 4000)})
        mine = self.norepo(False)                                 # the person's own no-repo session
        out = self.clean()
        self.assertIn("reaped-test:" + old + " policy=done:10m", out)
        self.assertFalse(self.alive(old))
        self.assertTrue(self.alive(young))                        # its 10 minutes are not up
        self.assertTrue(self.alive(busy))                         # working: never
        self.assertTrue(self.alive(mine))                         # not a test's: #791 holds
        self.tm("set-option", "-w", "-t", busy, "@claude_state", "done")
        self.assertIn("reaped-test:" + busy, self.clean())        # done 4000 s ago
        self.assertFalse(self.alive(busy))

    def test_probe_origin_closes_after_a_saved_result(self):
        done = {"@claude_state": "done", "@claude_state_ts": str(int(time.time()) - 900)}
        probe = self.norepo(False, **dict(done, **{"@reap_origin": "probe"}))
        fid = self.tm("display-message", "-p", "-t", probe, "#{@fleet_id}").strip()
        self.call("python3", str(BIN / "fleet_id.py"), "result", fid, "--state", "succeeded",
                  "--summary", "probe completed")
        mine = self.norepo(False, **done)                          # a person's home session: waits for the exit
        self.clean()                                              # the countdown starts …
        if self.tm("display-message", "-p", "-t", probe, "#{@reap_due}").strip().isdigit():
            self.tm("set-option", "-w", "-t", probe, "@reap_due", str(int(time.time()) - 1))
        out = self.clean()                                        # … and runs out
        self.assertIn("reaped-idle:" + probe + " policy=done:10m norepo", out)
        self.assertFalse(self.alive(probe))
        self.assertTrue(self.alive(mine))


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class EmptyReap(Rig):
    """A no-repo session nobody ever typed into (issue #4000): opened with no words
    (@prompt_track), never a turn (no @prompted) — closed after its done grace from
    its birth; one that took a turn, holds a draft, is young, or predates the track
    (no @prompt_track) is never closed this way."""
    def norepo(self, screen="> ", **opts):
        win = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", self.label,
                      "-c", str(self.root), "printf %s " + shlex.quote(screen) + "; sleep 90").strip()
        fid = "%08x-0000-4000-8000-000000000000" % int(win[1:])
        for key, value in dict({"@norepo": "1", "@fleet_id": fid, "@reap_policy": "done:15m",
                                "@origin": "hub", "@prompt_track": "1",
                                "@born": str(int(time.time()) - 1200)}, **opts).items():
            self.tm("set-option", "-w", "-t", win, key, value)
        return win

    def alive(self, win):
        return win in self.tm("list-windows", "-t", self.label, "-F", "#{window_id}").split()

    def test_closes_only_a_session_never_typed_into(self):
        empty = self.norepo()
        typed = self.norepo(**{"@prompted": "1", "@claude_state": "done",
                               "@claude_state_ts": str(int(time.time()) - 1200)})
        draft = self.norepo("> half a sentence")
        young = self.norepo(**{"@born": str(int(time.time()) - 60)})
        old = self.norepo(**{"@prompt_track": ""})                 # opened before the track
        self.tm("set-option", "-wu", "-t", old, "@prompt_track")
        time.sleep(0.5)                                            # the panes have drawn
        out = self.clean()
        self.assertIn("reaped-empty:" + empty + " policy=done:15m", out)
        self.assertFalse(self.alive(empty))
        for win in (typed, draft, young, old):
            self.assertTrue(self.alive(win), win + " was closed: " + out)
        self.assertNotIn("reaped-empty:" + typed, out)

    def test_dry_run_closes_nothing(self):
        empty = self.norepo()
        time.sleep(0.5)
        out = self.clean("--dry-run")
        self.assertIn("would-reap-empty:" + empty, out)
        self.assertTrue(self.alive(empty))


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class WebPark(Rig):
    """A session the web opened (@session_origin web, task HHV0) is never closed: idle
    FLEET_SESSION_PARK_IDLE it is PARKED through fleet_session_gate.py park (here a
    stand-in that logs the fid); a young one is not, a parked one is left alone, 0
    never parks, and under memory pressure only the longest idle goes early."""
    def web(self, idle, **opts):
        win = self.tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", self.label,
                      "-c", str(self.root), "sleep 90").strip()
        fid = "%08x-0000-4000-8000-0000000000aa" % int(win[1:])
        for key, value in dict({"@norepo": "1", "@fleet_id": fid, "@reap_policy": "keep", "@reap_origin": "web",
                                "@session_origin": "web", "@park_wrap_ver": "1", "@claude_state": "done",
                                "@claude_state_ts": str(int(time.time()) - idle)}, **opts).items():
            self.tm("set-option", "-w", "-t", win, key, value)
        return win, fid

    def gate(self):
        log = self.root / "gate.log"
        stub = self.root / "gate-stub"
        stub.write_text("#!/bin/sh\necho \"$*\" >> %s\necho '{\"ok\": true}'\n" % shlex.quote(str(log)))
        stub.chmod(0o755)
        self.env["FLEET_SESSION_GATE_CMD"] = str(stub)
        self.env["FLEET_PARK_MEM_FREE"] = "50"
        return log

    def test_parks_after_its_idle_never_closes(self):
        log = self.gate()
        idle, fid = self.web(400)
        young, yfid = self.web(30)
        parked, pfid = self.web(4000, **{"@parked": "1"})
        out = self.clean()
        self.assertIn("parked-web:" + idle + " idle", out)
        text = log.read_text() if log.exists() else ""
        self.assertIn("park --fid " + fid + " --why idle", text)
        self.assertNotIn(yfid, text)
        self.assertNotIn(pfid, text)
        for win in (idle, young, parked):
            self.assertIn(win, self.tm("list-windows", "-t", self.label, "-F", "#{window_id}").split(),
                          win + " was closed: " + out)

    def test_zero_never_parks_and_memory_parks_the_oldest_first(self):
        log = self.gate()
        self.env["FLEET_SESSION_PARK_IDLE"] = "0"
        a, afid = self.web(4000)
        self.clean()
        self.assertFalse(log.exists() and afid in log.read_text())
        self.env.pop("FLEET_SESSION_PARK_IDLE")
        self.tm("set-option", "-w", "-t", a, "@parked", "1")
        old, ofid = self.web(200)
        new, nfid = self.web(120)
        self.env["FLEET_PARK_MEM_FREE"] = "5"
        out = self.clean()
        self.assertIn("parked-web:" + old + " memory", out)
        self.assertNotIn(nfid, log.read_text())


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class HomeReap(ReapPolicy):
    """A no-repo (home) session (issue #2565): `done:2h` closes it two hours after
    its agent EXITED — never on a finished turn (#2564 resumes that one), never
    without a policy (#791); a pin is only the list's order (issue #3119)."""
    def setUp(self):
        super().setUp()
        for key in ("@raw", "@worktree"):
            self.tm("set-option", "-wu", "-t", self.win, key)
        self.set("@norepo", "1")
        self.set("@fleet_id", "%08x-0000-4000-8000-000000000000" % int(self.win[1:]))

    def test_exited_two_hours_closes_an_idle_turn_never(self):
        self.policy("done:2h")
        self.set("@claude_state_ts", str(int(time.time()) - 9000))
        self.due()
        self.assertTrue(self.exists())               # done for hours: still the current session
        self.set("@claude_state", "exited")
        self.set("@claude_state_ts", str(int(time.time()) - 4000))
        self.due()
        self.assertTrue(self.exists())               # exited 4000 s < 2 h: not yet
        self.set("@claude_state_ts", str(int(time.time()) - 9000))
        out = self.due()
        self.assertIn("reaped-idle:" + self.win + " policy=done:2h norepo", out)
        self.assertFalse(self.exists())

    def test_no_policy_and_keep_hold_but_pin_is_only_order(self):
        self.set("@claude_state", "exited")
        self.set("@claude_state_ts", str(int(time.time()) - 900000))
        self.due()
        self.assertTrue(self.exists())               # no policy: #791, as before
        self.policy("keep")
        self.set("@pin", "1")
        self.due()
        self.assertTrue(self.exists())               # keep: never
        self.policy("done:2h")
        out = self.due()                             # pin does not override done:2h
        self.assertIn("reaped-idle:" + self.win + " policy=done:2h norepo", out)
        self.assertFalse(self.exists())

    def test_idle_closes_a_finished_turn_not_only_an_exit(self):
        # T694: a person's own home session (idle:2h) goes after two idle hours,
        # its agent still up — `done` there waits for the exit.
        self.policy("idle:2h")
        self.set("@claude_state", "done")
        self.set("@claude_state_ts", str(int(time.time()) - 4000))
        self.due()
        self.assertTrue(self.exists())               # idle 4000 s < 2 h
        self.set("@claude_state_ts", str(int(time.time()) - 9000))
        out = self.due()
        self.assertIn("reaped-idle:" + self.win + " policy=idle:2h norepo", out)
        self.assertFalse(self.exists())

    def test_ancestry_does_not_override_norepo_done_policy(self):
        self.policy("done:5m")
        self.set("@claude_state_ts", str(int(time.time()) - 600))
        self.clean()
        self.assertTrue(self.exists())
        self.set("@origin", "1f0e0000-0000-4000-8000-000000004341")
        self.clean()
        self.assertTrue(self.exists())               # stale parent cannot change done
        self.set("@claude_state", "working")
        self.clean()
        self.assertTrue(self.exists())               # a working turn is never eligible
        self.set("@claude_state", "exited")
        self.set("@claude_state_ts", str(int(time.time()) - 120))
        self.clean()
        self.assertTrue(self.exists())               # exited less than the chosen grace
        self.set("@claude_state_ts", str(int(time.time()) - 600))
        out = self.due()
        self.assertIn("reaped-idle:" + self.win + " policy=done:5m norepo", out)
        self.assertFalse(self.exists())

    def test_spawned_norepo_without_policy_is_never_closed(self):
        self.set("@origin", "1f0e0000-0000-4000-8000-000000004341")
        self.set("@claude_state_ts", str(int(time.time()) - 900000))
        self.due()
        self.assertTrue(self.exists())               # no policy: #791, as before

    # the inherited worktree-session cases do not apply to a home session
    test_done_waits_its_own_idle_then_reaps_keeping_unpushed_work = None
    test_keep_and_merged_are_never_this_pass = None
    test_at_only_once_the_time_has_come_and_never_while_working = None
    test_loop_end_waits_for_the_loop = None
    test_sleep_on_considers_only_windows_with_a_policy = None
    test_scratch_default_is_fifteen_minutes_for_claude_and_codex = None


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class PinIsOrder(ReapPolicy):
    """PIN changes order only; no policy migration and no automatic keep."""
    def mark(self):
        return self.root / "conf" / "global" / "pin-keep.done"

    def test_first_pass_does_not_migrate_pin_to_keep(self):
        self.set("@pin", "1")
        self.set("@claude_state", "working")
        out = self.clean()
        self.assertNotIn("pin-keep:", out)
        self.assertEqual(self.tm("show-option", "-wqv", "-t", self.win, "@reap_policy").strip(), "")
        self.assertFalse(self.mark().exists())
        self.set("@reap_policy", "keep")
        self.set("@claude_state", "done")
        self.set("@claude_state_ts", str(int(time.time()) - 900000))
        self.due()
        self.assertTrue(self.exists())
        self.assertEqual(self.tm("show-option", "-wqv", "-t", self.win, "@reap_policy").strip(), "keep")

    def test_pin_does_not_override_existing_done_policy(self):
        self.set("@pin", "1")
        self.set("@reap_policy", "done:5m")
        self.set("@claude_state_ts", str(int(time.time()) - 900000))
        out = self.due()
        self.assertIn("reaped-idle:" + self.win, out)
        self.assertFalse(self.exists())
        self.assertFalse(self.mark().exists())

    def test_dry_run_migrates_nothing(self):
        self.set("@pin", "1")
        self.clean("--dry-run")
        self.assertFalse(self.mark().exists())
        self.assertEqual(self.tm("display-message", "-p", "-t", self.win, "#{@reap_policy}").strip(), "")

    test_done_waits_its_own_idle_then_reaps_keeping_unpushed_work = None
    test_keep_and_merged_are_never_this_pass = None
    test_at_only_once_the_time_has_come_and_never_while_working = None
    test_loop_end_waits_for_the_loop = None
    test_sleep_on_considers_only_windows_with_a_policy = None
    test_scratch_default_is_fifteen_minutes_for_claude_and_codex = None


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class DoneNoPr(Rig):
    """A finished session no PR will ever close (issue #1832): closed two hours
    after its last turn, its worktree dropped only when clean with nothing of its
    own, and every refusal said as a token."""
    def setUp(self):
        super().setUp()
        self.set("@raw", "")                         # a spawned scratch, no policy
        (self.root / "issue.json").write_text('{"state":"CLOSED"}')
        (self.root / "fake/gh").write_text(
            '#!/bin/sh\nif [ "$1" = issue ]; then cat ' + shlex.quote(str(self.root / "issue.json"))
            + '; else cat ' + shlex.quote(str(self.root / "prs.json")) + '; fi\n')

    def ago(self, secs):
        self.set("@claude_state_ts", str(int(time.time()) - secs))

    def due(self):
        out = self.clean()
        if self.tm("display-message", "-p", "-t", self.win, "#{@reap_due}").strip().isdigit():
            self.set("@reap_due", str(int(time.time()) - 1))
            out += self.clean()
        return out

    def listed(self):
        return str(self.wt) in self.call("git", "-C", str(self.main), "worktree", "list")

    def test_recent_is_kept_and_said_once(self):
        self.ago(3600)
        out = self.clean()
        self.assertIn("skip:done-recent " + self.win + " scratch-7", out)
        self.assertEqual(self.clean(), "")           # the same skip is not repeated
        self.assertTrue(self.exists())

    def test_two_hours_clean_closes_and_drops_the_worktree(self):
        self.ago(7300)
        self.assertIn("would-clean:done-no-pr " + self.win, self.clean("--dry-run"))
        self.assertTrue(self.exists())
        out = self.due()
        self.assertIn("cleaned:done-no-pr " + self.win + " scratch-7 worktree=trashed", out)
        self.assertFalse(self.exists())
        self.assertFalse(self.listed())
        self.assertIn("scratch-7", self.call("git", "-C", str(self.main), "branch", "--list", "scratch-7"))
        self.assertIn(self.sid, (self.root / "ledger.tsv").read_text())   # recorded first

    def test_native_owned_worktree_keeps_window_and_data(self):
        self.ago(7300)
        metadata = Path(self.call("git", "-C", str(self.wt), "rev-parse", "--absolute-git-dir").strip())
        (metadata / "CLAUDE_BASE").write_text(self.call("git", "-C", str(self.wt), "rev-parse", "HEAD"))
        self.assertIn("error:native-owned", self.clean())
        self.assertTrue(self.exists())
        self.assertTrue(self.listed())

    def test_git_locked_worktree_keeps_window_and_data(self):
        self.ago(7300)
        self.call("git", "-C", str(self.main), "worktree", "lock", str(self.wt))
        self.assertIn("error:locked", self.clean())
        self.assertTrue(self.exists())
        self.assertTrue(self.listed())

    def test_codex_worker_closes_like_a_claude_one(self):
        # Issue #3352: a Codex worker whose issue closed with no PR goes the same
        # road, on the same state stamps.
        self.codexify()
        self.set("@issue", "12")
        self.ago(7300)
        out = self.due()
        self.assertIn("cleaned:done-no-pr " + self.win, out)
        self.assertFalse(self.exists())

    def test_dirty_or_unpushed_only_closes_the_window(self):
        self.ago(7300)
        (self.wt / "dirty").write_text("keep")
        self.assertIn("worktree=kept:dirty", self.due())
        self.assertFalse(self.exists())
        self.assertTrue((self.wt / "dirty").is_file())
        self.assertTrue(self.listed())

    def test_unpushed_commit_keeps_the_worktree(self):
        self.ago(7300)
        self.call("git", "-C", str(self.wt), "-c", "user.name=T", "-c", "user.email=t@example.invalid",
                  "commit", "-qm", "unpushed", "--allow-empty")
        self.assertIn("worktree=kept:unpushed", self.due())
        self.assertFalse(self.exists())
        self.assertTrue(self.listed())

    def test_working_pr_open_issue_and_keep_are_kept(self):
        self.ago(9000)
        self.set("@claude_state", "working")
        self.assertEqual(self.due(), "")
        self.assertTrue(self.exists())
        self.set("@claude_state", "done")
        (self.root / "prs.json").write_text('[{"state":"OPEN"}]')
        self.assertIn("skip:has-pr " + self.win, self.due())
        self.assertTrue(self.exists())
        (self.root / "prs.json").write_text("[]")
        self.set("@issue", "12")
        (self.root / "issue.json").write_text('{"state":"OPEN"}')
        self.assertIn("skip:issue-open " + self.win + " scratch-7 #12", self.due())
        self.assertTrue(self.exists())
        for p in ("keep", "merged"):
            self.set("@issue", "" if p == "merged" else "12")
            self.set("@reap_policy", p)
            self.due()
            self.assertTrue(self.exists(), p)        # keep never; merged on a scratch is a PR's

    def test_closed_issue_with_merged_policy_and_no_worktree(self):
        # #2446: an issue session, policy merged, its issue closed with no PR — and
        # here its worktree already gone (#2417 on this machine): the window closes.
        self.ago(9000)
        self.set("@issue", "12")
        self.set("@reap_policy", "merged")
        self.call("git", "-C", str(self.main), "worktree", "remove", "--force", str(self.wt))
        out = self.due()
        self.assertIn("cleaned:done-no-pr " + self.win + " scratch-7 worktree=gone", out)
        self.assertFalse(self.exists())
        self.assertIn("finished with no PR", (self.root / "ledger.tsv").read_text())


    def test_no_policy_closed_ticket_with_final_prs_closes(self):
        # #2970: no @reap_policy is not «never». Its issue closed, every PR on its
        # branch final, idle past the grace ⇒ closed the done-no-pr way; an open
        # issue, an open PR or `keep` ⇒ kept.
        self.ago(9000)
        self.set("@issue", "12")
        (self.root / "prs.json").write_text('[{"state":"MERGED"},{"state":"CLOSED"}]')
        (self.root / "issue.json").write_text('{"state":"OPEN"}')
        self.assertIn("skip:issue-open " + self.win, self.due())
        self.assertTrue(self.exists())
        (self.root / "issue.json").write_text('{"state":"CLOSED"}')
        (self.root / "prs.json").write_text('[{"state":"MERGED"},{"state":"OPEN"}]')
        self.assertIn("skip:has-pr " + self.win, self.due())
        self.assertTrue(self.exists())
        (self.root / "prs.json").write_text('[{"state":"MERGED"}]')
        self.set("@reap_policy", "keep")
        self.due()
        self.assertTrue(self.exists())                # keep: never
        self.tm("set-option", "-wu", "-t", self.win, "@reap_policy")
        out = self.due()
        self.assertIn("cleaned:done-no-pr " + self.win + " scratch-7", out)
        self.assertFalse(self.exists())
        self.assertIn("every PR final", (self.root / "ledger.tsv").read_text())

    def test_driver_scratch_closes_once_its_epic_is_closed(self):
        # #2970: a batch driver's scratch (@raw, no @issue, @epic) with no policy
        # goes by its EPIC: open ⇒ kept, closed ⇒ closed; another repo's EPIC is
        # not this pass's ticket (a plain scratch: the idle rule).
        self.set("@raw", "1")
        self.set("@epic", "acme/repo#99")
        self.ago(9000)
        (self.root / "issue.json").write_text('{"state":"OPEN"}')
        self.assertIn("skip:issue-open " + self.win + " scratch-7 #99", self.due())
        self.assertTrue(self.exists())
        (self.root / "issue.json").write_text('{"state":"CLOSED"}')
        self.assertIn("cleaned:done-no-pr " + self.win, self.due())
        self.assertFalse(self.exists())

class StuckReaps(unittest.TestCase):
    """Issue #4822: the finished windows nothing closed on a multi-repo fleet.
    Last in the module on purpose — a case added above would move every later
    case to another stride part (part 4/4's groups are named one by one)."""
    def cleaner(self, repo, opts):
        args = argparse.Namespace(session="s", socket_name="s", main="/nonexistent", repo=repo,
                                  base="master", limit=4, forge="github", window_repo=True,
                                  dry_run=False)
        c = idle.Cleaner(args)
        self.writes = []

        def tm(*argv):
            if argv[0] == "display-message":
                # the one-call snapshot asks "#{a}\t#{b}…": answer each name it asked
                return "\t".join(opts.get(n[2:-1], "") for n in argv[-1].split("\t"))
            self.writes.append(argv)
            return ""
        c.tm = tm
        return c

    def test_another_repos_pass_leaves_the_countdown(self):
        # A done:10m window of acme/two, its countdown set by acme/two's pass: the
        # acme/one pass of the same tick used to call clear() on it, every tick.
        opts = {"@repo": "acme/two", "@issue": "7", "@reap_policy": "done:10m",
                "@claude_state": "exited", "@claude_state_ts": "100", "@worktree": "/nonexistent/wt",
                "@reap_key": "idle:abc", "@reap_due": "200", "window_name": "w"}
        c = self.cleaner("acme/one", opts)
        self.assertFalse(c.candidate("@5"))
        self.assertEqual([w for w in self.writes if "-wu" in w], [])
        # its own pass still clears a countdown it no longer stands behind
        c = self.cleaner("acme/two", opts)
        with patch.object(idle.Cleaner, "eligible", return_value=False):
            self.assertFalse(c.candidate("@5"))
        self.assertIn(("set-option", "-wu", "-t", "@5", "@reap_due"), self.writes)

    def test_the_agents_finished_word_outranks_a_looping_stamp(self):
        # The Stop hook stamped `looping` for a child that has since ended; the
        # agent itself said `done` (OSC 7501). What is really pending is busy()'s
        # and fleet-reap-live's to say, not the stamp's.
        def st(word):
            return '{"state":"%s"}' % word
        for word, want in (("done", "done"), ("idle", "done"), ("error", "exited"),
                           ("working", "looping"), ("blocked", "looping"), ("", "looping")):
            snap = {"@claude_state": "looping", "@agent_status": st(word) if word else ""}
            self.assertEqual(idle.Cleaner.finished(snap), want, word)
        opts = {"@claude_state": "looping", "@claude_state_ts": "100", "@agent_status": st("done")}
        def tm(*args):
            if args[0] == "display-message":
                return opts.get(args[-1][2:-1], "")
            if args[1] == "-wu":
                opts.pop(args[-1], None)
            else:
                opts[args[-2]] = args[-1]
            return ""
        self.assertEqual(notice(tm, "@1", "merged:9:abc", 0, 500), 560)
        opts["@agent_status"] = st("working")
        with self.assertRaises(ValueError):
            notice(tm, "@1", "merged:9:abc", 0, 600)



class ParkTable(unittest.TestCase):
    """C6: drive fleet-cleanup-idle.py and fleet_reap_policy.py for every origin.
    The E101 real tmux/history round trip below proves the close is resumable.
    """
    def test_finished_probe_keeps_its_one_minute_policy(self):
        args = argparse.Namespace(socket_name="test", session="test", main="/missing", repo="o/r",
                                  base="master", window_repo=False, dry_run=False)
        c = idle.Cleaner(args)
        c.now, c._mem = 200, (False, "")
        c._park_watched = set()
        with patch.object(c, "tm", return_value=""):
            snap = c.snapshot("@9")
        snap.update({"@reap_origin": "probe", "@reap_policy": "done:1m", "@park_wrap_ver": "1",
                     "@claude_state": "done", "@claude_state_ts": "100",
                     "@test_identity": "1", "@norepo": "1"})
        with patch.object(c, "work_over", return_value=True), patch.object(c, "waiting", return_value=None), \
                patch.object(c, "test_session", return_value=False) as reap, \
                patch.object(idle, "run") as gate:
            c.road("@9", snap)
            # The official reaper, including its live / history checks, gets
            # to decide. Five-minute parking must not delay a finished probe.
            reap.assert_called_once_with("@9", snap)
            gate.assert_not_called()

    def test_decide_keeps_idle_policy_except_reported_waiting(self):
        args = argparse.Namespace(socket_name="test", session="test", main="/missing", repo="o/r",
                                  base="master", window_repo=False, dry_run=True)
        c = idle.Cleaner(args)
        c.now = 500
        with patch.object(c, "tm", return_value=""):
            snap = c.snapshot("@9")
        snap.update({"@reap_origin": "decide", "@reap_policy": "idle:15m",
                     "@park_wrap_ver": "1", "@parked": "400", "@park_held": "1",
                     "@park_since": "400", "@claude_state_ts": "100"})
        # Parking must return an ordinary decision session to its existing
        # policy road, whose history / live-work / keep gates still own closing.
        self.assertIsNone(c.parked("@9", snap))
        self.assertEqual(c.deadline(snap, c.policy(snap)), 1000)
        self.assertEqual(idle.fleet_reap_policy.effective("idle:15m"), "idle:15m")
        snap["@reap_why"] = "timer:1000"
        self.assertIn("next=reap@1970-01-01T00:16:40Z", idle.fleet_reap_policy.explain(snap, now=500))
        # E101 is an explicit waiting report, not the origin's name.
        snap["@park_waiting"] = "1"
        with patch.dict(os.environ, {"FLEET_SESSION_REAP_PARKED": "3d"}):
            self.assertFalse(c.parked("@9", snap))
            self.assertEqual(idle.fleet_reap_policy.parked_deadline(snap), 259600)
        for opts in ({"@pin": "1"}, {"@reap_policy": "keep", "@reap_keep_by": "person"}):
            self.assertFalse(c.parked("@9", dict(snap, **opts)))

    def test_park_refusal_reaches_doctor(self):
        args = argparse.Namespace(socket_name="test", session="test", main="/missing", repo="o/r",
                                  base="master", window_repo=False, dry_run=False)
        c = idle.Cleaner(args)
        c.now, c._mem = 1000, (False, "")
        with patch.object(c, "tm", return_value=""):
            snap = c.snapshot("@9")
        snap.update({"@reap_origin": "person", "@park_wrap_ver": "1", "@claude_state": "done",
                     "@claude_state_ts": "100", "@fleet_id": "00000009-0000-4000-8000-0000000000aa"})
        for reason, code in (("watched", "watched"), ("draft", "draft"), ("bg", "park-bg"),
                             ("asking", "asking"), ("old_wrapper", "old-wrapper"),
                             ("probe_failed", "park-gate")):
            with self.subTest(reason=reason), patch.object(c, "tm", return_value=""), \
                    patch.object(idle, "run", return_value=json.dumps({"ok": False, "why": reason})):
                c._park_watched, c.why = set(), ""
                self.assertFalse(c.web_park("@9", snap))
                self.assertEqual(c.why, code)
                explanation = idle.fleet_reap_policy.explain(dict(snap, **{"@reap_why": c.why}), now=c.now)
                self.assertIn("next=park-held", explanation)
                self.assertIn("why=" + code, explanation)
        with patch.object(c, "tm", return_value=""), patch.object(idle, "run") as gate:
            c._park_watched = {"@9"}
            self.assertFalse(c.web_park("@9", snap))
            gate.assert_not_called()
            self.assertEqual(c.why, "watched")

    def test_each_origin_has_a_park_and_reap_column(self):
        rp = idle.fleet_reap_policy
        for origin, reap in (("person", "parked"), ("probe", "done")):
            with self.subTest(origin=origin):
                self.assertEqual(rp.ORIGINS[origin]["park"], "idle")
                self.assertEqual(rp.ORIGINS[origin]["reap"], reap)

    def test_activity_and_keep_hold_expiration(self):
        rp = idle.fleet_reap_policy
        snap = {"@reap_origin": "person", "@park_wrap_ver": "1", "@parked": "100",
                "@park_held": "1", "@park_since": "100", "@park_presence": "200"}
        with patch.dict(os.environ, {"FLEET_SESSION_REAP_PARKED": str(366 * 86400)}):
            self.assertEqual(rp.reap_parked_secs(), 366 * 86400)
        with patch.dict(os.environ, {"FLEET_SESSION_REAP_PARKED": "1h"}):
            self.assertEqual(rp.parked_deadline(snap), 3800)
            finished = {"@reap_origin": "person", "@park_wrap_ver": "1", "@claude_state": "looping",
                        "@agent_status": '{"state":"done"}', "@claude_state_ts": "100"}
            self.assertIn("next=park@", rp.explain(finished, now=200))
            self.assertEqual(rp.parked_deadline(dict(snap, **{"@pin": "1"})), 3800)
            for by in ("", "person", "session"):
                self.assertIsNone(rp.parked_deadline(dict(snap, **{"@reap_policy": "keep", "@reap_keep_by": by})))

    def test_driver_reads_every_origin_without_closing_early(self):
        args = argparse.Namespace(socket_name="test", session="test", main="/missing", repo="o/r",
                                  base="master", window_repo=False, dry_run=True)
        c = idle.Cleaner(args)
        c.now = 200
        for origin in idle.fleet_reap_policy.ORIGINS:
            with self.subTest(origin=origin):
                snap = {"@reap_origin": origin, "@park_wrap_ver": "1", "@parked": "100",
                        "@park_held": "1", "@park_since": "100", "@claude_state_ts": "90"}
                with patch.object(c, "policy", return_value=("merged", 0)), patch.object(c, "work_over", return_value=True):
                    result = c.parked("@9", snap)
                if origin in ("dispatched", "member", "driver", "probe", "decide"):
                    self.assertIsNone(result)  # completion/unreported policy still runs
                else:
                    self.assertFalse(result)  # retention or permanent keep


    def test_park_expiry_and_doctor_share_the_deadline(self):
        rp = idle.fleet_reap_policy
        snap = {"@reap_origin": "person", "@park_wrap_ver": "1", "@parked": "100",
                "@park_held": "1", "@park_since": "100", "@claude_state_ts": "90"}
        with patch.dict(os.environ, {"FLEET_SESSION_REAP_PARKED": "3d"}):
            self.assertEqual(rp.parked_deadline(snap), 259300)
            self.assertIn("1970-01-04T00:01:40Z", rp.explain(snap, now=200))
            self.assertIsNone(rp.parked_deadline(dict(snap, **{"@reap_policy": "merged"})))
            self.assertIsNone(rp.parked_deadline(dict(snap, **{"@reap_policy": "done:10m"})))
            snap["@reap_origin"] = "orchestrator"
            self.assertEqual(rp.parked_deadline(snap), 259300)
            self.assertIn("1970-01-04T00:01:40Z", rp.explain(snap, now=200))
            snap["@reap_origin"] = "person"
            snap["@park_held"] = ""
            self.assertIsNone(rp.parked_deadline(snap))


if __name__ == "__main__":
    import selftest_part
    # Parts 1–3 (every case its own rig: a git repo, a tmux server, ~0.6 s of
    # clean() passes each) run as three processes at once — the tmux label is the
    # pid's. Part 4/4 never: RigCalls is one budget per process.
    if os.environ.get("SELFTEST_PART") in ("1/4", "2/4", "3/4"):
        selftest_part.fan_out(3, argv_prefix=[str(BIN)])
    try:
        selftest_part.main()
    finally:
        if RIG_CALLS is not None:
            RIG_CALLS.finish()
