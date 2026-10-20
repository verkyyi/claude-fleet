#!/usr/bin/env python3
"""A native process and its worktree, read off the kernel and git — no task,
no receipt, no hub (EPIC T497 C8).

What the launch proof layer (fleet_launch.py, retired in C8) used to own and
other readers still need: a process's executable + birth (PID reuse safe),
ancestry, which provider a binary is, a linked worktree's git identity.
Nothing here grants or records an execution; a caller decides what a read means.
"""
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid


def valid_uuid(value):
    try:
        return str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def validate_worktree(binding):
    if (not isinstance(binding, dict) or set(binding) != {"root", "git_dir", "common_dir"}
            or any(not isinstance(value, str) or not os.path.isabs(value)
                   or any(character in value for character in "\n\r\0") for value in binding.values())):
        raise ValueError("invalid worktree binding")
    return binding


def worktree_identity(directory):
    if not isinstance(directory, str) or not os.path.isabs(directory):
        raise ValueError("native cwd must be an absolute worktree path")
    cwd = Path(directory).resolve(strict=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS="0")
    result = subprocess.run(["git", "-C", str(cwd), "rev-parse", "--path-format=absolute",
                             "--show-toplevel", "--absolute-git-dir", "--git-common-dir"],
                            env=environment, capture_output=True, text=True, check=True, timeout=2)
    root, metadata, common = [Path(value).resolve(strict=True) for value in result.stdout.splitlines()]
    marker = root / ".git"
    if (not cwd.is_relative_to(root) or metadata.parent != common / "worktrees"
            or not marker.is_file() or marker.is_symlink()
            or (metadata / (metadata / "gitdir").read_text().strip()).resolve(strict=True) != marker):
        raise ValueError("native cwd is not a registered linked worktree")
    return validate_worktree(dict(root=str(root), git_dir=str(metadata), common_dir=str(common)))


def tmux(*args, socket=""):
    cmd = ["tmux"] + (["-S" if os.path.isabs(socket) else "-L", socket] if socket else [])
    return subprocess.run(cmd + list(args), capture_output=True, text=True, check=True, timeout=5).stdout.strip()


def option(pane, key, socket=""):
    return tmux("display-message", "-p", "-t", pane, "#{" + key + "}", socket=socket)


def stamp(pane, key, value):
    tmux("set-option", "-w", "-t", pane, key, json.dumps(value, separators=(",", ":")))


