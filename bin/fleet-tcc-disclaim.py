#!/usr/bin/env python3
"""fleet-tcc-disclaim.py — run a command that no macOS privacy prompt can wait on
(issue #3167).

    fleet-tcc-disclaim.py [--] <command> [args…]

macOS privacy protection (TCC) charges every access a process makes to its
RESPONSIBLE process — the app launchd started, inherited down the whole tree.
When that one is not an Apple platform binary and holds no decision for the
service, tccd puts an authorization dialog on the CONSOLE and the access waits
for a person to answer it. On a machine nobody looks at, nobody does: on mac-a
(2026-10-10 and again 2026-10-11) the admin node's ccquota — a new, ungranted
identity on every release (#3034) — ran fleet-login-new.sh; sysadminctl asked
for kTCCServiceSystemPolicySysAdminFiles, the dialog sat there, the user tccd's
thread stayed in CFUserNotificationReceiveResponse, sandboxd's approval queues
(synchronous, no timeout) filled up behind it, and from then on every check
through sandboxd hung — opendirectoryd refused every user delete «disallowed by
sandbox» (-14120), even sudo dscl, until sandboxd was restarted.

This spawns <command> with responsibility DISCLAIMED
(posix_spawn + responsibility_spawnattrs_setdisclaim): the child is its own
responsible process. The account scripts are /bin/bash — a platform binary,
which tccd never prompts for («Platform binary prompting is 'Deny'») — so a
protected access is refused at once, the script sees the error and goes on (or
takes its ssh road, #2994), and no dialog is ever left on a screen.

It waits for the child and exits with its status (128+N for a signal, as a
shell does); SIGTERM / SIGINT / SIGHUP are passed on to it. Not macOS, or the
call is missing: the command is exec'd as is (exit 127 if it cannot run).
"""
import ctypes, os, signal, sys


def main(argv):
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        sys.stderr.write("usage: fleet-tcc-disclaim.py [--] <command> [args…]\n")
        return 2
    # Python starts with SIGPIPE (and SIGXFSZ) ignored; subprocess restores them
    # for its children, a bare posix_spawn / execvp does not. An ignored
    # disposition is inherited by the script and every child it starts, so a
    # `tr … </dev/urandom | head -c 22` never dies on EPIPE and spins forever
    # (#3419: an account create hung 9 minutes on gen_password).
    for name in ("SIGPIPE", "SIGXFSZ"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), signal.SIG_DFL)
    libc = None
    if sys.platform == "darwin":
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            libc.responsibility_spawnattrs_setdisclaim
        except (OSError, AttributeError):
            libc = None
    if libc is None:
        try:
            os.execvp(argv[0], argv)
        except OSError as e:
            sys.stderr.write("fleet-tcc-disclaim: %s: %s\n" % (argv[0], e))
            return 127
    return spawn_disclaimed(libc, argv)


def spawn_disclaimed(libc, argv):
    attr = ctypes.c_void_p()      # posix_spawnattr_t is a pointer on macOS
    if libc.posix_spawnattr_init(ctypes.byref(attr)) != 0:
        sys.stderr.write("fleet-tcc-disclaim: posix_spawnattr_init failed\n")
        return 127
    libc.responsibility_spawnattrs_setdisclaim.argtypes = [ctypes.c_void_p, ctypes.c_int]
    if libc.responsibility_spawnattrs_setdisclaim(ctypes.byref(attr), 1) != 0:
        sys.stderr.write("fleet-tcc-disclaim: responsibility_spawnattrs_setdisclaim failed\n")
        return 127
    path = argv[0].encode()
    cargs = (ctypes.c_char_p * (len(argv) + 1))(*[a.encode() for a in argv], None)
    env = ["%s=%s" % kv for kv in os.environ.items()]
    cenv = (ctypes.c_char_p * (len(env) + 1))(*[e.encode() for e in env], None)
    pid = ctypes.c_int()
    spawn = libc.posix_spawnp if b"/" not in path else libc.posix_spawn
    rc = spawn(ctypes.byref(pid), path, None, ctypes.byref(attr), cargs, cenv)
    libc.posix_spawnattr_destroy(ctypes.byref(attr))
    if rc != 0:
        sys.stderr.write("fleet-tcc-disclaim: %s: %s\n" % (argv[0], os.strerror(rc)))
        return 127
    child = pid.value

    def forward(sig, _frame):
        try:
            os.kill(child, sig)
        except OSError:
            pass
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, forward)
    while True:
        try:
            _, status = os.waitpid(child, 0)
            break
        except InterruptedError:
            continue
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
