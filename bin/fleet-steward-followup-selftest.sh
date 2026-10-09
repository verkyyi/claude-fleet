#!/bin/bash
# fleet-steward-followup-selftest.sh — the 「待你动手」 list (issue #2672, EPIC
# #2668 C4): bin/fleet_followup.py (the marker, the harvest, the runs, the desk
# ticket) on the steward's beat (bin/fleet_steward.py → fleet-steward-tick.sh),
# fleet-steward-stats.sh followups, fleet-ticket.sh edit, and the open count's
# road to the client (fleet-control-read.sh `orchtodo=` → fleet_hub_common
# inventory_row → fleet-hub-sessions.sh `todo=N` → fleet-sidebar.py).
#
# GitHub, fleet-stable.sh, the desk ticket and the epic hold are seams: GitHub is
# a directory of JSON files, the move a counter that exits as told.
#
#   K  three batches each leave a stable followup: ONE row, `move` runs ONCE,
#      ticked on ONE desk ticket, written back on all three parents; another beat
#      runs nothing more
#   L  a gate is red: the move is refused → not done, ONE decision row (and the
#      model woken once); more beats neither rerun it nor add a row; the steward
#      may not answer it; the person's 「重跑」 runs it again
#   M  hub-deploy: a never-defaulted row; beats past any deadline never run it;
#      the person's 「部署」 runs FLEET_STEWARD_HUB_DEPLOY_CMD once
#   N  an old closing comment (no marker): `fleet-stable.sh move <sha>` is read as
#      a stable followup (compat-1v); 「挪稳定版：不需要」 is nothing
#   O  a batch holds the install: the move waits; released ⇒ it runs
#   P  nothing met: a beat writes no todo, files no ticket, stamps nothing
#   Q  the person ticks a human row on the desk ticket ⇒ done, written back
#   R  fleet-steward-stats.sh followups: done-not-live 0 for listed / run batches,
#      1 for a closed batch the steward never met (--epics)
#   S  the open count travels: orchtodo=N → orch_todo → `todo=N`; none ⇒ the
#      inventory row byte for byte
#   T  fleet_followup.py mark / parse round-trip; fleet-ticket.sh edit replaces a
#      body through fleet_gh_write
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/followup-st.XXXXXX")
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) ;; *) REAL_TMUX=$t; break ;; esac; done
trap 'rm -rf "$WORK"' EXIT

export FLEET_UI_LANG=zh FLEET_DECISION_TZ=UTC FLEET_SKIP_GLOBAL_CONF=1 FLEET_STEWARD=1 FLEET_STEWARD_FOLLOWUP_SYNC=1
mkdir -p "$WORK/bin"

# --- the seams -------------------------------------------------------------------
cat > "$WORK/bin/gh-comments" <<'EOF'
#!/bin/sh
f="$ST_GH/$(printf '%s' "$1" | tr / -)-$2.json"
[ -f "$f" ] && cat "$f" || printf '{"comments":[]}\n'
EOF
cat > "$WORK/bin/gh-post" <<'EOF'
#!/usr/bin/env python3
import json, os, sys, time
repo, n, mode = sys.argv[1:4]
body = sys.stdin.read()
f = os.path.join(os.environ["ST_GH"], "%s-%s.json" % (repo.replace("/", "-"), n))
d = json.load(open(f)) if os.path.exists(f) else {"comments": []}
k = len(d["comments"]) + 1
d["comments"].append({"body": body, "url": "https://github.com/%s/issues/%s#issuecomment-%d" % (repo, n, 900 + k),
                      "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
json.dump(d, open(f, "w"))
open(os.path.join(os.environ["ST_GH"], "posts.log"), "a").write("%s#%s %s\n" % (repo, n, mode))
EOF
cat > "$WORK/bin/issue" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
repo, n = sys.argv[1:3]
g = os.environ["ST_GH"]
f = os.path.join(g, "%s-%s.json" % (repo.replace("/", "-"), n))
d = json.load(open(f)) if os.path.exists(f) else {"comments": []}
st = os.path.join(g, "state-%s" % n)
d["state"] = open(st).read().strip() if os.path.exists(st) else "OPEN"
print(json.dumps(d))
EOF
cat > "$WORK/bin/stable" <<'EOF'
#!/bin/sh
echo run >> "$ST_GH/moves"
rc=$(cat "$ST_GH/move-rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] && echo "moved stable" || echo "fleet-stable: REFUSED — macos: the newest macOS run is failure" >&2
exit "$rc"
EOF
cat > "$WORK/bin/deploy" <<'EOF'
#!/bin/sh
echo run >> "$ST_GH/deploys"
EOF
cat > "$WORK/bin/ticket" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ST_GH/tickets.log"
case "$1" in
  new)  while [ "$#" -gt 0 ]; do [ "$1" = --body ] && printf '%s' "$2" > "$ST_GH/desk.md"; shift; done
        printf 'gh:o/r#900\thttps://github.com/o/r/issues/900\n' ;;
  edit) cat > "$ST_GH/desk.md"; echo edited ;;
  read) python3 -c 'import json,sys; print(json.dumps({"body": open(sys.argv[1]).read()}))' "$ST_GH/desk.md" ;;
