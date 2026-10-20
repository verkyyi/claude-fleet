#!/bin/bash
# fleet-codex-plugins-selftest.sh — a Codex session reads the same plugins through
# Codex's OWN plugin manager (issue #3123; T589, EPIC T580 C3). bin/fleet-codex-plugins.py
# follows what the Claude side has installed (a fake `claude plugin list --json`) into
# a sandbox CODEX_HOME with a fake `codex plugin` (it keeps config.toml and the plugin
# cache the way the real one does — bin/fleet-native-plugin-cli-selftest.py
# --retire-bridge is the same road against the real binary, in native-managed-hooks.yml):
#
#   A  nothing installed ⇒ sync writes nothing, asks neither claude nor codex
#   B  the old bridge's products (a fleet-plugin-* link into Claude's cache, a marked
#      adapter, the config.toml marker block) are retired and fleet-epic is installed
#      natively (marketplace add + plugin add); a personal fleet-plugin-* entry and
#      the login's own config lines stay byte for byte; --dry-run writes nothing; a
#      second sync calls no `codex plugin add`
#   C  a version bump ⇒ plugin add again; a marketplace from another source ⇒
#      remove + add
#   D  Claude disables / uninstalls ⇒ codex plugin remove; another marketplace's
#      plugin is never touched
#   E  mention / command name the native copy; doctor says installed / behind and
#      what Codex cannot carry; no Codex home ⇒ exit 3
#   F  codex.plugins in agent-overrides.json ⇒ nothing; no codex binary ⇒ the home
#      is only retired
#   G  wiring: fleet-codex.sh no longer syncs or passes --plugin-dir; install-apply
#      and the doctor run it; dirs / --print-dirs (compat-1v) print nothing
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$(cd "$BIN/.." && pwd)"
CP="$BIN/fleet-codex-plugins.py"
st_sandbox "${TMPDIR:-/tmp}/fleet-codex-plugins-selftest.XXXXXX"
WORK="$(cd "$WORK" && pwd)"                         # one spelling (a TMPDIR ending in / doubles it)
CHECKS=0
fail() { printf 'selftest FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
has() { case "$2" in *"$1"*) st_count ;; *) fail "$3" "$2" ;; esac; }
hasnt() { case "$2" in *"$1"*) fail "$3" "$2" ;; *) st_count ;; esac; }

export FLEET_CONF_DIR="$WORK/conf" CLAUDE_CONFIG_DIR="$WORK/claude"
mkdir -p "$FLEET_CONF_DIR" "$CLAUDE_CONFIG_DIR/plugins"
HOME_C="$WORK/codex"; mkdir -p "$HOME_C/skills/own-skill"
printf -- '---\nname: own-skill\ndescription: mine\n---\n' > "$HOME_C/skills/own-skill/SKILL.md"
cat > "$HOME_C/config.toml" <<'T'
# my codex config
model = "gpt-5"

[mcp_servers.context7]
command = "npx"

[plugins."other@elsewhere"]
enabled = true
T
cp "$HOME_C/config.toml" "$WORK/orig.toml"

# a marketplace of our own shape (the real one's plugins, versions we control)
MK="$WORK/market"
mkdir -p "$MK/.claude-plugin"
cp -RL "$ROOT/plugins" "$MK/plugins"            # -L: the shadow root links it; never edit the real one
python3 - "$ROOT/.claude-plugin/marketplace.json" "$MK/.claude-plugin/marketplace.json" <<'P'
import json, sys
m = json.load(open(sys.argv[1])); json.dump(m, open(sys.argv[2], "w"))
P
VER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MK/plugins/fleet-epic/.claude-plugin/plugin.json")
# Claude Code's installed copy (its cache shape) and the old bridge's link into it
CACHE="$CLAUDE_CONFIG_DIR/plugins/cache/claude-fleet"
mkdir -p "$CACHE/fleet-epic/$VER" && cp -R "$MK/plugins/fleet-epic/." "$CACHE/fleet-epic/$VER/"

