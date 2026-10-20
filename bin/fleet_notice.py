#!/usr/bin/env python3
"""fleet_notice.py — THE one way the fleet tells the person something on screen
(T675, after issue #1618's fleet_ui_fail): three tiers, every notice recorded,
the 看台's top line draws it, ⌘P's 「最近消息」 row (at its bottom) reads them back —
fleet takes no key of its own for it.

    fleet_notice.py notify <error|warn|info> <text> [--next <下一步>] [--client <name>]
                    [--sock <label>] [--all] [--view <看台 session>] [--source <name>]
                    [--secs N] [--tag T] [--no-draw] [--no-record]
    fleet_notice.py list [--n 50] [--json]     the newest first (`fleet notices`)
    fleet_notice.py page [--client C]          「最近消息」 (⌘P's bottom row; the words 消息)
    fleet_notice.py unread                     errors since the page was last opened
    fleet_notice.py read                       mark them read
    fleet_notice.py seen <tag>                 rc 0 when a notice carrying <tag> was recorded

THE TIERS. error — red, on the line until the first key pressed after 10 s
(never less than 10 s); warn — yellow, 6 s; info — grey, 3 s. `--secs` may only
lengthen a tier (a one-time line the attach says: 8 s). Several at once: the newest
is drawn, 「还有 N 条 · ⌘P 看全部」 beside it — the rest are in ⌘P's 最近消息.

WHO SEES IT. Only the client that asked (`--client`, a bind's #{client_name};
fleet_ui_fail passes FLEET_UI_CLIENT). With none named, tmux's own current
client — what display-message picked before; `--all` (a background alert that
needs you NOW): every client of the server. A 看台 (a session marked @view_thin)
gets it on its top line: `@view_notice` (base64 JSON: level · text · next · ts ·
until · hold · more), drawn by bin/fleet-topbar.py; the 「a key was pressed」 test
is tmux's own `#{client_activity}` against `@view_notice_hold`, in the status
format, so no key is eaten and no process runs per key. Any other client (a
direct attach, an old client) gets a display-message held for the tier.

THE RECORD. Every notice is one row of $FLEET_CONF_DIR/logs/notices.ndjson (ts ·
level · text · next · source · client · view · tag), 7 days kept (an old FIRST
row costs one rewrite); the same level + text within 10 s is one row.
fleet-alerts.sh's events land here too. Nothing is ever a credential: callers say
what happened, never what a token was.
"""
import base64
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

BIN = Path(__file__).absolute().parent
LEVELS = ("error", "warn", "info")
TIER = {"error": 10, "warn": 6, "info": 3}
KEEP = 7 * 86400
DEDUP = 10
PAGE_N = 50


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet"))


def log_path():
    return conf_dir() / "logs" / "notices.ndjson"


def read_mark():
    return conf_dir() / "logs" / "notices.read"


def clean(text, limit=400):
    """One line, no control bytes, at most `limit` characters."""
    t = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or "")).strip()
    return t[:limit]


# --- the record --------------------------------------------------------------------