def process(pid, *, ps_row=None):
    """Kernel executable + birth. ps_row reuses one observation's ppid/lstart.

    The optional row never substitutes for the kernel birth/executable read.
    Callers must discard it after that observation; the default C3 path is
    unchanged. No process or task observation is cached here.
    """
    row = list(ps_row) if ps_row is not None else subprocess.run(
        ["ps", "-p", str(pid), "-o", "ppid=,lstart="],
        capture_output=True, text=True, check=True, timeout=3).stdout.strip().split(None, 1)
    if len(row) != 2:
        raise ValueError("native process disappeared")
    if sys.platform == "darwin":
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        buf = ctypes.create_string_buffer(4096)
        if lib.proc_pidpath(int(pid), buf, len(buf)) <= 0:
            raise ValueError("native executable unavailable")
        executable = os.fsdecode(buf.value)
        # proc_bsdinfo carries microsecond birth time; ps lstart alone permits
        # a reused PID from the same second to impersonate a stopped native.
        class BSDInfo(ctypes.Structure):
            _fields_ = [("ids", ctypes.c_uint32 * 12), ("comm", ctypes.c_char * 16),
                        ("name", ctypes.c_char * 32), ("info", ctypes.c_uint32 * 6),
                        ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]
        info = BSDInfo()
        if lib.proc_pidinfo(int(pid), 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            raise ValueError("native process birth unavailable")
        row[1] += ":%d:%d" % (info.start_sec, info.start_usec)
        kernel_parent, started = info.ids[4], info.start_sec
    else:
        executable = os.readlink("/proc/%d/exe" % pid)
        # Linux start ticks distinguish PID reuse within the same second.
        fields = Path("/proc/%d/stat" % pid).read_text().rsplit(")", 1)[1].split()
        row[1] += ":" + fields[19]
        if ps_row is not None:
            boot = next(int(line.split()[1]) for line in Path('/proc/stat').read_text().splitlines()
                        if line.startswith('btime '))
            kernel_parent, started = int(fields[1]), boot + int(fields[19]) // os.sysconf('SC_CLK_TCK')
    if ps_row is not None:
        # A PID can exit/recycle between ps and the kernel read. Never attach a
        # fresh birth to stale comm/parent data and call it the earlier process.
        if (kernel_parent != int(row[0]) or ' '.join(time.ctime(started).split()) !=
                ' '.join(ps_row[1].split())):
            raise ValueError('process changed during observation')
    return dict(pid=int(pid), ppid=int(row[0]), birth=row[1], executable=executable)


def same_executable(a, b):
    """One executable FILE, whatever name the kernel gives it (T524).

    A release hard-links one binary under several names (tools/claude/<sha>/claude,
    every <sha>/.release/artifacts/claude-<ver>-<os>-<arch>), and macOS
    proc_pidpath answers whichever name the vnode cache last saw — so reading an
    artifact during a version switch renames every running Claude. The identity
    is the inode: the same path, or two paths naming the same file."""
    if not isinstance(a, str) or not isinstance(b, str):
        return False
    if a == b:
        return True
    try:
        return os.path.isabs(a) and os.path.isabs(b) and os.path.samefile(a, b)
    except OSError:
        return False


def same_identity(a, b):
    """pid + birth + executable of two kernel observations name one process."""
    try:
        return (a["pid"] == b["pid"] and a["birth"] == b["birth"]
                and same_executable(a["executable"], b["executable"]))
    except (KeyError, TypeError):
        return False


def same_process(proof):
    """The process a saved {pid, birth, executable} named is still that one."""
    try:
        return same_identity(process(proof["pid"]), proof)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return False


def descendant(pid, parent):
    for _ in range(24):
        if pid == parent:
            return True
        if pid <= 1:
            break
        try:
            pid = process(pid)["ppid"]
        except (OSError, ValueError, subprocess.SubprocessError):
            break
    return False


def native_tool(path):
    """claude | codex | '' — the provider a binary's NAME says it is.

    Besides `claude` / `codex` and Claude's numeric version files, a release's
    artifact name (`claude-2.1.295-darwin-arm64`, `codex-0.162.1-darwin-arm64`)
    is the same binary under a hard link (T524: macOS may report that name)."""
    base = Path(path).name
    m = re.fullmatch(r"(claude|codex)(?:-\d+\.\d+\.\d+(?:-[A-Za-z0-9_]+)*)?", base)
    if m:
        return m.group(1)
    return "claude" if re.fullmatch(r"\d+\.\d+\.\d+", base) else ""


def native_name(path):
    return bool(native_tool(path))


def root_native(p, supervisor):
    pid = p["ppid"]
    for _ in range(24):
        if pid == supervisor:
            return True
        if pid <= 1:
            return False
        ancestor = process(pid)
        if native_name(ancestor["executable"]):
            return False  # nested helper/subagent, never the root launch
        pid = ancestor["ppid"]
    return False


def native_provider(p):
    """The provider a native process says it is, by its own version probe."""
    # Managed Claude binaries use a numeric version basename. Do not run
    # arbitrary ancestor shells/interpreters as provider probes.
    if not native_name(p["executable"]):
        return ""
    v = subprocess.run([p["executable"], "--version"], stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=5)
    version = v.stdout.strip()
    actual = "codex" if re.fullmatch(r"codex-cli \S+", version) else (
        "claude" if re.fullmatch(r"\S+ \(Claude Code\)", version) else "")
    return actual if v.returncode == 0 else ""


def native_parent():
    """The hook's native ancestor. Only its version probe sees an empty request."""
    pid = os.getppid()
    for _ in range(12):
        p = process(pid)
        actual = native_provider(p)
        if actual:
            return dict(p, actual_provider=actual)
        pid = p["ppid"]
        if pid <= 1:
            break
    raise ValueError("no verified native provider in hook ancestry")
