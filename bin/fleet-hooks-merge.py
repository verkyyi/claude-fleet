#!/usr/bin/env python3
"""Merge the fleet hook table into settings.json by IDENTITY, not by string.

Issue #818. The old /fleet-sync-install step 4 appended hooks/settings-hooks.json
to ~/.claude/settings.json and de-duplicated on the command STRING. The moment a
command's text changed (`/opt/homebrew/bin/python3 …guard.py` -> `python3
…guard.py`) the old entry no longer matched, the new one was appended beside it,
and every Bash / Edit / Artifact call ran the same guard twice.

A fleet hook's identity is (event, matcher, script basename) — the basename of
the `.claude/fleet/{hooks,bin}/<name>` path the command runs. The interpreter,
the arguments and the path spelling (~ vs $HOME vs absolute) are NOT identity.

  merge  [--settings F] [--source F] [--dry-run]
         For every identity in the source table: the FIRST existing entry is
         replaced in place by the source's hook object, every later one is
         removed; an identity with no entry is appended. A fleet-path entry whose
         identity is no longer in the table (a retired hook, or one whose matcher
         changed) is removed too — it fires a script the table no longer wires.
         Anything that is not a fleet-path hook is left exactly as it was.
         Backs the file up to <settings>.bak.<epoch> before writing, and writes
         nothing at all when the result is unchanged. Prints one line per change.
  check  [--settings F] [--source F] [--plugin]
         Read-only. Prints `ok …` (exit 0) or one line per problem — duplicate /
         missing / stale identity — (exit 1). fleet-doctor's `hooks` line.
         --plugin: the fleet plugin already wires the table, so the right number
         of fleet entries in settings.json is ZERO — any one of them fires twice.

  keys   [--config F] [--keys F] [--skip KEY]… [--dry-run]
         Issue #1528. Keys the fleet pins in Claude Code's GLOBAL config
         (hooks/global-config-keys.json — today `leftArrowOpensAgents: false`, so
         a stray ← never drops a pane into the agents view). That key is read
         from ~/.claude.json ($CLAUDE_CONFIG_DIR/.claude.json when set), NOT
         settings.json: in settings.json, or via --settings, it does nothing
         (measured on 2.1.289). Sets each key whose value differs or is absent;
         every other key is left exactly as it was. The write takes the lock
         Claude Code itself takes (proper-lockfile: mkdir <file>.lock), re-reads
         the file under it and replaces it atomically, so a running session's
         own save cannot interleave. No such file yet (Claude Code never ran on
         this login) → nothing written. --skip KEY leaves that key to the login
         (the FLEET_KEEP_AGENTS_KEY=1 opt-out).
  keys-check [--config F] [--keys F] [--skip KEY]…
         Read-only: `ok …` (exit 0) or one line per key that is missing or
         differs (exit 1). fleet-doctor's `setkeys` line.

Exit: 0 ok · 1 check found problems · 2 unreadable/malformed input.
"""
import argparse
import json
import os
import re
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SOURCE = os.path.join(os.path.dirname(HERE), "hooks", "settings-hooks.json")
DEFAULT_KEYS = os.path.join(os.path.dirname(HERE), "hooks", "global-config-keys.json")
DEFAULT_CONFIG = os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~"), ".claude.json")
DEFAULT_SETTINGS = os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "settings.json")

# The script a fleet hook runs lives under the install root's hooks/ or bin/.
_FLEET_SCRIPT = re.compile(r"\.claude/fleet/(?:hooks|bin)/([^/\s'\"]+)")


def script_of(command):
    """Basename of the fleet script `command` runs, or None for a non-fleet hook."""
    m = _FLEET_SCRIPT.search(command or "")
    return m.group(1) if m else None


def identity(event, group, hook):
    """(event, matcher, basename) — the ONE identity rule sync and doctor share."""
    base = script_of(hook.get("command"))
    if base is None:
        return None
    return (event, group.get("matcher", "") or "", base)


def fmt(ident):
    ev, matcher, base = ident
    return "%s[%s] %s" % (ev, matcher or "*", base)


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        print("fleet-hooks-merge: cannot read %s: %s" % (path, e), file=sys.stderr)
        sys.exit(2)


