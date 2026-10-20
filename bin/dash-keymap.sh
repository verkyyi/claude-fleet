#!/bin/bash
# dash-keymap.sh — the 看台's key table (issues #1903, #3185, #3006).
#
# The fzf panels' ⌃-key tables (dash · backlog · config) and their tmux-prefix
# resolver (#556/#558) went with those panels (issue #4902). What is left is the
# one table the 看台 binds: each ⌘ chord the iTerm2 profile `fleet` sends as a
# private code, and the ⌃] letters a terminal with no ⌘ uses. It keeps its name
# so an iTerm2 profile and an older session that name it still find it.
#
# Usage (the `--panel switch` its callers spell is still accepted):
#   dash-keymap.sh [--panel switch] list|actions   # action ⌘glyph iterm-key code prefix-key
#   dash-keymap.sh [--panel switch] full|default   # + the default-bound column (#3185) ·
#                                                  #   the actions bound by default (quickopen)
#   dash-keymap.sh [--panel switch] view           # the 看台's ⌃] letters (#3006): action letter
set -uo pipefail

if [ "${1:-}" = --panel ]; then
  case "${2:-}" in switch) ;; *) echo "dash-keymap.sh: unknown panel '${2:-}' (switch — the fzf panels went with issue #4902)" >&2; exit 2 ;; esac
  shift; [ "$#" -gt 0 ] && shift
fi

