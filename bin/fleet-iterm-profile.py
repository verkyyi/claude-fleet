#!/usr/bin/env python3
"""fleet-iterm-profile.py — the iTerm2 Dynamic Profile `fleet` (issue #1903,
EPIC #1906 C10): the profile the client's window runs in on a Mac, whose ⌘ chords
send the private codes conf/tmux-shell.conf catches (⌘↓ ⌘↑ ⌘[ ⌘] ⌘J ⌘↩ ⌘/ ⌘P ⌘N).

    fleet-iterm-profile.py write    write / refresh it (nothing when it is current)
    fleet-iterm-profile.py remove   delete it
    fleet-iterm-profile.py status   `installed` · `absent` · `no-iterm` (exit 0 / 1 / 2)
    fleet-iterm-profile.py json     the profile it would write, on stdout

It is ONE file, ~/Library/Application Support/iTerm2/DynamicProfiles/fleet.json
(FLEET_ITERM_DIR overrides the directory — the selftests' seam). iTerm2 loads it
by itself, no restart. It adds a profile and touches no other: every other key of
it comes from its parent — the profile the window was in when it was written
($ITERM_PROFILE), else iTerm2's default — and its Keyboard Map is the parent's
own map (read from iTerm2's preferences, when they can be read) with the fleet
rows on top. The rows come from `dash-keymap.sh --panel switch list`, the one
table: a ⌘ chord → «Send Escape Sequence» `[<code>~`. One more, not a table row
(issue #1953): ⇧↵ → «Send Hex Code» 0x0a, the newline byte (⌃j) — the writing
area's line break, and the one Claude Code and Codex already read as one; a bare
↵ stays the carriage return that sends.

bin/fleet-shell.sh writes it at each start and reload (so the install line and
every update leave it current) and switches the window into it only around its
own attach — `ESC ] 1337 ; SetProfile=fleet` before, the profile it came from
after — so outside the client iTerm2 behaves as it always did. Nothing happens
off a Mac, or on a Mac with no iTerm2 (no ~/Library/Application Support/iTerm2):
`status` says `no-iterm`, `write` writes nothing. FLEET_ITERM_KEYS=0 removes it
and keeps it away.
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


def build(existing=None):
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
    for row in table():
        base[row["key"]] = {"Action": ACTION_ESCAPE, "Text": "[%s~" % row["code"]}
    base.update(TEXT_KEYS)
    profile = {"Name": NAME, "Guid": GUID, "Keyboard Map": base,
               "Tags": ["claude-fleet"]}
    if parent:
        profile["Dynamic Profile Parent Name"] = parent
    return {"Profiles": [profile]}


def current():
    try:
        return json.loads(profile_path().read_text())
    except (OSError, ValueError):
        return None


def write():
    if os.environ.get("FLEET_ITERM_KEYS") == "0":
        return remove()
    if not has_iterm():
        return 0
    old = current()
    old_profile = (old or {}).get("Profiles", [{}])[0] if old else {}
    text = json.dumps(build(old_profile), indent=2, ensure_ascii=False, sort_keys=True) + "\n"
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
    if cmd == "write":
        return write()
    if cmd == "remove":
        return remove()
    if cmd == "status":
        return status()
    if cmd == "json":
        print(json.dumps(build((current() or {}).get("Profiles", [{}])[0]), indent=2,
                         ensure_ascii=False, sort_keys=True))
        return 0
    print("usage: fleet-iterm-profile.py write|remove|status|json", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
