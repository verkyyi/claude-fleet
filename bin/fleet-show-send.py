#!/usr/bin/env python3
"""fleet-show-send.py — write iTerm2's OSC 1337 file escapes to a tty (issue #1367).

The sending half of bin/fleet-show.sh. It runs as the tmux CLIENT's lock-command
(see fleet-show.sh for why): the client has left tmux mode, so this process is the
ONLY writer on the operator's tty and no tmux frame can land inside a FilePart.

  fleet-show-send.py --out <tty|file> --status <file> [--inline] [--single]
                     [--part N] [--wait-key S] [--geom C,R,CW,CH] <file>...
  fleet-show-send.py --out <tty|file> --status <file> --raw <file>

  --out      where the escapes go (the client runs us with /dev/tty)
  --status   one TAB-separated line per file, written AFTER its last byte:
             `ok<TAB><bytes><TAB><name>`, `dl<TAB><bytes><TAB><name>` (--inline,
             not an image → sent as a download instead) or
             `err<TAB><why><TAB><name>`, then a final `done` line — fleet-show.sh
             waits on it
  --inline   draw it (inline=1) on a laid-out screen instead of inline=0 (download)
  --raw      write the file's bytes to --out verbatim — an escape already built
             by the caller (bin/fleet-open.sh's OSC 1337 Custom=, issue #1379)
  --single   the one-shot `File=` form (iTerm2 < 3.5) instead of Multipart
  --part     base64 bytes per FilePart (rounded down to a multiple of 4)
  --wait-key --inline: hold each screen until a key (or S seconds) — tmux repaints
             the moment this exits
  --geom     the client's size in cells + one cell in pixels (tmux's
             #{client_width},#{client_height},#{client_cell_width},#{client_cell_height});
             any 0 → no centering, the image goes top-left at its own size

--inline screen (issue #1371), one per image:
  row 1        文件名 · 大小 · 宽×高
  rows 3..R-2  the image, scaled to fit (never up) and centered — width=/height= in
               cells + preserveAspectRatio=1, placed with CUP
  row R        任意键返回 tmux · d 同时下载到 ~/Downloads · Ns 后自动返回 (counts down)
`d` sends the same file again as inline=0. A file that is not an image (PDF, text…)
cannot be drawn inline by iTerm2: it is sent as a download and reported `dl`.
The screen text is Chinese, fixed (the fleet has no UI-language knob).

FLEET_SHOW_KEYS (selftests) — the keys the operator "presses", one per wait, in
order, instead of reading the tty; an empty slot (or running out) = the timeout.
"""
import argparse
import base64
import os
import select
import struct
import subprocess
import sys
import termios
import time
import tty as ttymod
import unicodedata

HEADER_ROWS = 2   # title + a blank
FOOTER_ROWS = 2   # a blank + the hint


def escapes(data, name, inline, single, part, extra=""):
    name = base64.b64encode(name.encode()).decode()
    head = f"name={name};size={len(data)};inline={inline}{extra}"
    b64 = base64.b64encode(data)
    if single:
        yield f"\033]1337;File={head}:".encode() + b64 + b"\a"
        return
    yield f"\033]1337;MultipartFile={head}\a".encode()
    for i in range(0, len(b64), part):
        yield b"\033]1337;FilePart=" + b64[i:i + part] + b"\a"
    yield b"\033]1337;FileEnd\a"


def write_all(fd, buf):
    if isinstance(buf, str):
        buf = buf.encode()
    view = memoryview(buf)
    while view:
        view = view[os.write(fd, view):]


# ---- what is it, and how big ---------------------------------------------------------
def _png(d):
    if d[:8] == b"\x89PNG\r\n\x1a\n" and d[12:16] == b"IHDR":
        return struct.unpack(">II", d[16:24])
    return None


def _gif(d):
    if d[:6] in (b"GIF87a", b"GIF89a"):
        return struct.unpack("<HH", d[6:10])
    return None


def _jpeg(d):
    if d[:2] != b"\xff\xd8":
        return None
    i = 2
    while i + 9 < len(d):
        if d[i] != 0xFF:
            i += 1
            continue
        m = d[i + 1]
        if m in (0xD8, 0x01) or 0xD0 <= m <= 0xD7 or m == 0xFF:
            i += 1 if m == 0xFF else 2
            continue
        seglen = struct.unpack(">H", d[i + 2:i + 4])[0]
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
            h, w = struct.unpack(">HH", d[i + 5:i + 9])
            return (w, h)
        i += 2 + seglen
    return (0, 0)  # a JPEG whose size we could not find: still an image


