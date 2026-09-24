#!/bin/bash
# fleet-host-tune.sh — walk the unattended-Mac checklist (docs/HOST.md) in one go
# (issue #1082, EPIC #1074).
#
#   fleet-host-tune.sh [--plan|--apply] [--yes] [--wifi-off]
#
# The doctor's `host` section only REPORTS (EPIC rule 3: the doctor never changes
# system state). This is the separate, explicit half: every item the checklist
# can do by command, listed as  now → target → command, one row per item under
# the SAME name as its doctor line (spotlight / nofile / sleep / siri / network /
# icloud).
#
#   --plan    (default) print each item's current state, target and command.
#             Changes nothing — it only reads (mdutil -s, pmset -g, defaults read,
#             launchctl limit, networksetup -get…). Pinned by the selftest.
#   --apply   run the command for each item that is not at target, asking y/N
#             per item (stdin; anything but y/yes skips it).
#   --yes     with --apply: no questions, apply every item.
#   --wifi-off  also offer Wi-Fi off on a wired host (the network item). Without
#             it, Wi-Fi off is offered only in the doctor's WARN case (wired +
#             Wi-Fi to one gateway); it is refused when every default route is ON
#             Wi-Fi — that would cut an SSH session off mid-command.
#
# Never touched, only hinted: the iCloud sign-in and GUI programs on the console
# (a Settings decision each; docs/HOST.md#headless). macOS only — elsewhere it
# says so and exits 0. Exit: 0 = nothing failed; 1 = an applied command failed;
# 2 = usage.
set -uo pipefail

mode=plan yes=0 wifi=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) mode=plan ;;
    --apply) mode=apply ;;
    --yes|-y) yes=1 ;;
    --wifi-off) wifi=1 ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'fleet-host-tune: unknown argument: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(uname -s 2>/dev/null)" != "Darwin" ]; then
  printf 'fleet-host-tune: macOS only — nothing to do on %s\n' "$(uname -s 2>/dev/null)"
  exit 0
fi

# The system-level LaunchDaemon that re-applies the file limit at every boot
# (`launchctl limit` alone is lost on restart). Overridable for the selftest only.
MAXF_PLIST="${FLEET_HOST_TUNE_MAXFILES_PLIST:-/Library/LaunchDaemons/com.claude-fleet.maxfiles.plist}"
MAXF_SOFT=65536 MAXF_HARD=200000

# --- output ------------------------------------------------------------------
# One row per item, same column layout as fleet-doctor:  TAG  name  text.
row() { printf '  %-6s %-9s %s\n' "$1" "$2" "$3"; }
sub() { printf '  %-6s %-9s %s\n' "" "" "$1"; }

n_change=0 n_done=0 n_skip=0 n_fail=0

# offer <name> <now> <target> <command-text> <apply-fn>
# The command text is what --plan shows and what --apply runs (via its fn);
# the two are written side by side below so they cannot drift apart unnoticed.
offer() {
  local name="$1" now="$2" target="$3" cmd="$4" fn="$5" ans
  n_change=$((n_change + 1))
  row CHANGE "$name" "now: $now → target: $target"
  sub "run: $cmd"
  [ "$mode" = apply ] || return 0
  if [ "$yes" != 1 ]; then
    printf '  %-6s %-9s apply? [y/N] ' "" ""
    ans=""; IFS= read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) sub "skipped"; n_skip=$((n_skip + 1)); return 0 ;; esac
  fi
  if "$fn"; then sub "done"; n_done=$((n_done + 1))
  else sub "FAILED (exit $?) — nothing else was changed for $name"; n_fail=$((n_fail + 1)); fi
}

# --- 1. spotlight (doctor line: spotlight; docs/HOST.md#spotlight) ------------
spvol=/System/Volumes/Data; [ -d "$spvol" ] || spvol=/
apply_spotlight() { sudo mdutil -a -i off; }
if command -v mdutil >/dev/null 2>&1; then
  spout=$(mdutil -s "$spvol" 2>&1 | tr '\n' ' ')
  case "$spout" in
    *"Indexing enabled"*)
      offer spotlight "indexing on ($spvol)" "indexing off on every volume" \
        "sudo mdutil -a -i off   (undo: sudo mdutil -a -i on)" apply_spotlight ;;
    *disabled*) row OK spotlight "indexing off on $spvol" ;;
    *) row '??' spotlight "could not read Spotlight state (mdutil -s: $(printf '%s' "$spout" | cut -c1-100))" ;;
  esac
else
  row SKIP spotlight "no mdutil on PATH"
fi

