#!/usr/bin/env bash
# precompact-hook-selftest.sh — bin/precompact-hook.sh, the PreCompact(auto) hook
# that saves a recovery map right before Claude Code's own compaction (issue
# #1321, EPIC #1315 R1), and its read-back in bin/refocus-hook.sh.
#
#   WIRED     hooks/settings-hooks.json runs it under PreCompact, matcher `auto`;
#             the codex target does not wire it
#   AUTO      a worker's PreCompact(auto) payload → the map in the worktree's git
#             dir (issue, branch, git status, prmap PR, latest comment, the
#             operator's last prompts), @compact_native stamped, ONE
#             `native-precompact` row reason `auto saved`; stdout stays empty
#   RESTORE   the SessionStart(compact) that follows restates the charter WITH a
#             "check the map" line naming it, and consumes @compact_native
#   FLEET     PreCompact(manual) while @compact_stage=compacting (the fleet's own
#             /compact) → no map write, no row
#   KEPT      a native compaction between the fleet's prep and its /compact keeps
#             the session's own (newer) map → reason `auto kept`
#   SCRATCH   @raw=1 in a non-git dir → the map under the fleet's conf dir, and
#             the refocus restates it inline after the native compaction
#   HUB       no @issue, no @raw → no map, row reason `auto no-map`
#   OFF       FLEET_PRECOMPACT=0 / a codex pane / a headless child → nothing
# No real tmux server, no gh, no live Claude.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
FILES="precompact-hook.sh refocus-hook.sh fleet-lib.sh fleet-ladder-log.sh"
for f in $FILES; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/precompact-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/inst/bin" "$WORK/conf/fleets/s1" "$WORK/tmp/.claude-dash/fleets/acme-widgets" \
         "$WORK/widgets-issue-12" "$WORK/scratchdir" "$WORK/hubdir"
for f in $FILES; do cp "$BIN/$f" "$WORK/inst/bin/$f"; done
HOOK="$WORK/inst/bin/precompact-hook.sh"
REFOCUS="$WORK/inst/bin/refocus-hook.sh"
GCONF="$WORK/inst/fleet.conf"
LOG="$WORK/inst/logs/context-ladder.log"
OPTS="$WORK/opts"
WT="$WORK/widgets-issue-12"
git -C "$WT" init -q -b issue-12 2>/dev/null || { git -C "$WT" init -q && git -C "$WT" checkout -q -b issue-12; }
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'first commit'
echo hi > "$WT/dirty.txt"
WTMAP="$(git -C "$WT" rev-parse --absolute-git-dir)/fleet-recovery-map.md"
printf 'FLEET_REPO=acme/widgets\nFLEET_MAIN=%s/main\nFLEET_BASE_BRANCH=trunk\n' "$WORK" > "$WORK/conf/fleets/s1/conf"
printf 'issue-12\t#345\tOPEN\t✓\tready\t\n' > "$WORK/tmp/.claude-dash/fleets/acme-widgets/prmap"
: > "$GCONF"

# A fake fleet-gh.sh in the install copy: the hook's one network read.
cat > "$WORK/inst/bin/fleet-gh.sh" <<'GH'
#!/bin/bash
echo "$*" >> "${FAKE_GHLOG:-/dev/null}"
echo '{"comments":[{"url":"https://github.com/acme/widgets/issues/12#issuecomment-1"},{"url":"https://github.com/acme/widgets/issues/12#issuecomment-2"}],"_source":"cache","_age":3}'
GH

# The transcript: two operator prompts, tool plumbing and a meta row to skip.
TRANSCRIPT="$WORK/t.jsonl"
cat > "$TRANSCRIPT" <<'TJ'
{"type":"user","message":{"role":"user","content":"please fix the widget spinner"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"META-SHOULD-NOT-APPEAR"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"and then ship it with a PR"}]}}
TJ

# --- stateful fake tmux: options in $OPTS ("key<TAB>value") ----------------------
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/usr/bin/env python3
import os, re, sys
a = sys.argv[1:]
if a[:1] in (["-L"], ["-S"]): a = a[2:]
path = os.environ["FAKE_OPTS"]
def load():
    d = {}
    try:
        for line in open(path):
            k, _, v = line.rstrip("\n").partition("\t"); d[k] = v
    except FileNotFoundError: pass
    return d
def save(d):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for k, v in d.items(): f.write("%s\t%s\n" % (k, v))
    os.replace(tmp, path)
# a format: innermost #{name} from the table; #{?cond,a,b} picks a or b — tmux's
# conditional, which the fleet's session read is since #1489
# (`#{?#{session_group},#{session_group},#{session_name}}`)
def _fx(d, f):
    r = re.compile(r"#\{([^#{}]*)\}")
    while True:
        m = r.search(f)
        if not m:
            return f
        k = m.group(1)
        if k.startswith("?"):
            p = k[1:].split(",", 2) + ["", ""]
            v = p[1] if p[0] else p[2]
        else:
            v = d.get(k, "")
        f = f[:m.start()] + v + f[m.end():]
