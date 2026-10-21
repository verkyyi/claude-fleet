#!/usr/bin/env python3
r"""fleet_view.py — the 看台's switcher, on the home machine (issue #3000, EPIC #2999 C2).

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
                                              you should do (#3179, #4225: 置顶 ·
                                              等你 · 在干活 · 等合并/等发版 · 刚落地 ·
                                              其他); 已结束 under them; ↵ goes there
    fleet-quickopen.py do next|prev|back|fwd --view <view>
                                              ⌘↓ ⌘↑ (the list's order) · ⌘[ ⌘] (history)
    fleet-quickopen.py do new|quit|shell|home --view <view> [--target <session>]
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

WORDS (#2752): no row says `merged` or `done:15m` — the reap policy is
「合并后关」 / 「空闲 2 小时关」, available in the row's actions;
ROWS — plan B (T486 v14, T493): every session line is the same columns, glyph(1)
· ID(8, bold: the window's own short code K3F9 — EPIC T497 C3/C11, id_apply; no
ID ⇒ blank, a hub task's T<n> only an alias) · Agent(7: Claude / Codex — the
ID's newest native segment, else opened, else a grey 未知) · short name (short_name: no envelope, issue prefix,
brackets or paths; cut at punctuation) · repo(13, its own, blank when none). A
state is ONE glyph (↻ running · ! needs · ✓ done · ✗ failed · ◌ exited, only
under 已结束 · ∙ idle · ? lost); only ! and ✗ are coloured — red,
bold — unless NO_COLOR / FLEET_COLOR=0; ASCII with FLEET_GLYPHS=ascii. A lost
row is grey; the selected one wears PAL_SEL behind (sel_color). Issue numbers,
PRs, machines and the other tags are off the row: the lit row's bottom line
(note_of; a broken configuration red) — an issue is still searched, exactly
(issue_hit, match_why). `?` on an empty query shows the legend. No session
is special (issues #3119, #4341): a session from any template is a row
like any other — no session is behind 「新任务」 below. All of it through
fleet-ui-lang.sh (`view_*`).

COMMANDS / PAGES (issue #4416; plan B, T486 v14 §2): the search line filters
sessions. Every second-level screen is a whole page in the list's place — its
object on top (the session line, or ⚡ 新任务), a rule, then one item a line with
the list's height, highlight, ↑↓ and ↵; no floating box anywhere. Escape steps
back a level (a question asked from the actions page returns to it) and from the
first restores the list's selection/search/scroll. The ⚡ page is the 「新会话」
box (T652, EPIC T651 C1): 仓库 ‹›, Agent ‹›, 开 — three items, nothing to type;
it opens on 开 with both chosen, so ↵ opens (bolt_argv → go_new, the one road:
under hub authority a repo's blank session is a record titled 「新会话」, renamed
by its first prompt). Tab / ↑↓ walk, ←→ change the lit value, ↵ on a value goes
to 开. Its defaults (T670, EPIC T651 C2) are fleet-quick-dispatch.py's one reader
(grid → defaults()): the repo of the session in view, else the last new
session's (不绑仓库 counts), else the only one; the agent that repo last opened
with, else the fleet's. Opening one records both (compose-state.json). ⌘N opens
the box itself, esc closes it. panel-drafts is read no more.
The footer contains keys, an optional glyph legend and transient feedback.
FLEET_PANEL_COMMANDS still controls new/quit/landed through panel_rows().

LANGUAGE (issue #3329, EPIC #3178 D7, L1–L3): the 「◐ 语言 / Language」 row sits
under ⚡, above ⏻, both scripts on it so a person who cannot read the one in use
still knows it; typing 语言 · lang · english · 中文 finds it (and lights it when no
session is hit). ↵ flips between 中文 and English, Tab adds 跟系统走 (the choice cleared) —
`fleet-config.py lang`, kept on the hub under the person and re-read here at
once; the popup redraws in it and says so on its footer for 3 s. Which language
is in use is fleet-ui-lang.sh's (the person's choice > the 看台's FLEET_VIEW_LANG >
Chinese), never decided here.

STALE (issue #3184, EPIC #3178 C6): 失联 is judged off ONE time, global/hub_ok —
the file the producer's `mac-a!` reads. A lost row is grey end to end and tagged
「? 失联 N 分钟」; hub_ok older than FLEET_HUB_SESSIONS_STALE (60 s) puts a red
banner on top naming the machines (banner()); ↵ on a lost row says 进不去 instead
of going (lost_msg()). An open popup reads its list again every
FLEET_VIEW_REFRESH (2 s, 0 = never) off the screen's thread (Refresh), the lit
row kept by its key — and each read runs hub_fresh, so a silent hub is retried.

TAB (issue #3181, EPIC #3178 C3; plan B, T493): the lit row's actions page —
进入 · 打开 PR #n (with a PR) · 改名… · 换成 Codex/Claude (alive; grey, unnumbered
and saying why when that agent cannot run here) · 回收… (PAGE_ACTIONS, page_of),
numbered from 1 as they appear; a reaped session's one item is 恢复. ↑↓ ↵ or a
digit pick, [ ] step to the previous / next session's page, Esc goes back. The
rest of ACTIONS (SIDEBAR_ACTIONS maps the old letters) stays for `view-act` and
the command line. A rename asks on its own page (↵ submit, Esc back to the
actions page), a reap y / n; then back on the list, read again.

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
that row, through the same fleet-row-remote.sh (FLEET_REMOTE_SAY=print: its
outcome line, the hub's refusal verbatim, comes back as the bottom line). Run off
the screen's thread, then one hub cache --refresh, so a reaped row leaves within
the next read. A lost row (`!`) sends nothing: 「<机器> 失联，做不了 · 正在重连」.
"""
import curses
import getpass
import hashlib
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

# a sibling, found beside this file however it was loaded (a selftest loads it by path)
if str(Path(__file__).absolute().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).absolute().parent))
import fleet_timing  # noqa: E402 — the panel's and the new session's clock (issue #3551)

US = "\x1f"
VIEW_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")
# The 看台's actions off dash-keymap.sh --panel switch: the verb each one runs.
# Only ⌘P is bound by default (T685); every other is bound only when the person
# names it (#3185) — and each has its row in ⌘P's panel (新会话 · 命令行 · 退出).
# ⌘N ⌘Q are C7's (issue #3004);
# ⌘N opens the 「新会话」 box, both values chosen (T670, EPIC T651 C2) — the panel's
# forward of `new`, for a chord the person named;
# zoom / fold stay caught by user-keys, bound to nothing (a 看台 has one pane a
# window, and no list to fold). ⌘T's 派一件事 popup has no entry since issue #3328:
# `dispatch` is the panel lit on its ⚡ row — the same send, one entry.
VIEW_ACTIONS = {"next": "do next", "prev": "do prev", "back": "do back", "fwd": "do fwd",
                "quickopen": "popup", "switcher": "popup",
                "new": "forward", "quit": "do quit", "dispatch": "forward", "home": "do home"}
PFX_KEY = "C-]"
NARROW = 100      # a client narrower than this (a phone) gets the switcher full-screen (#3006)
# ⌃\ (issue #3004; EPIC T651 C3: ⌘\'s fallback, the home shell): the terminal
# sends the byte itself; ⌃] \ is the same on a keyboard with no ⌃\.
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