esac
EOF
printf '#!/bin/sh\n[ -f "$ST_GH/hold" ]\n' > "$WORK/bin/hold"
printf '#!/bin/sh\n{ printf ">>> %%s\\n" "$1"; cat; printf "\\n"; } >> "$ST_GH/sends.log"\n' > "$WORK/bin/send"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" > "$ST_GH/todo"\n' > "$WORK/bin/stamp-todo"
printf '#!/bin/sh\n:\n' > "$WORK/bin/noop"
printf '#!/bin/sh\nprintf "{\\"seq\\": 0, \\"children\\": []}\\n"\n' > "$WORK/bin/children"
chmod +x "$WORK/bin/"*
export FLEET_DECISION_COMMENTS_CMD="$WORK/bin/gh-comments" FLEET_DECISION_POST_CMD="$WORK/bin/gh-post" \
  FLEET_DECISION_PARENT_CMD="$WORK/bin/noop" FLEET_STEWARD_WINDOWS_CMD="$WORK/bin/noop" \
  FLEET_STEWARD_CHILDREN_CMD="$WORK/bin/children" FLEET_STEWARD_SEND_CMD="$WORK/bin/send" \
  FLEET_STEWARD_STAMP_CMD="$WORK/bin/noop" FLEET_STEWARD_STAMP_TODO_CMD="$WORK/bin/stamp-todo" \
  FLEET_STEWARD_ISSUE_CMD="$WORK/bin/issue" FLEET_STEWARD_STABLE_CMD="$WORK/bin/stable" \
  FLEET_STEWARD_TICKET_CMD="$WORK/bin/ticket" FLEET_STEWARD_HOLD_CMD="$WORK/bin/hold"

# fresh <leg> — a clean conf dir and GitHub for one leg
fresh() {
  export FLEET_CONF_DIR="$WORK/$1/conf" ST_GH="$WORK/$1/gh"
  mkdir -p "$FLEET_CONF_DIR/fleets/st/repos" "$ST_GH"
  printf 'FLEET_REPO="o/r"\n' > "$FLEET_CONF_DIR/fleets/st/repos/o-r.conf"
  STATE="$FLEET_CONF_DIR/global/steward.state.json"
}
TICK() { python3 "$BIN/fleet_steward.py" "$@" --session st; }
# closed <N> <comment body> — a closed EPIC o/r#N whose closing comment says it
closed() {
  printf '%s' "$2" | "$WORK/bin/gh-post" o/r "$1" note
  echo CLOSED > "$ST_GH/state-$1"
  TICK followups --watch "o/r#$1" >/dev/null
}
mk() { python3 "$BIN/fleet_followup.py" mark "$@"; }
cnt() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
items() { python3 -c 'import json,sys; t=json.load(open(sys.argv[1])).get("todo") or {}; print(len(t.get("items") or {}))' "$STATE"; }
item() { python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["todo"]; i=t["items"][sys.argv[2]]; print(i.get(sys.argv[3], ""))' "$STATE" "$1" "$2"; }
frows() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for r in d["rows"].values() if r.get("followup") and r["state"] == "open"))' "$STATE"; }
frow() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([k for k,r in d["rows"].items() if r.get("followup") and r["state"] == "open"][0])' "$STATE"; }

