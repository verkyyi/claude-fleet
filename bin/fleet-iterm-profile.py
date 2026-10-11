#!/usr/bin/env python3
"""fleet-iterm-profile.py — the iTerm2 Dynamic Profile `fleet` (issue #1903,
EPIC #1906 C10): the profile the client's window runs in on a Mac, whose ⌘ chords
send the private codes the 看台 (conf/tmux-view.conf) and the old client
(conf/tmux-shell.conf) catch.

    fleet-iterm-profile.py write [--all]   write / refresh it (nothing when it is current)
    fleet-iterm-profile.py remove          delete it
    fleet-iterm-profile.py status          `installed` · `absent` · `no-iterm` (exit 0 / 1 / 2)
    fleet-iterm-profile.py json [--all]    the profile it would write, on stdout

Which ⌘ chords (issue #3185, EPIC #3178 C7): ONE by default — FLEET_KEY_PANEL
(⌘P, the panel; `off` none) — plus every ⌘ chord the person names in
FLEET_KEYS_EXTRA (`next=cmd+down …`), both fleet.conf [client] (bin/fleet_keys.py
reads them). Every other ⌘ key is the parent's — except, for ONE version (issue
#3328, compat-1v), the ⌘ keys that went: ⌘↓ ⌘↑ ⌘[ ⌘] ⌘N ⌘T ⌘Q ⌘K still send their
old code, which the 看台 turns into the panel + a one-time 「已并进 ⌘P」
(fleet_keys.FORWARD); the next batch gives them back to iTerm2. `--all` (the old client, `fleet --old`) writes every row of the table at its
own chord, as before.

It is ONE file, ~/Library/Application Support/iTerm2/DynamicProfiles/fleet.json
(FLEET_ITERM_DIR overrides the directory — the selftests' seam). iTerm2 loads it
by itself, no restart. It adds a profile and touches no other: every other key of
it comes from its parent — the profile the window was in when it was written
($ITERM_PROFILE), else iTerm2's default — and its Keyboard Map is the parent's
own map (read from iTerm2's preferences, when they can be read) with the fleet
rows on top. The rows come from `dash-keymap.sh --panel switch list`, the one
table: a ⌘ chord → «Send Escape Sequence» `[<code>~`. Its left ⌥ sends Esc+ (issue
#2760: ⌥← ⌥→ move by word, as in a local Claude; FLEET_KEYS_PARITY=0 leaves the
parent's). One more, not a table row
(issue #1953): ⇧↵ → «Send Hex Code» 0x0a, the newline byte (⌃j) — the writing
area's line break, and the one Claude Code and Codex already read as one; a bare
↵ stays the carriage return that sends.

bin/fleet-thin.py writes it at each start, bin/fleet-shell.sh (`--all`) at each
of its starts and reloads (so the install line and every update leave it current) and switches the window into it only around its
own attach — `ESC ] 1337 ; SetProfile=fleet` before, the profile it came from
after — so outside the client iTerm2 behaves as it always did. Nothing happens
off a Mac, or on a Mac with no iTerm2 (no ~/Library/Application Support/iTerm2):
`status` says `no-iterm`, `write` writes nothing. FLEET_ITERM_KEYS=0 removes it
and keeps it away.

`write` also lets programs in the terminal set the clipboard (issue #2758): a copy
made in a session reaches the Mac as OSC 52, and iTerm2 drops one unless
「Applications in terminal may access clipboard」 (Settings → General → Selection,
the preference `AllowClipboardAccess`) is on — off by default. It is APP-WIDE:
iTerm2 reads it for every OSC 52 / OSC 1337 Copy and has no per-profile key, so
it cannot live in this profile. So `write` turns it on ONCE (`defaults write`,
which the running iTerm2 picks up at once) and leaves a mark
(~/.config/claude-fleet/iterm-clipboard; FLEET_ITERM_CLIP_MARK overrides): a
person who turns it off afterwards keeps it off — the doctor's `clipboard` row
(fleet-agent-bundle.py) then says where to turn it back on. With FLEET_ITERM_DIR
set (a selftest) it touches iTerm2's preferences only through FLEET_ITERM_PREFS,
never the real ones.
"""
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

