#!/bin/bash
# dash-keymap-selftest.sh — the keys the fleet still binds, held to their one table.
#
# The keymap cheatsheet (fleet-keys.sh, issue #110) and the fzf panels it
# described — the dash, the backlog, the config modal, with their ⌃-key tables
# and prefix resolver (legs 3–6, 11) — went with those panels (issue #4902). (The
# old client's own legs — 1, 2, 7, 8's client half, 10's conf half and 12 — went
# with that client, issue #3008.) What is left:
#
#  10. The switch keys (issue #1903): dash-keymap.sh --panel switch — the 看台's
#      table — its rows and codes, and the iTerm2 profile fleet-iterm-profile.py
#      writes for it (⌘P by default, FLEET_KEY_PANEL, FLEET_KEYS_EXTRA).
#
#   9. The recovery page's keys (bin/fleet-session-page.py, issue #1862): ↵ / r / q
#      always, and p (reopen without the personal layer) only when the login has
#      one — the keys row and choice() agree, and with no personal layer the row
#      is exactly the three keys it always was.
#
#   8. The node binds none of them (issue #1714, EPIC #1710 C4): a server that
#      sources conf/tmux-attention.conf lists EXACTLY tmux's stock keys in root
#      and prefix — its only keys of its own live in the 看台's tables (issue
#      #3000: fleet-view = root copied + by default ONE action, the panel —
#      User927 (⌘P) and the phone keys ⌃空格 · F12 · ⌃] p (issue #3185); a
#      FLEET_KEYS_EXTRA adds its codes, FLEET_KEY_PHONE narrows the phone's) — on
#      an isolated socket.
#
# Exit 0 = pass. Non-zero = fail (prints what diverged). No network.
set -uo pipefail
# A block is searched with `grep -q … <<< "$block"`, never `printf … | grep -q`:
# grep -q exits on its first match, and under pipefail a writer still flushing
# the rest of the block dies of SIGPIPE (141) — a spurious, timing-dependent
# FAIL that showed up on a loaded macOS runner (PR #1468). A here-string has
# no writer to kill.
export FLEET_UI_LANG=en

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$(cd "$BIN/.." && pwd)"
NODE="$ROOT/conf/tmux-attention.conf"
KEYMAP="$BIN/dash-keymap.sh"

for f in "$NODE" "$KEYMAP"; do
  [ -f "$f" ] || { printf 'selftest: missing %s\n' "$f" >&2; exit 2; }
done