def source_table(path):
    src = load(path)
    if not isinstance(src, dict) or not isinstance(src.get("hooks"), dict):
        print("fleet-hooks-merge: %s has no hooks table" % path, file=sys.stderr)
        sys.exit(2)
    table = {}   # identity -> (group-without-hooks, hook)
    for ev, groups in src["hooks"].items():
        for g in groups:
            for h in g.get("hooks", []):
                ident = identity(ev, g, h)
                if ident is None:
                    continue
                if ident in table:
                    print("fleet-hooks-merge: %s is wired twice in %s" % (fmt(ident), path),
                          file=sys.stderr)
                    sys.exit(2)
                table[ident] = ({k: v for k, v in g.items() if k != "hooks"}, h)
    return src["hooks"], table


def census(settings):
    """identity -> count of fleet-path hook entries in a settings object."""
    counts = {}
    for ev, groups in (settings.get("hooks") or {}).items():
        for g in groups or []:
            for h in g.get("hooks", []) or []:
                ident = identity(ev, g, h)
                if ident is not None:
                    counts[ident] = counts.get(ident, 0) + 1
    return counts


def problems(settings, table):
    counts = census(settings)
    out = []
    for ident, n in sorted(counts.items()):
        if ident not in table:
            out.append("stale      %s — not in the hook table (retired or matcher changed)" % fmt(ident))
        elif n > 1:
            out.append("duplicate  %s ×%d — the hook fires %d times per event" % (fmt(ident), n, n))
    for ident in sorted(table):
        if ident not in counts:
            out.append("missing    %s" % fmt(ident))
    return out


def merge(settings, src_hooks, table):
    """Return (new_settings, change_lines). Pure: never touches the disk."""
    new = json.loads(json.dumps(settings))
    hooks = new.setdefault("hooks", {})
    seen = set()
    changes = []
    for ev in list(hooks):
        kept_groups = []
        for g in hooks[ev] or []:
            entries = g.get("hooks", []) or []
            kept = []
            for h in entries:
                ident = identity(ev, g, h)
                if ident is None:
                    kept.append(h)                       # not ours: untouched
                elif ident not in table:
                    changes.append("removed stale  %s: %s" % (fmt(ident), h.get("command")))
                elif ident in seen:
                    changes.append("removed dup    %s: %s" % (fmt(ident), h.get("command")))
                else:
                    seen.add(ident)
                    want = table[ident][1]
                    if h != want:
                        changes.append("replaced       %s: %s -> %s"
                                       % (fmt(ident), h.get("command"), want.get("command")))
                    kept.append(json.loads(json.dumps(want)))
            if kept or not entries:
                g["hooks"] = kept
                kept_groups.append(g)
        hooks[ev] = kept_groups
    # Append what is missing, in source order, grouped as the source groups them.
    for ev, groups in src_hooks.items():
        for g in groups:
            add = [h for h in g.get("hooks", [])
                   if identity(ev, g, h) is not None and identity(ev, g, h) not in seen]
            if not add:
                continue
            grp = {k: v for k, v in g.items() if k != "hooks"}
            grp["hooks"] = json.loads(json.dumps(add))
            hooks.setdefault(ev, []).append(grp)
            for h in add:
                seen.add(identity(ev, g, h))
                changes.append("appended       %s: %s" % (fmt(identity(ev, g, h)), h.get("command")))
    return new, changes


def keys_table(path, skip):
    src = load(path)
    if not isinstance(src, dict):
        print("fleet-hooks-merge: %s is not a JSON object" % path, file=sys.stderr)
        sys.exit(2)
    return {k: v for k, v in src.items() if k not in skip}


def keys_problems(settings, want):
    out = []
    for k in sorted(want):
        if k not in settings:
            out.append("missing    %s (want %s)" % (k, json.dumps(want[k])))
        elif settings[k] != want[k]:
            out.append("differs    %s: %s (want %s)" % (k, json.dumps(settings[k]), json.dumps(want[k])))
    return out


def keys_merge(settings, want):
    """Return (new_settings, change_lines). Pure: never touches the disk."""
    new = json.loads(json.dumps(settings))
    changes = []
    for k in sorted(want):
        if k in new and new[k] == want[k]:
            continue
        old = json.dumps(new[k]) if k in new else "(absent)"
        new[k] = json.loads(json.dumps(want[k]))
        changes.append("set            %s: %s -> %s" % (k, old, json.dumps(want[k])))
    return new, changes


