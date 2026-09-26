#!/bin/bash
# fleet-alerts.sh — the ONE producer of the fleet's alerts (issue #1238).
#
# Every tick writes $G/alerts.ndjson, one alert per line; the status bar, the
# `prefix !` popup and fleet-doctor only READ it. Before this each of them
# computed its own alarms and printed a whole sentence for each (the weekly
# pace gap, `⚠ daemon stale cleanup,dispatch+2 ↻3m`, …), so the bar's width moved with
# the bad news and a phone cut it off exactly when it mattered.
#
# THREE LEVELS + ONE TRACE — the icon and the colour always travel together:
#   ✖ alarm    (red)    what you see may be wrong / the fleet is flying blind
#   ▲ warning  (yellow) drifting, self-healing or a limit ahead — look when free
#   ● needs    (blue)   a session is waiting for a human
#   ↻ healed   (purple) not a level: a trace on the row for FLEET_ALERTS_TRACE
#                       (30m) after an alarm/warning cleared, so a recovery is
#                       never silent
#
# ONE GRAMMAR: `<icon> <subject> · <condition> · <value>`. Subjects are nouns the
# operator knows (quota, dash, daemon, disk, accounts, model, #<issue>);
# conditions come from a closed list (stale, unreadable, uneven, from banner,
# low, capped, all capped, question, permission, blocked, failed, waiting).
#
# A row (fixed key order — the readers parse it with ONE regex, no jq):
#   {"id":…,"severity":alarm|warning|needs|healed,"subject":…,"condition":…,
#    "value":…,"since":<epoch>,"action":…,"healed_at":<epoch|0>,
#    "target":…,"detail":…}
# action ∈ accounts | kick-collect | kick-daemons | disk | jump  (every row has
# one: an alert with nothing to do about it is demoted or deleted, not shown).
#
# Usage:
#   fleet-alerts.sh write [--kick]   compute + write $G/alerts.ndjson
#                                    (--kick: also self-heal a stale collector,
#                                    rate-limited — the status bar's refresh)
#   fleet-alerts.sh refresh [--kick] write only when the file is older than
#                                    FLEET_ALERTS_TTL (5s), one writer at a time
#   fleet-alerts.sh counts           "<alarm> <warning> <needs>" (muted excluded)
#   fleet-alerts.sh bar              the status bar's fixed-width count segment
#   fleet-alerts.sh list [--level L] [--plain]   the popup's rows (L = alarm |
#                                    warning | needs | all)
#   fleet-alerts.sh mute <id>        silence a warning/needs for 1h (never an alarm)
#   fleet-alerts.sh act <id>         run the row's action (a kick detaches:
#                                    `kick` is its background half, #1242)
#   fleet-alerts.sh popup [--level L]  the `prefix !` popup (fzf)
#
# Sourced (tmux-status.sh does, every 5s per client) it only defines functions;
# the caller must already have usage-lib.sh + fleet-daemon-lib.sh loaded.

