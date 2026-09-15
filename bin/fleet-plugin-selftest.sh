#!/bin/bash
# fleet-plugin-selftest.sh — the fleet ships as a Claude Code plugin (issue #611).
#
# The repo root IS the plugin: .claude-plugin/plugin.json declares the fleet
# commands, the skills/ tree and the hook table, and .claude-plugin/marketplace.json
# serves it from this same repo (`"source": "./"`). A teammate installs with
# `/plugin marketplace add verkyyi/claude-fleet` + `/plugin install fleet@claude-fleet`
# instead of hand-copying commands/*.md and hand-merging hooks into settings.json.
#
# What this pins — each one a way the plugin could silently stop being the thing
# the repo actually ships:
#
#   1. BOTH MANIFESTS ARE VALID — structurally, and (when the CLI is present)
#      according to `claude plugin validate`, with NO errors.
#   2. THE COMMAND LIST DOES NOT DRIFT — plugin.json's explicit `commands` array
#      is exactly the set of fleet commands on disk. Adding commands/fleet-foo.md
#      without listing it would ship a command to copy-installs and silently not
#      to plugin-installs; listing a file that no longer exists breaks the load.
#   3. THE DECLARED PATHS RESOLVE — every listed command, the hooks file, and
#      every skill directory exist relative to the plugin root.
#   4. ONE HOOK TABLE — the plugin's hooks path is the SAME file INSTALL.md merges
#      into ~/.claude/settings.json, so the two install paths cannot diverge.
#   5. SKILLS CAN REGISTER — every skills/<name>/SKILL.md carries the name +
#      description frontmatter Claude Code needs to load it.
#   6. NO PINNED VERSION — deliberate. With no `version`, the installed version is
#      the marketplace commit sha (measured: a manifest that omits it installs as
#      `<sha>`), so every merged commit is a new version and `/plugin update`
#      always lands. A hand-pinned semver would freeze updates behind a manual
#      bump — exactly the drift #611 removes.
#   7. BOTH INSTALL SHAPES ARE TYPEABLE — fleet_cmd resolves the bare `/fleet-claim`
#      of a copy install and the namespaced `/fleet:fleet-claim` of a plugin one,
#      so the spawn seed lands as a command either way.
#
# Hermetic: reads the repo, writes only to a temp dir; no network, no tmux, and it
# never touches the operator's real ~/.claude. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
PJ="$ROOT/.claude-plugin/plugin.json"
MJ="$ROOT/.claude-plugin/marketplace.json"

