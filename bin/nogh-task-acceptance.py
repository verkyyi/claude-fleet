#!/usr/bin/env python3
"""EPIC #4390 A1–A12: bounded FIXTURE acceptance, never live acceptance.

Prepare dependencies separately; run inside an empty Linux network namespace.
See docs/dev/TASK-ACCEPTANCE.md. No fleet/node configuration is changed.
"""
import argparse
import datetime
import hashlib
import ipaddress
import json
import os
import pwd
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
GO_DIRS = {"agent": ROOT/"tokenledger/agent"}

# A row passes only when every named boundary actually ran. Shared boundaries
# run once; their real command, exit, log and counters are linked from each row.
# A2 (reconnect and adapter restart) retired with the launch proof and the
# task-receipt journal it exercised (EPIC T497 C8).
ROWS = {
    "A1": ("forge-none explicit Codex", ["baseline", "dispatch", "provider"]),
    "A3": ("remote child, wait and report", ["children", "collaboration"]),
    "A4": ("GitHub repo, blocked then restored PR gate", ["cutover", "landing", "pr-gate"]),
    "A5": ("stale labels and defaults", ["dispatch", "provider"]),
    "A6": ("duplicate requests and lost ack", ["authority", "dispatch"]),
    "A7": ("late report and ownership transfer", ["authority", "collaboration", "children"]),
    "A8": ("same issue number and foreign owner", ["authority", "collaboration"]),
    "A9": ("hub outage and bounded journal", ["outbox", "projection", "browser"]),
    "A10": ("cancel/recover race with partition", ["collaboration"]),
    "A11": ("migration and rollback with active sessions", ["migration", "cutover", "repo-cli"]),
    "A12": ("portal, thin client and native agent UX", ["projection", "browser", "thin"]),
}


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def network_counts(trace):
    """Count supplied non-loopback socket destinations, even ENETUNREACH.

    HTTP is a conservative superset of GitHub HTTP (external ports 80/443).
    All other external attempts, including DNS/SSH, fail the run as well.
    AF_UNIX and local fixture HTTP are allowed. Never trace payloads/argv.
    """
    counts = dict(external_http=0, other_external=0, blocked_io_uring=0)
    for line in trace.splitlines():
        if "io_uring_setup(" in line:
            if "= -1 ENOSYS" not in line or "(INJECTED)" not in line:
                raise ValueError("unfenced io_uring is outside this observer's supported HTTP paths")
            counts["blocked_io_uring"] += 1
        if "io_uring_enter(" in line:
            raise ValueError("io_uring submission is outside this observer's supported HTTP paths")
        # Netlink route-query payloads contain rtm_family=AF_INET; only a
        # sockaddr's sa_family describes a network syscall destination.
        if not re.search(r'\bsa_family=AF_INET6?\b', line):
            continue
        destinations = re.findall(r'\{sa_family=AF_INET6?[, ].*?\}', line)
        if len(destinations) != len(re.findall(r'sa_family=AF_INET6?\b', line)) or not destinations:
            raise ValueError("unrecognized network trace: " + line)
        for destination in destinations:
            address = re.search(r'(?:inet_addr\(|inet_pton\(AF_INET6, )"([^"]+)"', destination)
            port = re.search(r'(?:sin_port|sin6_port)=htons\((\d+)\)', destination)
            if not address or not port:
                raise ValueError("unrecognized network destination: " + destination)
            ip = ipaddress.ip_address(address[1])
            if ip.is_loopback or bool(getattr(ip, "ipv4_mapped", None) and ip.ipv4_mapped.is_loopback):
                continue
            counts["external_http" if port[1] in ("80", "443") else "other_external"] += 1
    return counts


def gh_executions(trace):
    """Executable paths are printed in full by strace -s0; argv/env are not.

    Observe successful AND failed exec attempts, regardless of PATH or fixture
    shim. These fixtures invoke gh as an executable, not sourced shell code.
    """
    paths = []
    for line in trace.splitlines():
        if not re.search(r'\bexecve(?:at)?\(', line):
            continue
        match = re.search(r'\bexecve(?:at)?\((?:[^,]+, )?"([^"]+)"', line)
        if not match:
            raise ValueError("unrecognized executable trace: " + line)
        if Path(match[1]).name == "gh":
            paths.append(match[1])
    return paths


