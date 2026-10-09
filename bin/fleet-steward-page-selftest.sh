#!/bin/bash
# fleet-steward-page-selftest.sh — the steward's page (issue #2735): what a person
# reads instead of the decision sheet's table, and the doors to it.
#
#   A  the 2026-10-09 shape (bin/fleet_steward_page.py demo_state: five drill
#      leftovers asking the same thing + one money question + one defaulted +
#      one followup): `fleet-steward-tick.sh page --demo` passes
#      epic-page-surface.sh --lint; the five merge into ONE line, the money one
#      sits under 要钱 and waits for you; every line carries 建议 + 不答就; the
#      surface has no table, no number, no file name; the phone viewport and the
#      frame's <style> are there; the defaulted one says how to overturn it
#   B  plain(): code, links, issue / member numbers and file names out,
#      implementation nouns in plain words — the result lints clean
#   C  refresh + host: the first render shares page.html ONCE with no expiry, a
#      changed page is refreshed (same URL), an unchanged one calls nothing;
#      FLEET_STEWARD_PAGE=0 writes nothing; the day's copy is kept
#   D  `say --row` replaces the worker's words on the page and in brief()
#   E  the link's road to the client: @orch_page on the orchestrator → the
#      inventory's orchpage=<url> (last tag; a bad link dropped) → orch_page →
#      orch_<sess>'s page=<url>; none ⇒ the row byte for byte
#   F  「新任务」's menu: 进管家会话 when steward_all_<sess> names one, 管家页 when
#      orch_<sess> carries page=<url> (fleet-open.sh); neither ⇒ the menu as before
#   G  the [decision] message: the page's plain lines, 〔row ids〕, the link — no table
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/steward-page.XXXXXX")
WORK=$(cd "$WORK" && pwd)   # a TMPDIR ending in / leaves a // the page's own path never has
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) ;; *) REAL_TMUX=$t; break ;; esac; done
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export FLEET_UI_LANG=zh FLEET_CONF_DIR="$WORK/conf" FLEET_STEWARD_PAGE_SHARE=0 TZ=Asia/Shanghai
export FLEET_STEWARD_STATS_CMD="cat $WORK/stats"
mkdir -p "$FLEET_CONF_DIR/global"
printf 'day\tasked\tperson\tsteward\tdefaulted\n2026-10-09\t9\t0\t0\t1\n' > "$WORK/stats"
NOW=2026-10-09T15:20:00+08:00
TICK() { python3 "$BIN/fleet_steward.py" "$@"; }

# ---- A ----------------------------------------------------------------------------
TICK page --demo --now "$NOW" --session st > "$WORK/a.html"
surf=$(bash "$BIN/epic-page-surface.sh" --lint "$WORK/a.html" 2>"$WORK/a.warn"); rc=$?
[ "$rc" = 0 ] && ok "A: the demo page lints clean" || bad "A: lint rc=$rc: $(cat "$WORK/a.warn")"
lines=$(printf '%s\n' "$surf" | grep -c '^第 [0-9]* 件')
[ "$lines" = 2 ] && printf '%s\n' "$surf" | grep -q '5 处问了同样的事' \
  && ok "A: six open questions → two lines (the five drill leftovers merged)" || bad "A: $lines lines: $surf"
printf '%s\n' "$surf" | awk '/^### 要钱/{f=1;next} /^#/{f=0} f' | grep -q '云机器.*不答就：等你（永不默认：花钱）' \
  && ok "A: the money question sits under 要钱 and waits for you" || bad "A: 要钱 group: $surf"
n=$(printf '%s\n' "$surf" | grep '^第 [0-9]* 件' | grep -c '建议：.*不答就：')
[ "$n" = 2 ] && ok "A: every line carries 建议 and 不答就" || bad "A: $n lines with both"
printf '%s\n' "$surf" | grep -q '^| ' && bad "A: a table on the surface" || ok "A: no table on the surface"
printf '%s\n' "$surf" | grep -Eq '#[0-9]|scratch-|\.sh|`' && bad "A: numbers / files upstairs: $surf" \
  || ok "A: no issue number, key or file name upstairs"
printf '%s\n' "$surf" | grep -q '要翻案，在编排会话说' && ok "A: today's default says how to overturn it" \
  || bad "A: no 翻案 line"
printf '%s\n' "$surf" | grep -q '发布到各台机器' && ok "A: 待你动手 on the same page" || bad "A: no todo"
grep -q 'name="viewport" content="width=device-width' "$WORK/a.html" && grep -q -- '--ground' "$WORK/a.html" \
  && grep -q '<details class="fold">' "$WORK/a.html" \
  && ok "A: phone viewport, the epic-page <style>, details folded" || bad "A: frame missing"
