#!/bin/bash
# fleet-plugins-selftest.sh — this repo is a plugin marketplace of optional
# plugins (issue #3112, EPIC #3111 C1): fleet-orchestrate · fleet-steward · fleet-epic,
# fleet-browser (issue #3236), fleet-feedback (#3360) and fleet-infra (#3586) under plugins/, beside the core `fleet` plugin (the repo root).
#
#   A  manifests: the marketplace lists exactly the plugins/ dirs, each entry's
#      source is its dir and its name the dir's plugin.json name; steward and
#      epic depend on fleet-orchestrate; every plugin pins a version;
#      `claude plugin validate` passes (when claude is on PATH)
#   B  paths: every skill has name + description frontmatter, every command /
#      agent / hooks.json / .mcp.json the plugin carries exists and parses, and
#      every command they run is ~/.claude/fleet/bin/… — no script is copied
#      into a plugin
#   C  the default package has none of it: skills/ and commands/ hold no part of
#      a plugin, the core plugin.json names none, the agent bundle lists no
#      plugins/ path, fleet-agent-defaults.py counts none of their skills
#   D  fleet-plugins.py ensure (a fake claude): a fresh login gets the
#      marketplace added and NOTHING installed; a second run adds nothing; a
#      login that still has a moved part installed gets that plugin (carry-over);
#      a plugin behind the runtime is updated; --dry-run runs nothing; a
#      marketplace added from elsewhere is re-pointed; a link-tree install
#      adds it from the runtime's real tree (<runtime>/current)
#   E  fleet-plugins.py doctor: marketplace missing → WARN; installed + behind →
#      WARN 落后; else PASS naming each plugin's state
#   F  install-apply runs the pass before the commands / skills passes remove the
#      moved copies, and the doctor has the row
#   G  a changed plugin bumps its version (against the merge-base with master,
#      when git can tell)
#   H  the real thing (claude on PATH): a sandbox HOME adds the marketplace and
#      lists none of the three; install fleet-orchestrate lists it; uninstall
#      lists none again; install fleet-epic carries its three commands, epic-page
#      and agents/epic-driver.md (and pulls fleet-orchestrate in)
#   I  the epic plugin (issue #3116, EPIC #3111 C5): fleet-epic carries
#      /fleet-epic-plan · run · report, epic-page and the epic-driver agent file
#      (`fleet: reap: loop-end`, every tool — spawn among them); the core ships
#      no epic-driver; installed, `--as epic-driver` (the orchestrator's driver
#      line) resolves to the plugin's file and the launch says `--agent
#      epic-driver`; not installed, there is no such agent; a login an older
#      release shipped epic-driver into gets fleet-epic (carry-over, D)
#   J  the managed default (issue #3360, EPIC #3354 C6): ensure --default
#      fleet-feedback installs + enables it ONCE and records it in
#      plugins-defaulted.json; the person disables / uninstalls it => the next
#      apply leaves it so; installed already => recorded, its switch untouched;
#      no --default (anyone's own computer) => no install, no record, the output
#      as before; after `account release` (no --default) nothing is disabled or
#      uninstalled; --dry-run runs nothing; install-apply passes --default only
#      under fleet_node_manages; `fleet feedback on|off|status` is the switch
#      (fleet-feedback-switch.sh) and the doctor has a never-WARN `feedback` row
#   K  fleet-infra (issue #3586, EPIC #3569 C16): its six runbooks each carry
#      什么时候用 · 先查什么 · 步骤 · 怎么验收 · 怎么回滚; no hooks, no MCP;
#      oss-scan over it = 0; --default fleet-infra is refused, install-apply
#      never defaults it, the team bundle refuses to hand it out
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
PL="$BIN/fleet-plugins.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-plugins-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"   # realpath: market_source compares resolved paths (/var → /private/var)
CHECKS=0
fail() { printf 'selftest FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }
has() { case "$2" in *"$1"*) ok ;; *) fail "$3" "$2" ;; esac; }
hasnt() { case "$2" in *"$1"*) fail "$3" "$2" ;; *) ok ;; esac; }