def valid_output(kind, output, names=()):
    if re.search(r'\bSKIP\b|skipped=|\bskipped\b|no tests to run', output):
        return False
    if kind == "go":
        return all(re.search(r'^--- PASS: ' + re.escape(n) + r' \(', output, re.M) for n in names)
    if kind == "python":
        return bool(re.search(r'Ran [1-9]\d* tests?', output) and re.search(r'^OK$', output, re.M))
    if kind == "baseline":
        return "steps: 7/7 · gh calls: 0 · github http: 0" in output
    return bool(re.search(r'\bPASS\b', output))


def child_command(argv, cleanup_path):
    """Own/reap only this command's descendants, including detached test helpers.

    strace -f otherwise waits for an intentionally backgrounded fixture helper
    after the actual test exited. A Linux subreaper keeps those children ours;
    never scan a fleet socket, process name or another session's processes.
    """
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "could not own fixture descendants")
    code = subprocess.call(argv)
    cleaned = []

    def children():
        return [int(p) for p in Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()]

    def reap():
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
                if not pid:
                    return
            except ChildProcessError:
                return

    # Reparenting may reveal a grandchild after its direct parent exits.
    for sig, limit in ((signal.SIGTERM, 2), (signal.SIGKILL, 2)):
        until = time.monotonic()+limit
        while time.monotonic() < until:
            reap()
            remaining = children()
            if not remaining:
                break
            for pid in remaining:
                try:
                    name = Path(f"/proc/{pid}/comm").read_text().strip()
                    os.kill(pid, sig)
                    cleaned.append(dict(pid=pid, command=name, signal=sig, at=utc()))
                except ProcessLookupError:
                    pass
            time.sleep(0.05)
    reap()
    remaining = children()
    write(Path(cleanup_path), dict(command_exit=code, cleanup=cleaned, remaining=remaining))
    return code if not remaining else 125