# K — three batches, one stable row, one move
fresh K
closed 201 "收尾 $(mk --kind stable --what '挪稳定版到 aaa1111')"
closed 202 "收尾 $(mk --kind stable --what '挪稳定版到 bbb2222')"
closed 203 "收尾 $(mk --kind stable --what '挪稳定版到 ccc3333')"
TICK beat --force >"$WORK/out" 2>&1
[ "$(items)" = 1 ] && [ "$(cnt "$ST_GH/moves")" = 1 ] && [ "$(item fu-1 state)" = "done" ] && [ "$(item fu-1 by)" = steward ] \
  && ok "K: three stable followups → ONE row, move ran ONCE, done by the steward" \
  || bad "K: items=$(items) moves=$(cnt "$ST_GH/moves") state=$(item fu-1 state) / $(cat "$WORK/out")"
nw=0; for n in 201 202 203; do grep -q 'fleet:followup-done id=fu-1' "$ST_GH/o-r-$n.json" && nw=$((nw + 1)); done
[ "$nw" = 3 ] && ok "K: written back on all three parents (a note each)" || bad "K: written back on $nw parents"
[ "$(grep -c '^new ' "$ST_GH/tickets.log")" = 1 ] && grep -q '^- \[x\] .*<!-- fleet:todo id=fu-1 -->' "$ST_GH/desk.md" \
  && grep -q 'o/r#201、o/r#202、o/r#203' "$ST_GH/desk.md" && [ "$(cat "$ST_GH/todo")" = 0 ] \
  && ok "K: ONE desk ticket 待你动手, the row ticked with its three batches; open count 0" \
  || bad "K: tickets: $(cat "$ST_GH/tickets.log") / desk: $(cat "$ST_GH/desk.md" 2>/dev/null)"
grep -q '待你动手 0 件 · 管家已跑 1 件' "$WORK/out" && ok "K: the card says 待你动手 0 · 管家已跑 1" || bad "K: card: $(cat "$WORK/out")"
TICK beat --force >/dev/null 2>&1; TICK beat --force >/dev/null 2>&1
[ "$(cnt "$ST_GH/moves")" = 1 ] && [ "$(grep -c '^new ' "$ST_GH/tickets.log")" = 1 ] && [ "$(items)" = 1 ] \
  && ok "K: two more beats — nothing runs again, no second ticket, no second row" \
  || bad "K: later beats: moves=$(cnt "$ST_GH/moves") items=$(items)"

# L — a red gate
fresh L
echo 3 > "$ST_GH/move-rc"
closed 301 "$(mk --kind stable --what '挪稳定版')"
closed 302 "$(mk --kind stable --what '挪稳定版')"
TICK beat --force >/dev/null 2>&1
[ "$(cnt "$ST_GH/moves")" = 1 ] && [ "$(item fu-1 state)" = refused ] && [ "$(frows)" = 1 ] \
  && grep -q '发布检查没过' "$STATE" && [ "$(grep -c '^>>> steward' "$ST_GH/sends.log")" = 1 ] \
  && ok "L: gate red → refused, not done; ONE decision row; the model woken once" \
  || bad "L: moves=$(cnt "$ST_GH/moves") state=$(item fu-1 state) rows=$(frows)"
TICK beat --force >/dev/null 2>&1; TICK beat --force >/dev/null 2>&1
[ "$(cnt "$ST_GH/moves")" = 1 ] && [ "$(frows)" = 1 ] && [ "$(grep -c '^>>> steward' "$ST_GH/sends.log")" = 1 ] \
  && ok "L: more beats — no rerun, still one row, no second wake" || bad "L: moves=$(cnt "$ST_GH/moves") rows=$(frows)"