# --- 8. the node binds none of a person's keys ----------------------------------
# (issue #1714, EPIC #1710 C4). Two throwaway servers on sockets of our own
# (never the fleet's): stock tmux and one that sourced the node conf. HOME is a
# scratch dir so the node conf's one-shot reap never reaches a live install.
if command -v tmux >/dev/null 2>&1; then
  KW=$(mktemp -d "${TMPDIR:-/tmp}/fkeys.XXXXXX") || st_fail "8: mktemp"
  ktm() { local s="$1"; shift; HOME="$KW" tmux -S "$KW/$s" -f /dev/null "$@"; }
  for s in stock node; do ktm "$s" new-session -d -s k -x 120 -y 30 || st_fail "8: tmux $s server did not start"; done
  ktm node source-file "$NODE" 2>"$KW/node.err" || st_fail "8: the node conf failed to source: $(cat "$KW/node.err")"
  ktm stock list-keys > "$KW/stock.keys"; ktm node list-keys > "$KW/node.keys"
  # Exactly tmux's stock keys — except the human layer (conf/tmux-node-human.conf,
  # issue #1840), which may only TAKE AWAY the stock deletes and swap the pane's
  # right-click menus for a read-only one, and drop whatever else this tmux ships
  # that deletes (its sweep): no other key differs, and no key on the node deletes
  # or respawns anything.
  HUMAN_KEYS=' prefix:x prefix:& prefix:$ prefix:< prefix:> root:MouseDown3Pane root:M-MouseDown3Pane root:MouseDown3Status root:MouseDown3StatusLeft root:MouseDown3StatusRight root:M-MouseDown3Status root:M-MouseDown3StatusLeft root:M-MouseDown3StatusRight '
  # tmux pads the key column to the longest key, so a removed key re-pads every
  # line: compare whitespace-normalised.
  # The 看台's own tables (issue #3000, conf/tmux-view.conf) are the node's only
  # keys of its own: compared apart, below — root and prefix stay tmux's.
  hk() { awk -v hk="$HUMAN_KEYS" '$3 == "fleet-view" || $3 == "fleet-view-pfx" { next } /kill-(pane|window|session|server)|respawn-(pane|window)|rename-session/ { next } { k = $3 ":" $4; gsub(/\\/, "", k); if (index(hk, " " k " ") == 0) { $1 = $1; print } }' "$1"; }
  ndiff=$(diff <(hk "$KW/stock.keys") <(hk "$KW/node.keys"))
  [ -z "$ndiff" ] || { ktm stock kill-server; ktm node kill-server; st_fail "8: the node binds keys of its own (beyond the human layer it must list exactly tmux's stock keys):
$ndiff"; }
  # fleet-view = the node's root, copied (the 看台's mouse: tmux does not fall back
  # to root for a key a session's key-table lacks), + the 看台's keys — by default
  # ONE action, the panel (issue #3185, EPIC #3178 C7): User927 (⌘P), the phone
  # keys ⌃空格 and F12, ⌃] p; ⌃] itself.
  fv_ours='$4 ~ /^User9[0-9][0-9]$/ || $4 == "C-]" || $4 == "C-\\\\" || $4 == "C-Space" || $4 == "F12"'
  fv_copy=$(awk '$3 == "fleet-view" && !('"$fv_ours"') { $3 = "root"; $1 = $1; print }' "$KW/node.keys")
  [ "$fv_copy" = "$(awk '$3 == "root" && !('"$fv_ours"') { $1 = $1; print }' "$KW/node.keys")" ] \
    || st_fail "8: the 看台's fleet-view is not a copy of the node's root: $(diff <(printf '%s\n' "$fv_copy") <(awk '$3 == "root" { $1 = $1; print }' "$KW/node.keys") | head -5)"
  # + the codes of the keys issue #3328 folded into ⌘P — ⌘↓ ⌘↑ ⌘[ ⌘] ⌘N ⌘K ⌘Q ⌘T —
  # each the panel `--forward <action>`; + ⌃\ (⌘\ sends its byte), the home shell (EPIC T651 C3)
  fv_user=$(awk '$3 == "fleet-view" && $4 ~ /^User/ { print $4 }' "$KW/node.keys" | sort | tr '\n' ' ')
  [ "$fv_user" = "User920 User921 User922 User923 User927 User928 User930 User931 User932 " ] \
    || st_fail "8: by default the 看台 binds User927 (⌘P) + the forwarded codes of #3328 — got: $fv_user"
  # ⌃\: the home shell too (a web PTY's own road first); never the panel any more
  ckey=$(awk '$3 == "fleet-view" && $4 == "C-\\\\"' "$KW/node.keys")
  case "$ckey" in *'@view_web_home'*'do shell'*'do home'*) ;; *) st_fail "8: ⌃\\ is not the home shell (web home first): $ckey" ;; esac
  case "$ckey" in *--forward*) st_fail "8: ⌃\\ still forwards to the panel: $ckey" ;; esac
  awk '$3 == "fleet-view" && $4 == "User927"' "$KW/node.keys" | grep -q -- '--forward' && st_fail "8: ⌘P itself is a forward"
  for kf in User920:next User921:prev User922:back User923:fwd User928:new User930:switcher User931:quit User932:dispatch; do
    awk -v k="${kf%%:*}" '$3 == "fleet-view" && $4 == k' "$KW/node.keys" | grep -q "dash-popup.sh.*--forward ${kf#*:} " \
      || st_fail "8: ${kf%%:*} does not open the panel as the forward of ${kf#*:}: $(awk -v k="${kf%%:*}" '$3 == "fleet-view" && $4 == k' "$KW/node.keys")"
  done
  for k in C-Space F12; do
    awk -v k="$k" '$3 == "fleet-view" && $4 == k' "$KW/node.keys" | grep -q 'dash-popup.sh' || st_fail "8: the phone key $k does not open the panel"
  done
  grep -q 'fleet-quick-dispatch' "$KW/node.keys" && st_fail "8: a 看台 key still opens the 派一件事 popup (fleet-quick-dispatch.py, gone with #3328)"
  fv_pfx=$(awk '$3 == "fleet-view-pfx" { print $4 }' "$KW/node.keys" | sort | tr '\n' ' ')
  [ "$fv_pfx" = "C-] p " ] || st_fail "8: by default ⌃] takes p and ⌃] only — got: $fv_pfx"
  # a person's extra (the client's FLEET_KEYS_EXTRA, carried by the attach): one more code
  FLEET_KEYS_EXTRA="next=cmd+down" TMUX="$KW/node,0,0" HOME="$KW" python3 "$BIN/fleet-quickopen.py" view-keys \
    || st_fail "8: view-keys with FLEET_KEYS_EXTRA exited non-zero"
  ktm node list-keys -T fleet-view | awk '$4 == "User920"' | grep -q 'do next' \
    || st_fail "8: FLEET_KEYS_EXTRA=next=cmd+down does not bind User920 to ⌘↓'s own action (not the forward): $(ktm node list-keys -T fleet-view | awk '$4 == "User920"')"
  ktm node list-keys -T fleet-view | awk '$4 == "User921"' | grep -q -- '--forward prev' || st_fail "8: an extra for ⌘↓ took ⌘↑'s forward away"
  # the phone keys are this machine's: FLEET_KEY_PHONE=f12 leaves F12 alone (and the extra stays: kept on the server)
  FLEET_KEY_PHONE=f12 TMUX="$KW/node,0,0" HOME="$KW" python3 "$BIN/fleet-quickopen.py" view-keys \
    || st_fail "8: view-keys with FLEET_KEY_PHONE exited non-zero"
  ktm node list-keys -T fleet-view | awk '$4 == "F12"' | grep -q . || st_fail "8: FLEET_KEY_PHONE=f12 dropped F12"
  ktm node list-keys -T fleet-view | awk '$4 == "C-Space"' | grep -q . && st_fail "8: FLEET_KEY_PHONE=f12 still binds ⌃空格"
  # (the whole list, filtered: tmux 3.7 prints nothing for `list-keys -T <t>` when C-] is its only key)
  [ "$(ktm node list-keys | awk '$3 == "fleet-view-pfx" { print $4 }' | tr '\n' ' ')" = "C-] " ] \
    || st_fail "8: FLEET_KEY_PHONE=f12 still binds ⌃] p: $(ktm node list-keys | awk '$3 == "fleet-view-pfx"')"
  ktm node list-keys -T fleet-view | awk '$4 == "User920"' | grep -q 'do next' || st_fail "8: a later build dropped the kept FLEET_KEYS_EXTRA (User920)"
  ktm node list-keys > "$KW/node.keys"
  awk '($3 == "fleet-view" && ($4 ~ /^User/ || $4 == "C-]" || $4 == "C-\\\\")) || $3 == "fleet-view-pfx"' "$KW/node.keys" \
    | grep -Eq 'kill-(pane|window|session|server)|respawn-(pane|window)|rename-session' && st_fail "8: a 看台 key deletes, respawns or renames"
  awk '$3 == "root" || $3 == "prefix"' "$KW/node.keys" | grep -q 'fleet-quickopen' && st_fail "8: a 看台 key leaked into root / prefix"
  if awk '$3 != "fleet-view"' "$KW/node.keys" | grep -Eq 'kill-(pane|window|session|server)|respawn-(pane|window)|rename-session'; then
    ktm stock kill-server; ktm node kill-server
    st_fail "8: a node key still deletes, respawns or renames: $(awk '$3 != "fleet-view"' "$KW/node.keys" | grep -E 'kill-|respawn-|rename-session' | awk '{print $3, $4}' | tr '\n' ' ')"
  fi
  for k in x '&' '$' '<' '>'; do
    awk -v k="$k" '$3 == "prefix" { kk = $4; gsub(/\\/, "", kk); if (kk == k) f = 1 } END { exit !f }' "$KW/node.keys" \
      && st_fail "8: the node still binds prefix $k"
  done
  grep -q 'MouseDown3Pane.*display-menu' "$KW/node.keys" || st_fail "8: the node's right-click is not the read-only menu"
  ktm node list-keys -T fleet-sidebar >/dev/null 2>&1 && ktm node list-keys -T fleet-sidebar | grep -q . \
    && st_fail "8: the node still has a fleet-sidebar key table"
  ktm node show-options -g status-right | grep -q '#(' && st_fail "8: the node's status line still runs a job"
  ktm node show-hooks -g | grep -Eq '\[(71|73)\]' && st_fail "8: the node still carries the list's [71] / hub-visit [73] hooks"
  ktm stock kill-server; ktm node kill-server
  rm -rf "$KW"