class Harness:
    def __init__(self, work):
        self.work = work
        self.evidence = work / "evidence"
        self.evidence.mkdir(parents=True, exist_ok=True)
        self.started = time.monotonic()
        self.results = {}
        self.env = dict(os.environ)
        # The CI wrapper supplies a clean env; repeat the credential/fleet strip
        # for a manual invocation, and give every subprocess private state.
        for k in list(self.env):
            if k.startswith(("FLEET_", "CCQUOTA_", "GITHUB_", "GH_", "CODEX_", "CLAUDE_")) or k in ("TMUX", "TMUX_PANE"):
                self.env.pop(k)
        for directory in ("home", "tmp", "shim", "conf"):
            (work / directory).mkdir(exist_ok=True)
        self.env.update(HOME=str(work/"home"), TMPDIR=str(work/"tmp"),
                        USER=pwd.getpwuid(os.getuid()).pw_name, LOGNAME=pwd.getpwuid(os.getuid()).pw_name, SHELL="/bin/bash",
                        FLEET_CONF_DIR=str(work/"conf"), FLEET_SKIP_GLOBAL_CONF="1",
                        PATH=str(work/"shim")+os.pathsep+self.env["PATH"],
                        PYTHONDONTWRITEBYTECODE="1", GIT_CONFIG_NOSYSTEM="1",
                        UV_USE_IO_URING="0",
                        GIT_CONFIG_GLOBAL="/dev/null", LANG="C.UTF-8",
                        NOGH_ACCEPTANCE_EVIDENCE=str(self.evidence))
        shim = work / "shim/gh"
        shim.write_text('#!/bin/sh\nprintf "attempt\\n" >> "$NOGH_GH_LOG"\nexit 91\n')
        shim.chmod(0o700)

    def run(self, name, argv, kind="marker", names=(), timeout=60, expected_cli=0, mocked_cli=0, env=None, cwd=ROOT):
        log, trace, cli = [self.evidence/(name+suffix) for suffix in (".log", ".network", ".gh")]
        cli.write_text("")
        command = ["strace", "-f", "-qq", "-v", "-s", "0", "-e",
                   "trace=execve,execveat,connect,sendto,sendmsg,sendmmsg,io_uring_setup,io_uring_enter",
                   "-e", "inject=io_uring_setup:error=ENOSYS", "-o", str(trace),
                   sys.executable, str(Path(__file__).resolve()), "--child", str(self.evidence/(name+"-cleanup.json")), *map(str, argv)]
        record = dict(command=list(map(str, argv)), cwd=str(cwd), started_at=utc(), fixture="FAIL", log=log.name)
        deadline = min(timeout, max(0.1, 600 - (time.monotonic()-self.started)))
        print("START", name, record["started_at"], flush=True)
        with log.open("w") as output:
            p = subprocess.Popen(command, cwd=cwd, env=dict(self.env, NOGH_GH_LOG=str(cli), **(env or {})),
                                 stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = p.wait(timeout=deadline)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGTERM)
                try:
                    p.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid, signal.SIGKILL)
                    p.wait()
                code = 124
        output = log.read_text(errors="replace")
        observed = trace.read_text(errors="replace")
        try:
            counters = network_counts(observed)
            executions = gh_executions(observed)
        except ValueError as exc:
            record.update(exit=code, finished_at=utc(), observation_error=str(exc), counters=None)
            self.results[name] = record
            write(self.evidence/(name+".json"), record)
            raise
        counters["github_cli"] = len(executions)
        counters["deny_shim_cli"] = len(cli.read_text().splitlines())
        counters["mocked_cli"] = mocked_cli
        good = code == 0 and valid_output(kind, output, names)
        if name == "deny-probe":
            good = good and counters["external_http"] >= 5 and "AF_INET6" in observed
            good = good and counters["blocked_io_uring"] >= 1
            good = good and all(s+"(" in observed for s in ("connect", "sendto", "sendmsg", "sendmmsg", "execveat"))
            good = good and "PAYLOAD_MUST_NOT_APPEAR" not in observed
        else:
            good = good and counters["external_http"] == counters["other_external"] == 0
        good = good and counters["deny_shim_cli"] == expected_cli
        good = good and counters["github_cli"] == expected_cli+mocked_cli
        # Deliberate fixture gh replacements are explicitly classified by their
        # private paths, not broadly exempted whenever a command exits zero.
        extra_paths = [p for p in executions if p != str(self.work/"shim/gh")]
        approved = []
        if name == "pr-gate":
            approved = json.loads((self.evidence/"pr-gate-mock.json").read_text())["executables"]
        elif name == "deny-probe":
            approved = [str(self.work/"probe-override/gh")]
        good = good and len(extra_paths) == mocked_cli and all(p in approved for p in extra_paths)
        record.update(exit=code, finished_at=utc(), counters=counters, gh_executables=executions, fixture="PASS" if good else "FAIL")
        self.results[name] = record
        write(self.evidence/(name+".json"), record)
        print(record["fixture"], name, "exit="+str(code), json.dumps(counters), flush=True)
        if not good:
            print(output[-6000:], flush=True)

    def go(self, name, package, *tests):
        # a test binary runs in its package's directory (the node is its own
        # module at tokenledger/agent since claude-fleet#4812)
        self.run(name, [self.work/(package+".test"), "-test.v", "-test.timeout=60s",
                        "-test.run=^("+"|".join(tests)+")$"], "go", tests, cwd=GO_DIRS.get(package, ROOT/"tokenledger/hub"/package))

    def python(self, name, script, *tests):
        self.run(name, [sys.executable, ROOT/"bin"/script, "-v", *tests], "python", timeout=90)

    def execute(self):
        # No user-set flag can substitute for an actual isolated network stack.
        interfaces = {name for _, name in socket.if_nameindex()}
        if interfaces != {"lo"}:
            raise ValueError("run requires a fresh Linux network namespace with only loopback")
        source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        write(self.evidence/"provenance.json", dict(source_commit=source, started_at=utc(),
              merged="UNVERIFIED", deployed="NOT RUN", live_accepted="NOT RUN",
              baseline="3570: automated fixture 7/7, never live",
              retirement="BLOCKED: released version AND >=7 days after canary AND live C9 AND zero legacy owners",
              binaries={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.work.glob("*.test")}))
        write(self.evidence/"deny-policy.json", dict(interfaces=sorted(interfaces),
              policy="fresh Linux network namespace; no external interface or route; loopback fixtures only",
              counters="payload-free strace -v -s0 of descendant connect/sendto/sendmsg/sendmmsg destinations; external 80/443 upper bound for GitHub HTTP; strace inject=io_uring_setup:error=ENOSYS forces observable fallback; any unfenced ring setup/submission refuses",
              cli="execve/execveat gh executable paths (argv/env redacted); independent deny shim exit91; absolute and overridden paths observed",
              exceptions="deny-probe positive controls; pr-gate deliberately denied CLI read then local restored-response fixture"))
        self.run("deny-probe", [sys.executable, ROOT/"bin/nogh-task-deny-probe.py", self.work], expected_cli=2, mocked_cli=2)
        if self.results["deny-probe"]["fixture"] != "PASS":
            raise ValueError("deny policy positive control failed")
        self.run("baseline", ["bash", ROOT/"bin/nogh-e2e-selftest.sh", "--ccquota", self.work/"ccquota"], "baseline", timeout=300,
                 env={"NOGH_E2E_SUMMARY": str(self.evidence/"baseline-summary.json")})
        self.go("dispatch", "api", "TestAcceptedCodingAgentDispatch", "TestCodingAgentRejectsBeforeWork", "TestNodeCodingAgentAcceptedBeforeLocalOrRemote")
        self.run("provider", ["bash", ROOT/"bin/fleet-dispatch-selftest.sh"])
        self.python("children", "fleet_task_control_test.py")
        # C8 (EPIC T497): a record is a ticket, its window an ID — no claim,
        # generation fence or receipt journal left to exercise.
        self.go("collaboration", "store", "TestTaskChildrenNameTheirParent", "TestUnclaimedParentDispatches", "TestIDSwitchCancelsDeadRecords")
        self.go("authority", "store", "TestTaskRecordIsATicket", "TestTaskAuthorityAdditiveColumns")
        self.go("outbox", "agent", "TestRelayDeliverExitCodes", "TestRelayWorkersWritesTheCache")
        self.go("migration", "store", "TestOwnerAuthorityDryRunAndPerOwnerCutover", "TestRepoAuthorityPausedAfterFinalGate", "TestRepoAuthorityStopBoundToCurrentNative", "TestRepoAuthorityFreezeSerializesClaim")
        self.go("cutover", "api", "TestRepoAuthorityAPICleanCutoverNoGitHub", "TestRepoAuthorityAPIManifestCutoverAndCapabilities")
        self.python("repo-cli", "fleet_repo_authority_test.py")
        self.go("landing", "api", "TestTaskPageConfirmedOutcomeAndLanding")
        self.run("pr-gate", [sys.executable, ROOT/"bin/nogh-task-boundary-test.py"], expected_cli=1, mocked_cli=3)
        self.run("projection", ["node", "--experimental-strip-types", ROOT/"extras/web-console/test/tasks.mjs"])
        self.run("browser", ["node", ROOT/"bin/nogh-task-browser.mjs", self.work], timeout=60)
        self.run("thin", ["bash", ROOT/"bin/fleet-thin-selftest.sh"], timeout=60)

    def finish(self, error=None):
        rows = []
        for key, (scenario, steps) in ROWS.items():
            passed = all(self.results.get(s, {}).get("fixture") == "PASS" for s in steps)
            rows.append(dict(id=key, scenario=scenario, fixture="PASS" if passed else "FAIL",
                             live="NOT RUN", evidence=[s+".json" for s in steps]))
        count = sum(r["fixture"] == "PASS" for r in rows)
        ok = count == len(ROWS) and error is None and all(r["fixture"] == "PASS" for r in self.results.values())
        write(self.evidence/"acceptance.json", dict(finished_at=utc(), rows=rows, error=error,
              fixture_pass=count, fixture_total=len(ROWS), result="PASS" if ok else "FAIL",
              merged="UNVERIFIED", deployed="NOT RUN", live_accepted="NOT RUN"))
        print(f"fixture acceptance: {count}/{len(ROWS)}; result={'PASS' if ok else 'FAIL'}; live: NOT RUN", flush=True)
        return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--child":
        sys.exit(child_command(sys.argv[3:], sys.argv[2]))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True, help="prepared private directory outside the checkout")
    args = parser.parse_args()
    harness = Harness(args.work.resolve())
    error = None
    try:
        harness.execute()
    except Exception as exc:
        error = str(exc)
        print(error, file=sys.stderr)
    sys.exit(harness.finish(error))
