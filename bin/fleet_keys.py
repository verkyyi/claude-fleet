# fleet_keys.py — imported, not run (a comment first: fleet-install.sh checks every bin/ file starts with one)
"""fleet_keys.py — which keys a person's fleet binds (issue #3185, EPIC #3178 C7).

A new install takes ONE key on a Mac, ⌘P (the panel), and three on a phone or a
terminal with no ⌘ (⌃空格 · F12 · ⌃] p); everything else is the person's to add
(issue #3328 took the rest away — FORWARD keeps them one version as the panel):

    [client]  FLEET_KEY_PANEL=cmd+p           the panel; another chord, or `off`
              FLEET_KEYS_EXTRA="next=cmd+down new=cmd+n shell=ctrl+\\"
    [common]  FLEET_KEY_PHONE="ctrl+space f12 ctrl+]p"
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
DEFAULT_PHONE = "ctrl+space f12 ctrl+]p"
# the actions with no switch-table code: bound only as a chord the terminal sends
CODELESS = ("shell",)
# The keys issue #3328 (EPIC #3178 ⑤, D3 · D4) took away — one key, ⌘P. For ONE
# version each still reaches the 看台 and opens the panel (⌘N ⌘T lit on its ⚡ row)
# with a one-time 「⌘T 已并进 ⌘P」 (fleet_view.forward_note): (action, chord, glyph,
# code) — the code the iTerm2 row sends; ⌘K's is the retired 930 (an old profile
# sent it for the same panel), ⌃\ has none (the terminal sends it). A chord the
# person names in FLEET_KEYS_EXTRA / FLEET_KEY_PANEL is theirs, never a forward.
# compat-1v: 下一批删
FORWARD = (("next", "cmd+down", "⌘↓", "920"), ("prev", "cmd+up", "⌘↑", "921"),
           ("back", "cmd+[", "⌘[", "922"), ("fwd", "cmd+]", "⌘]", "923"),
           ("new", "cmd+n", "⌘N", "928"), ("dispatch", "cmd+t", "⌘T", "932"),
           ("quit", "cmd+q", "⌘Q", "931"), ("switcher", "cmd+k", "⌘K", "930"),
           ("shell", "ctrl+\\", "⌃\\", ""))

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
    """FORWARD less every chord the person bound themselves (the panel, an extra):
    [(action, chord, glyph, code)]. `extra`: the FLEET_KEYS_EXTRA text to read
    (the machine passes what the client carried), else this computer's."""
    if not panel():
        return []       # FLEET_KEY_PANEL=off: no panel to forward to

    def ident(c):
        return iterm_key(c) or tmux_key(c)
    words = re.findall(r"[a-z]+", " ".join(f[0] for f in FORWARD) + " quickopen zoom fold")
    taken = {ident(c) for _, c in pairs(client_extra() if extra is None else extra, set(words))}
    if panel():
        taken.add(ident(panel()))
    return [f for f in FORWARD if ident(f[1]) not in taken]


def phone():
    return setting("FLEET_KEY_PHONE", default=DEFAULT_PHONE).split()


def phone_extra():
    return setting("FLEET_KEYS_PHONE_EXTRA", default="")


def old_presses(log, days=7):
    """`<n> <key> <k> · …` — how often in the last `days` the keys issue #3328 took
    away were pressed (their forwards' how=old:<action> lines in view-switch.ndjson),
    most pressed first; `0 ` for none. The doctor's oldkeys row. compat-1v: 下一批删"""
    import json
    import time
    since, by = time.time() - days * 86400, {}
    try:
        lines = open(log, encoding="utf-8").read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and str(r.get("how", "")).startswith("old:") and float(r.get("ts") or 0) >= since:
            k = r.get("key") or r["how"][4:]
            by[k] = by.get(k, 0) + 1
    return "%d %s" % (sum(by.values()), " · ".join("%s %d" % kv for kv in sorted(by.items(), key=lambda kv: -kv[1])))
