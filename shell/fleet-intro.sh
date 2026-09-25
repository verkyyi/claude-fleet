#!/bin/sh
# fleet-intro.sh — the SSH login banner: what this login's fleet holds, and how
# to get in (issue #1068). One fleet per login (#979), every repo in it equal (#788).
#
# Called straight from ~/.zshrc (see docs/INSTALL.md step 7), which owns the
# gating: interactive shells only, never inside tmux (worker panes source .zshrc
# too), and ~/.hushfleet as the opt-out. This script does no gating of its own.
#
# Cheap by design: conf files + at most 2 tmux calls (has-session, list-windows).
# No git, no gh, no network — it runs on every login.
#
#   0 fleets  → "○ 未配置 fleet" + a pointer at docs/INSTALL.md
#   2+ fleets → one warning line pointing at `fleet-repo.sh fold` (guards #979)
#   1 fleet   → header (● 运行中 · N 会话 / ○ 未启动), one row per repo (the
#               fleet's own conf first, then repos/*.conf in file order, as fleet_repos; a repo
#               with live workers shows its count), then the `cf` action line.
#
# A worker = a window carrying @issue, grouped by @repo. No tmux keys, no `cw`,
# no doc links in the banner: `Ctrl-b ?` covers those once inside the fleet.
# bin/fleet-intro-selftest.sh pins every branch above.
CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
TMUX_BIN=$(command -v tmux 2>/dev/null || echo /opt/homebrew/bin/tmux)
ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
[ -f "$ROOT/fleet.conf" ] && . "$ROOT/fleet.conf" 2>/dev/null || :
[ -f "$ROOT/bin/fleet-ui-lang.sh" ] && . "$ROOT/bin/fleet-ui-lang.sh"
TAB=$(printf '\t')
b=$(printf '\033[1m'); d=$(printf '\033[2m'); g=$(printf '\033[32m'); y=$(printf '\033[33m'); r=$(printf '\033[0m')
line="${d}────────────────────────────────────────────────────────────${r}"
me="$(id -un)@$(hostname -s 2>/dev/null || hostname)"
getkv() { sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" "$1" | head -1; }

# the login's one fleet
n=0; sess=""; conf=""
for dd in "$CONF_DIR"/fleets/*/; do
  [ -f "${dd}conf" ] || continue
  n=$((n+1)); s=${dd%/}; sess=${s##*/}; conf="${dd}conf"
done
if [ "$n" -eq 0 ]; then
  if [ "$(fleet_ui_lang)" = zh ]; then
    printf '\n%s\n %sclaude fleet%s · %-22s %s○ 未配置 fleet%s —— 见 ~/.claude/fleet/docs/INSTALL.md\n%s\n' "$line" "$b" "$r" "$me" "$y" "$r" "$line"
  else
    printf '\n%s\n %sclaude fleet%s · %-22s %s○ no fleet configured%s — see ~/.claude/fleet/docs/INSTALL.md\n%s\n' "$line" "$b" "$r" "$me" "$y" "$r" "$line"
  fi
  exit 0
fi
if [ "$n" -gt 1 ]; then
  if [ "$(fleet_ui_lang)" = zh ]; then
    printf '\n%s\n %sclaude fleet%s · %-22s %s⚠ 配置了 %s 个 fleet，只允许一个%s —— fleet-repo.sh fold\n%s\n' "$line" "$b" "$r" "$me" "$y" "$n" "$r" "$line"
  else
    printf '\n%s\n %sclaude fleet%s · %-22s %s⚠ %s fleets configured; only one is allowed%s — fleet-repo.sh fold\n%s\n' "$line" "$b" "$r" "$me" "$y" "$n" "$r" "$line"
  fi
  exit 0
fi