def _other_image(d):
    """Raster formats macOS decodes but we do not parse: size comes from sips."""
    return (d[:2] == b"BM" or d[:4] in (b"II*\x00", b"MM\x00*")
            or (d[:4] == b"RIFF" and d[8:12] == b"WEBP")
            or d[4:12] in (b"ftypheic", b"ftypheix", b"ftypavif", b"ftypmif1"))


def sips_size(path):
    try:
        out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return (0, 0)
    w = h = 0
    for line in out.splitlines():
        k, _, v = line.strip().partition(":")
        if k == "pixelWidth" and v.strip().isdigit():
            w = int(v)
        elif k == "pixelHeight" and v.strip().isdigit():
            h = int(v)
    return (w, h)


def image_size(path, data):
    """(w, h) in pixels for an image ((0, 0) = an image of unknown size); None = not an image."""
    for parse in (_png, _gif, _jpeg):
        r = parse(data)
        if r is not None:
            return r
    if _other_image(data):
        return sips_size(path)
    return None


# ---- layout --------------------------------------------------------------------------
def layout(geom, px):
    """Where the image goes: (row, col, width_cells, height_cells), all 1-based —
    or None when the client size or the image size is unknown (top-left fallback)."""
    cols, rows, cw, ch = geom
    iw, ih = px
    avail_c = cols - 2                              # a one-cell margin each side
    avail_r = rows - HEADER_ROWS - FOOTER_ROWS
    if min(cols, rows, cw, ch, iw, ih) <= 0 or avail_c < 1 or avail_r < 1:
        return None
    scale = min(1.0, avail_c * cw / iw, avail_r * ch / ih)   # fit, never enlarge
    wc = min(avail_c, max(1, -(-round(iw * scale) // cw)))      # ceil to whole cells
    hc = min(avail_r, max(1, -(-round(ih * scale) // ch)))
    col = 1 + (cols - wc) // 2
    row = HEADER_ROWS + 1 + (avail_r - hc) // 2
    return (row, col, wc, hc)


def human(n):
    for unit in ("B", "KB", "MB"):
        if n < 1024 or unit == "MB":
            return f"{n} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0


def clip(s, cells):
    """s cut to `cells` terminal columns (a CJK character takes two)."""
    out, used = [], 0
    for c in s:
        w = 2 if unicodedata.east_asian_width(c) in "WF" else 1
        if used + w > cells:
            return "".join(out[:-1]) + "…" if out else ""
        out.append(c)
        used += w
    return s


class Keys:
    """One key per wait: the scripted FLEET_SHOW_KEYS, else the client's own tty (fd 0)."""

    def __init__(self):
        self.script = os.environ.get("FLEET_SHOW_KEYS")
        self.tty = self.script is None and os.isatty(0)
        self.old = None

    def __enter__(self):
        if self.tty:
            try:
                self.old = termios.tcgetattr(0)
                ttymod.setcbreak(0)
            except termios.error:
                self.tty = False
        return self

    def __exit__(self, *exc):
        if self.old is not None:
            termios.tcsetattr(0, termios.TCSADRAIN, self.old)

    def live(self):
        return self.tty or self.script is not None

    def get(self, secs):
        """A key within `secs`, or None on timeout."""
        if self.script is not None:
            k, self.script = self.script[:1], self.script[1:]
            return k or None
        if not self.tty or not select.select([0], [], [], max(0, secs))[0]:
            return None
        return os.read(0, 64).decode(errors="replace")[:1] or None


def draw(fd, geom, path, data, px, idx, total, a, part):
    """Clear the screen and draw one image: title row, the image centered under it."""
    cols = geom[0]
    name = os.path.basename(path)
    dims = f"{px[0]}×{px[1]}" if px[0] and px[1] else "尺寸未知"
    title = f"{name} · {human(len(data))} · {dims}"
    if total > 1:
        title = f"[{idx}/{total}] {title}"
    write_all(fd, "\033[?25l\033[2J\033[H\033[1m" + clip(title, cols if cols > 0 else 80) + "\033[0m")
    place = layout(geom, px)
    if place:
        row, col, wc, hc = place
        write_all(fd, f"\033[{row};{col}H")
        extra = f";width={wc};height={hc};preserveAspectRatio=1"
    else:
        write_all(fd, f"\033[{HEADER_ROWS + 1};1H")
        extra = ""
    for chunk in escapes(data, name, 1, a.single, part, extra):
        write_all(fd, chunk)


def hold(fd, keys, geom, path, data, idx, total, a, part):
    """The footer + its countdown, until a key or the timeout. `d` sends the file
    again as a download (inline=0) and keeps the screen. True = it was downloaded."""
    cols, rows = geom[0], geom[1]
    width = cols if cols > 0 else 80
    nxt = "下一张" if idx < total else "返回 tmux"
    downloaded = False

    def footer(left):
        mid = "已发出下载（在 iTerm2 里确认）" if downloaded else "d 同时下载到 ~/Downloads"
        hint = f"任意键{nxt} · {mid} · {left}s 后自动{nxt}"
        # the last row, or straight under the image when the client size is unknown
        at = f"\033[{rows};1H\033[2K" if rows > 0 else "\r\n\033[2K"
        write_all(fd, at + "\033[2m" + clip(hint, width - 1) + "\033[0m")

    if not keys.live() or a.wait_key <= 0:
        return False
    deadline = time.monotonic() + a.wait_key
    while True:
        left = int(deadline - time.monotonic() + 0.999)
        if left <= 0:
            break
        footer(left)
        k = keys.get(min(1.0, deadline - time.monotonic()))
        if k is None:
            if keys.script is not None:   # a scripted timeout: no need to really wait
                break
            continue
        if k in ("d", "D") and not downloaded:
            for chunk in escapes(data, os.path.basename(path), 0, a.single, part):
                write_all(fd, chunk)
            downloaded = True
            continue
        break
    return downloaded


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--status", required=True)
    ap.add_argument("--inline", action="store_true")
    ap.add_argument("--raw", action="store_true")
    ap.add_argument("--single", action="store_true")
    ap.add_argument("--part", type=int, default=768)
    ap.add_argument("--wait-key", type=int, default=0)
    ap.add_argument("--geom", default="0,0,0,0")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    part = max(4, a.part // 4 * 4)
    try:
        geom = tuple(int(x) for x in a.geom.split(","))
        assert len(geom) == 4
    except (ValueError, AssertionError):
        geom = (0, 0, 0, 0)

    with open(a.status, "a") as st:
        def status(verdict, detail, name):
            st.write(f"{verdict}\t{detail}\t{name}\n")
            st.flush()

        try:
            fd = os.open(a.out, os.O_WRONLY | os.O_NOCTTY | os.O_APPEND | os.O_CREAT, 0o600)
        except OSError as e:
            st.write(f"err\tcannot open {a.out}: {e.strerror}\t-\ndone\n")
            return 1
        rc = 0
        if a.raw:
            for f in a.files:
                try:
                    data = open(f, "rb").read()
                    write_all(fd, data)
                    status("ok", len(data), os.path.basename(f))
                except OSError as e:
                    status("err", e.strerror, os.path.basename(f))
                    rc = 1
            st.write("done\n")
            os.close(fd)
            return rc
        if not a.inline:
            for f in a.files:
                name = os.path.basename(f)
                try:
                    for chunk in escapes(open(f, "rb").read(), name, 0, a.single, part):
                        write_all(fd, chunk)
                    status("ok", os.path.getsize(f), name)
                except OSError as e:
                    status("err", e.strerror, name)
                    rc = 1
            st.write("done\n")
            os.close(fd)
            return rc

        # --inline: non-images go as downloads first, then one screen per image.
        images = []
        for f in a.files:
            name = os.path.basename(f)
            try:
                data = open(f, "rb").read()
                px = image_size(f, data)
                if px is None:
                    for chunk in escapes(data, name, 0, a.single, part):
                        write_all(fd, chunk)
                    status("dl", len(data), name)
                else:
                    images.append((f, data, px))
            except OSError as e:
                status("err", e.strerror, name)
                rc = 1
        # `done` goes out once the LAST image is on screen, before its hold: the
        # agent learns it was drawn without waiting on the operator. A `d` pressed
        # during that last hold is the operator's business, not the agent's.
        if not images:
            st.write("done\n")
        with Keys() as keys:
            for i, (f, data, px) in enumerate(images, 1):
                name = os.path.basename(f)
                try:
                    draw(fd, geom, f, data, px, i, len(images), a, part)
                    status("ok", len(data), name)
                    if i == len(images):
                        st.write("done\n")
                        st.flush()
                    if hold(fd, keys, geom, f, data, i, len(images), a, part) and i < len(images):
                        status("dl+", len(data), name)
                except OSError as e:
                    status("err", e.strerror, name)
                    rc = 1
                    if i == len(images):
                        st.write("done\n")
            write_all(fd, "\033[?25h")
        os.close(fd)
    return rc


if __name__ == "__main__":
    sys.exit(main())
