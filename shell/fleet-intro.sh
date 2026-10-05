#!/bin/sh
# fleet-intro.sh — the SSH login banner: this login's fleet and how to get in
# (issues #1068, #1255). One fleet per login (#979), every repo in it equal (#788).
#
# Called straight from ~/.zshrc (see docs/INSTALL.md step 7), which owns the
# gating: interactive shells only, never inside tmux (worker panes source .zshrc
# too), and ~/.hushfleet as the opt-out. This script does no gating of its own.
#
# Phone-width (#1255): every line ≤ 40 terminal columns (CJK = 2), no rules, no
# host, no repo names. Conf files only — NO tmux calls, no git, no gh, no
# network: it runs on every login, and `fleet` opens the client either way, so a
# running and a stopped fleet print the same banner. The way in is `fleet` alone
# (issue #1711, EPIC #1710 C1) — `cf` is folded into it.
#
#   0 fleets  → "○ 未配置" + a pointer at docs/INSTALL.md
#   2+ fleets → "⚠ 有 N 个，只能留一个" + `fleet-repo.sh fold` (guards #979)
#   1 fleet   → "claude fleet · N 个仓库" (the fleet conf's repo + repos/*.conf,
#               a repeat dropped, as fleet_repos), the `fleet` line, any intro.d
#               lines, then the hide hint.
#
# intro.d: machine-local extra lines (e.g. a `vnc` row) the repo knows nothing
# about. Every executable in $FLEET_INTRO_SYS_D (/usr/local/etc/claude-fleet/
# intro.d) then $CONF_DIR/intro.d, in file order, runs with stdin closed; its
# stdout prints verbatim between the fleet line and the hide hint. A failing or
# silent hook prints nothing. Each hook owns its gating (SSH-only, …) and must
# keep its own lines ≤ 40 columns. A hook runs with FLEET_UI_LANG set to the
# banner's RESOLVED language — exactly `zh` or `en` (#1259): the fleet conf's
# value wins over the login locale, so a zh fleet on an en_US login gets `zh`.
# Localize off it; never re-read the conf or $LANG.
# bin/fleet-intro-selftest.sh pins every branch above.
CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
SYS_D="${FLEET_INTRO_SYS_D:-/usr/local/etc/claude-fleet/intro.d}"
ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
[ -f "$ROOT/fleet.conf" ] && . "$ROOT/fleet.conf" 2>/dev/null || :
[ -f "$ROOT/bin/fleet-ui-lang.sh" ] && . "$ROOT/bin/fleet-ui-lang.sh"
b=$(printf '\033[1m'); d=$(printf '\033[2m'); y=$(printf '\033[33m'); r=$(printf '\033[0m')
getkv() { sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" "$1" | head -1; }
zh() { [ "$(fleet_ui_lang)" = zh ]; }

# the login's one fleet
n=0; sess=""; conf=""
for dd in "$CONF_DIR"/fleets/*/; do
  [ -f "${dd}conf" ] || continue
  n=$((n+1)); s=${dd%/}; sess=${s##*/}; conf="${dd}conf"
done
if [ "$n" -eq 0 ]; then
  if zh; then printf '%sclaude fleet%s %s○ 未配置%s\n' "$b" "$r" "$y" "$r"
  else printf '%sclaude fleet%s %s○ not set up%s\n' "$b" "$r" "$y" "$r"; fi
  if zh; then echo '见 ~/.claude/fleet/docs/INSTALL.md'
  else echo 'see ~/.claude/fleet/docs/INSTALL.md'; fi
  exit 0
fi
if [ "$n" -gt 1 ]; then
  if zh; then printf '%sclaude fleet%s %s⚠ 有 %s 个，只能留一个%s\n运行 fleet-repo.sh fold\n' "$b" "$r" "$y" "$n" "$r"
  else printf '%sclaude fleet%s %s⚠ %s fleets, keep one%s\nrun fleet-repo.sh fold\n' "$b" "$r" "$y" "$n" "$r"; fi
  exit 0
fi

_ui=$(getkv "$conf" FLEET_UI_LANG); [ -n "$_ui" ] && FLEET_UI_LANG=$_ui
# repo count: the fleet's own conf, then repos/*.conf, a repeat dropped — the
# same set as fleet_repos (bin/fleet-lib.sh). All equal, no main repo.
seen=" $(getkv "$conf" FLEET_REPO) "; nr=1
for rc in "$CONF_DIR/fleets/$sess/repos"/*.conf; do
  [ -f "$rc" ] || continue
  rp=$(getkv "$rc" FLEET_REPO); [ -n "$rp" ] || continue
  case "$seen" in *" $rp "*) continue ;; esac
  seen="$seen$rp "; nr=$((nr+1))
done

if zh; then
  printf '%sclaude fleet%s · %s 个仓库\n' "$b" "$r" "$nr"
  printf '%sfleet%s   打开客户端\n' "$b" "$r"
else
  [ "$nr" -eq 1 ] && rw=repo || rw=repos
  printf '%sclaude fleet%s · %s %s\n' "$b" "$r" "$nr" "$rw"
  printf '%sfleet%s   open the client\n' "$b" "$r"
fi
ui=$(fleet_ui_lang)
for hd in "$SYS_D" "$CONF_DIR/intro.d"; do
  for h in "$hd"/*; do
    [ -f "$h" ] && [ -x "$h" ] || continue
    hout=$(FLEET_UI_LANG=$ui "$h" </dev/null 2>/dev/null) || continue
    [ -n "$hout" ] && printf '%s\n' "$hout"
  done
done
if zh; then printf '%s隐藏：touch ~/.hushfleet%s\n' "$d" "$r"
else printf '%shide: touch ~/.hushfleet%s\n' "$d" "$r"; fi
