# fleet_keys.py — imported, not run (a comment first: fleet-install.sh checks every bin/ file starts with one)
"""fleet_keys.py — which keys a person's fleet binds (issue #3185, EPIC #3178 C7).

A new install takes ONE key (T685, 操作者 2026-10-20): ⌘P on a Mac, and the same
panel on a phone or a terminal with no ⌘ as F12 (one tap, once it is on Termius's
key row — T705, 操作者 2026-10-20: 「Termius还应保留F12」) or ⌃] p; every other
action is a row of that panel, and any other key is the person's to add:

    [client]  FLEET_KEY_PANEL=cmd+p           the panel; another chord, or `off`
              FLEET_KEYS_EXTRA="next=cmd+down new=cmd+n home=ctrl+\\"
    [common]  FLEET_KEY_PHONE="f12"           the phone's one-tap keys besides ⌃] p
                                              (always bound); `off` = ⌃] p alone
              FLEET_KEYS_PHONE_EXTRA="ctrl+]n=next ctrl+]q=quit"

A chord is `+`-joined modifiers (cmd · ctrl · alt/opt · shift) and one key (a
character, down/up/left/right, space, tab, return, esc, f1..f20); `ctrl+]<x>` is
⌃] then x — the 看台's own prefix table. An extra pair is `action=chord` or
`chord=action`, whichever side names an action of `dash-keymap.sh --panel switch`
(or `shell`, the session's shell — no ⌘ code, so only a chord the terminal sends).

The CLIENT half (fleet-iterm-profile.py) turns each ⌘ chord into an iTerm2 row
sending its action's private code; the MACHINE half (fleet_view.key_lines) binds
those codes, every other chord as a tmux key, and the phone keys. Neither reads
the other's file: the client carries its FLEET_KEYS_EXTRA to the machine at the
attach (fleet-thin.py → the remote command's environment).

Every value: the environment first (a test, or a conf already sourced), else the
machine's ONE fleet.conf (`$FLEET_CONF_DIR/fleet.conf`) sourced the way its own
readers source it — FLEET_SHELL=1 for the client's section.
"""
import os
import re
import subprocess

DEFAULT_PANEL = "cmd+p"
# the phone's panel keys (T705): ⌃] p is always one of them (PHONE_BASE — the
# phone's ⌘P, every terminal sends it); FLEET_KEY_PHONE names the others, F12 by
# default, `off` none. DEFAULT_PHONE is the whole default set, as the docs print it.
PHONE_BASE = "ctrl+]p"
DEFAULT_PHONE = "f12 " + PHONE_BASE
# iTerm2 keeps F12 (T705: the 看台 takes ⌘P alone on a Mac): the `fleet` profile
# sends F12 as its own private code, which the 看台 hands on to the pane as F12 —
# so a phone's F12 opens the panel and iTerm2's reaches the session. (chord, iTerm2
# key, code); dropped from the profile when the person named F12 themselves.
ITERM_PASS = (("f12", "0xf70f-0x800000", "933"),)
# the actions with no switch-table code: bound only as a chord the terminal sends.
# `shell` (a session's own, in its directory) is reached from the row's Tab page.
CODELESS = ("shell",)
# `home` (EPIC T651 C3): ⌃\ — and ⌘\, which the iTerm2 profile sends as ⌃\'s
# byte (dash-keymap.sh: code `x1c`) — only when the person names it (T685); the
# panel's 「回家命令行」 row is its default road. The web PTY keeps its own ⌃\.
HOME_CHORD = "ctrl+\\"
# The ⌘ keys issue #3328 folded into ⌘P and T685 gave back to iTerm2 (⌘K clears,
# ⌘T a tab, ⌘N a window, ⌘Q quits): (action, chord, glyph, code). The profile maps
# none of them any more; a code an older profile still sends is swallowed by the
# 看台 (caught as a user key, bound to nothing — conf/tmux-view.conf), and never
# reused. `forwards()` stays for one version (compat-1v: 下一批删) and is empty.
RETIRED = (("next", "cmd+down", "⌘↓", "920"), ("prev", "cmd+up", "⌘↑", "921"),
           ("back", "cmd+[", "⌘[", "922"), ("fwd", "cmd+]", "⌘]", "923"),
           ("new", "cmd+n", "⌘N", "928"), ("dispatch", "cmd+t", "⌘T", "932"),
           ("quit", "cmd+q", "⌘Q", "931"), ("switcher", "cmd+k", "⌘K", "930"))