grep -q 'issues/2690#issuecomment' "$WORK/a.html" && ok "A: the source links stay in the fold" || bad "A: no source in the fold"
v=$(printf '%s\n' "$surf" | awk '/^今天问了$/{print p} {p=$0}')
[ "$v" = 9 ] && ok "A: the band reads fleet-steward-stats.sh asks (今天问了 9)" || bad "A: 今天问了 [$v]"

# ---- B ----------------------------------------------------------------------------
python3 - "$BIN" > "$WORK/b.html" <<'EOF'
import sys; sys.path.insert(0, sys.argv[1])
import fleet_steward_page as p
s = p.plain("C2 的 `fleet-stable.sh move` 要不要在 #2701 合并后跑？worker 说 hook 会挂（见 bin/x.py 和 https://e.x/a）")
assert "`" not in s and "#2701" not in s and "C2" not in s and "x.py" not in s and "https" not in s, s
assert "执行会话" in s and "自动规则" in s, s
print("<html><body><section id=\"signoff\"><p>%s</p></section></body></html>" % p.esc(s))
EOF
[ $? = 0 ] && bash "$BIN/epic-page-surface.sh" --lint "$WORK/b.html" >/dev/null 2>"$WORK/b.warn" \
  && ok "B: plain() takes out code, links, numbers, files; jargon in plain words — lint clean" \
  || bad "B: $(cat "$WORK/b.html") $(cat "$WORK/b.warn")"

# ---- C ----------------------------------------------------------------------------
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/share.log"\n[ "$1" = --refresh ] && exit 0\nprintf "READY https://mini.tail.ts.net/d/abc123/\\nINDEX x\\n"\n' "$WORK" > "$WORK/share"
chmod +x "$WORK/share"
python3 - "$BIN" "$WORK" "$NOW" <<'EOF' > "$WORK/c.out" 2>&1
import os, sys; sys.path.insert(0, sys.argv[1])
os.environ["FLEET_STEWARD_PAGE_SHARE"] = sys.argv[2] + "/share"
import fleet_steward_page as p, fleet_decision as fd
now = fd.now_local(sys.argv[3])
st = p.demo_state(now)
u1 = p.refresh("st", st, now)
u2 = p.refresh("st", st, now)                  # unchanged → no share call
next(iter(st.d["rows"].values()))["state"] = "answered"
u3 = p.refresh("st", st, now)                  # changed → --refresh, same URL
print(u1, u2, u3)
os.environ["FLEET_STEWARD_PAGE"] = "0"
print(repr(p.refresh("off", st, now)))
EOF
read -r u1 u2 u3 < "$WORK/c.out"
calls=$(cat "$WORK/share.log" 2>/dev/null)
d="$FLEET_CONF_DIR/fleets/st/steward"
[ "$u1" = https://mini.tail.ts.net/d/abc123/ ] && [ "$u2" = "$u1" ] && [ "$u3" = "$u1" ] \
  && [ "$(printf '%s\n' "$calls" | grep -c .)" = 2 ] && [ "$(printf '%s\n' "$calls" | sed -n 1p)" = "--ttl 0 $d/page.html" ] \
  && [ "$(printf '%s\n' "$calls" | sed -n 2p)" = --refresh ] \
  && ok "C: shared once (no expiry), refreshed on change, nothing when unchanged — one URL" \
  || bad "C: urls [$u1|$u2|$u3] calls [$calls] d=[$d] n=[$(printf "%s\n" "$calls" | grep -c .)]"
[ -s "$d/page.html" ] && [ -s "$d/page-2026-10-09.html" ] && ok "C: page.html + the day's copy kept" \
  || bad "C: files: $(ls "$d" 2>&1)"
grep -q "^''$" "$WORK/c.out" && [ ! -e "$FLEET_CONF_DIR/fleets/off" ] && ok "C: FLEET_STEWARD_PAGE=0 writes nothing" \
  || bad "C: page off: $(cat "$WORK/c.out")"

# ---- D / G --------------------------------------------------------------------------
python3 - "$BIN" "$NOW" <<'EOF' > "$WORK/d.out" 2>&1 && ok "D: say replaces the worker's words, on the page and in brief()" || bad "D: $(cat "$WORK/d.out")"
import sys; sys.path.insert(0, sys.argv[1])
import fleet_steward_page as p, fleet_decision as fd
now = fd.now_local(sys.argv[2])
st = p.demo_state(now)
st.d["rows"]["demo-money"]["say"] = "要不要花钱租一台机器做测试？"
lines = p.brief(p.open_rows(st), now)
assert any("要不要花钱租一台机器做测试？" in t and ids == ["demo-money"] for t, ids in lines), lines
assert "要不要花钱租一台机器做测试？" in p.render(st, "st", now, {"asked": 0, "person": 0, "defaulted": 0, "parked": 0, "todo": 0})
EOF
grep -q '〔row %s〕' "$BIN/fleet_steward.py" && ! grep -q 'tr("steward_decision_head_fmt", len(rows), where), "", table' "$BIN/fleet_steward.py" \
  && ok "G: [decision] carries the page's plain lines and 〔row ids〕, not the table" || bad "G: post_sheet still sends the table"

# ---- E ----------------------------------------------------------------------------
if [ -n "$REAL_TMUX" ]; then
  jt="$WORK/jt"; js="stp$$"; mkdir -p "$jt" "$WORK/jconf/fleets/$js"
  printf 'FLEET_REPO=o/r\n' > "$WORK/jconf/fleets/$js/conf"
  jq() { TMUX_TMPDIR="$jt" "$REAL_TMUX" -L "$js" "$@"; }
  jq -f /dev/null new-session -d -s "$js" -n home 'sleep 600'
  jq new-window -d -t "=$js:" -n orchestrator 'sleep 600'
  jq set-option -w -t "=$js:orchestrator" @fleet_role orchestrator
  jq set-option -w -t "=$js:orchestrator" @norepo 1
  jinv() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$jt" TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/jconf" \
             bash "$BIN/fleet-control-read.sh" workers "$js" 2>/dev/null | awk -F'\t' '$10 == "orchestrator"'; }
  plain=$(jinv)
  jq set-option -w -t "=$js:orchestrator" @orch_park 1
  jq set-option -w -t "=$js:orchestrator" @orch_page 'https://mini.tail.ts.net:8443/d/abc123/'
  both=$(jinv)
  jq set-option -w -t "=$js:orchestrator" @orch_page "https://evil.example/x'; rm -rf ~"
  badurl=$(jinv)
  jq kill-server 2>/dev/null
  jrow() { printf '%s' "$1" | python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from fleet_hub_common import inventory_row; r = inventory_row(sys.stdin.read().rstrip("\n").split("\t")); r = r[1] if r else {}; print(r.get("orch_park", "-"), r.get("orch_page", "-"))' "$BIN"; }
  case "$plain" in *orchpage=*) bad "E: no page, yet the inventory carries orchpage: [$plain]" ;; *)
    [ -n "$plain" ] && [ "$both" = "$plain"$'\t'"orchpark=1"$'\t'"orchpage=https://mini.tail.ts.net:8443/d/abc123/" ] \
      && [ "$(jrow "$both")" = "1 https://mini.tail.ts.net:8443/d/abc123/" ] \
      && [ "$badurl" = "$plain"$'\t'"orchpark=1" ] \
      && ok "E: @orch_page → orchpage=<url> (the last tag) → orch_page; a bad link is dropped; none ⇒ as before" \
      || bad "E: plain [$plain] both [$both] → $(jrow "$both"); bad [$badurl]" ;; esac