verb = a[0] if a else ""
if verb == "display-message":
    d = load(); fmt = a[-1]
    print(_fx(d, fmt))
elif verb in ("set-window-option", "set-option"):
    d = load(); unset = "-u" in a
    rest = [x for x in a[1:] if x not in ("-u", "-w")]
    i = rest.index("-t"); rest = rest[:i] + rest[i+2:]
    if unset: d.pop(rest[0], None)
    else: d[rest[0]] = rest[1] if len(rest) > 1 else ""
    save(d)
else:
    sys.exit(1)
FAKE
chmod +x "$WORK/fakepath/tmux" "$WORK/inst/bin/fleet-gh.sh"

ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2
         printf -- '--- ladder log ---\n' >&2; cat "$LOG" >&2 2>/dev/null
         printf -- '--- opts ---\n' >&2; cat "$OPTS" >&2 2>/dev/null; exit 1; }

# reset [k=v …] — a worker window by default; `@issue=` blanks it.
reset() {
  printf 'session_name\ts1\n@issue\t12\nwindow_id\t@1\nwindow_name\twidgets-12\n' > "$OPTS"
  for kv in "$@"; do printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$OPTS"; done
  rm -f "$LOG" "$WTMAP"
}
getopt() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$OPTS" | tail -n1; }
penv() { env -i PATH="$WORK/fakepath:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$WORK" TMPDIR="$WORK/tmp" \
           TMUX="$WORK/sock,1,0" TMUX_PANE='%9' FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 \
           FAKE_OPTS="$OPTS" FAKE_GHLOG="$WORK/gh.log" "$@"; }
# precompact <dir> <trigger> [env…]
precompact() {
  local dir="$1" trig="$2"; shift 2
  OUT=$(cd "$dir" && printf '{"session_id":"s","transcript_path":"%s","cwd":"%s","hook_event_name":"PreCompact","trigger":"%s","custom_instructions":""}' \
          "$TRANSCRIPT" "$dir" "$trig" | penv "$@" bash "$HOOK" 2>&1); RC=$?
}
compact_start() {
  OUT=$(cd "$1" && printf '{"hook_event_name":"SessionStart","source":"compact"}' | penv bash "$REFOCUS" 2>&1)
}
rows() { if [ -f "$LOG" ]; then grep -vc '^#' "$LOG"; else echo 0; fi; }
row()  { grep -v '^#' "$LOG" 2>/dev/null | sed -n "${1}p"; }
# expect_row <n> <step> <reason>
expect_row() {
  local r; r=$(row "$1")
  IFS=$'\t' read -r _ _ e_step e_sess e_pane _ _ _ e_rsn <<<"$r"
  [ "$e_step" = "$2" ] && [ "$e_sess" = s1 ] && [ "$e_pane" = '%9' ] && [ "$e_rsn" = "$3" ] \
    || fail "row $1: want step '$2' reason '$3'" "$r"
}

# ---- WIRED ---------------------------------------------------------------------
python3 - "$ROOT/hooks/settings-hooks.json" <<'PY' || fail "WIRED: PreCompact(auto) → precompact-hook.sh missing from settings-hooks.json"
import json, sys
t = json.load(open(sys.argv[1]))["hooks"].get("PreCompact", [])
assert any(g.get("matcher") == "auto" and any("bin/precompact-hook.sh" in h.get("command", "")
           for h in g.get("hooks", [])) for g in t)
PY
if [ -f "$BIN/fleet-hooks-emit.sh" ]; then
  bash "$BIN/fleet-hooks-emit.sh" --target codex --root "$ROOT" 2>/dev/null | grep -q precompact-hook \
    && fail "WIRED: the codex target must not wire PreCompact"
fi
ok "WIRED: PreCompact matcher auto runs precompact-hook.sh (claude only)"

# ---- AUTO ----------------------------------------------------------------------
reset
precompact "$WT" auto
[ "$RC" = 0 ] && [ -z "$OUT" ] || fail "AUTO: the hook must exit 0 and print nothing" "rc=$RC $OUT"
[ -f "$WTMAP" ] || fail "AUTO: no map at $WTMAP"
M=$(cat "$WTMAP")
for want in 'auto-saved before Claude Code' 'issue #12 · acme/widgets' 'https://github.com/acme/widgets/issues/12' \
            'issuecomment-2' 'branch: issue-12 → base trunk' 'first commit' 'PR: #345 OPEN ci✓' \
            '?? dirty.txt' 'please fix the widget spinner' 'and then ship it with a PR'; do
  case "$M" in *"$want"*) : ;; *) fail "AUTO: map lacks '$want'" "$M" ;; esac
done
case "$M" in *META-SHOULD-NOT-APPEAR*|*tool_result*) fail "AUTO: map carries a meta/tool row" "$M" ;; esac
[ -n "$(getopt @compact_native)" ] || fail "AUTO: @compact_native not stamped"
[ "$(rows)" = 1 ] || fail "AUTO: want exactly 1 ladder row, got $(rows)"
expect_row 1 native-precompact 'auto saved'
grep -q -- 'issue view 12 --repo acme/widgets --json comments' "$WORK/gh.log" || fail "AUTO: comments read not (repo, issue)-keyed" "$(cat "$WORK/gh.log")"
ok "AUTO: worker map written (git, PR, comment, prompts) + one 'native-precompact auto saved' row"