# ---- A + B + C: the files themselves (python: structural, no CLI needed) -----
out=$(python3 - "$ROOT" <<'PY' 2>&1
import json, os, re, sys
root = sys.argv[1]
bad = []
m = json.load(open(os.path.join(root, ".claude-plugin", "marketplace.json")))
entries = {p["name"]: p for p in m["plugins"]}
dirs = sorted(d for d in os.listdir(os.path.join(root, "plugins"))
              if os.path.isdir(os.path.join(root, "plugins", d)))
want = ["fleet-browser", "fleet-epic", "fleet-feedback", "fleet-infra", "fleet-orchestrate", "fleet-steward"]
if dirs != want:
    bad.append("A plugins/ holds %s, expected %s" % (dirs, want))
ours = sorted(n for n, p in entries.items() if str(p.get("source", "")).startswith("./plugins/"))
if ours != dirs:
    bad.append("A marketplace lists %s under ./plugins/, plugins/ holds %s" % (ours, dirs))
if entries.get("fleet", {}).get("source") != "./":
    bad.append("A the core plugin `fleet` must stay source ./")
skills_of = {}
cmds_of = {}
for d in dirs:
    base = os.path.join(root, "plugins", d)
    e = entries.get(d, {})
    if e.get("source") != "./plugins/" + d:
        bad.append("A %s: marketplace source %r != ./plugins/%s" % (d, e.get("source"), d))
    try:
        pj = json.load(open(os.path.join(base, ".claude-plugin", "plugin.json")))
    except Exception as x:
        bad.append("A %s: plugin.json unreadable: %s" % (d, x)); continue
    if pj.get("name") != d:
        bad.append("A %s: plugin.json name %r" % (d, pj.get("name")))
    if not re.match(r"^\d+\.\d+\.\d+$", str(pj.get("version", ""))):
        bad.append("A %s: no semver version — the doctor's 落后 reads version vs folderVersion" % d)
    deps = pj.get("dependencies") or []
    if d in ("fleet-steward", "fleet-epic") and "fleet-orchestrate" not in deps:
        bad.append("A %s must depend on fleet-orchestrate (its dispatch tools)" % d)
    if d == "fleet-orchestrate" and deps:
        bad.append("A fleet-orchestrate depends on nothing, has %s" % deps)
    # B: parts
    sk = os.path.join(base, "skills")
    skills_of[d] = sorted(os.listdir(sk)) if os.path.isdir(sk) else []
    for s in skills_of[d]:
        f = os.path.join(sk, s, "SKILL.md")
        txt = open(f).read() if os.path.isfile(f) else ""
        fm = re.match(r"^---\n(.*?)\n---\n", txt, re.S)
        if not fm or not re.search(r"^name:\s*%s\s*$" % re.escape(s), fm.group(1), re.M) \
                or not re.search(r"^description:", fm.group(1), re.M):
            bad.append("B %s: skills/%s/SKILL.md lacks name: %s + description frontmatter" % (d, s, s))
    cd = os.path.join(base, "commands")
    cmds_of[d] = sorted(os.listdir(cd)) if os.path.isdir(cd) else []
    for c in cmds_of[d]:
        txt = open(os.path.join(cd, c)).read()
        if not re.match(r"^---\n(.*?\n)?description:", txt, re.S):
            bad.append("B %s: commands/%s has no description frontmatter" % (d, c))
    ad = os.path.join(base, "agents")
    for a in (sorted(os.listdir(ad)) if os.path.isdir(ad) else []):
        if not open(os.path.join(ad, a)).read().startswith("---\n"):
            bad.append("B %s: agents/%s has no frontmatter" % (d, a))
    runs = []
    hj = os.path.join(base, "hooks", "hooks.json")
    if os.path.exists(hj):
        h = json.load(open(hj))
        for ev in (h.get("hooks") or {}).values():
            for grp in ev:
                for hk in grp.get("hooks", []):
                    runs.append(("hooks.json", hk.get("command", "")))
    mj = os.path.join(base, ".mcp.json")
    if os.path.exists(mj):
        mc = json.load(open(mj))
        for name, srv in (mc.get("mcpServers") or mc).items():
            runs.append((".mcp.json " + name, " ".join([srv.get("command", "")] + list(srv.get("args", [])))))
    for where, cmd in runs:
        # ~/.claude/fleet/bin/…, $HOME/…, ${HOME}/…, or ${SEAM:-$HOME/.claude/fleet/bin}/…
        if not re.search(r"(~|\$HOME|\$\{HOME\})/\.claude/fleet/bin(/|\}/)", cmd):
            bad.append("B %s: %s runs %r — a plugin's commands call ~/.claude/fleet/bin, one implementation" % (d, where, cmd))
    for dp, _, fs in os.walk(base):
        for f in fs:
            if f.endswith((".sh", ".py")):
                bad.append("B %s: %s — scripts stay in bin/, never copied into a plugin"
                           % (d, os.path.relpath(os.path.join(dp, f), root)))
# C: the default package
for d in dirs:
    for s in skills_of[d]:
        if os.path.exists(os.path.join(root, "skills", s)):
            bad.append("C skills/%s is in the default package — it is %s's" % (s, d))
    for c in cmds_of[d]:
        if os.path.exists(os.path.join(root, "commands", c)):
            bad.append("C commands/%s is in the default package — it is %s's" % (c, d))
core = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json")))
for c in core.get("commands", []):
    if not os.path.exists(os.path.join(root, c)):
        bad.append("C core plugin.json names %s, which is not on disk" % c)
    if any(os.path.basename(c) in v for v in cmds_of.values()):
        bad.append("C core plugin.json still names %s" % c)
for line in open(os.path.join(root, "conf", "agent-bundle.manifest")):
    if line.split("#")[0].strip().startswith("plugins/"):
        bad.append("C conf/agent-bundle.manifest lists %s" % line.strip())
print("\n".join(bad) if bad else "ok %d plugins" % len(dirs))
sys.exit(1 if bad else 0)
PY
) || fail "A/B/C manifests, parts, default package" "$out"
ok