# --- 2. nofile (doctor line: nofile; docs/HOST.md#nofile) ---------------------
# The doctor passes at >= 4096. The fleet's own daemons already raise theirs
# (#1080); this is the host-wide default every OTHER LaunchAgent starts at.
# Two parts, both needed: `launchctl limit` for now, a LaunchDaemon for reboots.
apply_nofile() {
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    '  <key>Label</key><string>com.claude-fleet.maxfiles</string>' \
    "  <key>ProgramArguments</key><array><string>launchctl</string><string>limit</string><string>maxfiles</string><string>$MAXF_SOFT</string><string>$MAXF_HARD</string></array>" \
    '  <key>RunAtLoad</key><true/>' \
    '</dict></plist>' | sudo tee "$MAXF_PLIST" >/dev/null &&
    sudo chown root:wheel "$MAXF_PLIST" && sudo chmod 644 "$MAXF_PLIST" &&
    sudo launchctl limit maxfiles "$MAXF_SOFT" "$MAXF_HARD"
}
if command -v launchctl >/dev/null 2>&1; then
  nfsoft=$(launchctl limit maxfiles 2>/dev/null | awk '$1 == "maxfiles" { print $2; exit }')
  nfpl=""; [ -f "$MAXF_PLIST" ] || nfpl=" · no boot-time plist"
  case "$nfsoft" in
    ''|*[!0-9]*) row '??' nofile "could not read launchctl limit maxfiles (got: ${nfsoft:-nothing})" ;;
    *) if [ "$nfsoft" -ge 4096 ] && [ -z "$nfpl" ]; then
         row OK nofile "system default file limit is $nfsoft, set at boot by $MAXF_PLIST"
       else
         offer nofile "maxfiles $nfsoft$nfpl" "maxfiles $MAXF_SOFT $MAXF_HARD, now and at every boot" \
           "write $MAXF_PLIST (root:wheel 644; runs \`launchctl limit maxfiles $MAXF_SOFT $MAXF_HARD\` at load) + sudo launchctl limit maxfiles $MAXF_SOFT $MAXF_HARD   (undo: sudo rm $MAXF_PLIST, reboot)" \
           apply_nofile
       fi ;;
  esac
else
  row SKIP nofile "no launchctl on PATH"
fi

# --- 3. sleep (doctor line: sleep; docs/HOST.md#headless) ---------------------
# Target: never sleep, restart after a power cut, wake on LAN. A key the machine
# does not print (no womp on some models) is left alone.
if command -v pmset >/dev/null 2>&1; then
  pmout=$(pmset -g 2>/dev/null)
  slval=$(printf '%s\n' "$pmout" | awk '$1=="sleep"{print $2; exit}')
  arval=$(printf '%s\n' "$pmout" | awk '$1=="autorestart"{print $2; exit}')
  wompval=$(printf '%s\n' "$pmout" | awk '$1=="womp"{print $2; exit}')
  plargs="" now=""
  [ -n "$slval" ]   && { now="$now sleep=$slval";         [ "$slval" = 0 ]   || plargs="$plargs sleep 0"; }
  [ -n "$arval" ]   && { now="$now autorestart=$arval";   [ "$arval" = 1 ]   || plargs="$plargs autorestart 1"; }
  [ -n "$wompval" ] && { now="$now womp=$wompval";        [ "$wompval" = 1 ] || plargs="$plargs womp 1"; }
  apply_sleep() { sudo pmset -a $plargs; }   # word-split on purpose: key/value pairs
  if [ -z "$slval" ]; then
    row '??' sleep "could not read the sleep setting (pmset -g)"
  elif [ -n "$plargs" ]; then
    undo=""
    [ "$slval" = 0 ] || undo="$undo sleep $slval"
    [ -z "$arval" ] || [ "$arval" = 1 ] || undo="$undo autorestart $arval"
    [ -z "$wompval" ] || [ "$wompval" = 1 ] || undo="$undo womp $wompval"
    offer sleep "${now# }" "sleep 0 · autorestart 1 · womp 1" \
      "sudo pmset -a${plargs}   (undo: sudo pmset -a${undo})" apply_sleep
  else
    row OK sleep "never sleeps (${now# })"
  fi
else
  row SKIP sleep "no pmset on PATH"
fi