# ---- RESTORE -------------------------------------------------------------------
compact_start "$WT"
case "$OUT" in *'[fleet charter] #12'*'auto-compacted you'*"$WTMAP"*) : ;;
  *) fail "RESTORE: the refocus must name the native map" "$OUT" ;; esac
[ -z "$(getopt @compact_native)" ] || fail "RESTORE: @compact_native not consumed"
expect_row 2 restored auto
compact_start "$WT"
case "$OUT" in *'auto-compacted you'*) fail "RESTORE: a second compaction must not re-read a consumed map" "$OUT" ;; esac
ok "RESTORE: SessionStart(compact) reads the native map back once"

# ---- FLEET (manual, the fleet's own /compact) ----------------------------------
reset '@compact_stage=compacting' "@compact_prep_ts=$(date +%s)"
precompact "$WT" manual
[ -z "$OUT" ] && [ ! -f "$WTMAP" ] && [ "$(rows)" = 0 ] && [ -z "$(getopt @compact_native)" ] \
  || fail "FLEET: the fleet's own /compact must write no map and no row" "$OUT"
ok "FLEET: PreCompact(manual) during the fleet's compaction writes nothing"

# ---- KEPT ----------------------------------------------------------------------
reset '@compact_stage=prep' "@compact_prep_ts=$(( $(date +%s) - 30 ))"
printf 'SESSION-WRITTEN MAP\n' > "$WTMAP"
precompact "$WT" auto
[ "$(cat "$WTMAP")" = 'SESSION-WRITTEN MAP' ] || fail "KEPT: the session's newer map was overwritten" "$(cat "$WTMAP")"
expect_row 1 native-precompact 'auto kept'
[ -n "$(getopt @compact_native)" ] || fail "KEPT: @compact_native must still be stamped for the read-back"
# …but a map OLDER than the prep stamp is stale: rewrite it.
reset '@compact_stage=prep' "@compact_prep_ts=$(( $(date +%s) + 5 ))"
printf 'OLD MAP\n' > "$WTMAP"
precompact "$WT" auto
grep -q 'auto-saved' "$WTMAP" || fail "KEPT: a map older than the prep stamp must be replaced"
expect_row 1 native-precompact 'auto saved'
ok "KEPT: a newer prep map survives; an older one is replaced"

# ---- SCRATCH -------------------------------------------------------------------
reset '@issue=' '@raw=1' 'window_name=scratch-3'
SMAP="$WORK/conf/fleets/s1/recovery/w1.md"
precompact "$WORK/scratchdir" auto
[ -f "$SMAP" ] || fail "SCRATCH: no map at $SMAP" "$OUT"
grep -q 'scratch session (no issue)' "$SMAP" || fail "SCRATCH: map lacks the scratch line" "$(cat "$SMAP")"
grep -q 'issuecomment' "$SMAP" && fail "SCRATCH: a scratch has no issue to link"
expect_row 1 native-precompact 'auto saved'
compact_start "$WORK/scratchdir"
case "$OUT" in *'[fleet recovery map] scratch'*'auto-compacted you'*'please fix the widget spinner'*) : ;;
  *) fail "SCRATCH: the refocus must restate the native map inline" "$OUT" ;; esac
ok "SCRATCH: map under the conf dir, restated inline after the compaction"

# ---- HUB -----------------------------------------------------------------------
reset '@issue=' 'window_name=hub'
precompact "$WORK/hubdir" auto
[ -z "$OUT" ] && [ -z "$(getopt @compact_native)" ] || fail "HUB: no map, no stamp" "$OUT"
expect_row 1 native-precompact 'auto no-map'
ok "HUB: a native compaction on the hub is logged (no-map), nothing written"

# ---- OFF -----------------------------------------------------------------------
reset
printf 'FLEET_PRECOMPACT=0\n' > "$GCONF"
precompact "$WT" auto
[ ! -f "$WTMAP" ] && [ "$(rows)" = 0 ] || fail "OFF: FLEET_PRECOMPACT=0 must write nothing"
: > "$GCONF"
reset '@cc_agent=codex'
precompact "$WT" auto
[ ! -f "$WTMAP" ] && [ "$(rows)" = 0 ] || fail "OFF: a codex pane must write nothing"
reset
precompact "$WT" auto CLAUDE_CODE_ENTRYPOINT=sdk-cli
[ ! -f "$WTMAP" ] && [ "$(rows)" = 0 ] || fail "OFF: a headless child must write nothing"
precompact "$WT" bogus
[ ! -f "$WTMAP" ] && [ "$(rows)" = 0 ] || fail "OFF: an unknown trigger must write nothing"
ok "OFF: kill switch, codex, headless and unknown triggers are silent"

echo "precompact-hook-selftest: all passed"