def write_settings(path, new, backup=True):
    if backup and os.path.exists(path):
        bak = "%s.bak.%d" % (path, int(time.time()))
        shutil.copy2(path, bak)
        print("backup  %s" % bak)
    # Write through a symlinked settings.json, and keep its mode (it is 0600).
    target = os.path.realpath(path)
    tmp = target + ".fleet-hooks-merge.tmp"
    with open(tmp, "w") as f:
        json.dump(new, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if os.path.exists(target):
        shutil.copymode(target, tmp)
    os.replace(tmp, target)
    print("wrote   %s" % path)


def keys_main(a):
    want = keys_table(a.keys, set(a.skip))
    skipped = "" if not a.skip else " (left to this login: %s)" % ", ".join(sorted(a.skip))

    def current():
        cfg = load(a.config)
        if cfg is not None and not isinstance(cfg, dict):
            print("fleet-hooks-merge: %s is not a JSON object" % a.config, file=sys.stderr)
            sys.exit(2)
        return cfg

    if a.action == "keys-check":
        cfg = current()
        if cfg is None:
            print("missing    %s — Claude Code has not run on this login yet" % a.config)
            return 1
        bad = keys_problems(cfg, want)
        if not bad:
            print("ok %d global config key(s) set in %s%s" % (len(want), a.config, skipped))
            return 0
        for line in bad:
            print(line)
        return 1

    def apply():
        cfg = current()
        if cfg is None:
            print("absent  %s — Claude Code has not run on this login yet; nothing written" % a.config)
            return 0
        new, changes = keys_merge(cfg, want)
        if not changes:
            print("unchanged — every fleet global config key already set%s" % skipped)
            return 0
        for line in changes:
            print(line)
        if a.dry_run:
            print("(dry run — %s not written)" % a.config)
            return 0
        write_settings(a.config, new, backup=False)
        return 0

    if a.dry_run or not os.path.exists(a.config):
        return apply()
    return with_config_lock(a.config, apply)


def with_config_lock(path, fn, wait=None):
    """Run fn() holding Claude Code's own lock on `path` (proper-lockfile: an
    mkdir'd `<realpath>.lock` dir). Never steals a lock — a holder past `wait`
    is an error, not a race this script wins."""
    if wait is None:
        wait = float(os.environ.get("FLEET_KEYS_LOCK_WAIT") or 5)
    lock = os.path.realpath(path) + ".lock"
    deadline = time.time() + wait
    while True:
        try:
            os.mkdir(lock)
            break
        except FileExistsError:
            if time.time() >= deadline:
                print("fleet-hooks-merge: %s is held (a Claude Code save in flight?) — try again"
                      % lock, file=sys.stderr)
                sys.exit(2)
            time.sleep(0.1)
    try:
        return fn()
    finally:
        try:
            os.rmdir(lock)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("merge", "check", "keys", "keys-check"))
    ap.add_argument("--settings", default=DEFAULT_SETTINGS)
    ap.add_argument("--source", default=DEFAULT_SOURCE)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--plugin", action="store_true")
    ap.add_argument("--keys", default=DEFAULT_KEYS)
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--skip", action="append", default=[])
    a = ap.parse_args()

    if a.action in ("keys", "keys-check"):
        return keys_main(a)

    src_hooks, table = source_table(a.source)
    settings = load(a.settings)
    if settings is None:
        settings = {}
    if not isinstance(settings, dict):
        print("fleet-hooks-merge: %s is not a JSON object" % a.settings, file=sys.stderr)
        return 2

    if a.action == "check" and a.plugin:
        dup = sorted(census(settings))
        if not dup:
            print("ok %d fleet hook(s), wired by the fleet plugin" % len(table))
            return 0
        for ident in dup:
            print("duplicate  %s — in settings.json AND the fleet plugin" % fmt(ident))
        return 1
    if a.action == "check":
        bad = problems(settings, table)
        if not bad:
            print("ok %d fleet hook(s), each wired once" % len(table))
            return 0
        for line in bad:
            print(line)
        return 1

    new, changes = merge(settings, src_hooks, table)
    if not changes:
        print("unchanged — every fleet hook already wired once")
        return 0
    for line in changes:
        print(line)
    if a.dry_run:
        print("(dry run — %s not written)" % a.settings)
        return 0
    write_settings(a.settings, new)
    return 0


if __name__ == "__main__":
    sys.exit(main())