# --- 4. siri (doctor line: siri; docs/HOST.md#headless) -----------------------
# Per-user and no sudo: the same key the doctor reads and the Settings toggle
# writes. Its helpers exit when the toggle is flipped in Settings, or at the next
# login after this write — the Settings toggle stays the authoritative switch.
apply_siri() { defaults write com.apple.assistant.support "Assistant Enabled" -bool false; }
if command -v defaults >/dev/null 2>&1; then
  sival=$(defaults read com.apple.assistant.support "Assistant Enabled" 2>/dev/null | tr -d '[:space:]')
  case "$sival" in
    1) offer siri "Siri on" "Siri off (helpers exit at next login, or flip System Settings → Apple Intelligence & Siri now)" \
         "defaults write com.apple.assistant.support \"Assistant Enabled\" -bool false   (undo: … -bool true)" apply_siri ;;
    0|'') row OK siri "Siri off" ;;
    *) row '??' siri "could not read the Siri setting (Assistant Enabled=$sival)" ;;
  esac
else
  row SKIP siri "no defaults on PATH"
fi

# --- 5. network (doctor line: network; docs/HOST.md#network) -----------------
# The doctor WARNs when one gateway is the default route through 2+ interfaces
# (wired + Wi-Fi on one subnet). That case is offered unasked: another interface
# already reaches the same gateway, so switching Wi-Fi off cannot cut the host
# off. Otherwise Wi-Fi off is opt-in (--wifi-off) and refused while every
# default route goes through Wi-Fi.
wdev=""
command -v networksetup >/dev/null 2>&1 &&
  wdev=$(networksetup -listallhardwareports 2>/dev/null | awk '/^Hardware Port: (Wi-Fi|AirPort)$/ { w=1; next } w && /^Device:/ { print $2; exit }')
if [ -z "$wdev" ]; then
  [ "$wifi" = 1 ] && row SKIP network "no Wi-Fi hardware port"
else
  wpow=$(networksetup -getairportpower "$wdev" 2>/dev/null | awk '{print $NF}')
  # "<gateway> <interface>" per default route naming an IPv4 gateway (as the doctor reads it).
  nwroutes=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2, $4 }' | sort -u)
  wgws=$(printf '%s\n' "$nwroutes" | awk -v d="$wdev" '$2==d { print $1 }')
  wdup="" wother=""
  for g in $wgws; do
    printf '%s\n' "$nwroutes" | awk -v g="$g" -v d="$wdev" '$1==g && $2!=d { f=1 } END { exit !f }' && wdup="$g"
  done
  wother=$(printf '%s\n' "$nwroutes" | awk -v d="$wdev" 'NF==2 && $2!=d { print $2; exit }')
  apply_wifi() { networksetup -setairportpower "$wdev" off; }
  if [ "$wpow" = Off ]; then
    row OK network "Wi-Fi ($wdev) off"
  elif [ -n "$wdup" ]; then
    offer network "default route to $wdup through Wi-Fi ($wdev) and $wother — two interfaces on one subnet" "wired only: Wi-Fi off" \
      "networksetup -setairportpower $wdev off   (undo: … $wdev on)" apply_wifi
  elif [ "$wifi" != 1 ]; then
    row SKIP network "Wi-Fi ($wdev) is on, no shared default route — opt in with --wifi-off on a wired host"
  elif [ -z "$wother" ]; then
    row SKIP network "Wi-Fi ($wdev) carries every default route — turning it off would cut this host off; wire it first"
  else
    offer network "Wi-Fi ($wdev) on" "Wi-Fi off (default route on $wother)" \
      "networksetup -setairportpower $wdev off   (undo: … $wdev on)" apply_wifi
  fi
fi

# --- hints: Settings decisions, never run (docs/HOST.md#headless) -------------
iclive=""
for icd in bird cloudd fileproviderd; do
  pgrep -x "$icd" >/dev/null 2>&1 && iclive="$iclive $icd"
done
if [ -n "$iclive" ]; then
  row HINT icloud "sync daemons resident:$iclive — sign out, or turn off iCloud Drive + Contacts: System Settings → Apple Account → iCloud (not done by this script)"
else
  row OK icloud "no iCloud sync daemon resident"
fi
row HINT gui "quit browsers / Electron apps on the console and trim System Settings → General → Login Items (not done by this script; docs/HOST.md#headless)"

# --- summary --------------------------------------------------------------------
echo
if [ "$mode" = plan ]; then
  if [ "$n_change" -eq 0 ]; then echo "host tune: nothing to change."
  else echo "host tune: $n_change item(s) to change — nothing was changed. Apply: fleet-host-tune.sh --apply  (--yes = no questions)"; fi
  exit 0
fi
echo "host tune: $n_done applied, $n_skip skipped, $n_fail failed. Check: bash ~/.claude/fleet/bin/fleet-doctor.sh (host section)"
[ "$n_fail" -eq 0 ]