# C (cont.): the agents pass's skills count is the repo's skills/ — none of theirs
missing=$(python3 "$BIN/fleet-agent-defaults.py" check --root "$ROOT" --claude-config "$WORK/none.json" \
  --claude-md "$WORK/none.md" --claude-skills "$WORK/skills-empty" --override "$WORK/none-ovr.json" 2>&1)
for s in fleet-orchestrate fleet-steward epic-page; do
  hasnt "skill $s" "$missing" "C fleet-agent-defaults.py still counts $s as a default skill"
done
[ "$(python3 "$PL" names --root "$ROOT" | paste -sd, -)" = "fleet-browser,fleet-epic,fleet-feedback,fleet-infra,fleet-orchestrate,fleet-steward" ] && ok \
  || fail "C names" "$(python3 "$PL" names --root "$ROOT")"

# ---- D: ensure, against a fake claude ----------------------------------------
FK="$WORK/fakeclaude"; ST="$WORK/state"; mkdir -p "$ST"
cat > "$FK" <<'SH'
#!/bin/bash
# a fake `claude plugin …`: state in $FAKE_ST (market = added?, installed.json)
echo "$*" >> "$FAKE_ST/calls"
[ "$1" = plugin ] || exit 2; shift
case "$1 ${2:-}" in
  "marketplace list") if [ -f "$FAKE_ST/market" ]; then printf '[{"name":"claude-fleet","source":"directory","path":"%s"}]\n' "$(cat "$FAKE_ST/market")"; else echo '[]'; fi ;;
  "marketplace add") echo "$3" > "$FAKE_ST/market" ;;
  "list --json") cat "$FAKE_ST/installed.json" 2>/dev/null || echo '[]' ;;
  "install "*) python3 - "$FAKE_ST/installed.json" "$2" <<'PY'
import json, sys, os
p, pid = sys.argv[1], sys.argv[2]
l = json.load(open(p)) if os.path.exists(p) else []
l.append({"id": pid, "version": "0.1.0", "folderVersion": "0.1.0", "enabled": True})
json.dump(l, open(p, "w"))
PY
    ;;
  "update "*) python3 - "$FAKE_ST/installed.json" "$2" <<'PY'
import json, sys
p, pid = sys.argv[1], sys.argv[2]
l = json.load(open(p))
for e in l:
    if e["id"] == pid: e["version"] = e["folderVersion"]
json.dump(l, open(p, "w"))
PY
    ;;
  "enable "*|"disable "*) python3 - "$FAKE_ST/installed.json" "$2" "$1" <<'PY'
import json, sys
p, pid, verb = sys.argv[1:4]
l = json.load(open(p))
hit = [e for e in l if e["id"] == pid]
for e in hit: e["enabled"] = (verb == "enable")
json.dump(l, open(p, "w")); sys.exit(0 if hit else 1)
PY
    ;;
  "uninstall "*) python3 - "$FAKE_ST/installed.json" "$2" <<'PY'
import json, sys
p, pid = sys.argv[1:3]
json.dump([e for e in json.load(open(p)) if e["id"] != pid], open(p, "w"))
PY
    ;;
  *) exit 3 ;;
esac
SH
chmod +x "$FK"
export FAKE_ST="$ST"
CD="$WORK/claude"; mkdir -p "$CD"
ens() { python3 "$PL" ensure --root "$ROOT" --source /home/x/.claude/fleet --claude "$FK" --claude-dir "$CD" "$@" 2>&1; }

: > "$WORK/gone"
out=$(ens --gone "$WORK/gone"); rc=$?
[ "$rc" = 0 ] && ok || fail "D fresh ensure rc=$rc" "$out"
has "added the claude-fleet marketplace from /home/x/.claude/fleet" "$out" "D fresh login: marketplace added from the literal source"
has "installed: none" "$out" "D fresh login: nothing installed"
grep -q '^plugin install' "$ST/calls" && fail "D a fresh login ran an install" "$(cat "$ST/calls")"; ok
: > "$ST/calls"
out=$(ens --gone "$WORK/gone")
grep -q 'marketplace add' "$ST/calls" && fail "D second run re-added the marketplace" "$(cat "$ST/calls")"; ok

