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
         --via R (issue #1725): a client-only computer has no ~/.claude/fleet,
         so each command `<interp> ~/.claude/fleet/<d>/<name> …` is wired as
         `sh "R/bin/fleet-hook-run.sh" <interp> ~/.claude/fleet/<d>/<name> …` —
         same identity, so a later node sync replaces it in place.
  check  [--settings F] [--source F] [--plugin] [--via R]
         Read-only. Prints `ok …` (exit 0) or one line per problem — duplicate /
         missing / stale identity — (exit 1). fleet-doctor's `hooks` line.
         --plugin: the fleet plugin already wires the table, so the right number
         of fleet entries in settings.json is ZERO — any one of them fires twice.

  defaults [--defaults F] [--settings F] [--config F] [--override F] [--skip KEY]…
           [--dry-run]
         Issue #1558 (folds #1528). conf/claude-settings.default.json is the ONE
         default Claude configuration for every login on a managed machine:
         its "settings" section fills ~/.claude/settings.json (today
         permissions.defaultMode=bypassPermissions, skipDangerousModePermissionPrompt,
         effortLevel, outputStyle, theme, tui, precomputeCompactionEnabled,
         agentPushNotifEnabled — never model or enabledPlugins, those stay the
         login's), its "globalConfig" section fills Claude Code's GLOBAL config
         ~/.claude.json ($CLAUDE_CONFIG_DIR/.claude.json when set) — today
         leftArrowOpensAgents=false, the only place that key is read (in
         settings.json it does nothing, measured on 2.1.289). FILL ONLY: a key
         the login lacks is set, a key it has — any value — is never overwritten;
         an object default (permissions.defaultMode) fills into an existing
         object leaf by leaf, so the login's permissions.allow survives.
         ~/.claude/settings.fleet-override.json lists keys never written at all
         (a JSON array of dotted paths, or an object keyed by them); --skip KEY
         adds one from the command line (FLEET_KEEP_AGENTS_KEY=1 →
         --skip leftArrowOpensAgents). The .claude.json write takes the lock
         Claude Code itself takes (proper-lockfile: mkdir <file>.lock), re-reads
         the file under it and replaces it atomically; no such file yet (Claude
         Code never ran on this login) → nothing written there. Idempotent: a
         second run writes nothing.
  defaults-check [--defaults F] [--settings F] [--config F] [--override F] [--skip KEY]…
         Read-only: `ok N default key(s) in place` (exit 0) or `N key(s) differ
         from …` and one line per key that is missing or differs (exit 1); a
         shielded key is neither. fleet-doctor's `settings` line.

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
DEFAULT_DEFAULTS = os.path.join(os.path.dirname(HERE), "conf", "claude-settings.default.json")
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


# A client-only computer (issue #1725) has no ~/.claude/fleet: --via <root> wires
# each hook through <root>/bin/fleet-hook-run.sh, the wired path kept as its
# argument so the identity above is unchanged.
_WIRED = re.compile(r"^(\S+)\s+((?:~|\$HOME)/\.claude/fleet/(?:hooks|bin)/\S+)(.*)$", re.S)
def via_spelling(root):
    """<root> as the command spells it: $HOME/… under the home, else absolute."""
    root = os.path.abspath(os.path.expanduser(root))
    home = os.path.abspath(os.path.expanduser("~"))
    # The install line's base IS ~/.claude/fleet (#1804): spelled with a /./ so
    # the identity rule above never takes the shim for the wired script
    if root == os.path.join(home, ".claude", "fleet") and not any(c in root for c in "\"$`\\"):
        return "$HOME/.claude/fleet/."
    if ".claude/fleet/" in root + "/" or any(c in root for c in "\"$`\\"):
        print("fleet-hooks-merge: --via %s cannot carry the hooks (a .claude/fleet path, "
              "or a quote / $ / backslash in it)" % root, file=sys.stderr)
        sys.exit(2)
    if root == home or root.startswith(home + os.sep):
        return "$HOME" + root[len(home):]
    return root
def via_command(command, spelled):
    m = _WIRED.match(command or "")
    if not m:
        return command
    return 'sh "%s/bin/fleet-hook-run.sh" %s %s%s' % (spelled, m.group(1), m.group(2), m.group(3))
def source_table(path, via=None):
    src = load(path)
    if not isinstance(src, dict) or not isinstance(src.get("hooks"), dict):
        print("fleet-hooks-merge: %s has no hooks table" % path, file=sys.stderr)
        sys.exit(2)
    if via:
        spelled = via_spelling(via)
        for groups in src["hooks"].values():
            for g in groups:
                for h in g.get("hooks", []):
                    if "command" in h:
                        h["command"] = via_command(h["command"], spelled)
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


def defaults_table(path):
    """conf/claude-settings.default.json: {"settings": {…}, "globalConfig": {…}} —
    the keys the sync fills into ~/.claude/settings.json and ~/.claude.json. Both
    sections are optional; any other top-level key is a malformed file."""
    src = load(path)
    if src is None:
        print("fleet-hooks-merge: %s missing" % path, file=sys.stderr)
        sys.exit(2)
    if (not isinstance(src, dict)
            or any(k not in ("settings", "globalConfig") for k in src)
            or any(not isinstance(v, dict) for v in src.values())):
        print('fleet-hooks-merge: %s must be {"settings": {…}, "globalConfig": {…}}' % path,
              file=sys.stderr)
        sys.exit(2)
    return src.get("settings", {}), src.get("globalConfig", {})


def override_keys(path):
    """~/.claude/settings.fleet-override.json — the default keys this login keeps
    for itself: a JSON array of dotted paths ("effortLevel",
    "permissions.defaultMode", or "permissions" for the whole object), or an
    object whose keys are those paths (its values are free: a note). Absent → none."""
    src = load(path)
    if src is None:
        return set()
    if isinstance(src, list) and all(isinstance(k, str) for k in src):
        return set(src)
    if isinstance(src, dict):
        return set(src)
    print("fleet-hooks-merge: %s must be a JSON array of key paths, or an object keyed by them"
          % path, file=sys.stderr)
    sys.exit(2)


def leaves(obj, prefix=""):
    """A defaults section as (dotted path, value) leaves: a non-empty object is a
    branch, anything else (a scalar, a list, {}) is a leaf."""
    out = []
    for k in sorted(obj):
        if isinstance(obj[k], dict) and obj[k]:
            out.extend(leaves(obj[k], prefix + k + "."))
        else:
            out.append((prefix + k, obj[k]))
    return out


def shielded(path, blocked):
    """A path is kept for the login when it, or any ancestor of it, is listed."""
    parts = path.split(".")
    return any(".".join(parts[:i]) in blocked for i in range(1, len(parts) + 1))


def fill(target, want, blocked, label):
    """Fill-only merge of the defaults section `want` into `target`. A leaf the
    target lacks is set; a leaf it has — whatever the value — is left exactly as
    it is; a leaf under a blocked path is never written; an ancestor that is the
    login's own scalar is never replaced by an object. Pure: never touches the
    disk. Returns (new, set_lines, differs_lines, kept_paths)."""
    new = json.loads(json.dumps(target))
    sets, owns, kept = [], [], []
    for path, val in leaves(want):
        if shielded(path, blocked):
            kept.append(path)
            continue
        parts = path.split(".")
        cur, scalar_above = new, None
        for i, part in enumerate(parts[:-1]):
            if part in cur and not isinstance(cur[part], dict):
                scalar_above = (".".join(parts[:i + 1]), cur[part])
                break
            cur = cur.setdefault(part, {})
        if scalar_above is not None:
            owns.append("differs    %s %s: %s = %s is not an object (default %s)"
                        % (label, path, scalar_above[0], json.dumps(scalar_above[1]), json.dumps(val)))
            continue
        leaf = parts[-1]
        if leaf in cur:
            if cur[leaf] != val:
                owns.append("differs    %s %s = %s (default %s)"
                            % (label, path, json.dumps(cur[leaf]), json.dumps(val)))
            continue
        cur[leaf] = json.loads(json.dumps(val))
        sets.append("set            %s %s = %s" % (label, path, json.dumps(val)))
    return new, sets, owns, kept


def lookup(target, path):
    """(found, value) for a dotted path; a non-object on the way is not found."""
    cur = target
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return False, None
        cur = cur[part]
    return True, cur


def defaults_problems(target, want, blocked, label):
    """Check lines: each default leaf that is missing or differs (kept ones skipped)."""
    out, kept = [], []
    for path, val in leaves(want):
        if shielded(path, blocked):
            kept.append(path)
            continue
        found, cur = lookup(target, path)
        if not found:
            out.append("missing    %s %s (default %s)" % (label, path, json.dumps(val)))
        elif cur != val:
            out.append("differs    %s %s = %s (default %s)" % (label, path, json.dumps(cur), json.dumps(val)))
    return out, kept


def write_settings(path, new, backup=True):
    if backup and os.path.exists(path):
        bak = "%s.bak.%d" % (path, int(time.time()))
        shutil.copy2(path, bak)
        print("backup  %s" % bak)
    # Write through a symlinked settings.json, and keep its mode (it is 0600).
    target = os.path.realpath(path)
    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    tmp = target + ".fleet-hooks-merge.tmp"
    with open(tmp, "w") as f:
        json.dump(new, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if os.path.exists(target):
        shutil.copymode(target, tmp)
    os.replace(tmp, target)
    print("wrote   %s" % path)


def defaults_main(a):
    want_s, want_g = defaults_table(a.defaults)
    override = a.override or os.path.join(os.path.dirname(os.path.abspath(a.settings)),
                                          "settings.fleet-override.json")
    blocked = override_keys(override) | set(a.skip)
    s_label, g_label = os.path.basename(a.settings), os.path.basename(a.config)

    def kept_note(kept):
        return "" if not kept else "; %d left to this login: %s" % (len(kept), ", ".join(kept))

    def as_object(path):
        obj = load(path)
        if obj is not None and not isinstance(obj, dict):
            print("fleet-hooks-merge: %s is not a JSON object" % path, file=sys.stderr)
            sys.exit(2)
        return obj

    settings = as_object(a.settings)
    if settings is None:
        settings = {}          # a login whose settings.json does not exist yet gets one

    if a.action == "defaults-check":
        bad, kept = defaults_problems(settings, want_s, blocked, s_label)
        cfg = as_object(a.config)
        if cfg is None:
            for path, val in leaves(want_g):
                if shielded(path, blocked):
                    kept.append(path)
                else:
                    bad.append("missing    %s %s (default %s) — Claude Code has not run on this login yet"
                               % (g_label, path, json.dumps(val)))
        else:
            bad_g, kept_g = defaults_problems(cfg, want_g, blocked, g_label)
            bad += bad_g
            kept += kept_g
        n = len(leaves(want_s)) + len(leaves(want_g)) - len(kept)
        if not bad:
            print("ok %d default key(s) in place%s" % (n, kept_note(kept)))
            return 0
        print("%d key(s) differ from %s%s" % (len(bad), os.path.basename(a.defaults), kept_note(kept)))
        for line in bad:
            print(line)
        return 1

    # defaults — settings.json first (Claude Code writes it whole and takes no
    # lock; the hooks merge writes it the same way), then .claude.json under
    # Claude Code's own lock, re-read inside it.
    new_s, sets, owns, kept = fill(settings, want_s, blocked, s_label)
    for line in sets + owns:
        print(line)
    if sets and not a.dry_run:
        write_settings(a.settings, new_s, backup=False)

    g_sets = []

    def apply_cfg():
        cfg = as_object(a.config)
        if cfg is None:
            print("absent  %s — Claude Code has not run on this login yet; its %d key(s) wait for the next sync"
                  % (a.config, len(leaves(want_g))))
            return
        new_g, s2, o2, k2 = fill(cfg, want_g, blocked, g_label)
        for line in s2 + o2:
            print(line)
        g_sets.extend(s2)
        kept.extend(k2)
        if s2 and not a.dry_run:
            write_settings(a.config, new_g, backup=False)

    if want_g:
        if a.dry_run or not os.path.exists(a.config):
            apply_cfg()
        else:
            with_config_lock(a.config, apply_cfg)

    if kept:
        print("kept    %d key(s) left to this login: %s" % (len(kept), ", ".join(kept)))
    if not sets and not g_sets:
        print("unchanged — every default key present, or this login's own")
    elif a.dry_run:
        print("(dry run — nothing written)")
    return 0


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
    ap.add_argument("action", choices=("merge", "check", "defaults", "defaults-check"))
    ap.add_argument("--settings", default=DEFAULT_SETTINGS)
    ap.add_argument("--source", default=DEFAULT_SOURCE)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--plugin", action="store_true")
    ap.add_argument("--defaults", default=DEFAULT_DEFAULTS)
    ap.add_argument("--override", default=None)
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--skip", action="append", default=[])
    ap.add_argument("--via", default=None,
                    help="client-only root: wire each hook through <root>/bin/fleet-hook-run.sh (#1725)")
    a = ap.parse_args()

    if a.action in ("defaults", "defaults-check"):
        return defaults_main(a)

    src_hooks, table = source_table(a.source, a.via)
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
