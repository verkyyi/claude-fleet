#!/bin/bash
# fleet-hooks-emit.sh — materialize the ONE fleet hook table for a given agent
# target (issue #611).
#
# THE SOURCE IS hooks/settings-hooks.json. It is the Claude Code settings.json
# hook block, and it is also what the fleet plugin declares
# (.claude-plugin/plugin.json → "hooks"), so the Claude target needs no
# materialization at all — Claude Code reads that file directly on both install
# paths (copy-merge into settings.json, or the plugin).
#
# The CODEX target used to be a hand-transcoded second copy of the same table,
# inlined as TOML literals in bin/fleet-codex.sh. That is the "手工维护第二份"
# this script removes: the commands now come from the one JSON, and the only
# Codex-specific knowledge — which events Codex has, how its single edit tool is
# named, which hooks read a Claude transcript — is DECLARED in
# hooks/codex-map.json rather than duplicated in shell.
#
# Usage:
#   fleet-hooks-emit.sh --target codex [--root <install-root>] [--event <Event>]
#                       [--plugin-dir <dir>]…
#   fleet-hooks-emit.sh --target claude [--root <install-root>]
#
#   --target codex   prints one `<Event>\t<toml-array>` line per wired event, for
#                    the launcher to pass as `-c hooks.<Event>=<toml>`.
#   --target claude  prints the source table verbatim (JSON) with paths resolved —
#                    the shape INSTALL.md merges into ~/.claude/settings.json.
#   --root <dir>     rewrite the shipped `~/.claude/fleet` path prefix to <dir>,
#                    so a selftest or a re-homed install wires ITS OWN copies
#                    rather than the canonical live install. Default: the parent
#                    of this script's directory.
#   --plugin-dir <d> (codex, repeatable — issue #3123) also merge the plugin at <d>'s
#                    hooks/hooks.json (its ${CLAUDE_PLUGIN_ROOT} spelled as <d>),
#                    through the same codex-map: its groups follow the core's in an
#                    event's array, an event Codex lacks (PreCompact) is dropped with
#                    one stderr line. bin/fleet-codex.sh passes what
#                    `fleet-codex-plugins.py dirs` prints. None = byte for byte as before.
#
# Exit 0 on success; 2 on a missing/unreadable source; 3 on malformed JSON.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"

TARGET=''; OUT_ROOT="$ROOT"; ONLY_EVENT=''; PLUGIN_DIRS=''
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --root)   OUT_ROOT="${2:-}"; shift 2 ;;
    --event)  ONLY_EVENT="${2:-}"; shift 2 ;;
    --plugin-dir) PLUGIN_DIRS="${PLUGIN_DIRS:+$PLUGIN_DIRS
}${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
    *) printf 'fleet-hooks-emit: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$TARGET" in
  codex|claude) : ;;
  *) printf 'fleet-hooks-emit: --target must be codex or claude\n' >&2; exit 2 ;;
esac

SRC="$ROOT/hooks/settings-hooks.json"
MAP="$ROOT/hooks/codex-map.json"
[ -r "$SRC" ] || { printf 'fleet-hooks-emit: cannot read %s\n' "$SRC" >&2; exit 2; }
[ "$TARGET" = codex ] && { [ -r "$MAP" ] || { printf 'fleet-hooks-emit: cannot read %s\n' "$MAP" >&2; exit 2; }; }

SRC="$SRC" MAP="$MAP" TARGET="$TARGET" OUT_ROOT="$OUT_ROOT" ONLY_EVENT="$ONLY_EVENT" PLUGIN_DIRS="$PLUGIN_DIRS" \
python3 - <<'PY'
import json, os, sys

src, mapf = os.environ["SRC"], os.environ["MAP"]
target, out_root = os.environ["TARGET"], os.environ["OUT_ROOT"]
only = os.environ.get("ONLY_EVENT") or ""

# The shipped table names the canonical live install; a re-homed install (or a
# selftest running out of a worktree) wires its own copies instead.
SHIPPED_PREFIX = "~/.claude/fleet"

def die(msg, code=3):
    sys.stderr.write("fleet-hooks-emit: %s\n" % msg); sys.exit(code)

try:
    table = json.load(open(src)).get("hooks", {})