LIST="$WORK/list.json"
cat > "$WORK/claude-fake" <<SH
#!/bin/sh
[ "\$1 \$2 \$3" = "plugin list --json" ] && { printf 'list\n' >> "$WORK/claude.calls"; exec cat "$LIST"; }
exit 1
SH
# codex plugin, as the real one keeps it: [marketplaces.<m>] source, [plugins."p@m"],
# plugins/cache/<m>/<p>/<version>/ copied from the marketplace's source
cat > "$WORK/codex-fake" <<'PY'
#!/usr/bin/env python3
import json, os, re, shutil, sys
home = os.environ["CODEX_HOME"]; conf = os.path.join(home, "config.toml")
with open(os.environ["FAKE_CODEX_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
text = open(conf).read() if os.path.exists(conf) else ""
def save(t): open(conf, "w").write(t)
def drop(t, head):
    out, skip = [], False
    for line in t.split("\n"):
        if line.startswith("["):
            skip = line.strip() == head
        if not skip:
            out.append(line)
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out))
a = sys.argv[1:]
if a[:3] == ["plugin", "marketplace", "add"]:
    src = a[3]; mk = json.load(open(os.path.join(src, ".claude-plugin/marketplace.json")))["name"]
    m = re.search(r'\[marketplaces\.%s\]\nsource_type = "local"\nsource = "(.*)"' % mk, text)
    if m and m.group(1) != src:
        print("Error: marketplace '%s' is already added from a different source" % mk, file=sys.stderr); sys.exit(1)
    if not m:
        save(text.rstrip("\n") + '\n\n[marketplaces.%s]\nsource_type = "local"\nsource = "%s"\n' % (mk, src))
elif a[:3] == ["plugin", "marketplace", "remove"]:
    save(drop(text, "[marketplaces.%s]" % a[3]))
elif a[:2] == ["plugin", "add"]:
    p, mk = a[2].split("@")
    src = re.search(r'\[marketplaces\.%s\]\nsource_type = "local"\nsource = "(.*)"' % mk, text).group(1)
    pd = os.path.join(src, "plugins", p)
    v = json.load(open(os.path.join(pd, ".claude-plugin/plugin.json")))["version"]
    cd = os.path.join(home, "plugins", "cache", mk, p)
    shutil.rmtree(cd, ignore_errors=True); shutil.copytree(pd, os.path.join(cd, v))
    if '[plugins."%s"]' % a[2] not in text:
        save(text.rstrip("\n") + '\n\n[plugins."%s"]\nenabled = true\n' % a[2])
elif a[:2] == ["plugin", "remove"]:
    p, mk = a[2].split("@")
    shutil.rmtree(os.path.join(home, "plugins", "cache", mk, p), ignore_errors=True)
    save(drop(text, '[plugins."%s"]' % a[2]))
else:
    sys.exit(2)