r=$(frow)
TICK answer --row "$r" --text 重跑 >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 1 ] && grep -q 'only a person' "$WORK/err" && ok "L: the steward may not answer a followup row" || bad "L: steward answer rc=$rc"
echo 0 > "$ST_GH/move-rc"
TICK answer --row "$r" --text 重跑 --by person >/dev/null
grep -q 'o/r#301 note' "$ST_GH/posts.log" && ok "L: the person's answer is a note on the parent (no worker there)" \
  || bad "L: posts: $(cat "$ST_GH/posts.log")"
TICK beat --force >/dev/null 2>&1
[ "$(cnt "$ST_GH/moves")" = 2 ] && [ "$(item fu-1 state)" = "done" ] && [ "$(frows)" = 0 ] \
  && ok "L: 「重跑」 → the next beat runs it again, done, the row closed" \
  || bad "L: after 重跑 moves=$(cnt "$ST_GH/moves") state=$(item fu-1 state) rows=$(frows)"

# M — hub-deploy waits for a nod, always
fresh M
export FLEET_STEWARD_HUB_DEPLOY_CMD="$WORK/bin/deploy"
closed 401 "$(mk --kind hub-deploy --what '重部署入口')"
closed 402 "$(mk --kind hub-deploy --what '重部署入口（C8）')"
TICK beat --force >/dev/null 2>&1
TICK beat --force --now 2099-01-01T12:00:00Z >/dev/null 2>&1
TICK beat --force --now 2099-02-01T12:00:00Z >/dev/null 2>&1
k=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([r["kind"] for r in d["rows"].values() if r.get("followup")])' "$STATE")
[ "$(cnt "$ST_GH/deploys")" = 0 ] && [ "$(items)" = 1 ] && [ "$(frows)" = 1 ] && [ "$k" = "['never:publish']" ] \
  && [ "$(item fu-1 state)" = nod ] \
  && ok "M: two hub-deploy followups → ONE never-defaulted row; beats a century on never run it" \
  || bad "M: deploys=$(cnt "$ST_GH/deploys") items=$(items) rows=$(frows) kind=$k state=$(item fu-1 state)"
TICK answer --row "$(frow)" --text 部署 --by person >/dev/null
TICK beat --force >/dev/null 2>&1; TICK beat --force >/dev/null 2>&1
[ "$(cnt "$ST_GH/deploys")" = 1 ] && [ "$(item fu-1 state)" = "done" ] \
  && ok "M: the person's 「部署」 → FLEET_STEWARD_HUB_DEPLOY_CMD runs once, done" \
  || bad "M: deploys=$(cnt "$ST_GH/deploys") state=$(item fu-1 state)"
unset FLEET_STEWARD_HUB_DEPLOY_CMD

# N — the old words, one version
fresh N
closed 501 '| 稳定版还停在 d8eb7b92，落后本批 1 个提交 | 挪稳定版到 037cda6b：`~/.claude/fleet/bin/fleet-stable.sh move 037cda6b` |'
closed 502 '挪稳定版：不需要（stable=bfab983d 已含本批最后一个合并）。'
TICK beat --force >/dev/null 2>&1
[ "$(items)" = 1 ] && [ "$(cnt "$ST_GH/moves")" = 1 ] && [ "$(item fu-1 what)" = '挪稳定版 037cda6b' ] \
  && [ "$(item fu-1 legacy)" = True ] \
  && ok "N: an old closing comment's \`fleet-stable.sh move <sha>\` → a stable row (compat-1v); 不需要 → nothing" \
  || bad "N: items=$(items) moves=$(cnt "$ST_GH/moves") what=$(item fu-1 what)"

# O — a batch holds the install
fresh O
: > "$ST_GH/hold"
closed 601 "$(mk --kind stable --what '挪稳定版')"
TICK beat --force >/dev/null 2>&1
[ "$(cnt "$ST_GH/moves")" = 0 ] && [ "$(item fu-1 state)" = pending ] && [ "$(item fu-1 note)" = '有批次在跑，等它结束' ] \
  && ok "O: a batch holds the install — the move waits (等它结束)" || bad "O: moves=$(cnt "$ST_GH/moves") note=$(item fu-1 note)"
rm -f "$ST_GH/hold"
TICK beat --force >/dev/null 2>&1
[ "$(cnt "$ST_GH/moves")" = 1 ] && [ "$(item fu-1 state)" = "done" ] && ok "O: released — it runs" || bad "O: moves=$(cnt "$ST_GH/moves")"

