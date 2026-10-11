#!/usr/bin/env python3
"""fleet_view.py — the 看台's switcher, on the home machine (issue #3000, EPIC #2999 C2).

The thin client has no tmux and no list of its own: its ⌘ keys land in the 看台
(`<fleet>@view-<id>`, fleet-remote-view.sh attach --thin) as the `fleet-view` key
table (conf/tmux-view.conf), and every one of them comes here, through
fleet-quickopen.py (this module is its node half — the client never loads it):

    fleet-quickopen.py view-keys [--if-stale] [--socket <label>]
                                              (conf/tmux-view.conf at every load;
                                              attach --thin, if root moved since)
                                              rebuild `fleet-view` + `fleet-view-pfx`:
                                              root copied over, then the 看台's keys
    fleet-quickopen.py --view <view> [--client <c>]
                                              ⌘P / ⌘K: every session of yours, every
                                              machine, every login, grouped by what
                                              you should do (#3179: 置顶 · 等你 ·
                                              在干活 · 刚落地 · 其他); 已结束 under
                                              them; ↵ goes there
    fleet-quickopen.py do next|prev|back|fwd --view <view>
                                              ⌘↓ ⌘↑ (the list's order) · ⌘[ ⌘] (history)
    fleet-quickopen.py do new|quit|shell --view <view> [--target <session>]
                                              C7 (issue #3004): ⌘N a new session (a
                                              no-repo one on this machine, #3119) ·
                                              ⌘Q OSC 7502 quit + detach · ⌃\ the
                                              session's shell (--target: any
                                              session's, on screen or not — #3183)
    fleet-quickopen.py view-shell here|far|home <machine> <login> <target> --view <view>
                                              (the ⌃\ window's program)
    fleet-quickopen.py view-order --view <view>
                                              rewrite the order ⌘↓ ⌘↑ walk (below)
    fleet-quickopen.py view-menu --view <view> <target>
                                              a row's actions (Tab, issue #3181):
                                              id · label · what it asks
    fleet-quickopen.py view-act --view <view> <target> <id> [--text <answer>] [--yes]
                                              do one (ACTIONS, below) — the Tab
                                              menu's own road; exit = the script's
    fleet-quickopen.py view-gone --view <view>
                                              read the 已回收 list now (below), wait
                                              for it — what the popup reads cached
    fleet-quickopen.py view-rows --view <view> [<query>]
                                              the popup's lines, plain (the selftest):
                                              kind · target · word · text · right ·
                                              foot · glyph · group · tags
    fleet-quickopen.py go <view> <target>     THE way a 看台 changes session (= bin/fleet-view-go.sh)
    fleet-quickopen.py view-peers --view <view> [--socket <label>]
                                              (attach --thin, in the background) one
                                              window per other (machine, login) — C4

`<view>` is the 看台's id or its session's name (`fleet@view-<id>`, what a key's
`#{session_name}` says). `<target>` is a window here (`@12`) or a worker id
(`<fleet UUID>/<fleet_id>`, or its `<fleet UUID>/<key>` alias).

GO (共同约定 8): the one entry every 看台 switch takes — the popup's ↵, ⌘↑↓, ⌘[ ],
C4's other machines and C7's keys. A session of THIS login on this machine is a
window of the 看台's own group: `select-window` on the 看台, nothing else (no
client switch, no redraw of our own).

Another machine's — or another login's here — is a PEER WINDOW's (issue #2751,
EPIC #2999 C4): one window per (machine, login) in the 看台's group, made when the
看台 attaches (`view-peers`, so the first visit is warm too) or by the first go
that needs it — `@fleet_role panel` (no list, no restore, no cap), `@peer
<machine>@<login>` (+ `@peer_node` / `@peer_login`, C1's top line), `@peer_view
<view>`, its pane `fleet-peerlink.py pane`, an ssh
on C5's standing link attached to the far machine's 看台 `<view>-via-<home>` (bare:
no top line, no key table — this machine draws both). Going there is the window's
`select-window`, after — only when the far 看台 shows another session than
`@peer_cur` — ONE channel on the link running the far end's `fleet-remote-view.sh
select` (its pre-lib fast path: three tmux calls). The link down (no socket C5
calls up) → `@peer_want` on the window, the window selected (it says 「正在连」),
rc 3; its pane lands there when the link is back. The windows go with their 看台
(rv_prune's peer sweep).

Every go appends one line to `$FLEET_CONF_DIR/logs/view-switch.ndjson` — ts ·
view · from · to · machine · login · method (`select-window` | `peer-window` (the
far 看台 already there) | `peer-select` (+ `peer_ms`, the channel) | `peer-wait` |
`far-none` (no machine known) | `gone`) · ms (the decision and every call, until
select-window returned) · how (popup | next | back …) — C10's reading. The history (⌘[ ⌘]) lives beside the 看台's registry row,
`$FLEET_CONF_DIR/remote-views/<id>.d/history.json` (rv_prune takes it with the
row), in fleet-quickopen.py's own stack / at / mru shape; beside it `order.json`,
the list's session order as last drawn — ⌘↓ ⌘↑ read it (a press never waits
~0.2 s for the row producer) and refresh it in the background after the switch.

WORDS (#2752): no row says `merged` or `done:2h` — the reap policy is
「合并后关」 / 「空闲 2 小时关」, and only on the lit row's line at the foot;
names are the issue's title as wide as the popup is (the producer's 12-cell name
when there is none) with no `⇢cla` tag. A state is ONE glyph (#3179: ! needs ·
x failed · » working · ✓ done · ∙ idle · ? lost, coloured unless NO_COLOR /
FLEET_COLOR=0, ASCII with FLEET_GLYPHS=ascii) — only the lit row writes its word
beside it, and `?` on an empty query shows the legend. Machine, login and repo
(only when 2+) are tags at the row's end, never a group. No session
is special (issue #3119): the one holding the orchestrator or the steward is a row
like any other — no session is behind 「新任务」 below. All of it through
fleet-ui-lang.sh (`view_*`).

COMMANDS (issue #3180, EPIC #3178 C2): command rows above the list — 「新任务…」
(typed words no session hits light 「新任务：<字> ↵ 直接派」; ↵ is ⌘T's send with
that title, no second dialog — fleet-quick-dispatch.py send, to `pick`'s repo, the
footer asking 「派到哪个仓库」 when two are named and none was last) and 「在 #N
「…」 的目录开 shell」 (the `shell` action on the session in view; in a session's
shell window it is 「回到 #N …」 — `enter` on that session — first and lit) — and
「更多」 below: 开一个空白新会话 (go_new, ⌘N's) · 退出 fleet (quit_view, ⌘Q's).
Each is an ACTIONS entry (the row-less ones `rowless`, never in a Tab menu).
FLEET_PANEL_COMMANDS (the environment, else fleet.conf `[common]`; default `new
shell`) names the rows on top in order — new · shell · newsess · quit · landed
(the 刚落地 group first); `none` takes them all away. panel_rows() builds it;
`view-panel` prints it.

STALE (issue #3184, EPIC #3178 C6): 失联 is judged off ONE time, global/hub_ok —
the file the producer's `m4!` reads. A lost row is grey end to end and tagged
「? 失联 N 分钟」; hub_ok older than FLEET_HUB_SESSIONS_STALE (60 s) puts a red
banner on top naming the machines (banner()); ↵ on a lost row says 进不去 instead
of going (lost_msg()). An open popup reads its list again every
FLEET_VIEW_REFRESH (2 s, 0 = never) off the screen's thread (Refresh), the lit
row kept by its key — and each read runs hub_fresh, so a silent hub is retried.

TAB (issue #3181, EPIC #3178 C3): the lit row's actions — the old sidebar row
menu's, item for item (ACTIONS; SIDEBAR_ACTIONS maps its letters), each running
the same script the sidebar ran. ↑↓ ↵ pick, Esc steps back; one that needs words
(rename, a message, an answer, a time) asks on the bottom line (↵ submit, Esc
cancel), a reap asks y / n first; then back on the list, read again.

GONE (issue #3286): 已结束 lists, after the rows whose windows are still open,
the sessions whose windows were reaped — the old sidebar's ⌃t landed list, the
same ledger (`fleet-history.sh rows`, issue #1532: this machine's, then the hub's
rows of the other machines), every row it gives. Each is `gone` (no window): its
one action is 恢复 (Tab, or ↵), the script the sidebar's ⌃t ran —
fleet-restore-pick.sh --select (a CLOSED-unmerged PR asks first, y reopen · r
anyway, as the sidebar's input line did). That read takes seconds on a long
ledger (~30 s here), so it never runs in a list read: it is written to
`$G/view-gone.<fleet>` in the background, single-flight, when the copy is older
than FLEET_VIEW_GONE_SECS (60 s — the sidebar's 10 s LANDED_SECS was a re-read
only while ⌃t was shown; this list is read every time the popup is), and the list
shows the copy it has.

A ROW ON ANOTHER MACHINE (issue #3182, EPIC #3178 C4): 回答 · 发一句话 · 改名 ·
改回收方式 · 停 · 回收 · 恢复 are each `far` — the hub write the old sidebar made for
that row, through the same fleet-sidebar-remote.sh (FLEET_REMOTE_SAY=print: its
outcome line, the hub's refusal verbatim, comes back as the bottom line). Run off
the screen's thread, then one hub cache --refresh, so a reaped row leaves within
the next read. A lost row (`!`) sends nothing: 「<机器> 失联，做不了 · 正在重连」.
"""
import curses
import getpass
import importlib.util
import shlex
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

US = "\x1f"
VIEW_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")
# The 看台's actions off dash-keymap.sh --panel switch: the verb each one runs.
# ⌘N ⌘T ⌘Q are C7's (issue #3004); zoom / fold stay caught by user-keys, bound to
# nothing (a 看台 has one pane a window, and no list to fold).
VIEW_ACTIONS = {"next": "do next", "prev": "do prev", "back": "do back", "fwd": "do fwd",
                "quickopen": "popup", "switcher": "popup",
                "new": "do new", "quit": "do quit", "dispatch": "dispatch"}
PFX_KEY = "C-]"
NARROW = 100      # a client narrower than this (a phone) gets the switcher full-screen (#3006)
# ⌃\ (issue #3004, #2744's meaning): no ⌘ chord, so no row of the switch table —
# the terminal sends the byte itself; ⌃] \ is the same on a keyboard with no ⌃\.
SHELL_KEY, SHELL_LETTER = "C-\\", "\\"
HERE, ME = "here", "me"


# --- where things are ---------------------------------------------------------------

def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet"))


def views_dir():
    return conf_dir() / "remote-views"


def dash_global():
    """The collector's machine-wide cache dir (tmux-dashboard-rows.sh's $G)."""
    base = os.environ.get("TMPDIR") or "/tmp/claude-fleet-%d" % os.getuid()
    return Path(os.environ.get("FLEET_STATUS_G") or os.path.join(base.rstrip("/"), ".claude-dash", "global"))


def switch_log():
    return conf_dir() / "logs" / "view-switch.ndjson"


# Outside a tmux server ($TMUX unset — a caller over ssh, a test's shell) the
# fleet's own socket: its label is the fleet session's name (fleet_socket).
_SOCK = [""]