case "${BASH_SOURCE[0]}" in */*) _FA_BIN="${BASH_SOURCE[0]%/*}" ;; *) _FA_BIN=. ;; esac
_FA_BIN="$(cd "${_FA_BIN:-/}" && pwd)"

_FA_RE='^\{"id":"([^"]*)","severity":"([^"]*)","subject":"([^"]*)","condition":"([^"]*)","value":"([^"]*)","since":([0-9]+),"action":"([^"]*)","healed_at":([0-9]+),"target":"([^"]*)","detail":"([^"]*)"\}$'

fleet_alerts_file() { printf '%s/alerts.ndjson' "$(fleet_usage_cache_dir)"; }
fleet_alerts_mute_file() { printf '%s/alerts.mute' "$(fleet_usage_cache_dir)"; }

# _fa_clean <s> — a value safe inside a JSON string and a TSV field.
_fa_clean() {
  local s="${1:-}"
  s=${s//\\/}; s=${s//\"/}; s=${s//$'\t'/ }; s=${s//$'\n'/ }
  printf '%s' "$s"
}

# _fa_row id sev subject condition value since action healed_at target detail
# → one row on stdout (the compute → write interchange format), fields split by
# the ASCII unit separator: tab is IFS WHITESPACE, so `read` would collapse an
# empty field and shift every one after it.
_FA_US=$'\037'
_fa_row() {
  printf "%s${_FA_US}%s${_FA_US}%s${_FA_US}%s${_FA_US}%s${_FA_US}%s${_FA_US}%s${_FA_US}%s${_FA_US}%s${_FA_US}%s\n" \
    "$1" "$2" "$3" "$4" "$(_fa_clean "$5")" "${6:-0}" "$7" "${8:-0}" \
    "$(_fa_clean "${9:-}")" "$(_fa_clean "${10:-}")"
}

# _fa_json <tsv row> → the ndjson line.
_fa_json() {
  local id sev su co va si ac he ta de
  IFS=$_FA_US read -r id sev su co va si ac he ta de <<< "$1"
  case "$si" in ''|*[!0-9]*) si=0 ;; esac
  case "$he" in ''|*[!0-9]*) he=0 ;; esac
  printf '{"id":"%s","severity":"%s","subject":"%s","condition":"%s","value":"%s","since":%s,"action":"%s","healed_at":%s,"target":"%s","detail":"%s"}\n' \
    "$id" "$sev" "$su" "$co" "$va" "$si" "$ac" "$he" "$ta" "$de"
}

# _fa_hhmm <epoch> — local HH:MM (BSD date -r, GNU date -d).
_fa_hhmm() { date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null || printf '?'; }

# fleet_alerts_compute [--kick] — every alert that holds RIGHT NOW, as TSV rows
# (since=0 means "carry it over from the previous file, or now"). A line
# `#carry-needs` asks the writer to keep the previous file's needs rows: the
# quota watch writes from outside tmux, where no window is visible.
fleet_alerts_compute() {
  local kick=0 now qstale qblind qvb qspread cstale ckick trace dn du dnames
  local dkick dtrace free floor target af at nf label rest model until fb seen
  [ "${1:-}" = --kick ] && kick=1
  now=$(fleet_now)
  trace="${FLEET_COLLECT_KICK_TRACE:-1800}"

  # --- quota (issues #551, #684, #874, #1231) ---
  qstale=$(fleet_quota_stale_age)
  if [ -n "$qstale" ]; then
    _fa_row quota-stale alarm quota stale "$(fleet_usage_human_secs "$qstale")" \
      $(( now - qstale )) accounts 0 '' 'no quota-watch tick for this long: the pre-emptive rotation is blind'
  else
    qblind=$(fleet_quota_blind)
    [ -n "$qblind" ] && _fa_row quota-unreadable alarm quota unreadable \
      "$(fleet_usage_human_secs "${qblind#*	}")" $(( now - ${qblind#*	} )) accounts 0 '' \
      'the hub answers with no rows: the rotation has nothing to act on'
  fi
  qvb=$(fleet_quota_via_banner)
  [ -n "$qvb" ] && _fa_row quota-banner warning quota 'from banner' "${qvb%%	*}" \
    $(( now - ${qvb#*	} )) accounts 0 '' 'a limit banner benched an account with no fresh quota reading'
  qspread=$(fleet_quota_pace_spread)
  if [ -n "$qspread" ]; then
    rest=${qspread#*	}
    _fa_row quota-uneven warning quota uneven "${qspread%%	*} pts" 0 accounts 0 '' \
      "weekly quota drains unevenly: ${rest%%	*} is ahead, ${rest#*	} behind"
  fi

  # --- dash = the collector (issue #636): the stale alarm, its self-heal, its trace.
  cstale=$(fleet_collect_stale_age)
  ckick=$(fleet_collect_kick_age)
  if [ -n "$cstale" ]; then
    local cv; cv=$(fleet_usage_human_secs "$cstale")
    [ -n "$ckick" ] && [ "$ckick" -lt "$trace" ] && cv="$cv ↻"
    _fa_row dash-stale alarm dash stale "$cv" $(( now - cstale )) kick-collect 0 '' \
      'the collector stopped: every number on the dash is frozen'
    if [ "$kick" = 1 ] && fleet_collect_kick_due; then
      ( bash "$_FA_BIN/fleet-collect-kick.sh" </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
  elif [ -n "$ckick" ] && [ "$ckick" -lt "$trace" ]; then
    _fa_row dash-stale healed dash stale kicked 0 kick-collect $(( now - ckick )) '' 'self-healed by a kick'
  fi

  # --- every other interval daemon (issue #639). collect is the dash row above.
  dtrace="${FLEET_DAEMON_KICK_TRACE:-$trace}"
  dn=0; dnames=""
  for du in $(fleet_daemon_overdue_list "$_FA_BIN/.." collect); do
    dn=$((dn + 1)); dnames="${dnames:+$dnames,}$du"
  done
  dkick=$(fleet_daemon_recent_kick "$_FA_BIN/.." collect)
  if [ "$dn" -gt 0 ]; then
    local dv="$dn units"; [ "$dn" = 1 ] && dv="1 unit"
    [ -n "$dkick" ] && [ "$dkick" -lt "$dtrace" ] && dv="$dv ↻"
    _fa_row daemon-stale alarm daemon stale "$dv" 0 kick-daemons 0 '' "$dnames"
  elif [ -n "$dkick" ] && [ "$dkick" -lt "$dtrace" ]; then
    _fa_row daemon-stale healed daemon stale kicked 0 kick-daemons $(( now - dkick )) '' 'self-healed by a kick'
  fi

  # --- disk: the SAME volume + floor diskguard gates on (FLEET_STATUS_DISK=0 off).
  if [ "${FLEET_STATUS_DISK:-1}" != 0 ] && [ "${FLEET_ALERTS_DISK:-1}" != 0 ]; then
    target="${FLEET_DISK_TARGET:-${TMPDIR:-/tmp}}"; floor="${FLEET_DISK_FLOOR_GB:-12}"
    free=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 { printf "%d", int($4/1048576) }')
    case "$free" in ''|*[!0-9]*) ;; *)
      if [ "$free" -le "$floor" ]; then
        _fa_row disk-low alarm disk low "$free GB" 0 disk 0 "$target" "at or below the ${floor} GB floor: spawns are refused"
      elif [ "$free" -le $(( floor * 3 / 2 )) ]; then
        _fa_row disk-low warning disk low "$free GB" 0 disk 0 "$target" "within 1.5x of the ${floor} GB floor"
      fi ;;
    esac
  fi

  # --- accounts: every subscription at its ceiling (stamped by .fleet-account.py
  # when a launch found nothing to pick; FLEET_ALERTS_ALLCAPPED_SECS old at most).
  af="$(fleet_usage_cache_dir)/account.all-capped"
  if [ -f "$af" ] && IFS=$'\t' read -r at nf < "$af" 2>/dev/null; then
    case "$at" in ''|*[!0-9]*) at=0 ;; esac
    case "$nf" in ''|*[!0-9]*) nf=0 ;; esac
    if [ $(( now - at )) -lt "${FLEET_ALERTS_ALLCAPPED_SECS:-900}" ] && { [ "$nf" = 0 ] || [ "$nf" -gt "$now" ]; }; then
      local av='no account free'; [ "$nf" -gt 0 ] && av="next free $(_fa_hhmm "$nf")"
      _fa_row accounts-capped warning accounts 'all capped' "$av" "$at" accounts 0 '' \
        'no reachable, readable subscription is under the ceiling'
    fi
  fi

  # --- model: a per-model cap (issue #524) on any account, one row per model.
  af="$(fleet_usage_cache_dir)/account.model-limited"
  if [ -f "$af" ]; then
    seen="|"; fb="${FLEET_MODEL_FALLBACK-opus}"
    while IFS= read -r rest || [ -n "$rest" ]; do
      label=${rest%%	*}; rest=${rest#*	}; model=${rest%%	*}; rest=${rest#*	}; until=${rest%%	*}
      case "$until" in ''|*[!0-9]*) continue ;; esac
      [ "$until" -gt "$now" ] && [ -n "$model" ] || continue
      case "$seen" in *"|$model|"*) continue ;; esac
      seen="$seen$model|"
      local mv="$model"; [ -n "$fb" ] && [ "$fb" != "$model" ] && mv="$model → $fb"
      _fa_row "model-capped-$model" warning model capped "$mv" 0 accounts 0 '' \
        "capped on $label until $(_fa_hhmm "$until")"
    done < "$af"
  fi

  # --- needs: sessions waiting for a human, off each window's @claude_state.
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    # Every optional field has a `-`/0 sentinel: tab is IFS whitespace.
    local s w n i st sub ts cond subj
    while IFS=$'\t' read -r s w n i st sub ts; do
      case "$n" in dash|backlog) continue ;; esac
      case "$st" in
        needs) case "$sub" in ask) cond=question ;; perm) cond=permission ;; blocked) cond=blocked ;; *) cond=waiting ;; esac ;;
        failed) cond=failed ;;
        *) continue ;;
      esac
      case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
      subj="$n"; [ "$i" != - ] && subj="#$i"
      _fa_row "needs-$s-$w" needs "$subj" "$cond" '' "$ts" jump 0 "$s:$w" "$n"
    done <<EOF
$(tmux list-windows -a -F '#{session_name}	#{window_id}	#{window_name}	#{?@issue,#{@issue},-}	#{?@claude_state,#{@claude_state},-}	#{?@claude_needs,#{@claude_needs},-}	#{?@claude_state_ts,#{@claude_state_ts},0}' 2>/dev/null)
EOF
  else
    printf '#carry-needs\n'
  fi
  return 0
}

# fleet_alerts_write [--kick] — compute, merge with the previous file (carry each
# row's `since`; turn a cleared alarm/warning into a ↻ healed row for
# FLEET_ALERTS_TRACE), and publish atomically.
fleet_alerts_write() {
  local f cur prev="" now trace line row id sev su co va si ac he ta de out="" ids="|" carry=0 pid
  f=$(fleet_alerts_file)
  mkdir -p "${f%/*}" 2>/dev/null
  now=$(fleet_now)
  trace="${FLEET_ALERTS_TRACE:-1800}"
  cur=$(fleet_alerts_compute "$@")
  [ -f "$f" ] && prev=$(<"$f")   # builtin read: the bar's render path execs no cat (#888)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$row" = '#carry-needs' ] && { carry=1; continue; }
    IFS=$_FA_US read -r id sev su co va si ac he ta de <<< "$row"
    case "$ids" in *"|$id|"*) continue ;; esac   # first row per id wins
    if [ "$si" = 0 ] && [ "$sev" != healed ]; then
      si=$now
      while IFS= read -r line; do
        [[ $line =~ $_FA_RE ]] || continue
        [ "${BASH_REMATCH[1]}" = "$id" ] && [ "${BASH_REMATCH[2]}" != healed ] && { si=${BASH_REMATCH[6]}; break; }
      done <<< "$prev"
    fi
    ids="$ids$id|"
    out="$out$(_fa_json "$id$_FA_US$sev$_FA_US$su$_FA_US$co$_FA_US$va$_FA_US$si$_FA_US$ac$_FA_US$he$_FA_US$ta$_FA_US$de")"$'\n'
  done <<< "$cur"
  # What the previous file had and this tick does not: a cleared alarm/warning
  # becomes a ↻ trace; a trace lives out FLEET_ALERTS_TRACE; needs rows survive
  # only a writer that cannot see tmux.
  while IFS= read -r line; do
    [[ $line =~ $_FA_RE ]] || continue
    id=${BASH_REMATCH[1]}; sev=${BASH_REMATCH[2]}; he=${BASH_REMATCH[8]}
    case "$ids" in *"|$id|"*) continue ;; esac
    # dash/daemon carry their OWN trace (the kick stamp, FLEET_*_KICK_TRACE):
    # compute emits it when there is one, so a generic trace would only outlive it.
    case "$id" in dash-stale|daemon-stale) continue ;; esac
    case "$sev" in
      alarm|warning)
        line="${line/\"severity\":\"$sev\"/\"severity\":\"healed\"}"
        line="${line/\"healed_at\":0,/\"healed_at\":$now,}" ;;
      healed) [ $(( now - he )) -lt "$trace" ] || continue ;;
      needs) [ "$carry" = 1 ] || continue ;;
      *) continue ;;
    esac
    ids="$ids$id|"; out="$out$line"$'\n'
  done <<< "$prev"
  pid=$$
  printf '%s' "$out" > "$f.$pid" 2>/dev/null && mv -f "$f.$pid" "$f" 2>/dev/null || rm -f "$f.$pid"
  printf '%s\n' "$now" > "$f.ts.$pid" 2>/dev/null && mv -f "$f.ts.$pid" "$f.ts" 2>/dev/null || rm -f "$f.ts.$pid"
  return 0
}

# fleet_alerts_refresh [--kick] — the status bar's path: rewrite only when the
# file is older than FLEET_ALERTS_TTL (default 5 = status-interval); one writer
# at a time across every attached client (mkdir lock; a holder older than 30s
# is a dead one's). FLEET_ALERTS_TTL=0 always writes.
fleet_alerts_refresh() {
  local f ttl="${FLEET_ALERTS_TTL:-5}" ts="" lock now
  case "$ttl" in ''|*[!0-9]*) ttl=5 ;; esac
  f=$(fleet_alerts_file); lock="$f.lock"; now=$(fleet_now)
  # The age rides in $f.ts (read with a builtin): no stat fork per render.
  [ -f "$f.ts" ] && IFS= read -r ts < "$f.ts" 2>/dev/null
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  [ "$ttl" -gt 0 ] && [ -f "$f" ] && [ $(( now - ts )) -lt "$ttl" ] && [ "$ts" -le "$now" ] && return 0
  mkdir -p "${f%/*}" 2>/dev/null
  if ! mkdir "$lock" 2>/dev/null; then
    # Held — by a live writer unless the file has not moved for 30s past its TTL.
    [ $(( now - ts )) -gt $(( ttl + 30 )) ] || return 0
    rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 0
  fi
  fleet_alerts_write "$@"
  rmdir "$lock" 2>/dev/null
  return 0
}

# _fa_muted <id> <mute-file-contents> <now> — 0 iff muted and not expired.
_fa_muted() {
  local mid mu
  while IFS=$'\t' read -r mid mu; do
    [ "$mid" = "$1" ] || continue
    case "$mu" in ''|*[!0-9]*) continue ;; esac
    [ "$mu" -gt "$3" ] && return 0
  done <<< "$2"
  return 1
}

# fleet_alerts_counts — sets FA_ALARM / FA_WARNING / FA_NEEDS (muted rows and ↻
# traces never count; an alarm cannot be muted). Builtins only: the bar calls it.
fleet_alerts_counts() {
  local f mf mutes="" line now
  FA_ALARM=0; FA_WARNING=0; FA_NEEDS=0
  f=$(fleet_alerts_file); mf=$(fleet_alerts_mute_file)
  [ -f "$f" ] || return 0
  [ -f "$mf" ] && mutes=$(<"$mf")
  now=$(fleet_now)
  while IFS= read -r line; do
    [[ $line =~ $_FA_RE ]] || continue
    case "${BASH_REMATCH[2]}" in
      alarm) FA_ALARM=$((FA_ALARM + 1)) ;;
      warning) _fa_muted "${BASH_REMATCH[1]}" "$mutes" "$now" || FA_WARNING=$((FA_WARNING + 1)) ;;
      needs) _fa_muted "${BASH_REMATCH[1]}" "$mutes" "$now" || FA_NEEDS=$((FA_NEEDS + 1)) ;;
    esac
  done < "$f"
  return 0
}

# fleet_alerts_bar — `✖ N ▲ N`, FIXED width whatever the counts (a zero slot is
# blanks, a count past 99 reads 99), wrapped in clickable ranges that open the
# popup filtered to that level (conf/tmux-attention.conf, MouseDown1Status).
# Needs keep their own clickable `● N` at the left end of the bar (status-left).
# Sets $FA_BAR (no subshell: the bar renders every 5s per client).
fleet_alerts_bar() {
  local a w
  fleet_alerts_counts
  a=$FA_ALARM; w=$FA_WARNING
  [ "$a" -gt 99 ] && a=99; [ "$w" -gt 99 ] && w=99
  if [ "$a" -gt 0 ]; then printf -v a '#[fg=#f7768e,bold]✖ %-2s#[nobold]' "$a"; else a='    '; fi
  if [ "$w" -gt 0 ]; then printf -v w '#[fg=#e0af68]▲ %-2s' "$w"; else w='    '; fi
  printf -v FA_BAR '#[fg=#565f89]│ #[range=user|alarm]%s#[norange] #[range=user|warning]%s#[norange] ' "$a" "$w"
}

# fleet_alerts_list [--level L] [--plain] — the popup's rows, alarm → warning →
# needs → ↻, longest-standing first within a level. Each line is
# `<id>\t<rendered row>`; --plain drops the colour (fleet-doctor, selftests).
fleet_alerts_list() {
  local level=all plain=0 f mf mutes="" now line rank dur icon r x tail mute pad
  while [ $# -gt 0 ]; do
    case "$1" in
      --level) level="${2:-all}"; shift ;;
      --plain) plain=1 ;;
    esac
    shift
  done
  f=$(fleet_alerts_file); mf=$(fleet_alerts_mute_file)
  [ -f "$f" ] || return 0
  [ -f "$mf" ] && mutes=$(<"$mf")
  now=$(fleet_now)
  local R=$'\033[31m' Y=$'\033[33m' B=$'\033[34m' P=$'\033[35m' D=$'\033[2m' Z=$'\033[0m'
  [ "$plain" = 1 ] && { R=''; Y=''; B=''; P=''; D=''; Z=''; }
  while IFS= read -r line; do
    [[ $line =~ $_FA_RE ]] || continue
    local id=${BASH_REMATCH[1]} sev=${BASH_REMATCH[2]} su=${BASH_REMATCH[3]} co=${BASH_REMATCH[4]}
    local va=${BASH_REMATCH[5]} si=${BASH_REMATCH[6]} ac=${BASH_REMATCH[7]} he=${BASH_REMATCH[8]}
    case "$level" in all|"$sev") ;; *) continue ;; esac
    case "$sev" in
      alarm) rank=1; icon="${R}✖${Z}" ;;
      warning) rank=2; icon="${Y}▲${Z}" ;;
      needs) rank=3; icon="${B}●${Z}" ;;
      healed) rank=4; icon="${P}↻${Z}" ;;
      *) continue ;;
    esac
    r="$su · $co"; [ -n "$va" ] && r="$r · $va"
    case "$ac" in
      accounts) x='see accounts' ;; kick-collect|kick-daemons) x='restart daemon' ;;
      disk) x='see disk' ;; jump) x='↵ go to window' ;; *) x='' ;;
    esac
    tail=""
    if [ "$sev" = healed ]; then
      tail=" ${P}↻${Z} ${D}healed $(fleet_usage_human_secs $(( now - he ))) ago${Z}"; dur=''

      rank="$rank$(printf '%012d' $(( 999999999999 - he )))"
    else
      [ "$si" -gt 0 ] && dur=$(fleet_usage_human_secs $(( now - si ))) || dur='?'
      rank="$rank$(printf '%012d' "$si")"
    fi
    mute=""
    [ "$sev" != alarm ] && _fa_muted "$id" "$mutes" "$now" && mute=" ${D}(muted)${Z}"
    # Pad by CHARACTERS: printf's %-Ns counts bytes, and `·` / `→` are several.
    pad=$(( 40 - ${#r} )); [ "$pad" -lt 1 ] && pad=1
    printf '%s\t%s\t%s  %s%*s%6s  %s%s%s\n' "$rank" "$id" "$icon" "$r" "$pad" '' "$dur" "${D}$x${Z}" "$tail" "$mute"
  done < "$f" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 | cut -f2-
}

# fleet_alerts_mute <id> — FLEET_ALERTS_MUTE_SECS (1h). Refuses an alarm.
fleet_alerts_mute() {
  local id="${1:-}" f mf line sev="" now keep=""
  [ -n "$id" ] || { echo "fleet-alerts: mute <id>" >&2; return 2; }
  f=$(fleet_alerts_file); mf=$(fleet_alerts_mute_file); now=$(fleet_now)
  [ -f "$f" ] && while IFS= read -r line; do
    [[ $line =~ $_FA_RE ]] && [ "${BASH_REMATCH[1]}" = "$id" ] && { sev=${BASH_REMATCH[2]}; break; }
  done < "$f"
  case "$sev" in
    '') echo "fleet-alerts: no alert '$id'" >&2; return 1 ;;
    alarm) echo "fleet-alerts: an alarm cannot be muted" >&2; return 3 ;;
  esac
  if [ -f "$mf" ]; then
    local mid mu
    while IFS=$'\t' read -r mid mu; do
      [ -n "$mid" ] && [ "$mid" != "$id" ] || continue
      case "$mu" in ''|*[!0-9]*) continue ;; esac
      [ "$mu" -gt "$now" ] && keep="$keep$mid	$mu"$'\n'
    done < "$mf"
  fi
  printf '%s%s\t%s\n' "$keep" "$id" $(( now + ${FLEET_ALERTS_MUTE_SECS:-3600} )) > "$mf.$$" && mv -f "$mf.$$" "$mf"
}

# _fa_detach <cmd> — run <cmd> detached from the popup, so ↵ closes it at once
# (issue #1242: a kick run inline held a blank popup open for seconds). Inside
# tmux it is `run-shell -b` (fleet_bg's idiom — the job belongs to the server,
# not to the popup that is about to die); outside, a nohup'd double fork.
_fa_detach() {
  if [ -n "${TMUX:-}" ]; then
    tmux run-shell -b "( $1
) >/dev/null 2>&1 || :" 2>/dev/null && return 0
  fi
  ( nohup sh -c "$1" </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
}

# _fa_kick_units <detail> — the stale units a kick-daemons row names (its detail
# is the comma list the compute step wrote), known units only, space-separated.
# A ↻ healed row's detail is a sentence, which yields nothing — nothing to kick.
_fa_kick_units() {
  local u out="" d="${1:-}"
  # Split on the default IFS: fleet_daemon_known `read`s the registry with it.
  for u in ${d//,/ }; do
    [ -n "$u" ] && fleet_daemon_known "$u" 2>/dev/null && out="${out:+$out }$u"
  done
  printf '%s' "$out"
}

# fleet_alerts_kick <action> [unit…] — the background half of a kick (issue #1242):
# run fleet-daemon-watch on exactly these units — NO --force for kick-daemons, so
# the cooldown and the running-tick guard hold and a healthy unit is never kicked
# — then toast what happened to each: kicked / running (not touched) / cooldown /
# not loaded / fresh (already ticking again, nothing done).
fleet_alerts_kick() {
  local ac="${1:-}" out u line k="" r="" c="" n="" x="" f="" msg a
  shift
  case "$ac" in
    kick-collect) out=$(bash "$_FA_BIN/fleet-daemon-watch.sh" --unit collect --force </dev/null 2>&1) ;;
    kick-daemons)
      [ $# -gt 0 ] || { tmux display-message 'fleet: daemon restart — no stale unit named, nothing to do' 2>/dev/null; return 0; }
      a=""; for u in "$@"; do a="$a --unit $u"; done
      # shellcheck disable=SC2086  # $a is --unit <known name> pairs, word-split on purpose
      out=$(bash "$_FA_BIN/fleet-daemon-watch.sh" $a </dev/null 2>&1) ;;
    *) return 1 ;;
  esac
  [ "$ac" = kick-collect ] && set -- collect
  for u in "$@"; do
    line=$(printf '%s\n' "$out" | grep "^fleet-daemon-watch: $u " | tail -1)
    case "$line" in
      '') f="${f:+$f,}$u" ;;
      *'is RUNNING but WEDGED'*|*' — kicked '*|*RELOADED*|*bootstrapped*) k="${k:+$k,}$u" ;;
      *'a tick is RUNNING'*) r="${r:+$r,}$u" ;;
      *cooldown*) c="${c:+$c,}$u" ;;
      *'not loaded'*|*FAILED*) n="${n:+$n,}$u" ;;
      *) x="${x:+$x,}$u" ;;
    esac
  done
  msg=""
  [ -n "$k" ] && msg="$msg · kicked $k"
  [ -n "$r" ] && msg="$msg · running, not touched $r"
  [ -n "$c" ] && msg="$msg · cooldown $c"
  [ -n "$n" ] && msg="$msg · not loaded $n"
  [ -n "$f" ] && msg="$msg · fresh $f"
  [ -n "$x" ] && msg="$msg · ? $x"
  tmux display-message "fleet: daemon restart${msg}" 2>/dev/null
  return 0
}

# fleet_alerts_act <id> — do the row's one action. A kick returns at once and
# finishes in the background (fleet_alerts_kick toasts the outcome).
fleet_alerts_act() {
  local id="${1:-}" f line ac="" ta="" de="" units self
  f=$(fleet_alerts_file)
  [ -f "$f" ] && while IFS= read -r line; do
    [[ $line =~ $_FA_RE ]] && [ "${BASH_REMATCH[1]}" = "$id" ] && { ac=${BASH_REMATCH[7]}; ta=${BASH_REMATCH[9]}; de=${BASH_REMATCH[10]}; break; }
  done < "$f"
  self="bash '$_FA_BIN/fleet-alerts.sh'"
  case "$ac" in
    accounts) exec bash "$_FA_BIN/usage-modal.sh" ;;
    kick-collect)
      tmux display-message 'fleet: dash (collector) restart requested…' 2>/dev/null
      _fa_detach "$self kick kick-collect" ;;
    kick-daemons)
      units=$(_fa_kick_units "$de")
      if [ -z "$units" ]; then
        tmux display-message 'fleet: daemon restart — no stale unit named, nothing to do' 2>/dev/null
      else
        tmux display-message "fleet: daemon restart requested: ${units// /,}…" 2>/dev/null
        _fa_detach "$self kick kick-daemons $units"
      fi ;;
    disk)
      df -h "${ta:-${TMPDIR:-/tmp}}" 2>/dev/null
      printf '\n'; bash "$_FA_BIN/fleet-diskguard.sh" --free 2>/dev/null
      printf '\n  press any key to close\n'; IFS= read -rsn1 _ 2>/dev/null || true ;;
    jump)
      tmux switch-client -t "$ta" 2>/dev/null
      tmux select-window -t "${ta#*:}" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# _fa_prompt_level <fzf prompt> — the level the popup is showing, read back off
# its prompt (`alerts (warning) ▸ `): fzf exports $FZF_PROMPT to every command it
# runs, so a reload after a mute keeps the filter the operator picked.
_fa_prompt_level() {
  case "${1:-}" in
    *'(alarm)'*) printf alarm ;; *'(warning)'*) printf warning ;;
    *'(needs)'*) printf needs ;; *) printf all ;;
  esac
}

# fleet_alerts_rows <level> — the popup's body: the rows + a closing line.
fleet_alerts_rows() {
  fleet_alerts_list --level "${1:-all}"
  printf -- '-\t  \033[2m(no more alerts)\033[0m\n'
}

# fleet_alerts_popup_mute <id> <fzf prompt> — `m` in the popup: prints the fzf
# actions to run — a reload on success, a header note when it refuses.
fleet_alerts_popup_mute() {
  local err rc self="bash '$_FA_BIN/fleet-alerts.sh'"
  [ "${1:-}" != - ] || return 0
  err=$(fleet_alerts_mute "$1" 2>&1); rc=$?
  case "$rc" in
    0) printf 'reload(%s rows %s)' "$self" "$(_fa_prompt_level "${2:-}")" ;;
    3) printf 'change-header(✖ an alarm cannot be muted — ↵ acts on it · esc closes)' ;;
    *) printf 'change-header(%s)' "${err//)/}" ;;
  esac
}

# fleet_alerts_popup [--level L] — the `prefix !` table.
fleet_alerts_popup() {
  local level=all self="bash '$_FA_BIN/fleet-alerts.sh'" hdr l
  [ "${1:-}" = --level ] && level="${2:-all}"
  case "$level" in alarm|warning|needs) ;; *) level=all ;; esac
  fleet_alerts_refresh
  hdr='↵ act · 1 ✖ · 2 ▲ · 3 ● · 0 all · m mute 1h (not ✖) · esc  [✕ close]'
  set --
  for l in 1:alarm 2:warning 3:needs 0:all; do
    set -- "$@" --bind "${l%%:*}:reload($self rows ${l#*:})+change-prompt(alerts (${l#*:}) ▸ )+change-header($hdr)"
  done
  fleet_alerts_rows "$level" \
    | fzf --ansi --no-sort --layout=reverse --height=100% --disabled --no-info \
          --delimiter='\t' --with-nth=2.. --prompt="alerts ($level) ▸ " --header="$hdr" \
          "$@" \
          --bind "m:transform($self popup-mute {1} \"\$FZF_PROMPT\")" \
          --bind "enter:become([ {1} = - ] || $self act {1})" \
          --bind 'click-header:transform:case "$FZF_CLICK_HEADER_WORD" in *✕*|*close*) echo abort ;; esac'
  return 0
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  set -uo pipefail
  [ -f "$_FA_BIN/../fleet.conf" ] && . "$_FA_BIN/../fleet.conf"
  _fs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.settings"; [ -f "$_fs" ] && . "$_fs"
  . "$_FA_BIN/usage-lib.sh"
  . "$_FA_BIN/fleet-daemon-lib.sh"
  fleet_now_pin
  cmd="${1:-list}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    write) fleet_alerts_write "$@" ;;
    refresh) fleet_alerts_refresh "$@" ;;
    counts) fleet_alerts_counts; printf '%s %s %s\n' "$FA_ALARM" "$FA_WARNING" "$FA_NEEDS" ;;
    bar) fleet_alerts_bar; printf '%s' "$FA_BAR" ;;
    list) fleet_alerts_list "$@" ;;
    mute) fleet_alerts_mute "$@" ;;
    act) fleet_alerts_act "$@" ;;
    kick) fleet_alerts_kick "$@" ;;             # act's detached half
    popup) fleet_alerts_popup "$@" ;;
    rows) fleet_alerts_rows "$@" ;;              # the popup's own reloads
    popup-mute) fleet_alerts_popup_mute "$@" ;;  # the popup's `m`
    *) echo "fleet-alerts.sh: unknown command '$cmd' (write|refresh|counts|bar|list|mute|act|popup)" >&2; exit 2 ;;
  esac
fi