for f in "$PJ" "$MJ"; do
  [ -r "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 required\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-plugin.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
# run a python assertion block; its stdout is the failure detail
py() { PJ="$PJ" MJ="$MJ" ROOT="$ROOT" python3 -c "$1" 2>&1; }

# --- 1. the command list is exactly what is on disk ---------------------------
d="$(py '
import json, os, glob, sys
root = os.environ["ROOT"]
listed = json.load(open(os.environ["PJ"])).get("commands")
if not isinstance(listed, list) or not listed:
    print("plugin.json has no explicit `commands` array — the default scan would also "
          "register commands/README.md and the _template*.md files as slash commands")
    sys.exit(1)
listed_set = set(listed)
on_disk = {"./commands/" + os.path.basename(p)
           for p in glob.glob(os.path.join(root, "commands", "fleet-*.md"))}
missing = on_disk - listed_set
extra = listed_set - on_disk
if missing:
    print("on disk but NOT shipped by the plugin: %s" % sorted(missing))
if extra:
    print("listed in plugin.json but not on disk: %s" % sorted(extra))
sys.exit(1 if (missing or extra) else 0)
')" || fail "plugin.json commands drifted from commands/fleet-*.md" "$d"
ok "the plugin ships exactly the fleet-*.md commands that exist on disk"

# --- 2. every declared path resolves ------------------------------------------
d="$(py '
import json, os, sys
root = os.environ["ROOT"]
m = json.load(open(os.environ["PJ"]))
bad = []
for rel in m.get("commands", []):
    if not os.path.isfile(os.path.join(root, rel)):
        bad.append("commands entry %s" % rel)
hooks = m.get("hooks")
if hooks and not os.path.isfile(os.path.join(root, hooks)):
    bad.append("hooks %s" % hooks)
skills = os.path.join(root, "skills")
if not os.path.isdir(skills):
    bad.append("skills/ directory is missing — the default scan has nothing to load")
if bad:
    print("\n".join(bad)); sys.exit(1)
')" || fail "a path declared in plugin.json does not resolve" "$d"
ok "every command, the hooks file and the skills tree resolve from the plugin root"

# --- 3. ONE hook table, shared with the copy install --------------------------
d="$(py '
import json, os, sys
root = os.environ["ROOT"]
hooks = json.load(open(os.environ["PJ"])).get("hooks")
if hooks != "./hooks/settings-hooks.json":
    print("the plugin declares hooks at %r; INSTALL.md merges hooks/settings-hooks.json "
          "into ~/.claude/settings.json — two files would drift apart" % hooks)
    sys.exit(1)
t = json.load(open(os.path.join(root, "hooks", "settings-hooks.json"))).get("hooks", {})
if not t:
    print("hooks/settings-hooks.json has no hooks block"); sys.exit(1)
for ev, groups in t.items():
    for g in groups:
        for h in g.get("hooks", []):
            c = h.get("command", "")
            if not c:
                print("%s: a hook entry has no command" % ev); sys.exit(1)
            if "${CLAUDE_PLUGIN_ROOT}" in c:
                print("%s: %s uses ${CLAUDE_PLUGIN_ROOT}, whose path changes on EVERY "
                      "plugin update. The fleet hooks must call the stable live install "
                      "(~/.claude/fleet) that the daemons share." % (ev, c))
                sys.exit(1)
')" || fail "the plugin hook table is not the one the copy install merges" "$d"
ok "plugin and copy install share hooks/settings-hooks.json, pointed at the stable live install"

# --- 4. skills carry the frontmatter that makes them load ---------------------
d="$(py '
import os, re, sys
root = os.environ["ROOT"]
sk = os.path.join(root, "skills")
bad, seen = [], 0
for name in sorted(os.listdir(sk)):
    d = os.path.join(sk, name)
    if not os.path.isdir(d):
        continue
    seen += 1
    f = os.path.join(d, "SKILL.md")
    if not os.path.isfile(f):
        bad.append("%s/ has no SKILL.md" % name); continue
    head = open(f, encoding="utf-8").read(4096)
    m = re.match(r"^---\n(.*?)\n---\n", head, re.S)
    if not m:
        bad.append("%s/SKILL.md has no YAML frontmatter" % name); continue
    fm = m.group(1)
    for key in ("name:", "description:"):
        if not re.search(r"^%s" % key, fm, re.M):
            bad.append("%s/SKILL.md frontmatter has no %s" % (name, key))
    got = re.search(r"^name:\s*(\S+)", fm, re.M)
    if got and got.group(1) != name:
        bad.append("%s/SKILL.md declares name: %s" % (name, got.group(1)))
if not seen:
    bad.append("skills/ contains no skill directories")
if bad:
    print("\n".join(bad)); sys.exit(1)
')" || fail "a skill would not register from the plugin" "$d"
ok "every skills/<name>/SKILL.md carries matching name + description frontmatter"

# --- 5. the marketplace serves THIS repo as that plugin -----------------------
d="$(py '
import json, sys
p = json.load(open(__import__("os").environ["PJ"]))
m = json.load(open(__import__("os").environ["MJ"]))
bad = []
if not m.get("name"):  bad.append("marketplace.json has no name")
if not m.get("owner"): bad.append("marketplace.json has no owner")
plugins = m.get("plugins") or []
if len(plugins) != 1:
    bad.append("expected exactly one plugin entry, got %d" % len(plugins))
else:
    e = plugins[0]
    if e.get("name") != p.get("name"):
        bad.append("marketplace serves %r but plugin.json is named %r" % (e.get("name"), p.get("name")))
    if e.get("source") != "./":
        bad.append("marketplace source is %r; the repo root IS the plugin, so it must be \"./\"" % e.get("source"))
    if "version" in e:
        bad.append("the marketplace entry pins a version, which overrides the commit sha "
                   "and freezes /plugin update behind a manual bump")
if "version" in p:
    bad.append("plugin.json pins version %r — omit it so the installed version is the "
               "marketplace commit sha and every merge is a new version" % p["version"])
if bad:
    print("\n".join(bad)); sys.exit(1)
')" || fail "the marketplace does not serve this repo as the fleet plugin" "$d"
ok "marketplace serves the repo root as the plugin, unpinned so each commit is a new version"

# --- 6. the CLI agrees (when it is installed) ---------------------------------
if command -v claude >/dev/null 2>&1; then
  rep="$(claude plugin validate "$ROOT" --json 2>/dev/null)"
  if [ -z "$rep" ]; then
    printf 'note: `claude plugin validate` produced no report — skipping the CLI check\n' >&2
  else
    printf '%s' "$rep" > "$WORK/report.json"
    d="$(REP="$WORK/report.json" python3 -c '
import json, os, sys
r = json.load(open(os.environ["REP"]))
man = r.get("manifest", {})
errs = man.get("errors") or []
if errs or not r.get("success"):
    print(json.dumps(errs or r, indent=2)); sys.exit(1)
# The one expected warning is the deliberate missing version (see the header).
unexpected = [w for w in (man.get("warnings") or []) if "version" not in (w.get("path") or "")]
if unexpected:
    print("unexpected validation warnings:\n%s" % json.dumps(unexpected, indent=2)); sys.exit(1)
' 2>&1)" || fail "claude plugin validate rejected the manifests" "$d"
    ok "claude plugin validate passes with no errors and no unexpected warnings"
  fi
fi

# --- 7. the spawn seed resolves on BOTH install shapes ------------------------
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || fail "could not source fleet-lib.sh"
command -v fleet_cmd >/dev/null 2>&1 || fail "fleet-lib.sh does not define fleet_cmd — the spawn seed cannot adapt"

mkdir -p "$WORK/copy/commands" "$WORK/plug/plugins/cache/claude-fleet/fleet/deadbeef/commands"
: > "$WORK/copy/commands/fleet-claim.md"
: > "$WORK/plug/plugins/cache/claude-fleet/fleet/deadbeef/commands/fleet-claim.md"

got="$(CLAUDE_COMMANDS_DIR="$WORK/copy/commands" CLAUDE_CONFIG_DIR="$WORK/none" fleet_cmd fleet-claim)"
[ "$got" = "/fleet-claim" ] || fail "a copy install must seed the bare command, got: $got"
got="$(CLAUDE_COMMANDS_DIR="$WORK/none" CLAUDE_CONFIG_DIR="$WORK/plug" fleet_cmd fleet-claim)"
[ "$got" = "/fleet:fleet-claim" ] || fail "a plugin-only install must seed the namespaced command, got: $got"
got="$(CLAUDE_COMMANDS_DIR="$WORK/copy/commands" CLAUDE_CONFIG_DIR="$WORK/plug" fleet_cmd fleet-claim)"
[ "$got" = "/fleet-claim" ] || fail "with BOTH installed the bare form must win (it still resolves), got: $got"
got="$(CLAUDE_COMMANDS_DIR="$WORK/none" CLAUDE_CONFIG_DIR="$WORK/none" fleet_cmd fleet-claim)"
[ "$got" = "/fleet-claim" ] || fail "with neither installed the bare form is the unchanged default, got: $got"
got="$(FLEET_CMD_PREFIX=fleet CLAUDE_COMMANDS_DIR="$WORK/copy/commands" fleet_cmd fleet-handoff pickup /tmp/h.md)"
[ "$got" = "/fleet:fleet-handoff pickup /tmp/h.md" ] || fail "FLEET_CMD_PREFIX must override and keep args, got: $got"
got="$(FLEET_CMD_PREFIX='' CLAUDE_CONFIG_DIR="$WORK/plug" CLAUDE_COMMANDS_DIR="$WORK/none" fleet_cmd fleet-claim)"
[ "$got" = "/fleet-claim" ] || fail "an EMPTY FLEET_CMD_PREFIX must force the bare form, got: $got"
ok "fleet_cmd seeds the form that resolves on each install shape, with an operator override"

# --- 8. the seed site actually uses it ----------------------------------------
grep -q 'fleet_cmd fleet-claim' "$BIN/dash-issue-session.sh" \
  || fail "bin/dash-issue-session.sh no longer seeds through fleet_cmd — a plugin-only install would seed a literal that never expands"
ok "the spawn seed goes through fleet_cmd, not a hardcoded slash command"

printf '\nfleet-plugin-selftest: %d checks passed\n' "$pass"
