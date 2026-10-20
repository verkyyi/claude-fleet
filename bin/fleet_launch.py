#!/usr/bin/env python3
"""Retired: the launch proof layer (EPIC T497 C8). A window is its ID now.

compat-1v: 下一批删. Kept ONE version for a session still running an older
fleet-session-wrap.sh, which calls `fleet_launch.py supervise -- <argv>` for a
window stamped @launch before the ID switch: that window reopens as itself —
the @launch* options are taken off and it goes the ordinary road
(fleet_repo_authority.py --supervise), which resumes the conversation its
wrapper asked for. Every other mode answers what an unbound window answered.
Process and worktree helpers moved to fleet_native_proc.py.
"""
import os
import subprocess
import sys
from pathlib import Path

BIN = Path(__file__).resolve().parent
# The window options and the environment the proof layer used; none is read now.
OPTIONS = ("@launch", "@launch_receipt", "@launch_seed", "@launch_started",
           "@launch_error", "@launch_hook_error")
ENV = ("FLEET_LAUNCH", "FLEET_LAUNCH_CONTEXT", "FLEET_LAUNCH_SUPERVISOR", "FLEET_LAUNCH_NATIVE",
       "FLEET_LAUNCH_WORKTREE", "FLEET_LAUNCH_CREATE", "FLEET_LAUNCH_DELIVERY")


def retire(pane, socket=""):
    """Take the proof layer's options off a window (its ID stays)."""
    sock = ["-S" if os.path.isabs(socket) else "-L", socket] if socket else []
    for key in OPTIONS:
        subprocess.run(["tmux", *sock, "set-option", "-wu", "-t", pane, key],
                       capture_output=True, timeout=5)


def main(argv):
    while argv[:1] and argv[0] in ("--socket", "--pane", "--target", "--bundle"):
        argv = argv[2:]
    mode = argv[0] if argv else ""
    if mode == "supervise":
        rest = argv[1:]
        if rest[:1] == ["--"]:
            rest = rest[1:]
        pane = os.environ.get("TMUX_PANE", "")
        if pane:
            retire(pane)
        env = {k: v for k, v in os.environ.items() if k not in ENV}
        script = str(BIN / "fleet_repo_authority.py")
        os.execvpe(sys.executable, [sys.executable, script, "--supervise", "--", *rest], env)
    if mode in ("inspect", "transfer-commit", "native-worktree", "restore-native-worktree"):
        print("launch: retired (EPIC T497 C8): a window is its ID", file=sys.stderr)
        return 1
    if mode == "rebind":
        print("launch: retired (EPIC T497 C8): nothing to rebind", file=sys.stderr)
        return 3
    return 0   # local · admit · transfer-check: nothing to claim, nothing to hold


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