fi

# --- 10. the switch keys: the 看台's table ⇄ the iTerm2 profile (issue #1903) ---
# `dash-keymap.sh --panel switch` is the one table: fleet_view.py binds the 看台's
# keys off it, fleet-iterm-profile.py writes the ⌘ chords that send its codes.
sw_table="$(bash "$KEYMAP" --panel switch list)" || st_fail "10: dash-keymap.sh --panel switch list exited non-zero"
# `new` (⌘N / prefix c, issue #1953 → #3119): a new session — private code 928.
# `fold` (⌘. / prefix ., issue #2167): the session in view's sub-tasks — 929.
# `switcher` (⌘K / prefix s, code 930) went with issue #3185: ⌘K is iTerm2's again.
# `needs` (⌘J · 924 · prefix k) and `help` (⌘/ · 926 · prefix ?) went with issue #2362.
# `quit` (⌘Q / prefix Q, issue #2349): 退出 fleet — 931.
# `dispatch` (⌘T / prefix t, issue #2753): 派一件事 — 932.
[ "$(printf '%s\n' "$sw_table" | grep -c .)" = 11 ] || st_fail "10: the switch table is not #1903's 6 (less needs / help, #2362) + #1953's new + #2167's fold + #2349's quit + #2753's dispatch + T651 C3's home (less #2266's switcher, #3185): $sw_table"
[ "$(printf '%s\n' "$sw_table" | awk '{print $1}' | tr '\n' ' ')" = "next prev back fwd zoom quickopen new fold quit dispatch home " ] \
  || st_fail "10: the switch actions are not next prev back fwd zoom quickopen new fold quit dispatch home"