def words_key():
    """What the language table's dump depends on (issue #3514): the table itself
    and every input fleet_ui_lang reads — FLEET_UI_LANG, the person's choice
    file, FLEET_VIEW_LANG (set or not), the locale. One file per answer."""
    table = Path(__file__).absolute().parent / "fleet-ui-lang.sh"
    person = os.environ.get("FLEET_UI_PERSON_FILE") or os.path.join(
        os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet"), "person-bundle.json")
    parts = []
    for f in (table, person):
        try:
            st = os.stat(f)
            parts.append("%s:%d:%d" % (f, st.st_mtime_ns, st.st_size))
        except OSError:
            parts.append("%s:-" % f)
    for k in ("FLEET_UI_LANG", "FLEET_VIEW_LANG", "LC_ALL", "LC_MESSAGES", "LC_CTYPE", "LANG"):
        parts.append("%s=%s" % (k, os.environ.get(k, "\1")))
    return hashlib.sha1("\0".join(parts).encode("utf-8", "replace")).hexdigest()[:16]


def say(key, *args):
    if not _WORDS:
        # The dump is a shell run (~70 ms, seconds on a throttled box) the popup paid
        # before its first frame on every ⌘P (issue #3514): kept per words_key().
        kept = dash_global() / ("view-words-" + words_key())
        try:
            raw = kept.read_text(encoding="utf-8").split("\0")
        except (OSError, ValueError):
            raw = None
        if not raw or len(raw) < 2:
            try:
                out = subprocess.run(["sh", str(Path(__file__).absolute().parent / "fleet-ui-lang.sh"), "dump", "view_", "reap_menu_"],
                                     capture_output=True, text=True, timeout=5).stdout
            except (OSError, subprocess.TimeoutExpired):
                out = ""
            raw = out.split("\0")
            if out:
                atomic_write(kept, out)
        _WORDS.update({k: v.replace("\1", "%s") for k, v in zip(raw[0::2], raw[1::2])})
        _WORDS.setdefault("_", "")
    text = _WORDS.get(key, key)
    try:
        return text % args if args else text
    except (TypeError, ValueError):
        return text


def tokens_short(n):
    """A token count short, as the hub page's fmtCompact prints it (issue #3377):
    zh 3.4 万 · 1.2 亿, en 34k · 1.2M · 2.1B; three significant digits, never
    an exponent. The style is the language table's (view_tok_style)."""
    n = int(n)

    def trim0(t):
        return t.rstrip("0").rstrip(".") if "." in t else t

    def sig3(v):
        return str(int(round(v))) if v >= 100 else "%.3g" % v   # v ≥ 1 here: never an exponent

    if say("view_tok_style") == "zh":
        if n >= 10 ** 8:
            return sig3(n / 1e8) + " 亿"
        if n >= 10 ** 4:
            return sig3(n / 1e4) + " 万"
        return str(n)
    if n >= 10 ** 9:
        return trim0("%.2f" % (n / 1e9)) + "B"
    if n >= 10 ** 6:
        return trim0("%.1f" % (n / 1e6)) + "M"
    if n >= 10 ** 3:
        return trim0("%.1f" % (n / 1e3)) + "k"
    return str(n)


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
    if kind == "idle":
        return say("view_reap_idle_for", span(arg or "2h"))
    if kind == "loop-end":
        return say("view_reap_loop_end")
    if kind == "keep":
        return say("view_reap_keep")
    if kind == "at":
        return say("view_reap_at", arg)
    return ""


STATES = ("needs", "failed", "working", "looping", "idle", "done", "exited", "landed", "parked")


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


def hub_view_request(fleet):
    """Only a real list read renews the 30s viewing window (#4357).

    Opening a sleeping list broadcasts on the shared channel. Continuing reads
    renew its timestamp without waking every other renderer on every frame.
    """
    g = dash_global()
    if not fleet or not (g / ('remote_' + fleet)).is_file():
        return
    request = g / 'hubsess.view'
    try:
        age = time.time() - request.stat().st_mtime
    except OSError:
        age = 31
    try:
        request.touch()
    except OSError:
        return
    if age < 0 or age > 5:
        tm('wait-for', '-S', 'fleet-state-changed')


def hub_fresh(fleet):
    """The other machines' rows are only as new as global/remote_<fleet>, which
    fleet-hub-sessions.sh's loop keeps — a loop the collector's tick (re)starts. A
    collector that stopped (mac-a's node supervisor wedged, 2026-10-10) froze that
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


def rows_cache(fleet):
    # a producer seam (FLEET_VIEW_ROWS_CMD, the selftests') keeps its own copy
    seam = os.environ.get("FLEET_VIEW_ROWS_CMD")
    tag = "-" + hashlib.sha1(seam.encode("utf-8", "replace")).hexdigest()[:10] if seam else ""
    return dash_global() / ("view-rows-" + re.sub(r"[^A-Za-z0-9_.@-]", "_", fleet) + tag)


def atomic_write(path, text):
    import tempfile
    tmp = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        # Rows may carry a private native proof (#4504). Keep every cached
        # copy private too, including replacements of an older 0644 cache.
        fd, tmp = tempfile.mkstemp(prefix=".%s." % path.name, dir=str(path.parent))
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(tmp, path)
    except OSError:
        pass
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)


def produce(fleet, kept=False):
    """tmux-dashboard-rows.sh --rows, every subtree open: the rows the old list
    drew, the same producer (it reads remote_<sess>, so other machines come too).
    entries() runs hub_fresh before it, unless told not to (#3311).
    Every read is kept (view-rows-<fleet>); kept=True — the popup's first frame —
    answers that copy when it is younger than FLEET_VIEW_ROWS_KEEP (600 s) instead
    of running the producer (issue #3514: 150-350 ms, seconds on a throttled box,
    before anything was drawn); the Refresh thread's first read, at once, replaces
    it. FLEET_VIEW_ROWS_KEEP=0 always runs it — the default under a producer seam
    (FLEET_VIEW_ROWS_CMD), whose rows a selftest changes between two popups."""
    path = rows_cache(fleet)
    if os.environ.get("FLEET_VIEW_ROWS_CMD") and "FLEET_VIEW_ROWS_KEEP" not in os.environ:
        kept = False
    if kept:
        try:
            if 0 <= time.time() - path.stat().st_mtime < fenv("FLEET_VIEW_ROWS_KEEP", 600):
                text = path.read_text(encoding="utf-8", errors="replace")
                if text:
                    return text
        except OSError:
            pass
    # FLEET_ROWS_COLS=1: the plan-B columns' fields 22-24 (ID · agent · repo, T493)
    env = dict(os.environ, FLEET_SESSION=fleet, FLEET_ROWS_UNFOLD="1", FLEET_ROWS_COLS="1")
    seam = os.environ.get("FLEET_VIEW_ROWS_CMD")
    argv = ["sh", "-c", seam] if seam else ["bash", str(Path(__file__).absolute().parent / "tmux-dashboard-rows.sh"), "--rows"]
    try:
        # a cell cut mid-character (bash slices bytes with no UTF-8 locale) is one
        # row's blemish, never the whole list's loss (issue #3444)
        out = subprocess.run(argv, env=env, capture_output=True, encoding="utf-8", errors="replace",
                             timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if out:
        atomic_write(path, out)
    return out


def windows(fleet):
    """{window id: (fleet_id, role, activity)} of the fleet session."""
    rc, out = tm("list-windows", "-t", "=" + fleet, "-F", "#{window_id}|#{@fleet_id}|#{@fleet_role}|#{window_activity}")
    res = {}
    for line in out.splitlines() if rc == 0 else []:
        w, fid, role, act = (line.split("|") + ["", "", ""])[:4]
        res[w] = (fid, role, int(act) if act.isdigit() else 0)
    return res


# A rename of another machine's row (issue #3317) reaches this list only when that
# machine's next inventory has gone through the hub — up to a heartbeat. Until
# then the popup shows the name it just sent: `$G/view-names.<fleet>`, {target:
# [name, ts]}, written by the rename, read by entries(), each entry dropped once
# the hub's row says it or past FLEET_VIEW_NAME_HOLD_SECS (180 s).
def names_file(fleet):
    return dash_global() / ("view-names." + (fleet or "-"))


def names_raw(fleet):
    try:
        d = json.loads(names_file(fleet).read_text())
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def names_live(d, now=None):
    now = time.time() if now is None else now
    hold = fenv("FLEET_VIEW_NAME_HOLD_SECS", 180)
    return {k: v for k, v in d.items() if isinstance(v, list) and len(v) == 2
            and isinstance(v[1], (int, float)) and now - v[1] < hold}


def names_save(fleet, d):
    p = names_file(fleet)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        if not d:
            if p.exists():
                p.unlink()
            return
        tmp = p.with_name(p.name + ".%d" % os.getpid())
        tmp.write_text(json.dumps(d, ensure_ascii=False))
        os.replace(str(tmp), str(p))
    except OSError:
        pass


def name_hold(fleet, target, name):
    """A rename of a far row went out: show `name` on it until the hub agrees."""
    d = names_live(names_raw(fleet))
    d[target] = [name, time.time()]
    names_save(fleet, d)


# What a row is, in one cell (issue #3179, EPIC #3178 C1): a shape that reads
# without colour (16 colours, black and white, a reader who cannot tell red from
# green), every one an East-Asian-narrow character so it is one cell in a CJK
# terminal too, and in all seven of Termius iOS's fonts (✓ borrows a system font
# in UbuntuMono). FLEET_GLYPHS=ascii swaps in plain ASCII.
# Plan B (T486 v14, T493): seven states and lost, each a one-cell character with
# no emoji form — ↻ running · ! waiting on you · ✓ done · ✗ failed · ◌ exited (the
# agent gone, its window up: folded into 已收起, T688) · ∙ idle · ? lost (☾ asleep
# went with hibernation, T548).
GLYPHS = {"needs": "!", "fail": "✗", "work": "↻", "done": "✓", "exited": "◌", "idle": "∙", "lost": "?"}
GLYPHS_ASCII = {"needs": "!", "fail": "x", "work": ">", "done": "+", "exited": "o", "idle": ".", "lost": "?"}
# the 16-colour palette's numbers, present in every theme (the top line colours
# every glyph by them). The ⌘P rows colour only the two a person has to act on —
# ! and ✗, red and bold (ROW_RED); every other glyph keeps the row's colour.
GLYPH_COLORS = {"needs": 1, "fail": 1, "work": 2, "done": 4, "exited": 8, "idle": 8, "lost": 3}
ROW_RED = ("needs", "fail")
# A message's class (T701, bin/fleet_notice.py — the one book): the same single-
# cell shapes the rows and fleet-alerts.sh's ✖ ▲ use, one a class, its colour the
# class's: ✦ the count · ! asking you · ✖ error · ▲ warning · ✓ done (green) ·
# ✓ a result nobody took (yellow) · ∙ a note. FLEET_GLYPHS=ascii: letters.
MSG_GLYPHS = {"inbox": "✦", "ask": "!", "error": "✖", "warn": "▲", "done": "✓", "orphan": "✓", "info": "∙"}
MSG_GLYPHS_ASCII = {"inbox": "*", "ask": "!", "error": "x", "warn": "^", "done": "+", "orphan": "+", "info": "."}
MSG_COLORS = {"inbox": 3, "ask": 1, "error": 1, "warn": 3, "done": 2, "orphan": 3, "info": 8}
LEGEND = ("work", "needs", "done", "fail", "exited", "idle", "lost")
# The panel's groups (回收 D, T681): 置顶 · 等你 · 在干活 · 排队中, then 已收起 — the
# closed sessions, a folded section (sec "gone") under them; an exited agent whose
# window is still up sits there too (group_of's "shut", T688).
GROUPS = ("pin", "ask", "work", "queue")
MERGED_PR = ("merged", "live", "deploy…", "deploy✗")


def glyphs():
    return GLYPHS_ASCII if os.environ.get("FLEET_GLYPHS") == "ascii" else GLYPHS


def msg_glyphs():
    return MSG_GLYPHS_ASCII if os.environ.get("FLEET_GLYPHS") == "ascii" else MSG_GLYPHS


def color_on():
    """NO_COLOR (any value, no-color.org) or FLEET_COLOR=0 leaves the shapes alone."""
    return not os.environ.get("NO_COLOR") and os.environ.get("FLEET_COLOR", "1") != "0"


def sym_of(state, lost=False):
    """A row's glyph class: lost wins (whatever it last said is no longer known)."""
    if lost:
        return "lost"
    if state == "needs":
        return "needs"
    if state in ("failed", "error"):
        return "fail"
    if state == "exited":
        return "exited"
    if state in ("working", "looping"):
        return "work"
    if state in ("done", "landed"):
        return "done"
    return "idle"


def group_of(state, pinned, landed, ended, asked=False, stage=""):
    """Whether the row needs you (回收 D, T681; issues #3179, #4225; T688): 置顶 ·
    等你 — only what waits on YOUR hand: asking (needs, the `ask` tool's sticky
    blocked included — the window side of the record's 「问过你」, cleared by the
    answer; a plan page waiting on your nod asks the same way), failed, an
    unanswered ⛔ ask on its issue whatever the state — · 在干活 · 排队中 (waiting
    on something that is not you: an idle session with nothing asked — tagged
    空闲 —, done with its PR on its way to merge / ship, or done and about to be
    folded away — the producer's 已结束 mark included; unknown) · "shut": an exited
    agent whose window is still up, folded straight into 已收起 (↵ its recovery
    page: resume · new · close). `landed` / `stage` no longer split a group."""
    if pinned:
        return "pin"
    if state in ("needs", "failed", "error") or asked:
        return "ask"
    if state in ("working", "looping"):
        return "work"
    if state == "exited":
        return "shut"
    return "queue"


# A PR's step on its way out (issue #4225), off the producer's PR cell (field 11:
# `#75…` `#75✗` `#75✓↑` · `merged` · `live` · `deploy…` · `deploy✗` · `closed` · `—`)
# and its field 20 (`unknown`: merged, the deploy probe has not seen it live).
# "" = nothing to wait for: no PR, closed, live, or merged with no probe.
def stage_of(pr, dep=""):
    pr = (pr or "").strip()
    if pr == "deploy…":
        return "deploying"
    if pr == "deploy✗":
        return "deploy_red"
    if pr == "merged":
        return "train" if dep == "unknown" else ""
    if not pr or pr in ("—", "·", "-", "closed", "live"):
        return ""
    ci = re.sub(r"^#\d+", "", pr)
    if ci.startswith("✗") or ci == "✓!":
        return "red"
    if ci.startswith("✓"):
        return "green"
    return "checking"


def repo_slug(repo):
    """fleet_slug(fleet_norm_repo(repo)) — the cache dirs' and the ask book's key."""
    return re.sub(r"[^A-Za-z0-9._-]", "", (repo or "").strip().rstrip("/").replace("/", "-"))


def fleet_only_slug(fleet):
    """The slug of the fleet's one hosted repo (fleets/<fleet>/repos/<slug>.conf),
    "" unless it hosts exactly one — a one-repo list draws no repo heading."""
    try:
        confs = [p.stem for p in (conf_dir() / "fleets" / fleet / "repos").glob("*.conf")]
    except OSError:
        return ""
    return confs[0] if len(confs) == 1 else ""


ISSUES_LISTED = 300     # the collector's open-issue list holds this many (tmux-dash-collect.sh --limit)


def open_ask(slug, issue, lists=None):
    """The first line of the ⛔ ask still open on <slug>#<issue> (issue #4225), ""
    when none: the issue bridge's book ($G/asks/<slug>#<N>, written on the ⛔
    comment, removed by the answer — the bridge left with #4899, so no new one). An issue
    no longer on the collector's open-issue list (fleets/<slug>/issues, when it
    was read) is closed, so its ask is too. Local files only — the panel reads
    this on every pop and never asks GitHub. `lists`: a {slug: set} memo."""
    num = (issue or "").lstrip("#")
    if not slug or not num.isdigit():
        return ""
    try:
        line = (dash_global() / "asks" / ("%s#%s" % (slug, num))).read_text(
            encoding="utf-8", errors="replace").split("\n", 1)[0]
    except OSError:
        return ""
    lists = {} if lists is None else lists
    if slug not in lists:
        try:
            text = (dash_global().parent / "fleets" / slug / "issues").read_text(encoding="utf-8", errors="replace")
            lists[slug] = {ln.split("\t")[1] for ln in text.splitlines() if ln.count("\t") >= 1}
        except OSError:
            lists[slug] = None
    have = lists[slug]
    if have is not None and "#" + num not in have:
        # the list is the newest ISSUES_LISTED open ones: missing from a full one
        # says closed only for a number newer than its oldest
        nums = [int(n[1:]) for n in have if n[1:].isdigit()]
        if len(have) < ISSUES_LISTED or (nums and int(num) > min(nums)):
            return ""
    return one_line(line.split("\t", 2)[2] if line.count("\t") >= 2 else "") or say("view_ask_open")


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
    # FLEET_HISTORY_EPOCH: each row also carries its close time (issue #3731)
    env = dict(os.environ, FLEET_SESSION=fleet, FZF_COLUMNS="240", FLEET_HISTORY_EPOCH="1")
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
    """fleet-history.sh rows → (target, glyph, label, name, title, act, pr, when),
    one per `landed:…` target, the first (newest) of a key the ledger lists twice.
    Its fixed columns (cmd_rows): glyph · issue (5) · tree · window (26), then the
    title in its own colour, and the 21 right cells act (8) · PR (7) · dep (4);
    `when` is the close time a FLEET_HISTORY_EPOCH read appends (issue #3731), else
    None."""
    out, seen = [], set()
    for line in (text or "").split("\n"):
        parts = line.split(US, 2)
        if len(parts) < 3 or not parts[0].startswith("landed:") or parts[0] in seen:
            continue
        seen.add(parts[0])
        when = None
        if US in parts[2]:
            parts[2], _, ep = parts[2].rpartition(US)
            when = int(ep) if ep.strip().isdigit() else None
        plain = ANSI.sub("", parts[2]).rstrip("\n")
        tx = [t.strip() for t in GONE_TX.findall(parts[2])]
        name = tx[0] if tx else plain[11:37].strip()
        title = tx[1] if len(tx) > 1 else ""
        tail = plain[-21:] if len(plain) >= 59 else ""
        out.append((parts[0], plain[:1], plain[2:7].strip(), name, title, tail[:8].strip(), tail[9:16].strip(), when))
    return out


RELTIME = {"min": 60, "hour": 3600, "day": 86400, "wk": 604800, "mo": 2592000, "yr": 31536000}


def gone_age(when, act, now):
    """How long ago a closed session closed: its epoch, else the history row's own
    words (fleet_reltime: `now` · `3 mins` · `1 day` …), read as the least it can
    mean — a copy written before the epoch rode along still splits. None: unknown."""
    if when:
        return max(0, now - when)
    m = re.match(r"^(now|(\d+) (min|hour|day|wk|mo|yr)s?)$", (act or "").strip())
    if not m:
        return None
    return 0 if m.group(1) == "now" else int(m.group(2)) * RELTIME[m.group(3)]


def closed_secs():
    """FLEET_VIEW_CLOSED_HOURS (the environment, else fleet.conf's line; default 168,
    7 days — 回收 D): how far back the 已收起 group lists (issue #3731) — older ones
    only counted."""
    try:
        return max(0.0, float(conf_word("FLEET_VIEW_CLOSED_HOURS") or 168)) * 3600
    except ValueError:
        return 168 * 3600.0


# A session's short name (plan B, T486 v14 §1): what it is about, never its
# envelope, issue prefix, brackets or paths.
ENVELOPE_RE = re.compile(r'^\s*<cross-session-message\b([^>]*)(>|$)', re.S)
NAMED_RE = re.compile(r'^(T\d+)\s+(?:(?:Claude|Codex)\s*·\s*)?')
ISSUE_HEAD_RE = re.compile(r'^(?:[修查做改加]\s*)?#\d+\s*[：:]\s*')
BRACKET_RE = re.compile(r'\s*(?:（[^（）]*）|\([^()]*\)|【[^【】]*】|\[[^\[\]]*\])')
PATH_RE = re.compile(r'(?<!\S)(?:\S*:/|~/|\.{0,2}/)\S*|(?<!\S)[^\s/]+(?:/[^\s/]+){2,}/?|(?<!\S)[^\s/]+/[^\s/]*\.\w+(?!\S)')
EDGE = " \t·:：,，;；、-—…"


def short_name(text):
    """(the short name, the `T<n>` a `T<n> Claude · …` name carried): a
    cross-session message is 「来自 X：its words」 (its envelope is no name), the
    orchestrator's `T<n> <Agent> · ` / `T<n> ` prefix (the ID and Agent columns
    say it), a
    leading 「修/查/做 #N：」, brackets and paths go. '' when nothing is left."""
    text = " ".join((text or "").split())
    m = ENVELOPE_RE.match(text)
    if m:
        who = re.search(r'from-name="([^"]*)"?', m.group(1))
        body = text[m.end():] if m.group(2) == ">" else ""
        body = short_name(body.replace("</cross-session-message>", ""))[0]
        if not body:
            return "", ""
        return say("view_from_fmt", (who.group(1) if who else "").strip() or "?", body), ""
    tid = ""
    m = NAMED_RE.match(text)
    if m:
        tid, text = m.group(1), text[m.end():]
    text = ISSUE_HEAD_RE.sub("", text)
    bare = BRACKET_RE.sub("", text)
    text = bare if bare.strip(EDGE) else text
    bare = PATH_RE.sub("", text)
    text = bare if bare.strip(EDGE) else text
    return " ".join(text.split()).strip(EDGE), tid


def row_cols(e, tid, agent, title, name):
    """Fill a session line's plan-B columns: `id` (its hub task T<n> — id_apply
    turns it into an alias and puts the window's short code there), `agent` ('' ⇒ 未知) and its short
    `text` — the title cell (a name given, the issue's title, the first sentence)
    else the window name, the first that leaves a name."""
    tid = (tid or "").strip()
    found = ""
    for cand in (title, name):
        short, t = short_name(cand)
        found = found or t
        if short:
            e["text"] = short
            break
    e["id"] = tid if re.fullmatch(r"T\d+", tid) else found
    e["agent"] = agent.strip() if (agent or "").strip() in AGENTS else ""


# --- a window's ID (EPIC T497 C3, design page §8) --------------------------------
# The ID column is the window's own short code `K3F9` (bin/fleet_id.py: its
# @fleet_id, the ledger's `short`, else the shortest prefix this login knows no
# other ID to share) — never a hub task's T<n>, never a `T?`, never the issue or
# a predecessor. A row's ledger ($FLEET_CONF_DIR/ids/<ID>.ndjson) also gives its
# Agent (the newest native segment's, else the one it was opened with, else 未知),
# its latest result (S2: the newest one wins), its closing (no result ⇒ 已退出,
# S7), the issues it is linked to (searched, never drawn) and, on the actions
# page, its segments, aliases and whether the hub has it. Two live rows on the
# same native segment are a conflict (S9): both red 「等你」, the reason on the
# page. A ledger that cannot be read changes nothing: the row is drawn as before.
_ID_CACHE = {}
RESULT_STATE = {"failed": "failed", "error": "failed", "merged": "done", "succeeded": "done", "done": "done",
                "blocked": "needs"}
ISSUE_REF_RE = re.compile(r"(?:^|[^\w/#])(?:[\w.-]+/[\w.-]+)?#(\d+)\b")


def fleet_id_mod():
    """bin/fleet_id.py, loaded once (None when it cannot be)."""
    if "mod" not in _ID_CACHE:
        try:
            import fleet_id as mod   # noqa: E402 — the ledger's one reader (C1)
        except Exception:
            mod = None
        _ID_CACHE["mod"] = mod
    return _ID_CACHE["mod"]


def id_record(fid):
    """`fid`'s one record (fleet_id.record: this machine's ledger filled from the ID
    cache, else the cache's — another machine's ID, EPIC T644 C7), kept until either
    file changes; None when neither has it — then the ID is queued for id_cache_kick
    (a background pull) and the row shows its placeholder until the next frame."""
    fi = fleet_id_mod()
    if fi is None or not fi.is_fid(fid):
        return None
    stamp = []
    incache = fid in id_cache_set()
    for path in (fi.ledger_path(fid), fi.cache_path(fid) if incache else ""):
        try:
            st = os.stat(path)
            stamp.append((st.st_mtime_ns, st.st_size))
        except OSError:
            stamp.append(None)
    stamp = tuple(stamp)
    if stamp == (None, None):
        _ID_CACHE.setdefault("ids_want", set()).add(fid)
        return None
    key = "rec:" + fid
    hit = _ID_CACHE.get(key)
    if hit and hit[0] == stamp:
        return hit[1]
    try:
        rec = fi.record(fid, cached_here=stamp[1] is not None)
    except Exception:
        return None
    _ID_CACHE[key] = (stamp, rec)
    return rec


def id_cache_set():
    """The IDs the ID cache holds — its directory listed once per change (its
    mtime), so a row whose ID is not there costs no stat of a missing file."""
    fi = fleet_id_mod()
    d = fi.cache_dir()
    try:
        m = os.stat(d).st_mtime_ns
    except OSError:
        return frozenset()
    hit = _ID_CACHE.get("cache_set")
    if not hit or hit[0] != m:
        hit = _ID_CACHE["cache_set"] = (m, frozenset(fi.cache_ids()))
    return hit[1]


def far_fid(target):
    """Another machine's row → its ID: the hub's pair (wid_ids, written by
    fleet-hub-sessions.sh: a row is keyed `<fleet UUID>/<key>`, its ID is the
    worker's identity), else the worker_id's own tail when it is one (EPIC T644 C7)."""
    p = dash_global() / "wid_ids"
    try:
        st = p.stat()
        stamp = (st.st_mtime_ns, st.st_size)
    except OSError:
        stamp = None
    hit = _ID_CACHE.get("wid_ids")
    if not hit or hit[0] != stamp:
        pairs = {}
        if stamp is not None:
            try:
                for line in p.read_text(encoding="utf-8").splitlines():
                    w, _, fid = line.partition("\t")
                    if w and fid:
                        pairs[w] = fid.strip()
            except OSError:
                pass
        hit = _ID_CACHE["wid_ids"] = (stamp, pairs)
    return hit[1].get(target) or target.rpartition("/")[2]


def id_cache_kick():
    """After a frame: the IDs it showed and had no record of, pulled in the
    background (fleet_id.pull_later — single-flight); the next frame draws them."""
    want = _ID_CACHE.pop("ids_want", set())
    fi = fleet_id_mod()
    if want and fi is not None:
        try:
            fi.pull_later(sorted(want))
        except Exception:
            pass


def id_known(extra=()):
    fi = fleet_id_mod()
    try:
        return fi.known_ids(extra) if fi else set()
    except Exception:
        return set()


def id_short_fast(fid, known):
    """fleet_id.short_for over a frame's `known`, each ID encoded once per frame and
    its nearest neighbours found by bisection (T593: short_for re-encodes every
    known ID for every row — rows × IDs per frame)."""
    import bisect
    fi = fleet_id_mod()
    key = hash(frozenset(known))
    hit = _ID_CACHE.get("codes")
    if not hit or hit[0] != key:
        codes = sorted(fi.encode(k) for k in known if fi.is_fid(k))
        hit = _ID_CACHE["codes"] = (key, codes)
    codes, me = hit[1], fi.encode(fid)
    i = bisect.bisect_left(codes, me)
    lcp = 0
    for o in (codes[i - 1] if i > 0 else "", codes[i + 1] if i + 1 < len(codes) and codes[i] == me else
              (codes[i] if i < len(codes) and codes[i] != me else "")):
        n = 0
        while n < min(len(o), 26) and o[n] == me[n]:
            n += 1
        lcp = max(lcp, n)
    return me[:min(26, max(fi.SHORT_MIN, lcp + 1))]


def id_short(fid, rec, known):
    fi = fleet_id_mod()
    if fi is None or not fi.is_fid(fid):
        return ""
    have = ((rec or {}).get("opened") or {}).get("short") or ""
    try:
        mine = id_short_fast(fid, known)
    except Exception:
        mine = ""
    # the longer one: the hub may have lengthened it (S12), a newer ID may share it now
    return have if len(have) >= len(mine) else mine


def id_issues(rec):
    """The issue numbers a ledger links (§3.5): opened's issue / ticket_ref /
    `issue-<N>` key, results' issues, and every #N in the words it was opened with."""
    out = set()
    o = (rec or {}).get("opened") or {}
    for k in ("issue", "ticket_ref"):
        m = re.search(r"(\d+)$", str(o.get(k) or ""))
        if m:
            out.add(m.group(1))
    m = re.fullmatch(r"issue-(\d+)", str(o.get("key") or ""))
    if m:
        out.add(m.group(1))
    for r in (rec or {}).get("results") or ():
        for ref in r.get("issues") or ():
            m = re.search(r"#?(\d+)$", str(ref))
            if m:
                out.add(m.group(1))
    for k in ("title", "body", "words"):
        out.update(ISSUE_REF_RE.findall(str(o.get(k) or "")))
    return out


def id_hub(fid):
    """'' registered · 'unhubbed' never acknowledged · 'refused' (S13)."""
    fi = fleet_id_mod()
    if fi is None:
        return ""
    base = os.path.join(fi.hub_dir(), fid)
    if os.path.exists(base + ".refused"):
        return "refused"
    try:
        with open(base + ".seq", encoding="utf-8") as fh:
            seq = fh.read().split()
        return "" if seq and seq[0].isdigit() and int(seq[0]) > 0 else "unhubbed"
    except OSError:
        return "unhubbed"


EPIC_MARK_RE = re.compile(r"<!--\s*fleet:epic\b([^>]*)-->")   # fleet-epic-tick.py's MARK
SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def task_cache_file():
    return dash_global() / "view-tasks.json"


def task_cache():
    """The hub task records' panel words on disk, {T<n>: [read at, agent, repo,
    outcome]} (outcome since EPIC T644 C4; an older 3-long entry reads as open) —
    one file read per change (mtime), never a hub call (T593: a popup is a new
    process each time, so an in-process cache bought nothing and every ⌘P waited
    on the hub)."""
    p = task_cache_file()
    try:
        st = p.stat()
    except OSError:
        return {}
    hit = _ID_CACHE.get("tasks")
    if hit and hit[0] == (st.st_mtime_ns, st.st_size):
        return hit[1]
    try:
        got = json.loads(p.read_text())
        got = got if isinstance(got, dict) else {}
    except (OSError, ValueError):
        got = {}
    _ID_CACHE["tasks"] = ((st.st_mtime_ns, st.st_size), got)
    return got


def hub_task(task):
    """What the panel knows of a hub task record — {agent: actual_agent, repo: its
    repo, else the EPIC charter marker's `repo=` in its words (T593), outcome: its
    end (succeeded / failed / cancelled / refused, '' while open — C4)}, off
    task_cache only. A task it lacks, or read longer ago than
    FLEET_VIEW_TASK_AGENT_SECS (300 s), is queued for task_cache_kick: a detached
    read fills it for the next frame."""
    if not re.match(r"^T[1-9][0-9]*$", task or ""):
        return {}
    hit = task_cache().get(task)
    if not (isinstance(hit, list) and len(hit) >= 3 and time.time() - (hit[0] or 0) < fenv("FLEET_VIEW_TASK_AGENT_SECS", 300)):
        _ID_CACHE.setdefault("tasks_want", set()).add(task)
    if not isinstance(hit, list) or len(hit) < 3:
        return {}
    return {"agent": hit[1] if hit[1] in AGENTS else "", "repo": hit[2] if SLUG_RE.match(hit[2] or "") else "",
            "outcome": hit[3] if len(hit) > 3 and hit[3] in TASK_ENDS else ""}


# A task record's end (fleet_task_control.TERMINAL): a row whose record says one is
# done (排队中) whatever its window still runs (EPIC T644 C4, the operator's 2026-10-20 word —
# a Codex loop left running after the merge kept a closed task 在干活).
TASK_ENDS = ("succeeded", "failed", "cancelled", "refused")


def task_ended(e):
    """The row's hub task record has ended (off task_cache — never a hub call)."""
    o = (id_record(e.get("fid") or "") or {}).get("opened") or {}
    return bool(hub_task(e.get("task") or o.get("task") or "").get("outcome"))


def hub_task_agent(task):
    """The hub task record's actual_agent — the Agent column's last fallback (EPIC
    T497 C17)."""
    return hub_task(task).get("agent", "")


def task_read(task):
    """One record off the hub → [now, agent, repo, outcome] (None unread). `fleet-task-record.sh
    get`, bounded by FLEET_VIEW_PR_TIMEOUT; FLEET_VIEW_TASK_GET (a command, the T<n>
    appended) is the selftest's seam. Only task_cache_fill calls it — never a frame."""
    secs = fenv("FLEET_VIEW_PR_TIMEOUT", 3)
    try:
        seam = os.environ.get("FLEET_VIEW_TASK_GET", "")
        p = subprocess.run(seam.split() + [task] if seam else sh("fleet-task-record.sh", "get", task),
                           capture_output=True, text=True,
                           timeout=secs + 1, env=dict(os.environ, FLEET_HUB_TIMEOUT=str(secs)),
                           stdin=subprocess.DEVNULL)
        rec = json.loads(p.stdout) if p.returncode == 0 else None
        if not isinstance(rec, dict):
            return None
        t = rec.get("task") or rec
        agent = str(t.get("actual_agent") or "")
        repo = str(t.get("repo") or "")
        if not SLUG_RE.match(repo):
            words = str(t.get("body") or "")
            try:
                pl = t.get("request_payload") or ""
                words += "\n" + str((json.loads(pl) if isinstance(pl, str) and pl else pl or {}).get("body") or "")
            except (ValueError, AttributeError):
                pass
            m = EPIC_MARK_RE.search(words)
            repo = (re.search(r"\brepo=(\S+)", m.group(1)) or [None, ""])[1] if m else ""
        outcome = str(t.get("outcome") or "")
        return [time.time(), agent if agent in AGENTS else "", repo if SLUG_RE.match(repo) else "",
                outcome if outcome in TASK_ENDS else ""]
    except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError, TypeError):
        return None


def task_cache_fill(tasks):
    """Read `tasks` side by side and merge them into task_cache's file (the detached
    filler; the selftest calls it directly). An unread one keeps its old words."""
    import threading
    tasks = sorted({t for t in tasks if re.match(r"^T[1-9][0-9]*$", t or "")})[:32]
    got = {}
    def one(t):
        got[t] = task_read(t)
    th = [threading.Thread(target=one, args=(t,), daemon=True) for t in tasks]
    for t in th:
        t.start()
    for t in th:
        t.join(fenv("FLEET_VIEW_PR_TIMEOUT", 3) + 2)
    p = task_cache_file()
    try:
        cur = json.loads(p.read_text())
        cur = cur if isinstance(cur, dict) else {}
    except (OSError, ValueError):
        cur = {}
    for t, v in got.items():
        if v:
            cur[t] = v
        elif t in cur and isinstance(cur[t], list) and len(cur[t]) >= 3:
            cur[t][0] = time.time()       # unread: tried again after the TTL, not every frame
        else:
            cur[t] = [time.time(), "", "", ""]
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = Path(str(p) + ".%d" % os.getpid())
        tmp.write_text(json.dumps(cur, ensure_ascii=False))
        os.replace(str(tmp), str(p))
    except OSError:
        pass


def task_cache_spawn(tasks):
    """Start task_cache_fill detached, single-flight (a `.lock` dir; one older than
    two minutes is a dead filler's) — the frame never waits for it."""
    lock = Path(str(task_cache_file()) + ".lock")
    try:
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.mkdir()
    except FileExistsError:
        try:
            if time.time() - lock.stat().st_mtime < 120:
                return
            os.utime(str(lock))
        except OSError:
            return
    except OSError:
        return
    code = ("import sys; sys.path.insert(0, sys.argv[1]); import fleet_view as fv, os\n"
            "try: fv.task_cache_fill(sys.argv[3:])\nfinally: os.rmdir(sys.argv[2])")
    try:
        subprocess.Popen([sys.executable, "-c", code, str(Path(__file__).absolute().parent), str(lock)] + sorted(tasks),
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError:
        try:
            lock.rmdir()
        except OSError:
            pass


def task_cache_kick():
    """After a frame: the records it wanted and lacked, read in the background."""
    want = _ID_CACHE.pop("tasks_want", set())
    if want:
        task_cache_spawn(want)


def id_repo_ref(rec, task="", depth=0):
    """Where a row with no window @repo finds its repo (T593): (repo, '') when its
    ledger's opened names one, else ('', the hub task whose record does — an EPIC
    driver's carries it in the charter marker's `repo=`); a ledger with no task of
    its own asks the one it was continued from (opened.prev, a relay). ('', '') —
    truly none (an orchestrator, a no-repo task)."""
    o = (rec or {}).get("opened") or {}
    if SLUG_RE.match(o.get("repo") or ""):
        return o["repo"], ""
    task = task or o.get("task") or ""
    if task:
        return "", task
    prev = o.get("prev") or ""
    if depth < 4 and prev:
        return id_repo_ref(id_record(prev), "", depth + 1)
    return "", ""


def repo_fill(rows, repos):
    """Give each row of `rows` the repo id_repo_ref finds it (a hub record off
    task_cache — one it lacks fills for the next frame); a slug new to `repos`
    joins it."""
    refs = [(e, id_repo_ref(id_record(e.get("fid") or ""), e.get("task") or "")) for e in rows]
    for e, (full, task) in refs:
        full = full or (hub_task(task).get("repo", "") if task else "")
        if full:
            e["repo"] = full.rpartition("/")[2]
            if full not in repos:
                repos.append(full)


def id_apply(e, fid, known, live=True):
    """Lay one row's ID over it (see above). `fid` empty or unknown ⇒ the ID column
    is blank and the row is otherwise as T493 drew it."""
    alias = e.pop("id", "") or ""
    e["aliases"] = [alias] if alias else []
    e["id"] = ""
    fi = fleet_id_mod()
    if fi is None or not fi.is_fid(fid or ""):
        return
    rec = id_record(fid)
    e["fid"] = fid
    e["id"] = id_short(fid, rec, known)
    if rec is None:
        # not here and not cached yet: its code as this login knows it, the rest a
        # placeholder until the background pull lands (EPIC T644 C7)
        e["id_pending"] = True
        return
    o = rec.get("opened") or {}
    # a row whose window says no task (another machine's — the hub's rows carry
    # none) takes its record's: the EPIC tree hangs members by it
    if not e.get("task") and re.fullmatch(r"T\d+", str(o.get("task") or "")):
        e["task"] = o["task"]
    if o.get("task") and o["task"] not in e["aliases"]:
        e["aliases"].append(o["task"])
    # the old code (`T-` + 5 lowercase) still addresses it for one version (C11, compat-1v: 下一批删)
    e["aliases"].append("T-" + fi.legacy_encode(fid)[:5])
    segs = rec.get("segments") or []
    # C17: a ledger with no segment (a window opened before C1) falls back to the
    # window's @cc_agent (row_cols put it on the row), then the hub record's
    # actual_agent; only none of them is 未知
    agent = (segs[-1].get("agent") if segs else "") or o.get("agent") or ""
    if agent not in AGENTS:
        agent = e.get("agent") or ""
    if agent not in AGENTS:
        agent = hub_task_agent(e.get("task") or o.get("task") or "")
    e["agent"] = agent if agent in AGENTS else ""
    e["segs"] = segs
    # a task's redo is the same ID's next attempt (EPIC T644 C2): 「K5 · 第 2 次」
    e["attempt"] = rec.get("attempt", 1)
    if e["attempt"] > 1 and e.get("text"):
        e["text"] = say("view_id_attempt_fmt", e["text"], e["attempt"])
    e["issues"] = sorted(id_issues(rec))
    e["hub"] = id_hub(fid)
    e["native"] = segs[-1].get("native", "") if segs and live and not rec.get("closed") else ""
    cur = [r for r in rec.get("results") or () if r.get("attempt", 1) >= e["attempt"]]   # this attempt's (C2)
    res = cur[-1].get("state", "") if cur else ""
    st = RESULT_STATE.get(res, "")
    if live and st and e.get("state") not in ("working", "looping", "needs", "exited") and not e.get("lost"):
        # S2: the newest result says how a live window ended its last piece of work
        e["state"] = st
        e["sym"] = sym_of(st)
        e["word"] = state_words(st)
    if not live and rec.get("closed"):
        # S7: a closed ID with no result exited; else its newest result
        e["sym"] = "exited" if not res else ("fail" if st == "failed" else "done")
        e["word"] = say("view_legend_exited") if not res else e.get("word", "")


def finished(e):
    """A row in 排队中 that has handed in its result (done, or the producer's 已结束
    mark): waiting to be folded away, no longer unfinished (EPIC T644 C4)."""
    return e.get("group") == "queue" and (bool(e.get("ended")) or e.get("state") in ("done", "landed"))


def id_display(groups):
    """The ID column shows the code that tells the UNFINISHED apart (EPIC T644 C4):
    every open row but a finished one in 排队中 (done, or the producer's 已结束 —
    回收 D) is unfinished; each of those rows shows
    fleet_id.display_short over them (2 places, one more while another unfinished one
    shares them) and keeps the written code (≥ 4) as `code` for its page. The set is
    saved (ids/.open) for the top bar and the notifications; finished and 已收起 rows keep
    the written code. Nothing to show ⇒ nothing changes."""
    fi = fleet_id_mod()
    if fi is None:
        return
    rows = [e for g in groups.values() for e in g if fi.is_fid(e.get("fid") or "")]
    live = {e["fid"] for e in rows if not finished(e)}
    for e in rows:
        e["code"] = e.get("id") or ""
        e["open_id"] = e["fid"] in live
        try:
            e["id"] = fi.display_short(e["fid"], live)
        except Exception:
            pass
    try:
        fi.open_save(live)
    except Exception:
        pass


def id_conflicts(rows):
    """S9: live rows sharing one native segment — each marked with the others' codes;
    and (EPIC T644 C2) two live rows carrying one task's ID."""
    by = {}
    for e in rows:
        if e.get("native") and not e.get("far"):
            by.setdefault(e["native"], []).append(e)
    seen = {id(e) for es in by.values() if len(es) > 1 for e in es}
    for e in rows:
        if e.get("fid") and not e.get("far") and not e.get("gone") and id(e) not in seen:
            by.setdefault("fid:" + e["fid"], []).append(e)
    for native, es in by.items():
        if len(es) < 2:
            continue
        for e in es:
            e["conflict"] = ", ".join(x["id"] for x in es if x is not e)
            e["state"], e["sym"], e["group"] = "needs", "needs", "ask"
            e["word"] = say("view_id_conflict")


def id_gone_index(live=()):
    """{opened key: fid} over the closed ledgers, newest opening first — a reaped
    row (fleet-history's `landed:issue:<N>` / `landed:scratch:<key>`) finds its ID —
    and {"native:<session id>": fid} over every segment: a scratch key is recycled
    (scratch-42 is many sessions), its conversation is not (T593), so that is asked
    first."""
    fi = fleet_id_mod()
    out = {}
    for fid in (fi.ledger_ids() if fi else []):
        rec = id_record(fid)
        if not rec or fid in live:
            continue
        o = rec.get("opened") or {}
        ts = o.get("ts") or 0
        # a ledger whose window went without its close (a reap that wrote only the
        # result) is still that conversation's: by native, closed or not
        for sg in rec.get("segments") or []:
            k = "native:" + (sg.get("native") or "")
            if sg.get("native") and (k not in out or ts > out[k][1]):
                out[k] = (fid, ts)
        if not rec.get("closed"):
            continue
        key = o.get("key") or ""
        if key and (key not in out or ts > out[key][1]):
            out[key] = (fid, ts)
    return {k: v[0] for k, v in out.items()}


def gone_sids(text):
    """{landed target: its session id} — fleet-history rows' second field."""
    out = {}
    for line in (text or "").split("\n"):
        parts = line.split(US, 2)
        if len(parts) == 3 and parts[0].startswith("landed:") and parts[0] not in out:
            out[parts[0]] = parts[1].strip()
    return out


def probe_title(title):
    """A probe's / placement demo's title (fleet_reap_policy.is_probe_title, BCYB):
    已收起 never lists one — it is closed, not work to resume."""
    try:
        import fleet_reap_policy
    except ImportError:
        return False
    return fleet_reap_policy.is_probe_title(title)


def id_gone_alone(have, now, keep):
    """The closed ledgers no history row and no window answers to (a no-repo task,
    a session /clear or a relay left — T593), closed within `keep`: [(fid, rec)],
    newest close first. fleet-history never lists them, so the ledger is their row."""
    fi = fleet_id_mod()
    out = []
    for fid in (fi.ledger_ids() if fi else []):
        if fid in have:
            continue
        rec = id_record(fid)
        ts = ((rec or {}).get("closed") or {}).get("ts") or 0
        if ts and probe_title((rec.get("opened") or {}).get("title") or ""):
            continue   # BCYB: 已收起 lists no probe
        # a dead record closed with nothing in it (C13's sweep) is no session
        if ts and now - ts < keep and (rec.get("segments") or (rec.get("opened") or {}).get("title")):
            out.append((ts, fid, rec))
    return [(fid, rec) for _, fid, rec in sorted(out, key=lambda x: x[0], reverse=True)]


def gone_key(target):
    m = re.match(r"landed:(issue|scratch):([^@]+)", target or "")
    if not m:
        return ""
    return ("issue-" + m.group(2)) if m.group(1) == "issue" else m.group(2)


def id_page(e, w):
    """The actions page's ID block (§8): the code and the full ID, its aliases, every
    native segment (agent · start–end · trigger · compactions), the hub's word and
    a conflict's reason. [(text, style)]."""
    if not e.get("fid"):
        return []
    out = [("", ())]
    # the WRITTEN code (≥ 4, EPIC T644 C4) — the column shows the shorter one
    out.append(("  " + say("view_id_head_fmt", e.get("code") or e.get("id") or "", e["fid"]), ("dim",)))
    if e.get("aliases"):
        out.append(("  " + say("view_id_aliases_fmt", " ".join(e["aliases"])), ("dim",)))
    segs = e.get("segs") or []
    for s in segs:
        fi = fleet_id_mod()
        span = "%s–%s" % (fi.hhmm(s.get("start")), fi.hhmm(s["end"]) if s.get("end") else "")
        tail = s.get("trigger") or ""
        if s.get("compactions"):
            tail += "  " + say("view_id_compact_fmt", s["compactions"])
        out.append(("  " + say("view_id_seg_fmt", s.get("n", "?"), (s.get("agent") or "?").capitalize(), span, tail),
                    ("dim",)))
    if not segs and "segs" in e:
        out.append(("  " + say("view_id_no_segs"), ("dim",)))
    if e.get("hub") == "unhubbed":
        out.append(("  " + say("view_id_unhubbed"), ("dim",)))
    elif e.get("hub") == "refused":
        out.append(("  " + say("view_id_hub_refused"), ("red",)))
    if e.get("conflict"):
        out.append(("  " + say("view_id_conflict_fmt", e["conflict"], e.get("native") or ""), ("red",)))
    return out


# --- an EPIC's members under its driver (T507, T486 v18 定稿 ⑪–⑭) -----------------
# Only an EPIC hangs: a driver is a window here wearing @epic (fleet-epic-heartbeat.sh)
# whose @task is the batch's parent task; its members are that task's children on
# the hub (`fleet-task-record.sh children T<n>` — parent_task, whatever their repo
# or state). A member's row follows its driver into the driver's group, its name the
# child's title (「C5 · EPIC 技能跟改」), the tree drawn in the name column only. The
# driver says 已完成/总数 (closed members counted) and is folded unless its window's
# @expand is `1` (⑭: kept until the window closes, a new member never opens it);
# folded, only a member that is ! or ✗ shows (⑬), counted red on the driver. A
# group heading counts every member hung in it, folded or not (T541): a member
# belongs to its driver's group — where it shows — whatever its own repo. A
# closed member stays in 已关闭 (⑫). An ordinary dispatch never hangs. The hub's
# answer is kept in remote-views/epic-<fleet>.json, read again every
# FLEET_VIEW_EPIC_SECS (30 s) by the refresh thread — never on the first frame.
EPIC_DONE = ("succeeded", "done", "merged")


def epic_windows(fleet):
    """{window id: (@epic, @expand)} of the fleet's windows that wear an @epic."""
    rc, out = tm("list-windows", "-t", "=" + fleet, "-F", "#{window_id}|#{@epic}|#{@expand}")
    res = {}
    for line in out.splitlines() if rc == 0 else []:
        w, epic, exp = (line.split("|") + ["", ""])[:3]
        if epic.strip():
            res[w] = (epic.strip(), exp.strip())
    return res


def epic_file(fleet):
    return views_dir() / ("epic-%s.json" % (fleet or "-"))


def epic_read_children(task):
    """The hub's children of `task`: [{id, title, state, outcome}], None when unread.
    FLEET_VIEW_EPIC_CMD (a seam, `sh -c` with the task as $1) answers instead."""
    seam = os.environ.get("FLEET_VIEW_EPIC_CMD")
    argv = ["sh", "-c", seam, "sh", task] if seam else \
        ["bash", str(Path(__file__).absolute().parent / "fleet-task-record.sh"), "children", task]
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=8)
        got = json.loads(p.stdout) if p.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    if not isinstance(got, dict) or not isinstance(got.get("children"), list):
        return None
    return [{k: str(c.get(k) or "") for k in ("id", "title", "state", "outcome")}
            for c in got["children"] if isinstance(c, dict) and re.fullmatch(r"T\d+", str(c.get("id") or ""))]


def epic_members(fleet, tasks, refresh=True, now=None):
    """{driver task: its children} for `tasks`, off the kept copy; refresh=True reads
    the hub again for a task whose copy is older than FLEET_VIEW_EPIC_SECS."""
    now = time.time() if now is None else now
    p = epic_file(fleet)
    try:
        book = json.loads(p.read_text())
        book = book if isinstance(book, dict) else {}
    except (OSError, ValueError):
        book = {}
    changed = False
    for t in tasks:
        ent = book.get(t) if isinstance(book.get(t), dict) else None
        if refresh and (ent is None or now - (ent.get("ts") or 0) >= fenv("FLEET_VIEW_EPIC_SECS", 30)):
            kids = epic_read_children(t)
            if kids is not None:
                book[t] = ent = {"ts": now, "children": kids}
                changed = True
    if changed:
        keep = {t: v for t, v in book.items() if t in tasks}
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            atomic_write(p, json.dumps(keep, ensure_ascii=False))
        except OSError:
            pass
    return {t: (book.get(t) or {}).get("children") or [] for t in tasks if isinstance(book.get(t), dict)}


def epic_kept(e):
    """A folded driver still shows a member that waits on you (!) or failed (✗)."""
    return e.get("sym") in ROW_RED


def epic_tree(groups, ended, fleet, refresh=True, marks=None):
    """Hang every EPIC's open member rows under its driver (in place). `marks`:
    epic_windows' answer (read here when None)."""
    marks = epic_windows(fleet) if marks is None and fleet else (marks or {})
    far_open = epic_far_expanded(fleet)
    drivers = {}
    for g in GROUPS:
        for e in groups[g]:
            t = e.get("task") or ""
            # a driver here wears @epic; another machine's says so in the row's field
            # 25 (its node's epic=) — the same batch hangs whichever machine is home
            # (EPIC T644 C7)
            mark = e["target"] in marks if not e.get("far") else bool(e.get("epic_mark"))
            if mark and re.fullmatch(r"T\d+", t) and t not in drivers:
                drivers[t] = e
    if not drivers:
        return
    kids = epic_members(fleet, list(drivers), refresh)
    for t, d in drivers.items():
        if t not in kids:
            continue
        recs = {c["id"]: c for c in kids[t]}
        members = []
        for g in GROUPS:
            stay = []
            for e in groups[g]:
                (members if e is not d and e.get("task") in recs else stay).append(e)
            groups[g] = stay
        stay = []
        for e in ended:
            (members if e.get("task") in recs else stay).append(e)
        ended[:] = stay
        members.sort(key=lambda e: int(e["task"][1:]))
        for m in members:
            title = (recs[m["task"]].get("title") or "").strip()
            if title:
                m["text"] = title
            m.pop("sec", None)
            m["depth"], m["fold"], m["group"] = 0, d["target"], d["group"]
        done = sum(1 for c in recs.values() if (c.get("outcome") or c.get("state")) in EPIC_DONE)
        # rows: the member rows hung under it (an open window's; a folded-away one is
        # never here) — 0 ⇒ an ordinary row, no ▸ to open (T762)
        d["epic"] = {"done": done, "total": len(recs), "rows": len(members),
                     "needs": sum(1 for m in members if m.get("sym") == "needs"),
                     "fail": sum(1 for m in members if m.get("sym") == "fail")}
        d["expanded"] = (d["target"] in far_open) if d.get("far") else marks[d["target"]][1] == "1"
        lst = groups[d["group"]]
        i = next(n for n, e in enumerate(lst) if e is d)
        lst[i + 1:i + 1] = members


def epic_rehang(groups, gone):
    """After the board's re-lay (C25B): an EPIC's members in its own group sit
    right under it, in the board's order — the order drawn is the order ↑↓ walk —
    and only they are what its ▸ opens; a member the board put in another group
    or 已收起 is an ordinary row where it stands, never hidden by the fold. No
    member left under it ⇒ no ▸ (an ordinary row, T762)."""
    drivers = {e["target"]: e for g in GROUPS for e in groups[g] if e.get("epic")}
    if not drivers:
        return
    for g in GROUPS:
        hung = {}
        for e in groups[g]:
            f = e.get("fold")
            if f in drivers and drivers[f].get("group") == g and e is not drivers[f]:
                hung.setdefault(f, []).append(e)
        moved = {id(m) for ms in hung.values() for m in ms}
        lst = [e for e in groups[g] if id(e) not in moved]
        for t, ms in hung.items():
            i = next(n for n, e in enumerate(lst) if e is drivers[t])
            for m in ms:
                m["depth"] = 0
            lst[i + 1:i + 1] = ms
        for e in lst:
            if e.get("fold") in drivers and e.get("fold") not in hung:
                e.pop("fold", None)
                e["depth"] = 0
        groups[g] = lst
    for e in gone:
        if e.get("fold") in drivers:
            e.pop("fold", None)
    for t, d in drivers.items():
        ms = [e for e in groups[d["group"]] if e.get("fold") == t]
        d["epic"] = dict(d["epic"], rows=len(ms), needs=sum(1 for m in ms if m.get("sym") == "needs"),
                         fail=sum(1 for m in ms if m.get("sym") == "fail"))


def epic_folds(e):
    """A driver with member rows under it: its ▸ / ▾, → / ← and the click fold it
    (T762) — one with none is drawn and keyed as an ordinary row."""
    ep = e.get("epic")
    return bool(ep) and ep.get("rows", 1) > 0


def epic_hidden(e, drivers):
    """A member row a folded driver hides."""
    f = e.get("fold")
    return bool(f) and f in drivers and not drivers[f].get("expanded") and not epic_kept(e)


def epic_far_file(fleet):
    return views_dir() / ("epic-open-%s.json" % (fleet or "-"))


def epic_far_expanded(fleet):
    """The far drivers this view opened (→): their window is another machine's, so
    the bit is kept here (EPIC T644 C7) — a set of row targets."""
    try:
        got = json.loads(epic_far_file(fleet).read_text())
    except (OSError, ValueError):
        return set()
    return {x for x in got if isinstance(x, str)} if isinstance(got, list) else set()


def epic_toggle(items, fleet, target, on):
    """→ / ← on a driver: its window's @expand (⑭) — another machine's driver, this
    view's own book — and the list at once."""
    if target.startswith("@"):
        if on:
            tm("set-option", "-w", "-t", target, "@expand", "1")
        else:
            tm("set-option", "-wu", "-t", target, "@expand")
    else:
        book = epic_far_expanded(fleet)
        book = (book | {target}) if on else (book - {target})
        try:
            epic_far_file(fleet).parent.mkdir(parents=True, exist_ok=True)
            atomic_write(epic_far_file(fleet), json.dumps(sorted(book)))
        except OSError:
            pass
    for e in items:
        if e.get("epic") and e.get("target") == target:
            e["expanded"] = bool(on)


def entries(vid, now=None, hub=True):
    """Every line the popup can show, in order (issue #3179): grouped by what you
    should do — 置顶 (@pin) · 等你 (needs / failed / blocked, or an unanswered ⛔
    ask on its issue — issue #4225) · 在干活 (working / looping) · 等合并/等发版
    (done, its PR open or merged-not-live; the step a tag at the row's end) ·
    刚落地 (done, its PR merged within FLEET_VIEW_LANDED_SECS, 24 h) · 其他 —
    then ▸ 已结束 (folds; the producer's mark — a bound session too once its
    issue closed and its PR merged past that window). Within a group the producer's order stands, and a
    row stays indented under its parent while the parent is in the same group.
    Machine, login and repo are tags, never groups. Each a dict:
    kind  hdr (a group heading, `group`) · sess · ask (the question a needs row
          asks, the line under it) · sec (已结束, folds) — `sec` names the
          section a line sits in
    text  the line's words · word (the state, available in actions) · sym
          (its glyph class) · group · ask · tags (lost / direct machine, ✗ broken
          configuration, ∅ no issue, k/N, repo when 2+) · right (the issue) · foot
          (the lit row's line; it says 「今天 N token」 when the hub recorded any —
          issue #3377) · today (that phrase alone) · target (what go() takes) · far (another
          machine/login)"""
    now = time.time() if now is None else now
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    hub_view_request(fleet)
    here, me = here_label(row), getpass.getuser()
    logins = fleet_logins()
    wins = windows(fleet) if fleet else {}
    held0 = names_raw(fleet) if fleet else {}
    held = names_live(held0, now)
    # the environment, else fleet.conf's line — the producer reads the same one
    try:
        landed_secs = float(conf_word("FLEET_VIEW_LANDED_SECS") or 86400)
    except ValueError:
        landed_secs = 86400.0
    gl = glyphs()
    hage = hub_age(now)
    hstale = hage is not None and hage > fenv("FLEET_HUB_SESSIONS_STALE", 60)
    groups = {g: [] for g in GROUPS}
    ended, repos, anc, norepo, shut = [], [], {}, [], []
    section, repo = "", ""
    seen = set()
    known = id_known(v[0] for v in wins.values())
    # the repo a row sits under, as the ask book's key (issue #4225): a heading's
    # owner/name; with no heading at all (a one-repo list) the fleet's one repo
    only = fleet_only_slug(fleet) if fleet else ""
    slug, lists = only, {}
    if hub:     # hub=False: the cache as it is — the popup's first paint (#3311)
        hub_fresh(fleet)
    for line in produce(fleet, kept=not hub).splitlines():
        f = line.split(US)
        if f[0] == "hdr":
            kind = f[1] if len(f) > 1 else ""
            text = f[3] if len(f) > 3 else ""
            if kind in ("pin", "ended"):
                section, slug = kind, only     # names no repo
            elif text.startswith("─") or not text.strip():
                section = ""          # the rule closing the pinned block
            else:
                section = ""
                repo = re.sub(r"\s*\(\d+\)$", "", re.sub(r"^▸\s*", "", text.strip()))
                slug = repo_slug(kind) if "/" in kind else ""
                if "/" in kind:       # a hosted repo's heading (`none` / '' are 无仓库 / ?)
                    repos.append(kind)
            continue
        if len(f) < 15 or not f[0]:
            continue
        f += [""] * (25 - len(f))
        key = f[0]
        local = not key.startswith("wid:")
        target = key if local else key[4:]
        # Reuse the producer's eligible rows and this read's canonical mapping.
        # Distinct @windows count separately even if a bad stamp shares a fid.
        if not local and row.get("fuid") and target.startswith(row["fuid"] + "/"):
            target, far = resolve(vid, target, row, fleet, wins)
            if not target or far:
                continue
            local = True
        if local and (not re.fullmatch(r"@[0-9]+", target) or
                      wins.get(target, ("", "", 0))[1] in ("home", "panel")):
            continue
        identity = (local, target)
        if identity in seen:
            continue
        seen.add(identity)
        mark = f[8]
        machine = mark.rstrip("!~") or here
        lost, direct = mark.endswith("!"), mark.endswith("~")
        login = me if local else logins.get(target.split("/", 1)[0], "")
        name = TAG_RE.sub("", f[3]).strip()
        title = (f[13] or "").strip()
        # a name the person gave it (issue #3317) is already the title cell — the
        # producer's for a window here, its node's title= for a far one; until a
        # far rename has gone round the hub, the name this client just sent
        if target in held:
            if held[target][0] in (title, name):
                held.pop(target)
            else:
                title = held[target][0]
        detail = (f[7] or "").strip()
        issue = f[9].strip() if f[9].strip() not in ("—", "·", "-") else ""
        depth = int(f[6]) if f[6].isdigit() else 0
        state = f[1]
        act = wins.get(target, ("", "", 0))[2] if local else 0
        if not act:
            # another machine's: the measurement bus's reading time is its last word
            ts = (f[18].split("|") + ["", "", ""])[2]
            act = int(ts) if ts.isdigit() else 0
        # the session's pool tokens today (issue #3377): the bus's sixth part, a
        # remote row's off the hub; none recorded ⇒ nothing said, never 0
        tok = (f[18].split("|") + [""] * 6)[5]
        today = say("view_today_fmt", tokens_short(tok)) if tok.isdigit() and int(tok) > 0 else ""
        # no activity known: 刚落地 — unless the producer already found it over
        # (issue #4225: its own clock, the last state, is past the window)
        landed = state in ("done", "landed") and f[10].strip() in MERGED_PR and \
            (now - act <= landed_secs if act else section != "ended")
        # issue #4225: an unanswered ⛔ ask on its issue is 等你 whatever the state;
        # a done row whose PR is still on its way is 等合并 / 等发版
        pend = open_ask(slug, issue, lists) if issue and section != "pin" else ""
        stage = stage_of(f[10], f[19].strip())
        grp = group_of(state, section == "pin", landed, section == "ended", bool(pend), stage)
        ask = one_line(f[17]) if state == "needs" else ""
        if not ask and pend and grp == "ask":
            ask = pend
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
        if grp == "queue" and stage:
            tags.append(say("view_stage_" + stage))
        if grp == "queue" and state in ("idle", "sleeping") and section != "ended":
            tags.append(say("view_state_idle"))      # T688: idle waits in 排队中, said so
        e = {"kind": "sess", "target": target, "far": not local, "machine": machine, "login": login,
             "open": target in wins if local else True,
             "state": state, "text": title or name, "name": name, "reap": f[14].strip(), "issue": issue, "depth": depth,
             "detail": detail,
             "group": grp, "sym": sym_of(state, lost), "lost": lost, "lost_secs": lost_secs, "ask": ask, "tags": tags, "repo": repo,
             "word": state_words(state, detail if state == "needs" else ""),
             "today": today, "act": act,
             "foot": " · ".join(x for x in (title or name, reap_words(f[14]),
                                            detail if detail and detail != state else "", today,
                                            " · ".join(x for x in (machine, login) if x)) if x)}
        # Column 21 carried a launch-proof session's status proof; nothing writes
        # it since EPIC T497 C8, an older producer's is ignored.
        e["deploy"] = f[19].strip()
        e["pr"] = f[10].strip()
        # plan B's columns (T493): ID · Agent · short name · the row's own repo
        own = f[23].strip()
        e["repo"] = own.rpartition("/")[2] if "/" in own else (repo if slug and not section else "")
        # a window here with no agent word (an older producer) is Claude — the
        # spawners' convention; another machine's says its own or 未知
        row_cols(e, f[21], f[22] or ("claude" if local else ""), title, name)
        e["task"] = f[21].strip() if re.fullmatch(r"T\d+", f[21].strip()) else ""
        # field 25 (EPIC T644 C7): the row drives an EPIC — here or on another machine
        e["epic_mark"] = f[24].strip() == "1"
        # the window's own ID (EPIC T497 C3): its short code, ledger agent and result
        id_apply(e, wins.get(target, ("", "", 0))[0] if local else far_fid(target), known)
        if not e["repo"]:
            norepo.append(e)
        if e["state"] in ("working", "looping", "idle") and task_ended(e):
            # its record has ended: done (排队中), even with a loop still running in its window
            e["state"], e["sym"] = "done", sym_of("done", e["lost"])
            e["word"] = state_words("done")
        if e["state"] != state:
            grp = e["group"] = group_of(e["state"], section == "pin", landed, section == "ended", bool(pend), stage)
        if grp == "shut":
            # T688: the agent exited, its window still up — folded into 已收起 at
            # once, a live row there: ↵ goes to its window's recovery page
            e.update(group="folded", sec="gone", shut=True, depth=0)
            e["word"] = say("view_ended_exited")
            e["foot"] = " · ".join(x for x in (e["foot"], e["word"], say("view_gone_hint")) if x)
            shut.append(e)
            continue
        if section == "ended" and grp == "queue":
            # the producer's 已结束 (回收 D): no group of its own — 排队中, to be
            # folded away; its words say why, Tab reaps it now
            why = say("view_ended_merged") if f[10].strip() in MERGED_PR else say("view_ended_done")
            e["word"] = why
            e["ended"] = True
            e["right"] = say("view_ago_fmt", dur(now - act)) if act and local else ""
            e["depth"] = 0
            e["foot"] = " · ".join(x for x in (e["foot"], say("view_ended_reap_hint")) if x)
            groups["queue"].append(e)
            continue
        # indented under its parent only while the parent sits in the same group
        par = anc.get(depth - 1) if depth > 0 else None
        e["depth"] = par[1] + 1 if par and par[0] == grp else 0
        anc = {d: v for d, v in anc.items() if d < depth}
        anc[depth] = (grp, e["depth"])
        groups[grp].append(e)
    # T593: a row with no window @repo (an EPIC driver opens @norepo) takes the
    # ledger's / the task record's / the charter's repo; none ⇒ the column stays blank
    repo_fill(norepo, repos)
    # the sessions whose windows are gone (issue #3286): after the open ended rows,
    # one an open row already shows (its issue, restored since) left out
    open_issues = {e["issue"] for g in groups.values() for e in g if e.get("issue")} | \
        {e["issue"] for e in ended + shut if e.get("issue")}
    # issue #3731: they are their own group, 已关闭 — only the last
    # FLEET_VIEW_CLOSED_HOURS of them listed, the older ones a count that opens
    # /fleet-history; a row whose age cannot be read counts as older
    gone, older, keep, ages = [], 0, closed_secs(), {}
    gidx = None
    gtext = gone_text(fleet)
    sids = gone_sids(gtext)
    for target, glyph, label, name, title, act, pr, when in gone_rows(gtext):
        if label.startswith("#") and label in open_issues:
            continue
        if probe_title(title or name):
            continue   # a probe / placement demo is not work to come back to (BCYB)
        age = gone_age(when, act, now)
        if age is None or age >= keep:
            older += 1
            continue
        ages[target] = age
        grepo = target.rpartition("@")[2] if "@" in target else ""
        word = say("view_ended_gone_merged") if glyph == "✓" else say("view_ended_gone")
        gone.append({"kind": "sess", "target": target, "far": False, "gone": True, "machine": here, "login": me,
                     "state": "landed", "text": title or name, "name": name, "reap": "", "issue": label,
                     "depth": 0, "detail": "", "group": "folded", "sec": "gone",
                     "sym": "done" if glyph == "✓" else "fail", "lost": False, "lost_secs": None, "ask": "",
                     "tags": [], "repo": grepo.rpartition("/")[2], "word": word, "right": act,
                     "foot": " · ".join(x for x in (title or name, label, say("view_pr_fmt", pr) if pr.startswith("#") else "",
                                                    word, say("view_gone_hint")) if x)})
        row_cols(gone[-1], label, "", title, name)
        if gidx is None:
            gidx = id_gone_index({v[0] for v in wins.values() if v[0]})
        id_apply(gone[-1], gidx.get("native:" + sids.get(target, ""), "") or gidx.get(gone_key(target), ""),
                 known, live=False)
    # T593: a closed ID no history row lists — its ledger is the row (no restore:
    # its Agent, title, result and ID page only)
    have = {e.get("fid") for e in gone if e.get("fid")} | {v[0] for v in wins.values() if v[0]}
    for fid, rec in id_gone_alone(have, now, keep):
        o = rec.get("opened") or {}
        title = o.get("title") or ""
        gone.append({"kind": "sess", "target": "id:" + fid, "far": False, "gone": True, "ledger": True,
                     "machine": here, "login": me, "state": "landed", "text": title, "name": title, "reap": "",
                     "issue": "", "depth": 0, "detail": "", "group": "folded", "sec": "gone", "sym": "done",
                     "lost": False, "lost_secs": None, "ask": "", "tags": [], "repo": "",
                     "word": say("view_ended_gone"), "right": say("view_ago_fmt", dur(now - rec["closed"]["ts"])),
                     "task": o.get("task") or "",
                     "foot": " · ".join(x for x in (title, o.get("task") or "", say("view_ended_gone")) if x)})
        row_cols(gone[-1], o.get("task") or "", "", title, title)
        id_apply(gone[-1], fid, known, live=False)
        ages["id:" + fid] = now - rec["closed"]["ts"]
    repo_fill([e for e in gone if e.get("ledger")], repos)
    gone.sort(key=lambda e: ages.get(e["target"], 0))
    if held != held0:
        names_save(fleet, held)
    # an EPIC's members under its driver (T507) — the hub read off the first frame
    if fleet:
        epic_tree(groups, ended, fleet, refresh=hub)
    ended = [e for e in groups["queue"] if e.get("ended")]
    # S9: two live windows on one conversation — both to 等你
    id_conflicts([e for g in GROUPS for e in groups[g]] + shut)
    for e in [e for e in shut if e.get("conflict")]:
        shut.remove(e)
        e.pop("sec", None)
        e.pop("shut", None)
        e["group"] = "ask"
        groups["ask"].append(e)
    for g in GROUPS:
        if g != "ask":
            moved = [e for e in groups[g] if e.get("conflict")]
            groups[g] = [e for e in groups[g] if not e.get("conflict")]
            for e in moved:
                e["depth"] = 0
            for e in moved:
                e.pop("fold", None)
            groups["ask"] += moved
    # A4G2: the hub's one list, when fresh — the same entries, groups and order
    # the console draws
    board = board_read(now) if fleet else None
    if board:
        groups, gone = board_apply(board, groups, shut, gone, here, me)
        shut, older = [], int(board.get("gone_more") or 0)
        ended = [e for e in groups["queue"] if e.get("ended")]
        epic_rehang(groups, gone)
    id_display(dict(groups, shut=shut))
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
        many = [e for e in ended if not e.get("lost")] if g == "queue" else []
        if many:
            # the producer's 已结束 rows still hold a window (each costs memory): ↵
            # folds them all now through dash-reap.sh --yes, its own gate each — a
            # dirty worktree is kept (only the window goes), a live one is skipped
            out.append({"kind": "cmd", "cmd": "reapall", "act": "reapall", "n": len(many),
                        "row": {"targets": [("wid:" if e["far"] else "") + e["target"] for e in many]},
                        "text": say("view_cmd_reapall_fmt", len(many))})
    # 已收起 (a record only; ↵ on a row resumes its conversation), folded until
    # opened (issue #3731)
    gone = shut + gone
    if gone or older:
        out.append({"kind": "sec", "sec": "gone", "text": say("view_sec_gone_fmt", len(gone)), "n": len(gone),
                    "older": older})
        for e in gone:
            if multi and e["repo"]:
                e["tags"].append(e["repo"])
            out.append(e)
        if older:
            out.append({"kind": "cmd", "cmd": "history", "act": "history", "sec": "gone", "n": older, "row": {},
                        "text": say("view_cmd_older_fmt", older)})
    task_cache_kick()
    id_cache_kick()
    return out


# The one session list (claude-fleet A4G2): the hub builds it once — rows,
# groups, order, count — inside every fleet_sessions answer (`board`), which
# fleet-hub-sessions.sh keeps as global/hubsess.body; the console's 会话 draws
# the same one. While it is fresh (hub_ok within FLEET_HUB_SESSIONS_STALE) the
# list takes its entries, groups, order and words from it: a window here only
# lends its row (state, actions), a row with no window is drawn from the board
# (a record not started yet: no actions). Stale or absent ⇒ the list as before.
_BOARD = {}


def board_read(now=None):
    """The hub's list off global/hubsess.body, or None (no hub, an older hub, stale)."""
    if os.environ.get("FLEET_VIEW_BOARD", "1") == "0" or hub_stale(now) or hub_age(now) is None:
        return None
    path = dash_global() / "hubsess.body"
    try:
        st = path.stat()
    except OSError:
        return None
    sig = (st.st_mtime_ns, st.st_size)
    if _BOARD.get("sig") != sig:
        try:
            b = json.loads(path.read_text(encoding="utf-8")).get("board")
        except (OSError, ValueError, AttributeError):
            b = None
        _BOARD.update(sig=sig, board=b if isinstance(b, dict) and isinstance(b.get("rows"), list) else None)
    return _BOARD.get("board")


def board_words(r):
    w = r.get("words") or ["", ""]
    if "lang" not in _BOARD:
        _BOARD["lang"] = ui_lang()
    return (w[1] if _BOARD["lang"] == "en" and len(w) > 1 else w[0]) or r.get("tag", "")


def board_why(r):
    """The hub's 「为什么还没收」 line for the row (E101, BoardRow.why), in the
    panel's language — the console's words, one source; "" when none."""
    w = r.get("why")
    if not isinstance(w, list) or len(w) != 2:
        return ""
    if "lang" not in _BOARD:
        _BOARD["lang"] = ui_lang()
    return str(w[1] if _BOARD["lang"] == "en" else w[0])


BOARD_SYM = {"asking": "needs", "waiting_you": "needs", "failed": "fail", "refused": "fail", "working": "work",
             "looping": "work", "completed": "done", "turn_done": "done", "ended": "done", "exited": "exited",
             "parked": "needs", "stopped": "fail"}


def board_apply(board, groups, shut, gone, here, me):
    """Re-lay the list on the hub's one list: (groups, gone) in its order. A row
    is matched to an entry by its session's ID (fid), else its worker_id (another
    machine's target); a window here the hub has not heard of yet stays at the
    end of its group (the next round lists it); a closed row only this machine
    remembers is left out — the hub's 已收起 is the list's."""
    items = [e for g in GROUPS for e in groups[g]] + shut + gone
    by_fid, by_wid = {}, {}
    for e in items:
        if e.get("fid"):
            by_fid.setdefault(e["fid"], e)
        if e.get("far") and e.get("target"):
            by_wid.setdefault(e["target"], e)
    used = set()
    out = {g: [] for g in GROUPS}
    out_gone = []
    for r in board.get("rows") or []:
        g = r.get("group") or "queue"
        e = by_fid.get(r.get("id") or "") or by_wid.get(r.get("worker_id") or "")
        if e is not None and id(e) in used:
            e = None
        if e is None:
            title = r.get("title") or ""
            e = {"kind": "sess", "target": "id:" + r["id"], "far": True, "record_only": True, "ledger": True,
                 "machine": r.get("machine") or "", "login": r.get("login") or "", "open": True,
                 "state": r.get("state") or r.get("tag") or "", "text": title, "name": title, "reap": "",
                 "issue": "", "depth": 0, "detail": "", "sym": BOARD_SYM.get(r.get("tag"), "idle"),
                 "lost": bool(r.get("lost")), "lost_secs": None, "ask": "", "tags": [],
                 "repo": (r.get("repo") or "").rpartition("/")[2], "today": "", "task": r.get("task") or "",
                 "code": r.get("code") or "", "id": (r.get("code") or "")[:4], "fid": r.get("id")}
            if g == "gone":
                e["gone"] = True
        else:
            used.add(id(e))
            if r.get("title"):
                e["text"] = r["title"]
            if g != "gone" and e.get("gone"):
                # a closed session here, its record still open on the hub: the
                # record's row (counted, nothing to act on — it is not running)
                e.pop("gone", None)
                e.update(record_only=True, ledger=True, open=True, far=True, target="id:" + r["id"])
        e["board"] = r.get("id")
        if not e.get("act") and isinstance(r.get("at"), (int, float)):
            e["act"] = int(r["at"])             # the hub's last word for it (Q1A8: the landing's pick)
        e["word"] = board_words(r)
        e["depth"] = int(r.get("depth") or 0)
        e["foot"] = " · ".join(x for x in (e.get("text") or "", e["word"], " · ".join(
            x for x in (e.get("machine") or here, e.get("login") or me) if x)) if x)
        why = board_why(r)
        if why:
            e["why"] = why
        else:
            e.pop("why", None)
        if g == "gone":
            e.update(group="folded", sec="gone")
            out_gone.append(e)
        else:
            e.pop("sec", None)
            e.pop("shut", None)
            e["group"] = g if g in out else "queue"
            out[e["group"]].append(e)
    for g in GROUPS:
        for e in groups[g]:
            if id(e) not in used and not e.get("far"):
                e["unboarded"] = True
                out[g].append(e)
    return out, out_gone


def counted_rows(items):
    """The rows the count counts, one per (far, target): a session up — never one
    put away, and never an exited agent's window folded into 已收起 (sec gone,
    A4G2: the hub's list counts the same)."""
    return {(bool(e.get("far")), e.get("target")): e for e in items
            if e.get("kind") == "sess" and e.get("target") and not e.get("gone") and e.get("open", True)
            and e.get("sec") != "gone"}


def session_count(items, query="", remote_unknown=False):
    rows = counted_rows(items)
    known = [e for e in rows.values() if not e.get("lost")]
    unknown = remote_unknown or any(e.get("lost") for e in rows.values())
    total = str(len(known)) + ("+?" if unknown else "")
    if query.strip():
        matched = str(sum(matches(e, query) for e in known))
        if unknown:
            matched += "+?"
        total = matched + "/" + total
    return say("view_count_fmt", total)


def banner(items, now=None):
    """The red line on top of the popup (issue #3184, EPIC #3178 C6): hub_ok older
    than FLEET_HUB_SESSIONS_STALE and another machine's rows on the list ⇒ 「<机器们>
    的会话 N 分钟没更新（连不上入口）· 正在重连」 — the list's own refresh calls
    hub_fresh's --ensure meanwhile; with no such row 「入口 N 分钟没响应」 alone (a
    row's PR is read off the hub, issue #4902). Nothing else is judged here: the
    hub fresh, or no hub_ok at all ⇒ no line."""
    age = hub_age(now)
    if age is None or age <= fenv("FLEET_HUB_SESSIONS_STALE", 60):
        return ""
    names = []
    for e in items:
        if e["kind"] == "sess" and e.get("lost") and e.get("machine") and e["machine"] not in names:
            names.append(e["machine"])
    if not names:
        # no other machine's row to name (issue #4902): the hub is still what the
        # rows' PR is read off — say how long it has not answered, never a spinner
        return say("view_hub_down_banner_fmt", max(1, int(age) // 60))
    return say("view_stale_banner_fmt", "、".join(names), max(1, int(age) // 60))


def lost_msg(e):
    """↵ on a lost row: nothing to go to — say so instead of trying (None = go)."""
    if e.get("kind") == "sess" and e.get("lost"):
        return say("view_lost_go_fmt", e.get("machine") or "?")
    return None


class Refresh:
    """The open popup's list, read again every FLEET_VIEW_REFRESH (2 s) off the
    screen's thread (entries() runs the producer and hub_fresh, up to seconds when
    the hub is silent): `poll()` hands back a new list once one is read, else None.
    first: seconds to the first read (default `every`) — 0 when the popup drew its
    first frame from the cache and the hub check is still owed (issue #3311)."""

    def __init__(self, vid, every=None, first=None):
        self.vid, self.every = vid, fenv("FLEET_VIEW_REFRESH", 2) if every is None else every
        self.due = time.monotonic() + (self.every if first is None else first)
        self.res, self.busy = None, False
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


def row_issues(e):
    """The row's linked issue numbers: its own, and its ID's (EPIC T497 C3 — the
    ledger's issues and every #N in the words it was dispatched with)."""
    issue = (e.get("issue") or "").lstrip("#")
    out = [issue] if issue.isdigit() else []
    return out + [n for n in e.get("issues") or () if n not in out]


def issue_hit(token, e):
    """The linked issue a word that is a number or `#number` names exactly (plan B,
    T493: an issue is never drawn on the row, but it is searched), or ''."""
    if re.fullmatch(r"#?\d+", token) is None:
        return ""
    n = token.lstrip("#")
    return n if n in row_issues(e) else ""


def id_code_hit(token, e):
    """A word written as the row's ID code (C11): `k3f9`, `#K3F9`, I/L/O read as 1/1/0,
    a prefix of the row's code; the old `t-hfkc7` for one version. A number never is.
    2 places are enough (EPIC T644 C4: the code a row shows); `visible` keeps a
    finished row's code hit only while no unfinished row has one (convention 4)."""
    fi = fleet_id_mod()
    fid = e.get("fid") or ""
    if fi is None or not fi.is_fid(fid):
        return False
    p = fi.parse_code(token, fi.DISPLAY_MIN)
    if p is None:
        return False
    return (fi.legacy_encode(fid) if p[1] else fi.encode(fid)).startswith(p[0])


CODE_HIT = 2100


def score_token(token, e):
    """The row's title (substring, a word start better) > its window name or ID >
    its linked issue (a whole number, exactly) > the title's letters in order. Only
    those (issue #3327): a machine's, a login's or a repo's name never hits —
    typing `mac-a` lights no row, the ⚡ row takes it."""
    name = e.get("text") or ""
    i = name.lower().find(token)
    if i >= 0:
        return 3000 - i + (200 if word_start(name, i) else 0)
    if id_code_hit(token, e):
        return CODE_HIT
    # a code is a PREFIX (id_code_hit above), never a substring, and the full ID
    # only for a word long enough to mean it: 2 typed places (C4) would light every
    # row whose code or hex happens to hold them
    fid = e.get("fid") or ""
    hay = " ".join(str(x) for x in [e.get("name"), "" if fid else e.get("id"), fid if len(token) >= 8 else ""]
                   + list(e.get("aliases") or ()) if x).lower()
    i = hay.find(token)
    if i >= 0:
        return 2000 - i
    if issue_hit(token, e):
        return 1500
    hit = fuzzy(token, name)
    return 1000 + hit[0] if hit else None


def match_why(e, query):
    """The bottom line under a search: why the lit row is listed — said only when
    its linked issue is what matched (a name hit explains itself)."""
    words = query.lower().split()
    name = (e.get("text") or "").lower()
    for w in words:
        n = issue_hit(w, e)
        if n and w not in name:
            return say("view_match_issue_fmt", "#" + n)
    return ""


def note_of(e):
    """The lit session's bottom line (plan B): what its row no longer carries — lost,
    a broken configuration (red: a person has to act), k/N, the PR's step, the
    repo when 2+ — and, first, why the hub says it is still open (E101: the
    console card's 「为什么还没收」 line, one source). (text, red)."""
    tags = [t for t in (e.get("tags") or []) if t and t != e.get("repo")]
    red = any(say("view_tag_cfg_broken") in t for t in tags)
    return " · ".join(([e["why"]] if e.get("why") else []) + tags), red


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
        toks = query.split()
        # a typed code (EPIC T644 C4, convention 4): the unfinished first — while one
        # of them answers, a finished row only its code would list stays out
        if len(toks) == 1 and any(e.get("open_id") and id_code_hit(toks[0].lower(), e) for _, _, e in hits):
            hits = [h for h in hits if h[2].get("open_id") or h[0] != CODE_HIT]
        out = []
        for _, _, e in sorted((h for h in hits if h[0] is not None), key=lambda h: (-h[0], h[1])):
            out.append(dict(e, depth=0))
            if e.get("target") in asks and not e.get("sec"):
                out.append(dict(asks[e["target"]], depth=0))
        return out
    drivers = {e["target"]: e for e in items if epic_folds(e)}
    hide = {e["target"] for e in items if e["kind"] == "sess" and epic_hidden(e, drivers)}
    out = [dict(e, closed=e["sec"] not in opened) if e["kind"] == "sec" else e
           for e in items if not (e.get("sec") and e["kind"] != "sec" and e["sec"] not in opened)
           and not (e["kind"] == "sess" and e.get("target") in hide)
           and not (e["kind"] == "ask" and e.get("of") in hide)]
    if not drivers:
        return out
    # the tree in the name column (T507): ├ each shown member, └ the last
    last = {}
    for i, e in enumerate(out):
        if e["kind"] == "sess" and e.get("fold") in drivers:
            last[e["fold"]] = i
    stem = {}
    for i, e in enumerate(out):
        if e["kind"] == "sess" and e.get("fold") in drivers:
            end = last[e["fold"]] == i
            out[i] = dict(e, tree="└ " if end else "├ ")
            stem[e["target"]] = "  " if end else "│ "
        elif e["kind"] == "ask" and e.get("of") in stem:
            out[i] = dict(e, tree=stem[e["of"]])
    return out


def sec_fold(opened, sec, expand):
    """The open sections after → (`expand`) or ← on heading `sec`: → on an open
    one and ← on a shut one change nothing (issue #3666)."""
    return (opened | {sec}) if expand else (opened - {sec})


def legend():
    """The one line `?` toggles on an empty query: every glyph and its word."""
    gl = glyphs()
    return "  ".join("%s %s" % (gl[k], say("view_legend_" + k)) for k in LEGEND)


PUNCT = "，。；：、！？,;:!?·—)）」』"
ID_W, AGENT_W, REPO_W = 8, 7, 13


def ellipsis(text, room, cells, clip):
    """`text` in `room` cells, `…` closing what was cut."""
    if cells(text) <= room:
        return text
    return clip(text, max(0, room - 1)) + "…" if room > 0 else ""


def clip_name(text, room, cells, clip):
    """`text` in `room` cells: whole when it fits, else cut at the last
    punctuation that leaves at least half the room (then `…`), else clipped."""
    if cells(text) <= room:
        return text
    body = clip(text, max(0, room - 1))
    cut = max((i for i, ch in enumerate(body) if ch in PUNCT), default=-1)
    if cut >= 0 and cells(body[:cut]) * 2 >= room:
        return body[:cut].rstrip(" ·") + "…"
    return body + "…"


def agent_word(e):
    a = e.get("agent") or ""
    return a.capitalize() if a else say("view_agent_unknown")


def name_col(width):
    """The cell the name column starts at, as row_segs lays a row out."""
    return 4 + ID_W + 1 + (AGENT_W + 1 if width >= 40 else 0)


def row_segs(e, width, cells, clip, lit=False, glyph=True):
    """One session as plan B draws it (T486 v14 §1): glyph(1) · ID(8, bold) ·
    Agent(7) · short name · repo(13), the repo column kept when empty. Only ! and ✗
    are coloured (red, bold); a lost row is grey end to end; 未知 is grey."""
    gl, col = glyphs(), color_on()
    base = (("dim",) if e.get("lost") else ()) + (("lit",) if lit else ())
    sym = e.get("sym") or "idle"
    gstyle = base + (("c%d" % GLYPH_COLORS[sym], "bold") if col and sym in ROW_RED and not e.get("lost") else ())
    indent = "  " * (e.get("depth") or 0)
    show_repo = width >= 60
    show_agent = width >= 40
    agent = agent_word(e)
    segs = [("  ", base), (gl[sym], gstyle), (" ", base),
            ((e.get("id") or "").ljust(ID_W) + " ", base + ("bold",))]
    if show_agent:
        aw = ellipsis(agent, AGENT_W, cells, clip)
        segs.append((aw + " " * (AGENT_W - cells(aw)) + " ", base + (("dim",) if not e.get("agent") else ())))
    used = sum(cells(t) for t, _ in segs)
    tail = (REPO_W + 2) if show_repo else 1
    room = max(1, width - used - tail)
    # an EPIC (T507): a member's tree, the driver's ▸ / ▾ and its 已完成/总数 —
    # grey — then !k / ✗k in red for the members that still show folded
    lead = e.get("tree") or indent
    ep = e.get("epic")
    after = []
    if ep:
        if epic_folds(e):
            lead = ("▾ " if e.get("expanded") else "▸ ") + lead
        after.append((" %d/%d" % (ep["done"], ep["total"]), base + ("dim",)))
        red = base + ((("c%d" % GLYPH_COLORS["needs"], "bold") if col and not e.get("lost") else ()))
        for k in ("needs", "fail"):
            if ep.get(k):
                after.append((" %s%d" % (gl[k], ep[k]), red))
    extra = sum(cells(t) for t, _ in after)
    if extra and room - extra < 8:
        after, extra = [], 0
    name = clip_name(lead + (e.get("text") or ""), room - extra, cells, clip)
    if after:
        segs.append((name, base))
        segs += after
        segs.append((" " * max(0, room - extra - cells(name)), base))
    else:
        segs.append((name + " " * max(0, room - cells(name)), base))
    if show_repo:
        r = ellipsis(e.get("repo") or "", REPO_W, cells, clip)
        segs.append((" " + r + " " * (REPO_W - cells(r)) + " ", base))
    used = sum(cells(t) for t, _ in segs)
    if used < width:
        segs.append((" " * (width - used), base))
    return segs


# the icon column (T774): a 1-cell gutter, then a 2-cell slot a narrow glyph sits
# at the right of (where a session row's state glyph is) and a wide one (⚡) fills,
# a space — so every label starts at TEXT_X, a session's ID too
TEXT_X = 4


def cmd_line(text, cells):
    """A command row (✦ 消息 · ⚡ 新会话 · $ 命令行 · 置顶 · ◐ · ⏻ …) with its icon in
    the one column and its words at TEXT_X, by display cells; a row with no icon
    (its first word is not a lone symbol) keeps the slot blank."""
    icon, sep, rest = text.partition(" ")
    if not sep or len(icon) != 1 or icon.isalnum() or cells(icon) > 2:
        icon, rest = "", text
    return " " + " " * (2 - cells(icon)) + icon + " " + rest


def paint(shown, at, width, cells, clip):
    """The list's lines as segments [(text, style)] — style a tuple of: bold ·
    lit · dim · c<N> (a 16-colour palette number). Kept off curses so the
    selftest reads exactly what is drawn. Selection changes style only; glyph/name columns are invariant."""
    lines = []
    for i, e in enumerate(shown):
        lit = i == at
        if e["kind"] == "hdr":
            lines.append([(clip("─ " + e["text"] + " ", width), ("bold",))])
            continue
        if e["kind"] == "sec":
            # a row the cursor stops on (T762): indented like one; only a ─ heading
            # starts at the left edge
            lines.append([(clip("  " + ("▸ " if e.get("closed", True) else "▾ ") + e["text"], width),
                           ("lit",) if lit else ())])
            continue
        if e["kind"] == "cmd":
            lines.append([(clip(cmd_line(e["text"], cells), width), ("lit",) if lit else ())])
            continue
        if e["kind"] == "grid":
            # the ⚡ row's cells (issue #3327): the one Tab is on lit, the rest plain
            segs = [("    ", ())]
            for n, (text, on) in enumerate(e.get("cells") or []):
                segs += ([("  ·  ", ("dim",))] if n else []) + [(text, ("lit", "bold") if on else ())]
            if not e.get("cells"):
                segs.append((e.get("text") or "", ("dim",)))
            if e.get("note"):
                segs.append(("  " + e["note"], ("dim",)))
            lines.append(segs)
            continue
        indent = "  " * (e.get("depth") or 0)
        if e["kind"] == "ask":
            # the question under its row, from the name column
            lead = " " * (4 + ID_W + 1 + (AGENT_W + 1 if width >= 40 else 0))
            lines.append([(clip(lead + (e.get("tree") or indent) + e["text"], width), ("dim",))])
            continue
        lines.append(row_segs(e, width, cells, clip, lit))
    return lines


def nav_step(shown, at, d):
    """↓ (d=1) / ↑ (d=-1) in the popup's list (T762): the next / previous row the
    cursor stops on, as drawn, round from the last to the first and back — the ONE
    rule, so ↑ walks exactly ↓'s way back. `at` itself when nothing stops."""
    sel = [i for i, e in enumerate(shown) if pickable(e)]
    if not sel:
        return at
    if d > 0:
        return next((i for i in sel if i > at), sel[0])
    return next((i for i in reversed(sel) if i < at), sel[-1])


def row_gone_at(shown, at):
    """Where the cursor goes when its row left the list: the nearest session, else
    ⚡ (T762: the commands sit above and below the sessions, so the old index
    would land on one of them), else the old index kept in range."""
    sess = [i for i, e in enumerate(shown) if e["kind"] == "sess"]
    if sess:
        return min(sess, key=lambda i: abs(i - at))
    return next((i for i, e in enumerate(shown) if e.get("cmd") == "new"), min(at, max(0, len(shown) - 1)))


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


def resolve(vid, target, row, fleet, inventory=None):
    """(window id in the fleet, far) for a target: a window here; a worker id of
    this fleet (its UUID = the registry's fuid=) by @fleet_id; anything else far."""
    if target.startswith("@"):
        return target, False
    uuid, _, fid = target.partition("/")
    if fid and uuid and uuid == row.get("fuid"):
        matches = [w for w, v in (windows(fleet) if inventory is None else inventory).items() if v[0] == fid]
        return (matches[0] if len(matches) == 1 else ""), False
    return "", True


def log_switch(rec):
    try:
        path = switch_log()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as out:
            out.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
    except OSError:
        pass


def toast(client, text, level="warn", nxt="", secs=None):
    """A 看台 message on this client only: a notice (T675, bin/fleet_notice.py —
    the message row: an error until seen, warn 6 s, info 3 s; recorded for ⌘P's ✦ 消息), never a
    0.75 s display-message."""
    try:
        sys.path.insert(0, str(Path(__file__).absolute().parent))
        import fleet_notice
        fleet_notice.notify(level, text, nxt, client=client, sock="" if os.environ.get("TMUX") else _SOCK[0],
                            source="看台", secs=secs)
    except Exception:
        tm("display-message", *(["-c", client] if client else []), "-d", "6000", text)


def notice_tag():
    """The tag a child's notices carry (FLEET_NOTICE_TAG): the one this run was
    handed, else a new one — so a caller can ask whether the child already said
    why (fleet_notice.seen) instead of saying it a second time."""
    return os.environ.get("FLEET_NOTICE_TAG") or "t%d-%d" % (os.getpid(), int(time.time() * 1000))


def notice_seen(tag):
    try:
        import fleet_notice
        return fleet_notice.seen(tag)
    except Exception:
        return False


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
                                              pl.link_host(machine, login), cmd],
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
    toast(client, say("view_peer_wait_fmt", m), "info")
    return "peer-wait", 3, m, l, extra


def far_miss(vid, row, rc):
    """The line a go that did not land says: a browser 看台 cannot reach another
    machine's session at all (go's `unsupported`) — never 「<machine> 这台还没接上」,
    which sent the person looking for a broken link (C8X3)."""
    if rc == 3 and vid.startswith("wt-") and row.get("far"):
        return say("view_web_far")
    return say("view_far_fmt", row.get("machine") or "?") if rc == 3 else say("view_gone")


WEB_GO_RE = re.compile(r"[A-Za-z0-9-]{1,64}/[A-Za-z0-9._:-]{1,128}")


def web_go(g, client, target):
    """A browser 看台's go to another machine's session (task C8X3): `ESC ] 7502 ;
    web-go ; w=<worker id> BEL` on its client's own tty — the page
    (extras/web-console terminal.tsx) opens /s/<id>?view=term, which the hub
    admits only on one of the person's own logins. True when it was written."""
    if not WEB_GO_RE.fullmatch(target or ""):
        return False
    if client:
        _, tty = tm("display-message", "-p", "-c", client, "#{client_tty}")
    else:
        _, out = tm("list-clients", "-t", "=" + g, "-F", "#{client_tty}")
        tty = (out.splitlines() or [""])[0]
    if not tty.startswith("/dev/"):
        return False
    try:
        fd = os.open(tty, os.O_WRONLY | os.O_NOCTTY)
        try:
            os.write(fd, ("\x1b]7502;web-go;w=%s\x07" % target).encode())
        finally:
            os.close(fd)
    except OSError:
        return False
    return True


def webterm_switch(vid, window):
    if not vid.startswith("wt-"):
        return None
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "fleet-webterm.py"),
                        "switch", "--conn", vid[3:], "--window", window],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode


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
    if far and vid.startswith("wt-"):
        # a browser 看台 has no peer window (no ssh of its own): its page opens
        # that session's own terminal through the hub instead (task C8X3)
        method, rc = ("web-go", 0) if web_go(g, client, target) else ("unsupported", 3)
        if rc:
            toast(client, say("view_web_far"))
    elif far:
        method, rc, fm, fl, extra = go_far(vid, fleet, g, target, meta, client)
        meta = dict(meta, machine=fm or meta.get("machine") or "", login=fl or meta.get("login") or "")
    elif not w:
        method, rc = "gone", 4
        toast(client, say("view_gone"))
    else:
        code = webterm_switch(vid, w)
        if code is None:
            code, _ = tm("select-window", "-t", "=%s:%s" % (g, w))
        if code:
            toast(client, say("view_open_elsewhere"))
        method, rc = ("select-window", 0) if code == 0 else ("gone", 4)
    ms = round((time.monotonic() - t0) * 1000, 1)
    rec = {"ts": round(time.time(), 3), "view": vid, "from": before, "to": target,
           "machine": meta.get("machine") or ("" if far else row.get("node") or ""),
           "login": meta.get("login") or ("" if far else getpass.getuser()),
           "method": method, "ms": ms, "how": how}
    rec.update(extra)
    log_switch(rec)
    if rc == 0 and far:
        tell_cur(g)
    if rc == 0 and record:
        hist_save(qo, vid, qo.visit(hist_load(qo, vid), target if not target.startswith("@") else w))
    return rc


def tell_cur(g):
    """The 看台's session in view, to its thin loop (issue #3489): the `cur` hook's
    own mode (fleet-remote-view.sh cur — the one writer of `cur=` and its OSC 7502).
    A switch between two sessions of one other machine stays in ONE peer window, so
    no session-window-changed says it."""
    code, sp = tm("display-message", "-p", "-t", "=%s:" % g, "#{socket_path}")
    if code != 0 or not sp:
        return
    try:
        subprocess.run(["bash", str(Path(__file__).absolute().parent / "fleet-remote-view.sh"), "cur",
                        str(views_dir()), sp, g], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


def do(qo, verb, vid, client="", target=None, new=None):
    """⌘↓ ⌘↑ ⌘[ ⌘] in a 看台 — and C7's ⌘N (new) · ⌘Q (quit) · ⌃\\ (home: this
    machine's command line, EPIC T651 C3; ⌘\\ too) · shell (`--target <row>`: that
    session's, issue #3183). `new`: go_new's repo / agent / prompt (⌘P's ⚡ row,
    issue #3327)."""
    if verb == "home":
        return open_home_shell(qo, vid, client)
    if verb == "new":
        return go_new(qo, vid, client, **(new or {}))
    if verb == "land":
        return land(qo, vid, client)
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

def land_pick(items):
    """(any, pick) for a first screen with nowhere named (task Q1A8): any — the
    person has a session up anywhere (the list's own count, counted_rows: the hub's
    board when fresh, so every machine's; a task record with no session yet is not
    one); pick — the most recently active of them (its `act`, ties in the list's
    order), one whose machine is not lost first. (False, None) ⇒ none at all."""
    rows = [e for e in counted_rows(items).values() if not e.get("record_only")]
    if not rows:
        return False, None
    order = {id(e): n for n, e in enumerate(items)}
    pool = [e for e in rows if not e.get("lost")] or rows
    return True, max(pool, key=lambda e: (int(e.get("act") or 0), -order.get(id(e), 0)))


def land_how():
    """FLEET_VIEW_LAND (the environment, else fleet.conf): `panel` (default) — ⌘P's
    list, its cursor on the pick · `last` — straight onto the pick · `new` — the
    old first screen, a new session every time."""
    how = (conf_word("FLEET_VIEW_LAND") or "panel").strip()
    return how if how in ("panel", "last", "new") else "panel"


def land(qo, vid, client=""):
    """The first screen of an attach with nowhere named to go back to (task Q1A8:
    a phone in Termius, `ssh` to the entry, `fleet connect`, a plain `fleet` whose
    last session is gone): a new session ONLY when the person has none anywhere;
    with one, ⌘P's panel opens on its client, the cursor on the most recently
    active (↵ goes back to it) — or, FLEET_VIEW_LAND=last, the 看台 goes there.
    An explicit new session (the panel's 「新会话」, ⌘N) is go_new as always."""
    how = land_how()
    if how == "new":
        return go_new(qo, vid, client)
    has, pick = land_pick(entries(vid))
    if not has:
        return go_new(qo, vid, client)
    fleet = view_fleet(vid)
    if not fleet:
        return 2
    g = "%s@view-%s" % (fleet, vid)
    if how == "last" and pick is not None and not pick.get("lost"):
        rc = go(qo, vid, pick["target"], "land", client,
                {k: pick.get(k) for k in ("machine", "login") if pick.get(k)})
        if rc in (0, 3):
            return rc
    # the panel needs the client on: an attach's first word comes before it is up
    clients = [client] if client else []
    for _ in range(20):
        if clients:
            break
        _, out = tm("list-clients", "-t", "=" + g, "-F", "#{client_name}")
        clients = [c for c in out.splitlines() if c]
        if not clients:
            time.sleep(0.25)
    if not clients:
        return 1
    c = clients[0]
    _, width = tm("display-message", "-p", "-c", c, "#{client_width}")
    narrow = not width.isdigit() or int(width) < NARROW
    me = os.path.normpath(os.path.abspath(qo.__file__))
    popup_sh = str(Path(me).parent / "dash-popup.sh")
    cmd = ("bash %s --client %s --no-inline --freeze -w %s -h %s --title view_title -- python3 %s --view %s "
           "--client %s --at %s >/dev/null 2>&1 || :") % (
        shlex.quote(popup_sh), shlex.quote(c), "100%" if narrow else "90%", "100%" if narrow else "80%",
        shlex.quote(me), shlex.quote(g), shlex.quote(c), shlex.quote(pick["target"]))
    rc, _ = tm("run-shell", "-b", "-t", g + ":", cmd.replace("#", "##"))
    return 0 if rc == 0 else 1


def go_new(qo, vid, client="", repo="", agent="", prompt="", draft="", t0=""):
    """⌘N (issue #3119): a NEW session — a no-repo one on this machine, in $HOME
    (dash-raw-session.sh --no-repo, the hub's own origin), then go() onto it: the
    pane is the agent's input. No session is special, so nothing here names a
    template. rc as go(); 3 when none opened (one line on the client).
    ⌘P's ⚡ row — the 「新会话」 box (issue #3327, T652) — names its two values:
    `repo` (--repo, else --no-repo) and `agent` (--agent, the box's selection);
    nothing is typed. `draft` (an older panel's words, left unsubmitted) is read
    one more version (compat-1v: 下一批删). Explicit `prompt` callers retain
    seeded starts.
    Every start is clocked (T684, fleet_timing.py's `session`): `t0` is the box's
    ↵ (`--t0`; none ⇒ now), carried down the road as FLEET_TIMING_T0 so each
    stage — record · placed · window · switched · ready · input — is its time
    since that ↵ (T716: `input`, the agent's input box, is the one judged)."""
    fleet = view_fleet(vid)
    if not fleet:
        return 2
    run = fleet_timing.Run("session", fleet_timing_t0(t0))
    os.environ["FLEET_TIMING_T0"] = "%.3f" % run.t0
    if repo and not prompt and new_authority(fleet, vid, repo) == "hub":
        # under hub authority a repo's start is a task record first (issue #4965):
        # a blank one (T652, EPIC T651 C1) is a record titled 「新会话」 with no first
        # turn, renamed by its first prompt. `draft` words: an older panel's send
        # (compat-1v: 下一批删)
        rc = bolt_task(vid, client, repo, agent, draft) if draft else bolt_blank(vid, client, repo, agent)
        if rc == 0:
            new_typeable(run, client)
        return rc
    seam = os.environ.get("FLEET_VIEW_NEW_CMD")
    argv = shlex.split(seam) if seam else ["bash", str(Path(__file__).absolute().parent / "dash-raw-session.sh")]
    chosen = bool(agent)    # the box names both (T670): its choice is the next box's default
    if not agent:
        agent, why = new_agent(fleet, vid)
        if why:
            toast(client, say("view_new_agent_fmt", why, agent.capitalize()), "info")
    named = ["--repo", repo] if repo else ["--no-repo"]
    named += (["--agent", agent] if agent else []) + (["--prompt", prompt] if prompt else [])
    named += ["--draft", draft] if draft else []
    secs = fenv("FLEET_VIEW_NEW_SECS", 60)
    # its refusal is drawn by dash-raw-session.sh itself (fleet_ui_fail) on THIS
    # client, tagged — said once, never re-said here over it (T675)
    tag = notice_tag()
    env = dict(os.environ, FLEET_NOTICE_TAG=tag, **({"FLEET_UI_CLIENT": client} if client else {}))
    try:
        p = subprocess.run(argv + ["--origin", "hub"] + named + ["--print", fleet],
                           stdin=subprocess.DEVNULL, capture_output=True, encoding="utf-8",
                           errors="replace", timeout=secs, env=env)
        rc, w = p.returncode, ((p.stdout.strip().splitlines() or [""])[-1].split("\t") + [""])[0].strip()
        why = new_why(p.stderr, rc)
    except subprocess.TimeoutExpired:
        rc, w, why = 1, "", say("view_new_timeout_fmt", "%g" % secs)
    except OSError as error:
        rc, w, why = 1, "", str(error)
    if rc == 0 and re.fullmatch(r"@[0-9]+", w):
        if chosen and not prompt:
            new_remember(repo, agent)
        went = go(qo, vid, w, "new", client)
        if went == 0:
            new_typeable(run, client)
        return went
    # the reason travels (issue #3458): the notice, and stderr — the ⚡ row's popup
    # shows `do new`'s last line, which was nothing, so the panel said no why. A
    # refusal dash-raw-session.sh already drew (its tag recorded) is not drawn again
    said = say("view_new_failed_fmt", why or say("view_new_exit_fmt", rc))
    if not notice_seen(tag):
        toast(client, said, "error")
    print(said, file=sys.stderr, flush=True)
    return 3


def fleet_timing_t0(t0):
    """`do new --t0`'s ↵ (epoch seconds) when it is a recent number, else None (now)."""
    try:
        t = float(t0)
    except (TypeError, ValueError):
        return None
    return t if 0 <= time.time() - t < 600 else None


def new_typeable(run, client):
    """The 看台 is on the new session: `switched` under the run (T716 — `typeable`
    before); then the person's real wait, the agent's input box (`input`, which
    its relay writes), on the client: 「新会话 N 秒就能打字」. An agent whose
    input box the clock never sees within FLEET_VIEW_INPUT_WAIT (20 s) says
    nothing more — the switch's own time is not that number."""
    run.at("switched")
    secs = fenv("FLEET_VIEW_INPUT_WAIT", 20)
    # the wait is a child of its own: `do new` (its popup waits on it) ends now
    if secs <= 0 or os.environ.get("FLEET_VIEW_INPUT_WAIT_FG") != "1" and os.fork():
        return
    try:
        ms = fleet_timing.wait_seg("session", run.t0, "input", secs)
        if ms is not None:
            toast(client, say("view_new_timing_fmt", "%.1f" % (ms / 1000.0)), "info")
    finally:
        if os.environ.get("FLEET_VIEW_INPUT_WAIT_FG") != "1":
            os._exit(0)


def new_remember(repo, agent):
    """The box's session opened: its repo ("" = 不绑仓库) and agent are the next
    box's defaults — written by fleet-quick-dispatch.py, their one reader (T670).
    Under hub authority its own send remembers them."""
    try:
        subprocess.run([sys.executable, str(Path(__file__).absolute().parent / "fleet-quick-dispatch.py"),
                        "remember", "--repo", repo or "", "--agent", agent], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    except (OSError, subprocess.SubprocessError):
        pass


def new_authority(fleet, vid, repo):
    """The task authority a start of `repo` meets (fleet-quick-dispatch.py
    authority): hub · legacy · frozen, "" when it cannot tell — the old road."""
    try:
        out = subprocess.run([sys.executable, str(Path(__file__).absolute().parent / "fleet-quick-dispatch.py"),
                              "authority", "--repo", repo, "--view", "%s@view-%s" % (fleet, vid)],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    return (out.strip().splitlines() or [""])[-1].strip()


def bolt_task(vid, client, repo, agent, words):
    """go_new's repo + words under hub authority: the ⚡ row's own send (issue #4965)."""
    argv = [sys.executable, str(Path(__file__).absolute().parent / "fleet-quick-dispatch.py"), "send",
            "--title", words, "--repo", repo, "--view", "%s@view-%s" % (view_fleet(vid), vid), "--toast",
            "--draft"] + (["--agent", agent] if agent else []) + (["--client", client] if client else [])
    try:
        return 0 if subprocess.run(argv, stdin=subprocess.DEVNULL).returncode == 0 else 3
    except OSError:
        return 3


def bolt_blank(vid, client, repo, agent):
    """go_new's blank repo session under hub authority (T652): `send --blank` —
    the record, then its session here, the 看台 onto it. rc as go_new."""
    argv = [sys.executable, str(Path(__file__).absolute().parent / "fleet-quick-dispatch.py"), "send", "--blank",
            "--repo", repo, "--view", "%s@view-%s" % (view_fleet(vid), vid)] + \
        (["--agent", agent] if agent else []) + (["--client", client] if client else [])
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, encoding="utf-8", errors="replace",
                           timeout=fenv("FLEET_VIEW_NEW_SECS", 60) + 120)
    except (OSError, subprocess.SubprocessError) as error:
        p = subprocess.CompletedProcess(argv, 1, "", str(error))
    if p.returncode == 0:
        return 0
    last = ((p.stdout or "").strip().splitlines() or (p.stderr or "").strip().splitlines() or [""])[-1]
    said = last or say("view_new_failed_fmt", say("view_new_exit_fmt", p.returncode))
    toast(client, said, "error")
    print(said, file=sys.stderr, flush=True)
    return 3


def new_agent(fleet, vid):
    """⌘N names no agent: ("", "") = the fleet's default, as always. Only when the
    admin's allowlists block one (issue #3826 — fleet_agent_allow.py's cached
    verdict, no hub on the fast path) is ⌘T's rule asked (fleet-quick-dispatch.py
    agent): the default if usable, else the usable one + why, which ⌘N says."""
    try:
        sys.path.insert(0, str(Path(__file__).absolute().parent))
        import fleet_agent_allow
        if not fleet_agent_allow.blocked():
            return "", ""
        out = subprocess.run([sys.executable, str(Path(__file__).absolute().parent / "fleet-quick-dispatch.py"),
                              "agent", "--view", "%s@view-%s" % (fleet, vid)], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, timeout=15).stdout
        got = json.loads((out.strip().splitlines() or ["{}"])[-1])
    except Exception:       # never let the check stop a new session
        return "", ""
    a, why = got.get("agent") or "", got.get("why") or ""
    return (a, why) if why and a in AGENTS else ("", "")


def new_why(err, rc):
    """dash-raw-session.sh's reason for not opening: its last stderr line (a refusal
    is `dash-raw-session: <why>`), the prefix off; "" when it said nothing."""
    lines = [ln.strip() for ln in (err or "").splitlines() if ln.strip()]
    if rc == 0 or not lines:
        return ""
    return re.sub(r"^dash-raw-session:\s*", "", lines[-1])


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


def far_agent(fleet, wid):
    """A far session's agent as the hub's rows say it (global/remote_<fleet>,
    field 7): claude · codex, '' when the row is not there (issue #4184)."""
    try:
        for line in (dash_global() / ("remote_" + fleet)).read_text().splitlines():
            f = line.split(US)
            if f[0] == "wid:" + wid and len(f) > 6:
                return f[6].strip()
    except OSError:
        pass
    return ""


def open_shell(qo, vid, client="", target=None, meta=None):
    r"""⌃\ (#2744's meaning, in a 看台): a SESSION's shell — a login shell on
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
    view: the home shell (open_home_shell). rc 0 · 3 that session is gone (a line
    on the client)."""
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    if not fleet:
        return 2
    g = "%s@view-%s" % (fleet, vid)
    # Web PTYs share the persistent personal home shell (C4), not a shell
    # whose lifetime is a disposable view. The second press returns to the
    # selected worker; direct native clients keep their existing shell road.
    _, home = tm("display-message", "-p", "-t", "=" + g + ":", "#{@view_web_home}")
    if home:
        _, current = tm("display-message", "-p", "-t", "=" + g + ":", "#{window_id}")
        if current == home:
            _, dest = tm("display-message", "-p", "-t", "=" + g + ":{last}", "#{window_id}")
        else:
            dest = home
        code = webterm_switch(vid, dest)
        if code is None:
            code, _ = tm("select-window", "-t", "=%s:%s" % (g, dest))
        return 0 if code == 0 else 3
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
            return open_home_shell(qo, vid, client)
    return shell_window(qo, vid, client, fleet, g, prog, m, l, wid, name)


def open_home_shell(qo, vid, client=""):
    r"""⌘\ · ⌃\ (EPIC T651 C3): the command line of the machine this 看台 lives on —
    this login's login shell in $HOME, from any screen, with no session and no
    hub. ONE window of the 看台's group, marked `@view_shell home`: open ⇒ go to
    it; on it ⇒ back to where you were. A web PTY's persistent home shell (C4)
    keeps its own road (open_shell). rc 0 · 1 the window would not open · 2 no 看台."""
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    if not fleet:
        return 2
    g = "%s@view-%s" % (fleet, vid)
    _, out = tm("display-message", "-p", "-t", "=" + g + ":", "#{@view_web_home}|#{@view_shell}")
    web, vsh = (out.split("|") + [""])[:2]
    if web:
        return open_shell(qo, vid, client)
    if vsh == "home":
        code, _ = tm("last-window", "-t", "=" + g)
        return 0 if code == 0 else 1
    return shell_window(qo, vid, client, fleet, g, "home", here_label(row), getpass.getuser(), "", "")


def shell_window(qo, vid, client, fleet, g, prog, m, l, wid, name):
    r"""The ⌃\ window itself: the one already open for this key in this 看台, else a
    new window running `view-shell <prog>` — a session's (`<machine>@<login>:<wid>`)
    or the home shell (`home`)."""
    key = "%s@%s:%s" % (m, l, wid) if wid else "home"
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
        toast(client, say("view_shell_failed_fmt", m), "error")
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
    r"""`view-shell` — the ⌃\ window's program. here: the session's window (wid)
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
                                             pl.link_host(m, l), cmd], env=env)
        if rc == 3:
            wait_key(say("view_shell_gone_fmt", m))
        elif rc == 255:
            wait_key(say("view_shell_nolink_fmt", m))
        return 0
    d = os.path.expanduser("~")
    if prog == "here":
        d = agent_dir(wid) or d
        # `codex` / `claude` here (issue #3463): the session's own agent is said
        # back to it (fleet-session-shell-agent.sh) — a bare one has no fleet login
        env["FLEET_SESSION_SHELL_WIN"] = wid
        env["PATH"] = bin_dir + "/session-shell:" + path
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


def key_lines(me, extra=None, browser=False):
    """The commands that rebuild both tables: root copied into fleet-view, then the
    看台's keys (issue #3185, EPIC #3178 C7; T685) — by default ONE action, the
    panel: its ⌘ code (User927, ⌘P on the client) and the phone keys FLEET_KEY_PHONE
    (F12 · ⌃] p, T705 — iTerm2's F12 arrives as User933 and goes on to the pane); then what the person added — the clients' FLEET_KEYS_EXTRA (key_extra:
    a ⌘ chord → its action's code, any other chord → that tmux key) and this
    machine's FLEET_KEYS_PHONE_EXTRA (`ctrl+]n=next` → ⌃] n); ⌃] ⌃] always sends
    one ⌃] on. Every other code (the retired ⌘ keys an older profile still sends)
    is caught as a user key and bound to nothing: swallowed."""
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
              for c in sorted(set(codes.values()) | {"924", "926", "930"} | {p[2] for p in fleet_keys.ITERM_PASS})
              if c.isdigit()]
    size = lambda pc: "#{?#{e|<:#{client_width},%d},100%%,%d%%}" % (NARROW, pc)
    popup = str(Path(me).parent / "dash-popup.sh")

    def cmd_of(action, forward=""):
        verb = "do " + action if action in fleet_keys.CODELESS else VIEW_ACTIONS.get(action)
        if verb == "forward":
            forward = forward or action
        if forward:
            verb = "popup"
        if verb == "popup":
            # through the one popup door (dash-popup.sh, issue #3044), from a
            # run-shell, which expands the formats — the old client's road too.
            # Narrower than NARROW columns (a phone, C9): the whole screen.
            # --freeze: the session behind holds still while the list is up — tmux
            # 3.7c bleeds a pane's wrapped CJK through any popup (issue #3058)
            return ("run-shell -b \"bash '%s' --client '#{client_name}' --no-inline --freeze -w %s -h %s --title view_title "
                    "-- python3 '%s' --view '#{session_name}' --client '#{client_name}'%s "  # view-ok: the key's own session IS the 看台
                    ">/dev/null 2>&1 || :\"") % (popup, size(90), size(80), me,
                                                  " --forward %s" % forward if forward else "")
        if verb:
            return ("run-shell -b \"python3 '%s' %s --view '#{session_name}' --client '#{client_name}' "  # view-ok: the 看台
                    ">/dev/null 2>&1 || :\"") % (me, verb)
        return ""

    binds = {}      # (table, key) → command; a later layer wins a key it names again

    def bind(table, key, action, forward=""):
        c = cmd_of(action, forward)
        if c and key:
            binds[(table, key)] = c

    def bind_chord(chord, action):
        if fleet_keys.is_cmd(chord):
            code = codes.get(action, "")
            if code.isdigit():
                bind("fleet-view", "User%s" % code, action)
            elif code == "x1c":
                # ⌘\ sends ⌃\'s byte (dash-keymap.sh): it arrives as ⌃\
                tk = fleet_keys.tmux_key(fleet_keys.HOME_CHORD)
                bind(tk[0], tk[1], action)
        else:
            tk = fleet_keys.tmux_key(chord)
            if tk and tk != ("fleet-view", PFX_KEY) and tk != ("fleet-view-pfx", PFX_KEY):
                bind(tk[0], tk[1], action)

    known = set(VIEW_ACTIONS) | set(fleet_keys.CODELESS)
    for action in defaults:                                   # ⌘P: User927, whatever chord the client picked
        if action in VIEW_ACTIONS and codes.get(action, "").isdigit():
            bind("fleet-view", "User%s" % codes[action], action)
    for chord in fleet_keys.phone():                          # ⌃] p
        bind_chord(chord, "quickopen")
    carried = key_extra() if extra is None else extra
    for action, chord in fleet_keys.pairs(carried, known):
        bind_chord(chord, action)
    for action, chord in fleet_keys.pairs(fleet_keys.phone_extra(), known):
        bind_chord(chord, action)
    # ⌃\ is the terminal's again (T685) — sent on to the pane — unless the person
    # bound it (home=ctrl+\\ or ⌘\); a web PTY's persistent home shell (EPIC T651
    # C4) keeps its own road
    shell_key = fleet_keys.tmux_key(fleet_keys.HOME_CHORD)
    fallback = binds.get(shell_key, "send-keys 'C-\\'")
    binds[shell_key] = "if-shell -F '#{@view_web_home}' { %s } { %s }" % (cmd_of("shell"), fallback)
    # a click on the message row (T701, #[range=user|inbox]) opens ⌘P's 消息 — every
    # other status click stays root's own
    stock = next((l.split("MouseDown1Status", 1)[1].strip() for l in lines
                  if l.startswith("bind-key") and " -T fleet-view " in l and re.search(r"\sMouseDown1Status\s", l)), "")
    page = ("run-shell -b \"bash '%s' --client '#{client_name}' --no-inline --freeze -w %s -h %s --title notice_page_title "
            "-- python3 '%s' page --view '#{session_name}' --client '#{client_name}' >/dev/null 2>&1 || :\"") % (  # view-ok: the 看台
        popup, size(90), size(80), str(Path(me).parent / "fleet_notice.py"))
    binds[("fleet-view", "MouseDown1Status")] = "if-shell -F '#{==:#{mouse_status_range},inbox}' { %s }%s" % (
        page, " { %s }" % stock if stock else "")
    # F12 from iTerm2 (T705): its `fleet` profile sends the code, not F12 — the
    # session's key, handed on; the phone's F12 is FLEET_KEY_PHONE's, above
    for chord, _k, code in fleet_keys.ITERM_PASS:
        binds[("fleet-view", "User%s" % code)] = "send-keys %s" % fleet_keys.tmux_key(chord)[1]
    _OURS[0] = {tk for tk in binds if tk[0] == "fleet-view"}
    for (table, key), c in binds.items():
        lines.append("bind-key -T %s %s %s" % (table, tkey(key), c))
    lines.append("bind-key -T fleet-view %s switch-client -T fleet-view-pfx" % PFX_KEY)
    lines.append("bind-key -T fleet-view-pfx %s send-keys %s" % (PFX_KEY, PFX_KEY))
    # A browser may switch only through the controller's transaction. Root
    # and prefix include unfenced next-window, select-pane and command-prompt.
    if browser:
        lines += ["unbind-key -q -a -T fleet-webterm", "unbind-key -q -a -T fleet-webterm-pfx",
                  "bind-key -T fleet-webterm Any send-keys",
                  "bind-key -T fleet-webterm User927 " + cmd_of("quickopen"),
                  "bind-key -T fleet-webterm 'C-\\' " + cmd_of("shell"),
                  "bind-key -T fleet-webterm C-] switch-client -T fleet-webterm-pfx",
                  "bind-key -T fleet-webterm-pfx p " + cmd_of("quickopen"),
                  "bind-key -T fleet-webterm-pfx C-] send-keys C-]",
                  # root's own wheel (iTerm2's 看台 has it): an app that asked for the
                  # mouse — Claude Code's fullscreen transcript, no tmux history —
                  # scrolls itself; only a plain pane goes into copy-mode (C8X3)
                  "bind-key -T fleet-webterm WheelUpPane if-shell -F '#{||:#{pane_in_mode},#{mouse_any_flag}}'"
                  " { send-keys -M } { copy-mode -e }",
                  "bind-key -T fleet-webterm WheelDownPane send-keys -M"]
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


def view_keys(me, if_stale=False, browser=False):
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
        lines = key_lines(me, browser=browser)
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
        lines = key_lines(me, browser=browser)
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
# (fleet_view.py ACTIONS) is one ACTIONS entry — `id` · `label(row)` · `when(row)`
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
    """What a local row's window says now: pin · agent · the
    needs kind · @fleet_id · its name · the wrapper's page up · its PR."""
    t = e.get("target") or ""
    if e.get("far"):
        # another machine's: what it asks is all the panel needs to know (a
        # permission prompt is y / n; fleet-row-remote.sh reads the rest), and
        # which agent it runs — 换 Codex / 换 Claude names the other (issue #4184)
        return {"needs": ("perm" if e.get("detail") == "perm" else "ask") if e.get("state") == "needs" else "",
                "pin": e.get("group") == "pin", "agent": far_agent(fleet, t) or "claude"}
    if not t.startswith("@"):
        return {}
    rc, out = tm("display-message", "-p", "-t", t, "#{window_id}|#{@pin}|"
                 "#{@cc_agent}|#{@claude_needs}|#{@fleet_id}|#{window_name}|#{@wrap_exit_rc}|#{pane_id}|#{@task}")
    f = (out.split("|") + [""] * 9)[:9] if rc == 0 else [""] * 9
    if f[0] != t:     # tmux answers a gone id with another window's format
        return {"gone": True}
    pr, pr_url = task_pr(fleet, f[8])
    return {"pin": f[1] == "1", "agent": f[2] or "claude", "needs": f[3],
            "fid": f[4], "wname": f[5], "page": f[6] != "", "pane": f[7], "pr": pr, "pr_url": pr_url}


PR_REF = re.compile(r"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([1-9][0-9]*)$")


def task_pr(fleet, task):
    """A session's PR, off its hub task record (issue #4902): (`#N`, its URL), or
    ("?", "") when the hub did not answer — the row says it does not know, it
    never asks GitHub — or ("", "") for no record, no PR on it, or no hub here
    (fleet-task-record.sh exit 3). FLEET_VIEW_PR_TIMEOUT (3 s) bounds the read."""
    if not re.match(r"^T[1-9][0-9]*$", task or ""):
        return "", ""
    secs = fenv("FLEET_VIEW_PR_TIMEOUT", 3)
    env = dict(act_env(fleet), FLEET_HUB_TIMEOUT=str(secs))
    try:
        seam = os.environ.get("FLEET_VIEW_TASK_GET", "")
        p = subprocess.run(seam.split() + [task] if seam else sh("fleet-task-record.sh", "get", task),
                           capture_output=True, text=True,
                           timeout=secs + 1, env=env, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return "?", ""
    if p.returncode == 3:
        return "", ""
    try:
        rec = json.loads(p.stdout) if p.returncode == 0 else None
    except ValueError:
        rec = None
    if not isinstance(rec, dict):
        return "?", ""
    m = PR_REF.match(str((rec.get("task") or {}).get("pr") or ""))
    if not m:
        return "", ""
    return "#" + m.group(2), "https://github.com/%s/pull/%s" % (m.group(1), m.group(2))


def pr_label(r):
    if r.get("pr") == "?":
        age = hub_age()
        return say("view_act_pr_unknown_fmt", max(1, int(age) // 60)) if age is not None and age > 60 \
            else say("view_act_pr_unknown")
    return say("view_act_pr_fmt", r.get("pr"))


def live(r):
    return not r.get("far") and not r.get("gone") and r.get("state") not in ("exited",)


def ended(r):
    return bool(r.get("ended")) or r.get("sec") == "gone"


def other_agent(r):
    return "Claude" if r.get("agent") == "codex" else "Codex"


REAP_CHOICES = (("merged", "reap_menu_merged"), ("done:15m", "reap_menu_done_15m"), ("loop-end", "reap_menu_loop_end"),
                ("at", "reap_menu_at"), ("keep", "reap_menu_keep"))


def reap_choices(r, fleet):
    cur = (r.get("reap") or "").partition(":")[0]
    return [(v, ("● " if cur and cur == v.partition(":")[0] else "") + say(k)) for v, k in REAP_CHOICES]


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
    (fleet-row-remote.sh <action> <fleet> wid:<worker_id>); the answer rides
    FLEET_SIDEBAR_TEXT (act_run)."""
    return lambda r, a, f: sh("fleet-row-remote.sh", action, f, "wid:" + r["target"])


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
    # the ONE place a row's PR shows (issue #4902): its hub task record's, read
    # when the menu opens (facts); `?` when the hub did not answer. far None
    # (issue #4184): another machine's row carries no task record here
    {"id": "pr", "label": pr_label, "when": lambda r: bool(r.get("pr")),
     "local": lambda r, a, f: "pr-unknown" if r.get("pr") == "?" else sh("open-url.sh", r.get("pr_url") or ""),
     "far": None, "ask": None},
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
    # another machine's row (issue #3517): a hub write — @pin on its own machine
    {"id": "pin", "label": lambda r: say("view_act_unpin" if r.get("pin") else "view_act_pin"),
     "when": lambda r: not r.get("gone"),
     "local": lambda r, a, f: sh("dash-pin-toggle.sh", r["target"]),
     "far": lambda r, a, f: sh("fleet-row-remote.sh", "pin", f, "wid:" + r["target"]), "ask": None},
    {"id": "reappol", "label": lambda r: say("view_act_reappol"), "when": lambda r: not r.get("gone"),
     "local": reappol_local, "far": far("reappol"), "ask": "choice", "choices": reap_choices,
     "then": {"at": ("text", lambda r: say("view_ask_at"))}},
    {"id": "stop", "label": lambda r: say("view_act_stop"),
     "when": lambda r: (live(r) and bool(r.get("fid"))) or far_live(r),
     "local": lambda r, a, f: sh("fleet-worker-stop.sh", f, "fid:" + r["fid"]), "far": far("stop"), "ask": None,
     "slow": True},
    {"id": "resume", "label": lambda r: say("view_act_restore" if ended(r) else "view_act_resume"),
     "when": lambda r: (r.get("gone") and not r.get("ledger")) or (r.get("state") == "exited" and (r.get("far") or r.get("page"))),
     "local": lambda r, a, f: "restore" if r.get("gone") else "resume", "far": far("resume"), "ask": None,
     "slow": True, "keys": "yYrR"},
    # another machine's row (issue #4184): the hub's worker_transfer — the same
    # fleet-transfer.sh, run on that machine, its --dry-run's refusal said here
    {"id": "agent", "label": lambda r: say("view_act_agent_fmt", other_agent(r)),
     "when": lambda r: live(r) or far_live(r),
     "local": lambda r, a, f: sh("fleet-transfer.sh", "--from-panel", "--session", f, "--window", r["target"], "--to",
                                 other_agent(r).lower()),
     "far": far("agent"), "ask": None, "slow": True},
    # 在 WebChat 里继续 (task T810): this login's own session only — another
    # machine's, or a Codex one before the page has Codex, is shown grey with why
    {"id": "webchat", "label": lambda r: say("view_act_webchat"),
     "when": lambda r: (live(r) and bool(r.get("fid"))) or far_live(r),
     "local": lambda r, a, f: sh("fleet-webchat-handoff.sh", "to-web", "fid:" + r["fid"]),
     "far": lambda r, a, f: ["bash", "-c", 'printf "%s\\n" "$1" >&2; exit 2', "_", webchat_why(r)], "ask": None},
    {"id": "reap", "label": lambda r: say("view_act_reap"), "when": lambda r: not r.get("gone"),
     "local": lambda r, a, f: sh("dash-reap.sh", r["target"], "--yes"), "far": far("reap"), "ask": "key",
     "prompt": lambda r: say("view_ask_reap_fmt", r.get("text") or r.get("name") or r["target"]), "keys": "yYnN",
     "yes": True, "slow": True},
    # row-less (issue #3180, C2; #3327): the panel's ⚡ and ⏻ rows, never a Tab menu's
    # — the ⚡ row's ↵ is the popup's own (its cells, its progress: bolt_job)
    {"id": "new", "label": lambda r: say("view_cmd_blank"), "when": lambda r: True, "rowless": True,
     "local": lambda r, a, f: "new", "far": None, "ask": None},
    # 退出 asks first (T685: it is a row now, not ⌘Q — one ↵ too many must not end it)
    {"id": "quit", "label": lambda r: say("view_cmd_quit"), "when": lambda r: True, "rowless": True,
     "local": lambda r, a, f: "quit", "far": None, "ask": "key", "prompt": lambda r: say("view_ask_quit"),
     "keys": "yYnN", "yes": True},
    # $ 命令行 (T685, T774; EPIC T651 C3's ⌘\ before): this machine's shell in $HOME
    {"id": "home", "label": lambda r: say("view_cmd_home"), "when": lambda r: True, "rowless": True,
     "local": lambda r, a, f: "home", "far": None, "ask": None},
    # ✦ 消息 (T675, T701): every message in the one book — the popup's Enter opens the page
    {"id": "notices", "label": lambda r: say("view_notices_row"), "when": lambda r: True, "rowless": True,
     "local": lambda r, a, f: "notices", "far": None, "ask": None},
    # the interface language (issue #3329): ↵ flips it, Tab offers 跟系统走 too
    {"id": "lang", "label": lambda r: say("view_lang_row"), "when": lambda r: True, "rowless": True,
     "local": lambda r, a, f: "lang", "far": None, "ask": None,
     "choices": lambda r, f: [("zh", "中文"), ("en", "English"), ("auto", say("view_lang_auto"))]},
    # the 排队中 group's last row (issue #3731, 回收 D): every session in it, each
    # through its own row's reap (dash-reap.sh --yes: a dirty worktree kept, a live
    # one skipped) — off the screen's thread, the line it prints said after
    {"id": "reapall", "label": lambda r: say("view_act_reapall"), "when": lambda r: True, "rowless": True,
     "local": lambda r, a, f: sh("fleet-view-reap-all.sh", f, *r["targets"]), "far": None, "ask": "key",
     "prompt": lambda r: say("view_ask_reapall_fmt", len(r["targets"])), "keys": "yYnN", "yes": True,
     "slow": True, "thread": True},
    # the 已关闭 group's last row: the older ones are /fleet-history's — its list,
    # in this terminal (fleet-restore-pick.sh --pick: ↵ there restores one)
    {"id": "history", "label": lambda r: say("view_act_history"), "when": lambda r: True, "rowless": True,
     "local": lambda r, a, f: "history", "far": None, "ask": None},
]
ACTION = {a["id"]: a for a in ACTIONS}
# The sidebar menu's letters (fleet-ui-lang.sh menu_keys) → the action here; the
# row-less ones (no row to act on) live elsewhere — the list's top lines (C2), the
# client's own keys (C7). fleet-view-actions-selftest.sh holds the two lists in step.
SIDEBAR_ACTIONS = {"rename": "rename", "pin": "pin", "pr": "pr", "answer": "answer",
                   "reappol": "reappol", "agent": "agent", "reap": "reap", "open": "enter",
                   "message": "message", "stop": "stop", "resume": "resume", "restore": "resume"}
ROWLESS = {"new": "C2", "newto": "C2", "repo": "C2", "clients": "C7", "quit": "C7", "home": "T685", "notices": "T675", "lang": "#3329",
           "reapall": "#3731", "history": "#3731"}


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
    if r.get("record_only"):
        return []     # a record with no session yet (A4G2): nothing to act on here
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


# The actions page (plan B, T486 v14 §2): five, in this order — the rest stay
# in ACTIONS for `fleet view-act` and the command line, and are done from
# elsewhere (进入 answers and resumes; ⌃\ the shell; ⌃T the pin). A
# reaped session's one item is 恢复.
PAGE_ACTIONS = ("resume", "enter", "pr", "rename", "agent", "webchat", "reap")


def page_of(r, missing=None):
    """The actions page of row `r`: [(action, label, why)] in PAGE_ACTIONS order;
    `why` non-empty = shown grey, unnumbered, skipped — the switch to an agent
    this machine lacks (`missing`: grid_read's {agent: why})."""
    have = {a["id"]: (a, label) for a, label in menu_of(r)}
    out = []
    for aid in PAGE_ACTIONS:
        if aid not in have or (aid == "resume" and not r.get("gone")):
            continue
        a, label = have[aid]
        why = ""
        if aid == "agent":
            why = str((missing or {}).get(other_agent(r).lower(), "") or "")
        if aid == "webchat":
            why = webchat_why(r)
        out.append((a, label, why))
    return out


def webchat_why(r):
    """Why 「在 WebChat 里继续」 cannot run for row `r` ("" = it can): WebChat
    adopts a session of THIS login only (task T810); a Codex one too since the
    page has a Codex side (R9A2) — FLEET_WEBCHAT_CODEX=0 turns that off."""
    if r.get("far"):
        return say("view_webchat_why_far")
    if r.get("agent") == "codex" and os.environ.get("FLEET_WEBCHAT_CODEX", "1") != "1":
        return say("view_webchat_why_codex")
    return ""


def act_ask(a, r):
    ask = a["ask"]
    return ask(r) if callable(ask) else ask


def history_pick(screen, fleet):
    """/fleet-history's list in the popup's own terminal (issue #3731): curses
    steps aside, fleet-restore-pick.sh --pick runs (fzf over every closed session;
    ↵ restores one, esc comes back), curses resumes. Its rc: 0 = a session was
    restored (and is current now)."""
    curses.def_prog_mode()
    curses.endwin()
    try:
        rc = subprocess.run(sh("fleet-restore-pick.sh", "--pick", "--session", fleet), env=act_env(fleet)).returncode
    except OSError:
        rc = 1
    curses.reset_prog_mode()
    screen.clear()
    return rc


def act_run(qo, vid, fleet, a, r, ans, client="", wait=True):
    """Do one action: (rc, the line to say, went — the 看台 is on the row now).
    `wait` False runs a slow one in the background (the popup does not freeze on
    a reap)."""
    fn = a["far"] if r.get("far") else a["local"]
    argv = fn(r, ans, fleet)
    label = a["label"](r).rstrip("…")
    if argv == "pr-unknown":
        return 1, pr_label(r), False
    if argv in ("go", "shell") and lost_msg(r):
        return 1, lost_msg(r), False
    if argv == "go":
        rc = go(qo, vid, r["target"], "menu", client, r)
        return rc, "" if rc == 0 else far_miss(vid, r, rc), rc == 0
    if argv == "shell":
        # C5's road (issue #3183): a shell beside that session, where its agent is
        rc = open_shell(qo, vid, client, r["target"], r)
        return rc, "" if rc == 0 else (say("view_gone") if rc == 3 else
                                       say("view_shell_failed_fmt", r.get("machine") or "?")), rc == 0
    if argv == "quit":
        rc = quit_view(vid, client)
        return rc, "", rc == 0
    if argv == "home":
        rc = open_home_shell(qo, vid, client)
        return rc, "" if rc == 0 else say("view_shell_failed_fmt", here_label(view_row(vid))), rc == 0
    if argv == "notices":
        return 0, "", False     # the popup opens the page itself (notices_pick)
    if argv == "lang":
        rc, said = lang_set(fleet, ans)
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
        # a hub write (fleet-row-remote.sh): nothing goes out for a lost row
        if r.get("lost"):
            return 1, say("view_lost_act_fmt", r.get("machine") or "?"), False
        env.update(FLEET_SIDEBAR_TEXT=ans, FLEET_REMOTE_SAY="print")
        try:
            p = subprocess.run(argv, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=150,
                               start_new_session=True)
        except (OSError, subprocess.TimeoutExpired):
            return 1, say("view_act_failed_fmt", label, ""), False
        said = ((p.stdout.strip() or p.stderr.strip()).splitlines() or [""])[-1]
        if p.returncode == 0 and a["id"] == "rename" and ans.strip():
            name_hold(fleet, r["target"], ans.strip())
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


# --- the interface language (issue #3329, EPIC #3178 D7) ------------------------------

def ui_lang():
    """zh | en — the language fleet-ui-lang.sh draws in right now."""
    try:
        out = subprocess.run(["sh", str(Path(__file__).absolute().parent / "fleet-ui-lang.sh"), "lang"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    return out if out in ("zh", "en") else "zh"


_LANG_NONE = []


def lang_said_none():
    """The 看台's client brought no language (D6/D9: the door kept none) and the
    person never chose one — what the row's footer explains how to fix. Asked
    once per popup (lang_set asks again)."""
    if _LANG_NONE:
        return _LANG_NONE[0]
    none = False
    if os.environ.get("FLEET_VIEW_LANG", "-") in ("", "C", "POSIX"):
        try:
            none = subprocess.run(["sh", "-c", '. "$1"; fleet_ui_person_lang >/dev/null', "-",
                                   str(Path(__file__).absolute().parent / "fleet-ui-lang.sh")],
                                  capture_output=True, timeout=5).returncode != 0
        except (OSError, subprocess.TimeoutExpired):
            none = False
    _LANG_NONE.append(none)
    return none


def lang_set(fleet, want=""):
    """(rc, line): `want` zh · en · auto (跟系统走), "" flips the one in use. Kept
    on the hub under the person — fleet-config.py lang, which re-reads this
    computer's copy at once — and every word after it is drawn in the new one."""
    want = want or ("en" if ui_lang() == "zh" else "zh")
    try:
        p = subprocess.run([sys.executable, str(Path(__file__).absolute().parent / "fleet-config.py"), "lang", want],
                           capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
        rc, why = p.returncode, ((p.stderr.strip() or p.stdout.strip()).splitlines() or [""])[-1]
    except (OSError, subprocess.TimeoutExpired) as error:
        rc, why = 1, str(error)
    if rc != 0:
        return 1, say("view_lang_failed_fmt", one_line(why.replace("fleet config · ", ""), 120))
    _WORDS.clear()
    del _LANG_NONE[:]
    return 0, say("view_lang_auto_saved" if want == "auto" else "view_lang_saved")


def view_lang_env(vid):
    """The 看台's client language into this process's environment when the popup
    was not handed it (fleet-remote-view.sh puts FLEET_VIEW_LANG in the 看台
    session's environment; `@view_lang_set` says the door recorded one)."""
    if "FLEET_VIEW_LANG" in os.environ:
        return
    rc, out = tm("display-message", "-p", "-t", "=%s@view-%s:" % (view_fleet(vid), vid),
                 "#{@view_lang_set}|#{@view_lang}")
    said, _, lang = (out or "").partition("|")
    if rc == 0 and said == "1":
        os.environ["FLEET_VIEW_LANG"] = lang


def lang_row(query):
    """「◐ 语言 / Language」 (issue #3329) — when there are no words, or they name it."""
    text = "◐ " + say("view_lang_row")
    q = query.strip().lower()
    if q and not all(w in text.lower() for w in q.split()):
        return None
    return {"kind": "cmd", "cmd": "lang", "act": "lang", "row": {}, "text": text,
            "foot": say("view_lang_nolang_fmt", here_label({})) if lang_said_none() else say("view_lang_foot")}


def compose_title(cells):
    """The 「新会话」 box's first line (T774): ⚡ 新会话, its icon in the one column."""
    return cmd_line("⚡ " + say("view_composer"), cells)


def notices_row(query):
    """「✦ 消息 N」 (T675, T701): every reminder in the one book — asking you, stuck,
    done, an alert, a result nobody took, a notice — N the ones not seen yet, on any
    machine; the panel's FIRST row, and what the words 消息 / message find."""
    try:
        sys.path.insert(0, str(Path(__file__).absolute().parent))
        import fleet_notice
        n = fleet_notice.unread()
    except Exception:
        n = 0
    text = msg_glyphs()["inbox"] + " " + (say("view_notices_row_fmt", n) if n else say("view_notices_row"))
    q = query.strip()
    if q and not panel_hit(q, text, say("view_notices_words")):
        return None
    return {"kind": "cmd", "cmd": "notices", "act": "notices", "row": {}, "text": text,
            "foot": say("view_notices_foot"), "hit": bool(q)}


def notices_pick(screen, vid="", client=""):
    """「✦ 消息」 in the popup's own terminal (T675, T701): curses steps aside,
    bin/fleet_notice.py's page runs, curses resumes. True when the page took the
    看台 to a message's session (its exit 3): the popup closes."""
    curses.def_prog_mode()
    curses.endwin()
    rc = 0
    try:
        rc = subprocess.run([sys.executable, str(Path(__file__).absolute().parent / "fleet_notice.py"), "page"]
                            + (["--view", vid] if vid else []) + (["--client", client] if client else [])).returncode
    except OSError:
        pass
    curses.reset_prog_mode()
    screen.clear()
    return rc == 3


def pin_row(items, query, cur):
    """「置顶当前会话」 / 「取消置顶当前会话」 (issue #3517) — the session in view, as
    the list's 置顶 group has it; when there are no words, or they name it. None
    with no session in view (or one already over)."""
    e = next((x for x in items if x["kind"] == "sess" and cur and x.get("target") == cur), None)
    if e is None or e.get("gone") or e.get("ended"):
        return None
    text = say("view_unpin_current" if e.get("group") == "pin" else "view_pin_current")
    q = query.strip().lower()
    if q and not all(w in (text + " pin top 置顶").lower() for w in q.split()):
        return None
    return {"kind": "cmd", "cmd": "pin", "act": "pin", "row": e, "text": text,
            "foot": say("view_pin_foot_fmt", label_of(e))}


# --- the panel's ⚡ and ⏻ rows (issue #3180, EPIC #3178 C2; issue #3327 ④) ---------------

PANEL_WORDS = ("new", "quit", "landed")


def conf_word(key):
    """A setting the panel reads: the environment, else fleet.conf's line —
    fleet-conf.sh line's own grep, without its bash and shell library (issue #3514:
    ~50 ms before every ⌘P's first frame): the lines of fleet.conf that set it,
    the last one wins. '' when neither has it."""
    raw = os.environ.get(key)
    if raw is not None:
        return raw
    conf = os.path.join(os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet"), "fleet.conf")
    try:
        with open(conf, encoding="utf-8", errors="replace") as fh:
            line = "".join(l for l in fh if re.match(r"[ \t]*(export[ \t]+)?%s=" % key, l))
    except OSError:
        line = ""
    m = re.search(r"%s=(['\"]?)([^'\"\n]*)\1" % key, line.strip().splitlines()[-1] if line.strip() else "")
    return m.group(2) if m else ""


def panel_commands():
    """FLEET_PANEL_COMMANDS (the environment, else fleet.conf's line; default
    `new quit`): new (the ⚡ row and its cells) and quit (⏻) are always there —
    the words are accepted, in any order —, landed moves the 刚落地 group first,
    `none` takes ⚡ and ⏻ away. The old `shell` / `newsess` are read and dropped
    (issue #3327: the shell is the row's Tab, a blank session is ⚡ on no words)."""
    words = conf_word("FLEET_PANEL_COMMANDS").replace(",", " ").split()
    if "none" in words:
        return []
    return ["new", "quit"] + (["landed"] if "landed" in words else [])


def label_of(e):
    """A session as the keys line names it: #N, else its title's first 12 cells."""
    issue = ((e or {}).get("issue") or "").lstrip("#")
    if issue:
        return "#" + issue
    title = (e or {}).get("text") or (e or {}).get("name") or ""
    return title[:12] + "…" if len(title) > 12 else title


def landed_first(items):
    """The 排队中 group (刚落地's heir: plan B's 做完待收, 回收 D) moved above the
    others (`landed` in FLEET_PANEL_COMMANDS)."""
    i = next((n for n, e in enumerate(items) if e["kind"] == "hdr" and e.get("group") == "queue"), -1)
    if i < 0:
        return items
    j = next((n for n in range(i + 1, len(items)) if items[n]["kind"] in ("hdr", "sec")), len(items))
    return items[i:j] + items[:i] + items[j:]


AGENTS = ("claude", "codex")


def grid_read(vid, repo=""):
    """The 「新会话」 box's values as fleet-quick-dispatch.py grid reads them — its
    defaults() is the one reader (T670, EPIC T651 C2; the panel only shows):
    {repos (every repo the hub names), last (the box's repo: `repo` — the session
    in view's — else the last new session's), agent (the fleet's default), agents
    ({repo: the agent it last opened with, else the default}), missing ({agent:
    why} this machine lacks, or the admin has not opened — issue #3826), blocked
    (those last ones)}."""
    g = {"repos": [], "last": "", "agent": "claude", "agents": {}, "missing": {}, "blocked": []}
    argv = [sys.executable, str(Path(__file__).absolute().parent / "fleet-quick-dispatch.py"), "grid",
            "--view", "%s@view-%s" % (view_fleet(vid), vid)] + (["--repo", repo] if repo else [])
    try:
        out = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10).stdout
        got = json.loads((out.strip().splitlines() or ["{}"])[-1])
        if isinstance(got, dict):
            g.update({k: v for k, v in got.items() if k in g and v is not None})
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass
    return g


def view_repo(vid, cur="", items=()):
    """The repo of the session in view (`cur`, current()'s): a window here says
    its @repo (owner/name); another machine's row its short name, which grid
    resolves against the hub's list. "" when it has none."""
    if not cur:
        return ""
    if cur.startswith("@"):
        rc, out = tm("display-message", "-p", "-t", cur, "#{@repo}")
        if rc == 0 and SLUG_RE.match(out.strip()):
            return out.strip()
    e = next((e for e in items if e.get("kind") == "sess" and e.get("target") == cur), None)
    return (e or {}).get("repo") or ""


def bolt_new(g=None):
    """The ⚡ row's state: the cells read (`g`), what the person changed — `repo`
    None is the pick (the last send's repo, else the only one), `agent` None is the
    fleet's default — and the cell Tab is on ('' · repo · agent).
    No `g` yet (the popup reads it off its thread): not `ready` — the repo cell
    says …, and a ↵ waits for the read rather than guess 不绑仓库."""
    return {"g": g or {"repos": [], "last": "", "agent": "claude", "agents": {}, "missing": {}, "blocked": []},
            "repo": None, "agent": None, "focus": "", "ready": g is not None}


def bolt_repo(st, query=""):
    """The box's repo: the person's choice, else the pick (the last send's repo,
    else the only one) — the 「新会话」 box opens chosen (T652)."""
    if st["repo"] is not None:
        return st["repo"]
    return st["g"].get("last") or ""


def bolt_dflt(st):
    a = st["g"].get("agent") or "claude"
    return a if a in AGENTS else "claude"


def bolt_usable(st):
    miss = st["g"].get("missing") or {}
    return [a for a in AGENTS if a not in miss] or [bolt_dflt(st)]


def bolt_agent(st):
    if st["agent"] is not None:
        return st["agent"]    # an explicit selection is never silently reassigned
    # the repo's own (the agent it last opened with — T670), else the fleet's
    a = (st["g"].get("agents") or {}).get(bolt_repo(st)) or bolt_dflt(st)
    use = bolt_usable(st)
    return a if a in use else use[0]


def bolt_step(st, query, d):
    """←→ on the cell Tab is on: the next repo (不绑仓库 is one) / usable agent."""
    if not st.get("ready", True):
        return      # the cells are not read yet: nothing to step through
    if st["focus"] == "repo":
        opts = [""] + [r for r in st["g"].get("repos") or [] if r]
        cur = bolt_repo(st, query)
        i = opts.index(cur) if cur in opts else 0
        st["repo"] = opts[(i + d) % len(opts)]
    elif st["focus"] == "agent":
        use = bolt_usable(st)
        cur = bolt_agent(st)
        i = use.index(cur) if cur in use else 0
        st["agent"] = use[(i + d) % len(use)]


def bolt_cells(st, query):
    """([(text, focused)], note): 仓库 ‹…› · Agent ‹…›, and why an agent is grey."""
    repo = bolt_repo(st, query) if st.get("ready", True) or st["repo"] is not None else "…"
    cells = [("%s ‹%s›" % (say("view_grid_repo"), repo or say("view_grid_norepo")), st["focus"] == "repo"),
             ("%s ‹%s›" % (say("view_grid_agent"), bolt_agent(st).capitalize()), st["focus"] == "agent")]
    miss = st["g"].get("missing") or {}
    note = " · ".join(str(why) for why in miss.values())
    use = [a for a in AGENTS if a not in miss]
    if st["g"].get("blocked") and len(use) == 1:
        # one agent left (issue #3826): it is the one, and the row says so
        note += " · " + say("view_grid_only_fmt", use[0].capitalize())
    return cells, note


def panel_rows(items, query, opened, cmds=None, bolt=None, busy=None, cur=""):
    """The full-width list projection. Composer controls belong to the overlay,
    never inserted rows; search words may seed an empty draft on explicit open.
    `busy` is retained for the command-line projection; the popup keeps its list
    geometry and shows progress in the feedback line (#4416)."""
    words = panel_commands() if cmds is None else cmds
    if "landed" in words:
        items = landed_first(items)
    q = query.strip()
    rows = visible(items, query, opened)
    # ONE order (T762): what is drawn top to bottom is what ↓ walks and ↑ walks
    # back — ✦ 消息 · ⚡ 新会话 · $ 命令行 on top, the sessions, then 置顶 · ◐ · ⏻
    top, bottom = [], []
    nr = notices_row(query) if words else None
    if nr:
        top.append(nr)      # the FIRST row (T701): every message is two steps away
    if "new" in words:
        st = bolt or bolt_new()
        if busy:
            top.append({"kind": "cmd", "cmd": "new", "act": "new", "row": {}, "busy": True,
                        "text": say("view_task_starting_fmt", busy["title"]) if busy["title"] else say("view_task_opening")})
        else:
            hit = any(e["kind"] == "sess" for e in rows)
            top.append({"kind": "cmd", "cmd": "new", "act": "new", "row": {},
                        "text": say("view_cmd_blank"),
                        "foot": say("view_nomatch") if q and not hit else ""})
    if "quit" in words and (not q or panel_hit(q, say("view_cmd_home"), HOME_WORDS)):
        # $ 命令行 (T685, T774): typed words that name it keep it in view, lit
        top.append({"kind": "cmd", "cmd": "home", "act": "home", "row": {}, "text": say("view_cmd_home"),
                    "foot": say("view_cmd_home_foot"), "hit": bool(q)})
    pr = pin_row(items, query, cur) if words else None
    if pr:
        bottom.append(pr)   # under the sessions (issue #3517)
    lr = lang_row(query) if words else None
    if lr:
        bottom.append(lr)   # above ⏻ (issue #3329)
    if "quit" in words:
        bottom.append({"kind": "cmd", "cmd": "quit", "act": "quit", "row": {}, "text": say("view_cmd_quit"),
                       "hit": bool(q) and panel_hit(q, say("view_cmd_quit"), QUIT_WORDS)})
    out = top + rows + bottom
    return out


# the words that name the panel's own rows besides their label (T685: the keys
# they replaced are gone, so typing is the other road straight to them)
HOME_WORDS = "home shell terminal 回家 命令行 终端 本机 ⌘\\"
QUIT_WORDS = "quit exit 退出 ⌘q"


def panel_hit(q, text, extra=""):
    """Every typed word is in the row's label or its extra words."""
    hay = (text + " " + extra).lower()
    return all(w in hay for w in q.lower().split())


def bolt_argv(qo, vid, client, st, query=""):
    """The 「新会话」 box's 开 (T652, EPIC T651 C1): ONE road, `do new` (go_new) with
    the repo and agent — nothing typed, no draft, no first turn. Under hub
    authority go_new makes a repo's start a record titled 「新会话」 first."""
    repo, agent = bolt_repo(st), bolt_agent(st)
    cl = ["--client", client] if client else []
    argv = [sys.executable, qo.__file__, "do", "new", "--view", vid] + cl + (["--repo", repo] if repo else []) \
        + ["--agent", agent, "--t0", "%.3f" % time.time()]
    return argv, "", " · ".join((repo or say("view_grid_norepo"), agent.capitalize()))


def bolt_run(argv, done):
    """Run it in its own session (esc closes the popup; the job goes on and says
    how it ended itself) and hand (rc, its last line) to `done`. Its output goes
    to an unlinked file, never a pipe a closed popup would break."""
    tag = notice_tag()

    def run():
        import tempfile
        try:
            with tempfile.TemporaryFile() as out:
                p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                     start_new_session=True, env=dict(os.environ, FLEET_NOTICE_TAG=tag))
                rc = p.wait(timeout=fenv("FLEET_VIEW_NEW_SECS", 60) + 30)
                out.seek(0)
                lines = out.read().decode("utf-8", "replace").strip().splitlines()
            done.append((rc, lines[-1] if lines else ""))
        except (OSError, subprocess.TimeoutExpired) as error:
            rc, lines = 1, [str(error)]
            done.append((1, str(error)))
        # its output is not thrown away (T675): a failure nobody recorded is put in
        # the record, its last lines — what the popup showed, if it was still up
        if rc != 0 and not notice_seen(tag):
            try:
                import fleet_notice
                fleet_notice.notify("error", " · ".join(lines[-3:]) or say("view_new_exit_fmt", rc),
                                    source="⚡", draw_it=False, tag=tag)
            except Exception:
                pass
    threading.Thread(target=run, daemon=True).start()


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


def panel_key(screen, timeout_ms, completed=None, inputs=None):
    read = screen.get_wch if inputs is None else lambda: inputs.read(screen)
    if completed is None:
        screen.timeout(timeout_ms)
        return read()
    deadline = time.monotonic() + timeout_ms / 1000
    while True:
        remaining = deadline - time.monotonic()
        if completed or remaining <= 0:
            raise curses.error()
        screen.timeout(min(50, max(1, int(remaining * 1000))))
        try:
            return read()
        except curses.error:
            if completed or time.monotonic() >= deadline:
                raise


# --- the popup -------------------------------------------------------------------------

# --- one key, ⌘P (T685, 操作者 2026-10-20; after issue #3328) --------------------------------
# #3328 kept ⌘↓ ⌘↑ ⌘[ ⌘] ⌘N ⌘T ⌘Q ⌘K as forwards to the panel; T685 gave them back to
# iTerm2 (fleet_keys.RETIRED): an older profile's code is swallowed, nothing opens.
# The one message below says so once per login.
KEYS_NOTICE = "keys-notice-T685"
# T762 moved ⚡ 新会话 and $ 命令行 to the top (⌘P ↑ ↵ no longer reaches ⚡ from the
# list's top): the footer says so for a week from the first ⌘P that drew it
ORDER_NOTICE, ORDER_NOTICE_SECS = "panel-order-T762", 7 * 86400


def order_notice(now=None):
    """「新会话、命令行在最上面」 for ORDER_NOTICE_SECS after this login first saw
    the new order; "" after that (or when the file cannot be kept)."""
    now = time.time() if now is None else now
    path = conf_dir() / ORDER_NOTICE
    try:
        first = float(path.read_text().split()[0])
    except (OSError, ValueError, IndexError):
        first = now
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("%d\n" % now)
        except OSError:
            return ""
    return say("view_order_moved") if now - first < ORDER_NOTICE_SECS else ""


def keys_notice(vid, client=""):
    """The one message after the update that left ⌘P the only key (T685; #3328
    before): on this 看台's client, once per login — 「fleet 只用 ⌘P，其余都在面板里」."""
    path = conf_dir() / KEYS_NOTICE
    if path.exists():
        return 0
    fleet = view_fleet(vid)
    if not fleet:
        return 2
    if client:
        clients = [client]
    else:
        _, out = tm("list-clients", "-t", "=%s@view-%s" % (fleet, vid), "-F", "#{client_name}")
        clients = [c for c in out.splitlines() if c]
    if not clients:
        return 1
    for c in clients:
        toast(c, say("view_keys_moved"), "info", secs=8)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("%d\n" % time.time())
    except OSError:
        pass
    return 0


def _keys():
    import fleet_keys
    return fleet_keys


# PAL_SEL (conf/fleet-palette.conf) in the dark theme and its Tokyo Night Day
# counterpart, each with its nearest 256-colour cell.
SEL_RGB = {"dark": ((0x41, 0x48, 0x68), 60), "light": ((0xb7, 0xc1, 0xe3), 146)}


def view_theme():
    """dark | light: FLEET_VIEW_THEME, else the terminal's COLORFGBG (a light
    background is 7 or 15), else dark."""
    want = os.environ.get("FLEET_VIEW_THEME", "")
    if want in SEL_RGB:
        return want
    bg = os.environ.get("COLORFGBG", "").rpartition(";")[2]
    return "light" if bg in ("7", "15") else "dark"


def sel_color(cs):
    """The selected row's background: PAL_SEL's nearest 256-colour cell (never a
    redefined colour — it would outlive the popup on the terminal), else blue."""
    return SEL_RGB[view_theme()][1] if cs.COLORS >= 256 else cs.COLOR_BLUE


def popup(screen, qo, vid, client, forward="", land_at=""):
    # Scope paste mode to this popup's terminal, including exceptions/close.
    sys.stdout.write("\x1b[?2004h")
    sys.stdout.flush()
    try:
        return _popup(screen, qo, vid, client, forward, land_at)
    finally:
        sys.stdout.write("\x1b[?2004l")
        sys.stdout.flush()


def _popup(screen, qo, vid, client, forward="", land_at=""):
    # raw: ⌃\ is a key here (the home shell), never SIGQUIT
    import fleet_panel as panel
    inputs = panel.Input()
    curses.raw()
    curses.curs_set(0)
    styles = {"bold": curses.A_BOLD, "lit": curses.A_REVERSE}
    selected_pairs = {}
    curses.mousemask(curses.ALL_MOUSE_EVENTS)
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
            # Keep foregrounds and state glyphs; selection changes background only —
            # the palette's PAL_SEL (plan B, T486 v14 §1).
            sel_bg = sel_color(curses)
            for n, fg in [(-1, -1), (8, grey)] + [(n, n if n < curses.COLORS else n % 8) for n in GLYPH_COLORS.values()]:
                pair = 32 + n + 1
                curses.init_pair(pair, fg, sel_bg)
                selected_pairs[n] = curses.color_pair(pair)
            for n in sorted(set(GLYPH_COLORS.values())):
                c = n if n < curses.COLORS else (curses.COLOR_WHITE if n == 8 else n % 8)
                curses.init_pair(10 + n, c, -1)
                styles["c%d" % n] = curses.color_pair(10 + n)
    except curses.error:
        pass

    def attr(style):
        if "lit" in style and selected_pairs:
            fg = next((int(k[1:]) for k in style if k.startswith("c") and k[1:].isdigit()),
                      8 if "dim" in style else -1)
            return selected_pairs.get(fg, selected_pairs[-1]) | (curses.A_BOLD if "bold" in style else 0)
        a = 0
        for k in style:
            a |= styles.get(k, 0)
        return a
    # the first frame never waits on the hub (issue #3311): a stale hub_ok made this
    # read run hub_fresh's --ensure / --refresh (3-5 s) before anything was drawn.
    # The cache is drawn as it is (a stale one wears the 失联 banner) and the hub
    # check is the Refresh thread's first read, at once. FLEET_VIEW_REFRESH=0 (no
    # Refresh) keeps the old blocking read.
    bg = fenv("FLEET_VIEW_REFRESH", 2) > 0
    # the panel's clock (issue #3551): the process start (Linux) or the module's
    # import → loaded → the rows read → the first frame, in timing/panel.ndjson
    clock = fleet_timing.Clock("panel", fleet_timing.proc_start() or getattr(qo, "T_START", None))
    clock.mark("boot")
    items = entries(vid, hub=not bg)
    clock.mark("read")
    order_save(vid, items)
    cur = current(vid)
    # opened in a session's shell (⌃\): its session is the lit row — ↵ is back on it
    _, vsh = tm("display-message", "-p", "-t", "=%s@view-%s:" % (view_fleet(vid), vid), "#{@view_shell}")
    if ":" in vsh:
        cur = vsh.split(":", 1)[1]
    fleet = view_fleet(vid)
    view_lang_env(vid)
    cmds = panel_commands()
    query, opened, msg, show_legend = "", set(), order_notice(), False
    msg_until = 0      # a line that goes by itself (the language row's, 3 s — L3)
    # the ⚡ row (issue #3327): its cells, read off the screen's thread (⌘T's rules);
    # `busy` while a ↵ runs, its outcome landing in `job`
    bolt, busy, job = bolt_new(), None, []
    # the box's defaults start from the session in view (T670, EPIC T651 C2)
    vrepo = view_repo(vid, cur, items)
    page, follow_list, ask_focus = None, True, 0
    box = 2         # the 「新会话」 box's lit item: 0 仓库 · 1 Agent · 2 开 (T652)

    def grid_load():
        bolt["g"] = grid_read(vid, vrepo)
        bolt["ready"] = True
    loader = threading.Thread(target=grid_load, daemon=True)
    loader.start()

    def listing():
        return panel_rows(items, query, opened, cmds, bolt, busy, cur)

    key_of = panel.key_of

    def bolt_at():
        return next((i for i, e in enumerate(shown) if e.get("cmd") == "new"), -1)
    shown = listing()
    # --at (task Q1A8's landing): the cursor on that session, else as always
    at = next((i for i, e in enumerate(shown) if land_at and e.get("target") == land_at and e["kind"] == "sess"),
              next((i for i, e in enumerate(shown) if e.get("target") == cur and e["kind"] == "sess"),
                   next((i for i, e in enumerate(shown) if e["kind"] == "sess"),
                        next((i for i, e in enumerate(shown) if pickable(e)), 0))))
    top = 0
    # The popup door's --freeze contains background output. Repair after resize
    # only: a periodic last-row scroll otherwise repaints the frame at rest.
    heal = qo.Heal(periodic=False)
    fresh = Refresh(vid, first=0 if bg else None)
    # One full page in the list's place (plan B, T486 v14 §2): the actions, a
    # choice, a question or the composer. Escape steps back a level — a question
    # asked from the actions page returns to it (`stack`) — and from the first
    # level restores the list's search/selection/scroll, its row the lit one.
    mode, mrow, mitems, mat, mtitle, pend, line = "", None, [], 0, "", None, Line()
    stack = []
    # another machine's action runs off the screen's thread (a hub write waits up
    # to its op's answer): its line lands here, then the list is read again
    landed = []

    def close_page():
        nonlocal mode, mrow, mitems, mat, pend, page, query, opened, at, top, shown, follow_list
        if page:
            query, opened, _, _ = page.snapshot
            shown = listing()
            query, opened, at, top = page.restore(shown)
            if not any(key_of(e) == page.origin for e in shown):
                at = row_gone_at(shown, at)
        mode, mrow, mitems, mat, pend, page = "", None, [], 0, None, None
        stack.clear()
        follow_list = True

    def back():
        nonlocal mode, mrow, mitems, mat, mtitle, pend, ask_focus
        if stack:
            mode, mrow, mitems, mat, mtitle, pend = stack.pop()
            ask_focus = 0
            if page:
                page.scroll, page.follow = 0, True
            return
        close_page()

    def anchor(row):
        nonlocal page, ask_focus
        if page is None:
            page = panel.Page(row, query, opened, at, top)
        else:
            page.retarget(row)
        ask_focus = 0

    def actions_page(row):
        """The lit session's actions page (Tab, [ ]): 进入 · 打开 PR · 改名… · 换成
        Codex/Claude · 回收… — a grey, unnumbered one says why it cannot run."""
        nonlocal mrow, mitems, mat, mtitle, mode
        anchor(row)
        mrow = act_row(fleet, row)
        miss = (bolt["g"].get("missing") or {}) if not mrow.get("far") else {}
        mitems = [(a["id"], label, a, why) for a, label, why in page_of(mrow, miss)]
        mat = next((i for i, m in enumerate(mitems) if not m[3]), 0)
        mtitle = mrow.get("text") or mrow.get("name") or ""
        mode = "menu"
        stack.clear()
        page.scroll, page.follow = 0, True

    def page_step(d):
        """[ ] on the actions page: the list's previous / next session's page."""
        rows_ = [e for e in shown if e["kind"] == "sess" and e.get("target")]
        i = next((n for n, e in enumerate(rows_) if key_of(e) == page.origin), -1)
        if i < 0 or not rows_:
            return
        actions_page(rows_[(i + d) % len(rows_)])

    def compose(row):
        """The 「新会话」 box (T652): opens on 开, both values chosen."""
        nonlocal mode, box
        anchor(row)
        # Resolve the defaults once; later list/search changes cannot silently
        # change its destination. Async grid loading is handled below.
        if bolt["ready"] and bolt["repo"] is None:
            bolt["repo"] = bolt_repo(bolt)
        mode, box = "compose", 2
        page.scroll, page.follow = 0, True

    def valid_row(r):
        # Frozen origin, fresh eligibility. Never use the currently selected row
        # for an open page; a vanished/replaced origin is a refusal.
        if not r.get("target") or (r.get("gone") and r["target"].startswith(("landed:", "id:"))):
            return r
        if r.get("gone"):
            return None
        e = next((e for e in items if e.get("kind") == "sess" and e.get("target") == r["target"]
                  and bool(e.get("far")) == bool(r.get("far")) and not e.get("gone")), None)
        if e is None or e.get("lost"):
            return None
        now = act_row(fleet, e)
        if now.get("gone") or (r.get("fid") and now.get("fid") != r["fid"]):
            return None
        return now

    def run(a, r, ans):
        """Do it, say how it went, read the list again (a pin, a rename, a reap
        shows at once); back on the list."""
        nonlocal items, shown, msg, mode, pend, line, msg_until
        checked = valid_row(r)
        if checked is None or (r.get("target") and not a.get("rowless") and
                               not any(x[0]["id"] == a["id"] for x in menu_of(checked))):
            msg = say("view_overlay_gone")
            return False
        r = checked
        if (r.get("far") and not r.get("lost") and a["id"] not in ("enter", "shell")) or a.get("thread"):
            def far_run():
                landed.append(act_run(qo, vid, fleet, a, r, ans, client)[1])
            threading.Thread(target=far_run, daemon=True).start()
            close_page()
            msg = say("view_act_sent_fmt", a["label"](r).rstrip("…"))
            return False
        rc, said, went = act_run(qo, vid, fleet, a, r, ans, client, wait=False)
        msg_until = time.time() + 3 if a["id"] == "lang" and rc == 0 else 0
        if rc == 4 and r.get("gone") and not ans:
            # a restore that asks first (#543): its question on the bottom line,
            # y reopen the PR · r restore anyway · any other key cancels
            mode, pend, line = "ask", (a, r, "", "key", said + " · " + say("view_ask_restore")), Line()
            return False
        close_page()
        if went:
            return True     # the 看台 is on it now: the popup closes
        msg = said
        items = entries(vid)
        shown = listing()
        return False

    def pick(a, r, value=None):
        """An action picked (or one of its options): ask what it needs, else do it."""
        nonlocal mode, mitems, mat, mtitle, pend, line, ask_focus
        ask_focus = 0
        if page:
            page.scroll, page.follow = 0, True
        ask = act_ask(a, r)
        if mode == "menu" and (ask in ("choice", "text", "key") or (value is not None and (a.get("then") or {}).get(value))):
            stack.append((mode, mrow, mitems, mat, mtitle, pend))     # esc comes back here
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
            mode, mitems, mat, mtitle, pend = "choice", [(v, l, a, "") for v, l in ch], 0, a["label"](r), (a, r)
            return False
        if ask in ("text", "key"):
            dflt = a.get("default")
            mode, pend, line = "ask", (a, r, "", ask, a["prompt"](r)), Line(dflt(r) if dflt else "")
            return False
        return run(a, r, "")

    def run_none(a, r):
        nonlocal msg
        close_page()
        msg = say("view_act_failed_fmt", a["label"](r), say("view_act_nothing"))
        return False

    # ⌘N (T670, EPIC T651 C2) — a key only when the person names it since T685
    # (new=cmd+n): straight into the 「新会话」 box, both values chosen — ↵ opens;
    # esc closes the popup (there is no list it came from)
    if forward == "dispatch" and bolt_at() >= 0:
        at = bolt_at()      # ⌘T, when the person named it: the panel lit on ⚡
    direct = forward == "new" and bolt_at() >= 0
    if direct:
        at = bolt_at()
        compose(shown[at])

    while True:
        if msg_until and time.time() > msg_until:
            msg, msg_until = "", 0
        if landed:
            msg = landed.pop(0)
            items = entries(vid)
            shown = listing()
        if job:
            # the ⚡ row's ↵ ended: opened ⇒ the 看台 is on it, the popup closes
            rc, said = job.pop(0)
            busy = None
            if rc == 0:
                return 0
            msg = said or say("view_new_failed")
            shown = listing()
        new = fresh.poll()
        if new is not None:
            # the list read again: the lit row stays the lit row (by its key)
            lit = key_of(shown[at]) if 0 <= at < len(shown) else (None, None)
            items = new
            shown = listing()
            at = next((i for i, e in enumerate(shown) if pickable(e) and lit[1] and key_of(e) == lit),
                      row_gone_at(shown, at))
        if msg and not msg_until:
            msg_until = time.time() + 3
        heal.tick(screen)
        height, width = screen.getmaxyx()
        screen.erase()
        ban = banner(items)
        off = 2 if ban else 1
        body = max(1, height - 2 - off)
        sel = [i for i, e in enumerate(shown) if pickable(e)]
        if sel and at not in sel:
            at = min(sel, key=lambda i: abs(i - at))
        top = panel.clamp_top(top, len(shown), body)
        if follow_list:
            top = panel.reveal(top, at, body)
            if at + 1 < len(shown) and shown[at + 1]["kind"] == "ask" and at + 1 >= top + body:
                top += 1
        follow_list = False
        remote_unknown = hub_stale() or (os.environ.get("CCQUOTA_FLEET") == "1" and hub_age() is None)
        count = session_count(items, query, remote_unknown)
        count_x = max(2, width - 2 - qo.cells(count))
        if page and mode == "compose":
            # the 「新会话」 box's own first line stands where 搜索会话 stood (T774),
            # as ✦ 消息's page puts its title there; esc gives the search back
            panel.put(screen, 0, 0, compose_title(qo.cells), width - 1, qo.clip, attr(("bold",)))
        else:
            panel.put(screen, 0, 0, "› " + (query or say("view_search_ph")), count_x - 1, qo.clip)
            panel.put(screen, 0, count_x, count, width - count_x - 1, qo.clip, attr(("bold",)))
        if ban:
            try:
                screen.addnstr(1, 0, qo.clip(ban, width - 1), width - 1, attr(("red",)) or curses.A_BOLD)
            except curses.error:
                pass
        for y, segs in enumerate(paint(shown[top:top + body], at - top, width - 1, qo.cells, qo.clip) if not page else [], off):
            x = 0
            for text, style in segs:
                if x >= width - 1:
                    break
                try:
                    panel.put(screen, y, x, text, width - 1 - x, qo.clip, attr(style))
                except curses.error:
                    pass
                x += qo.cells(text)
        lit_e = shown[at] if 0 <= at < len(shown) else {}
        foot = (say("view_task_starting_fmt", busy["title"]) if busy else msg) or (legend() if show_legend else "")
        fstyle = ("dim",)
        if not foot and not page and lit_e.get("kind") == "sess":
            # what the plan-B row no longer carries, or why a search listed it
            foot, red = (match_why(lit_e, query), False) if query.strip() else ("", False)
            if not foot:
                foot, red = note_of(lit_e)
            fstyle = ("red",) if red else fstyle
        if width < 48:
            foot = say("view_narrow")
        panel.put(screen, height - 2, 0, foot, width - 1, qo.clip, attr(fstyle))
        keys = say("view_keys_sending") if busy else say("view_keys_short")
        if not busy and not page and epic_folds(lit_e) and not query.split():
            keys = say("view_keys_epic") + "  " + keys
        hits, controls = {}, {}
        if page:
            # the page (plan B): its object on top — the session line as the list
            # draws it, or ⚡ 新任务 — a rule, then one item a line, list-styled
            w = width - 1
            head = page.row if mode != "compose" else None
            if mode == "compose":
                hsegs = []      # its title is row 0's (T774)
            elif head and head.get("kind") == "sess":
                hsegs = row_segs(head, w, qo.cells, qo.clip)
            else:
                hsegs = [(cmd_line((head or {}).get("text") or mtitle, qo.cells), ("bold",))]
            x = 0
            for text, style in hsegs:
                panel.put(screen, off, x, text, w - x, qo.clip, attr(style))
                x += qo.cells(text)
            pg = off + (1 if hsegs else 0)     # the rule, then the page's lines
            panel.put(screen, pg, 0, "─" * w, w, qo.clip, attr(("dim",)))
            lines, selected, cursor = [], None, None
            if mode in ("menu", "choice"):
                n = 0
                for i, (_, label, _, why) in enumerate(mitems):
                    if why:
                        lines.append(("     " + label + "　" + why, ("dim",)))
                        continue
                    n += 1
                    lines.append(("  %s  %s" % (n if n < 10 else " ", label), ("lit",) if i == mat else ()))
                if mode == "menu" and head and head.get("kind") == "sess":
                    # the window's ID under its actions (EPIC T497 C3): segments, aliases, hub
                    lines.extend(id_page(head, w))
                selected = mat
                keys = say("view_page_keys_fmt", "1–%d" % min(9, max(1, n))) if mode == "menu" else \
                    say("view_choice_keys_fmt", "1–%d" % min(9, max(1, n)))
            elif mode == "ask":
                # what is asked (the action's name), then the line: a text's
                # `prompt› words▏`, a key's whole question (y/n)
                lines.append(("  " + pend[0]["label"](pend[1]).rstrip("…"), ()))
                if pend[3] == "text":
                    lead = "  " + pend[4]
                    controls[len(lines)] = 0
                    lines.append((lead + line.text + "▏", ("lit",) if ask_focus == 0 else ()))
                    if ask_focus == 0:
                        cursor = len(lines) - 1, qo.cells(lead + line.text)
                else:
                    prompt = panel.Editor(pend[4])
                    for a0, b0 in prompt.rows(max(2, w - 2), qo.cells):
                        controls[len(lines)] = 0
                        lines.append(("  " + prompt.text[a0:b0], ("lit",) if ask_focus == 0 else ()))
                for k, label in ((1, say("view_confirm")), (2, say("view_cancel"))):
                    controls[len(lines)] = k
                    lines.append(("  " + label, ("lit",) if ask_focus == k else ()))
                selected = max(i for i, k in controls.items() if k == ask_focus)
                keys = say("view_ask_keys_back") if stack else say("view_ask_keys")
            elif mode == "compose":
                # the 「新会话」 box (T652): 仓库 ‹›, Agent ‹›, 开 — nothing to type
                if bolt["ready"] and bolt["repo"] is None:
                    bolt["repo"] = bolt_repo(bolt)
                # the agent is not pinned: untouched, it is the box's repo's own (T670)
                cells, note = bolt_cells(bolt, "")
                for k, label in enumerate([cells[0][0], cells[1][0], say("view_new_open")]):
                    controls[len(lines)] = k
                    lines.append(("  " + label, ("lit",) if box == k else ()))
                selected = next(i for i, k in controls.items() if k == box)
                if note:
                    lines.append(("  " + note, ("dim",)))
                keys = say("view_compose_keys")
            area = max(1, body - 1 - (pg - off))
            page.scroll = panel.clamp_top(page.scroll, len(lines), area)
            if page.follow and selected is not None:
                page.scroll = panel.reveal(page.scroll, selected, area)
            page.follow = False
            for k, (text, style) in enumerate(lines[page.scroll:page.scroll + area]):
                y = pg + 1 + k
                text = qo.clip(text, w)
                panel.put(screen, y, 0, text + " " * max(0, w - qo.cells(text)), w, qo.clip, attr(style))
                hits[y] = page.scroll + k
            if cursor and page.scroll <= cursor[0] < page.scroll + area:
                try:
                    curses.curs_set(1)
                    screen.move(pg + 1 + cursor[0] - page.scroll, min(w - 1, cursor[1]))
                except curses.error:
                    pass
            else:
                curses.curs_set(0)
        else:
            curses.curs_set(0)
        panel.put(screen, height - 1, 0, keys, width - 1, qo.clip, attr(("dim",)))
        screen.refresh()
        if not clock.written:
            clock.mark("frame")
            clock.done()
        timeout_ms = min(heal.timeout(False) or 1000, fresh.wait_ms(), 200 if busy or not bolt["ready"] else 1000,
                         max(50, int((msg_until - time.time()) * 1000)) if msg_until else 1000)
        try:
            ch = panel_key(screen, timeout_ms, job if busy else None, inputs)
        except curses.error:
            continue
        if ch is None:
            continue
        if isinstance(ch, tuple) and ch[0] == "paste":
            if page:
                if mode == "ask" and ask_focus == 0 and pend[3] == "text":
                    line.text += " ".join(ch[1].split())[:400]
                # Pasting onto a button never activates it.
                continue
            # Search paste is a single edit; no newline/Tab may run a command.
            query += " ".join(ch[1].split())[:4000]
            shown = listing()
            at = next((i for i, e in enumerate(shown) if e["kind"] == "sess"),
                      next((i for i, e in enumerate(shown) if e.get("cmd") == "new"), 0))
            top, follow_list = 0, True
            continue
        msg, msg_until = "", 0
        if ch in ("\x1b", "\x03"):
            if page and not (direct and mode == "compose" and not stack):
                back()
                continue
            return 0
        if ch == curses.KEY_RESIZE:
            heal.resized(screen)
            # Only clamp physical offsets in render; no reveal/reset on resize.
            follow_list = False
            if page:
                page.follow = False
            continue
        if busy:
            continue
        if ch == "\x1c":
            # ⌘\ · ⌃\ (EPIC T651 C3): the home shell from every page — the list, a row's
            # Tab page, the new-session box; a session's own is its Tab page's 命令行
            if open_home_shell(qo, vid, client) == 0:
                return 0
            msg = say("view_shell_failed_fmt", here_label(view_row(vid)))
            continue
        if ch == curses.KEY_MOUSE:
            try:
                _, mx, my, _, buttons = curses.getmouse()
            except curses.error:
                continue
            wheel = -1 if buttons & getattr(curses, "BUTTON4_PRESSED", 0) else 1 if buttons & getattr(curses, "BUTTON5_PRESSED", 0) else 0
            if page:
                # the page takes the whole list area; a click elsewhere is nothing
                if wheel:
                    page.scroll += wheel
                    continue
                i = hits.get(my)
                if i is None:
                    continue
                if mode in ("menu", "choice"):
                    if i >= len(mitems) or mitems[i][3]:
                        continue
                    mat = i
                elif mode == "compose":
                    # a click lights a value (again: its next one); a click on 开 opens
                    if i not in controls:
                        continue
                    if controls[i] in (0, 1):
                        if box == controls[i]:
                            bolt["focus"] = "repo" if box == 0 else "agent"
                            bolt_step(bolt, "", 1)
                        box = controls[i]
                        continue
                    box = 2
                elif mode == "ask":
                    ask_focus = controls.get(i, ask_focus)
                ch = "\n" if buttons & (curses.BUTTON1_CLICKED | curses.BUTTON1_RELEASED | curses.BUTTON1_DOUBLE_CLICKED) else None
            elif off <= my < off + body:
                if wheel:
                    top = panel.clamp_top(top + wheel, len(shown), body)
                    continue
                i = top + my - off
                if i < len(shown) and epic_folds(shown[i]) and not query.split() and \
                        buttons & (curses.BUTTON1_CLICKED | curses.BUTTON1_RELEASED) and \
                        0 <= mx - name_col(width - 1) < 2:
                    # a click on the driver's ▸ / ▾ folds it (T507)
                    at, follow_list = i, False
                    epic_toggle(items, fleet, shown[i]["target"], not shown[i].get("expanded"))
                    shown = listing()
                    continue
                if i < len(shown) and pickable(shown[i]):
                    at = i
                    follow_list = False
                    # Single click selects; double click enters or opens composer.
                    ch = "\n" if buttons & curses.BUTTON1_DOUBLE_CLICKED else None
                else:
                    continue
            else:
                continue
        if page:
            if mode in ("menu", "choice"):
                live_i = [i for i, m in enumerate(mitems) if not m[3]]
                digit = isinstance(ch, str) and len(ch) == 1 and ch in "123456789"
                if ch in ("\t", curses.KEY_BTAB, curses.KEY_UP, curses.KEY_DOWN, "\x10", "\x0e") and live_i:
                    d = 1 if ch in ("\t", curses.KEY_DOWN, "\x0e") else -1
                    k = live_i.index(mat) if mat in live_i else 0
                    if ch in ("\t", curses.KEY_BTAB):
                        mat = live_i[(k + d) % len(live_i)]
                    else:
                        mat = live_i[max(0, min(len(live_i) - 1, k + d))]
                    page.follow = True
                elif mode == "menu" and ch in ("[", "]"):
                    page_step(-1 if ch == "[" else 1)
                elif (ch in ("\n", "\r", curses.KEY_ENTER) or digit) and live_i:
                    if digit:
                        if int(ch) > len(live_i):
                            continue
                        mat = live_i[int(ch) - 1]
                    if mat not in live_i:
                        continue
                    v, _, a, _ = mitems[mat]
                    if pick(a, mrow) if mode == "menu" else pick(a, pend[1], v):
                        return 0
                continue
            if mode == "ask":
                a, r, pre, kind, _ = pend
                if ch in ("\t", curses.KEY_BTAB, curses.KEY_UP, curses.KEY_DOWN):
                    d = 1 if ch in ("\t", curses.KEY_DOWN) else -1
                    ask_focus = (ask_focus + d) % 3 if ch in ("\t", curses.KEY_BTAB) else max(0, min(2, ask_focus + d))
                    page.follow = True
                elif ch in ("\n", "\r", curses.KEY_ENTER) and ask_focus == 2:
                    back()
                elif kind == "key" and ask_focus == 0 and isinstance(ch, str) and ch in (a.get("keys") or ""):
                    if a.get("yes") and ch not in "yY":
                        back()
                    elif run(a, r, ch):
                        return 0
                elif ch in ("\n", "\r", curses.KEY_ENTER):
                    text = ("y" if a.get("yes") else "") if kind == "key" else line.text.strip()
                    if not text:
                        back()
                    elif run(a, r, pre + text):
                        return 0
                elif ask_focus == 0 and kind == "text":
                    line.key(ch)
                continue
            if mode == "compose":
                # the 「新会话」 box (T652): Tab / ↑↓ walk the three, ←→ change the
                # lit value, ↵ on a value goes to 开, ↵ on 开 opens
                if ch in ("\t", curses.KEY_BTAB, curses.KEY_UP, curses.KEY_DOWN, "\x10", "\x0e"):
                    box = (box + (1 if ch in ("\t", curses.KEY_DOWN, "\x0e") else -1)) % 3
                elif box in (0, 1) and ch in (curses.KEY_LEFT, curses.KEY_RIGHT, " "):
                    bolt["focus"] = "repo" if box == 0 else "agent"
                    bolt_step(bolt, "", -1 if ch == curses.KEY_LEFT else 1)
                elif box in (0, 1) and ch in ("\n", "\r", curses.KEY_ENTER):
                    box = 2
                elif box == 2 and ch in ("\n", "\r", curses.KEY_ENTER, " "):
                    if not bolt["ready"]:
                        msg = say("view_grid_loading")
                        continue
                    repo = bolt_repo(bolt)
                    if repo and repo not in bolt["g"].get("repos", []):
                        msg = say("view_draft_repo_gone")
                        continue
                    missing = bolt["g"].get("missing") or {}
                    if bolt_agent(bolt) in missing:
                        msg = str(missing[bolt_agent(bolt)]) or say("view_draft_agent_gone")
                        continue
                    argv, title, where = bolt_argv(qo, vid, client, bolt)
                    busy = {"title": title, "where": where}
                    bolt_run(argv, job)
                continue
            continue
        if ch in (curses.KEY_UP, "\x10", curses.KEY_DOWN, "\x0e"):
            # as drawn, both ways round (T762) — no row is skipped or jumped to
            at = nav_step(shown, at, 1 if ch in (curses.KEY_DOWN, "\x0e") else -1)
            follow_list = True
            continue
        if ch in (curses.KEY_LEFT, curses.KEY_RIGHT) and 0 <= at < len(shown) and shown[at]["kind"] == "sess" \
                and not query.split() and (epic_folds(shown[at]) or (shown[at].get("fold") and ch == curses.KEY_LEFT)):
            # an EPIC (T507): → opens the driver, ← shuts it; ← on a member goes up
            # to its driver and shuts it — ↵ still goes to the session
            tgt = shown[at]["target"] if epic_folds(shown[at]) else shown[at]["fold"]
            epic_toggle(items, fleet, tgt, ch == curses.KEY_RIGHT)
            shown = listing()
            at = next((i for i, x in enumerate(shown) if x["kind"] == "sess" and x.get("target") == tgt), at)
            continue
        if ch in (curses.KEY_LEFT, curses.KEY_RIGHT) and 0 <= at < len(shown) and shown[at]["kind"] == "sec":
            # → opens a folding heading (已结束), ← shuts it — as ↵ toggles it
            # (issue #3666: only ↵ did, the arrows fell through to nothing)
            opened = sec_fold(opened, shown[at]["sec"], ch == curses.KEY_RIGHT)
            shown = listing()
            continue
        if ch == "\t":
            if lit_e.get("cmd") == "new":
                compose(lit_e)
                continue
            if lit_e.get("cmd") == "lang":
                # the language row's options (issue #3329): 中文 · English · 跟系统走
                anchor(lit_e)
                a = ACTION["lang"]
                mitems = [(v, label, a, "") for v, label in a["choices"]({}, fleet)]
                mode, mat, mtitle, pend = "choice", 0, a["label"]({}), (a, {})
                continue
            if 0 <= at < len(shown) and shown[at]["kind"] == "sess":
                actions_page(shown[at])
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
                # ⚡ (issue #3327): words ⇒ a task, none ⇒ a blank session — off the
                # screen's thread, the row its progress until it opens
                if e["act"] == "new":
                    compose(e)
                    continue
                if e["act"] == "lang":
                    run(ACTION["lang"], {}, "")     # flips it; the list redraws in it
                    continue
                if e["act"] == "notices":
                    # ✦ 消息 (T675, T701): the page, then the list again (its count read
                    # anew) — or, when the page went to a message's session, closed
                    if notices_pick(screen, vid, client):
                        return 0
                    heal.resized(screen)
                    shown = listing()
                    continue
                if e["act"] == "pin":
                    # the session in view (issue #3517): its own 置顶 item
                    anchor(e)
                    if pick(ACTION["pin"], act_row(fleet, e["row"])):
                        return 0
                    continue
                if e["act"] == "quit":
                    # 退出 fleet (T685): y / n first
                    anchor(e)
                    if pick(ACTION["quit"], e["row"]):
                        return 0
                    continue
                if e["act"] == "reapall":
                    # 已结束 · 还开着 (issue #3731): y/N first, then all of them
                    anchor(e)
                    pick(ACTION["reapall"], e["row"])
                    continue
                if e["act"] == "history":
                    # 已关闭's 「更早的 X 个」 (issue #3731): the history list here
                    if history_pick(screen, fleet) == 0:
                        return 0
                    heal.resized(screen)
                    items = entries(vid)
                    shown = listing()
                    continue
                rc, msg, went = act_run(qo, vid, fleet, ACTION[e["act"]], e["row"], "", client)
                if went:
                    return 0
                continue
            target = e.get("target") or ""
            if not target:
                continue
            if e.get("ledger"):
                continue      # a closed ID with no history row (T593): nothing to restore
            if e.get("gone"):
                # a reaped session (issue #3286): ↵ is its one action, 恢复
                anchor(e)
                if pick(ACTION["resume"], act_row(fleet, e)):
                    return 0
                continue
            msg = lost_msg(e) or ""
            if msg:
                continue
            rc = go(qo, vid, target, "popup", client, e)
            if rc == 0:
                return 0
            msg = far_miss(vid, e, rc)
            continue
        if ch == "\x14":
            # ⌃T (issue #3517): 置顶 / 取消置顶 the lit session, as its Tab menu would
            e = shown[at] if 0 <= at < len(shown) else {}
            if e.get("kind") != "sess" or not e.get("target") or e.get("gone"):
                continue
            anchor(e)
            if pick(ACTION["pin"], act_row(fleet, e)):
                return 0
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
        # typed words: the best session hit is lit; none hit — the language row
        # when they name it (语言 · lang …, issue #3329; 消息 …, T675), else ⚡
        at = next((i for i, e in enumerate(shown) if e["kind"] == "sess"),
                  next((i for i, e in enumerate(shown) if query and (e.get("cmd") in ("lang", "pin", "notices") or e.get("hit"))),
                       next((i for i, e in enumerate(shown) if e.get("cmd") == "new"),
                            next((i for i, e in enumerate(shown) if pickable(e)), 0))))
        if not query:
            at = next((i for i, e in enumerate(shown) if e["kind"] == "sess" and e.get("target") in (lit, cur)), at)
        top, follow_list = 0, True


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
        return view_keys(me, "--if-stale" in argv, browser="--browser" in argv)
    if argv[:1] == ["go"] and len(argv) >= 3:
        vid = view_id(argv[1])
        return go(qo, vid, argv[2], opt(argv, "--how") or "go", opt(argv, "--client")) if vid else 2
    vid = view_id(opt(argv, "--view"))
    if not vid:
        return 2
    client = opt(argv, "--client")
    if argv[:1] == ["do"] and len(argv) >= 2:
        return do(qo, argv[1], vid, client, opt(argv, "--target"),
                  {k: opt(argv, "--" + k) for k in ("repo", "agent", "prompt", "draft", "t0")})
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
        # the popup's lines with its ⚡ / ⏻ rows (issues #3180, #3327): kind · cmd · text
        q = " ".join(a for i, a in enumerate(argv[1:], 1) if a not in ("--view", "--client")
                     and argv[i - 1] not in ("--view", "--client"))
        for e in panel_rows(entries(vid), q, {"ended", "gone"}, bolt=bolt_new(grid_read(vid)), cur=current(vid)):
            print("\t".join((e["kind"], e.get("cmd") or e.get("target") or e.get("group") or e["kind"], e.get("text") or "")))
        return 0
    if argv[:1] == ["view-gone"]:
        # read the 已回收 list now and wait (the selftest, a person's evidence)
        return 0 if gone_read(view_fleet(vid), wait=True) else 1
    if argv[:1] == ["view-rows"]:
        rest = [a for i, a in enumerate(argv[1:], 1) if a not in ("--view", "--client")
                and argv[i - 1] not in ("--view", "--client")]
        gl = glyphs()
        for e in visible(entries(vid), " ".join(rest), {"ended", "gone"}):
            print("\t".join((e["kind"], e.get("target") or e.get("of") or e.get("cmd") or e.get("sec") or e.get("group") or "",
                             e.get("word") or "", e.get("text") or "", e.get("right") or "", e.get("foot") or "",
                             gl.get(e.get("sym") or "", "") if e["kind"] == "sess" else "",
                             e.get("group") or "", " ".join(e.get("tags") or ()))))
        return 0
    if argv[:1] == ["view-notice"]:
        if opt(argv, "--socket"):
            _SOCK[0] = opt(argv, "--socket")
            os.environ.pop("TMUX", None)
        return keys_notice(vid, client)
    os.environ.setdefault("ESCDELAY", "25")
    return curses.wrapper(popup, qo, vid, client, opt(argv, "--forward"), opt(argv, "--at"))