else
  ok "E: (no tmux here — the inventory leg skipped)"
fi
grep -q '"page=" + r\["page"\]' "$BIN/fleet-hub-sessions.sh" && ok "E: page=<url> rides orch_<sess>" \
  || bad "E: hub-sessions does not carry page"

# ---- F ----------------------------------------------------------------------------
G="$WORK/status"; mkdir -p "$G"
pmenu() { FLEET_SHELL=1 FLEET_STATUS_G="$G" bash -c 'BIN=$1; sess=$2; verb=menu; set -- menu "$2" new --print
  . "$BIN/fleet-lib.sh"; . "$BIN/fleet-ui-lang.sh"; . "$BIN/fleet-sidebar-menu.sh"' _ "$BIN" fsp 2>/dev/null; }
before=$(pmenu)
printf 'U/orch\x1fm4\x1fonline\x1fdone\x1f\x1f\x1f\x1fdecide=2\x1fpage=https://mini.tail.ts.net/d/abc123/\n' > "$G/orch_fsp"
printf 'U/stew\n' > "$G/steward_all_fsp"
after=$(pmenu)
printf '%s\n' "$after" | grep -q $'^u\t进管家会话\t.*fleet-compose.py.*--steward.*fsp' \
  && printf '%s\n' "$after" | grep -q $'^j\t管家页\t.*fleet-open.sh.*https://mini.tail.ts.net/d/abc123/' \
  && ok "F: 「新任务」's menu: 进管家会话 (--steward) and 管家页 (fleet-open.sh <url>)" || bad "F: menu: $after"
printf '%s\n' "$before" | grep -Eq $'^(u|j)\t' && bad "F: steward items with no steward: $before" \
  || ok "F: no steward, no page ⇒ neither item"
grep -q '("steward", "enter")' "$BIN/fleet-quickopen.py" && grep -q '("stewardpage", "enter")' "$BIN/fleet-quickopen.py" \
  && ok "F: both are in the command table (⌘P >)" || bad "F: not in fleet-quickopen.py COMMANDS"

[ "$fails" = 0 ] && { echo "fleet-steward-page selftest PASS"; exit 0; }
echo "fleet-steward-page selftest: $fails FAILED"; exit 1