# Switching sessions from anywhere in the client (issue #1903, EPIC #1906 C10).
# NOT fzf and not ⌃-chords: on the Mac each row is a ⌘ chord that the iTerm2
# Dynamic Profile `fleet` (bin/fleet-iterm-profile.py, written from THIS table)
# turns into a private code `ESC [ <code> ~` — codes no terminal sends for a real
# key — which conf/tmux-view.conf catches as `user-keys[<code>]` → `User<code>`.
# Every other terminal reaches the same action with the prefix key in the last
# column (`F9` is a root key, no prefix). Columns: action, ⌘ glyph, iTerm2 key
# (`0x<char>-0x<modifier mask>`, as iTerm2 spells its Keyboard Map: 0x100000 ⌘,
# + 0x200000 for an arrow), private code, prefix key. A tmux prefix never
# collides with a ⌘ chord, so nothing here remaps; `list` prints the table as is.
# bin/dash-keymap-selftest.sh holds it in lockstep with the conf, the sheet and
# the profile. `new` (issue #1953 → #3119 → T670): ⌘N opens the 「新会话」 box,
# both values chosen — the repo of the session in view, else the last new
# session's; that repo's last agent (fleet-quick-dispatch.py defaults()) — so ⌘N ↵
# opens a NEW session (the 看台's fleet_view.go_new) — prefix c elsewhere, tmux's
# own new-window key, which the client has no use for.
# `fold` (issue #2167): ⌘. opens or shuts the sub-tasks of the session in view
# (on a sub-task: shuts its parent) — the list's caret, from wherever the
# keyboard is; prefix . elsewhere (tmux's move-window prompt, no use here).
# `switcher` (⌘K / prefix s, code 930 — issue #2266) went with issue #3185: it
# opened ⌘P's panel since #2365, and ⌘K is iTerm2's clear-buffer. 930 is retired
# like 924 / 926 — never reuse it: a profile written before still sends it.
# `quit` (issue #2349): ⌘Q, 退出 fleet — the client's every process here goes,
# the sessions run on (fleet-shell.sh quit); prefix Q elsewhere, unbound in tmux.
# `dispatch` (issue #2753): ⌘T, 派一件事 — a title, a repo, ↵ files it and opens
# its worker (bin/fleet-quick-dispatch.py, the writing area's own payload and road);
# prefix t elsewhere (tmux's clock, no use here). Issue #3328 folded it into ⌘P's
# ⚡ row: the row stays (its code is never reused). #3328 kept ⌘↓ ⌘↑ ⌘[ ⌘] ⌘N ⌘T ⌘Q ⌘K
# as forwards to the panel; T685 gave them back to iTerm2 — an older profile's code
# for one is swallowed (bin/fleet_keys.py RETIRED).
# `needs` (⌘J / prefix k, code 924) and `help` (⌘/ / prefix ?, code 926) went
# with issue #2362: the bar's 「! N 等你」 is still a tap to the one waiting, the
# keys live in docs/dev/CLIENT.md. Their codes stay retired — never reuse 924 / 926:
# an iTerm2 profile written before still sends them (the conf swallows both).
# `home` (EPIC T651 C3): ⌘\, 回家命令行 — this machine's login shell in $HOME from
# any screen of the 看台, no session and no hub needed (fleet_view.open_home_shell).
# Its «code» is `x1c`: the profile sends ⌃\'s own byte (0x1c, «Send Hex Code»),
# not a private code — tmux (3.7c) drops a user key while a popup is up, so a code
# would never reach ⌘P's list or its 新会话 box; the byte does, and in a window it
# is the 看台's ⌃\ binding (fleet_keys.HOME_CHORD), the same key for a terminal
# with no ⌘. Since T685 it is the panel's 「回家命令行」 row; ⌘\ / ⌃\ only when named.
# The LAST column (issue #3185, EPIC #3178 C7; T685): `1` = bound by default — ONLY
# quickopen (⌘P, the panel). The 看台 takes one key (操作者 2026-10-20, T685): every
# other action is a row of ⌘P's panel (新会话 · 回家命令行 · 退出 fleet …), and every
# other row here is bound only when the person names it (fleet.conf [client]
# FLEET_KEYS_EXTRA, bin/fleet_keys.py) — ⌘\ home too. `list` prints the first five
# columns as it always did; `full` all six; `default` the default actions.
TABLE='next ⌘↓ 0xf701-0x300000 920 n -
prev ⌘↑ 0xf700-0x300000 921 p -
back ⌘[ 0x5b-0x100000 922 h -
fwd ⌘] 0x5d-0x100000 923 l -
zoom ⌘↩ 0xd-0x100000 925 F9 -
quickopen ⌘P 0x70-0x100000 927 / 1
new ⌘N 0x6e-0x100000 928 c -
fold ⌘. 0x2e-0x100000 929 . -
quit ⌘Q 0x71-0x100000 931 Q -
dispatch ⌘T 0x74-0x100000 932 t -
home ⌘\ 0x5c-0x100000 x1c \ -'
# The 看台's ⌃] letters (issue #3006, EPIC #2999 C9): a terminal with no ⌘ — a
# phone's Termius, an iPad's Blink — reaches a 看台's actions with ⌃] then ONE
# letter (fleet_view.py's `fleet-view-pfx` table). Not the prefix column above:
# that is the old client's tmux prefix row, where p is ⌘↑ and Q is shifted; a
# thumb wants p the list, n / b next and back up the list, q quit. Only the
# actions a 看台 binds get a letter; every one is a row of the table above.
# Only `p` is bound by default (fleet.conf FLEET_KEY_PHONE's `ctrl+]p` — the
# phone's ⌘P; T685 dropped ⌃空格 and F12); the rest are the letters FLEET_KEYS_PHONE_EXTRA's example spells
# (`ctrl+]n=next …`), bound only when the person writes them.
VIEW='quickopen p
next n
prev b
back h
fwd l
new c
dispatch t
quit q'
cmd="${1:-list}"
case "$cmd" in
  list)    printf '%s\n' "$TABLE" | awk '{print $1, $2, $3, $4, $5}' ;;
  full)    printf '%s\n' "$TABLE" ;;
  default) printf '%s\n' "$TABLE" | awk '$6 == 1 {print $1}' ;;
  actions) printf '%s\n' "$TABLE" | awk '{print $1}' ;;
  view)    printf '%s\n' "$VIEW" ;;
  *) echo "usage: dash-keymap.sh [--panel switch] list|full|default|actions|view" >&2; exit 2 ;;
esac
exit 0
