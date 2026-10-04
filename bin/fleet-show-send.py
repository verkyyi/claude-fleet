#!/usr/bin/env python3
"""fleet-show-send.py — write iTerm2's OSC 1337 file escapes to a tty (issue #1367).

The sending half of bin/fleet-show.sh. It runs as the tmux CLIENT's lock-command
(see fleet-show.sh for why): the client has left tmux mode, so this process is the
ONLY writer on the operator's tty and no tmux frame can land inside a FilePart.

  fleet-show-send.py --out <tty|file> --status <file> [--inline] [--single]
                     [--part N] [--wait-key S] <file>...

  --out      where the escapes go (the client runs us with /dev/tty)
  --status   one TAB-separated line per file, written AFTER its last byte:
             `ok<TAB><bytes><TAB><name>` or `err<TAB><why><TAB><name>`, then a
             final `done` line — fleet-show.sh waits on it
  --inline   inline=1 (draw it) instead of inline=0 (download to ~/Downloads)
  --single   the one-shot `File=` form (iTerm2 < 3.5) instead of Multipart
  --part     base64 bytes per FilePart (rounded down to a multiple of 4)
  --wait-key after sending, hold the screen until a key (or S seconds) — what makes
             --inline worth having: tmux repaints the moment this exits.
"""
import argparse
import base64
import os
import select
import sys
import termios
import tty as ttymod


def escapes(path, inline, single, part):
    data = open(path, "rb").read()
    name = base64.b64encode(os.path.basename(path).encode()).decode()
    head = f"name={name};size={len(data)};inline={inline}"
    b64 = base64.b64encode(data)
    if single:
        yield f"\033]1337;File={head}:".encode() + b64 + b"\a"
        return
    yield f"\033]1337;MultipartFile={head}\a".encode()
    for i in range(0, len(b64), part):
        yield b"\033]1337;FilePart=" + b64[i:i + part] + b"\a"
    yield b"\033]1337;FileEnd\a"


def write_all(fd, buf):
    view = memoryview(buf)
    while view:
        view = view[os.write(fd, view):]


def wait_key(fd_in, secs):
    try:
        old = termios.tcgetattr(fd_in)
    except termios.error:
        return
    try:
        ttymod.setcbreak(fd_in)
        select.select([fd_in], [], [], secs)
        if select.select([fd_in], [], [], 0)[0]:
            os.read(fd_in, 64)
    finally:
        termios.tcsetattr(fd_in, termios.TCSADRAIN, old)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--status", required=True)
    ap.add_argument("--inline", action="store_true")
    ap.add_argument("--single", action="store_true")
    ap.add_argument("--part", type=int, default=768)
    ap.add_argument("--wait-key", type=int, default=0)
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    part = max(4, a.part // 4 * 4)
    inline = 1 if a.inline else 0

    with open(a.status, "a") as st:
        try:
            fd = os.open(a.out, os.O_WRONLY | os.O_NOCTTY | os.O_APPEND | os.O_CREAT, 0o600)
        except OSError as e:
            st.write(f"err\tcannot open {a.out}: {e.strerror}\t-\ndone\n")
            return 1
        rc = 0
        for f in a.files:
            name = os.path.basename(f)
            try:
                for chunk in escapes(f, inline, a.single, part):
                    write_all(fd, chunk)
                st.write(f"ok\t{os.path.getsize(f)}\t{name}\n")
            except OSError as e:
                st.write(f"err\t{e.strerror}\t{name}\n")
                rc = 1
            st.flush()
        if a.wait_key and os.isatty(fd):
            write_all(fd, b"\r\n  [fleet-show] press any key to return to tmux\r\n")
            st.write("done\n")
            st.flush()
            if os.isatty(0):  # the client's own tty: lock-command inherits it
                wait_key(0, a.wait_key)
        else:
            st.write("done\n")
        os.close(fd)
    return rc


if __name__ == "__main__":
    sys.exit(main())