def tm(*args, timeout=5):
    base = ["tmux"] if os.environ.get("TMUX") or not _SOCK[0] else ["tmux", "-L", _SOCK[0]]
    try:
        p = subprocess.run(base + list(args), capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.rstrip("\n")
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


_FLEET_HINT = {}


def view_id(arg):
    """`fleet@view-<id>` or `<id>` → `<id>`, "" when it is neither. The fleet a
    session name names is remembered for view_fleet()."""
    fleet, sep, v = (arg or "").rpartition("@view-")
    if not VIEW_RE.match(v):
        return ""
    if sep and fleet:
        _FLEET_HINT[v] = fleet
    return v


def view_row(vid):
    """The 看台's registry row: tty · session · kind · since · pid + its key=value cells."""
    try:
        line = (views_dir() / vid).read_text().split("\n", 1)[0]
    except OSError:
        return {}
    f = line.split("\t")
    if len(f) < 2:
        return {}
    row = {"tty": f[0], "session": f[1], "kind": f[2] if len(f) > 2 else ""}
    for cell in f[5:]:
        k, eq, v = cell.partition("=")
        if eq:
            row.setdefault(k, v)
    return row


def view_fleet(vid, row=None):
    """The fleet session a 看台 is grouped onto: its registry row's, else the name's."""
    row = view_row(vid) if row is None else row
    fleet = row.get("session") or _FLEET_HINT.get(vid, "")
    _SOCK[0] = _SOCK[0] or fleet
    return fleet


def here_label(row):
    """This machine as the rows name it: the registry's node= (rv_node_label), else
    the short hostname."""
    return row.get("node") or os.environ.get("FLEET_SIDEBAR_HOST") or socket.gethostname().split(".")[0]


# --- the words ------------------------------------------------------------------------

_WORDS = {}


def say(key, *args):
    if not _WORDS:
        try:
            raw = subprocess.run(["sh", str(Path(__file__).absolute().parent / "fleet-ui-lang.sh"), "dump", "view_", "reap_menu_"],
                                 capture_output=True, text=True, timeout=5).stdout.split("\0")
        except (OSError, subprocess.TimeoutExpired):
            raw = []
        _WORDS.update({k: v.replace("\1", "%s") for k, v in zip(raw[0::2], raw[1::2])})
        _WORDS.setdefault("_", "")
    text = _WORDS.get(key, key)
    try:
        return text % args if args else text
    except (TypeError, ValueError):
        return text


def dur(secs):
    """`45 分钟` · `3 小时` · `2 天` (the 「多久前」 of a row's end)."""
    secs = max(0, int(secs))
    if secs < 3600:
        return say("view_dur_m_fmt", max(1, secs // 60))
    if secs < 2 * 86400:
        return say("view_dur_h_fmt", secs // 3600)
    return say("view_dur_d_fmt", secs // 86400)


def span(text):
    """`2h` / `90m` / `3d` → the words (a reap policy's duration)."""
    m = re.fullmatch(r"(\d+)([smhd]?)", text or "")
    if not m:
        return text or ""
    n, u = int(m.group(1)), m.group(2) or "s"
    return dur(n * {"s": 1, "m": 60, "h": 3600, "d": 86400}[u])


def reap_words(policy):
    """A reap policy (fleet_reap_policy.py's grammar) as a sentence (#2752 item 1)."""
    p = (policy or "").strip()
    kind, _, arg = p.partition(":")
    if kind == "merged":
        return say("view_reap_merged_for", span(arg)) if arg else say("view_reap_merged")
    if kind == "done":
        return say("view_reap_done_for", span(arg)) if arg else say("view_reap_done")
    if kind == "loop-end":
        return say("view_reap_loop_end")
    if kind == "keep":
        return say("view_reap_keep")
    if kind == "at":
        return say("view_reap_at", arg)
    return ""


STATES = ("needs", "failed", "working", "looping", "idle", "done", "exited", "sleeping", "landed", "parked")


def state_words(state, needs=""):
    s = state if state in STATES else "idle"
    if s == "needs" and needs == "blocked":
        return say("view_state_blocked")
    return say("view_state_" + s)


TAG_RE = re.compile(r"\s*⇢\S*$")


# --- the rows -------------------------------------------------------------------------

def fleet_logins():
    out = {}
    try:
        for line in (dash_global() / "fleet_logins").read_text().splitlines():
            u, _, lg = line.partition("\t")
            if u and lg:
                out[u] = lg
    except OSError:
        pass
    return out


def hub_age(now=None):
    """Seconds since global/hub_ok — the ONE time the list judges 失联 by (the
    producer's `!` reads the same file, fleet_status_hub_lost). None when there is
    no hub_ok: no hub here, or a loop older than #1483 — nothing to say."""
    try:
        ok = int((dash_global() / "hub_ok").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    return max(0, (time.time() if now is None else now) - ok)


def hub_stale(now=None):
    """hub_ok older than FLEET_HUB_SESSIONS_STALE (60 s) — the bar's 入口连不上."""
    age = hub_age(now)
    return age is not None and age > fenv("FLEET_HUB_SESSIONS_STALE", 60)


def hub_fresh(fleet):
    """The other machines' rows are only as new as global/remote_<fleet>, which
    fleet-hub-sessions.sh's loop keeps — a loop the collector's tick (re)starts. A
    collector that stopped (mini2's node supervisor wedged, 2026-10-10) froze that
    file, and ⌘P went on listing sessions reaped since (issue #3079). So the list
    checks it on every open: hub_ok within FLEET_VIEW_HUB_FRESH (10 s) → nothing;
    older with no loop alive → one --refresh (at most FLEET_VIEW_HUB_REFRESH_SECS,
    5 s) before the rows, then --ensure; a loop alive but the hub silent → the rows
    as they are (their 失联 says so). No cache file ⇒ no hub here ⇒ nothing."""
    g = dash_global()
    if not fleet or not (g / ("remote_" + fleet)).is_file():
        return
    try:
        ok = int((g / "hub_ok").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        ok = 0
    if time.time() - ok <= fenv("FLEET_VIEW_HUB_FRESH", 10):
        return
    hs = os.environ.get("FLEET_VIEW_HUBSESS") or str(Path(__file__).absolute().parent / "fleet-hub-sessions.sh")

    def run(mode, secs):
        try:
            p = subprocess.Popen(["bash", hs, mode], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        except OSError:
            return ""
        try:
            return p.communicate(timeout=secs)[0] or ""
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
            p.wait()
            return ""
    st = run("--status", 3)
    if st.startswith("loop none"):
        run("--refresh", fenv("FLEET_VIEW_HUB_REFRESH_SECS", 5))
    if st.startswith("loop "):
        run("--ensure", 3)


def hub_reread(fleet):
    """After a write to another machine's session: read the hub's rows once now
    (fleet-hub-sessions.sh --refresh, ≤ FLEET_VIEW_HUB_REFRESH_SECS), so the next
    list read shows it — a reaped row gone, a new name. No cache ⇒ nothing."""
    if not fleet or not (dash_global() / ("remote_" + fleet)).is_file():
        return
    hs = os.environ.get("FLEET_VIEW_HUBSESS") or str(Path(__file__).absolute().parent / "fleet-hub-sessions.sh")
    try:
        subprocess.run(["bash", hs, "--refresh"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=fenv("FLEET_VIEW_HUB_REFRESH_SECS", 5), start_new_session=True)
    except (OSError, subprocess.TimeoutExpired):
        pass


def produce(fleet):
    """tmux-dashboard-rows.sh --sidebar, every subtree open: the rows the old list
    drew, the same producer (it reads remote_<sess>, so other machines come too)."""
    hub_fresh(fleet)
    env = dict(os.environ, FLEET_SESSION=fleet, FLEET_ROWS_UNFOLD="1")
    seam = os.environ.get("FLEET_VIEW_ROWS_CMD")
    argv = ["sh", "-c", seam] if seam else ["bash", str(Path(__file__).absolute().parent / "tmux-dashboard-rows.sh"), "--sidebar"]
    try:
        return subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def windows(fleet):
    """{window id: (fleet_id, role, activity)} of the fleet session."""
    rc, out = tm("list-windows", "-t", "=" + fleet, "-F", "#{window_id}|#{@fleet_id}|#{@fleet_role}|#{window_activity}")
    res = {}
    for line in out.splitlines() if rc == 0 else []:
        w, fid, role, act = (line.split("|") + ["", "", ""])[:4]
        res[w] = (fid, role, int(act) if act.isdigit() else 0)
    return res


# What a row is, in one cell (issue #3179, EPIC #3178 C1): a shape that reads
# without colour (16 colours, black and white, a reader who cannot tell red from
# green), every one an East-Asian-narrow character so it is one cell in a CJK
# terminal too, and in all seven of Termius iOS's fonts (✓ borrows a system font
# in UbuntuMono). FLEET_GLYPHS=ascii swaps in plain ASCII.
GLYPHS = {"needs": "!", "fail": "x", "work": "»", "done": "✓", "idle": "∙", "lost": "?"}
GLYPHS_ASCII = {"needs": "!", "fail": "x", "work": ">", "done": "+", "idle": ".", "lost": "?"}
# the 16-colour palette's numbers, present in every theme: red red green blue grey yellow
GLYPH_COLORS = {"needs": 1, "fail": 1, "work": 2, "done": 4, "idle": 8, "lost": 3}
GROUPS = ("pin", "ask", "work", "landed", "other")
MERGED_PR = ("merged", "live", "deploy…", "deploy✗")


def glyphs():
    return GLYPHS_ASCII if os.environ.get("FLEET_GLYPHS") == "ascii" else GLYPHS


def color_on():
    """NO_COLOR (any value, no-color.org) or FLEET_COLOR=0 leaves the shapes alone."""
    return not os.environ.get("NO_COLOR") and os.environ.get("FLEET_COLOR", "1") != "0"


def sym_of(state, lost=False):
    """A row's glyph class: lost wins (whatever it last said is no longer known)."""
    if lost:
        return "lost"
    if state == "needs":
        return "needs"
    if state in ("failed", "exited", "error"):
        return "fail"
    if state in ("working", "looping"):
        return "work"
    if state in ("done", "landed"):
        return "done"
    return "idle"


def group_of(state, pinned, landed, ended):
    if pinned:
        return "pin"
    if state in ("needs", "failed"):
        return "ask"
    if state in ("working", "looping"):
        return "work"
    if landed:
        return "landed"
    return "ended" if ended else "other"


def one_line(text, n=200):
    return re.sub(r"\s+", " ", text or "").strip()[:n]


# --- the 已回收 rows (issue #3286) --------------------------------------------------------

GONE_TX = re.compile(r"\x1b\[38;2;169;177;214m(.*?)\x1b\[0m")   # fleet-history.sh's TX: name, then title
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def gone_file(fleet):
    return dash_global() / ("view-gone." + (fleet or "-"))


def gone_read(fleet, wait=True):
    """Write `fleet-history.sh rows` (FLEET_VIEW_LANDED_CMD — the selftest's seam)
    to gone_file, single-flight (a `.lock` dir; one older than 10 minutes is a dead
    reader's). A failed read keeps the last copy. wait=False: in the background, its
    own session. True when this call ran (or started) the read."""
    out = gone_file(fleet)
    lock = Path(str(out) + ".lock")
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        lock.mkdir()
    except FileExistsError:
        try:
            if time.time() - lock.stat().st_mtime < 600:
                return False
            os.utime(str(lock))
        except OSError:
            return False
    except OSError:
        return False
    prod = os.environ.get("FLEET_VIEW_LANDED_CMD") or 'bash "$1" rows'
    script = '(%s) > "$2.$$" 2>/dev/null && mv -f "$2.$$" "$2"; rm -f "$2.$$"; rmdir "$3"' % prod
    argv = ["sh", "-c", script, "sh", str(Path(__file__).absolute().parent / "fleet-history.sh"), str(out), str(lock)]
    env = dict(os.environ, FLEET_SESSION=fleet, FZF_COLUMNS="240")
    try:
        if wait:
            subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=300)
        else:
            subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
    except subprocess.TimeoutExpired:
        pass
    except OSError:
        try:
            lock.rmdir()
        except OSError:
            pass
        return False
    return True


def gone_text(fleet):
    """The last copy of the 已回收 list; one older than FLEET_VIEW_GONE_SECS (or
    none) starts a read in the background — never waited for here."""
    p = gone_file(fleet)
    try:
        age, text = time.time() - p.stat().st_mtime, p.read_text(errors="replace")
    except OSError:
        age, text = None, ""
    if age is None or age >= fenv("FLEET_VIEW_GONE_SECS", 60):
        gone_read(fleet, wait=False)
    return text


def gone_rows(text, now=None):
    """fleet-history.sh rows → (target, glyph, label, name, title, act, pr), one per
    `landed:…` target, the first (newest) of a key the ledger lists twice. Its
    fixed columns (cmd_rows): glyph · issue (5) · tree · window (26), then the
    title in its own colour, and the 21 right cells act (8) · PR (7) · dep (4)."""
    out, seen = [], set()
    for line in (text or "").split("\n"):
        parts = line.split(US, 2)
        if len(parts) < 3 or not parts[0].startswith("landed:") or parts[0] in seen:
            continue
        seen.add(parts[0])
        plain = ANSI.sub("", parts[2]).rstrip("\n")
        tx = [t.strip() for t in GONE_TX.findall(parts[2])]
        name = tx[0] if tx else plain[11:37].strip()
        title = tx[1] if len(tx) > 1 else ""
        tail = plain[-21:] if len(plain) >= 59 else ""
        out.append((parts[0], plain[:1], plain[2:7].strip(), name, title, tail[:8].strip(), tail[9:16].strip()))
    return out


def entries(vid, now=None):
    """Every line the popup can show, in order (issue #3179): grouped by what you
    should do — 置顶 (@pin) · 等你 (needs / failed / blocked) · 在干活 (working /
    looping) · 刚落地 (done, its PR merged within FLEET_VIEW_LANDED_SECS, 24 h) ·
    其他 — then ▸ 已结束 (folds). Within a group the producer's order stands, and a
    row stays indented under its parent while the parent is in the same group.
    Machine, login and repo are tags, never groups. Each a dict:
    kind  hdr (a group heading, `group`) · sess · ask (the question a needs row
          asks, the line under it) · sec (已结束, folds) — `sec` names the
          section a line sits in
    text  the line's words · word (the state, written out on the lit row) · sym
          (its glyph class) · group · ask · tags (lost / direct machine, ✗ broken
          configuration, ∅ no issue, k/N, repo when 2+) · right (the issue) · foot
          (the lit row's line) · target (what go() takes) · far (another
          machine/login)"""
    now = time.time() if now is None else now
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    here, me = here_label(row), getpass.getuser()
    logins = fleet_logins()
    wins = windows(fleet) if fleet else {}
    landed_secs = fenv("FLEET_VIEW_LANDED_SECS", 86400)
    gl = glyphs()
    hage = hub_age(now)
    hstale = hage is not None and hage > fenv("FLEET_HUB_SESSIONS_STALE", 60)
    groups = {g: [] for g in GROUPS}
    ended, repos, anc = [], [], {}
    section, repo = "", ""
    for line in produce(fleet).splitlines():
        f = line.split(US)
        if f[0] == "hdr":
            kind = f[1] if len(f) > 1 else ""
            text = f[3] if len(f) > 3 else ""
            if kind in ("pin", "ended"):
                section = kind
            elif text.startswith("─") or not text.strip():
                section = ""          # the rule closing the pinned block
            else:
                section = ""
                repo = re.sub(r"\s*\(\d+\)$", "", re.sub(r"^▸\s*", "", text.strip()))
                if "/" in kind:       # a hosted repo's heading (`none` / '' are 无仓库 / ?)
                    repos.append(kind)
            continue
        if len(f) < 15 or not f[0]:
            continue
        f += [""] * (19 - len(f))
        key = f[0]
        local = not key.startswith("wid:")
        target = key if local else key[4:]
        mark = f[8]
        machine = mark.rstrip("!~") or here
        lost, direct = mark.endswith("!"), mark.endswith("~")
        login = me if local else logins.get(target.split("/", 1)[0], "")
        name = TAG_RE.sub("", f[3]).strip()
        title = (f[13] or "").strip()
        detail = (f[7] or "").strip()
        issue = f[9].strip() if f[9].strip() not in ("—", "·", "-") else ""
        depth = int(f[6]) if f[6].isdigit() else 0
        state = f[1]
        act = wins.get(target, ("", "", 0))[2] if local else 0
        if not act:
            # another machine's: the measurement bus's reading time is its last word
            ts = (f[18].split("|") + ["", "", ""])[2]
            act = int(ts) if ts.isdigit() else 0
        landed = state in ("done", "landed") and f[10].strip() in MERGED_PR and \
            (not act or now - act <= landed_secs)
        grp = group_of(state, section == "pin", landed, section == "ended")
        ask = one_line(f[17]) if state == "needs" else ""
        tags = []
        lost_secs = None
        if lost:
            # how long nothing new came: the hub's silence (hub_ok, the producer's
            # own source) while it is silent, else that machine's last reading
            lost_secs = hage if hstale else (now - act if act else hage)
        if lost and lost_secs is not None:
            # the glyph is the table's lost one (? — never a second symbol, #3194)
            tags.append(gl["lost"] + " " + say("view_tag_lost_min_fmt", max(1, int(lost_secs) // 60)))
        elif lost:
            tags.append(say("view_tag_lost_fmt", machine))
        elif direct:
            tags.append(say("view_tag_direct_fmt", machine))
        if f[12] == "broken":
            tags.append(("x " if gl is GLYPHS_ASCII else "✗ ") + say("view_tag_cfg_broken"))
        if f[15] == "failed":
            tags.append("-" if gl is GLYPHS_ASCII else "∅")
        if f[5].strip():
            tags.append(f[5].strip())
        e = {"kind": "sess", "target": target, "far": not local, "machine": machine, "login": login,
             "state": state, "text": title or name, "name": name, "reap": f[14].strip(), "issue": issue, "depth": depth,
             "detail": detail,
             "group": grp, "sym": sym_of(state, lost), "lost": lost, "lost_secs": lost_secs, "ask": ask, "tags": tags, "repo": repo,
             "word": state_words(state, detail if state == "needs" else ""),
             "foot": " · ".join(x for x in (title or name, reap_words(f[14]),
                                            detail if detail and detail != state else "",
                                            " · ".join(x for x in (machine, login) if x)) if x)}
        if grp == "ended":
            why = say("view_ended_merged") if f[10].strip() == "merged" else \
                say("view_ended_exited") if state == "exited" else say("view_ended_done")
            e["word"] = why
            e["right"] = say("view_ago_fmt", dur(now - act)) if act and local else ""
            e["sec"] = "ended"
            e["depth"] = 0
            ended.append(e)
            continue
        # indented under its parent only while the parent sits in the same group
        par = anc.get(depth - 1) if depth > 0 else None
        e["depth"] = par[1] + 1 if par and par[0] == grp else 0
        anc = {d: v for d, v in anc.items() if d < depth}
        anc[depth] = (grp, e["depth"])
        groups[grp].append(e)
    # the sessions whose windows are gone (issue #3286): after the open ended rows,
    # one an open row already shows (its issue, restored since) left out
    open_issues = {e["issue"] for g in groups.values() for e in g if e.get("issue")} | \
        {e["issue"] for e in ended if e.get("issue")}
    for target, glyph, label, name, title, act, pr in gone_rows(gone_text(fleet)):
        if label.startswith("#") and label in open_issues:
            continue
        grepo = target.rpartition("@")[2] if "@" in target else ""
        word = say("view_ended_gone_merged") if glyph == "✓" else say("view_ended_gone")
        ended.append({"kind": "sess", "target": target, "far": False, "gone": True, "machine": here, "login": me,
                      "state": "landed", "text": title or name, "name": name, "reap": "", "issue": label,
                      "depth": 0, "detail": "", "group": "ended", "sec": "ended",
                      "sym": "done" if glyph == "✓" else "fail", "lost": False, "lost_secs": None, "ask": "",
                      "tags": [], "repo": grepo.rpartition("/")[2], "word": word, "right": act,
                      "foot": " · ".join(x for x in (title or name, label, say("view_pr_fmt", pr) if pr.startswith("#") else "",
                                                     word, say("view_gone_hint")) if x)})
    multi = len(set(repos)) >= 2
    out = []
    for g in GROUPS:
        if not groups[g]:
            continue
        out.append({"kind": "hdr", "group": g, "text": say("view_grp_" + g + "_fmt", len(groups[g]))})
        for e in groups[g]:
            if multi and e["repo"]:
                e["tags"].append(e["repo"])
            out.append(e)
            if e["ask"]:
                out.append({"kind": "ask", "of": e["target"], "text": e["ask"], "depth": e["depth"]})
    if ended:
        out.append({"kind": "sec", "sec": "ended", "text": say("view_sec_ended_fmt", len(ended)), "n": len(ended)})
        for e in ended:
            if multi and e["repo"]:
                e["tags"].append(e["repo"])
            out.append(e)
    return out


def banner(items, now=None):
    """The red line on top of the popup (issue #3184, EPIC #3178 C6): hub_ok older
    than FLEET_HUB_SESSIONS_STALE and another machine's rows on the list ⇒ 「<机器们>
    的会话 N 分钟没更新（连不上入口）· 正在重连」 — the list's own refresh calls
    hub_fresh's --ensure meanwhile. Nothing else is judged here: the hub fresh, or
    no hub_ok at all ⇒ no line."""
    age = hub_age(now)
    if age is None or age <= fenv("FLEET_HUB_SESSIONS_STALE", 60):
        return ""
    names = []
    for e in items:
        if e["kind"] == "sess" and e.get("lost") and e.get("machine") and e["machine"] not in names:
            names.append(e["machine"])
    if not names:
        return ""
    return say("view_stale_banner_fmt", "、".join(names), max(1, int(age) // 60))


def lost_msg(e):
    """↵ on a lost row: nothing to go to — say so instead of trying (None = go)."""
    if e.get("kind") == "sess" and e.get("lost"):
        return say("view_lost_go_fmt", e.get("machine") or "?")
    return None


class Refresh:
    """The open popup's list, read again every FLEET_VIEW_REFRESH (2 s) off the
    screen's thread (entries() runs the producer and hub_fresh, up to seconds when
    the hub is silent): `poll()` hands back a new list once one is read, else None."""

    def __init__(self, vid, every=None):
        self.vid, self.every = vid, fenv("FLEET_VIEW_REFRESH", 2) if every is None else every
        self.due, self.res, self.busy = time.monotonic() + self.every, None, False
        self.lock = threading.Lock()

    def _run(self):
        try:
            res = entries(self.vid)
        except Exception:
            res = None
        with self.lock:
            self.res, self.busy = res, False
            self.due = time.monotonic() + self.every

    def poll(self):
        with self.lock:
            res, self.res = self.res, None
            start = self.every > 0 and not self.busy and time.monotonic() >= self.due
            if start:
                self.busy = True
        if start:
            threading.Thread(target=self._run, daemon=True).start()
        return res

    def wait_ms(self):
        return max(50, int((self.due - time.monotonic()) * 1000)) if self.every > 0 else 1000


# --- the filter: every word must hit, best first (the old ⌘P's scoring, #3179) ---------

def word_start(text, i):
    if i == 0:
        return True
    a, b = text[i - 1], text[i]
    return (not a.isalnum()) or (a.islower() and b.isupper())


def fuzzy(token, text):
    """(score, positions) of the letters of `token` in order in `text`, or None.
    Greedy, preferring a word start for each letter when one is ahead."""
    low, pos, at, score, last = text.lower(), [], 0, 0, -2
    for ch in token:
        i = low.find(ch, at)
        if i < 0:
            return None
        j = i
        while j >= 0 and not word_start(text, j) and j != last + 1:
            j = low.find(ch, j + 1)
        if j >= 0:
            i = j
        score += 10 if word_start(text, i) else 0
        score += 8 if i == last + 1 else -min(i - at, 10) * 0.2
        pos.append(i)
        last, at = i, i + 1
    return score, pos


def score_token(token, e):
    """The row's name (substring, a word start better) > any other field > the
    name's letters in order."""
    name = e.get("text") or ""
    i = name.lower().find(token)
    if i >= 0:
        return 3000 - i + (200 if word_start(name, i) else 0)
    issue = (e.get("issue") or "").lstrip("#")
    hay = " ".join(str(x) for x in (e.get("name"), "#" + issue if issue else "", e.get("word"),
                                    e.get("machine"), e.get("login"), e.get("repo"), e.get("ask"),
                                    " ".join(e.get("tags") or ())) if x).lower()
    i = hay.find(token)
    if i >= 0:
        return 2000 - i
    hit = fuzzy(token, name)
    return 1000 + hit[0] if hit else None


def score(query, e):
    """The row's score, or None when one word of `query` does not hit it."""
    total = 0
    for token in query.lower().split():
        s = score_token(token, e)
        if s is None:
            return None
        total += s
    return total


def matches(e, query):
    return not query.split() or score(query, e) is not None


def pickable(e):
    return e["kind"] in ("sess", "sec", "cmd")


def visible(items, query, opened):
    """What the popup lists. No query: every group, a section's items only when it
    is open. A query: the rows every word hits, best first, flat (each needs row
    with its question under it)."""
    asks = {e["of"]: e for e in items if e["kind"] == "ask"}
    if query.split():
        hits = [(score(query, e), i, e) for i, e in enumerate(items) if e["kind"] == "sess"]
        out = []
        for _, _, e in sorted((h for h in hits if h[0] is not None), key=lambda h: (-h[0], h[1])):
            out.append(dict(e, depth=0))
            if e.get("target") in asks and not e.get("sec"):
                out.append(dict(asks[e["target"]], depth=0))
        return out
    return [dict(e, closed=e["sec"] not in opened) if e["kind"] == "sec" else e
            for e in items if not (e.get("sec") and e["kind"] != "sec" and e["sec"] not in opened)]


def legend():
    """The one line `?` toggles on an empty query: every glyph and its word."""
    gl = glyphs()
    return "  ".join("%s %s" % (gl[k], say("view_legend_" + k)) for k in ("needs", "fail", "work", "done", "idle", "lost"))


def paint(shown, at, width, cells, clip):
    """The list's lines as segments [(text, style)] — style a tuple of: bold ·
    lit · dim · c<N> (a 16-colour palette number). Kept off curses so the
    selftest reads exactly what is drawn. Only the lit row writes its state."""
    gl, col = glyphs(), color_on()
    lines = []
    for i, e in enumerate(shown):
        lit = i == at
        if e["kind"] == "hdr":
            lines.append([(clip("─ " + e["text"] + " ", width), ("bold",))])
            continue
        if e["kind"] == "sec":
            lines.append([(clip(("▸ " if e.get("closed", True) else "▾ ") + e["text"], width),
                           ("bold", "lit") if lit else ("bold",))])
            continue
        if e["kind"] == "cmd":
            lines.append([(clip(("▶ " if lit else "  ") + e["text"], width), ("lit", "bold") if lit else ())])
            continue
        indent = "  " * (e.get("depth") or 0)
        if e["kind"] == "ask":
            lines.append([(clip("    " + indent + e["text"], width), ("dim",))])
            continue
        base = ("lit", "bold") if lit else (("dim",) if e.get("far") or e.get("sec") else ())
        sym = e.get("sym") or "idle"
        # a lost row is grey end to end, its glyph too: what it says is no longer known
        gstyle = base + (("c%d" % GLYPH_COLORS[sym],) if col and not e.get("lost") else ())
        head = ("▶ " if lit else "  ")
        word = (" " + e["word"]) if lit and e.get("word") else ""
        right = " ".join(list(e.get("tags") or ()) + [e.get("right") or (
            "#" + e["issue"].lstrip("#") if e.get("issue") else "")]).strip()
        used = cells(head) + 1 + cells(word) + 1
        room = width - used - (cells(right) + 1 if right else 0)
        name = clip(indent + (e.get("text") or ""), max(1, room))
        segs = [(head, base), (gl[sym], gstyle), (word + " " + name, base)]
        if right:
            pad = max(1, width - used - cells(name) - cells(right))
            segs.append((" " * pad + right, base if lit else ("dim",)))
        lines.append(segs)
    return lines


def session_order(items):
    """The order ⌘↓ / ⌘↑ walk: every session line of the list, as it is drawn."""
    return [e["target"] for e in items if e["kind"] == "sess" and e.get("target") and not e.get("gone")]


def order_file(vid):
    return views_dir() / (vid + ".d") / "order.json"


def order_save(vid, items):
    """Write the list's session order (+ each one's machine / login) — the popup on
    every open, view-order after a ⌘↓ — and return (seq, metas)."""
    seq = session_order(items)
    metas = {e["target"]: {"machine": e.get("machine", ""), "login": e.get("login", "")}
             for e in items if e["kind"] == "sess" and e.get("target") and not e.get("gone")}
    path = order_file(vid)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name("." + path.name + ".%d" % os.getpid())
        tmp.write_text(json.dumps({"ts": int(time.time()), "seq": seq, "meta": metas}, ensure_ascii=False))
        os.replace(str(tmp), str(path))
    except OSError:
        pass
    return seq, metas


def order_load(vid):
    try:
        d = json.loads(order_file(vid).read_text())
    except (OSError, ValueError):
        return None
    seq = [t for t in d.get("seq") or [] if isinstance(t, str)]
    metas = d.get("meta") if isinstance(d.get("meta"), dict) else {}
    return (seq, metas) if seq else None


# --- go: the one way a 看台 changes session (共同约定 8) ---------------------------------

def history_file(vid):
    return views_dir() / (vid + ".d") / "history.json"


def hist_load(qo, vid):
    try:
        h = json.loads(history_file(vid).read_text())
    except (OSError, ValueError):
        h = {}
    stack = [k for k in h.get("stack", []) if isinstance(k, str) and k]
    at = h.get("at", len(stack) - 1)
    at = at if isinstance(at, int) and 0 <= at < len(stack) else len(stack) - 1
    mru = [k for k in h.get("mru", []) if isinstance(k, str) and k]
    seen = h.get("seen") if isinstance(h.get("seen"), dict) else {}
    return {"stack": stack, "at": at, "mru": mru, "seen": seen}


def hist_save(qo, vid, h):
    return qo.write_atomic(history_file(vid), json.dumps(h, ensure_ascii=False) + "\n")


def current(vid, fleet=None):
    """The 看台's session in view, as go() targets it: `@<window>` here, or the far
    session a C4 window shows (its @peer_cur)."""
    rc, out = tm("display-message", "-p", "-t", "=%s@view-%s:" % (fleet or view_fleet(vid), vid),
                 "#{window_id}|#{@peer_cur}")
    if rc != 0 or not out:
        return ""
    w, _, pc = out.partition("|")
    return pc[4:] if pc.startswith("wid:") else (pc or w)


def resolve(vid, target, row, fleet):
    """(window id in the fleet, far) for a target: a window here; a worker id of
    this fleet (its UUID = the registry's fuid=) by @fleet_id; anything else far."""
    if target.startswith("@"):
        return target, False
    uuid, _, fid = target.partition("/")
    if fid and uuid and uuid == row.get("fuid"):
        for w, v in windows(fleet).items():
            if v[0] == fid:
                return w, False
        return "", False
    return "", True


def log_switch(rec):
    try:
        path = switch_log()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as out:
            out.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
    except OSError:
        pass


def toast(client, text):
    tm("display-message", *(["-c", client] if client else []), text)


# --- peer windows: the other machines, inside the 看台 (issue #2751, EPIC #2999 C4) -----

_PL = []


def peerlink():
    """bin/fleet-peerlink.py as a module (C5: the one owner of the links)."""
    if not _PL:
        path = Path(__file__).absolute().parent / "fleet-peerlink.py"
        spec = importlib.util.spec_from_file_location("fleet_peerlink", str(path))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _PL.append(mod)
    return _PL[0]


def peer_windows(fleet, vid):
    """{"<machine>@<login>": (window id, @peer_cur)} of the 看台's peer windows."""
    rc, out = tm("list-windows", "-t", "=" + fleet, "-F", "#{window_id}|#{@peer}|#{@peer_view}|#{@peer_cur}")
    res = {}
    for line in out.splitlines() if rc == 0 else []:
        w, peer, pv, pc = (line.split("|") + ["", "", ""])[:4]
        if peer and pv == vid:
            res.setdefault(peer, (w, pc))
    return res


def peer_make(fleet, vid, machine, login, want=""):
    """The 看台's window onto (machine, login): made hidden (-d), its pane the C5
    pane program (`want`: a worker id its first connect lands on). Its window id,
    "" when tmux said no."""
    me = getpass.getuser()
    pane = "exec python3 %s pane %s %s %s" % (
        shlex.quote(str(Path(__file__).absolute().parent / "fleet-peerlink.py")),
        shlex.quote(machine), shlex.quote(login), shlex.quote(vid))
    name = "@" + machine + ("" if login == me else "·" + login)
    rc, w = tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=%s@view-%s:" % (fleet, vid), "-n", name, pane)
    if rc != 0 or not w.startswith("@"):
        return ""
    tm("set-option", "-w", "-t", w, "@fleet_role", "panel", ";",
       "set-option", "-w", "-t", w, "@peer", "%s@%s" % (machine, login), ";",
       "set-option", "-w", "-t", w, "@peer_view", vid, ";",
       "set-option", "-w", "-t", w, "@peer_node", machine, ";",
       "set-option", "-w", "-t", w, "@peer_login", login, ";",
       "set-option", "-w", "-t", w, "automatic-rename", "off", ";",
       "set-option", "-w", "-t", w, "pane-border-status", "off",
       *([";", "set-option", "-w", "-t", w, "@peer_want", "wid:" + want] if want else []))
    return w


def peer_targets():
    """[(machine, login)] the 看台 should hold a window for: C5's own wanted set."""
    try:
        return sorted(peerlink().wanted_targets())
    except Exception:  # noqa: BLE001 — a broken peerlink makes no windows, never a crash
        return []


def view_peers(vid):
    """`view-peers`: a window for every (machine, login) your sessions are on."""
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    if not fleet or "-via-" in vid:
        return 2
    have = peer_windows(fleet, vid)
    for m, l in peer_targets():
        if "%s@%s" % (m, l) not in have:
            peer_make(fleet, vid, m, l)
    return 0


def far_where(target, meta, fleet):
    """(machine, login) of a far worker id: the go's meta (the list's), else the
    hub's row for it (global/remote_<fleet>)."""
    m, l = (meta or {}).get("machine") or "", (meta or {}).get("login") or ""
    if not m and fleet:
        try:
            for line in (dash_global() / ("remote_" + fleet)).read_text().splitlines():
                f = line.split(US)
                if f[0] == "wid:" + target and len(f) > 1:
                    m = f[1].rstrip("!~")
                    break
        except OSError:
            pass
    if m and not l:
        l = fleet_logins().get(target.split("/", 1)[0], "") or getpass.getuser()
    return m, l


def peer_select(machine, login, sock, target, vid):
    """ONE channel on the link: the far 看台 shows `target`. The far end's rc (0 ·
    3 not live there · 5 no such 看台 there yet), 255 the channel failed."""
    pl = peerlink()
    cmd = "bash %s/fleet-remote-view.sh select %s %s" % (pl.remote_bin(), shlex.quote(target),
                                                         shlex.quote(pl.via_view(vid)))
    try:
        return subprocess.run(pl.ssh_cmd() + ["-S", sock, "-o", "ControlMaster=no", "-l", login,
                                              pl.ssh_host(machine), cmd],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=fenv("FLEET_VIEW_PEER_SECS", 3)).returncode
    except (OSError, subprocess.TimeoutExpired):
        return 255


def fenv(k, d):
    try:
        return float(os.environ.get(k) or d)
    except ValueError:
        return float(d)


def go_far(vid, fleet, g, target, meta, client):
    """go()'s other-machine half: (method, rc, machine, login, extra)."""
    m, l = far_where(target, meta, fleet)
    if not m:
        toast(client, say("view_far_fmt", "?"))
        return "far-none", 3, m, l, {}
    key = "%s@%s" % (m, l)
    w, pcur = peer_windows(fleet, vid).get(key, ("", ""))
    made = not w
    if made:
        w = peer_make(fleet, vid, m, l, target)
        if not w:
            toast(client, say("view_far_fmt", m))
            return "far-none", 3, m, l, {}
    if not made and pcur == "wid:" + target:
        code, _ = tm("select-window", "-t", "=%s:%s" % (g, w))
        return ("peer-window", 0) + (m, l, {}) if code == 0 else ("gone", 4, m, l, {})
    sock = "" if made else peerlink().up_sock(m, l)
    extra = {}
    if sock:
        t1 = time.monotonic()
        prc = peer_select(m, l, sock, target, vid)
        # 5: the far 看台 is not there yet — the window's pane is attaching right
        # now (a fresh 看台, a line just back); it is, within moments
        for _ in range(int(fenv("FLEET_VIEW_PEER_RETRIES", 8))):
            if prc != 5:
                break
            time.sleep(0.15)
            prc = peer_select(m, l, sock, target, vid)
        extra["peer_ms"] = round((time.monotonic() - t1) * 1000, 1)
        if prc == 0:
            code, _ = tm("select-window", "-t", "=%s:%s" % (g, w), ";",
                         "set-option", "-w", "-t", w, "@peer_cur", "wid:" + target, ";",
                         "set-option", "-w", "-u", "-t", w, "@peer_want")
            return ("peer-select", 0, m, l, extra) if code == 0 else ("gone", 4, m, l, extra)
        if prc == 3:
            toast(client, say("view_gone"))
            return "gone", 4, m, l, extra
    # the link not up (or the far 看台 not there yet): the window waits and lands there
    tm("set-option", "-w", "-t", w, "@peer_want", "wid:" + target)
    tm("select-window", "-t", "=%s:%s" % (g, w))
    toast(client, say("view_peer_wait_fmt", m))
    return "peer-wait", 3, m, l, extra


def go(qo, vid, target, how="go", client="", meta=None, record=True):
    """Switch the 看台 to `target`. rc 0 switched · 3 another machine / login whose
    link is not up yet (C4: its window shown, waiting to land there) · 4 gone ·
    2 no such 看台."""
    t0 = time.monotonic()
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    if not fleet:
        return 2
    g = "%s@view-%s" % (fleet, vid)
    before = current(vid, fleet)
    meta = meta or {}
    w, far = resolve(vid, target, row, fleet)
    if far and not meta.get("machine"):
        cached = order_load(vid)
        meta = (cached[1].get(target) if cached else None) or meta
    extra = {}
    if far:
        method, rc, fm, fl, extra = go_far(vid, fleet, g, target, meta, client)
        meta = dict(meta, machine=fm or meta.get("machine") or "", login=fl or meta.get("login") or "")
    elif not w:
        method, rc = "gone", 4
        toast(client, say("view_gone"))
    else:
        code, _ = tm("select-window", "-t", "=%s:%s" % (g, w))
        method, rc = ("select-window", 0) if code == 0 else ("gone", 4)
    ms = round((time.monotonic() - t0) * 1000, 1)
    rec = {"ts": round(time.time(), 3), "view": vid, "from": before, "to": target,
           "machine": meta.get("machine") or ("" if far else row.get("node") or ""),
           "login": meta.get("login") or ("" if far else getpass.getuser()),
           "method": method, "ms": ms, "how": how}
    rec.update(extra)
    log_switch(rec)
    if rc == 0 and record:
        hist_save(qo, vid, qo.visit(hist_load(qo, vid), target if not target.startswith("@") else w))
    return rc


def do(qo, verb, vid, client="", target=None):
    """⌘↓ ⌘↑ ⌘[ ⌘] in a 看台 — and C7's ⌘N (new) · ⌘Q (quit) · ⌃\\ (shell;
    `--target <row>`: that session's, issue #3183)."""
    if verb == "new":
        return go_new(qo, vid, client)
    if verb == "quit":
        return quit_view(vid, client)
    if verb == "shell":
        return open_shell(qo, vid, client, target or None)
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    if not fleet:
        return 2
    cur = current(vid, fleet)
    if verb in ("next", "prev"):
        # The list's order as last drawn (order.json, beside the history): a press
        # never waits for the row producer (~0.2 s); it refreshes after the switch.
        cached = order_load(vid)
        if cached:
            seq, metas = cached
            refresh = True
        else:
            items = entries(vid)
            seq, metas = order_save(vid, items)
            refresh = False
        if not seq:
            return 1
        # the current window may be listed by its window id or its worker id
        wins = windows(fleet)
        fid = wins.get(cur, ("",))[0]
        alias = "%s/%s" % (row.get("fuid", ""), fid) if fid else ""
        i = next((n for n, t in enumerate(seq) if t in (cur, alias)), -1)
        i = (i + (1 if verb == "next" else -1)) % len(seq) if i >= 0 else 0
        rc = go(qo, vid, seq[i], verb, client, metas.get(seq[i]) or {})
        if refresh:
            subprocess.Popen([sys.executable, qo.__file__, "view-order", "--view", vid], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return rc
    if verb in ("back", "fwd"):
        h = hist_load(qo, vid)
        if not h["stack"]:
            return 1
        wins = windows(fleet)
        live = lambda k: k in wins or (not k.startswith("@") and "/" in k)
        key = qo.step(h, live, -1 if verb == "back" else 1)
        if not key:
            return 1
        rc = go(qo, vid, key, verb, client, record=False)
        if rc == 0:
            hist_save(qo, vid, qo.visit(h, key))
        return rc
    return 2


# --- ⌘N ⌘Q ⌃\ (issue #3004, EPIC #2999 C7) ----------------------------------------------

def go_new(qo, vid, client=""):
    """⌘N (issue #3119): a NEW session — a no-repo one on this machine, in $HOME
    (dash-raw-session.sh --no-repo, the hub's own origin), then go() onto it: the
    pane is the agent's input. No session is special, so nothing here names an
    orchestrator. rc as go(); 3 when none opened (one line on the client)."""
    fleet = view_fleet(vid)
    if not fleet:
        return 2
    seam = os.environ.get("FLEET_VIEW_NEW_CMD")
    argv = shlex.split(seam) if seam else ["bash", str(Path(__file__).absolute().parent / "dash-raw-session.sh")]
    try:
        p = subprocess.run(argv + ["--origin", "hub", "--no-repo", "--no-desk", "--print", fleet], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           timeout=fenv("FLEET_VIEW_NEW_SECS", 60))
        rc, w = p.returncode, ((p.stdout.strip().splitlines() or [""])[-1].split("\t") + [""])[0].strip()
    except (OSError, subprocess.TimeoutExpired):
        rc, w = 1, ""
    if rc == 0 and re.fullmatch(r"@[0-9]+", w):
        return go(qo, vid, w, "new", client)
    toast(client, say("view_new_failed"))
    return 3


def quit_view(vid, client=""):
    """⌘Q: tell the thin loop on the person's computer this connection is over
    (`ESC ] 7502 ; quit ; token=… BEL` on the client's own tty, the token its
    attach registered — 约定 10), then detach: ssh ends 0 and the loop exits."""
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    if not fleet:
        return 2
    g = "%s@view-%s" % (fleet, vid)
    if client:
        _, tty = tm("display-message", "-p", "-c", client, "#{client_tty}")
    else:
        _, out = tm("list-clients", "-t", "=" + g, "-F", "#{client_tty}")
        tty = (out.splitlines() or [""])[0]
    token = row.get("token") or ""
    if token and re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", token) and tty.startswith("/dev/"):
        try:
            fd = os.open(tty, os.O_WRONLY | os.O_NOCTTY)
            try:
                os.write(fd, ("\x1b]7502;quit;token=%s\x07" % token).encode())
            finally:
                os.close(fd)
        except OSError:
            pass
    rc, _ = tm("detach-client", *(["-t", client] if client else ["-s", "=" + g]))
    return 0 if rc == 0 else 1


def far_name(fleet, wid):
    """A far session's name as the hub's rows say it (global/remote_<fleet>, field 8)."""
    try:
        for line in (dash_global() / ("remote_" + fleet)).read_text().splitlines():
            f = line.split(US)
            if f[0] == "wid:" + wid and len(f) > 7 and f[7].strip():
                return f[7].strip()
    except OSError:
        pass
    return wid.rsplit("/", 1)[-1]


def open_shell(qo, vid, client="", target=None, meta=None):
    """⌃\ (#2744's meaning, in a 看台): a SESSION's shell — a login shell on
    the machine it runs on, as its login, in the directory its agent is in right
    now (the agent pane's, else `@worktree`, else $HOME — issue #3183) — a window
    of the 看台's group marked `@view_shell <machine>@<login>:<worker id>` +
    `@peer_view <view>` (rv_peer_sweep takes it with the 看台), one a session.
    `target` (the panel's lit row, issue #3183): that session, on screen or not —
    `@<window>`, a worker id (`wid:` optional) or a bare `@fleet_id`; `meta` its
    machine / login when the row knows them. None: the session in view, and in
    its shell the next ⌃\ is back on the session. Another machine's rides C5's
    standing link (`ssh -S <link> -tt … fleet-remote-view.sh shell-here <wid>`);
    a session reaped takes its shell along, never the other way. No session in
    view: this machine's shell in $HOME. rc 0 · 3 that session is gone (a line on
    the client)."""
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    if not fleet:
        return 2
    g = "%s@view-%s" % (fleet, vid)
    here, me = here_label(row), getpass.getuser()
    if target:
        t = target[4:] if target.startswith("wid:") else target
        if not t.startswith("@") and "/" not in t:
            # a bare @fleet_id: this fleet's window carrying it
            t = next((w for w, v in windows(fleet).items() if v[0] == t), "")
        w, far = resolve(vid, t, row, fleet) if t else ("", False)
        if far:
            m, l = far_where(t, meta, fleet)
            if not m:
                toast(client, say("view_gone"))
                return 3
            m, l, wid, name, prog = m, l or me, t, far_name(fleet, t), "far"
        else:
            rc, wname = tm("display-message", "-p", "-t", w, "#{window_name}") if w else (1, "")
            if rc != 0 or w not in windows(fleet):
                toast(client, say("view_gone"))
                return 3
            m, l, wid, name, prog = here, me, w, TAG_RE.sub("", wname).strip() or w, "here"
    else:
        rc, out = tm("display-message", "-p", "-t", "=%s:" % g,
                     "#{window_id}|#{@fleet_id}|#{@peer_node}|#{@peer_login}|#{@peer_cur}|#{@view_shell}|#{window_name}")
        if rc != 0 or not out:
            return 2
        w, fid, pnode, plogin, pcur, vsh, wname = (out.split("|") + [""] * 7)[:7]
        if vsh:
            code, _ = tm("last-window", "-t", "=" + g)
            return 0 if code == 0 else 1
        if pcur.startswith("wid:") and pnode:
            m, l, wid, name, prog = pnode, plogin or me, pcur[4:], far_name(fleet, pcur[4:]), "far"
        elif fid:
            m, l, wid, name, prog = here, me, w, TAG_RE.sub("", wname).strip() or w, "here"
        else:
            m, l, wid, name, prog = here, me, "", "", "home"
    key = "%s@%s:%s" % (m, l, wid) if wid else "local"
    _, lst = tm("list-windows", "-t", "=" + fleet, "-F", "#{window_id}|#{@view_shell}|#{@peer_view}")
    for line in lst.splitlines():
        sw, sk, sv = (line.split("|") + ["", ""])[:3]
        if sk == key and sv == vid:
            tm("select-window", "-t", "=%s:%s" % (g, sw))
            return 0
    pane = "exec python3 %s view-shell %s %s %s %s --view %s" % (
        shlex.quote(os.path.abspath(qo.__file__)), prog, shlex.quote(m), shlex.quote(l), shlex.quote(wid or "-"), shlex.quote(vid))
    title = say("view_shell_title_fmt", name, m) if wid else say("view_shell_home_fmt", m)
    rc, sw = tm("new-window", "-P", "-F", "#{window_id}", "-t", "=%s:" % g, "-c", os.path.expanduser("~"),
                "-n", title[:60], pane)
    if rc != 0 or not sw.startswith("@"):
        toast(client, say("view_shell_failed_fmt", m))
        return 1
    tm("set-option", "-w", "-t", sw, "@fleet_role", "panel", ";",
       "set-option", "-w", "-t", sw, "@view_shell", key, ";",
       "set-option", "-w", "-t", sw, "@peer_view", vid, ";",
       "set-option", "-w", "-t", sw, "automatic-rename", "off", ";",
       "set-option", "-w", "-t", sw, "allow-rename", "off", ";",
       "set-option", "-w", "-t", sw, "pane-border-status", "off")
    return 0


def wait_key(text):
    sys.stdout.write("\r\n" + text + "\r\n")
    sys.stdout.flush()
    try:
        import termios
        import tty
        old = termios.tcgetattr(0)
        tty.setraw(0)
        try:
            os.read(0, 1)
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, old)
    except Exception:  # noqa: BLE001 — no terminal: just end
        pass


def login_shell():
    import pwd
    sh = os.environ.get("SHELL") or ""
    if not os.access(sh, os.X_OK):
        try:
            sh = pwd.getpwuid(os.getuid()).pw_shell
        except KeyError:
            sh = "/bin/sh"
    return sh or "/bin/sh"


def agent_dir(w):
    """Where a session's agent is right now (issue #3183): the cwd its last Bash
    call left (`@agent_cwd`, stamped by set-claude-state.sh — Claude Code never
    chdirs its process), else its pane's `pane_current_path` — the pane the
    wrapper started, else the window's first, never a shell beside it — else the
    window's `@worktree`; "" when none is a directory. fleet-remote-view.sh
    shell-here keeps the same order."""
    _, out = tm("list-panes", "-t", w, "-F", "#{@agent_cwd}\t#{pane_current_path}\t#{pane_start_command}")
    panes = [(ln.split("\t") + ["", ""])[:3] for ln in out.splitlines() if ln]
    pick = next((p for p in panes if "fleet-session-wrap" in p[2]), panes[0] if panes else ["", "", ""])
    for d in pick[:2]:
        if d and os.path.isdir(d):
            return d
    _, wt = tm("display-message", "-p", "-t", w, "#{@worktree}")
    return wt if wt and os.path.isdir(wt) else ""


def shell_pane(vid, prog, m, l, wid):
    """`view-shell` — the ⌃\ window's program. here: the session's window (wid)
    in this fleet; its directory, a login shell there, HUP'd when that window goes.
    far: a channel on C5's link into the far machine's `shell-here`. home: $HOME."""
    bin_dir = str(Path(__file__).absolute().parent)
    path = os.path.expanduser("~/.local/bin") + ":" + bin_dir + ":" + os.environ.get("PATH", "")
    env = {k: v for k, v in os.environ.items() if k != "FLEET_WORKER_CRED"}
    env["PATH"] = path
    if prog == "far":
        pl = peerlink()
        sock, waited = "", 0.0
        while not sock and waited <= fenv("FLEET_VIEW_SHELL_WAIT", 10):
            sock = pl.up_sock(m, l)
            if not sock:
                if waited == 0:
                    sys.stdout.write(say("view_peer_wait_fmt", m) + "\r\n")
                    sys.stdout.flush()
                time.sleep(0.5)
                waited += 0.5
        if not sock:
            wait_key(say("view_shell_nolink_fmt", m))
            return 1
        cmd = "bash %s/fleet-remote-view.sh shell-here %s" % (pl.remote_bin(), shlex.quote(wid))
        rc = subprocess.call(pl.ssh_cmd() + ["-S", sock, "-o", "ControlMaster=no", "-tt", "-l", l,
                                             pl.ssh_host(m), cmd], env=env)
        if rc == 3:
            wait_key(say("view_shell_gone_fmt", m))
        elif rc == 255:
            wait_key(say("view_shell_nolink_fmt", m))
        return 0
    d = os.path.expanduser("~")
    if prog == "here":
        d = agent_dir(wid) or d
    sh = login_shell()
    pid = os.fork()
    if pid == 0:
        try:
            os.chdir(d)
        except OSError:
            pass
        env["PWD"] = d
        os.execve(sh, [sh, "-l"], env)
    if prog != "here":
        return rc_wait(pid)
    # the session's window gone (reaped, moved): its shell goes with it
    every = fenv("FLEET_SESSION_SHELL_WATCH", 5)
    while True:
        done, st = os.waitpid(pid, os.WNOHANG)
        if done:
            return 0
        time.sleep(every)
        rc, out = tm("list-windows", "-a", "-F", "#{window_id}")
        if rc == 0 and wid not in out.split():
            try:
                os.kill(pid, signal.SIGHUP)
            except OSError:
                pass
            return rc_wait(pid)


def rc_wait(pid):
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    return 0


# --- the key tables (conf/tmux-view.conf) ------------------------------------------------

ROOT_RE = re.compile(r"^(bind-key(?:\s+-r)?)\s+-T\s+root\s")


def key_extra(store=True):
    """The client keys this server binds (issue #3185): the union of every attach's
    FLEET_KEYS_EXTRA (fleet_keys.carried, in the attach's environment) — kept as the
    server option `@fleet_view_keys_extra`, so a conf re-source (no attach, no env)
    binds them again, and a phone attaching with none leaves the Mac's in place. A
    code no client's profile sends is bound to nothing that arrives."""
    _, have = tm("show-options", "-gqv", "@fleet_view_keys_extra")
    words = have.split()
    for w in (os.environ.get("FLEET_KEYS_EXTRA") or "").split():
        if w not in words:
            words.append(w)
    if store and " ".join(words) != have.strip():
        tm("set-option", "-g", "@fleet_view_keys_extra", " ".join(words))
    return " ".join(words)


def tkey(key):
    """A tmux key name as a bind-key argument."""
    return "'%s'" % key if not re.match(r"^[A-Za-z0-9-]+$", key) else key


def key_lines(me, extra=None):
    """The commands that rebuild both tables: root copied into fleet-view, then the
    看台's keys (issue #3185, EPIC #3178 C7) — by default ONE action, the panel:
    its ⌘ code (User927, ⌘P on the client) and the phone keys FLEET_KEY_PHONE
    (⌃空格 · F12 in fleet-view, ⌃] p); then what the person added — the clients'
    FLEET_KEYS_EXTRA (key_extra: a ⌘ chord → its action's code, any other chord →
    that tmux key) and this machine's FLEET_KEYS_PHONE_EXTRA (`ctrl+]n=next` → ⌃] n);
    ⌃] ⌃] always sends one ⌃] on."""
    import fleet_keys
    rc, root = tm("list-keys", "-T", "root")
    lines = ["unbind-key -q -a -T fleet-view", "unbind-key -q -a -T fleet-view-pfx"]
    for line in root.splitlines() if rc == 0 else []:
        if ROOT_RE.match(line):
            lines.append(ROOT_RE.sub(r"\1 -T fleet-view ", line, count=1))
    keymap = lambda what: subprocess.run(["bash", str(Path(me).parent / "dash-keymap.sh"), "--panel", "switch", what],
                                         capture_output=True, text=True, timeout=5).stdout
    try:
        table = keymap("list")
        defaults = keymap("default").split()
    except (OSError, subprocess.TimeoutExpired):
        table, defaults = "", ["quickopen"]
    codes = {t.split()[0]: t.split()[3] for t in table.splitlines() if len(t.split()) >= 5}
    # the codes too (conf/tmux-view.conf sets the same, idempotent); 924 926 930 retired
    lines += ['set-option -s user-keys[%s] "\\e[%s~"' % (c, c)
              for c in sorted(set(codes.values()) | {"924", "926", "930"}) if c.isdigit()]
    size = lambda pc: "#{?#{e|<:#{client_width},%d},100%%,%d%%}" % (NARROW, pc)
    popup = str(Path(me).parent / "dash-popup.sh")

    def cmd_of(action):
        verb = "do shell" if action == "shell" else VIEW_ACTIONS.get(action)
        if verb == "popup":
            # through the one popup door (dash-popup.sh, issue #3044), from a
            # run-shell, which expands the formats — the old client's road too.
            # Narrower than NARROW columns (a phone, C9): the whole screen.
            # --freeze: the session behind holds still while the list is up — tmux
            # 3.7c bleeds a pane's wrapped CJK through any popup (issue #3058)
            return ("run-shell -b \"bash '%s' --client '#{client_name}' --no-inline --freeze -w %s -h %s --title view_title "
                    "-- python3 '%s' --view '#{session_name}' --client '#{client_name}' "  # view-ok: the key's own session IS the 看台
                    ">/dev/null 2>&1 || :\"") % (popup, size(90), size(80), me)
        if verb == "dispatch":
            # ⌘T (C7): the old client's 派一件事 popup, run HERE with --view — the
            # repos the hub names, the agent picked per this one send (#1834)
            return ("run-shell -b \"bash '%s' --client '#{client_name}' --no-inline --freeze -w %s -h 12 --title view_dispatch_title "
                    "-- python3 '%s' --view '#{session_name}' --client '#{client_name}' "  # view-ok: the 看台
                    ">/dev/null 2>&1 || :\"") % (popup, size(80), str(Path(me).parent / "fleet-quick-dispatch.py"))
        if verb:
            return ("run-shell -b \"python3 '%s' %s --view '#{session_name}' --client '#{client_name}' "  # view-ok: the 看台
                    ">/dev/null 2>&1 || :\"") % (me, verb)
        return ""

    binds = {}      # (table, key) → command; a later layer wins a key it names again

    def bind(table, key, action):
        c = cmd_of(action)
        if c and key:
            binds[(table, key)] = c

    def bind_chord(chord, action):
        if fleet_keys.is_cmd(chord):
            bind("fleet-view", "User%s" % codes[action] if action in codes else "", action)
        else:
            tk = fleet_keys.tmux_key(chord)
            if tk and tk != ("fleet-view", PFX_KEY) and tk != ("fleet-view-pfx", PFX_KEY):
                bind(tk[0], tk[1], action)

    known = set(VIEW_ACTIONS) | set(fleet_keys.CODELESS)
    for action in defaults:                                   # ⌘P: User927, whatever chord the client picked
        if action in VIEW_ACTIONS and action in codes:
            bind("fleet-view", "User%s" % codes[action], action)
    for chord in fleet_keys.phone():                          # ⌃空格 · F12 · ⌃] p
        bind_chord(chord, "quickopen")
    for action, chord in fleet_keys.pairs(key_extra() if extra is None else extra, known):
        bind_chord(chord, action)
    for action, chord in fleet_keys.pairs(fleet_keys.phone_extra(), known):
        bind_chord(chord, action)
    _OURS[0] = {tk for tk in binds if tk[0] == "fleet-view"}
    for (table, key), c in binds.items():
        lines.append("bind-key -T %s %s %s" % (table, tkey(key), c))
    lines.append("bind-key -T fleet-view %s switch-client -T fleet-view-pfx" % PFX_KEY)
    lines.append("bind-key -T fleet-view-pfx %s send-keys %s" % (PFX_KEY, PFX_KEY))
    return lines


def our_keys(lines):
    """The fleet-view keys a build binds beyond its root copy (the copy check skips them)."""
    return {k for t, k in _OURS[0]} if _OURS[0] is not None else set()


_OURS = [None]


def keys_sig(lines):
    """What a build of the tables says it is: a hash of its commands, stamped as
    the server's `@fleet_view_keys_sig` (issue #3085)."""
    import hashlib
    return hashlib.sha1("\n".join(lines).encode("utf-8")).hexdigest()[:16]


def view_keys(me, if_stale=False):
    """Rebuild both tables. --if-stale (attach --thin, every attach): only when
    fleet-view exists and either its copy of root no longer IS root — a personal
    conf re-sourced after the fleet's moved root, and the 看台's mouse with it — or
    it was built by another version's key_lines (its `@fleet_view_keys_sig` is not
    this build's): a release that changed a bind (#3058's --freeze) reached a
    server whose conf it never re-sourced, and ⌘P kept the old popup (issue #3085)."""
    if if_stale:
        rc, fv = tm("list-keys", "-T", "fleet-view")
        _, root = tm("list-keys", "-T", "root")
        if rc != 0 or not fv:
            return 0          # never loaded here: attach --thin adds no table (C1's rule)
        lines = key_lines(me)
        sig = keys_sig(lines)
        ours = our_keys(lines) | {"C-]"}
        norm = lambda line: " ".join(line.split())
        def key_of(line):
            f = line.split()
            i = f.index("-T") + 2 if "-T" in f else len(f)
            return f[i].replace("\\\\", "\\") if i < len(f) else ""
        copy = sorted(norm(ROOT_RE.sub(r"\1 -T root ", l.replace(" -T fleet-view ", " -T root ", 1)))
                      for l in fv.splitlines() if key_of(l) not in ours)
        want = sorted(norm(l) for l in root.splitlines() if key_of(l) not in ours)
        _, have = tm("show-options", "-gqv", "@fleet_view_keys_sig")
        if have.strip() == sig and copy == want:
            return 0
    else:
        lines = key_lines(me)
        sig = keys_sig(lines)
    import tempfile
    fd, tmp = tempfile.mkstemp(prefix="fleet-view-keys.", suffix=".conf")
    try:
        with os.fdopen(fd, "w") as out:
            out.write("\n".join(lines + ["set-option -g @fleet_view_keys_sig %s" % sig]) + "\n")
        rc, _ = tm("source-file", tmp)
        return rc
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# --- a row's actions: Tab (issue #3181, EPIC #3178 C3) ----------------------------------
#
# THE table (共同约定 2): every thing the old sidebar's row menu did to a session
# (fleet-sidebar-menu.sh) is one ACTIONS entry — `id` · `label(row)` · `when(row)`
# · `local(row, answer)` · `far(row, answer)` (C4 fills it; None = not on another
# machine's row yet) · `ask` (None | "text" | "key" | "choice": the question the
# panel's bottom line asks first). `local` / `far` return the argv of the SAME
# script the sidebar ran (nothing re-implemented), or a verb this module does
# itself (go · shell · resume). The popup's Tab menu, `view-menu` and `view-act`
# (C2's command line) all read this one table. A row is the list's entry (entries())
# plus what its window says now (facts()).

def act_bin():
    """Where the actions' scripts are: beside this file (FLEET_VIEW_ACT_BIN — the
    selftest's stubs)."""
    return Path(os.environ.get("FLEET_VIEW_ACT_BIN") or Path(__file__).absolute().parent)


def sh(name, *args):
    return ["bash", str(act_bin() / name)] + [str(a) for a in args]


def facts(fleet, e):
    """What a local row's window says now: pin · sleep · keep-awake · agent · the
    needs kind · @fleet_id · its name · the wrapper's page up · its PR."""
    t = e.get("target") or ""
    if e.get("far"):
        # another machine's: what it asks is all the panel needs to know (a
        # permission prompt is y / n; fleet-sidebar-remote.sh reads the rest)
        return {"needs": ("perm" if e.get("detail") == "perm" else "ask") if e.get("state") == "needs" else ""}
    if not t.startswith("@"):
        return {}
    rc, out = tm("display-message", "-p", "-t", t, "#{window_id}|#{@pin}|#{@worker_lifecycle}|#{@sleep_keep_awake}|"
                 "#{@cc_agent}|#{@claude_needs}|#{@fleet_id}|#{window_name}|#{@wrap_exit_rc}|#{pane_id}")
    f = (out.split("|") + [""] * 10)[:10] if rc == 0 else [""] * 10
    if f[0] != t:     # tmux answers a gone id with another window's format
        return {"gone": True}
    pr = ""
    try:
        pr = subprocess.run(sh("dash-open-pr.sh", "--wid", t, "--probe"), capture_output=True, text=True, timeout=3,
                            env=act_env(fleet), stdin=subprocess.DEVNULL).stdout.strip().splitlines()
        pr = pr[-1] if pr else ""
    except (OSError, subprocess.TimeoutExpired):
        pr = ""
    return {"pin": f[1] == "1", "life": f[2], "keep": f[3] == "1", "agent": f[4] or "claude", "needs": f[5],
            "fid": f[6], "wname": f[7], "page": f[8] != "", "pane": f[9], "pr": pr}


def live(r):
    return not r.get("far") and not r.get("gone") and r.get("state") not in ("exited",)


def ended(r):
    return r.get("sec") == "ended"


def other_agent(r):
    return "Claude" if r.get("agent") == "codex" else "Codex"


REAP_CHOICES = (("merged", "reap_menu_merged"), ("done:2h", "reap_menu_done_2h"), ("loop-end", "reap_menu_loop_end"),
                ("at", "reap_menu_at"), ("keep", "reap_menu_keep"))


def reap_choices(r, fleet):
    cur = (r.get("reap") or "").partition(":")[0]
    return [(v, ("● " if cur and cur == v.partition(":")[0] else "") + say(k)) for v, k in REAP_CHOICES]


def sub_choices(r, fleet):
    """fleet-manual-sub.sh list → (account, `account · 5h · 7d · note`), as the
    sidebar's 迁移到… stepped through them."""
    try:
        out = subprocess.run(sh("fleet-manual-sub.sh", "list", fleet), capture_output=True, text=True, timeout=15,
                             env=act_env(fleet), stdin=subprocess.DEVNULL).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    rows = [l.split("\t") for l in out.splitlines()[1:] if l.count("\t") >= 3]
    return [(x[0], " · ".join(y for y in (x[0], "5h " + x[1] if x[1] else "", "7d " + x[2] if x[2] else "", x[3]) if y))
            for x in rows]


def answer_ask(r):
    """A permission prompt is y / n, a question its option number(s); anything
    else (a login, a blocked worker) is answered in its own pane: go there."""
    return {"perm": "key", "ask": "text"}.get(r.get("needs"), None)


def answer_local(r, ans, fleet):
    w = r["target"]
    if r.get("needs") == "perm":
        return sh("fleet-permission.sh", "--allow" if ans in ("y", "Y") else "--deny", w,
                  "--session", fleet, "--by", getpass.getuser())
    if r.get("needs") == "ask":
        return sh("fleet-answer.sh", "--answer", w, "--session", fleet, *ans.split())
    return "go"


def reappol_local(r, ans, fleet):
    return sh("fleet-reap-policy.sh", "set", ans, "--win", r["target"], "--session", fleet)


def far(action):
    """Another machine's row: the hub write the old sidebar made for it
    (fleet-sidebar-remote.sh <action> <fleet> wid:<worker_id>); the answer rides
    FLEET_SIDEBAR_TEXT (act_run)."""
    return lambda r, a, f: sh("fleet-sidebar-remote.sh", action, f, "wid:" + r["target"])


def far_live(r):
    return bool(r.get("far")) and r.get("state") != "exited" and not ended(r)


# Each entry: id · label · when · local · far · ask (+ prompt / choices / slow: run
# in the background from the popup — a stop, a reap, a move take seconds).
ACTIONS = [
    # 进入
    {"id": "enter", "label": lambda r: say("view_act_enter"), "when": lambda r: not r.get("gone"),
     "local": lambda r, a, f: "go", "far": lambda r, a, f: "go", "ask": None},
    {"id": "shell", "label": lambda r: say("view_act_shell"),
     "when": lambda r: not r.get("gone") and not r.get("lost") and r.get("state") != "exited",
     "local": lambda r, a, f: "shell", "far": lambda r, a, f: "shell", "ask": None},
    {"id": "pr", "label": lambda r: say("view_act_pr_fmt", r.get("pr")), "when": lambda r: bool(r.get("pr")),
     "local": lambda r, a, f: sh("dash-open-pr.sh", "--wid", r["target"]), "far": None, "ask": None},
    # 消息
    {"id": "answer", "label": lambda r: say("view_act_answer"),
     "when": lambda r: (live(r) or far_live(r)) and r.get("state") == "needs",
     "local": answer_local, "far": far("answer"), "ask": answer_ask,
     "prompt": lambda r: say("view_ask_perm") if r.get("needs") == "perm" else say("view_ask_pick"), "keys": "yYnN"},
    {"id": "message", "label": lambda r: say("view_act_message"), "when": lambda r: live(r) or far_live(r),
     "local": lambda r, a, f: sh("fleet-peer-send.sh", r["target"], a), "far": far("message"), "ask": "text",
     "prompt": lambda r: say("view_ask_message")},
    # 控制
    {"id": "rename", "label": lambda r: say("view_act_rename"), "when": lambda r: not r.get("gone"),
     "local": lambda r, a, f: sh("dash-rename.sh", "--wid", r["target"], a), "far": far("rename"), "ask": "text",
     "prompt": lambda r: say("view_ask_rename"), "default": lambda r: r.get("wname") or r.get("name") or ""},
    {"id": "pin", "label": lambda r: say("view_act_unpin" if r.get("pin") else "view_act_pin"),
     "when": lambda r: not r.get("far") and not r.get("gone"),
     "local": lambda r, a, f: sh("dash-pin-toggle.sh", r["target"]), "far": None, "ask": None},
    {"id": "reappol", "label": lambda r: say("view_act_reappol"), "when": lambda r: not r.get("gone"),
     "local": reappol_local, "far": far("reappol"), "ask": "choice", "choices": reap_choices,
     "then": {"at": ("text", lambda r: say("view_ask_at"))}},
    {"id": "stop", "label": lambda r: say("view_act_stop"),
     "when": lambda r: (live(r) and bool(r.get("fid")) and r.get("life") != "sleeping") or far_live(r),
     "local": lambda r, a, f: sh("fleet-worker-stop.sh", f, "fid:" + r["fid"]), "far": far("stop"), "ask": None,
     "slow": True},
    {"id": "resume", "label": lambda r: say("view_act_restore" if ended(r) else "view_act_resume"),
     "when": lambda r: r.get("gone") or (r.get("state") == "exited" and (r.get("far") or r.get("page"))),
     "local": lambda r, a, f: "restore" if r.get("gone") else "resume", "far": far("resume"), "ask": None,
     "slow": True, "keys": "yYrR"},
    {"id": "wake", "label": lambda r: say("view_act_wake"), "when": lambda r: not r.get("far") and r.get("life") == "sleeping",
     "local": lambda r, a, f: sh("fleet-sleep.sh", "wake", f, r["target"], "--over-cap"), "far": None, "ask": None,
     "slow": True},
    {"id": "awake", "label": lambda r: say("view_act_allow_sleep" if r.get("keep") else "view_act_keep_awake"),
     "when": lambda r: not r.get("far") and not r.get("gone"),
     "local": lambda r, a, f: sh("fleet-sleep.sh", "allow-sleep" if r.get("keep") else "keep-awake", f, r["target"]),
     "far": None, "ask": None},
    {"id": "sub", "label": lambda r: say("view_act_sub"), "when": lambda r: live(r) and r.get("agent") != "codex",
     "local": lambda r, a, f: sh("dash-migrate.sh", r["target"], "to", a), "far": None, "ask": "choice",
     "choices": sub_choices, "slow": True},
    {"id": "agent", "label": lambda r: say("view_act_agent_fmt", other_agent(r)), "when": live,
     "local": lambda r, a, f: sh("fleet-transfer.sh", "--session", f, "--window", r["target"], "--to",
                                 other_agent(r).lower()), "far": None, "ask": None, "slow": True},
    {"id": "reap", "label": lambda r: say("view_act_reap"), "when": lambda r: not r.get("gone"),
     "local": lambda r, a, f: sh("dash-reap.sh", r["target"], "--yes"), "far": far("reap"), "ask": "key",
     "prompt": lambda r: say("view_ask_reap_fmt", r.get("text") or r.get("name") or r["target"]), "keys": "yYnN",
     "yes": True, "slow": True},
    # row-less (issue #3180, C2): the panel's command rows, never a Tab menu's
    {"id": "new", "label": lambda r: say("view_cmd_new"), "when": lambda r: True, "rowless": True,
     "local": lambda r, a, f: "dispatch", "far": None, "ask": "text", "prompt": lambda r: say("view_cmd_new")},
    {"id": "newsess", "label": lambda r: say("view_cmd_newsess"), "when": lambda r: True, "rowless": True,
     "local": lambda r, a, f: "newsess", "far": None, "ask": None},
    {"id": "quit", "label": lambda r: say("view_cmd_quit"), "when": lambda r: True, "rowless": True,
     "local": lambda r, a, f: "quit", "far": None, "ask": None},
]
ACTION = {a["id"]: a for a in ACTIONS}
# The sidebar menu's letters (fleet-ui-lang.sh menu_keys) → the action here; the
# row-less ones (no row to act on) live elsewhere — the list's top lines (C2), the
# client's own keys (C7). fleet-view-actions-selftest.sh holds the two lists in step.
SIDEBAR_ACTIONS = {"rename": "rename", "pin": "pin", "pr": "pr", "answer": "answer", "sub": "sub", "wake": "wake",
                   "awake": "awake", "reappol": "reappol", "agent": "agent", "reap": "reap", "open": "enter",
                   "message": "message", "stop": "stop", "resume": "resume", "restore": "resume"}
ROWLESS = {"new": "C2", "newto": "C2", "repo": "C2", "clients": "C7", "quit": "C7"}


def act_env(fleet):
    """The scripts' context: bare tmux on THIS fleet's server (TMUX inherited in a
    pane, else pointed at the socket — as fleet-control-read.sh does), never a
    TMUX_PANE (an empty one is the pane the person looks at)."""
    env = dict(os.environ, FLEET_SESSION=fleet)
    env.pop("TMUX_PANE", None)
    if not env.get("TMUX") and _SOCK[0]:
        rc, sp = tm("display-message", "-p", "#{socket_path}")
        if rc == 0 and sp:
            env["TMUX"] = sp + ",0,0"
    return env


def act_row(fleet, e):
    r = dict(e)
    r.update(facts(fleet, e))
    return r


def menu_of(r):
    """The actions a row gets, in the table's order: (action, label)."""
    out = []
    for a in ACTIONS:
        if a.get("rowless") or (a["far"] if r.get("far") else a["local"]) is None:
            continue
        try:
            if a["when"](r):
                out.append((a, a["label"](r)))
        except (KeyError, TypeError):
            continue
    return out


def act_ask(a, r):
    ask = a["ask"]
    return ask(r) if callable(ask) else ask


def act_run(qo, vid, fleet, a, r, ans, client="", wait=True):
    """Do one action: (rc, the line to say, went — the 看台 is on the row now).
    `wait` False runs a slow one in the background (the popup does not freeze on
    a reap)."""
    fn = a["far"] if r.get("far") else a["local"]
    argv = fn(r, ans, fleet)
    label = a["label"](r).rstrip("…")
    if argv in ("go", "shell") and lost_msg(r):
        return 1, lost_msg(r), False
    if argv == "go":
        rc = go(qo, vid, r["target"], "menu", client, r)
        return rc, "" if rc == 0 else (say("view_far_fmt", r.get("machine") or "?") if rc == 3 else say("view_gone")), rc == 0
    if argv == "shell":
        # C5's road (issue #3183): a shell beside that session, where its agent is
        rc = open_shell(qo, vid, client, r["target"], r)
        return rc, "" if rc == 0 else (say("view_gone") if rc == 3 else
                                       say("view_shell_failed_fmt", r.get("machine") or "?")), rc == 0
    if argv == "newsess":
        rc = go_new(qo, vid, client)
        return rc, "" if rc == 0 else say("view_new_failed"), rc == 0
    if argv == "quit":
        rc = quit_view(vid, client)
        return rc, "", rc == 0
    if argv == "dispatch":
        repo, have = repo_pick()
        if not repo:
            return 2, say("view_new_norepo") if not have else ask_line({"repos": have, "i": -1}), False
        rc, said = dispatch(None, vid, client, ans, repo)
        return rc, said, False
    if argv == "restore":
        # a gone row (issue #3286): the sidebar's ⌃t restore, the same script. A
        # `landed:issue:` row may have to ask first (a CLOSED-unmerged PR, #543):
        # --ask exits 4 with the question, the answer comes back as --answer y|r
        cmd = sh("fleet-restore-pick.sh", "--select", r["target"], "--session", fleet)
        env = act_env(fleet)
        if not wait and not ans and not r["target"].startswith("landed:issue:"):
            try:
                subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            except OSError:
                return 1, say("view_act_failed_fmt", label, ""), False
            return 0, say("view_act_sent_fmt", label), False
        try:
            p = subprocess.run(cmd + (["--answer", ans.lower()] if ans else ["--ask"]), env=env, capture_output=True,
                               text=True, stdin=subprocess.DEVNULL, timeout=300)
        except (OSError, subprocess.TimeoutExpired):
            return 1, say("view_act_failed_fmt", label, ""), False
        said = ((p.stdout.strip() or p.stderr.strip()).splitlines() or [""])[-1]
        if p.returncode == 4:
            return 4, one_line(said, 160), False
        if p.returncode != 0:
            return p.returncode, say("view_act_failed_fmt", label, one_line(said, 120)), False
        return 0, say("view_act_done_fmt", label), False
    if argv == "resume":
        # the wrapper's page (fleet-session-wrap.sh): ↵ resumes the same conversation
        rc, _ = tm("send-keys", "-t", r.get("pane") or r["target"], "Enter")
        went = rc == 0 and go(qo, vid, r["target"], "menu", client, r) == 0
        return rc, say("view_act_done_fmt", label) if rc == 0 else say("view_act_failed_fmt", label, ""), went
    env = act_env(fleet)
    if r.get("far"):
        # a hub write (fleet-sidebar-remote.sh): nothing goes out for a lost row
        if r.get("lost"):
            return 1, say("view_lost_act_fmt", r.get("machine") or "?"), False
        env.update(FLEET_SIDEBAR_TEXT=ans, FLEET_REMOTE_SAY="print")
        try:
            p = subprocess.run(argv, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=150,
                               start_new_session=True)
        except (OSError, subprocess.TimeoutExpired):
            return 1, say("view_act_failed_fmt", label, ""), False
        said = ((p.stdout.strip() or p.stderr.strip()).splitlines() or [""])[-1]
        hub_reread(fleet)
        if p.returncode != 0:
            return p.returncode, "✗ " + one_line(said or label, 160), False
        return 0, "✓ " + one_line(said or label, 160), False
    if not wait and a.get("slow"):
        try:
            subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            return 1, say("view_act_failed_fmt", label, ""), False
        return 0, say("view_act_sent_fmt", label), False
    try:
        p = subprocess.run(argv, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                           timeout=300 if a.get("slow") else 30)
    except (OSError, subprocess.TimeoutExpired):
        return 1, say("view_act_failed_fmt", label, ""), False
    said = ((p.stdout.strip() or p.stderr.strip()).splitlines() or [""])[-1]
    if p.returncode != 0:
        return p.returncode, say("view_act_failed_fmt", label, one_line(said, 120)), False
    return 0, say("view_act_done_fmt", label) + ((" · " + one_line(said, 80)) if said else ""), False


def find_row(vid, target):
    for e in entries(vid):
        if e["kind"] == "sess" and e.get("target") == target:
            return e
    return None


def cli_menu(vid, target):
    """view-menu: the row's actions, `id<TAB>label<TAB>ask` a line."""
    e = find_row(vid, target)
    if e is None:
        print(say("view_gone"), file=sys.stderr)
        return 1
    r = act_row(view_fleet(vid), e)
    for a, label in menu_of(r):
        print("\t".join((a["id"], label, act_ask(a, r) or "")))
    return 0


def cli_act(qo, vid, target, aid, text=None, yes=False, client=""):
    """view-act: one action on one row, as the Tab menu does it (C2's command line).
    A question the action asks is --text (a line, a choice's value, a key); a
    confirming one needs --yes. Exit: the script's, 2 not applicable / no answer,
    3 not confirmed."""
    fleet = view_fleet(vid)
    e = find_row(vid, target)
    if e is None or aid not in ACTION:
        print(say("view_gone") if e is None else "no action " + aid, file=sys.stderr)
        return 2
    r = act_row(fleet, e)
    a = ACTION[aid]
    if all(x is not a for x, _ in menu_of(r)):
        print("%s: not for this row" % aid, file=sys.stderr)
        return 2
    if a.get("yes"):
        # a y / n confirm (回收): --yes is the y
        if not yes and (text or "").lower() != "y":
            print("%s: not confirmed (--yes)" % aid, file=sys.stderr)
            return 3
        text = "y"
    if act_ask(a, r) and text is None:
        print("%s: needs --text" % aid, file=sys.stderr)
        return 2
    rc, said, _ = act_run(qo, vid, fleet, a, r, text or "", client, wait=True)
    if said:
        print(said)
    return rc


# --- the panel's command rows (issue #3180, EPIC #3178 C2) ------------------------------

PANEL_WORDS = ("new", "shell", "newsess", "quit", "landed")


def panel_commands():
    """FLEET_PANEL_COMMANDS (the environment, else fleet.conf's line; default
    `new shell`): the words that sit ABOVE the list, in that order — new (「新任务」)
    · shell (「在 <会话> 的目录开 shell」) · newsess · quit · landed (the 刚落地 group
    first). newsess / quit not named go to 「更多」 below the list; `none` takes
    every command row away. (top, bottom)."""
    raw = os.environ.get("FLEET_PANEL_COMMANDS")
    if raw is None:
        try:
            line = subprocess.run(["bash", str(Path(__file__).absolute().parent / "fleet-conf.sh"), "line",
                                   "FLEET_PANEL_COMMANDS"], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.TimeoutExpired):
            line = ""
        m = re.search(r"FLEET_PANEL_COMMANDS=(['\"]?)([^'\"\n]*)\1", line.strip().splitlines()[-1] if line.strip() else "")
        raw = m.group(2) if m else ""
    words = raw.replace(",", " ").split() or ["new", "shell"]
    if "none" in words:
        return [], []
    top = []
    for w in words:
        if w in PANEL_WORDS and w not in top:
            top.append(w)
    return top, [w for w in ("newsess", "quit") if w not in top]


def sess_label(e):
    """A session as a command row names it: #N 「标题前 12 字…」."""
    title = (e or {}).get("text") or (e or {}).get("name") or ""
    title = title[:12] + "…" if len(title) > 12 else title
    issue = ((e or {}).get("issue") or "").lstrip("#")
    return say("view_sess_issue_fmt", issue, title) if issue else say("view_sess_fmt", title)


def landed_first(items):
    """The 刚落地 group moved above the others (`landed` in FLEET_PANEL_COMMANDS)."""
    i = next((n for n, e in enumerate(items) if e["kind"] == "hdr" and e.get("group") == "landed"), -1)
    if i < 0:
        return items
    j = next((n for n in range(i + 1, len(items)) if items[n]["kind"] in ("hdr", "sec")), len(items))
    return items[i:j] + items[:i] + items[j:]


def panel_rows(items, query, opened, cur="", shell_of="", cmds=None):
    """What the popup lists: the command rows above (FLEET_PANEL_COMMANDS' top),
    the sessions (visible()), then 「更多」 — 开一个空白新会话 · 退出 fleet. `cur` the
    session in view (the shell row's), `shell_of` the session whose shell the
    panel was opened in: its 「回到 …」 row comes first, in the shell row's place.
    With a query the 「新任务」 row says the words (↵ sends them as the title) and
    the other command rows stay only where their words hit."""
    top, bottom = panel_commands() if cmds is None else cmds
    if "landed" in top:
        items = landed_first(items)
    sess = {e.get("target"): e for e in items if e["kind"] == "sess"}
    q = query.strip()
    hit = lambda e: not q or all(w in e["text"].lower() for w in q.lower().split())

    # each row names its ACTIONS entry (`act`) and the session it acts on (`row`)
    def row(w):
        if w == "new":
            return {"kind": "cmd", "cmd": "new", "act": "new", "row": {},
                    "text": say("view_cmd_new_fmt", q) if q else say("view_cmd_new"), "foot": say("view_cmd_new_foot")}
        if w == "shell":
            if shell_of:
                return {"kind": "cmd", "cmd": "back", "act": "enter", "row": sess.get(shell_of) or {"target": shell_of},
                        "text": say("view_cmd_back_fmt", sess_label(sess.get(shell_of)))}
            e = sess.get(cur)
            if e:
                return {"kind": "cmd", "cmd": "shell", "act": "shell", "row": e,
                        "text": say("view_cmd_shell_fmt", sess_label(e))}
            return {"kind": "cmd", "cmd": "shell", "act": "shell", "row": {"target": ""},
                    "text": say("view_cmd_shell_home")}
        if w in ("newsess", "quit"):
            return {"kind": "cmd", "cmd": w, "act": w, "row": {}, "text": ACTION[w]["label"]({})}
        return None
    head = [r for r in (row(w) for w in top) if r]
    # in a session's shell, 「回到」 is the first line
    head.sort(key=lambda r: r["cmd"] != "back")
    tail = [r for r in (row(w) for w in bottom) if r]
    if q:
        head = [r for r in head if r["cmd"] == "new" or hit(r)]
        tail = [r for r in tail if hit(r)]
    more = [{"kind": "hdr", "group": "more", "text": say("view_grp_more")}] + tail if tail else []
    return head + visible(items, query, opened) + more


def repo_pick():
    """(the repo 「新任务」 sends to — '' = ask, every repo the hub names):
    fleet-quick-dispatch.py pick, ⌘T's own rule (the last send's, else the only one)."""
    try:
        out = subprocess.run([sys.executable, str(Path(__file__).absolute().parent / "fleet-quick-dispatch.py"), "pick"],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    lines = out.split("\n")
    return lines[0].strip(), [l.strip() for l in lines[1:] if l.strip()]


def ask_line(asking):
    return say("view_ask_repo_fmt", "  ".join(("[%s]" if i == asking["i"] else "%s") % r
                                              for i, r in enumerate(asking["repos"])))


def dispatch(screen, vid, client, title, repo):
    """「新任务」's ↵: ⌘T's send, no second dialog — fleet-quick-dispatch.py send
    --title <the words, as typed> --repo <repo> --view <the 看台> (it opens the
    session here and moves the 看台 onto it). (rc, words for the footer)."""
    try:
        if screen is not None:     # the popup says 「派单中」 meanwhile; view-act has none
            h, w = screen.getmaxyx()
            screen.addnstr(h - 2, 0, say("view_new_sending_fmt", title)[:max(1, w - 1)], max(1, w - 1))
            screen.clrtoeol()
            screen.refresh()
    except curses.error:
        pass
    g = "%s@view-%s" % (view_fleet(vid), vid)
    argv = [sys.executable, str(Path(__file__).absolute().parent / "fleet-quick-dispatch.py"), "send",
            "--title", title, "--repo", repo, "--view", g] + (["--client", client] if client else [])
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           timeout=fenv("FLEET_VIEW_NEW_SECS", 60))
        rc, said = p.returncode, (p.stdout.strip() or p.stderr.strip()).splitlines()
    except (OSError, subprocess.TimeoutExpired) as error:
        rc, said = 1, [str(error)]
    said = said[-1] if said else ""
    if rc == 0 and said:
        toast(client, said)
    return (0 if rc == 0 else 1), said


class Line:
    """The bottom line's editor (fleet-ask.py's way, cut to what a short answer
    needs): type, ⌫, ⌃U clears, ↵ submits, Esc cancels."""
    def __init__(self, text=""):
        self.text = text

    def key(self, ch):
        if ch in (curses.KEY_BACKSPACE, "\x7f", "\b"):
            self.text = self.text[:-1]
        elif ch == "\x15":
            self.text = ""
        elif isinstance(ch, str) and ch.isprintable():
            self.text += ch


# --- the popup -------------------------------------------------------------------------

def popup(screen, qo, vid, client):
    # raw: ⌃\ is a key here (a shell beside the lit row), never SIGQUIT
    curses.raw()
    curses.curs_set(0)
    styles = {"bold": curses.A_BOLD, "lit": curses.A_REVERSE | curses.A_BOLD}
    try:
        curses.use_default_colors()
        grey = 8 if curses.COLORS > 8 else curses.COLOR_WHITE
        styles["dim"] = curses.A_NORMAL
        if color_on():
            curses.init_pair(2, grey, -1)
            curses.init_pair(3, curses.COLOR_CYAN, -1)
            curses.init_pair(4, curses.COLOR_RED, -1)
            styles["red"] = curses.color_pair(4) | curses.A_BOLD
            styles["dim"] = curses.color_pair(2)
            for n in sorted(set(GLYPH_COLORS.values())):
                c = n if n < curses.COLORS else (curses.COLOR_WHITE if n == 8 else n % 8)
                curses.init_pair(10 + n, c, -1)
                styles["c%d" % n] = curses.color_pair(10 + n)
    except curses.error:
        pass

    def attr(style):
        a = 0
        for k in style:
            a |= styles.get(k, 0)
        return a
    items = entries(vid)
    order_save(vid, items)
    cur = current(vid)
    # opened in a session's shell (⌃\): its session is the lit row — ↵ is back on it;
    # with the command rows on, 「回到 …」 is the first line and lit (issue #3180)
    _, vsh = tm("display-message", "-p", "-t", "=%s@view-%s:" % (view_fleet(vid), vid), "#{@view_shell}")
    shell_of = ""
    if ":" in vsh:
        cur = shell_of = vsh.split(":", 1)[1]
    fleet = view_fleet(vid)
    cmds = panel_commands()
    query, opened, msg, show_legend = "", set(), "", False
    asking = None      # 「派到哪个仓库」: {"title", "repos", "i"} while the footer asks

    def listing():
        return panel_rows(items, query, opened, cur, shell_of, cmds)

    def key_of(e):
        return (e.get("kind"), e.get("cmd") or e.get("target") or e.get("sec"))
    shown = listing()
    at = next((i for i, e in enumerate(shown) if e.get("cmd") == "back"),
              next((i for i, e in enumerate(shown) if e.get("target") == cur and e["kind"] == "sess"),
                   next((i for i, e in enumerate(shown) if pickable(e)), 0)))
    top = 0
    heal = qo.Heal()
    fresh = Refresh(vid)
    # Tab (issue #3181): `menu` = the row's actions, `choice` = an action's options,
    # `ask` = the question on the bottom line. Esc steps back to the list.
    mode, mrow, mitems, mat, mtitle, pend, line = "", None, [], 0, "", None, Line()
    # another machine's action runs off the screen's thread (a hub write waits up
    # to its op's answer): its line lands here, then the list is read again
    landed = []

    def back():
        nonlocal mode, mrow, mitems, mat, pend
        mode, mrow, mitems, mat, pend = "", None, [], 0, None

    def run(a, r, ans):
        """Do it, say how it went, read the list again (a pin, a rename, a reap
        shows at once); back on the list."""
        nonlocal items, shown, msg, mode, pend, line
        if r.get("far") and not r.get("lost") and a["id"] not in ("enter", "shell"):
            def far_run():
                landed.append(act_run(qo, vid, fleet, a, r, ans, client)[1])
            threading.Thread(target=far_run, daemon=True).start()
            back()
            msg = say("view_act_sent_fmt", a["label"](r).rstrip("…"))
            return False
        rc, said, went = act_run(qo, vid, fleet, a, r, ans, client, wait=False)
        back()
        if rc == 4 and r.get("gone") and not ans:
            # a restore that asks first (#543): its question on the bottom line,
            # y reopen the PR · r restore anyway · any other key cancels
            mode, pend, line = "ask", (a, r, "", "key", said + " · " + say("view_ask_restore")), Line()
            return False
        if went:
            return True     # the 看台 is on it now: the popup closes
        msg = said
        items = entries(vid)
        shown = listing()
        return False

    def pick(a, r, value=None):
        """An action picked (or one of its options): ask what it needs, else do it."""
        nonlocal mode, mitems, mat, mtitle, pend, line
        ask = act_ask(a, r)
        if value is not None:
            then = (a.get("then") or {}).get(value)
            if then:
                mode, pend, line = "ask", (a, r, value + ":", "text", then[1](r)), Line()
                return False
            return run(a, r, value)
        if ask == "choice":
            ch = a["choices"](r, fleet)
            if not ch:
                return run_none(a, r)
            mode, mitems, mat, mtitle, pend = "choice", [(v, l, a) for v, l in ch], 0, a["label"](r), (a, r)
            return False
        if ask in ("text", "key"):
            dflt = a.get("default")
            mode, pend, line = "ask", (a, r, "", ask, a["prompt"](r)), Line(dflt(r) if dflt else "")
            return False
        return run(a, r, "")

    def run_none(a, r):
        nonlocal msg
        back()
        msg = say("view_act_failed_fmt", a["label"](r), say("view_act_nothing"))
        return False

    while True:
        if landed:
            msg = landed.pop(0)
            items = entries(vid)
            shown = visible(items, query, opened)
        new = fresh.poll()
        if new is not None:
            # the list read again: the lit row stays the lit row (by its key)
            lit = key_of(shown[at]) if 0 <= at < len(shown) else (None, None)
            items = new
            shown = listing()
            at = next((i for i, e in enumerate(shown) if pickable(e) and lit[1] and key_of(e) == lit),
                      min(at, max(0, len(shown) - 1)))
        heal.tick(screen)
        height, width = screen.getmaxyx()
        screen.erase()
        ban = banner(items)
        off = 2 if ban else 1
        body = max(1, height - 2 - off)
        if mode in ("menu", "choice"):
            screen.addnstr(0, 0, qo.clip("› " + query, width - 1), width - 1)
            screen.addnstr(1, 0, qo.clip("─ " + mtitle + " ", width - 1), width - 1, attr(("bold",)))
            mtop = max(0, mat - (body - 2))
            for y, (_, label, _) in enumerate(mitems[mtop:mtop + body - 1], 2):
                lit = mtop + y - 2 == mat
                screen.addnstr(y, 0, qo.clip(("▶ " if lit else "  ") + label, width - 1), width - 1,
                               attr(("lit", "bold") if lit else ()))
            screen.addnstr(height - 2, 0, qo.clip(msg, width - 1), width - 1)
            screen.addnstr(height - 1, 0, qo.clip(say("view_act_keys"), width - 1), width - 1, attr(("dim",)))
            screen.refresh()
            screen.timeout(heal.timeout(False) or 1000)
            try:
                ch = screen.get_wch()
            except curses.error:
                continue
            msg = ""
            if ch == curses.KEY_RESIZE:
                heal.resized(screen)
            elif ch in ("\x1b", "\x03"):
                back()
            elif ch in (curses.KEY_UP, "\x10"):
                mat = max(0, mat - 1)
            elif ch in (curses.KEY_DOWN, "\x0e", "\t"):
                mat = min(len(mitems) - 1, mat + 1)
            elif ch in ("\n", "\r", curses.KEY_ENTER) and mitems:
                v, _, a = mitems[mat]
                done = pick(a, mrow) if mode == "menu" else pick(a, pend[1], v)
                if done:
                    return 0
            continue
        sel = [i for i, e in enumerate(shown) if pickable(e)]
        if sel and at not in sel:
            at = min(sel, key=lambda i: abs(i - at))
        if at < top:
            top = at
        if at >= top + body:
            top = at - body + 1
        # the lit row's question under it stays on screen
        if at + 1 < len(shown) and shown[at + 1]["kind"] == "ask" and at + 1 >= top + body:
            top += 1
        screen.addnstr(0, 0, qo.clip("› " + query, width - 1), width - 1)
        if ban:
            try:
                screen.addnstr(1, 0, qo.clip(ban, width - 1), width - 1, attr(("red",)) or curses.A_BOLD)
            except curses.error:
                pass
        for y, segs in enumerate(paint(shown[top:top + body], at - top, width - 1, qo.cells, qo.clip), off):
            x = 0
            for text, style in segs:
                if x >= width - 1:
                    break
                try:
                    screen.addnstr(y, x, text, width - 1 - x, attr(style))
                except curses.error:
                    pass
                x += qo.cells(text)
        if mode == "ask":
            # the question on the bottom line, the keyboard in it (fleet-ask.py's way)
            screen.addnstr(height - 2, 0, qo.clip(pend[4] + line.text + ("" if pend[3] == "key" else "▏"), width - 1),
                           width - 1, curses.color_pair(3) if color_on() else attr(("bold",)))
            screen.addnstr(height - 1, 0, qo.clip(say("view_ask_keys"), width - 1), width - 1, attr(("dim",)))
            screen.refresh()
            screen.timeout(heal.timeout(False) or 1000)
            try:
                ch = screen.get_wch()
            except curses.error:
                continue
            a, r, pre, kind, _ = pend
            if ch == curses.KEY_RESIZE:
                heal.resized(screen)
            elif ch in ("\x1b", "\x03"):
                back()
            elif kind == "key":
                if isinstance(ch, str) and ch in (a.get("keys") or ""):
                    if a.get("yes") and ch not in "yY":
                        back()      # n: nothing done
                    elif run(a, r, ch):
                        return 0
                elif ch not in (curses.KEY_RESIZE,):
                    back()          # any other key cancels a one-key question
            elif ch in ("\n", "\r", curses.KEY_ENTER):
                text = line.text.strip()
                if not text:
                    back()          # an empty answer cancels, as an empty name always has
                elif run(a, r, pre + text):
                    return 0
            else:
                line.key(ch)
            continue
        foot = msg or (ask_line(asking) if asking else legend() if show_legend
                       else shown[at].get("foot", "") if 0 <= at < len(shown) else "")
        screen.addnstr(height - 2, 0, qo.clip(foot, width - 1), width - 1, attr(("dim",)) if show_legend and not msg
                       else (curses.color_pair(3) if color_on() else 0))
        screen.addnstr(height - 1, 0, qo.clip(say("view_keys"), width - 1), width - 1, attr(("dim",)))
        screen.refresh()
        screen.timeout(min(heal.timeout(False) or 1000, fresh.wait_ms()))
        try:
            ch = screen.get_wch()
        except curses.error:
            continue
        msg = ""
        if asking:
            # the footer asks 「派到哪个仓库」: ←→ (↑↓ Tab) pick, ↵ sends, esc leaves it
            if ch in ("\x1b", "\x03"):
                asking = None
            elif ch in (curses.KEY_LEFT, curses.KEY_UP, curses.KEY_BTAB):
                asking["i"] = (asking["i"] - 1) % len(asking["repos"])
            elif ch in (curses.KEY_RIGHT, curses.KEY_DOWN, "\t"):
                asking["i"] = (asking["i"] + 1) % len(asking["repos"])
            elif ch in ("\n", "\r", curses.KEY_ENTER):
                repo, title = asking["repos"][asking["i"]], asking["title"]
                asking = None
                rc, msg = dispatch(screen, vid, client, title, repo)
                if rc == 0:
                    return 0
            elif ch == curses.KEY_RESIZE:
                heal.resized(screen)
            continue
        if ch in ("\x1b",) or ch == "\x03":
            return 0
        if ch == curses.KEY_RESIZE:
            heal.resized(screen)
            continue
        if ch in (curses.KEY_UP, "\x10"):
            sel = [i for i, e in enumerate(shown) if pickable(e) and i < at]
            at = sel[-1] if sel else at
            continue
        if ch in (curses.KEY_DOWN, "\x0e"):
            sel = [i for i, e in enumerate(shown) if pickable(e) and i > at]
            at = sel[0] if sel else at
            continue
        if ch == "\t":
            if 0 <= at < len(shown) and shown[at]["kind"] == "sess":
                mrow = act_row(fleet, shown[at])
                mitems = [(a["id"], label, a) for a, label in menu_of(mrow)]
                word = mrow.get("word") or ""
                mtitle = " · ".join(x for x in (mrow.get("text") or mrow.get("name") or "",
                                                mrow.get("machine") if mrow.get("far") else "", word) if x)
                mode, mat = "menu", 0
            continue
        if ch in ("\n", "\r", curses.KEY_ENTER):
            if not (0 <= at < len(shown)):
                continue
            e = shown[at]
            if e["kind"] == "sec":
                opened ^= {e["sec"]}
                shown = listing()
                continue
            if e["kind"] == "cmd":
                # a command row (issue #3180): its ACTIONS entry; 「新任务」 sends the words
                if e["act"] == "new":
                    title = query.strip()
                    if not title:
                        msg = say("view_new_empty")
                        continue
                    repo, have = repo_pick()
                    if not repo and len(have) >= 2:
                        asking = {"title": title, "repos": have, "i": 0}
                        continue
                    if not repo:
                        msg = say("view_new_norepo")
                        continue
                    rc, msg = dispatch(screen, vid, client, title, repo)
                    if rc == 0:
                        return 0
                    continue
                rc, msg, went = act_run(qo, vid, fleet, ACTION[e["act"]], e["row"], "", client)
                if went:
                    return 0
                continue
            target = e.get("target") or ""
            if not target:
                continue
            if e.get("gone"):
                # a reaped session (issue #3286): ↵ is its one action, 恢复
                if pick(ACTION["resume"], act_row(fleet, e)):
                    return 0
                continue
            msg = lost_msg(e) or ""
            if msg:
                continue
            rc = go(qo, vid, target, "popup", client, e)
            if rc == 0:
                return 0
            msg = say("view_far_fmt", e.get("machine") or "?") if rc == 3 else say("view_gone")
            continue
        if ch == "\x1c":
            # ⌃\ (issue #3183): a shell beside the lit session, on screen or not —
            # a new window of the 看台, in the directory its agent is in
            e = shown[at] if 0 <= at < len(shown) else {}
            if e.get("kind") != "sess" or not e.get("target"):
                continue
            rc = open_shell(qo, vid, client, e["target"], e)
            if rc == 0:
                return 0
            msg = say("view_gone") if rc == 3 else say("view_shell_failed_fmt", e.get("machine") or "?")
            continue
        if ch == "?" and not query:
            # an empty query: `?` is the legend, not a letter (with text it is one)
            show_legend = not show_legend
            continue
        if ch in (curses.KEY_BACKSPACE, "\x7f", "\b"):
            query = query[:-1]
        elif isinstance(ch, str) and ch.isprintable():
            query += ch
        else:
            continue
        show_legend = False
        lit = shown[at].get("target") if 0 <= at < len(shown) else None
        shown = listing()
        # typed words: the best session hit is lit; none hit — 「新任务」 is
        at = next((i for i, e in enumerate(shown) if e["kind"] == "sess"),
                  next((i for i, e in enumerate(shown) if e.get("cmd") == "new"),
                       next((i for i, e in enumerate(shown) if pickable(e)), 0)))
        if not query:
            at = next((i for i, e in enumerate(shown) if e.get("cmd") == "back"),
                      next((i for i, e in enumerate(shown) if e["kind"] == "sess" and e.get("target") in (lit, cur)), at))
        top = 0


# --- the entry --------------------------------------------------------------------------

def opt(argv, name):
    return argv[argv.index(name) + 1] if name in argv[:-1] else ""


def main(argv, qo):
    me = os.path.normpath(os.path.abspath(qo.__file__)) if getattr(qo, "__file__", None) else ""
    if argv[:1] == ["view-keys"]:
        # --socket <label>: a caller outside the server (attach --thin over ssh)
        if opt(argv, "--socket"):
            _SOCK[0] = opt(argv, "--socket")
            os.environ.pop("TMUX", None)
        return view_keys(me, "--if-stale" in argv)
    if argv[:1] == ["go"] and len(argv) >= 3:
        vid = view_id(argv[1])
        return go(qo, vid, argv[2], opt(argv, "--how") or "go", opt(argv, "--client")) if vid else 2
    vid = view_id(opt(argv, "--view"))
    if not vid:
        return 2
    client = opt(argv, "--client")
    if argv[:1] == ["do"] and len(argv) >= 2:
        return do(qo, argv[1], vid, client, opt(argv, "--target"))
    if argv[:1] == ["view-peers"]:
        if opt(argv, "--socket"):
            _SOCK[0] = opt(argv, "--socket")
            os.environ.pop("TMUX", None)
        return view_peers(vid)
    if argv[:1] == ["view-shell"] and len(argv) >= 5 and argv[1] in ("here", "far", "home"):
        rest = [a for i, a in enumerate(argv) if a != "--view" and argv[i - 1] != "--view"]
        return shell_pane(vid, *rest[1:5])
    if argv[:1] == ["view-order"]:
        order_save(vid, entries(vid))
        return 0
    if argv[:1] in (["view-menu"], ["view-act"]):
        flags = ("--view", "--client", "--text")
        rest = [x for i, x in enumerate(argv[1:], 1) if x not in flags + ("--yes",) and argv[i - 1] not in flags]
        if argv[0] == "view-menu":
            return cli_menu(vid, rest[0]) if rest else 2
        if len(rest) < 2:
            return 2
        return cli_act(qo, vid, rest[0], rest[1], opt(argv, "--text") if "--text" in argv[:-1] else None,
                       "--yes" in argv, client)
    if argv[:1] == ["view-panel"]:
        # the popup's lines with its command rows (issue #3180): kind · cmd · text
        q = " ".join(a for i, a in enumerate(argv[1:], 1) if a not in ("--view", "--client")
                     and argv[i - 1] not in ("--view", "--client"))
        for e in panel_rows(entries(vid), q, {"ended"}, current(vid)):
            print("\t".join((e["kind"], e.get("cmd") or e.get("target") or e.get("group") or "", e.get("text") or "")))
        return 0
    if argv[:1] == ["view-gone"]:
        # read the 已回收 list now and wait (the selftest, a person's evidence)
        return 0 if gone_read(view_fleet(vid), wait=True) else 1
    if argv[:1] == ["view-rows"]:
        rest = [a for i, a in enumerate(argv[1:], 1) if a not in ("--view", "--client")
                and argv[i - 1] not in ("--view", "--client")]
        gl = glyphs()
        for e in visible(entries(vid), " ".join(rest), {"ended"}):
            print("\t".join((e["kind"], e.get("target") or e.get("of") or e.get("sec") or e.get("group") or "",
                             e.get("word") or "", e.get("text") or "", e.get("right") or "", e.get("foot") or "",
                             gl.get(e.get("sym") or "", "") if e["kind"] == "sess" else "",
                             e.get("group") or "", " ".join(e.get("tags") or ()))))
        return 0
    os.environ.setdefault("ESCDELAY", "25")
    return curses.wrapper(popup, qo, vid, client)