# P — nothing met
fresh P
TICK beat --force >/dev/null 2>&1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit("todo" in d)' "$STATE" \
  && [ ! -e "$ST_GH/tickets.log" ] && [ ! -e "$ST_GH/todo" ] \
  && ok "P: nothing met — no todo in the state, no ticket, nothing stamped" || bad "P: something was written"
rm -f "$STATE"
FLEET_STEWARD=0 python3 "$BIN/fleet_steward.py" beat --session st >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ ! -e "$STATE" ] && ok "P: FLEET_STEWARD=0 — the beat is a no-op (rc 3)" || bad "P: off rc=$rc"

# Q — the person ticks a human row
fresh Q
closed 701 "$(mk --kind human --what 'iPad 上真环境走一遍' --due 2026-10-12)"
TICK beat --force >/dev/null 2>&1
grep -q '^- \[ \] .*iPad 上真环境走一遍.*截止 2026-10-12.*<!-- fleet:todo id=fu-1 -->' "$ST_GH/desk.md" && [ "$(cat "$ST_GH/todo")" = 1 ] \
  && ok "Q: a human row is listed with its due date; open count 1" || bad "Q: desk: $(cat "$ST_GH/desk.md" 2>/dev/null)"
sed -i.bak 's/^- \[ \] /- [x] /' "$ST_GH/desk.md"
TICK beat --force >/dev/null 2>&1
[ "$(item fu-1 state)" = "done" ] && [ "$(item fu-1 by)" = person ] && grep -q 'fleet:followup-done id=fu-1' "$ST_GH/o-r-701.json" \
  && [ "$(cat "$ST_GH/todo")" = 0 ] \
  && ok "Q: ticked on the ticket → done by the person, written back, open count 0" \
  || bad "Q: state=$(item fu-1 state) by=$(item fu-1 by)"

# R — the metric
FLEET_CONF_DIR="$WORK/K/conf" ST_GH="$WORK/K/gh" bash "$BIN/fleet-steward-stats.sh" followups >"$WORK/out" 2>&1
grep -q '^done-not-live	0' "$WORK/out" && grep -q '^o/r#202	yes	1	1	0' "$WORK/out" \
  && ok "R: followups — the three run batches, done-not-live 0" || bad "R: $(cat "$WORK/out")"
mkdir -p "$WORK/R/bin"
printf '#!/bin/sh\ncat "%s/R/issue.json"\n' "$WORK" > "$WORK/R/bin/fleet-gh.sh"
cat > "$WORK/R/issue.json" <<'JSON'
{"state":"CLOSED","comments":[{"body":"挪稳定版到 abc：`fleet-stable.sh move abcdef1`","url":"u"}]}
JSON
# the stats script reads fleet-gh.sh beside it: a sandbox bin with the real script + the fake reader
cp "$BIN/fleet-steward-stats.sh" "$BIN/fleet_followup.py" "$WORK/R/bin/"
FLEET_CONF_DIR="$WORK/K/conf" bash "$WORK/R/bin/fleet-steward-stats.sh" followups --epics o/r#999 >"$WORK/out" 2>&1
grep -q '^done-not-live	1' "$WORK/out" && grep -q '^o/r#999	yes	1	0	0' "$WORK/out" \
  && ok "R: --epics: a closed batch the steward never met, with a followup → done-not-live 1" || bad "R: $(cat "$WORK/out")"