# two actions are bound by default (issue #3185; EPIC T651 C3): the panel and the home shell
[ "$(bash "$KEYMAP" --panel switch default | tr '\n' ' ')" = "quickopen home " ] || st_fail "10: the default-bound column is not quickopen + home"
# ⌘\ sends ⌃\'s byte (x1c), never a private code: tmux drops a user key while a popup is up
printf '%s\n' "$sw_table" | awk '$1 == "home" && $2 == "⌘\\" && $3 == "0x5c-0x100000" && $4 == "x1c"' | grep -q . \
  || st_fail "10: home is not ⌘\\ · 0x5c-0x100000 · the byte x1c"
[ "$(bash "$KEYMAP" --panel switch full | awk '{ print $1, $2, $3, $4, $5 }')" = "$sw_table" ] || st_fail "10: full's first five columns are not list"
printf '%s\n' "$sw_table" | awk '$1 == "dispatch" && $2 == "⌘T" && $3 == "0x74-0x100000" && $4 == 932 && $5 == "t"' | grep -q . \
  || st_fail "10: dispatch is not ⌘T · 0x74-0x100000 · code 932 · prefix t"
printf '%s\n' "$sw_table" | awk '$4 == 924 || $4 == 926 || $2 == "⌘J" || $2 == "⌘/"' | grep -q . \
  && st_fail "10: a retired code / chord is back in the switch table (924 ⌘J, 926 ⌘/ — issue #2362)"
printf '%s\n' "$sw_table" | awk '$1 == "quit" && $2 == "⌘Q" && $3 == "0x71-0x100000" && $4 == 931 && $5 == "Q"' | grep -q . \
  || st_fail "10: quit is not ⌘Q · 0x71-0x100000 · code 931 · prefix Q"