BIN = Path(__file__).absolute().parent
NAME = "fleet"
GUID = "claude-fleet-client-keys"
# iTerm2's «Send Escape Sequence» key action: ESC, then the Text.
ACTION_ESCAPE = 10
# ⇧↵ (issue #1953): «Send Hex Code» (action 11) 0x0a — tmux has no extended keys
# here, so without it ⇧↵ arrives as a bare ↵ and a second line cannot be written.
ACTION_HEX = 11
SHIFT_RETURN = "0xd-0x20000"
TEXT_KEYS = {SHIFT_RETURN: {"Action": ACTION_HEX, "Text": "0x0a"}}
# ⌥← ⌥→ by word, as a local Claude does (issue #2760, EPIC #2756 C4): the LEFT ⌥
# sends Esc+ (iTerm2's «Option Key Sends» 2) — ⌥← reaches the session as a
# meta arrow, ⌥b / ⌥f as meta letters. The right ⌥ keeps the parent's (typing
# special characters). FLEET_KEYS_PARITY=0 leaves it to the parent, as before.
LEFT_OPTION = "Option Key Sends"
OPTION_ESC = 2


def iterm_home():
    return Path(os.path.expanduser("~/Library/Application Support/iTerm2"))


def profile_dir():
    env = os.environ.get("FLEET_ITERM_DIR")
    if env:
        return Path(env)
    return iterm_home() / "DynamicProfiles"


def profile_path():
    return profile_dir() / ("%s.json" % NAME)


def has_iterm():
    if os.environ.get("FLEET_ITERM_DIR"):
        return True
    return sys.platform == "darwin" and iterm_home().is_dir()