FORWARD = RETIRED       # compat-1v: 下一批删 — the old name an older reader imports

MODS = {"cmd": 0x100000, "command": 0x100000, "ctrl": 0x40000, "control": 0x40000,
        "alt": 0x80000, "opt": 0x80000, "option": 0x80000, "shift": 0x20000}
# iTerm2's Keyboard Map spells a key as its NSEvent character; an arrow carries the
# numeric-pad bit (dash-keymap.sh: ⌘↓ is 0xf701-0x300000), an F key the function bit
NAMED = {"down": 0xF701, "up": 0xF700, "left": 0xF702, "right": 0xF703,
         "space": 0x20, "tab": 0x9, "return": 0xD, "enter": 0xD, "esc": 0x1B, "escape": 0x1B,
         "backspace": 0x7F, "bspace": 0x7F}
TMUX_NAMED = {"down": "Down", "up": "Up", "left": "Left", "right": "Right", "space": "Space",
              "tab": "Tab", "return": "Enter", "enter": "Enter", "esc": "Escape", "escape": "Escape",
              "backspace": "BSpace", "bspace": "BSpace"}
PFX = "ctrl+]"


def conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")


def setting(name, client=False, default=""):
    """`name` from the environment, else the machine's fleet.conf (its [client]
    section too when `client`), else `default`. Set-but-empty is a value: `""`."""
    if name in os.environ:
        return os.environ[name]
    path = os.path.join(conf_dir(), "fleet.conf")
    if not os.path.isfile(path):
        return default
    script = ('%s. "$1" >/dev/null 2>&1; if [ -n "${%s+x}" ]; then printf "1%%s" "$%s"; fi'
              % ("FLEET_SHELL=1; " if client else "unset FLEET_SHELL; ", name, name))
    try:
        out = subprocess.run(["bash", "-c", script, "fleet-keys", path], capture_output=True, text=True,
                             timeout=5, stdin=subprocess.DEVNULL).stdout
    except (OSError, subprocess.TimeoutExpired):
        return default
    return out[1:] if out.startswith("1") else default


def parse(chord):
    """`cmd+down` → (mods set, key) — key lower-cased unless one character; None when unreadable.
    `ctrl+]x` → ({'pfx'}, 'x')."""
    c = (chord or "").strip()
    if not c or c == "off":
        return None
    if c.lower().startswith(PFX) and len(c) > len(PFX):
        rest = c[len(PFX):]
        rest = "\\" if rest in ("\\", "\\\\") else rest
        return ({"pfx"}, rest) if len(rest) == 1 else None
    parts = c.split("+")
    # a `+` key itself: `cmd++`
    if c.endswith("++"):
        parts = c[:-2].split("+") + ["+"]
    mods, key = set(), parts[-1]
    for m in parts[:-1]:
        m = m.strip().lower()
        if m not in MODS:
            return None
        mods.add("cmd" if MODS[m] == 0x100000 else "ctrl" if MODS[m] == 0x40000
                 else "alt" if MODS[m] == 0x80000 else "shift")
    if key in ("\\\\",):
        key = "\\"
    if len(key) != 1:
        key = key.lower()
        if key not in NAMED and not re.match(r"^f([1-9]|1[0-9]|20)$", key):
            return None
    return mods, key


def is_cmd(chord):
    p = parse(chord)
    return bool(p) and "cmd" in p[0]