_ui=$(getkv "$conf" FLEET_UI_LANG); [ -n "$_ui" ] && FLEET_UI_LANG=$_ui
# repos: the fleet's own conf first, then repos/*.conf in file order, a repeat
# dropped — the same order as fleet_repos (bin/fleet-lib.sh). All equal, no main repo.
repos="$(getkv "$conf" FLEET_REPO)${TAB}$(getkv "$conf" FLEET_BASE_BRANCH)"
seen=" $(getkv "$conf" FLEET_REPO) "
for rc in "$CONF_DIR/fleets/$sess/repos"/*.conf; do
  [ -f "$rc" ] || continue
  rp=$(getkv "$rc" FLEET_REPO); [ -n "$rp" ] || continue
  case "$seen" in *" $rp "*) continue ;; esac
  seen="$seen$rp "
  repos="$repos
$rp${TAB}$(getkv "$rc" FLEET_BASE_BRANCH)"
done

# state + worker count per repo (windows carrying @issue)
running=0; total=0; counts=""
if "$TMUX_BIN" -L "$sess" has-session -t "$sess" 2>/dev/null; then
  running=1
  counts=$("$TMUX_BIN" -L "$sess" list-windows -t "$sess" -F "#{@repo}${TAB}#{@issue}" 2>/dev/null \
    | awk -F"$TAB" '$2!=""{c[$1]++; t++} END{for(k in c) print k"\t"c[k]; print "__total__\t"t+0}')
  total=$(printf '%s\n' "$counts" | awk -F"$TAB" '$1=="__total__"{print $2}')
fi

printf '\n%s\n' "$line"
if [ "$running" -eq 1 ]; then
  if [ "$(fleet_ui_lang)" = zh ]; then
    printf ' %sclaude fleet%s · %-22s %s● 运行中%s · %s 会话\n' "$b" "$r" "$me" "$g" "$r" "${total:-0}"
  else
    printf ' %sclaude fleet%s · %-22s %s● running%s · %s sessions\n' "$b" "$r" "$me" "$g" "$r" "${total:-0}"
  fi
else
  if [ "$(fleet_ui_lang)" = zh ]; then
    printf ' %sclaude fleet%s · %-22s %s○ 未启动%s\n' "$b" "$r" "$me" "$y" "$r"
  else
    printf ' %sclaude fleet%s · %-22s %s○ not started%s\n' "$b" "$r" "$me" "$y" "$r"
  fi
fi
printf '%s\n' "$line"
printf '%s\n' "$repos" | while IFS="$TAB" read -r rp rb; do
  [ -n "$rp" ] || continue
  c=""; [ "$running" -eq 1 ] && c=$(printf '%s\n' "$counts" | awk -F"$TAB" -v k="$rp" '$1==k{print $2}')
  if [ -n "$c" ] && [ "$(fleet_ui_lang)" = zh ]; then printf '   %-40s %-8s %s 会话\n' "$rp" "${rb:-master}" "$c"
  elif [ -n "$c" ]; then printf '   %-40s %-8s %s sessions\n' "$rp" "${rb:-master}" "$c"
  else printf '   %-40s %s\n' "$rp" "${rb:-master}"; fi
done
printf '\n'
if [ "$running" -eq 1 ]; then
  if [ "$(fleet_ui_lang)" = zh ]; then printf '  %scf%s     回到 fleet（已在后台跑，直接 attach）\n' "$b" "$r"
  else printf '  %scf%s     reattach to fleet\n' "$b" "$r"; fi
else
  if [ "$(fleet_ui_lang)" = zh ]; then printf '  %scf%s     启动 fleet 并进入\n' "$b" "$r"
  else printf '  %scf%s     start fleet and enter\n' "$b" "$r"; fi
fi
if [ "$(fleet_ui_lang)" = zh ]; then printf '%s\n%s(不想每次看到：touch ~/.hushfleet)%s\n' "$line" "$d" "$r"
else printf '%s\n%s(hide this banner: touch ~/.hushfleet)%s\n' "$line" "$d" "$r"; fi