printf '%s\n' "$sw_table" | awk '$4 == 930 || $2 == "⌘K"' | grep -q . \
  && st_fail "10: ⌘K / code 930 is back in the switch table (retired with issue #3185)"
printf '%s\n' "$sw_table" | awk '$1 == "new" && $2 == "⌘N" && $4 == 928 && $5 == "c"' | grep -q . \
  || st_fail "10: new is not ⌘N · code 928 · prefix c"
printf '%s\n' "$sw_table" | awk '$1 == "fold" && $2 == "⌘." && $3 == "0x2e-0x100000" && $4 == 929 && $5 == "."' | grep -q . \
  || st_fail "10: fold is not ⌘. · 0x2e-0x100000 · code 929 · prefix ."
while read -r sa _ sk _ _; do
  [ -n "$sa" ] || continue
  case "$sk" in 0x[0-9a-f]*-0x[0-9a-f]*) ;; *) st_fail "10: $sa: '$sk' is not an iTerm2 key spec" ;; esac
  [ $(( $(printf '%d' "${sk#*-}") & 0x100000 )) -ne 0 ] || st_fail "10: $sa: '$sk' carries no ⌘"
done <<EOF
$sw_table
EOF
SW_PROF=$(mktemp -d "${TMPDIR:-/tmp}/fkeys-iterm.XXXXXX") || st_fail "10: mktemp"
# the client's profile (issue #3185, EPIC #3178 C7): ONE ⌘ chord, ⌘P, + ⇧↵ — and
# the ⌘ keys issue #3328 folded into ⌘P, at their old
# codes (the 看台 forwards them to the panel); FLEET_KEY_PANEL=off none;
# FLEET_KEYS_EXTRA adds exactly what it names (a forward of the same chord goes)
sw_map() { FLEET_ITERM_DIR="$SW_PROF" FLEET_ITERM_PREFS=/dev/null ITERM_PROFILE='' FLEET_CONF_DIR="$SW_PROF/conf" "$@" python3 "$BIN/fleet-iterm-profile.py" json \
  | python3 -c 'import json,sys; m=json.load(sys.stdin)["Profiles"][0]["Keyboard Map"]; print(" ".join("%s=%s" % (k, m[k].get("Text")) for k in sorted(m)))'; }
FWD="0x5b-0x100000=[922~ 0x5c-0x100000=0x1c 0x5d-0x100000=[923~ 0x6b-0x100000=[930~ 0x6e-0x100000=[928~"
FWD_T="0x71-0x100000=[931~ 0x74-0x100000=[932~"
FWD_A="0xf700-0x300000=[921~ 0xf701-0x300000=[920~"
[ "$(sw_map env)" = "$FWD 0x70-0x100000=[927~ $FWD_T 0xd-0x20000=0x0a $FWD_A" ] || st_fail "10: the default profile is not ⌘P + ⇧↵ + #3328's forwards: $(sw_map env)"
[ "$(sw_map env FLEET_KEY_PANEL=off)" = "0x5c-0x100000=0x1c 0xd-0x20000=0x0a" ] || st_fail "10: FLEET_KEY_PANEL=off maps more than ⌘\\ (home, not the panel): $(sw_map env FLEET_KEY_PANEL=off)"
# a person's extra on ⌘\ takes the chord from home
[ "$(sw_map env 'FLEET_KEYS_EXTRA=next=cmd+\' | tr ' ' '\n' | grep '^0x5c-')" = "0x5c-0x100000=[920~" ] \
  || st_fail "10: FLEET_KEYS_EXTRA=next=cmd+\\ did not take ⌘\\: $(sw_map env 'FLEET_KEYS_EXTRA=next=cmd+\')"