# added from elsewhere (an older source) → re-pointed, nothing else re-run
echo /old/place > "$ST/market"; : > "$ST/calls"
out=$(ens --gone "$WORK/gone")
has "added the claude-fleet marketplace from /home/x/.claude/fleet (was /old/place)" "$out" "D a marketplace added from elsewhere is re-pointed"

# the source: a plain install as spelled; a managed LINK TREE (#2774) → the
# runtime's real tree, its `current` when that is the version (install copies no
# symlink leaving the marketplace — measured: an empty cache, version unknown)
src() { python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("p",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.market_source(sys.argv[2]))' "$PL" "$1"; }
RT="$WORK/runtime"; mkdir -p "$RT/abc/.claude-plugin" "$WORK/lt/.claude-plugin" "$WORK/plain/.claude-plugin"
echo '{}' > "$RT/abc/.claude-plugin/marketplace.json"; echo '{}' > "$WORK/plain/.claude-plugin/marketplace.json"
ln -s "$RT/abc/.claude-plugin/marketplace.json" "$WORK/lt/.claude-plugin/marketplace.json"
[ "$(src "$WORK/plain")" = "$WORK/plain" ] && ok || fail "D source: a plain install is used as spelled" "$(src "$WORK/plain")"
[ "$(src "$WORK/lt")" = "$RT/abc" ] && ok || fail "D source: a link tree with no current → the version dir" "$(src "$WORK/lt")"
ln -s "$RT/abc" "$RT/current"
[ "$(src "$WORK/lt")" = "$RT/current" ] && ok || fail "D source: a link tree → <runtime>/current" "$(src "$WORK/lt")"

# carry-over: the moved parts left the install this apply, and this login has them
printf 'skills/fleet-orchestrate/SKILL.md\nskills/fleet-orchestrate/role.md\ncommands/fleet-epic-run.md\nskills/doc-preview/old.md\n' > "$WORK/gone"
mkdir -p "$CD/skills/fleet-orchestrate" "$CD/commands"; echo x > "$CD/skills/fleet-orchestrate/SKILL.md"
out=$(ens --gone "$WORK/gone" --dry-run)
has "would install fleet-orchestrate@claude-fleet" "$out" "D dry-run names the carry-over"
grep -q '^plugin install' "$ST/calls" && fail "D --dry-run installed" "$(cat "$ST/calls")"; ok
out=$(ens --gone "$WORK/gone")
has "installed fleet-orchestrate@claude-fleet" "$out" "D carry-over: a login with the skill installed gets the plugin"
hasnt "fleet-epic@" "$out" "D carry-over: fleet-epic's command was not installed here — no fleet-epic"
hasnt "fleet-steward" "$out" "D carry-over: no steward part here — no fleet-steward"
echo x > "$CD/commands/fleet-epic-run.md"
out=$(ens --gone "$WORK/gone")
has "installed fleet-epic@claude-fleet" "$out" "D carry-over: the epic command installed → fleet-epic"
hasnt "installed fleet-orchestrate" "$out" "D carry-over: an installed plugin is not re-installed"

# carry-over of an agent file the core shipped (issue #3116): epic-driver left
# conf/agent-defaults/ for plugins/fleet-epic/agents/; a login holding the shipped
# copy in ~/.claude/agents gets fleet-epic before the agentfiles pass retires it
echo '[{"id":"fleet-orchestrate@claude-fleet","version":"0.1.0","folderVersion":"0.1.0","enabled":true}]' > "$ST/installed.json"
rm -f "$CD/commands/fleet-epic-run.md"
printf 'conf/agent-defaults/claude/agents/epic-driver.md\n' > "$WORK/gone"
out=$(ens --gone "$WORK/gone")
hasnt "fleet-epic@" "$out" "D carry-over: no shipped epic-driver here — no fleet-epic"
mkdir -p "$CD/agents"; echo x > "$CD/agents/epic-driver.md"
out=$(ens --gone "$WORK/gone")
has "installed fleet-epic@claude-fleet" "$out" "D carry-over: the shipped epic-driver here → fleet-epic"

# behind → update
python3 - "$ST/installed.json" <<'PY'
import json, sys
l = json.load(open(sys.argv[1])); l[0]["folderVersion"] = "0.2.0"; json.dump(l, open(sys.argv[1], "w"))
PY
: > "$WORK/gone"
out=$(ens --gone "$WORK/gone")
has "updated fleet-orchestrate@claude-fleet 0.1.0 → 0.2.0" "$out" "D a plugin behind the runtime is updated"

# ---- E: doctor ------------------------------------------------------------------
rm -f "$ST/market" "$ST/installed.json"
out=$(python3 "$PL" doctor --root "$ROOT" --claude "$FK"); rc=$?
[ "$rc" = 1 ] && ok || fail "E no marketplace rc=$rc" "$out"
has "marketplace is not added" "$out" "E no marketplace → WARN"
echo x > "$ST/market"
out=$(python3 "$PL" doctor --root "$ROOT" --claude "$FK"); rc=$?
[ "$rc" = 0 ] && ok || fail "E none installed rc=$rc" "$out"
has "fleet-orchestrate 未装" "$out" "E none installed → each 未装"
echo '[{"id":"fleet-orchestrate@claude-fleet","version":"0.1.0","folderVersion":"0.2.0","enabled":true},{"id":"fleet-epic@claude-fleet","version":"0.1.0","folderVersion":"0.1.0","enabled":true}]' > "$ST/installed.json"
out=$(python3 "$PL" doctor --root "$ROOT" --claude "$FK"); rc=$?
[ "$rc" = 1 ] && ok || fail "E behind rc=$rc" "$out"
has "fleet-orchestrate 0.1.0 落后（运行时 0.2.0）" "$out" "E behind → 落后"
has "fleet-epic 0.1.0" "$out" "E installed → its version"
has "fleet-steward 未装" "$out" "E not installed → 未装"
out=$(python3 "$PL" doctor --root "$ROOT" --claude "$WORK/no-such-claude"); rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && ok || fail "E no claude → no row (rc=$rc)" "$out"

# ---- F: wiring ---------------------------------------------------------------------
AP="$BIN/fleet-install-apply.sh"
lp=$(grep -n 'fleet-plugins.py" ensure' "$AP" | head -1 | cut -d: -f1)
lc=$(grep -n '^# --- commands ---' "$AP" | cut -d: -f1)
ls_=$(grep -n '^# --- skills ---' "$AP" | cut -d: -f1)
[ -n "$lp" ] && [ "$lp" -lt "$lc" ] && [ "$lp" -lt "$ls_" ] && ok \
  || fail "F install-apply must run fleet-plugins.py ensure before the commands/skills passes" "plugins=$lp commands=$lc skills=$ls_"
grep -q '/fleet-plugins.py"' "$BIN/fleet-doctor.sh" && grep -qE '(pass|warn) plugins' "$BIN/fleet-doctor.sh" && ok \
  || fail "F fleet-doctor.sh has no plugins row"

# ---- G: a changed plugin bumps its version ---------------------------------------
# git runs in the REAL tree (issue #3158): under run-selftests.sh $ROOT is the shadow
# root, where plugins/ is one symlink — `git diff <mb> -- plugins/<d>` there sees a
# typechange and calls every plugin changed. `git -C` into plugins/ resolves it
# physically, so --show-toplevel names the real checkout.
if GR=$(git -C "$ROOT/plugins" rev-parse --show-toplevel 2>/dev/null) && [ -n "$GR" ] \
   && mb=$(git -C "$GR" merge-base HEAD origin/master 2>/dev/null) && [ -n "$mb" ]; then
  for d in $(python3 "$PL" names --root "$ROOT"); do
    git -C "$GR" cat-file -e "$mb:plugins/$d/.claude-plugin/plugin.json" 2>/dev/null || continue
    git -C "$GR" diff --quiet "$mb" -- "plugins/$d" && continue
    old=$(git -C "$GR" show "$mb:plugins/$d/.claude-plugin/plugin.json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))')
    new=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$GR/plugins/$d/.claude-plugin/plugin.json")
    [ "$old" != "$new" ] || fail "G plugins/$d changed since $mb but its version is still $new — bump it, or an installed copy never updates (claude plugin update keys on version)"
    ok
  done
fi

# ---- I: the epic plugin (issue #3116) ---------------------------------------------
EP="$ROOT/plugins/fleet-epic"
for f in commands/fleet-epic-plan.md commands/fleet-epic-run.md commands/fleet-epic-report.md \
         skills/epic-page/SKILL.md skills/epic-page/template.html agents/epic-driver.md; do
  [ -f "$EP/$f" ] && ok || fail "I fleet-epic carries no $f"
done
[ ! -e "$ROOT/conf/agent-defaults/claude/agents/epic-driver.md" ] && [ ! -e "$ROOT/agents/epic-driver.md" ] && ok \
  || fail "I the core still ships an epic-driver agent file — it is fleet-epic's"
grep -q -- '--as epic-driver' "$ROOT/plugins/fleet-orchestrate/skills/fleet-orchestrate/SKILL.md" && ok \
  || fail "I the orchestrator's driver line does not start --as epic-driver"
grep -rq -- '--role epic-driver' "$ROOT/plugins" && fail "I a plugin still starts a driver with --role epic-driver" "$(grep -rn -- '--role epic-driver' "$ROOT/plugins")"; ok
AE=$(mktemp -d "$WORK/ae.XXXXXX")
adef() { env HOME="$AE" CLAUDE_CONFIG_DIR="$AE/.claude" FLEET_CONF_DIR="$AE/conf" \
           FLEET_AGENT_PLUGINS_CMD="cat '$AE/plugins.json'" python3 "$BIN/fleet-agent-def.py" "$@" 2>&1; }
printf '[{"id":"fleet-epic@claude-fleet","enabled":true,"installPath":"%s"}]\n' "$EP" > "$AE/plugins.json"
out=$(adef launch epic-driver --dir "$AE")
has "file	$EP/agents/epic-driver.md" "$out" "I installed: epic-driver resolves to fleet-epic's file"
has "reap	loop-end" "$out" "I epic-driver's fleet.reap is loop-end"
has "spawn	1" "$out" "I epic-driver grants spawn (a driver dispatches)"
has "arg	--agent
arg	epic-driver" "$out" "I the launch says --agent epic-driver (the bare name Claude Code finds)"
printf '[]\n' > "$AE/plugins.json"; rm -rf "$AE/conf/agents/plugins.json"
out=$(adef launch epic-driver --dir "$AE"); rc=$?
[ "$rc" = 1 ] && ok || fail "I not installed: there is no epic-driver (rc=$rc)" "$out"

# ---- J: the managed default (issue #3360) ------------------------------------------
REC="$WORK/defaulted.json"; FB=fleet-feedback@claude-fleet
rm -f "$REC" "$ST/installed.json"; echo /home/x/.claude/fleet > "$ST/market"; : > "$WORK/gone"
fbstate() { python3 - "$ST/installed.json" "$FB" <<'PY'
import json, sys, os
l = json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else []
e = [x for x in l if x["id"] == sys.argv[2]]
print("absent" if not e else ("on" if e[0].get("enabled") else "off"))
PY
}
jens() { FLEET_CONF_DIR="$WORK/jconf" ens "$@"; }
# anyone's own computer: no --default ⇒ nothing installed, no record, no word of a default
: > "$ST/calls"; out=$(jens --gone "$WORK/gone")
grep -qE '^plugin (install|enable)' "$ST/calls" && fail "J own computer: an install ran" "$(cat "$ST/calls")"; ok
[ ! -e "$WORK/jconf/plugins-defaulted.json" ] && ok || fail "J own computer: a record was written"
hasnt "default" "$out" "J own computer: the output names no default"
# dry-run: says what it would do, runs and records nothing
: > "$ST/calls"; out=$(jens --gone "$WORK/gone" --default fleet-feedback --dry-run)
has "would install + enable $FB" "$out" "J dry-run names the managed default"
grep -qE '^plugin (install|enable)' "$ST/calls" && fail "J --dry-run installed" "$(cat "$ST/calls")"; ok
[ ! -e "$WORK/jconf/plugins-defaulted.json" ] && ok || fail "J --dry-run wrote the record"
# managed: installed + enabled once, recorded under $FLEET_CONF_DIR
: > "$ST/calls"; out=$(jens --gone "$WORK/gone" --default fleet-feedback); rc=$?
[ "$rc" = 0 ] && ok || fail "J managed ensure rc=$rc" "$out"
has "installed + enabled $FB" "$out" "J managed: fleet-feedback installed + enabled"
grep -q "^plugin install $FB" "$ST/calls" && grep -q "^plugin enable $FB" "$ST/calls" && ok \
  || fail "J managed: install + enable not both run" "$(cat "$ST/calls")"
[ "$(fbstate)" = on ] && ok || fail "J managed: not on after the apply" "$(fbstate)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("fleet-feedback",{}).get("how")=="installed" else 1)' \
  "$WORK/jconf/plugins-defaulted.json" && ok || fail "J managed: plugins-defaulted.json lacks fleet-feedback" "$(cat "$WORK/jconf/plugins-defaulted.json" 2>&1)"
# the person turns it off ⇒ the next apply (an upgrade) leaves it off
"$FK" plugin disable "$FB"; : > "$ST/calls"
out=$(jens --gone "$WORK/gone" --default fleet-feedback)
grep -qE "^plugin (install|enable) $FB" "$ST/calls" && fail "J a person's off was turned back on" "$(cat "$ST/calls")"; ok
[ "$(fbstate)" = off ] && ok || fail "J off did not stay off" "$(fbstate)"
# … or uninstalls it ⇒ never reinstalled
"$FK" plugin uninstall "$FB"; : > "$ST/calls"
out=$(jens --gone "$WORK/gone" --default fleet-feedback)
[ "$(fbstate)" = absent ] && ok || fail "J an uninstalled default came back" "$(cat "$ST/calls")"
# account release: the login is no longer managed (no --default) ⇒ nothing taken away
"$FK" plugin install "$FB"; : > "$ST/calls"
out=$(jens --gone "$WORK/gone")
grep -qE '^plugin (disable|uninstall)' "$ST/calls" && fail "J release took the plugin away" "$(cat "$ST/calls")"; ok
[ "$(fbstate)" = on ] && ok || fail "J release changed the plugin" "$(fbstate)"
# installed already by the person (no record yet) ⇒ recorded, its switch untouched
REC2="$WORK/defaulted2.json"; "$FK" plugin disable "$FB"; : > "$ST/calls"
out=$(ens --gone "$WORK/gone" --default fleet-feedback --defaulted "$REC2")
has "already installed here — recorded as defaulted" "$out" "J already installed: recorded"
grep -q "^plugin enable $FB" "$ST/calls" && fail "J already installed: its switch was flipped" "$(cat "$ST/calls")"; ok
[ "$(fbstate)" = off ] && ok || fail "J already installed + off: turned on" "$(fbstate)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["fleet-feedback"]["how"]=="already" else 1)' "$REC2" \
  && ok || fail "J already installed: record" "$(cat "$REC2" 2>&1)"
# install-apply: --default only for a managed login, inside the plugins pass's ensure
grep -q 'fleet_node_manages "$LOGIN" && pdef=(--default fleet-feedback)' "$AP" \
  && sed -n '/fleet-plugins.py" ensure/,/2>&1); then/p' "$AP" | grep -q 'pdef\[@\]' && ok \
  || fail "J install-apply does not pass --default fleet-feedback under fleet_node_manages"
# the switch: fleet feedback on|off|status
SW="$BIN/fleet-feedback-switch.sh"; SS="$WORK/sw-settings.json"; FC2="$WORK/fakeclaude-sw"
cat > "$FC2" <<'SH'
#!/bin/bash
# `claude plugin enable|disable|install <id>` writing enabledPlugins in $SW_SETTINGS
python3 - "$SW_SETTINGS" "$2" "${3:-}" <<'PY'
import json, sys, os
p, verb, pid = sys.argv[1:4]
d = json.load(open(p)) if os.path.exists(p) else {}
if verb in ("enable", "disable"):
    d.setdefault("enabledPlugins", {})[pid] = (verb == "enable")
json.dump(d, open(p, "w"))
PY
SH
chmod +x "$FC2"
sw() { env SW_SETTINGS="$SS" FLEET_FEEDBACK_PLUGIN_SETTINGS="$SS" FLEET_FEEDBACK_CLAUDE="$FC2" \
         FLEET_CONF_DIR="$WORK/swconf" bash "$SW" "$@" 2>&1; }
rm -f "$SS"
out=$(FLEET_FEEDBACK_MANAGED=0 sw status); has "fleet-feedback: 关 · 自己的电脑" "$out" "J switch: own computer, nothing installed → 关"
out=$(FLEET_FEEDBACK_MANAGED=0 sw on); rc=$?
[ "$rc" = 0 ] && ok || fail "J switch on rc=$rc" "$out"
FLEET_FEEDBACK_MANAGED=0 sw enabled >/dev/null && ok || fail "J switch: on → enabled"
out=$(FLEET_FEEDBACK_MANAGED=1 sw status); has "fleet-feedback: 开" "$out" "J switch: on → status 开"
has "托管登录" "$out" "J switch: managed status names it"
has "还没装过" "$out" "J switch: managed, no record → says the next sync installs it"
out=$(FLEET_FEEDBACK_MANAGED=1 sw off); has "升级也不会再打开它" "$out" "J switch: managed off says it stays off"
FLEET_FEEDBACK_MANAGED=1 sw enabled >/dev/null && fail "J switch: off → still enabled"; ok
sw bogus >/dev/null; [ $? = 2 ] && ok || fail "J switch: an unknown word is usage (2)"
grep -q '  feedback)' "$BIN/fleet" && grep -q 'on|off|status|enabled) .*fleet-feedback-switch.sh' "$BIN/fleet" && ok \
  || fail "J bin/fleet does not dispatch fleet feedback on|off|status to the switch"
grep -q 'pass feedback' "$BIN/fleet-doctor.sh" && grep -q 'info feedback' "$BIN/fleet-doctor.sh" \
  && ! grep -q 'warn feedback' "$BIN/fleet-doctor.sh" && ok \
  || fail "J fleet-doctor.sh: a feedback row that is PASS / INFO, never WARN"

# ---- K: fleet-infra, the admins' runbooks (issue #3586, EPIC #3569 C16) ------------
FI="$ROOT/plugins/fleet-infra"
for sk in mac-node-prep mac-node-enroll login-lifecycle ack-linux-node sg-relay-setup hub-deploy; do
  f="$FI/skills/$sk/SKILL.md"
  [ -f "$f" ] && ok || fail "K fleet-infra carries no skills/$sk/SKILL.md"
  # every runbook has the same five parts, in order
  heads=$(grep -E '^## ' "$f" | sed 's/^## //' | paste -sd'|' -)
  case "$heads" in
    什么时候用\|先查什么\|步骤\|怎么验收\|怎么回滚*) ok ;;
    *) fail "K $sk: headings are «$heads», want 什么时候用 · 先查什么 · 步骤 · 怎么验收 · 怎么回滚" ;;
  esac
