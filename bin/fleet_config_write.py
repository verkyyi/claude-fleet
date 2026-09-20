"""Locked config writes shared by the dashboard and the remote controller."""

import fcntl
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time


def revision(path):
    path = Path(path)
    return hashlib.sha256(path.read_bytes() if path.exists() else b"").hexdigest()


def write(path, key, value, kind, expected=None):
    path = Path(path)
    if not re.fullmatch(r"FLEET_[A-Z0-9_]+", key):
        raise ValueError("invalid config key")
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = os.open(str(path) + ".write.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    temporary = None
    try:
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("config write lock is busy")
                time.sleep(0.05)
        if path.is_symlink():
            raise ValueError("config writes require a regular file")
        if expected is not None and revision(path) != expected:
            raise ValueError("REVISION_CONFLICT: configuration changed; read it again")
        exists = path.exists()
        source = path.read_text() if exists else (
            "# claude-fleet config — managed by Fleet.\n"
            "# Assignments only (this file is sourced). Per-fleet overlays the global fleet.conf.\n")
        assignment = key + "=" + (value if kind in ("num", "int", "bool") else '"' + value + '"')
        lines, found = [], False
        for line in source.splitlines():
            if re.match(r"^\s*" + re.escape(key) + "=", line):
                lines.append(assignment)
                found = True
            else:
                lines.append(line)
        if not found:
            lines.append(assignment)
        fd, temporary = tempfile.mkstemp(prefix=path.name + ".tmp.", dir=path.parent)
        with os.fdopen(fd, "w") as output:
            output.write("\n".join(lines) + "\n")
            output.flush()
            os.fsync(output.fileno())
        if exists:
            os.chmod(temporary, path.stat().st_mode & 0o777)
            shutil.copy2(path, str(path) + ".bak")
        os.replace(temporary, path)
        temporary = None
        return "updated" if exists else "created"
    finally:
        if temporary is not None:
            os.unlink(temporary)
        os.close(lock)


if __name__ == "__main__":
    try:
        print(write(*sys.argv[1:]))
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