def iterm_key(chord):
    """The iTerm2 Keyboard Map key of a ⌘ chord (`0x70-0x100000`), '' for any other."""
    p = parse(chord)
    if not p or "cmd" not in p[0]:
        return ""
    mods, key = p
    mask = sum(v for m, v in (("cmd", 0x100000), ("ctrl", 0x40000), ("alt", 0x80000), ("shift", 0x20000))
               if m in mods)
    if len(key) == 1:
        ch = ord(key.lower())
    elif key in NAMED:
        ch = NAMED[key]
        if key in ("down", "up", "left", "right"):
            mask |= 0x200000
    else:
        ch, mask = 0xF704 + int(key[1:]) - 1, mask | 0x800000
    return "0x%x-0x%x" % (ch, mask)


def tmux_key(chord):
    """(table, key) for a chord the terminal itself sends: ('fleet-view', 'C-Space'),
    ('fleet-view-pfx', 'p'); None for a ⌘ chord or an unreadable one."""
    p = parse(chord)
    if not p or "cmd" in p[0]:
        return None
    mods, key = p
    if "pfx" in mods:
        return "fleet-view-pfx", key
    if len(key) == 1:
        name = key
    elif key in TMUX_NAMED:
        name = TMUX_NAMED[key]
    else:
        name = key.upper()
    pre = ("C-" if "ctrl" in mods else "") + ("M-" if "alt" in mods else "") + ("S-" if "shift" in mods else "")
    return "fleet-view", pre + name


def pairs(text, actions):
    """FLEET_KEYS_EXTRA / FLEET_KEYS_PHONE_EXTRA → [(action, chord)], in order; a pair
    naming no known action, or an unreadable chord, is dropped."""
    out = []
    for tok in (text or "").split():
        # `ctrl+]=…` is not a pair to split at its first `=` blindly: try both sides
        for i in [m.start() for m in re.finditer("=", tok)]:
            a, b = tok[:i], tok[i + 1:]
            if a in actions and parse(b):
                out.append((a, b))
                break
            if b in actions and parse(a):
                out.append((b, a))
                break
    return out


def panel():
    """The client's panel chord, or '' (`off`)."""
    v = setting("FLEET_KEY_PANEL", client=True, default=DEFAULT_PANEL).strip()
    return "" if v in ("", "off") else v


def client_extra():
    return setting("FLEET_KEYS_EXTRA", client=True, default="")


def carried():
    """What the client hands the machine at the attach: its extras, plus the panel
    when the panel is a chord the terminal sends (not a ⌘ one)."""
    words = client_extra().split()
    p = panel()
    if p and not is_cmd(p):
        words.append("quickopen=" + p)
    return " ".join(words)


def forwards(extra=None):
    """None since T685: the keys #3328 forwarded to the panel are iTerm2's again
    (RETIRED). compat-1v: 下一批删 — kept so an older caller still gets a list."""
    return []


def iterm_pass():
    """[(iTerm2 key, code)] the `fleet` profile hands on to the session (T705: F12),
    less a key the person bound themselves (the panel, an extra)."""
    named = [panel()] + [c for _, c in pairs(client_extra(), _ANY)]
    own = {(frozenset(p[0]), p[1]) for p in map(parse, named) if p}
    return [(k, code) for chord, k, code in ITERM_PASS if (frozenset(parse(chord)[0]), parse(chord)[1]) not in own]


class _Any:
    """Every action name — iterm_pass reads any extra's chord, whatever it binds."""
    def __contains__(self, _):
        return True


_ANY = _Any()


def phone():
    """The panel's phone chords: FLEET_KEY_PHONE's (F12 by default; `off` / empty
    none) and ⌃] p, always (T705 — before it, `f12` replaced ⌃] p)."""
    v = setting("FLEET_KEY_PHONE", default=DEFAULT_PHONE).split()
    words = [w for w in v if w != "off"]
    return words + ([PHONE_BASE] if PHONE_BASE not in words else [])


def phone_extra():
    return setting("FLEET_KEYS_PHONE_EXTRA", default="")