[ "$(sw_map env "FLEET_KEY_PANEL=cmd+'" 'FLEET_KEYS_EXTRA=next=cmd+down shell=ctrl+\ bogus=cmd+z')" = "0x27-0x100000=[927~ $FWD $FWD_T 0xd-0x20000=0x0a $FWD_A" ] \
  || st_fail "10: FLEET_KEY_PANEL=cmd+' + FLEET_KEYS_EXTRA=next=cmd+down is not ⌘' + ⌘↓: $(sw_map env "FLEET_KEY_PANEL=cmd+'" 'FLEET_KEYS_EXTRA=next=cmd+down shell=ctrl+\ bogus=cmd+z')"
# read from fleet.conf's [client] section when the environment has none
mkdir -p "$SW_PROF/conf"
printf '[ "${FLEET_SHELL:-0}" = 1 ] && FLEET_KEYS_EXTRA="new=cmd+n"\n' > "$SW_PROF/conf/fleet.conf"
[ "$(sw_map env -u FLEET_KEYS_EXTRA)" = "$FWD 0x70-0x100000=[927~ $FWD_T 0xd-0x20000=0x0a $FWD_A" ] || st_fail "10: FLEET_KEYS_EXTRA in fleet.conf [client] is not read: $(sw_map env -u FLEET_KEYS_EXTRA)"
python3 -c 'import json,sys; m=json.load(sys.stdin)["Profiles"][0]["Keyboard Map"]; assert "0x6a-0x100000" not in m and "0x2f-0x100000" not in m, m' \
  < <(FLEET_ITERM_DIR="$SW_PROF" FLEET_ITERM_PREFS=/dev/null ITERM_PROFILE='' python3 "$BIN/fleet-iterm-profile.py" json) \
  || st_fail "10: the profile maps ⌘J or ⌘/ (issue #2362)"
FLEET_ITERM_DIR="$SW_PROF" FLEET_ITERM_PREFS=/dev/null ITERM_PROFILE='' python3 "$BIN/fleet-iterm-profile.py" write
FLEET_ITERM_DIR="$SW_PROF" FLEET_ITERM_KEYS=0 python3 "$BIN/fleet-iterm-profile.py" write
[ -f "$SW_PROF/fleet.json" ] && st_fail "10: FLEET_ITERM_KEYS=0 left the profile in place"
rm -rf "$SW_PROF"

# (the sheet is gone, issue #4902 — fleet-keys.sh and its manifest line: conf/gone.list)

# 9 — the recovery page's keys (issue #1862)
page_out=$(python3 - "$BIN" <<'PY'
import importlib.util, os, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("page", os.path.join(sys.argv[1], "fleet-session-page.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
plain = lambda t: __import__("re").sub(r"\x1b\[[0-9;]*m", "", t)
w = m.TEXT["zh"]
errs = []
if plain(m.keys_line(w)) != "↵ 重开 · ⌘P 回列表   r 新对话 · q 关窗口": errs.append("no-layer row: %r" % plain(m.keys_line(w)))
if plain(m.keys_line(w, "off")) != plain(m.keys_line(w)): errs.append("off row differs")
if plain(m.keys_line(w, "on")) != "↵ 重开 · ⌘P 回列表   r 新对话 · q 关窗口 · p 不带个人配置重开": errs.append("on row: %r" % plain(m.keys_line(w, "on")))
# the line under the conversation (issue #2743): one line, two wordings
if plain(m.render({"rc": 0, "lang": "zh", "sid": "s"}, 80)) != "会话已结束 · ↵ 重开 · ⌘P 回列表   r 新对话 · q 关窗口": errs.append("ended line: %r" % plain(m.render({"rc": 0, "lang": "zh", "sid": "s"}, 80)))
if not plain(m.render({"rc": 137, "lang": "zh", "sid": "s"}, 80)).startswith("会话意外退出 · "): errs.append("crash line: %r" % plain(m.render({"rc": 137, "lang": "zh"}, 80)))
for ch, want, pers in (("\r", m.RESUME, False), ("r", m.NEW, False), ("q", m.QUIT, False),
                       ("p", None, False), ("p", m.PERSONAL, True)):
    if m.choice(ch, 24, pers) != want: errs.append("choice(%r, personal=%s) = %r" % (ch, pers, m.choice(ch, 24, pers)))
print("\n".join(errs) or "ok")
PY
)
[ "$page_out" = ok ] || st_fail "9: the recovery page's keys: $page_out"

printf 'selftest OK: the node binds stock keys only; the 看台 table, the iTerm2 profile and the recovery page agree\n'