done
[ ! -e "$FI/hooks" ] && [ ! -e "$FI/.mcp.json" ] && ok || fail "K fleet-infra runs nothing on its own: no hooks, no MCP server"
# no internal name or address in it — the ONE rule table (EPIC #3569 共同约定 1)
out=$(bash "$BIN/oss-scan.sh" --root "$ROOT" -- plugins/fleet-infra 2>&1); rc=$?
[ "$rc" = 0 ] && ok || fail "K oss-scan over plugins/fleet-infra found something (rc=$rc)" "$out"
# never a managed default, never handed out by the hub
: > "$ST/calls"; out=$(FLEET_CONF_DIR="$WORK/kconf" ens --gone "$WORK/gone" --default fleet-infra)
grep -qE '^plugin (install|enable) fleet-infra' "$ST/calls" && fail "K --default fleet-infra installed it" "$(cat "$ST/calls")"; ok
has "never a managed default" "$out" "K --default fleet-infra is refused out loud"
grep -q 'pdef=(--default [^)]*fleet-infra' "$AP" && fail "K install-apply defaults fleet-infra"; ok
grep -q '"fleet-infra"' "$BIN/fleet-agent-team.py" && ok || fail "K fleet-agent-team.py does not refuse fleet-infra"

# ---- A (cont.) + H: the real CLI ----------------------------------------------------
if command -v claude >/dev/null 2>&1 && claude plugin validate --help >/dev/null 2>&1; then
  for p in "$ROOT" "$ROOT"/plugins/*; do
    v=$(claude plugin validate "$p" 2>&1) || fail "A claude plugin validate ${p#"$ROOT"/}" "$v"
    ok
  done
  H="$WORK/home"; mkdir -p "$H"
  ln -s "$ROOT" "$WORK/fleet"   # as ~/.claude/fleet: a link to the install
  hc() { env -u CLAUDE_CONFIG_DIR HOME="$H" claude plugin "$@" 2>&1; }
  ids() { hc list --json | python3 -c 'import json,sys; print(" ".join(sorted(e["id"] for e in json.load(sys.stdin))))'; }
  out=$(hc marketplace add "$WORK/fleet") || fail "H marketplace add" "$out"
  [ -z "$(ids)" ] && ok || fail "H a fresh login lists a plugin" "$(ids)"
  out=$(hc install fleet-orchestrate@claude-fleet) || fail "H install fleet-orchestrate" "$out"
  [ "$(ids)" = "fleet-orchestrate@claude-fleet" ] && ok || fail "H install → listed" "$(ids)"
  ls "$H"/.claude/plugins/cache/claude-fleet/fleet-orchestrate/*/skills/fleet-orchestrate/SKILL.md >/dev/null 2>&1 && ok \
    || fail "H the installed copy carries the /fleet-orchestrate skill"
  out=$(hc uninstall fleet-orchestrate@claude-fleet) || fail "H uninstall" "$out"
  [ -z "$(ids)" ] && ok || fail "H uninstall → none" "$(ids)"
  out=$(hc install fleet-epic@claude-fleet) || fail "H install fleet-epic" "$out"
  case " $(ids) " in *" fleet-epic@claude-fleet "*) ok ;; *) fail "H install fleet-epic → listed" "$(ids)" ;; esac
  for f in agents/epic-driver.md commands/fleet-epic-run.md skills/epic-page/SKILL.md; do
    ls "$H"/.claude/plugins/cache/claude-fleet/fleet-epic/*/"$f" >/dev/null 2>&1 && ok \
      || fail "H the installed fleet-epic carries $f"
  done
  out=$(hc install fleet-infra@claude-fleet) || fail "H install fleet-infra" "$out"
  ls "$H"/.claude/plugins/cache/claude-fleet/fleet-infra/*/skills/mac-node-prep/SKILL.md >/dev/null 2>&1 && ok \
    || fail "H the installed fleet-infra carries mac-node-prep"
  hc uninstall fleet-infra@claude-fleet >/dev/null
  hc uninstall fleet-epic@claude-fleet >/dev/null; hc uninstall fleet-orchestrate@claude-fleet >/dev/null
  case " $(ids) " in *" fleet-epic@"*) fail "H uninstall fleet-epic → still listed" "$(ids)" ;; *) ok ;; esac
fi

printf 'fleet-plugins-selftest: PASS (%d checks)\n' "$CHECKS"