def rows(n=None):
    """Every recorded notice, oldest first (the last `n` when given)."""
    try:
        with open(log_path(), "rb") as fh:
            if n:
                fh.seek(0, os.SEEK_END)
                size = fh.tell()
                fh.seek(max(0, size - 4096 * max(1, n // 8 + 1)))
            raw = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []
    out = []
    for line in raw:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and isinstance(r.get("ts"), (int, float)):
            out.append(r)
    return out[-n:] if n else out


def record(level, text, nxt="", source="", client="", view="", tag="", now=None):
    """Append one row; False when it was a repeat (same level + text within DEDUP)."""
    now = time.time() if now is None else now
    path = log_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a+", encoding="utf-8") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            fh.seek(0)
            first = fh.readline()
            try:
                t0 = json.loads(first).get("ts", now) if first else now
            except (ValueError, AttributeError):
                t0 = 0
            if t0 < now - KEEP:
                keep = []
                for line in [first] + fh.readlines():
                    try:
                        if json.loads(line).get("ts", 0) >= now - KEEP:
                            keep.append(line if line.endswith("\n") else line + "\n")
                    except (ValueError, AttributeError):
                        pass
                fh.seek(0)
                fh.truncate()
                fh.write("".join(keep))
            for r in rows(8):
                if r.get("level") == level and r.get("text") == text and now - r["ts"] < DEDUP:
                    return False
            row = {"ts": round(now, 3), "level": level, "text": text}
            for k, v in (("next", nxt), ("source", source), ("client", client), ("view", view), ("tag", tag)):
                if v:
                    row[k] = v
            fh.seek(0, os.SEEK_END)
            fh.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
        return True
    except OSError:
        return False


def unread(now=None):
    """Errors recorded after the page was last opened."""
    try:
        mark = float(read_mark().read_text().strip() or 0)
    except (OSError, ValueError):
        mark = 0.0
    return sum(1 for r in rows(200) if r.get("level") == "error" and r["ts"] > mark)


def mark_read(now=None):
    p = read_mark()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("%.3f\n" % (time.time() if now is None else now))
    except OSError:
        pass


def seen(tag):
    return bool(tag) and any(r.get("tag") == tag for r in rows(50))


# --- drawing ---------------------------------------------------------------------

def tmux(sock, *args, timeout=5):
    base = ["tmux"] + (["-L", sock] if sock else [])
    try:
        p = subprocess.run(base + list(args), capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout.rstrip("\n")
    except (OSError, subprocess.SubprocessError):
        return 1, ""


def tgt(s):
    """A session target: an id ($N) as is, a name exactly (=name)."""
    return ("%s:" if s.startswith("$") else "=%s:") % s


def decode(b64):
    """@view_notice → dict, {} when empty or unreadable."""
    try:
        d = json.loads(base64.b64decode(b64 or "", validate=True).decode("utf-8"))
        return d if isinstance(d, dict) else {}
    except (ValueError, TypeError, UnicodeDecodeError):
        return {}


def encode(d):
    return base64.b64encode(json.dumps(d, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).decode()


def live(n, now, acked):
    """Is notice `n` still on the line: its tier not over, or an error not yet
    answered by a key (`acked`: a key came after its hold)."""
    if not n:
        return False
    return now < n.get("until", 0) or (n.get("level") == "error" and not acked)


def targets(sock, client, everyone, view=""):
    """[(client name, its session)] to draw on; `view`: that 看台 session itself,
    whoever is (or is about to be) attached to it."""
    if view:
        return [("", view)]
    # list-clients, never `display -p -c <client>`: its formats are the current
    # pane's, so #{client_session} names whichever client tmux thinks is current
    rc, out = tmux(sock, "list-clients", "-F", "#{client_name}\t#{client_session}\t#{client_control_mode}")
    rows_ = [l.split("\t") for l in out.splitlines() if rc == 0 and l.count("\t") >= 2]
    if client:
        return [(c, s) for c, s, _ in rows_ if c == client][:1]
    if everyone:
        return [(c, s) for c, s, ctl in rows_ if ctl != "1"]
    rc, out = tmux(sock, "display-message", "-p", "#{client_name}\t#{client_session}")
    c, _, s = out.partition("\t")
    return [(c, s)] if rc == 0 and c and s else []


def palette(name):
    """A colour of conf/fleet-palette.conf — the ONE palette (fleet_ui_fail's)."""
    try:
        txt = (BIN.parent / "conf" / "fleet-palette.conf").read_text()
    except OSError:
        return ""
    m = re.search(r"^%%hidden %s='(#[0-9A-Fa-f]+)'" % name, txt, re.M)
    return m.group(1) if m else ""


def plain_line(level, text, nxt):
    """The display-message form for a client that is not a 看台."""
    glyph = {"error": "✗", "warn": "!", "info": "i"}[level]
    col = {"error": palette("PAL_RED"), "warn": palette("PAL_YELLOW"), "info": ""}[level]
    body = ("%s — %s" % (text, nxt) if nxt else text).replace("#", "##")
    return "#[%sbold] %s %s " % ("fg=%s," % col if col else "", glyph, body)


def draw(level, text, nxt="", sock="", client="", everyone=False, secs=None, now=None, view=""):
    """Put the notice on the screen(s); the 看台 names drawn on, for the record."""
    now = time.time() if now is None else now
    if not (os.environ.get("TMUX") or sock):
        # no server named and none around us: nothing to draw on
        rc, _ = tmux(sock, "has-session")
        if rc != 0:
            return []
    tier = TIER[level]
    hold = max(tier, int(secs or 0))
    views, done = [], set()
    found = targets(sock, client, everyone, view)
    if not found and not view:
        # no client tmux can name (none attached, or a caller's own tmux stand-in):
        # the old display-message, held for the tier — never the ~0.75 s default
        tmux(sock, "display-message", *(["-c", client] if client else []), "-d", str(hold * 1000),
             plain_line(level, text, nxt))
    for c, s in found:
        if not s or s in done:
            continue
        done.add(s)
        rc, vt = tmux(sock, "show-options", "-qv", "-t", tgt(s), "@view_thin")
        if rc == 0 and vt and "-via-" not in vt:
            rc, old = tmux(sock, "show-options", "-qv", "-t", tgt(s), "@view_notice")
            prev = decode(old)
            _, acts = tmux(sock, "list-clients", "-F", "#{client_name}\t#{client_activity}") if c else (1, "")
            act = next((l.split("\t")[1] for l in acts.splitlines() if l.split("\t")[0] == c), "")
            acked = act.isdigit() and int(act) >= int(prev.get("hold", 0) or 0)
            more = (int(prev.get("more", 0)) + 1) if live(prev, now, acked) else 0
            n = {"seq": int(prev.get("seq", 0)) + 1, "level": level, "text": text, "next": nxt,
                 "ts": int(now), "until": int(now) + hold, "hold": int(now) + hold, "more": more}
            tmux(sock, "set-option", "-t", tgt(s), "@view_notice", encode(n), ";",
                 "set-option", "-t", tgt(s), "@view_notice_hold", str(n["hold"]),
                 *([";", "refresh-client", "-S", "-t", c] if c else []))
            views.append(s)
        elif c:
            tmux(sock, "display-message", "-c", c, "-d", str(hold * 1000), plain_line(level, text, nxt))
    return views


def notify(level, text, nxt="", client="", sock="", everyone=False, source="", secs=None, tag="",
           draw_it=True, record_it=True, view=""):
    """The one entry: draw (unless `draw_it` is off) and record (unless off)."""
    if level not in LEVELS:
        level = "warn"
    text, nxt = clean(text), clean(nxt, 200)
    if not text:
        return 2
    tag = tag or os.environ.get("FLEET_NOTICE_TAG", "")
    views = draw(level, text, nxt, sock, client, everyone, secs, view=view) if draw_it else []
    if record_it:
        record(level, text, nxt, source, client, ",".join(views), tag)
    return 0


# --- reading back ------------------------------------------------------------------

_WORDS = {}


def say(key, *args):
    if not _WORDS:
        try:
            out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "notice_"], capture_output=True,
                                 text=True, timeout=5, stdin=subprocess.DEVNULL).stdout
        except (OSError, subprocess.SubprocessError):
            out = ""
        raw = out.split("\0")
        _WORDS.update({k: v.replace("\1", "%s") for k, v in zip(raw[0::2], raw[1::2])})
        _WORDS.setdefault("_", "")
    text = _WORDS.get(key, key)
    try:
        return text % args if args else text
    except (TypeError, ValueError):
        return text


def fmt_row(r, color=False):
    when = time.strftime("%m-%d %H:%M:%S", time.localtime(r["ts"]))
    lvl = r.get("level", "info")
    word = say("notice_level_" + lvl)
    body = r.get("text", "") + ((" — " + r["next"]) if r.get("next") else "")
    src = (" · " + r["source"]) if r.get("source") else ""
    if color:
        c = {"error": "31", "warn": "33", "info": "90"}.get(lvl, "0")
        return "\x1b[90m%s\x1b[0m \x1b[%s;1m%s\x1b[0m %s\x1b[90m%s\x1b[0m" % (when, c, word, body, src)
    return "%s %s %s%s" % (when, word, body, src)


def cmd_list(args):
    n = PAGE_N
    if "--n" in args:
        try:
            n = max(1, int(args[args.index("--n") + 1]))
        except (IndexError, ValueError):
            pass
    got = list(reversed(rows(n)))
    if "--json" in args:
        print(json.dumps(got, ensure_ascii=False))
        return 0
    if not got:
        print(say("notice_none"))
        return 0
    tty = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    for r in got:
        print(fmt_row(r, tty))
    return 0


def page(args):
    """The 「最近消息」 page in a popup: the newest 50, ↑↓ / PgUp PgDn scroll, any
    other key closes. Opening it reads every error (the top line's count goes)."""
    import shutil
    import termios
    import tty as ttym
    got = list(reversed(rows(PAGE_N)))
    mark_read()
    lines = [fmt_row(r, not os.environ.get("NO_COLOR")) for r in got] or [say("notice_none")]
    head = "\x1b[1m%s\x1b[0m  \x1b[90m%s\x1b[0m" % (say("notice_page_title"), say("notice_page_keys"))
    fd = sys.stdin.fileno()
    try:
        saved = termios.tcgetattr(fd)
    except (termios.error, OSError):
        print(head)
        print("\n".join(lines))
        return 0
    top = 0
    try:
        ttym.setraw(fd)
        while True:
            cols, rows_ = shutil.get_terminal_size((80, 24))
            room = max(1, rows_ - 2)
            top = max(0, min(top, len(lines) - room))
            out = ["\x1b[2J\x1b[H" + head]
            for ln in lines[top:top + room]:
                out.append(ln)
            sys.stdout.write("\r\n".join(out) + "\x1b[?25l")
            sys.stdout.flush()
            ch = os.read(fd, 8)
            if ch in (b"\x1b[A", b"k"):
                top -= 1
            elif ch in (b"\x1b[B", b"j"):
                top += 1
            elif ch in (b"\x1b[5~", b"\x02"):
                top -= room
            elif ch in (b"\x1b[6~", b" ", b"\x06"):
                top += room
            else:
                break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        sys.stdout.write("\x1b[?25h")
        sys.stdout.flush()
    return 0


def opt(args, name, default=""):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return default


def main(argv):
    if not argv:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "notify":
        pos = [a for i, a in enumerate(args) if not a.startswith("--") and
               (i == 0 or args[i - 1] not in ("--next", "--client", "--sock", "--source", "--secs", "--tag", "--view"))]
        if len(pos) < 2:
            print("usage: fleet_notice.py notify <error|warn|info> <text> [--next …] [--client …]", file=sys.stderr)
            return 2
        secs = opt(args, "--secs")
        return notify(pos[0], pos[1], opt(args, "--next"), opt(args, "--client"), opt(args, "--sock"),
                      "--all" in args, opt(args, "--source"), int(secs) if secs.isdigit() else None,
                      opt(args, "--tag"), "--no-draw" not in args, "--no-record" not in args, opt(args, "--view"))
    if cmd == "list":
        return cmd_list(args)
    if cmd == "page":
        return page(args)
    if cmd == "unread":
        print(unread())
        return 0
    if cmd == "read":
        mark_read()
        return 0
    if cmd == "seen":
        return 0 if args and seen(args[0]) else 1
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