PY
chmod +x "$WORK/claude-fake" "$WORK/codex-fake"
export FAKE_CODEX_LOG="$WORK/codex.calls"
: > "$FAKE_CODEX_LOG"
mark_installed() { printf '{"version":2,"plugins":{"fleet-epic@claude-fleet":[]}}\n' > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"; }
row() { # name enabled
  printf '{"id":"%s@claude-fleet","version":"%s","enabled":%s,"installPath":"%s/%s/%s"}' "$1" "$VER" "$2" "$CACHE" "$1" "$VER"
}
cx() { python3 "$CP" "$@" --root "$MK" --claude "$WORK/claude-fake" --codex "$WORK/codex-fake" --cache '' \
         --override "$WORK/no-override.json" --codex-home "$HOME_C"; }
q() { python3 "$CP" "$@" --root "$MK" --codex-home "$HOME_C"; }
echo '[]' > "$WORK/no-override.json"

# ---- A: nothing installed -------------------------------------------------------
echo '[]' > "$LIST"
out=$(cx sync); rc=$?
[ "$rc" = 0 ] || fail "A sync rc $rc" "$out"; st_count
has 'unchanged' "$out" "A sync should change nothing"
cmp -s "$HOME_C/config.toml" "$WORK/orig.toml" || fail "A config.toml changed"; st_count
[ ! -s "$FAKE_CODEX_LOG" ] && [ ! -f "$WORK/claude.calls" ] || fail "A asked claude or codex"; st_count

# ---- B: the old bridge retired, fleet-epic native --------------------------------
ln -s "$CACHE/fleet-epic/$VER/skills/epic-page" "$HOME_C/skills/fleet-plugin-epic-page"
mkdir -p "$HOME_C/skills/fleet-plugin-fleet-epic-run" "$HOME_C/skills/fleet-plugin-mine"
printf -- '---\nname: fleet-epic-run\n---\n\n<!-- fleet codex plugin skill -->\nbody\n' > "$HOME_C/skills/fleet-plugin-fleet-epic-run/SKILL.md"
printf -- '---\nname: mine\ndescription: personal\n---\n' > "$HOME_C/skills/fleet-plugin-mine/SKILL.md"
ln -s "$HOME_C/skills/own-skill" "$HOME_C/skills/fleet-plugin-mylink"
cat >> "$HOME_C/config.toml" <<'T'

# >>> fleet plugins — bin/fleet-codex-plugins.py sync writes this block; edit outside it >>>
[mcp_servers.fleet-orch]
command = "x"
# <<< fleet plugins <<<
T
cp "$HOME_C/config.toml" "$WORK/bridged.toml"
printf '[%s]\n' "$(row fleet-epic true)" > "$LIST"; mark_installed
dry=$(cx sync --dry-run)
has 'retire  link' "$dry" "B dry run should plan the link's retirement"
has "add     $HOME_C fleet-epic@claude-fleet $VER" "$dry" "B dry run should plan the native add"
cmp -s "$HOME_C/config.toml" "$WORK/bridged.toml" && [ -L "$HOME_C/skills/fleet-plugin-epic-page" ] \
  && [ ! -s "$FAKE_CODEX_LOG" ] || fail "B --dry-run changed something"; st_count
out=$(cx sync); rc=$?
[ "$rc" = 0 ] || fail "B sync rc $rc" "$out"; st_count
for w in 'retire  link' 'retire  skill' 'retire  config' "market  $HOME_C claude-fleet → $MK" 'add     '; do
  has "$w" "$out" "B sync should say: $w"
done
[ ! -e "$HOME_C/skills/fleet-plugin-epic-page" ] && [ ! -L "$HOME_C/skills/fleet-plugin-epic-page" ] \
  && [ ! -e "$HOME_C/skills/fleet-plugin-fleet-epic-run" ] || fail "B bridge skills survived" "$(ls -la "$HOME_C/skills")"; st_count
grep -q 'name: mine' "$HOME_C/skills/fleet-plugin-mine/SKILL.md" && [ -L "$HOME_C/skills/fleet-plugin-mylink" ] \
  || fail "B a personal fleet-plugin-* entry was touched"; st_count
has 'own     ' "$out" "B the personal entries should be said"
hasnt '# >>> fleet plugins' "$(cat "$HOME_C/config.toml")" "B the marker block survived"
head -c "$(wc -c < "$WORK/orig.toml")" "$HOME_C/config.toml" | cmp -s - "$WORK/orig.toml" \
  || fail "B the login's lines are not byte for byte" "$(cat "$HOME_C/config.toml")"; st_count
has '[plugins."fleet-epic@claude-fleet"]' "$(cat "$HOME_C/config.toml")" "B not installed natively"
[ -f "$HOME_C/plugins/cache/claude-fleet/fleet-epic/$VER/skills/epic-page/SKILL.md" ] || fail "B no native cache copy"; st_count
: > "$FAKE_CODEX_LOG"
out=$(cx sync)
has 'unchanged' "$out" "B a second sync should change nothing"
[ ! -s "$FAKE_CODEX_LOG" ] || fail "B a second sync ran codex" "$(cat "$FAKE_CODEX_LOG")"; st_count

# ---- C: version bump; marketplace moved ------------------------------------------
sed -i.bak "s/\"version\": \"$VER\"/\"version\": \"9.9.9\"/" "$MK/plugins/fleet-epic/.claude-plugin/plugin.json"
out=$(cx sync)
has "add     $HOME_C fleet-epic@claude-fleet 9.9.9" "$out" "C a bump should re-add"
[ -d "$HOME_C/plugins/cache/claude-fleet/fleet-epic/9.9.9" ] || fail "C the new version is not in the cache"; st_count
cp -R "$MK" "$WORK/market2"
: > "$FAKE_CODEX_LOG"
out=$(python3 "$CP" sync --root "$WORK/market2" --claude "$WORK/claude-fake" --codex "$WORK/codex-fake" --cache '' \
        --override "$WORK/no-override.json" --codex-home "$HOME_C")
has "market  $HOME_C claude-fleet → $WORK/market2" "$out" "C a moved marketplace should be re-added"
grep -q '^plugin marketplace remove claude-fleet$' "$FAKE_CODEX_LOG" && grep -q "^plugin marketplace add $WORK/market2\$" "$FAKE_CODEX_LOG" \
  || fail "C not remove + add" "$(cat "$FAKE_CODEX_LOG")"; st_count
cx sync >/dev/null                                   # back onto $MK

# ---- E: mention / command / doctor -------------------------------------------------
[ "$(q mention epic-page)" = fleet-epic:epic-page ] || fail "E mention epic-page" "$(q mention epic-page)"; st_count
[ "$(q command fleet-epic-run)" = "$HOME_C/plugins/cache/claude-fleet/fleet-epic/9.9.9/commands/fleet-epic-run.md" ] \
  || fail "E command fleet-epic-run" "$(q command fleet-epic-run)"; st_count
q mention mine >/dev/null && fail "E a personal entry has no mention"; st_count
q command nope >/dev/null && fail "E no such command"; st_count
doc=$(cx doctor); rc=$?
[ "$rc" = 0 ] || fail "E doctor rc $rc" "$doc"; st_count
has 'Codex 原生装着 fleet-epic' "$doc" "E doctor should say installed"
for w in 'mod 界面模块' 'PreCompact' 'tools 限制'; do has "$w" "$doc" "E doctor should name $w"; done
mv "$MK/plugins/fleet-epic/.claude-plugin/plugin.json.bak" "$MK/plugins/fleet-epic/.claude-plugin/plugin.json"
has '原生缺 / 落后 fleet-epic' "$(cx doctor)" "E doctor should say behind"
cx sync >/dev/null
python3 "$CP" doctor --root "$MK" --claude "$WORK/claude-fake" --cache '' --codex-home "$WORK/none" >/dev/null; rc=$?
[ "$rc" = 3 ] || fail "E doctor with no Codex home should exit 3 (got $rc)"; st_count

# ---- D: disabled, then uninstalled ⇒ removed; other marketplaces untouched -------------
printf '[%s]\n' "$(row fleet-epic false)" > "$LIST"
out=$(cx sync)
has "remove  $HOME_C fleet-epic@claude-fleet" "$out" "D a disabled plugin should be removed"
hasnt 'fleet-epic@claude-fleet' "$(cat "$HOME_C/config.toml")" "D the plugin's table stayed"
has '[plugins."other@elsewhere"]' "$(cat "$HOME_C/config.toml")" "D another marketplace's plugin was touched"
printf '[%s]\n' "$(row fleet-epic true)" > "$LIST"; cx sync >/dev/null
echo '[]' > "$LIST"
has 'remove  ' "$(cx sync)" "D an uninstalled plugin should be removed"
[ ! -d "$HOME_C/plugins/cache/claude-fleet/fleet-epic" ] || fail "D the cache copy stayed"; st_count

# ---- F: override; no codex binary --------------------------------------------------------
printf '[%s]\n' "$(row fleet-epic true)" > "$LIST"
echo '["codex.plugins"]' > "$WORK/override.json"
: > "$FAKE_CODEX_LOG"
out=$(python3 "$CP" sync --root "$MK" --claude "$WORK/claude-fake" --codex "$WORK/codex-fake" --cache '' \
        --override "$WORK/override.json" --codex-home "$HOME_C")
has "codex.plugins is this login's own" "$out" "F override should do nothing"
[ ! -s "$FAKE_CODEX_LOG" ] || fail "F override still ran codex"; st_count
H2="$WORK/codex-nobin"; mkdir -p "$H2/skills"
ln -s "$CACHE/fleet-epic/$VER/skills/epic-page" "$H2/skills/fleet-plugin-epic-page"
out=$(PATH=/usr/bin:/bin HOME="$WORK/nohome" python3 "$CP" sync --root "$MK" --claude "$WORK/claude-fake" --codex "$WORK/no-such-codex" \
        --cache '' --override "$WORK/no-override.json" --codex-home "$H2")
has 'no codex binary here' "$out" "F no codex should be said"
[ ! -L "$H2/skills/fleet-plugin-epic-page" ] || fail "F the home was not retired"; st_count

# ---- G: wiring ------------------------------------------------------------------------------
hasnt 'fleet-codex-plugins.py" sync' "$(cat "$BIN/fleet-codex.sh")" "G the launcher still syncs plugins"
hasnt '--plugin-dir' "$(grep -v '^#' "$BIN/fleet-codex.sh")" "G the launcher still merges plugin hooks"
grep -q 'fleet-codex-plugins.py" mention' "$BIN/fleet-codex.sh" && grep -q 'fleet-codex-plugins.py" command' "$BIN/fleet-codex.sh" \
  || fail "G the launcher does not ask mention / command"; st_count
grep -q 'fleet-codex-plugins.py" sync' "$BIN/fleet-install-apply.sh" || fail "G install-apply does not sync"; st_count
grep -q 'fleet-codex-plugins.py' "$BIN/fleet-doctor.sh" || fail "G the doctor's plugins row does not ask"; st_count
[ -z "$(cx dirs)" ] || fail "G dirs printed something"; st_count
out=$(cx sync --print-dirs 2>/dev/null); [ -z "$out" ] || fail "G --print-dirs printed on stdout" "$out"; st_count

echo "fleet-codex-plugins-selftest: PASS ($CHECKS checks)"