def table():
    out = subprocess.run(["bash", str(BIN / "dash-keymap.sh"), "--panel", "switch", "list"],
                         capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines():
        f = line.split()
        if len(f) == 5:
            rows.append({"action": f[0], "glyph": f[1], "key": f[2], "code": f[3], "prefix": f[4]})
    return rows


def rows(all_rows=False):
    """[(iTerm2 key, code)] — the ⌘ chords this profile turns into codes. A new
    client (issue #3185, EPIC #3178 C7): the panel, FLEET_KEY_PANEL (⌘P unless the
    person moved it, none for `off`), plus each ⌘ chord of FLEET_KEYS_EXTRA — every
    other ⌘ key stays the parent's, i.e. iTerm2's own. `all_rows` (the old client,
    fleet-shell.sh): every row of the table at its own chord, as before."""
    t = table()
    if all_rows:
        return [(r["key"], r["code"]) for r in t]
    sys.path.insert(0, str(BIN))
    import fleet_keys
    codes = {r["action"]: r["code"] for r in t}
    out = []
    panel = fleet_keys.iterm_key(fleet_keys.panel())
    if panel and "quickopen" in codes:
        out.append((panel, codes["quickopen"]))
    for action, chord in fleet_keys.pairs(fleet_keys.client_extra(), set(codes) | set(fleet_keys.CODELESS)):
        key = fleet_keys.iterm_key(chord)
        if key and action in codes:
            out.append((key, codes[action]))
    # the keys issue #3328 took away, one version long: their old code, which the
    # 看台 binds to the panel + a one-time hint (fleet_keys.FORWARD). compat-1v: 下一批删
    for _, chord, _, code in fleet_keys.forwards():
        key = fleet_keys.iterm_key(chord)
        if key and code:
            out.append((key, code))
    return out


def prefs():
    """iTerm2's own profiles, or [] when its preferences cannot be read."""
    path = Path(os.environ.get("FLEET_ITERM_PREFS") or
                os.path.expanduser("~/Library/Preferences/com.googlecode.iterm2.plist"))
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except Exception:  # absent, unreadable, a format this python cannot parse
        return [], ""
    return data.get("New Bookmarks") or [], data.get("Default Bookmark Guid") or ""


def parent_name(existing):
    """The profile this one inherits from: the window's own, unless that is
    already `fleet` (the client writing from inside itself) — then whatever the
    file named before."""
    name = os.environ.get("ITERM_PROFILE", "")
    if name and name != NAME:
        return name
    return existing.get("Dynamic Profile Parent Name", "")


def build(existing=None, all_rows=False):
    existing = existing or {}
    parent = parent_name(existing)
    profiles, default_guid = prefs()
    base = {}
    for p in profiles:
        if (parent and p.get("Name") == parent) or (not parent and p.get("Guid") == default_guid):
            for key, val in (p.get("Keyboard Map") or {}).items():
                try:
                    json.dumps(val)
                except (TypeError, ValueError):
                    continue  # a value JSON cannot hold (plist data): left to the parent
                base[key] = val
            break
    for key, code in rows(all_rows):
        base[key] = {"Action": ACTION_ESCAPE, "Text": "[%s~" % code}
    base.update(TEXT_KEYS)
    profile = {"Name": NAME, "Guid": GUID, "Keyboard Map": base,
               "Tags": ["claude-fleet"]}
    if os.environ.get("FLEET_KEYS_PARITY") != "0":
        profile[LEFT_OPTION] = OPTION_ESC
    if parent:
        profile["Dynamic Profile Parent Name"] = parent
    return {"Profiles": [profile]}


CLIP_KEY = "AllowClipboardAccess"


def clip_mark():
    return Path(os.environ.get("FLEET_ITERM_CLIP_MARK") or
                os.path.expanduser("~/.config/claude-fleet/iterm-clipboard"))


def clip_read():
    """(readable, value): value None when unset."""
    test = os.environ.get("FLEET_ITERM_PREFS")
    if test:
        try:
            with open(test, "rb") as f:
                return True, plistlib.load(f).get(CLIP_KEY)
        except Exception:
            return False, None
    r = subprocess.run(["defaults", "read", "com.googlecode.iterm2", CLIP_KEY],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return True, None  # the key is not there: iTerm2's default, off
    return True, r.stdout.strip() in ("1", "true", "YES")


def clip_on():
    test = os.environ.get("FLEET_ITERM_PREFS")
    if test:
        with open(test, "rb") as f:
            data = plistlib.load(f)
        data[CLIP_KEY] = True
        with open(test, "wb") as f:
            plistlib.dump(data, f)
        return True
    r = subprocess.run(["defaults", "write", "com.googlecode.iterm2", CLIP_KEY, "-bool", "true"],
                       capture_output=True)
    return r.returncode == 0


def clipboard():
    """Turn iTerm2's clipboard permission on once (see the docstring)."""
    if os.environ.get("FLEET_ITERM_DIR") and not os.environ.get("FLEET_ITERM_PREFS"):
        return  # a selftest's profile dir: never the real preferences
    mark = clip_mark()
    if mark.exists():
        return  # done once; whatever it is now is the person's
    readable, val = clip_read()
    if not readable:
        return
    try:
        if val is not True and not clip_on():
            return
        mark.parent.mkdir(parents=True, exist_ok=True)
        mark.write_text("AllowClipboardAccess turned on by fleet-iterm-profile.py (issue #2758)\n")
    except Exception:
        return


def current():
    try:
        return json.loads(profile_path().read_text())
    except (OSError, ValueError):
        return None


def write(all_rows=False):
    if os.environ.get("FLEET_ITERM_KEYS") == "0":
        return remove()
    if not has_iterm():
        return 0
    clipboard()
    old = current()
    old_profile = (old or {}).get("Profiles", [{}])[0] if old else {}
    text = json.dumps(build(old_profile, all_rows), indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    path = profile_path()
    try:
        if path.read_text() == text:
            return 0
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(text)
    os.replace(str(tmp), str(path))
    return 0


def remove():
    try:
        profile_path().unlink()
    except FileNotFoundError:
        pass
    return 0


def status():
    if not has_iterm():
        print("no-iterm")
        return 2
    if current() is not None:
        print("installed")
        return 0
    print("absent")
    return 1


def main(argv):
    cmd = argv[0] if argv else "status"
    all_rows = "--all" in argv[1:]
    if cmd == "write":
        return write(all_rows)
    if cmd == "remove":
        return remove()
    if cmd == "status":
        return status()
    if cmd == "json":
        print(json.dumps(build((current() or {}).get("Profiles", [{}])[0], all_rows), indent=2,
                         ensure_ascii=False, sort_keys=True))
        return 0
    print("usage: fleet-iterm-profile.py write [--all]|remove|status|json [--all]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
