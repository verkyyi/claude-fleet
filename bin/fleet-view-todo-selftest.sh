#!/bin/bash
# shellcheck disable=SC1010  # `done` here is a state word handed to w(), not the keyword
# fleet-view-todo-selftest.sh — ⌘P's groups say what the person should do (issue #4225).
#
#   A  the ask book (fleet-issue-bridge.sh bridge_ask_note): a ⛔ comment writes
#      $G/asks/<slug>#<N> with its question; the worker's own later note keeps it;
#      a later person's comment, a `fleet:answer` or a 「决定…」 removes it; an
#      older comment relayed late never does
#   B  the producer (tmux-dashboard-rows.sh --rows) marks a bound session 已结束
#      once its issue is off the open-issue list, its PR merged and its last state
#      older than FLEET_VIEW_LANDED_SECS — not while the issue is open, not inside
#      the window, not with `keep`, not while its deploy is pending (field 20
#      `unknown` instead)
#   C  fleet_view.entries over that producer: done + an unanswered ask → 等你 (the
#      question under it); an ask on a closed issue → not; done + PR open → 等合并
#      / 等发版 with its step (检查中 · 检查红), merged-not-live → 等发布列车; done +
#      closed + merged > 24 h → 已结束; idle → 其他; the group order
#   D  `fleet ls` (fleet-session-cli.py attach_bus) reads the same book: 在问
#   E  stage_of / group_of on every PR cell the producer writes; the words in
#      both languages
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
BRIDGE="$BIN/fleet-issue-bridge.sh"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-view-todo selftest: python3 absent — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fvtodo-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
unset CCQUOTA_FLEET FLEET_DASH_ORDER TMUX TMUX_PANE FLEET_SIDEBAR_SOURCE FLEET_STATUS_G FLEET_VIEW_LANDED_SECS
S="fvtodo$$"
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
C="$WORK/.claude-dash"; G="$C/global"; FD="$C/fleets/acme-app"
mkdir -p "$G" "$FD" "$WORK/conf/fleets/$S/repos" "$WORK/bin"
printf 'FLEET_REPO=acme/app\n' > "$WORK/conf/fleets/$S/conf"
printf 'FLEET_REPO="acme/app"\n' > "$WORK/conf/fleets/$S/repos/acme-app.conf"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
pass() { echo "ok   $*"; }

# ============================================================================
# A. the ask book
# ============================================================================
(
  FLEET_C="$C"; FROM_PREFIX='<!-- fleet:from '
  now() { date +%s; }
  eval "$(awk '/^bridge_ask_note\(\) \{/,/^}/' "$BRIDGE")"
  command -v bridge_ask_note >/dev/null || { echo "no bridge_ask_note in $BRIDGE"; exit 1; }
  F="$G/asks/acme-app#12"
  W='<!-- fleet:from role=worker session=s issue=12 -->'
  bridge_ask_note acme-app 12 100 $'⛔ blocked: 要不要先合 #7？\n\nmore\n<!-- fleet:no-relay -->\n'"$W"
  [ "$(cut -f1,3 "$F")" = $'100\t要不要先合 #7？' ] || { echo "ask not written: $(cat "$F" 2>&1)"; exit 1; }
  bridge_ask_note acme-app 12 101 "still working on it"$'\n'"$W"
  [ -f "$F" ] || { echo "the worker's own note answered it"; exit 1; }
  bridge_ask_note acme-app 12 99 "an older person's comment, relayed late"
  [ -f "$F" ] || { echo "an older comment answered it"; exit 1; }
  bridge_ask_note acme-app 12 102 "先合 #7"
  [ -f "$F" ] && { echo "a person's answer did not remove it"; exit 1; }
  bridge_ask_note acme-app 12 103 $'⛔ blocked — needs authorization: 推 tag？\n<!-- fleet:ask v=1 id=x -->\n'"$W"
  [ "$(cut -f3 "$F")" = '推 tag？' ] || { echo "a permission ask: $(cat "$F")"; exit 1; }
  bridge_ask_note acme-app 12 104 $'默认\n<!-- fleet:answer row=x by=default -->\n<!-- fleet:from role=steward -->'
  [ -f "$F" ] && { echo "a fleet:answer did not remove it"; exit 1; }
  bridge_ask_note acme-app 12 105 $'⛔ blocked: again\n'"$W"
  bridge_ask_note acme-app 12 106 $'决定（直达）：先不推\n'"$W"
  [ -f "$F" ] && { echo "a 决定 did not remove it"; exit 1; }
  bridge_ask_note acme-app x 107 '⛔ blocked: no number'
  [ -e "$G/asks/acme-app#x" ] && { echo "a non-number issue wrote a file"; exit 1; }
  exit 0
) || fail "A: the ask book" "$(cat "$G"/asks/* 2>/dev/null)"
rm -rf "$G/asks"
pass "A  ask book: ⛔ writes, the worker's own note keeps, a person / fleet:answer / 决定 removes, late relays ignored"