except Exception as e:
    die("malformed %s: %s" % (src, e))
if not isinstance(table, dict) or not table:
    die("no hooks block in %s" % src)

def rehome(cmd):
    """Point a shipped `~/.claude/fleet/...` command at THIS install.

    Only the path token is rewritten, and it comes back single-quoted: unlike the
    shipped `~`-prefixed literal (which must stay unquoted so the shell expands
    it), a resolved absolute path may contain spaces, and both consumers hand the
    command to a shell.
    """
    if out_root == SHIPPED_PREFIX:
        return cmd
    q = out_root.replace("'", "'\\''")
    return " ".join(
        "'" + q + tok[len(SHIPPED_PREFIX):] + "'" if tok.startswith(SHIPPED_PREFIX + "/") else tok
        for tok in cmd.split(" ")
    )


if target == "claude":
    out = {"hooks": {}}
    for ev, groups in table.items():
        if only and ev != only:
            continue
        ng = []
        for g in groups:
            e = dict(g)
            e["hooks"] = [dict(h, command=rehome(h["command"])) for h in g.get("hooks", [])]
            ng.append(e)
        out["hooks"][ev] = ng
    json.dump(out, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    sys.exit(0)

# --- codex --------------------------------------------------------------------
try:
    m = json.load(open(mapf))
except Exception as e:
    die("malformed %s: %s" % (mapf, e))
# events: true = wired; anything else (a string) is the REASON it is not.
events = {k: v for k, v in m.get("events", {}).items() if v is True}
matchers = m.get("matchers", {})       # old -> new, or null to drop the group
drops = m.get("drop_commands", {})     # substring -> reason

def re_ver(d):
    """A plugin cache dir is <name>/<version>: name the plugin, not its version."""
    import re
    return re.match(r"^\d+(\.\d+)*", os.path.basename(d.rstrip("/"))) is not None

def toml_str(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')

# Plugin hook tables (issue #3123): each one's groups after the core's, same map.
plugin_groups = {}
for pdir in [d for d in os.environ.get("PLUGIN_DIRS", "").split("\n") if d]:
    try:
        ptable = json.load(open(os.path.join(pdir, "hooks", "hooks.json"))).get("hooks") or {}
    except FileNotFoundError:
        continue
    except Exception as e:
        sys.stderr.write("fleet-hooks-emit: %s/hooks/hooks.json unreadable (%s) — skipped\n" % (pdir, e))
        continue
    pname = os.path.basename(os.path.dirname(pdir.rstrip("/"))) if re_ver(pdir) else os.path.basename(pdir.rstrip("/"))
    for ev, groups in ptable.items():
        if ev not in events:
            why = m.get("events", {}).get(ev) or "not a Codex event"
            sys.stderr.write("fleet-hooks-emit: plugin %s: %s not carried — %s\n" % (pname, ev, why))
            continue
        for g in groups or []:
            e = dict(g)
            e["hooks"] = [dict(h, command=str(h.get("command", "")).replace("${CLAUDE_PLUGIN_ROOT}", pdir))
                          for h in g.get("hooks", [])]
            plugin_groups.setdefault(ev, []).append(e)

emitted = 0
for ev in list(table) + [e for e in plugin_groups if e not in table]:
    if ev not in events:
        continue
    if only and ev != only:
        continue
    groups = []
    for g in table.get(ev, []) + plugin_groups.get(ev, []):
        matcher = g.get("matcher")
        if matcher is not None:
            if matcher in matchers:
                if matchers[matcher] is None:
                    continue                      # no such tool on Codex
                matcher = matchers[matcher]
        hooks = [h for h in g.get("hooks", [])
                 if not any(d in h.get("command", "") for d in drops)]
        if not hooks:
            continue
        parts = ",".join("{type=%s,command=%s}"
                         % (toml_str(h.get("type", "command")), toml_str(rehome(h["command"])))
                         for h in hooks)
        groups.append("{%shooks=[%s]}"
                      % ("matcher=%s," % toml_str(matcher) if matcher is not None else "", parts))
    if not groups:
        continue
    sys.stdout.write("%s\t[%s]\n" % (ev, ",".join(groups)))
    emitted += 1

if emitted == 0:
    die("no events wired for the codex target — check hooks/codex-map.json", 3)
PY
