#!/bin/sh
# fleet-dist-source.sh — does this login still reach GitHub for its new versions?
# (issue #2776, EPIC #2770 C6) — the judgment behind `fleet doctor`'s `dist` row.
#
# Three ways a login still does: its ~/.claude/fleet's origin is GitHub
# (install-sync fetches stable there), FLEET_DIST_SOURCE=github (the one-version
# fallback switch), or its client install follows GitHub (a .client-version
# with an empty hub=). With a hub each is a WARN with its fix, none a PASS. With
# no hub GitHub is the only source — the developer's / own-code road: INFO, never
# a WARN. Nothing installed: nothing printed. `fleet doctor --installs` lists
# every install's 来源 (fleet-installs.sh).
#
# Prints one line `PASS|WARN|INFO<TAB><message>`, or nothing. Exit 0.
# Env: FLEET_HUB_URL (the hub; the doctor passes the one it resolved) ·
# FLEET_CONF_DIR · FLEET_LIVE_DIR (~/.claude/fleet) · FLEET_INSTALL_HOME (the
# client install, ~/.local/share/claude-fleet) · FLEET_DIST_SOURCE.
set -u
conf="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
live="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
croot="${FLEET_INSTALL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-fleet}"
hub="${FLEET_HUB_URL:-}"; hub=${hub%/}
src=${FLEET_DIST_SOURCE:-}
[ -n "$src" ] || src=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}FLEET_DIST_SOURCE[[:space:]]*=[[:space:]]*\([^#]*\).*/\2/p' \
  "$conf/fleet.conf" 2>/dev/null | tail -n 1 | tr -d "\"' 	")
[ -d "$live" ] || [ -f "$croot/.client-version" ] || exit 0
if [ -z "$hub" ]; then
  printf 'INFO\t没有入口：新版本从 GitHub 来（开发者 / 自己取代码的路，照旧）\n'
  exit 0
fi
why=''
[ "$src" = github ] && why="FLEET_DIST_SOURCE=github（一版内的回退开关）— 修：从 ${conf}/fleet.conf 删掉 FLEET_DIST_SOURCE 那一行"
origin=''
[ -d "$live" ] && origin=$(git -C "$live" remote get-url origin 2>/dev/null)
case "$origin" in
  *github.com[:/]*) why="${why:+${why}；}${live} 的 origin 是 GitHub（${origin}），install-sync 去那里取 stable — 修：bash ${live}/bin/fleet-install-sync.sh（换到从入口取的那一版起，下一拍改从入口取、去掉 origin）" ;;
esac
if grep -q '^hub=' "$croot/.client-version" 2>/dev/null && [ -z "$(sed -n 's/^hub=//p' "$croot/.client-version" | head -n 1)" ]; then
  why="${why:+${why}；}客户端跟的是 GitHub（${croot}/.client-version 没有入口）— 修：curl -fsSL ${hub}/install | sh"
fi
if [ -n "$why" ]; then
  printf 'WARN\t还在找 GitHub 拿新版本：%s\n' "$why"
else
  printf 'PASS\t新版本只从入口来（%s）\n' "$hub"
fi