# ============================================================================
# B. the producer — a PATH-shimmed tmux replays a fixture window list
# ============================================================================
US=$'\x1f'
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037'); lw=0; fmt=0
for a in "$@"; do [ "$a" = list-windows ] && lw=1; case "$a" in *"$US"*) fmt=1 ;; esac; done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
export WLIST_FILE="$WORK/wlist"
SHIMPATH="$WORK/bin:$PATH"
NOW=$(date +%s); OLD=$((NOW - 2 * 86400)); NEW=$((NOW - 3600))
gk() { local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"; }
# w <idx> <name> <state> <state_ts> <issue> <reap policy> — WFMT's fields: sess idx
# name path state state_ts wid iss origin wt agent hnd nsub exp pin qwait reap_due
# reap_seen reap_stamp wrepo wnorepo slept repo_fold loop title born cfg ittl reap
w() {
  printf '%s\n' "$S$US$1$US$2$US/w/app-$2$US$3$US$4$US@$1$US$5$US$US$US$US$US$US$US$US$US$US$US${US}acme/app$US$US$US$US$US$US${1}000$US$US$US$6" >> "$WLIST_FILE"
  [ -n "$5" ] && printf 'issue-%s\tclean\n' "$5" > "$G/git_$(gk "/w/app-$2")"
  return 0
}
: > "$WLIST_FILE"
w 1 over    done "$OLD" 11 merged     # closed + merged + 2 days → 已结束
w 2 asks    done "$OLD" 12 merged     # merged, but #12 is open — and asks
w 3 fresh   done "$NEW" 13 merged     # closed + merged, an hour ago → not yet
w 4 train   done "$OLD" 14 merged     # merged, not live → 等发布列车, never 已结束
w 5 kept    done "$OLD" 15 keep       # its person keeps it
w 6 closedq done "$NEW" 16 merged     # an ask on a closed issue (an hour ago: not 已结束 yet)
w 7 chk     done "$NEW" 17 merged     # PR open, checks running
w 8 red     done "$NEW" 18 merged     # PR open, checks red
w 9 idle    idle "$NEW" '' keep       # nothing to do
# the open-issue list: #12 #17 #18 open; 11 13 14 15 16 closed
printf '· no milestone\t#12\t·\t在问的\n· no milestone\t#17\t·\t检查中的\n· no milestone\t#18\t·\t检查红的\n' > "$FD/issues"
: > "$FD/issues.ts"
printf 'issue-11\t#111\tMERGED\t✓\tready\ts11\nissue-12\t#112\tMERGED\t✓\tready\ts12\nissue-13\t#113\tMERGED\t✓\tready\ts13\nissue-14\t#114\tMERGED\t✓\tready\ts14\nissue-15\t#115\tMERGED\t✓\tready\ts15\nissue-16\t#116\tMERGED\t✓\tready\ts16\nissue-17\t#117\tOPEN\t…\tunknown\t\nissue-18\t#118\tOPEN\t✗\tready\t\n' > "$FD/prmap"
: > "$FD/prmap.ts"
printf 'unknown\t1\n' > "$FD/deploy_s14"
out=$(PATH="$SHIMPATH" FLEET_SESSION=$S FLEET_ROWS_UNFOLD=1 bash "$ROWS" --rows 2>&1) || fail "B: the producer exited non-zero" "$out"
ended=$(printf '%s\n' "$out" | awk -F"$US" '$1 == "hdr" && $2 == "ended" { on = 1; next } $1 == "hdr" { on = 0 } on { print $4 }' | sed 's/ .*//' | tr '\n' ' ')
[ "$ended" = "over " ] || fail "B: 已结束 should be exactly «over», got «${ended}»" "$out"
f20=$(printf '%s\n' "$out" | awk -F"$US" '$1 == "@4" { print (NF >= 20 ? $20 : "-") }')
[ "$f20" = unknown ] || fail "B: the train row's field 20: «${f20}»" "$out"
n20=$(printf '%s\n' "$out" | awk -F"$US" '$1 ~ /^@/ && $1 != "@4" && NF >= 20' | wc -l | tr -d ' ')
[ "$n20" = 0 ] || fail "B: field 20 on a row with nothing to say" "$out"
# a FULL list (the collector's newest 300 open ones, issue #4225): #11 is older
# than all of them — not on it says nothing; a number newer than its oldest does
cp "$FD/issues" "$FD/issues.keep"
i=1000; while [ "$i" -lt 1300 ]; do printf '· no milestone\t#%s\t·\tt\n' "$i"; i=$((i + 1)); done > "$FD/issues"
outf=$(PATH="$SHIMPATH" FLEET_SESSION=$S FLEET_ROWS_UNFOLD=1 bash "$ROWS" --rows 2>&1)
printf '%s\n' "$outf" | grep -q "^hdr${US}ended" && fail "B: an issue older than a full list went 已结束" "$outf"
python3 - "$BIN" "$FD" <<'PY' || fail "B: open_ask on a full list"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fv", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
full = {"acme-app": {"#%d" % n for n in range(1000, 1300)}}
import os
d = fv.dash_global() / "asks"; d.mkdir(parents=True, exist_ok=True)
(d / "acme-app#16").write_text("1\t1\told one\n"); (d / "acme-app#2000").write_text("1\t1\tnew one\n")
assert fv.open_ask("acme-app", "16", dict(full)) == "old one"      # older than the list: unknown → still asks
assert fv.open_ask("acme-app", "2000", dict(full)) == ""           # newer and missing: closed
assert fv.open_ask("acme-app", "1005", dict(full)) == ""           # on the list, no file for it
assert fv.open_ask("acme-app", "16", {"acme-app": {"#12"}}) == ""  # a short list: missing = closed
for f in ("acme-app#16", "acme-app#2000"): (d / f).unlink()
PY
mv "$FD/issues.keep" "$FD/issues"
# no issue list read ⇒ nothing is closed
mv "$FD/issues" "$FD/issues.off"
out0=$(PATH="$SHIMPATH" FLEET_SESSION=$S FLEET_ROWS_UNFOLD=1 bash "$ROWS" --rows 2>&1)
printf '%s\n' "$out0" | grep -q "^hdr${US}ended" && fail "B: with no open-issue list a bound row went 已结束" "$out0"
mv "$FD/issues.off" "$FD/issues"
pass "B  producer: closed + merged + past 24 h → 已结束; open / fresh / keep / deploy pending stay; field 20 = unknown"

# ============================================================================
# C + D + E. the panel and `fleet ls`
# ============================================================================
mkdir -p "$G/asks"
printf '200\t%s\t要不要先合 #7？\n' "$NOW" > "$G/asks/acme-app#12"
printf '201\t%s\t早就关了的单\n' "$NOW" > "$G/asks/acme-app#16"
printf 'PATH=%q FLEET_SESSION=%q exec bash %q --rows\n' "$SHIMPATH" "$S" "$ROWS" > "$WORK/rows.sh"
FLEET_VIEW_ROWS_CMD="sh '$WORK/rows.sh'" FLEET_SESSION=$S FV_FLEET=$S python3 - "$BIN" <<'PY' || fail "C/D/E: the panel"
import importlib.util, os, sys
B = sys.argv[1]
def load(name, f):
    spec = importlib.util.spec_from_file_location(name, os.path.join(B, f))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
fv = load("fleet_view", "fleet_view.py")
fleet = os.environ["FV_FLEET"]
fv.view_row = lambda vid: {}
fv.view_fleet = lambda vid, row=None: fleet
fv.here_label = lambda row: "nodeA"
fv.fleet_logins = lambda: {}
import time
t = int(time.time())
# window activity: 「刚落地」's clock — the old ones two days quiet, the rest an hour
fv.windows = lambda f: {"@%d" % i: ("", "worker", t - (2 * 86400 if i in (1, 2, 4, 5) else 3600)) for i in range(1, 10)}
fv.gone_text = lambda f: ""
it = fv.entries("v1", hub=False)
heads = [e["group"] for e in it if e["kind"] == "hdr"]
assert heads == ["ask", "wait", "landed", "other"], (heads, [(e.get("name"), e.get("group"), e.get("sec")) for e in it])
grp = {e["name"]: e["group"] for e in it if e["kind"] == "sess"}
want = {"asks": "ask", "chk": "wait", "red": "wait", "train": "wait", "fresh": "landed", "kept": "other",
        "closedq": "landed", "idle": "other", "over": "ended"}
assert grp == want, grp
ask = [e for e in it if e["kind"] == "ask"]
assert [(a["of"], a["text"]) for a in ask] == [("@2", "要不要先合 #7？")], ask
tag = {e["name"]: e["tags"] for e in it if e["kind"] == "sess"}
assert tag["chk"] == ["检查中"] and tag["red"] == ["检查红"] and tag["train"] == ["等发布列车"], tag
assert tag["fresh"] == [] and tag["idle"] == [], tag
hdr = [e["text"] for e in it if e["kind"] == "hdr"]
assert hdr[1] == "等合并 / 等发版 3", hdr
sec = [e for e in it if e["kind"] == "sec"]
assert sec and sec[0]["sec"] == "ended" and sec[0]["n"] == 1, sec
over = next(e for e in it if e.get("name") == "over")
assert over["word"] == "已合并", over["word"]
# D: fleet ls reads the same book
cli = load("fleet_session_cli", "fleet-session-cli.py")
cli.bus_cache = lambda: {}
cli.bus_local = lambda keys: {}
rs = [{"key": "@2", "state": "done", "issue": "12", "repo": "", "ended": ""},
      {"key": "@6", "state": "done", "issue": "16", "repo": "", "ended": ""},
      {"key": "@9", "state": "idle", "issue": "", "repo": "", "ended": ""}]
cli.attach_bus(rs)
assert [(r["ask"], r["ask_kind"]) for r in rs] == [("要不要先合 #7？", "question"), ("", ""), ("", "")], rs
# E: every PR cell the producer writes
cells = {"—": "", "closed": "", "live": "", "merged": "", "#75…": "checking", "#75": "checking",
         "#75✗": "red", "✗": "red", "#75✓!": "red", "#75✓": "green", "#75✓↑": "green", "✓d": "green",
         "deploy…": "deploying", "deploy✗": "deploy_red"}
for c, s in cells.items():
    assert fv.stage_of(c) == s, (c, fv.stage_of(c), s)
assert fv.stage_of("merged", "unknown") == "train"
assert fv.group_of("idle", False, False, False) == "other"
assert fv.group_of("done", False, True, False, asked=True, stage="red") == "ask"
assert fv.group_of("working", False, False, False, stage="red") == "work"
assert fv.group_of("idle", False, False, False, stage="red") == "other"      # only a done row waits
assert fv.group_of("done", False, True, True, stage="train") == "landed"     # 刚落地 unchanged
assert fv.group_of("done", True, False, False, asked=True) == "pin"
assert fv.GROUPS == ("pin", "ask", "work", "wait", "landed", "other")
PY
for l in zh en; do
  for k in view_grp_wait_fmt view_stage_checking view_stage_red view_stage_green view_stage_train view_stage_deploying view_stage_deploy_red view_ask_open; do
    v=$(FLEET_UI_LANG=$l sh "$BIN/fleet-ui-lang.sh" t "$k" 2>/dev/null)
    [ -n "$v" ] && [ "$v" != "$k" ] || fail "E: $l:$k has no words"
  done
done
pass "C  panel: 等你 (ask on an open issue, its question) · 等合并/等发版 (检查中 · 检查红 · 等发布列车) · 刚落地 · 其他 · 已结束"
pass "D  fleet ls: 在问 from the same book; E stage_of / group_of on every PR cell, words zh + en"
echo "fleet-view-todo-selftest: PASS"