# S — the open count's road to the client
if [ -n "$REAL_TMUX" ]; then
  jt="$WORK/jt"; js="stf$$"; mkdir -p "$jt" "$WORK/jconf/fleets/$js"
  printf 'FLEET_REPO=o/r\n' > "$WORK/jconf/fleets/$js/conf"
  jq() { TMUX_TMPDIR="$jt" "$REAL_TMUX" -L "$js" "$@"; }
  jq -f /dev/null new-session -d -s "$js" -n home 'sleep 600'
  jq new-window -d -t "=$js:" -n orchestrator 'sleep 600'
  jq set-option -w -t "=$js:orchestrator" @fleet_role orchestrator
  jq set-option -w -t "=$js:orchestrator" @norepo 1
  jinv() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$jt" TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/jconf" \
             bash "$BIN/fleet-control-read.sh" workers "$js" 2>/dev/null | awk -F'\t' '$10 == "orchestrator"'; }
  plain=$(jinv)
  jq set-option -w -t "=$js:orchestrator" @orch_todo 3
  only=$(jinv)
  jq set-option -w -t "=$js:orchestrator" @orch_decide 2
  both=$(jinv)
  jq kill-server 2>/dev/null
  rd() { printf '%s' "$1" | python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from fleet_hub_common import inventory_row; r = inventory_row(sys.stdin.read().rstrip("\n").split("\t")); r = r[1] if r else {}; print("%s/%s" % (r.get("orch_decide", ""), r.get("orch_todo", "")))' "$BIN"; }
  case "$plain" in *orchtodo=*) bad "S: no list, yet the inventory carries orchtodo: [$plain]" ;; *)
    [ -n "$plain" ] && [ "$only" = "$plain"$'\t'"orchtodo=3" ] && [ "$both" = "$plain"$'\t'"orchdec=2"$'\t'"orchtodo=3" ] \
      && [ "$(rd "$only")" = /3 ] && [ "$(rd "$both")" = 2/3 ] \
      && ok "S: @orch_todo 3 → orchtodo=3 (after orchdec=) → orch_todo 3; none ⇒ the row byte for byte" \
      || bad "S: inventory [$only] / [$both] (plain [$plain]) → $(rd "$only") $(rd "$both")" ;; esac
else
  echo "SKIP  S: no tmux"
fi
grep -q '"todo=" + r\["todo"\]' "$BIN/fleet-hub-sessions.sh" && grep -q '("todo", "☐", "sidebar_steward_todo_fmt")' "$BIN/fleet-sidebar.py" \
  && ok "S: todo=N rides orch_<sess>; the sidebar draws 待你动手 N from it" || bad "S: hub-sessions / sidebar do not carry todo"

# T — the marker, and fleet-ticket.sh edit
m=$(mk --kind human --what 'a --> b   c' --due 2026-10-12)
p=$(python3 -c 'import json,sys; print(json.dumps({"comments":[{"body":"x\n"+sys.argv[1],"url":"u"}]}))' "$m" \
    | python3 "$BIN/fleet_followup.py" parse --comments-json -)
case "$p" in *'"kind": "human"'*'"what": "a —> b c"'*'"due": "2026-10-12"'*) ok "T: mark → parse round-trips (no --> inside, spaces folded)" ;;
  *) bad "T: mark [$m] parsed [$p]" ;; esac
python3 "$BIN/fleet_followup.py" mark --kind deploy --what x >/dev/null 2>&1 && bad "T: an unknown kind was accepted" \
  || ok "T: an unknown kind is refused"
mkdir -p "$WORK/T/bin"
cat > "$WORK/T/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/T/gh.log"
while [ "\$#" -gt 0 ]; do [ "\$1" = --body-file ] && cat "\$2" > "$WORK/T/body"; shift; done
EOF
chmod +x "$WORK/T/bin/gh"
printf 'new body\n- [ ] x\n' | PATH="$WORK/T/bin:$PATH" FLEET_CONF_DIR="$WORK/T/conf" bash "$BIN/fleet-ticket.sh" edit 'gh:o/r#900' --body-file - >"$WORK/out" 2>&1
grep -q '^issue edit 900 --repo o/r --body-file' "$WORK/T/gh.log" && grep -q '^- \[ \] x' "$WORK/T/body" && grep -q edited "$WORK/out" \
  && ok "T: fleet-ticket.sh edit replaces the body (gh issue edit --body-file, through fleet_gh_write)" \
  || bad "T: edit: $(cat "$WORK/out") / $(cat "$WORK/T/gh.log" 2>/dev/null)"

[ "$fails" = 0 ] && { echo "fleet-steward-followup selftest PASS"; exit 0; }
echo "fleet-steward-followup selftest: $fails FAILED"; exit 1
