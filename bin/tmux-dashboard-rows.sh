#!/bin/bash
# tmux-dashboard-rows.sh — emit rows for the interactive dash (fzf), GROUPED by
# status with aligned (display-width-correct) columns.
# Line format:  <sess:idx>US<window-id>US<colored display>
#   field1 = jump target · field2 = stable summary key (window-id) · field3 = display
# Data: @claude_state (no LLM), everything slow from collector caches.
# --sidebar emits wid US state US glyph US name US tree US badge US depth US detail
# US node US issue US pr US ctx (issues #1328/#1475/#1532: the pieces, so the
# view lays them out to its own width), without
# a header. It shares the live hub's ordering/folds, but never follows its
# landed-history toggle.
#
# HOT PATH (2026-07-07): this runs on every dash repaint (4×/s) — the loop is
# exec-fork-free (bash builtins only: read/expansion instead of cat/cut/sed/awk).
# Execs per render: tmux + sort + perl(sub-second clock) + one fleet_cache slug
# lookup ≈ 4. ~30ms total. (The #566 @wid backfill adds a handful of forks for a
# window that carries no handle yet — once in that window's life, not per tick.)
# --time (issue #1530) appends one `#took <ms>` line: the wall time of this run,
# from before the libraries load to the last row. Two perl forks, paid only by a
# caller that asks — the sidebar's 1 s tick never does.
set -uo pipefail
TIMEIT=0; case " $* " in *" --time "*) TIMEIT=1; T0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null) ;; esac
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"   # ${#s} must count chars, not bytes
case "$0" in */*) BIN="${0%/*}" ;; *) BIN=. ;; esac   # forkless dirname (issue #888)
BIN="$(cd "${BIN:-/}" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"   # fleet_cache: route prmap through THIS fleet's slug'd cache
. "$BIN/fleet-ui-lang.sh"
[ -n "${FLEET_SESSION:-}" ] && fleet_load_conf "$FLEET_SESSION" 2>/dev/null || true
C="${TMPDIR:-/tmp}/.claude-dash"; [ -d "$C" ] || mkdir -p "$C"   # 1Hz path: no exec once it exists (#888)
G="$C/global"                       # machine-wide caches (git_/ctx_) — issue #181
SIDEBAR=0; [ "${1:-}" = --sidebar ] && SIDEBAR=1

# live⇄landed view toggle (dash ⌃t writes $C/dash_view_<session>, per-fleet). In
# LANDED mode this producer hands off to the history ledger's row emitter, so
# finished (merged + cleaned-up) sessions are one keystroke away with the same row
# ergonomics (#130). Keyed by FLEET_SESSION so one fleet's toggle can't flip
# another's dash (they share $C); FLEET_SESSION is exported by tmux-dashboard.sh.
_view=''; [ -f "$G/dash_view_${FLEET_SESSION:-default}" ] && IFS= read -r _view < "$G/dash_view_${FLEET_SESSION:-default}" 2>/dev/null
if [ "$SIDEBAR" = 0 ] && [ "$_view" = landed ]; then
  exec bash "$BIN/fleet-history.sh" rows
fi

E=$'\033['
# Colours: conf/fleet-palette.conf, the fleet's ONE colour table (issue #1534), as
# truecolour escapes — never a literal here. No palette → no colour.
. "$BIN/fleet-palette.sh"; fleet_palette_load
_rows_fg() { fleet_palette_rgb "$2"; if [ -n "$_fpr" ]; then printf -v "$1" '%s38;2;%sm' "$E" "$_fpr"; else printf -v "$1" '%s' ''; fi; }
_rows_fg CY "${PAL_CYAN:-}"; _rows_fg RD "${PAL_RED:-}"; _rows_fg GN "${PAL_GREEN:-}"
_rows_fg IN "${PAL_MAGENTA:-}"; _rows_fg GY "${PAL_DIM:-}"; _rows_fg TX "${PAL_FG:-}"
_rows_fg AM "${PAL_YELLOW:-}"   # amber — green PR that isn't land-ready (behind/blocked)
GYU=${GY/38;/4;38;}             # the header row: underlined, dim
R="${E}0m"; US=$'\x1f'
# @pin (issue #623) is LAST on purpose: both passes below read it with `read`'s
# last-name-takes-the-rest rule, so a field appended AFTER it would arrive glued to
# the pin value. A new field goes BEFORE @pin, or pin_v's strict `1` test silently
# reads every pinned window as unpinned. @claude_needs (#640) and @expand (the
# fold bit) are the two newest such fields and sit exactly there, ahead of @pin,
# for that reason.
# Keep the column count stable. Codex's agent cell carries an exact cache suffix;
# the display loop separates it before drawing the ordinary `codex` tag.
# @repo_fold (LAST, issue #1037) is a SESSION option, not a window one: tmux
# resolves a `#{@…}` format through the window's session when the window has no
# option of that name, so the per-repo fold set rides the one list-windows call
# every frame already makes — same value on every line, no extra fork. Both
# passes name it so nothing lands glued to @sleep_since.
# A PROXY window (@remote, issue #1424) prints an EMPTY name, so both passes drop
# it like a nameless line: the machine's own `[m4]` row already stands for it.
# The LAST field (issue #1750) is the window's BIRTH — @born, stamped once at
# spawn and carried by every road a session takes (move/migrate), else tmux's own
# window_created — read off this same list-windows, so the born order costs no fork.
# After it (issue #1783): @agent_cfg, the fingerprint of the configuration the
# session was launched with (#1782) — compared per row against the one expected
# NOW (fleet_cfg_state, the file read once per frame below), so 配置旧 costs no fork.
# Inside the same field (issue #1895), `/<@agent_ver>` when the window has one —
# the fleet version it runs, so 待换新 costs no field and no fork either.
# Last (issue #1902): an empty slot where a remote row carries its title
# (#1921 — a local one is looked up below), then @reap_policy.
# The orchestrating session (issue #1957, `@fleet_role orchestrator`) reads as
# `home` in the name field: no row, as a panel — 「新任务」 wears it instead.
# After @reap_policy (issue #1958): @epic, `<owner/name>#<N>` on the window that
# drives a running EPIC (fleet-epic-heartbeat.sh stamps it) — the row is then the
# EPIC's: its parent issue's number + title, badged landed/members (epic_v).
WFMT="#{session_name}${US}#{window_index}${US}#{?@remote,,#{?#{==:#{@fleet_role},orchestrator},home,#{window_name}}}${US}#{pane_current_path}${US}#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}${US}#{@claude_state_ts}${US}#{window_id}${US}#{@issue}${US}#{@origin}${US}#{@worktree}${US}#{?#{==:#{@cc_agent},codex},codex:#{@cc_launcher_pid}_#{@codex_session_id},#{@cc_agent}}${US}#{@wid}${US}#{?#{==:#{@claude_state},looping},#{@claude_wait},#{@claude_needs}}${US}#{@expand}${US}#{@pin}${US}#{?@degenerate_ts,degen=#{@degenerate_ts}:,}#{?@mem_killed,mem:,}#{?@claude_mem_warn,fat=#{@claude_mem_warn}:,}#{?@ctx_warn,ctxw:,}#{?@quota_stuck,stuck:,}#{@quota_failover}${US}#{@reap_due}${US}#{@reap_seen}${US}#{@reap_state_ts}${US}#{@repo}${US}#{@norepo}${US}#{@sleep_since}#{?@sleep_wake_deferred,:#{@sleep_wake_deferred},}${US}#{@repo_fold}${US}#{@loop}${US}#{@title_info}${US}#{?@born,#{@born},#{window_created}}${US}#{@agent_cfg}#{?@agent_ver,/#{@agent_ver},}${US}${US}#{@reap_policy}${US}#{@epic}"

# pad/truncate a plaintext string to N DISPLAY chars (locale-aware ${#}) → $fld_out
fld() { local w="$1" s="$2" n=${#2}
  if [ "$n" -gt "$w" ]; then fld_out="${s:0:$w}"
  else printf -v fld_out "%s%*s" "$s" $((w-n)) ''; fi; }

# working glyph rotates: quarter-second frames from perl HiRes (macOS date has
# no %N and /bin/bash 3.2 no EPOCHREALTIME) — one frame per 4Hz repaint. The same
# tick doubles as the fork-free NOW (epoch seconds) for the activity column:
# perl's time()*4 ÷ 4 == floor(now), so no extra `date` fork on the hot path; the
# no-perl fallback reads whole seconds from `date` (one fork, as before).
# The same perl also says the local UTC offset (TZOFF, seconds) so a Loop's next
# round renders as local HH:MM in @title_info (issue #1377) with no extra fork.
SPINF='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
TICK=$(perl -MTime::HiRes=time -e '$t=time; @l=localtime($t); @g=gmtime($t); $d=$l[7]-$g[7]; $d=$d>1?-1:$d<-1?1:$d; printf "%d %d", $t*4, $d*86400+($l[2]-$g[2])*3600+($l[1]-$g[1])*60' 2>/dev/null)
TZOFF=${TICK#* }; TICK=${TICK%% *}
if [ -n "$TICK" ]; then NOW=$(( TICK / 4 )); else TICK=$(date +%s); NOW=$TICK; TZOFF=''; fi
FRAME=${SPINF:$(( TICK % 10 )):1}

# state → color/glyph/rank (set vars; no subshells)
# FIVE glyphs, one per thing the operator does about a row (issue #1328 — there
# were ten, and nobody could keep them apart):
#
#   ⠏  working — preparing / waking included: it is busy, not waiting on you
#   ↻  turn over, waiting on background work (looping)
#   !  needs YOU — every @claude_needs kind (ask / perm / blocked / restore /
#      the classifier's undifferentiated one) AND failed. WHICH kind is said in
#      words ($ndet below: the hub's act cell, the sidebar's selected-row line);
#      $2, the @claude_needs subtype (#640), is unchanged and still drives ⌃k
#   ✓  done
#   z  asleep — the glyph alone; the hub's act cell still says for how long
#   ⏏  exited — the agent left; the window waits on its recovery page (issue #1784)
#
# Every one is ONE display cell: the row's leading "${gc}${gl}${R} " slot is a
# fixed width the right-pinned act/PR/ctx block is padded against, so a 2-cell
# emoji here (🔒) would shear every red row.
state_v() { case "$1" in
  needs)   gc=$RD; gl='!'; rk=0;;
  sleeping) gc=$GY; gl='z'; rk=1;;
  exited)  gc=$AM; gl='⏏'; rk=1;;
  preparing|waking) gc=$CY; gl=$FRAME; rk=1;;
  failed) gc=$RD; gl='!'; rk=0;;
  done)    gc=$GN; gl='✓';      rk=1;;
  working) gc=$CY; gl=$FRAME;   rk=2;;
  looping) gc=$IN; gl='↻';      rk=3;;
  *)       gc=$GY; gl='·';      rk=4;;
esac; }

# seg_v <rk> <idx> <born> <window id> → $seg, one row's segment of the sort PATH.
# A row's place is its BIRTH (issue #1750, FLEET_DASH_ORDER=born, the default):
# `<born>:<stable id>` — the epoch it was spawned (@born, else window_created),
# ties broken by the window id's number, a remote row's by its worker_id — so a
# turn going working → done → working, a `needs` coming and going, or a window
# closing in the middle (renumber-windows) moves no row, and this machine's rows
# and another machine's are measured with the one ruler, whatever order the hub
# returned them in. A row with no birth (a remote node older than #1750) sorts
# after every born sibling, by its id. `status` is the old order, byte for byte:
# `<rk>:<idx>` — the state rank first, so a row jumps whenever its state does.
ORDER=${FLEET_DASH_ORDER:-born}; [ "$ORDER" = status ] || ORDER=born
seg_v() {
  if [ "$ORDER" = status ]; then printf -v seg '%s:%05d' "$1" "$2"; return; fi
  local b=$3 t=$4
  case "$b" in ''|*[!0-9]*) b=9999999999 ;; esac
  case "$t" in @*[0-9]) t=${t#@}; case "$t" in *[!0-9]*) ;; *) printf -v t '%08d' "$((10#$t))" ;; esac ;;
               wid:*) t=${t#wid:} ;; esac
  printf -v seg '%010d:%s' "$((10#$b))" "$t"
}

# loop_live_v <@loop> — true while the window's Loop mark (issue #1331) still holds
# a round: a wakeup not past `next + max(600, ttl/2)`, or a cron id not past its
# `until`. The same expiry bin/fleet_loop_mark.py applies, fork-free for the 4Hz
# path. (A fleet-loop.py ledger loop is stamped `looping` by the Stop hook, so the
# state already keeps it out of k; this only reads the mark.)
loop_live_v() { local v="$1" n t g e
  [ -n "$v" ] || return 1
  case "$v" in *next=*)
    n=${v#*next=}; n=${n%% *}; t=''
    case "$v" in *ttl=*) t=${v#*ttl=}; t=${t%% *} ;; esac
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    case "$n" in ''|*[!0-9]*) ;; *)
      g=$(( t / 2 )); [ "$g" -lt 600 ] && g=600
      [ $(( n + g )) -ge "$NOW" ] && return 0 ;;
    esac ;;
  esac
  case "$v" in *id=*)
    e=${v#*id=}; e=${e%% *}
    while [ -n "$e" ]; do
      t=${e%%,*}; t=${t##*@}
      case "$t" in ''|*[!0-9]*) ;; *) [ "$t" -ge "$NOW" ] && return 0 ;; esac
      case "$e" in *,*) e=${e#*,} ;; *) e='' ;; esac
    done ;;
  esac
  return 1
}

# @sleep_since → "z <age>" (issue #1051): how long a sleeping row has slept, so a
# stale sleeper reads as stale. The epoch is stamped by fleet-sleep.py's phase()
# — one window option, no sleep-record read per row. m/h/d only, so it fits the
# 8-cell act column; a missing/garbled stamp leaves the bare `z`. Sets $zage.
# The field may carry `:cap` (issue #1058: @sleep_wake_deferred rides the same
# column, so the count stays stable) — an automatic wake waiting for a slot;
# $zwait is then the row's `z · waiting for a slot` text.
zage_v() { zage=''; zwait=''
  case "$1" in *:cap) zwait=$(fleet_ui_t wait_slot) ;; esac
  set -- "${1%%:*}"
  case "$1" in ''|*[!0-9]*) return 0;; esac
  local d=$(( NOW - $1 )); [ "$d" -lt 0 ] && d=0
  if   [ "$d" -lt 3600 ];  then zage="z $(( d / 60 ))m"
  elif [ "$d" -lt 86400 ]; then zage="z $(( d / 3600 ))h"
  else                          zage="z $(( d / 86400 ))d"; fi
}

# @pin → 0/1 (issue #623). `1` is the ONLY pinned value; anything else — unset,
# 0, or a stray trailing field glued on by a future WFMT addition — is ordinary.
# Sets $pin; no subshells.
pin_v() { case "$1" in 1) pin=1 ;; *) pin=0 ;; esac; }

# @expand → 0/1 (the fold bit). A parent row's subtree is COLLAPSED BY DEFAULT, so
# the absent option must mean folded: `1` is the only expanded value and anything
# else — unset, 0, a stray field — folds. That polarity is the whole feature: a
# window that never heard of folding, and every freshly spawned parent, starts
# collapsed with no writer having to touch it. Sets $exp; no subshells.
exp_v() { case "$1" in 1) exp=1 ;; *) exp=0 ;; esac; }

# window → its OWN ledger key (issue #503): `issue-<N>` from @issue, else the
# `scratch-<N>` slug — read from @worktree FIRST and the pane cwd only as a
# fallback (issue #529). @worktree is stamped once at spawn and never moves; the
# cwd does, and a scratch whose Claude `cd`s into a subdir yields basename `docs`,
# no key, and so used to render as an un-addressable row with a blank id cell.
# That is the same @worktree-first rule fleet_origin_key already follows, so the
# two provenance readers no longer disagree about the same window.
# Same strict digits-only shape as fleet_scratch_key (both the bare `scratch-<N>`
# and the `<repo>-scratch-<N>` dir form) — inlined because $(fleet_scratch_key)
# would fork a subshell on the 4Hz hot path.
# Empty = not addressable as a spawn parent. Sets $okey; no subshells.
okey_v() { okey=''
  if [ -n "$1" ]; then okey="${okp}issue-$1"; return; fi
  local cand bn sn
  for cand in "$2" "$3"; do
    bn=${cand##*/}
    case "$bn" in
      scratch-*)   sn=${bn#scratch-} ;;
      *-scratch-*) sn=${bn##*-scratch-} ;;
      *)           continue ;;
    esac
    case "$sn" in ''|*[!0-9]*) continue;; *) okey="${okp}scratch-$sn"; return;; esac
  done
}

# the window's key PREFIX (issue #790) → $okp. Repo A's issue-12 and repo B's
# issue-12 are two different parents, so the key carries the repo:
# `<slug>:issue-<N>` — the spelling a spawn stamps into @origin (#789), in every
# fleet however many repos it hosts (issue #1939). @repo is read in the one
# list-windows format, so a stamped window costs no fork; an unstamped one falls
# back to the fleet's only repo (rslug_v, one fleet_repos a frame). Unknown (or
# @norepo) → `?:`, a key no @origin ever names: its row renders, nothing groups
# under it by guesswork.
# Takes the window's @repo + @norepo; resolution is rslug_v's (below), one rule for
# the PR cell and the grouping key.
okp=''
okp_v() { okp=''
  rslug_v "$1" "$2"                    # the window's repo slug, fork-free (#792)
  if [ -z "$rslug" ]; then
    rlist_v; [ "$RZERO" = 1 ] && return 0  # the fleet hosts NO repo: its keys stay bare
  fi
  if [ -n "$rslug" ]; then okp="$rslug:"; else okp='?:'; fi
}

# model → context window (FLEET_CTX_WINDOW; haiku 200k). The model short name was
# dropped from the row in #36, so only cwin is computed now.
model_v() {
  case "$1" in *haiku*) cwin=200000;; *) cwin=${FLEET_CTX_WINDOW:-200000};; esac; }

# The PR map is per REPO, never per fleet (issues #792, #1940): identity is
# (repo, branch), never the branch alone — two repos can each have an `issue-3`,
# and one per-fleet prmap would paint repo A's green check on repo B's unfinished
# work. So every window is looked up in its OWN repo's prmap (fleets/<slug>/prmap,
# deploy_<sha> beside it — issue #541), however many repos the fleet hosts (a
# one-repo fleet's sessmap slug IS its repo's slug, so that is the same file it
# always read), and the frame's haystack is keyed `<slug>\t<branch>` — ONE
# narrowed string per frame, built by ONE awk over the repos on screen, so #662's
# per-frame bound holds. The CONTENT is loaded after pass A, which is what collects
# the (repo, branch) pairs this frame actually needs. The window's repo is its
# @repo (pr-refresh stamps it via fleet_window_repo within a tick); `@norepo 1`
# has none; an unstamped window falls back to the fleet's ONLY repo, and in a 2+
# repo fleet is unknown → no PR cell, never a guess.
# The fleet's repo list is read ONCE a frame (rlist_v, EPIC #1935 rule 5), and
# only when some window needs it: RONLY = its only repo ('' for none / 2+),
# RZERO = 1 when it hosts none — and then RCSLUG is the collector's slug for the
# session (sessmap, builtins only), the caches such a fleet's windows read, as
# fleet_target_repo falls back to the collector's repo.
RLIST_DONE=0; RONLY=''; RZERO=0; RCSLUG=''
rlist_v() {
  [ "$RLIST_DONE" = 1 ] && return 0
  RLIST_DONE=1; RONLY=$(fleet_repos "${FLEET_SESSION:-}")
  [ -z "$RONLY" ] && { RZERO=1; RCSLUG=$(fleet_slug_cached "${FLEET_SESSION:-}"); }
  case "$RONLY" in *$'\n'*) RONLY='' ;; esac              # 2+ repos: no default
}
# window's @repo/@norepo → $rslug, its repo's cache slug ('' = no repo / unknown).
# fleet_repos (forks) runs at most once a frame, and only for an unstamped window.
rslug_v() { rslug=''
  [ "$2" = 1 ] && return
  local r=$1
  if [ -z "$r" ]; then rlist_v; r=$RONLY; fi
  [ -n "$r" ] || return
  r=${r//\//-}; rslug=${r//[^[:alnum:]._-]/}               # = fleet_slug, fork-free
}
# cslug_v <@repo> <@norepo> → $rslug, the slug whose caches (prmap, issues,
# deploy_<sha>) the window's PR cell and title read: rslug_v's, else — a fleet
# hosting no repo — the collector's (RCSLUG). Keys never use it (okp_v).
cslug_v() {
  rslug_v "$1" "$2"
  [ -z "$rslug" ] && [ "$2" != 1 ] && { rlist_v; rslug=$RCSLUG; }
  return 0
}

# ONE EPIC, ONE ROW (issue #1958). The window that drives a running EPIC carries
# @epic (fleet-epic-heartbeat.sh stamps its own pane every tick): `<owner/name>#<N>`,
# `#<N>` with no repo; a row from another machine carries its node's cell
# (the inventory's `epic=`, fleet-control-read.sh), `<ref>[:<landed>/<members>]`.
# epic_ref_v <cell> → $en (the EPIC's number), $eslug (its repo's cache slug, ''
# for none); 1 when the cell names no EPIC. Fork-free (the rslug_v spelling).
epic_ref_v() { en='' eslug=''
  local ref=${1%%:*} r
  en=${ref##*#}
  case "$ref:$en" in *'#'*:[0-9]*) ;; *) en=''; return 1 ;; esac
  case "$en" in *[!0-9]*) en=''; return 1 ;; esac
  r=${ref%#*}; r=${r//\//-}; eslug=${r//[^[:alnum:]._-]/}
}
# epic_v <@epic cell> <window id> <the row's title cell> → $en, $ettl (the parent
# issue's title: a local row's off the EPIC repo's issue cache, ITTL; a remote
# one's is its node's, the title cell), $ebadge (`landed/members`: a local row's
# off THIS batch's heartbeat mark — epic-running.d/<slug>-<N>, read with builtins
# only, so the frame forks nothing — a remote one's off its cell). All empty on
# every other row, which therefore renders byte for byte as before.
epic_v() { en='' ettl='' ebadge=''
  [ -n "$1" ] || return 0
  epic_ref_v "$1" || return 0
  local f k l m _l
  case "$2" in
    wid:*) ettl=$3
           case "$1" in *:*/*) ebadge=${1#*:} ;; esac
           case "$ebadge" in *[!0-9/]*) ebadge='' ;; esac ;;
    *) if [ -n "$eslug" ]; then
         k="$eslug"$'\t#'"$en"
         case "$ITTL" in *$'\n'"$k"$'\t'*) ettl=${ITTL#*$'\n'"$k"$'\t'}; ettl=${ettl%%$'\n'*} ;; esac
       fi
       f="$FLEET_CONF_DIR/global/epic-running.d/${eslug:-_}-$en"
       if [ -f "$f" ]; then
         l='' m=''
         while IFS= read -r _l || [ -n "$_l" ]; do
           case "$_l" in 'landed: '*) l=${_l#landed: } ;; 'members: '*) m=${_l#members: } ;; esac
         done < "$f"
         case "$l:$m" in *[!0-9:]*|:*|*:) ;; *) ebadge="$l/$m" ;; esac
       fi ;;
  esac
}

# The repos this dash shows (issue #793): every hosted one, under `all` (#1034).
# RMANY=1 only in a fleet hosting 2+ repos; then RHEADS is its group headings
# (fleet_dash_repo_frame, once a frame); a fleet hosting one repo counts RMANY=0.
# The shell (FLEET_SHELL=1, issue #1680) has no conf: its repos are the hub rows'
# own (fleet_dash_repo_frame reads the hub cache), so its list groups and folds
# like a 2+ repo fleet's. A node's dash outside the sidebar has no hub cache to
# read, which fleet_dash_repo_frame answers from one directory test.
RMANY=0; RGRPMAP=''; RHEADS=''; RNREPO=0
if [ "${FLEET_SHELL:-0}" != 1 ] || [ "$SIDEBAR" = 1 ]; then
  fleet_dash_repo_frame "${FLEET_SESSION:-}"
fi
# RGRP=1 iff this frame groups its rows by repo (issue #974): a 2+ repo fleet. A
# one-repo fleet never groups — its frame stays as it was, heading-free, byte
# for byte.
RGRP=$RMANY
RGCNT=()                               # rows per repo group, for the heading's (n)
NSESS=0                                # session rows this frame; 0 → the empty-state hint (#998)
ATTN=0                                 # rows on the list waiting on you (#1750)
# rgrp_v <@repo> <@norepo> → $rgrp, the window's OWN repo group (issues
# #793/#974), off its $rslug (rslug_v; keys are #790's okp_v, never re-qualified
# here): each hosted repo is its own group in fleet_repos order (RGRPMAP, one
# lookup, no fork), a window whose repo is not hosted is `?` (RNREPO), a no-repo
# session last. 0 whenever this frame does not group (RGRP=0), so a one-repo
# fleet never sees anything else — no fork, $rslug untouched.
rgrp_v() { rgrp=0
  [ "$RGRP" = 1 ] || return 0
  rslug_v "$1" "$2"
  if [ "$2" = 1 ]; then rgrp=$((RNREPO + 1))
  elif [ -n "$rslug" ]; then
    rgrp=${RGRPMAP#*$'\n'"$rslug"$'\t'}
    if [ "$rgrp" = "$RGRPMAP" ]; then rgrp=$RNREPO; else rgrp=${rgrp%%$'\n'*}; fi
  else rgrp=$RNREPO; fi
}
# RGTAG[g] — the short repo tag (issue #1031) a row wears when it renders in a
# group that is NOT its own: a cross-repo child follows its parent's group, whose
# heading then no longer names the child's repo. `⇢` + the first three characters
# of the repo's bare name (`⇢24h`, `⇢tok`); `⇢?` for an unhosted repo, `⇢none`
# for no repo. Built once a frame, only when the frame groups.
RGTAG=()
if [ "$RGRP" = 1 ]; then
  while IFS=$'\t' read -r _g _nm _; do
    [ -n "$_g" ] || continue; _nm=${_nm##*/}; RGTAG[_g]="⇢${_nm:0:3}"
  done <<< "$RHEADS"
  RGTAG[RNREPO]='⇢?'; RGTAG[RNREPO + 1]="$(fleet_ui_t repo_none_tag)"
fi

# branch → the three spellings the PR cell looks a row up by, in the order it
# tries them: the branch EXACTLY as the git cache has it, then with a trailing
# `+<ahead>` stripped, then with a trailing `-<behind>` stripped. Exact comes
# first because a real branch name can itself end in `-<digits>` (`issue-231`),
# and the old sed-strip wrongly ate that.
# ONE definition, used by BOTH the pass-A collector below and the render loop —
# they must agree on what a row's candidates are, or the frame's haystack would
# be missing the very line the loop then looks for.
prcands_v() { b1="$1"
  b2=$b1; case "$b2" in *-[0-9]|*-[0-9][0-9]|*-[0-9][0-9][0-9]|*-[0-9][0-9][0-9][0-9]) b2=${b2%-*};; esac
  b3=$b2; case "$b3" in *+[0-9]|*+[0-9][0-9]|*+[0-9][0-9][0-9]|*+[0-9][0-9][0-9][0-9]) b3=${b3%+*};; esac
}

# window cwd → the collector's cache key. Keep byte-identical to cache_key() in
# tmux-dash-collect.sh; pass A and the render loop both derive it.
ckey_v() { ckey=${1//_/_u}; ckey=${ckey//\//_s}; ckey=${ckey// /_w}; }

# List width, to right-align the PR/ctx block to the edge and give the flex
# span the full remaining width. Prefer fzf's own viewport width — FZF_COLUMNS is
# exported to reload/transform child procs (fzf ≥0.53) and is the TRUE list
# width. `tput cols </dev/tty` is unreliable here (it reads the client tty, not
# the pane), so it's only a fallback for the very first pre-fzf render before
# FZF_COLUMNS exists; 120 as a last resort. Keep a 2-col gutter + 2-col right
# margin so fzf never clips the ctx% digits. Layout column widths:
#   LEFTW  = glyph1+sp + issue5+sp + tree2+sp + window26+sp = 38   (tree: #836/#1328)
#   RIGHTW = act8+sp + PR7+sp + ctx4 = 21   (act = last-activity, issue #228)
# NB: LEFTW/ACTW/RIGHTW MUST stay in step with fleet-history.sh cmd_rows so the
# live list and the landed history list render the SAME aligned columns (#228).
COLS=${FZF_COLUMNS:-}
case "$COLS" in ''|*[!0-9]*) COLS=$( { tput cols </dev/tty; } 2>/dev/null );; esac
case "$COLS" in ''|*[!0-9]*) COLS=120;; esac
LEFTW=38; ACTW=8; RIGHTW=21; USABLE=$(( COLS - 4 ))
[ "$USABLE" -lt $(( LEFTW + RIGHTW + 1 )) ] && USABLE=$(( LEFTW + RIGHTW + 1 ))

# One tmux read, iterated twice (issue #503): pass A below builds the parent
# lookup table the grouping needs (a child can appear BEFORE its parent in window
# order); pass B renders. Herestring iteration, no extra forks.
WLIST=$(fleet_lw "$WFMT")
# tmux 3.4 escapes a control separator as the literal four bytes `\037`;
# newer versions return the byte. Accept both at the serialization boundary.
WLIST=${WLIST//\\037/$US}

# --- the other machines' sessions (issue #1423, EPIC #1419 C4) -----------------
# With the cross-machine hub on (CCQUOTA_FLEET=1), fleet-hub-sessions.sh keeps
# global/remote_<sess> — your sessions on the other machines, refreshed off the
# render path. Each becomes a WLIST line of the SAME shape as a local window's, so
# the nesting, folds, counts and sort below take it with no second code path:
#   window id  `wid:<worker_id>` — no tmux target, so every action that needs a
#              window (jump, menu, reap, rename, pin, fold) finds none: a remote
#              row is read-only, and its key (below) is the worker_id itself
#   index      90001+, after this machine's windows of the same rank (the
#              `status` order; the default born order reads the next one)
#   born       the session's birth (cache field 15, issue #1750: @born, else its
#              window_created, as the node reported it) — the one ruler this
#              machine's rows and the other machines' are ordered by
#   @wid       the machine the row is on (`m4`; sidebar field 9, drawn as the
#              row's `@m4` mark, #1780), `m4!` once that machine is lost — or the
#              hub itself has been silent longer than FLEET_HUB_SESSIONS_STALE
#              (60s; global/hub_ok, #1483): the row stays, dimmed, under its
#              machine's 失联 heading
#   @expand    THIS machine's word on it (issue #1749): a remote row's fold bit
#              lives here, never on the other machine — global/remote_fold_<sess>,
#              one expanded worker_id per line, written by dash-fold-toggle.sh.
#              Absent ⇒ collapsed, the local rows' polarity, so a client (where
#              EVERY row is remote) folds like a node does
# Off, or no cache: not one extra line, and no file read at all when off.
#   needs      the window's @claude_needs (cache field 10, #1475), so a remote
#              row's `!` says which — ask / perm / blocked — like a local one
# THE LIST FROM THE HUB (issue #1480, EPIC #1479 C1). The cache also carries THIS
# machine's rows (field 11 `local`=1, field 12 their live window id, #1480). With
# FLEET_SIDEBAR_SOURCE=hub the sidebar's row SET is the cache's, one source on
# every machine: a local row renders off its own tmux line — state, needs, glyph,
# fold, pin, Enter, byte for byte today's row — a local window the hub does not
# list is not a row (its own sidebar's window excepted, as the fold rule has it),
# a cached local row whose window is gone is not one either. Only WHICH rows is
# the hub's. The default, `local`, is today's path: the cache's local rows are
# skipped and this machine's rows come from tmux. Sidebar only — the hub list
# keeps its local rows; and with the hub off, or no cache, `hub` is `local`.
# THE HUB SILENT (issue #1483, EPIC #1479 C4): 入口通不通 is ONE word —
# global/hub_ok, written by fleet-hub-sessions.sh on every round that stood, read
# through fleet_status_hub_lost (fleet-status-lib.sh: the bar and the remote-row
# actions read the same file; a cache from before hub_ok is judged by its #ts).
# Lost ⇒ every other machine's row is 失联 (below, as before), and on the hub
# source this machine's rows come from tmux again — the local-source code, so a
# window opened or closed during the silence shows at once, and a row's state is
# its live tmux state as always: the hub's word on WHICH local rows exist is as
# old as its silence, this machine's tmux is not. The next round that stands
# rewrites hub_ok and the hub's row set is back — nothing to restart.
# The cache's header lines (#1475) feed the MACHINE STATUS LINE and the LOST
# GROUPS: `#me` this machine's label; one `#node` per other machine — label,
# online|lost, your session count there, the hub's last observation of it. A
# LOST row (its machine lost, or the whole cache stale) STAYS PUT (issue #1882):
# same group, same place, same parent — only dimmed, its `@m4!` mark and the
# bar's 入口连不上 / machine cell saying why. It used to move to its machine's
# own group at the foot (`─ m4 失联 ─`, #1475/#1770), so the list reshuffled the
# moment a network dropped and again when it came back.
HUBSRC=0; [ "$SIDEBAR" = 1 ] && [ "${FLEET_SIDEBAR_SOURCE:-local}" = hub ] && HUBSRC=1
if [ -n "${FLEET_SESSION:-}" ] && fleet_hub_on "$FLEET_SESSION" && [ -s "$G/remote_$FLEET_SESSION" ]; then
  RLIST=''; _rn=90000; _rstale=0; _rlostn=' '; _rrows=(); _lwids=' '
  # the remote rows' fold bits (issue #1749): the worker_ids opened on THIS machine
  _rexpd=$'\n'; [ -s "$G/remote_fold_$FLEET_SESSION" ] && _rexpd+="$(cat "$G/remote_fold_$FLEET_SESSION")"$'\n'
  # 失联 is decided ONCE, off global/hub_ok (#1483) — the cache's own #ts only
  # for a cache from before that file existed (fleet_status_hub_ok's fallback)
  # shellcheck disable=SC2034  # FLEET_STATUS_G is read by the lib sourced on the same line
  FLEET_STATUS_G="$G"; . "$BIN/fleet-status-lib.sh"
  fleet_status_remote_head "$FLEET_SESSION"; fleet_status_hub_ok "$FSR_TS"
  fleet_status_hub_lost "$NOW" && _rstale=1
  # `local` and `wid` (fields 11/12, #1480) are named so a new cache's needs field
  # stays its own; a cache older than #1480 leaves them empty. `via` (field 13,
  # #1488: hub | node) the same — empty reads as hub.
  # The orchestrating session (issue #1957) is no row: 「新任务」 wears it
  # (fleet-sidebar.py). Its worker_ids are fleet-hub-sessions.sh's orch_<sess>.
  _orchw=' '
  if [ -s "$G/orch_$FLEET_SESSION" ]; then
    while IFS=$US read -r _ow _; do [ -n "$_ow" ] && _orchw+="wid:$_ow "; done < "$G/orch_$FLEET_SESSION"
  fi
  while IFS=$US read -r r_wid r_node r_av r_iss r_repo r_state r_agent r_name r_orig r_needs r_local r_lwid r_via _r_busy r_born r_cfg r_ttl r_reap r_epic; do
    case "$_orchw" in *" $r_wid "*) continue ;; esac
    case "$r_wid" in
      '#ts'|'#me') continue ;;
      '#node') [ -n "$r_node" ] || continue
               # a machine heard over the shell's own connection (via=node — its
               # 6th field, #1488) is not lost for the hub's silence: it answered
               [ "$_rstale" = 1 ] && [ "$r_state" != node ] && r_av=lost
               [ "$r_av" = lost ] && _rlostn+="$r_node "
               continue ;;
      wid:*/*) ;;
      *) continue ;;
    esac
    if [ "$r_local" = 1 ]; then
      # this machine's own row (#1480): never a wid: line — its tmux line renders
      # it; on the hub source its window id is what keeps that line on the list
      [ "$HUBSRC" = 1 ] && [ -n "$r_lwid" ] && _lwids+="$r_lwid "
      continue
    fi
    [ "$_rstale" = 1 ] && [ "$r_via" != node ] && r_av=lost
    case "$_rlostn" in *" $r_node "*) r_av=lost ;; esac
    if [ "$r_av" = lost ]; then
      r_node="$r_node!"
    elif [ "$r_via" = node ]; then
      # taken over the machine's direct connection while the hub is silent
      # (#1488): `m5~` — the view ends the row in a dim `m5` (#1621), nothing else
      # about the row changes (its place, its nesting, its colour)
      r_node="$r_node~"
    fi
    _rrows+=("$r_wid$US$r_node$US$r_iss$US$r_repo$US$r_state$US$r_agent$US$r_name$US$r_orig$US$r_needs$US$r_born$US$r_cfg$US$r_ttl$US$r_reap$US$r_epic")
  done < "$G/remote_$FLEET_SESSION"
  for _rr in ${_rrows[@]+"${_rrows[@]}"}; do
    IFS=$US read -r r_wid r_node r_iss r_repo r_state r_agent r_name r_orig r_needs r_born r_cfg r_ttl r_reap r_epic <<< "$_rr"
    _rn=$((_rn + 1)); _rno=''; [ -n "$r_repo" ] || _rno=1   # no repo = @norepo
    _rexp=''; case "$_rexpd" in *$'\n'"${r_wid#wid:}"$'\n'*) _rexp=1 ;; esac
    RLIST+="$FLEET_SESSION$US$_rn$US$r_name$US$US$r_state$US$US$r_wid$US$r_iss$US$r_orig$US$US$r_agent$US${r_node:-?}$US$r_needs$US$_rexp$US$US$US$US$US$US$r_repo$US$_rno$US$US$US$US$US$r_born$US$r_cfg$US$r_ttl$US$r_reap$US$r_epic"$'\n'
  done
  unset _rrows _rr _rexpd _rexp
  WLIST="$RLIST$WLIST"
  if [ "$HUBSRC" = 1 ] && [ "$_rstale" != 1 ]; then
    # the hub source (#1480): of this fleet's own lines keep the windows the cache
    # names, the panels (they carry @repo_fold), the sidebar's own window and any
    # pinned / `@norepo` window (#1643, below); a remote line passes, another
    # session's line is pass B's to skip. Not while
    # the hub is silent (#1483): then every one of this fleet's own lines stays,
    # as on the local source — the cache cannot say which windows exist NOW.
    _hl=''
    while IFS= read -r _ln; do
      [ -n "$_ln" ] || continue
      case "$_ln" in "$FLEET_SESSION$US"*) ;; *) _hl+="$_ln"$'\n'; continue ;; esac
      # WFMT fields 3 (name), 7 (window id), 15 (@pin), 21 (@norepo)
      IFS=$US read -r _ _ _nm _ _ _ _w _ _ _ _ _ _ _ _pin _ _ _ _ _ _no _ <<< "$_ln"
      case "$_nm" in dash|plan|backlog|home) _hl+="$_ln"$'\n'; continue ;; esac
      case "$_w" in wid:*) _hl+="$_ln"$'\n'; continue ;; esac
      case "$_lwids" in *" $_w "*) _hl+="$_ln"$'\n'; continue ;; esac
      # a pinned or a no-repo window stays (issue #1643): the hub never lists one
      # — a `@norepo` session has no worker_id to report, and a pin is this
      # machine's own mark — so on the hub source the pinned guide (#1169) and
      # every `@norepo` session vanished from their own sidebar with the switch
      if [ "$_pin" = 1 ] || [ "$_no" = 1 ]; then _hl+="$_ln"$'\n'; continue; fi
      [ -n "${FLEET_SIDEBAR_CURRENT:-}" ] && [ "$_w" = "$FLEET_SIDEBAR_CURRENT" ] && _hl+="$_ln"$'\n'
    done <<< "$WLIST"
    WLIST=$_hl; unset _hl _ln _nm _w _pin _no
  fi
  unset _lwids
fi

# pass A — KEYTAB: one `<key>\t<rk>\t<seg>\t<pin>\t<exp>\t<rgrp>\t<origin>` line
# per addressable window (<seg>: its sort-path segment, seg_v — issue #1750),
# the parent-resolution table for the spawn-provenance
# grouping (#503), the pin bit a child inherits from its parent (#623), the
# @expand fold bit its children are hidden by, the subtree progress each parent
# row reports (#624), and the repo group a cross-repo child follows its root into
# (#1031). @origin stays LAST:
# pass B peels the row with `${x#*\t}`, so only the final field may contain no tab.
# The `_` placeholders after @worktree (@cc_agent since #547, @wid since #566)
# are load-bearing: `read` gives the LAST name all remaining fields, so without
# them $wt arrived as `<path><US><agent><US><handle>` and okey_v's strict
# `scratch-<digits>` test could never match a @worktree-stamped scratch — the
# #529 blind spot, reopened in pass A only (pass B reads every field by name).
# $pin (#623) is named for the same reason: this pass needs it; so are @repo/
# @norepo (#792), which trail WFMT, with a `_` to swallow @sleep_since, and
# @repo_fold (#1037) last — the session's folded repo groups, one value on every
# line of this fleet, taken off the first (panels included: a fleet whose only
# windows are panels still draws its `(0)` headings, folded or not).
KEYTAB=''; PRWANT=''; RSLUGS=' '; RFOLD=''; UNFIN=$'\n'
# The issue titles this frame needs (issue #1921, --sidebar only): a local row's
# (repo, #issue) key, looked up once below in its repo's issue cache.
ITWANT=''; ISLUGS=' '; DRIVEN=' '
while IFS=$US read -r sess idx name path state _ rwid iss origin wt _ _ nsub exp pin _ _ _ _ wrepo wnorepo _ rfold wloop _ wborn _ _ _ wepic; do
  [ -z "$name" ] && continue
  [ -n "${FLEET_SESSION:-}" ] && [ "$sess" != "$FLEET_SESSION" ] && continue
  RFOLD=$rfold
  case "$name" in dash|plan|backlog|home) continue;; esac
  rgrp_v "$wrepo" "$wnorepo"
  # Collect the branch spellings this frame will look up in the prmap (issue
  # #662) — BEFORE the okey filter below, because a window with no addressable
  # key still RENDERS in pass B and still gets a PR cell. Its only cost is the
  # same one-line git_ cache read pass B already does.
  ckey_v "$path"
  prbr=''; [ -f "$G/git_$ckey" ] && { IFS=$'\t' read -r prbr _ < "$G/git_$ckey" || :; }
  case "$prbr" in ''|-) ;; *)
    prcands_v "$prbr"
    cslug_v "$wrepo" "$wnorepo"         # (repo, branch) keys — issue #792
    if [ -n "$rslug" ]; then
      PRWANT+="$rslug"$'\t'"$b1"$'\n'"$rslug"$'\t'"$b3"$'\n'"$rslug"$'\t'"$b2"$'\n'
      case "$RSLUGS" in *" $rslug "*) ;; *) RSLUGS+="$rslug " ;; esac
    fi ;;
  esac
  if [ "$SIDEBAR" = 1 ]; then
    case "$rwid" in wid:*) ;; *) case "$iss" in ''|*[!0-9]*) ;; *)
      cslug_v "$wrepo" "$wnorepo"
      [ -n "$rslug" ] && { ITWANT+="$rslug"$'\t#'"$iss"$'\n'
                           case "$ISLUGS" in *" $rslug "*) ;; *) ISLUGS+="$rslug " ;; esac; } ;; esac ;;
    esac
  fi
  # A window still wearing an EPIC (issue #1916): its batch has a row of its own,
  # so no 「没人在跑」 row is drawn for it (ESTALE below).
  [ -n "$wepic" ] && DRIVEN+="${wepic%%:*} "
  # An EPIC driver's row (issue #1958) is named after its parent issue: that
  # title too, from the EPIC's own repo's cache — in the hub list as well.
  case "$rwid" in wid:*) ;; *)
    if [ -n "$wepic" ] && epic_ref_v "$wepic" && [ -n "$eslug" ]; then
      ITWANT+="$eslug"$'\t#'"$en"$'\n'
      case "$ISLUGS" in *" $eslug "*) ;; *) ISLUGS+="$eslug " ;; esac
    fi ;;
  esac
  okp_v "$wrepo" "$wnorepo"
  okey_v "$iss" "$wt" "$path"
  # A remote row: its worker_id (#1423). The row's id is `wid:<worker_id>`, its
  # origin the parent's `<worker_id>` bare — stripping the prefix HERE is what
  # makes the two spellings meet, so the origin slot stays bare (issue #1698:
  # a `wid:` added to it would match no KEYTAB key and flatten every chain).
  case "$rwid" in wid:*) okey=${rwid#wid:} ;; esac
  [ -z "$okey" ] && continue
  state_v "$state" "$nsub"; pin_v "$pin"; exp_v "$exp"; seg_v "$rk" "$idx" "$wborn" "$rwid"
  KEYTAB+="$okey"$'\t'"$rk"$'\t'"$seg"$'\t'"$pin"$'\t'"$exp"$'\t'"$rgrp"$'\t'"$origin"$'\n'
  # rank 1 is "quiet", not "finished" (issue #1331): a sleeper, a waking/preparing
  # worker, and a `done` window whose @loop still holds a pending round all sort
  # with done, but only a done window with NO Loop counts toward its parent's k/N.
  [ "$rk" = 1 ] && { [ "$state" != 'done' ] || loop_live_v "$wloop"; } && UNFIN+="$okey"$'\n'
done <<< "$WLIST"

# The PR haystack for THIS frame (issue #662). The render loop looks a branch up
# with `${PRMAPN#*$'\n'"$bare"$'\t'}` — a leading-`*` pattern match, which bash
# walks in time proportional to the string it is given, up to three times per row.
# Handed the whole prmap that made ONE FRAME cost O(prmap × windows): on a
# 6-window fleet with an 88-line prmap, 270ms of a 380ms frame, and it grew every
# time the repo landed a PR (a 2000-line prmap took 21s — bin/dash-rows-prmap-
# scale-selftest.sh). So the haystack is narrowed ONCE here, to just the lines
# whose branch some window on screen can actually ask for: one awk pass over the
# file, and the loop's own logic below is untouched — it simply scans a string
# that is now a handful of lines instead of kilobytes.
# PRWANT rides the ENVIRONMENT, not `-v`: awk processes escape sequences in a -v
# assignment, so a branch containing a backslash would arrive mangled and its row
# would silently lose its PR cell.
# One awk over every on-screen repo's prmap; each line comes out prefixed with
# its repo's slug (the dir it was read from), so the lookup key is (repo, branch).
PRMAPN=$'\n'
PRFILES=()
for _s in $RSLUGS; do [ -s "$FLEET_C/fleets/$_s/prmap" ] && PRFILES+=("$FLEET_C/fleets/$_s/prmap"); done
if [ "${#PRFILES[@]}" -gt 0 ] && [ -n "$PRWANT" ]; then
  PRMAPN=$'\n'$(PRWANT="$PRWANT" awk -F'\t' '
    BEGIN { n = split(ENVIRON["PRWANT"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    { d = FILENAME; sub(/\/prmap$/, "", d); sub(/.*\//, "", d); if ((d "\t" $1) in want) print d "\t" $0 }' \
    ${PRFILES[@]+"${PRFILES[@]}"} 2>/dev/null)
fi

# THE BATCHES NOBODY DRIVES (issue #1916, sidebar only). A heartbeat mark
# (epic-running.d/<slug>-<N>, fleet-epic-heartbeat.sh) gone stale while its EPIC
# is still OPEN — on the collector's open-issue list, looked up in the title
# haystack below, so a closed EPIC or an unread repo draws nothing — and no window
# wearing its @epic (DRIVEN): the loop that drove it stopped. THIS machine's marks
# are read here with builtins only (the frame forks nothing for them); another
# machine's come from its node, off the hub cache's epicstale_<sess>
# (fleet-hub-sessions.sh). Each becomes ONE grey row at the top of its repo's
# group, `#<N> <title>` badged 没人在跑, keyed `epicstale:<ref>[@<machine>]` — a tap
# asks to reopen its driver (fleet-sidebar.py). No stale mark ⇒ not one line more.
ESTALE=''                       # ref US machine US age US slug US N, one a line
# The shell (FLEET_SHELL=1) reads none here: every row there is a machine's, its
# marks too — they come off the hub cache like the rest.
if [ "$SIDEBAR" = 1 ] && [ "${FLEET_SHELL:-0}" != 1 ] && [ -d "$FLEET_CONF_DIR/global/epic-running.d" ]; then
  for _ef in "$FLEET_CONF_DIR/global/epic-running.d/"*; do
    [ -f "$_ef" ] || continue
    case "$_ef" in *.tmp.*) continue ;; esac
    _ee='' _et='' _en='' _er=''
    while IFS= read -r _l || [ -n "$_l" ]; do
      case "$_l" in 'epoch: '*) _ee=${_l#epoch: } ;; 'ttl: '*) _et=${_l#ttl: } ;;
                    'epic: '*) _en=${_l#epic: } ;; 'repo: '*) _er=${_l#repo: } ;; esac
    done < "$_ef"
    case "$_ee:$_en" in *[!0-9:]*|:*|*:) continue ;; esac   # a bare touch: a hand hold, never stale here
    case "$_et" in ''|*[!0-9]*|0) _et=${FLEET_EPIC_RUNNING_TTL:-2700} ;; esac
    case "$_er" in */*) ;; *) continue ;; esac
    case "$_er" in *[!A-Za-z0-9/._-]*) continue ;; esac
    [ $(( NOW - _ee )) -ge "$_et" ] || continue
    case "$DRIVEN" in *" $_er#$_en "*) continue ;; esac
    _es=${_ef##*/}; _es=${_es%-"$_en"}
    ESTALE+="$_er#$_en$US$US$(( NOW - _ee ))$US$_es$US$_en"$'\n'
    ITWANT+="$_es"$'\t#'"$_en"$'\n'
    case "$ISLUGS" in *" $_es "*) ;; *) ISLUGS+="$_es " ;; esac
  done
fi

# The issue-title haystack (issue #1921): one awk over each on-screen repo's
# issue cache (beside its prmap), narrowed to the keys pass A collected, `<key>\t<title>` a line. The cache line
# is `milestone\t#num\tassignee\ttitle`. No issue row on screen ⇒ no fork.
ITTL=$'\n'
if [ -n "$ITWANT" ]; then
  ITFILES=()
  for _s in $ISLUGS; do [ -s "$FLEET_C/fleets/$_s/issues" ] && ITFILES+=("$FLEET_C/fleets/$_s/issues"); done
  if [ "${#ITFILES[@]}" -gt 0 ]; then
    ITTL=$'\n'$(ITWANT="$ITWANT" awk -F'\t' '
      BEGIN { n = split(ENVIRON["ITWANT"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
      { d = FILENAME; sub(/\/issues$/, "", d); sub(/.*\//, "", d); k = d "\t" $2
        if (!(k in want)) next
        t = $0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", t); gsub(/[\t\r\037]/, " ", t)
        if (t != "") print k "\t" t }' ${ITFILES[@]+"${ITFILES[@]}"} 2>/dev/null)$'\n'
  fi
fi

# chain walk (issues #503/#623/#624, real depth since #1328): walk a parent KEY up
# to the ultimate LIVE root, collecting EVERY live ancestor on the way, so a
# grandchild nests under its real parent (not beside it under the root), each
# level folds on its own, and each level counts its own subtree.
# Sets, all as globals (no subshells — this runs per row at 4Hz):
#   ANC=n     ancestors found; A{K,I,P,E,G}[0..n-1] = key/seg/@pin/@expand/
#             repo group, [0] the parent, [n-1] the topmost one found
#   $croot    the root's key (= AK[n-1]); EMPTY ⇒ the chain is broken (a window
#             in it closed and the ledger does not know its parent, or it ran
#             past CHAIN_MAX hops) — an ORPHAN, which
#             sorts under the 9:99999 sink sentinel, still nested under whatever
#             of its chain IS live
#   $crootpin the root's @pin (0 if none); its @expand / repo group are
#             AE/AG[ANC-1]
#   $cpnlvl   level (index into A*) of the NEAREST pinned ancestor; '' if none.
#             Self is not considered here — the caller checks its own @pin first,
#             so a pinned row is always its own pin root (#623's rule, unchanged).
# Factored out of the render loop in #624 so the progress count and the grouping
# can never disagree about who a row belongs to: one walker for sort, fold,
# caret, pin, badge and the repo group (#1031).
# CHAIN_MAX bounds a cycle in @origin; depth DISPLAYS at most DEPTH_MAX levels
# (the indent stops growing), but the sort key keeps the whole path, so a
# deeper subtree still stays contiguous.
# A key NOT on this dash is a reaped window (issue #1352): before calling the chain
# broken, the walk asks the child-report ledger who that key's parent was
# (fleet_origin_map) and climbs on through it, so a grandchild whose middle window
# was reaped nests under the nearest LIVE ancestor — at the depth of the live
# levels only, no label. The skipped hop adds no A* entry. Only a key the ledger
# does not know (hub-spawned, cross-fleet, never reported) still breaks the chain.
# The map is read ONCE a frame, and only when some chain actually broke — and
# only the part of it this frame can reach (issue #1530): every key that gets
# here is a window's @origin (KEYTAB's last field, which both chain_v callers
# pass) or a parent climbed to from one through the map, so one awk walks those
# seeds up the map (≤ CHAIN_MAX hops, the bare-key fallback below included) and
# keeps just the lines it touched. The lookup below is unchanged; it is the
# string it scans that shrinks. A `${OMAP#*…}` scan of the whole 715-line ledger
# took ~160 ms on bash 3.2, 35 lookups a frame — 5.7 s of a 5.8 s sidebar.
CHAIN_MAX=16; DEPTH_MAX=4
AK=(); AI=(); AP=(); AE=(); AG=()
OMAP=''; OMAP_LOADED=0
lparent_v() { lpar=''
  if [ "$OMAP_LOADED" = 0 ]; then
    OMAP_LOADED=1
    local f
    [ -n "${FLEET_SESSION:-}" ] && f=$(fleet_origin_map "$FLEET_SESSION") \
      && [ -s "$f" ] && OMAP=$'\n'$(awk -F '\t' -v CM="$CHAIN_MAX" '
        FILENAME == "-" { if (NF >= 7 && $7 != "") s[$7] = 1; next }
        !($1 in m) { m[$1] = $2 }
        END {
          for (k in s) for (h = 0; h < CM; h++) {
            if (k in m) j = k
            else { b = k; sub(/^[^:]*:/, "", b); if (b == k || !(b in m)) break; j = b }
            if (!(j in o)) { o[j] = 1; print j "\t" m[j] }
            k = m[j]
          }
        }' - "$f" <<< "$KEYTAB")$'\n'
  fi
  [ -n "$OMAP" ] || return 1
  local m=${OMAP#*$'\n'"$1"$'\t'}
  if [ "$m" = "$OMAP" ] && [ "${1#*:}" != "$1" ]; then m=${OMAP#*$'\n'"${1#*:}"$'\t'}; fi
  [ "$m" = "$OMAP" ] && return 1
  lpar=${m%%$'\n'*}
  [ -n "$lpar" ]
}
chain_v() { croot=''; crootpin=0; cpnlvl=''; ANC=0
  local cur="$1" t m prow prest porig hop=0
  t=$'\n'"$KEYTAB"
  while [ "$ANC" -lt "$CHAIN_MAX" ] && [ "$hop" -lt "$CHAIN_MAX" ]; do
    hop=$((hop+1))
    m=${t#*$'\n'"$cur"$'\t'}
    if [ "$m" = "$t" ]; then                                 # not on this dash:
      lparent_v "$cur" || return                             # unknown ⇒ broken
      case "$lpar" in issue-*|scratch-*|*:issue-*|*:scratch-*) cur=$lpar; continue ;; esac
      return
    fi
    prow=${m%%$'\n'*}
    AK[ANC]=$cur
    prest=${prow#*$'\t'}                                      # (the rank: KIDTAB's)
    AI[ANC]=${prest%%$'\t'*}; prest=${prest#*$'\t'}
    AP[ANC]=${prest%%$'\t'*}; prest=${prest#*$'\t'}
    AE[ANC]=${prest%%$'\t'*}; prest=${prest#*$'\t'}
    AG[ANC]=${prest%%$'\t'*}; porig=${prest#*$'\t'}
    [ "${AP[ANC]}" = 1 ] && [ -z "$cpnlvl" ] && cpnlvl=$ANC
    ANC=$((ANC+1))
    case "$porig" in
      issue-*|scratch-*|*:issue-*|*:scratch-*|*/issue-*|*/scratch-*) cur=$porig ;;   # a child too — keep climbing
      *) croot=$cur; crootpin=${AP[ANC-1]}
         return ;;                                            # hub/autofill/none: the root
    esac
  done
}

# pass A2 — KIDTAB: one `\n<ancestor-key>\t<rk>\n` record per (window, live
# ancestor) pair, so EVERY row that spawned work reports its OWN subtree's
# progress (issue #624; per level since #1328): a grandchild counts toward its
# parent AND its grandparent, so the root's badge still sums the whole tree and
# a middle row's badge describes exactly the block indented beneath it. The
# attribution is chain_v's, the same walker the nesting sorts by. A window whose
# parent closed counts toward nobody (it has no live ancestor to count toward).
# Each record carries its OWN leading AND trailing newline: the counting
# substitutions in pass B replace non-overlapping matches, so records sharing one
# separator newline would count `\nA\t1\n` twice in a row as ONE.
KIDTAB=''
while IFS=$'\t' read -r kkey krk _ _ _ _ korig; do
  case "$korig" in issue-*|scratch-*|*:issue-*|*:scratch-*|*/issue-*|*/scratch-*) ;; *) continue ;; esac
  # quiet-but-unfinished (#1331): `1L` still counts toward the total, never the k
  case "$UNFIN" in *$'\n'"$kkey"$'\n'*) krk=1L ;; esac
  chain_v "$korig"
  _i=0
  while [ "$_i" -lt "$ANC" ]; do KIDTAB+=$'\n'"${AK[_i]}"$'\t'"$krk"$'\n'; _i=$((_i+1)); done
done <<< "$KEYTAB"

# RGFOLD[g]=1 — the repo groups this frame draws FOLDED (issue #1037): @repo_fold
# is the space-separated slugs of the folded groups (a repo's fleet_slug, `none`
# for the no-repo group), set by dash-fold-toggle.sh from ←/→ on a heading and
# UNSET once the last one opens — so a fleet nobody folded reads exactly as
# before. Resolved through RGRPMAP once a frame; a slug the fleet no longer
# hosts resolves to nothing and folds nothing. Only a grouping frame has
# headings to fold, so a one-repo fleet never reads it (RGRP=0).
RGFOLD=()
# The 置顶 group (issue #1170) folds through the same option, as the token `pin`
# (a repo slug is always `owner-name`, so it can never collide) — in a one-repo
# fleet too, where it is the only heading there is.
PGRP=-2; PINCNT=0; PINFOLD=0
# The shell's windows are proxies (no name in WFMT, so pass A never reads their
# line) and its rows are the hub's: the fold bit is read off its OWN session —
# one value per client, never per fleet (issue #1680). Only while it groups.
if [ "${FLEET_SHELL:-0}" = 1 ] && [ "$RGRP" = 1 ] && [ -n "${FLEET_SESSION:-}" ]; then
  RFOLD=$(tmux show-option -t "=$FLEET_SESSION:" -qv @repo_fold 2>/dev/null) || RFOLD=''
fi
case " $RFOLD " in *' pin '*) PINFOLD=1 ;; esac
if [ "$RGRP" = 1 ] && [ -n "$RFOLD" ]; then
  for _s in $RFOLD; do
    if [ "$_s" = none ]; then RGFOLD[RNREPO + 1]=1
    else
      _g=${RGRPMAP#*$'\n'"$_s"$'\t'}
      [ "$_g" = "$RGRPMAP" ] || RGFOLD[${_g%%$'\n'*}]=1
    fi
  done
fi

buf=""
# 配置旧 (issue #1783): the fingerprint a fresh session would get NOW, read once a
# frame — every row below is a compare against it, no fork.
fleet_cfg_expected_load; fleet_cfg_broken_load
CFG_STALE_T='' CFG_RENEW_T='' CFG_BROKEN_T=''
while IFS=$US read -r sess idx name path state state_ts wid iss origin wt agent hnd nsub exp pin qwait reap_due reap_seen reap_stamp wrepo wnorepo slept _ wloop wtitle wborn wcfg wittl wreap wepic; do
  [ -z "$name" ] && continue
  epic_v "$wepic" "$wid" "$wittl"
  # Is this session's configuration the one it would get now? A local row
  # compares its @agent_cfg (fleet_cfg_state); a row on another machine carries
  # that machine's own verdict (the hub cache's `cfg`, judged there against ITS
  # expected file). broken | stale | renew | ok | unknown — stale draws 配置旧, renew
  # 待换新 (issue #1895: the same configuration on an older fleet version), broken a
  # red 会坏·需重开 (issue #2076: its start names something the install no longer
  # has — fleet_cfg_broken_load's list, written by fleet-oldcfg-check.sh --sweep).
  case "$wid" in
    wid:*) case "$wcfg" in broken|stale|renew|ok) cfgst=$wcfg ;; *) cfgst=unknown ;; esac ;;
    *)     case "$wcfg" in */*) wver=${wcfg#*/}; wcfg=${wcfg%%/*} ;; *) wver='' ;; esac
           fleet_cfg_state "$agent" "$wcfg" "$wver" "$sess" "$wid"; cfgst=$FCFG_STATE ;;
  esac
  cfgf=''; [ "$cfgst" = unknown ] || cfgf="$US$cfgst"
  # The session's issue title (issue #1921): a row on another machine carries its
  # node's (the hub cache's `title`); a local one is looked up in ITTL above.
  # Only the sidebar emits it — field 14, after cfg (an empty field 13 when cfg is
  # unknown) — and only when there is one, so a row without is byte for byte as
  # before.
  if [ "$SIDEBAR" = 1 ]; then
    case "$wid" in
      wid:*) ;;
      *) wittl=$ettl                                  # an EPIC row: its title (#1958)
         case "$iss" in ''|*[!0-9]*) ;; *)
           _ik=''
           cslug_v "$wrepo" "$wnorepo"; [ -n "$rslug" ] && _ik="$rslug"$'\t#'"$iss"
           if [ -n "$_ik" ]; then
             case "$ITTL" in *$'\n'"$_ik"$'\t'*) wittl=${ITTL#*$'\n'"$_ik"$'\t'}; wittl=${wittl%%$'\n'*} ;; esac
           fi ;;
         esac ;;
    esac
    [ -z "$wittl" ] || cfgf="$US${cfgf#"$US"}$US$wittl"
    # field 15 (issue #1902): the session's @reap_policy, the view words it
    # (合并后回收 · 做完就回收 · 常驻 …); fields 13/14 stay, empty, before it. No
    # policy ⇒ no field, so an old window's row is byte for byte as before.
    case "$wreap" in ''|*[!A-Za-z0-9:.+-]*) ;; *)
      _c13=''; [ "$cfgst" = unknown ] || _c13=$cfgst
      cfgf="$US$_c13$US$wittl$US$wreap" ;;
    esac
  fi
  # strict per-fleet: only windows from the viewing dash's own tmux session.
  # FLEET_SESSION exported by tmux-dashboard.sh; unset ⇒ show all (single-fleet).
  [ -n "${FLEET_SESSION:-}" ] && [ "$sess" != "$FLEET_SESSION" ] && continue
  case "$name" in dash|plan|backlog|home) continue;; esac   # panels, not Claude sessions
  NSESS=$((NSESS + 1))                                 # a session row this frame (#998)
  # repo group (issues #793/#974) — the FIRST sort key: the row's OWN group here
  # (rgrp_v); a cross-repo child swaps in its root's once the chain walk below
  # has run (#1031), and the heading's count is taken there. Everything else is
  # group 0, so a one-repo fleet sorts exactly as before.
  rgrp_v "$wrepo" "$wnorepo"; ownrgrp=$rgrp
  # A row on another machine (issues #1423/#1475): @wid carries its machine
  # label — `m4`, `m4!` once that machine is lost, `m5~` when the row came over
  # the shell's direct connection to it (#1488). The label draws DIM at the
  # row's end; a lost row stays where it is, dimmed (issue #1882).
  rnode=''; rlost=''
  case "$wid" in wid:*)
    rnode=${hnd%[!~]}
    case "$hnd" in *!) rlost=1 ;; esac ;;
  esac
  ckey_v "$path"; key=$ckey
  ctxkey="$key"
  case "$agent" in
    codex:*) ctxkey="codex_${sess}_${wid}_${agent#codex:}"; agent=codex ;;
    codex) ctxkey="codex_unknown" ;; # older launcher: unknown, never Claude data
  esac

  branch='-'
  [ -f "$G/git_$key" ] && { IFS=$'\t' read -r branch _ < "$G/git_$key" || :; }

  state_v "$state" "$nsub"; pin_v "$pin"; exp_v "$exp"
  nmcol=$TX; { [ "$state" = idle ] || [ -z "$state" ]; } && nmcol=$GY
  [ -n "$rlost" ] && nmcol=$GY                        # a lost machine's row dims (#1475)

  # PR cell: look up the branch in prmap. The cache branch may carry +ahead/-behind
  # decorations; try EXACT first (real branch names can end in -digits, e.g.
  # issue-231 — the old sed-strip wrongly ate that), then decoration-stripped.
  # The key is prefixed with the window's repo slug, and its deploy_<sha> verdicts
  # come from that repo's dir (issue #792); no repo → '—'.
  ptxt='—'; pcol=$GY
  cslug_v "$wrepo" "$wnorepo"; rpfx="$rslug"$'\t'; rowdir="$FLEET_C/fleets/$rslug"
  if [ "$branch" != '-' ] && [ -n "$branch" ] && [ -n "$rslug" ]; then
    prcands_v "$branch"
    for bare in "$b1" "$b3" "$b2"; do
      tail=${PRMAPN#*$'\n'"$rpfx$bare"$'\t'}
      if [ "$tail" != "$PRMAPN" ]; then
        line=${tail%%$'\n'*}
        # line = #num\tstate\tci\tready\tsha. Parse each; ready / sha may be absent
        # on a stale 4-/5-field cache (mid-upgrade) — tab-guard so each degrades to ''.
        pnum=${line%%$'\t'*}   # "#num" — field 1, surfaced into the OPEN-PR cell
        rest=${line#*$'\t'}; st=${rest%%$'\t'*}; after=${rest#*$'\t'}
        ci=${after%%$'\t'*}; ready=''; msha=''
        case "$after" in *$'\t'*)
          ready=${after#*$'\t'}
          case "$ready" in *$'\t'*) msha=${ready#*$'\t'}; msha=${msha%%$'\t'*}; ready=${ready%%$'\t'*};; esac;;
        esac
        case "$st" in
          MERGED) pcol=$IN; ptxt="merged"
                  # merged ≠ live (issue #541): the deploy probe's verdict for this
                  # merge sha, when the fleet has one. 7 cells, single-cell glyphs.
                  dst=''
                  [ -n "$msha" ] && [ -f "$rowdir/deploy_$msha" ] && { read -r dst _ < "$rowdir/deploy_$msha" || :; }
                  case "$dst" in
                    live)      ptxt='live';    pcol=$GN;;   # merge sha is in the deployment
                    deploying) ptxt='deploy…'; pcol=$TX;;   # post-merge runs still going
                    failed)    ptxt='deploy✗'; pcol=$RD;;   # a post-merge run went red
                  esac;;
          CLOSED) pcol=$GY; ptxt="closed";;
          *) case "$ci" in
               ✓) pcol=$GN
                  # green: decorate by land-readiness (single-cell glyphs only —
                  # the metadata column is width-budgeted; no 2-cell emoji).
                  case "$ready" in
                    behind)   ptxt='✓↑'; pcol=$AM;;   # behind base → update-branch
                    conflict) ptxt='✓!'; pcol=$RD;;   # conflicting → rebase
                    blocked)  ptxt='✓·'; pcol=$AM;;   # mergeable+green but blocked
                    draft)    ptxt='✓d'; pcol=$GY;;   # a DRAFT — can't land; gh pr ready (#533)
                    unknown)  ptxt='✓?'; pcol=$TX;;   # mergeability not computed yet (#533)
                    *)        ptxt='✓';;              # land-ready (ready, or a 4-field cache)
                  esac;;
               ✗) pcol=$RD; ptxt="$ci";;
               …) pcol=$TX; ptxt="$ci";;
               *) pcol=$GY; ptxt="$ci";;
             esac
             # OPEN PR → prefix the number next to the glyph (e.g. #75✓, #75✓↑).
             # #<4-digit> + 2-cell readiness glyph = 7 = the fld 7 ceiling. All
             # these glyphs are single display cells so ${#}==width; prefix ONLY
             # when it fits, else keep the glyph (the land signal) glyph-only —
             # never let fld's right-clip eat the glyph on a huge PR number.
             [ $(( ${#pnum} + ${#ptxt} )) -le 7 ] && ptxt="$pnum$ptxt";;
        esac
        break
      fi
    done
  fi

  # model + ctx%
  cmodel=''; ctok=''; climit=''
  [ -f "$G/ctx_$ctxkey" ] && { IFS=$'\t' read -r cmodel ctok climit < "$G/ctx_$ctxkey" || :; }
  model_v "$cmodel"
  if [ "$agent" = codex ]; then
    case "$climit" in ''|*[!0-9]*|0) ctok='' ;; *) cwin="$climit" ;; esac
  fi
  pct='·'; pcolr=$GY
  case "$ctok" in
    ''|*[!0-9]*) : ;;
    *) pct=$(( ctok * 100 / cwin ))
       if   [ "$pct" -ge 80 ]; then pcolr=$RD
       elif [ "$pct" -ge 55 ]; then pcolr=$TX; fi
       pct="${pct}%";;
  esac

  # last-activity (issue #228): friendly "time since" from @claude_state_ts (epoch
  # re-stamped by the hooks/spinner/classifier on every state change). fleet_reltime
  # is pure-bash (no fork) so it stays on the hot path; NOW was computed once above.
  # No timestamp yet (a window that never took a turn) → a muted dot.
  fleet_reltime "$state_ts" "$NOW"; act=${reltime_out:-}
  acol=$GY; [ -z "$act" ] && act='·'
  # a sleeper's act cell is how long it has slept (issue #1051), not its last turn
  zwait=''
  if [ "$state" = sleeping ]; then zage_v "$slept"; [ -n "$zage" ] && act=$zage; fi
  # WHICH `!` this is (issue #1328): the five needs glyphs are one red `!` now,
  # so the kind moves into words — the hub's act cell, the sidebar's selected-row
  # line. @claude_needs is unchanged; only its display moved. One lookup per
  # kind a frame (fleet_ui_t forks), cached in ND_<kind>.
  ndet=''
  case "$state" in
    needs)  case "$nsub" in ask|perm|blocked|restore) _nk=$nsub ;; *) _nk=other ;; esac ;;
    failed) _nk=failed ;;
    exited) _nk=exited ;;
    *)      _nk='' ;;
  esac
  if [ -n "$_nk" ]; then
    eval "ndet=\${ND_$_nk-}"
    [ -n "$ndet" ] || { ndet=$(fleet_ui_t "needs_$_nk"); eval "ND_$_nk=\$ndet"; }
  fi
  # A fresh daemon notice is tied to this exact done turn. Activity invalidates
  # it immediately; a stopped daemon cannot leave a misleading permanent marker.
  if [ "$state" = "done" ] && [ "$reap_stamp" = "$state_ts" ]; then
    case "$reap_due:$reap_seen" in
      # Held (issue #1156): the PR merged/closed but the bound issue is still
      # open, so cleanup will NOT reap — continue the task or close the issue.
      hold:*[!0-9]*|hold:) : ;;
      hold:*) if [ "$reap_seen" -le "$NOW" ] && [ "$((NOW - reap_seen))" -le 180 ]; then
                act='iss open'; acol=$AM
              fi ;;
      *[!0-9:]*|:*|*:) : ;;
      *) if [ "$reap_seen" -le "$NOW" ] && [ "$((NOW - reap_seen))" -le 180 ]; then
           remain=$(( (reap_due - NOW + 59) / 60 )); [ "$remain" -ge 0 ] || remain=0
           act="r${remain}m"; acol=$AM
         fi ;;
    esac
  fi

  # --- internal window handle (issue #566) -----------------------------------
  # Keep @wid for CLI targeting (`reap a1` / `migrate b3`); the list identifies
  # tasks by their user-supplied names. Backfilled here (the render sees every window on
  # every tick) for anything that has none — a window that predates #566, or a
  # spawn whose allocator failed open. fleet_wid_stamp is idempotent + lock-held,
  # so this costs its handful of forks ONCE per window's life, never per tick,
  # and can never hand the same handle to two windows.
  if [ -z "$hnd" ]; then hnd=$(fleet_wid_stamp "$wid" "${FLEET_SESSION:-}") || hnd=''; fi

  # --- the issue cell (issues #529/#566) --------------------------------------
  # ISSUE-ONLY since #566: `#<N>` in GREEN for an issue-bound worker, BLANK for a
  # scratch. Live scratches are identified by their task descriptions.
  # (#502's finding still holds and is still honoured in the LANDED view,
  # where a closed row has no live window and `~<N>` IS its only id — see
  # fleet-history.sh cmd_rows.) The scratch slot number stays findable: it names
  # the worktree dir and still renders in the `↳~76` provenance tag.
  okp_v "$wrepo" "$wnorepo"
  okey_v "$iss" "$wt" "$path"
  # A remote row (issue #1423) is keyed by its worker_id; its machine is $rnode
  # (above), drawn dim at the row's end (#1475).
  case "$wid" in wid:*) okey=${wid#wid:} ;; esac
  issd=''; icol=$GN
  case "$okey" in issue-*|*:issue-*|*/issue-*) issd="#${okey##*issue-}" ;; esac
  # --- spawn provenance (issue #503) -----------------------------------------
  # The hierarchy is said by POSITION alone (issue #1328): a child sorts right
  # under its real parent and indents one level per generation. The old `↳#483` /
  # `↳~12` parent tag — and the `↳autofill` / `↳bridge` source word — are gone:
  # the indent already says the first, and the second was noise on every line.
  # The parent's history is still in /fleet-history.
  #
  # $treed is the fixed 2-cell TREE COLUMN between issue and window (issue #836,
  # 2 cells since #1328): `└ ` a first-level child, ` └` a second, `┊└` third and
  # deeper; a row that owns a subtree swaps its free cell for the fold caret
  # (`▾ ` a root, `└▾`, ` ▾`, `┊▾`). The name keeps all 26 of its cells.
  dname=$name; treed=''
  [ -n "$en" ] && dname="#$en${ettl:+ $ettl}"           # an EPIC row (issue #1958)
  # agent tag (issue #547): a window running a non-Claude agent (@cc_agent, stamped
  # by bin/fleet-codex.sh) shows its agent name in the flex span — a Claude window
  # carries no @cc_agent and draws nothing. ASCII only, so the ${#tagd} width math
  # below stays exact.
  agentd=''
  case "$agent" in ''|claude) : ;; *) agentd="${agent//[^A-Za-z0-9_-]/}" ;; esac
  # sort key: the row's PATH (issue #1328) — one segment per live ancestor
  # (seg_v: `<born>:<id>` by default since issue #1750, so siblings keep their
  # birth order whatever their state; `<rk>:<idx>` under FLEET_DASH_ORDER=status,
  # which the rest of this note describes) — one `<rk>:<idx>` segment per live
  # ancestor, root first, then its own, `/`-joined and zero-padded so a plain
  # byte sort puts every subtree contiguously under its parent, siblings in the
  # (rank, idx) order roots have always had. A root's path is its own segment —
  # exactly the old (grk, gidx, depth, rk, idx) order for a one-level tree. A
  # broken chain (a window in it closed) is an ORPHAN: the `9:99999/` sentinel
  # sinks it below every live group, still nested under what IS live of its chain.
  #
  # PIN (issue #623) is a tier ABOVE all of that: `pinned` (0 = pinned, 1 =
  # ordinary) sorts before the path, so a pinned window outranks every unpinned one
  # whatever its status. The bit rides the SAME ancestor chain — pinning a parent
  # takes its children up with it, or the pin strands them as orphans:
  #   • the ultimate live ROOT is pinned → the whole tree is pinned and keeps its
  #     nesting — the everyday case;
  #   • otherwise the nearest pinned ancestor-or-SELF becomes the tree's top for
  #     sorting: its path starts there, so it floats with its own descendants still
  #     nested under it. A row that is its own pin root sheds the └ indent: its
  #     parent is no longer the line above, and indenting under an unrelated row is
  #     a lie.
  seg_v "$rk" "$idx" "$wborn" "$wid"; gpath=$seg
  depth=0; pinned=1; ANC=0; croot=''; top=0
  if [ "$pin" = 1 ]; then pinned=0
  else
    case "$origin" in
      issue-*|scratch-*|*:issue-*|*:scratch-*|*/issue-*|*/scratch-*)   # `/`: a remote worker_id (#1423)
        chain_v "$origin"
        top=$ANC                               # levels kept above this row
        if [ "$crootpin" = 1 ]; then pinned=0
        elif [ -n "$cpnlvl" ]; then pinned=0; top=$((cpnlvl + 1)); fi
        depth=$top
        _i=0
        while [ "$_i" -lt "$top" ]; do
          gpath="${AI[_i]}/$gpath"; _i=$((_i+1))
        done
        [ "$pinned" = 1 ] && [ -z "$croot" ] && gpath="9:99999/$gpath" ;;
    esac
  fi
  # --- subtree progress (issue #624) ------------------------------------------
  # A row that SPAWNED work reports its subtree: `3/5` = 3 of its 5 descendants
  # done — at EVERY level (issue #1328), counted off KIDTAB with the fork-free
  # length-delta idiom (one substitution per figure, no subshell) so the 4Hz hot
  # path keeps its exec budget. Just the two numbers: the old trailing `✓` was
  # there on every parent whatever its state, and the loud `· 1!` is gone too — a
  # child that needs you is the red `!` on its OWN row, which no fold hides.
  # A row with no children draws NOTHING — the dash's quiet layer must not grow a
  # badge on every line.
  kidd=''; carg=''
  if [ -n "$okey" ]; then
    kn=$'\n'"$okey"$'\t'; kt=${KIDTAB//"$kn"/}
    ktot=$(( (${#KIDTAB} - ${#kt}) / ${#kn} ))
    if [ "$ktot" -gt 0 ]; then
      kn=$'\n'"$okey"$'\t1'$'\n'; kt=${KIDTAB//"$kn"/}    # rk 1 = done
      kdone=$(( (${#KIDTAB} - ${#kt}) / ${#kn} ))
      kidd="$kdone/$ktot"
      # fold caret — ONLY on a row that has a subtree, so the quiet layer still
      # doesn't grow a mark on every line. It reads this row's OWN @expand,
      # because this row is the one ←/→ toggles; every row the fold above can hide
      # renders under such a row.
      if [ "$exp" = 1 ]; then carg='▾'; else carg='▸'; fi
    fi
  fi
  [ -n "$ebadge" ] && kidd=$ebadge                    # an EPIC row: landed/members (#1958)
  # --- @title_info: the worker pane's header line (issue #1377) --------------
  # What the sidebar's selected-row line used to say, moved to where there is
  # room: the worker pane's top border (conf/tmux-attention.conf reads
  # #{@title_info} and nothing else). Plain text, ` · `-joined, most important
  # first so a narrow pane truncates the tail: subtree k/N, why a ↻ waits, the
  # Loop's next round, which `!`, the parent. Computed HERE — before the folds —
  # so a folded row's header stays current; written only when it changed, and
  # UNSET when every segment is empty, so a lone worker's header is byte for byte
  # the old ` name #issue `. Parent = @origin as stamped (#1352's nearest-live
  # ancestor replaces it when that lands).
  tinfo=''
  [ -n "$kidd" ] && { [ -n "${TL_kids-}" ] || TL_kids=$(fleet_ui_t title_kids); tinfo="$TL_kids $kidd"; }
  if [ "$state" = looping ]; then
    case ",$nsub," in *,children,*)
      [ -n "${WD_children-}" ] || WD_children=$(fleet_ui_t wait_children)
      tinfo="${tinfo:+$tinfo · }$WD_children" ;;
    esac
    case ",$nsub," in *,bg,*)
      [ -n "${WD_bg-}" ] || WD_bg=$(fleet_ui_t wait_bg)
      tinfo="${tinfo:+$tinfo · }$WD_bg" ;;
    esac
  fi
  _lp=0; loop_live_v "$wloop" && _lp=1
  [ "$state" = looping ] && case ",$nsub," in *,loop,*) _lp=1 ;; esac
  if [ "$_lp" = 1 ]; then
    _ln=''
    case "$wloop" in *next=*) _ln=${wloop#*next=}; _ln=${_ln%% *} ;; esac
    case "$_ln:$TZOFF" in
      *[!0-9:-]*|:*|*:)
         [ -n "${TL_loop-}" ] || TL_loop=$(fleet_ui_t title_loop)
         tinfo="${tinfo:+$tinfo · }$TL_loop" ;;
      *) _ln=$(( (_ln + TZOFF) % 86400 )); [ "$_ln" -lt 0 ] && _ln=$((_ln + 86400))
         [ -n "${TL_loopf-}" ] || TL_loopf=$(fleet_ui_t title_loop_fmt '%02d:%02d')
         printf -v _ln "$TL_loopf" $((_ln / 3600)) $((_ln % 3600 / 60))
         tinfo="${tinfo:+$tinfo · }$_ln" ;;
    esac
  fi
  if [ -n "$ndet" ]; then
    if [ "$_nk" = other ]; then tinfo="${tinfo:+$tinfo · }$ndet"
    else
      [ -n "${TL_needs-}" ] || TL_needs=$(fleet_ui_t title_needs)
      tinfo="${tinfo:+$tinfo · }$TL_needs$ndet"
    fi
  fi
  case "$origin" in
    issue-*|scratch-*|*:issue-*|*:scratch-*)
      _po=${origin##*:}; case "$_po" in issue-*) _po="#${_po#issue-}" ;; esac
      [ -n "${TL_parent-}" ] || TL_parent=$(fleet_ui_t title_parent)
      tinfo="${tinfo:+$tinfo · }$TL_parent $_po" ;;
  esac
  if [ "$tinfo" != "$wtitle" ] && [ -z "$rnode" ]; then
    if [ -n "$tinfo" ]; then tmux set-option -wq -t "$wid" @title_info "$tinfo" 2>/dev/null
    else tmux set-option -wqu -t "$wid" @title_info 2>/dev/null; fi
  fi
  # --- the 置顶 group: every pinned row, above every repo group (issue #1170) ---
  # A row in the pin tier (`pinned`=0 — it carries @pin, or floats with a pinned
  # ancestor) leaves its repo group for ONE group at the very top, headed
  # `置顶 (n)` and closed by a thin rule, so the tier is said by WHERE the row
  # sits, never by a mark on it. Its group key is PGRP (-2), below every repo
  # group and the empty-state hint (-1), and the only negative one a row ever
  # gets — which is why the fold test below never indexes RGFOLD with it. Its
  # rows do not count toward their repo heading: `(n)` is still the rows that
  # render under it. In a 2+ repo fleet the heading above no longer names a
  # repo, so a pinned row wears its repo tag — #1031's rule, applied as written.
  # --- repo group: a child FOLLOWS ITS PARENT (issue #1031) ---------------------
  # A nested row renders in the repo group of the top of the tree it renders in
  # — the same attribution the sort, fold, caret and badge take off chain_v — or
  # it would land in its own repo's group with a `└` under an unrelated row,
  # folded away by a caret that sits in another group. Where the group is not the
  # row's own, a short repo tag says so — the heading above no longer names its
  # repo. Counted HERE, once the group is resolved and still BEFORE the fold
  # filter, so a heading's `(n)` is the rows that render under it, a collapsed
  # parent's hidden ones too.
  repod=''
  if [ "$pinned" = 0 ]; then
    rgrp=$PGRP; PINCNT=$((PINCNT + 1))
    [ "$RGRP" = 1 ] && repod=${RGTAG[ownrgrp]-}
  elif [ "$RGRP" = 1 ]; then
    [ "$depth" -gt 0 ] && rgrp=${AG[depth-1]}
    [ "$rgrp" != "$ownrgrp" ] && repod=${RGTAG[ownrgrp]-}
    RGCNT[rgrp]=$(( ${RGCNT[rgrp]:-0} + 1 ))
  fi
  # --- repo fold: a folded heading hides its whole group (issue #1037) --------
  # ←/→ on a repo heading fold and unfold the group under it — the per-repo
  # focus now that the picker is gone (#1034). The SAME two rails as the parent
  # fold below, on purpose: a `needs` row (`rk`=0) never folds away — the quiet
  # layer folds, the loud one does not — and the sidebar keeps its current
  # window on the list. Counted already (RGCNT above), so the heading's `(n)`
  # still says how many rows it is hiding; NSESS too, so a fully folded frame
  # never draws the empty-state hint. The group is the row's RENDERED one — a
  # cross-repo child folds with the parent it renders under (#1031), a pinned
  # row with the 置顶 heading (#1170), which folds in a one-repo fleet too.
  gfold=0
  if [ "$pinned" = 0 ]; then gfold=$PINFOLD
  elif [ "$RGRP" = 1 ]; then gfold=${RGFOLD[rgrp]:-0}; fi
  if [ "$gfold" = 1 ] && [ "$rk" != 0 ] && [ "${FLEET_ROWS_UNFOLD:-0}" != 1 ] &&
     { [ "$SIDEBAR" = 0 ] || [ "$wid" != "${FLEET_SIDEBAR_CURRENT_ROW:-${FLEET_SIDEBAR_CURRENT:-}}" ]; }; then
    continue
  fi
  # --- fold: a collapsed holder hides its subtree, level by level --------------
  # Default-collapsed (the @expand polarity in exp_v): a nested row survives here
  # only if EVERY ancestor it renders under is expanded (issue #1328 — each level
  # folds on its own; before, only the root's bit counted). Rails that keep it
  # from hiding anything the operator needs:
  #   • only `depth>0` rows can hide — the ones drawn indented under a row above.
  #     A root, a closed parent's child and a row promoted to its own pin root all
  #     carry depth 0 and are never touched, so nothing can vanish with no visible
  #     parent to expand it back from; and every ancestor a row renders under owns
  #     a subtree, so it carries a caret to unfold from;
  #   • `rk != 0` — a row in `needs` (the red `!`) is EXEMPT and stays on the list
  #     whatever the folds say, under its real parent. The dash's whole job is
  #     surfacing the row that is waiting on you: the quiet layer folds, the loud
  #     one never does;
  #   • the sidebar's current window is never hidden from itself.
  # FLEET_ROWS_UNFOLD=1 (issue #1903) skips both fold filters: ⌘P
  # (fleet-quickopen.py) lists every session, a folded one too.
  # Hiding is a RENDER filter only: KIDTAB was counted in pass A2 over every window,
  # so a collapsed parent's `3/5` badge still describes its whole subtree — which
  # is exactly what makes the fold safe to have on by default.
  if [ "$depth" -gt 0 ] && [ "$rk" != 0 ] && [ "${FLEET_ROWS_UNFOLD:-0}" != 1 ] &&
     { [ "$SIDEBAR" = 0 ] || [ "$wid" != "${FLEET_SIDEBAR_CURRENT_ROW:-${FLEET_SIDEBAR_CURRENT:-}}" ]; }; then
    _i=0; _hid=0
    while [ "$_i" -lt "$depth" ]; do
      [ "${AE[_i]}" = 1 ] || { _hid=1; break; }; _i=$((_i+1))
    done
    [ "$_hid" = 1 ] && continue
  fi
  # a row on the list that is waiting on you (rk 0: needs / failed) — the born
  # order's summary line counts it (issue #1750) — a lost machine's row too: the
  # list keeps every line it had while a network is down (issue #1882), and the
  # question is still waiting there once the line is back
  [ "$rk" = 0 ] && ATTN=$((ATTN + 1))
  tagd="$repod"
  [ -n "$agentd" ] && tagd="${tagd:+$tagd }$agentd"
  # repo badge (issue #793): DROPPED under `all` (issue #995) — the only frame
  # that ever drew it is the grouped one (#974), where the heading above already
  # names the row's repo. A one-repo fleet never had one.
  # A request retrying on the same reason past FLEET_FAILOVER_STUCK_ATTEMPTS is
  # stamped @quota_stuck, which WFMT folds in as a `stuck:` prefix (issue #872):
  # it reads `⚠ stuck`, not the ordinary `quota:waiting` it would otherwise be.
  # memguard (issue #1292) SIGKILLed a command in this window for a memory spike;
  # @mem_killed rides the same WFMT field as a `mem:` prefix, so the row says so
  # (`⚠ mem·137` — the exit code the session saw) without one more field or fork.
  # The degenerate watchdog (issue #1557) pressed Esc on this window's runaway
  # output: @degenerate_ts rides the same field as a `degen=<epoch>:` prefix, and
  # the row ends in `⟲` for FLEET_DEGENERATE_MARK_SECS (30 min) after it.
  degd=''
  case $qwait in degen=*:*)
    degv=${qwait%%:*}; degv=${degv#degen=}; qwait=${qwait#*:}
    case $degv in ''|*[!0-9]*) ;; *)
      [ $(( NOW - degv )) -lt "${FLEET_DEGENERATE_MARK_SECS:-1800}" ] 2>/dev/null && degd='⟲' ;;
    esac ;;
  esac
  [ -n "$degd" ] && tagd="${tagd:+$tagd }$degd"
  case $qwait in mem:*) qwait=${qwait#mem:}; tagd="${tagd:+$tagd }⚠ mem·137" ;; esac
  # memguard rule C (issue #1297): this window's claude/codex session itself has
  # grown past FLEET_CLAUDE_RSS_WARN_MB. `fat=<size>:` on the same field; the badge
  # names the size (`⚠ mem 4.3G`) — the notification carries the /fleet-handoff line.
  case $qwait in fat=*:*) fatv=${qwait%%:*}; qwait=${qwait#*:}; tagd="${tagd:+$tagd }⚠ mem ${fatv#fat=}" ;; esac
  # The hub reached the handoff line (issue #1319): the Stop hook never blocks the
  # operator's own seat, it stamps @ctx_warn and notifies once — `ctxw:` here.
  case $qwait in ctxw:*) qwait=${qwait#ctxw:}; tagd="${tagd:+$tagd }⚠ ctx" ;; esac
  case $qwait in
    '') ;;
    stuck:*) tagd="${tagd:+$tagd }⚠ stuck" ;;
    *) tagd="${tagd:+$tagd }quota:${qwait%%:*}" ;;
  esac

  # the tree cell (issues #836/#1328): 2 cells, the level said by WHERE the `└`
  # sits — left for a first-level child, right for a second, `┊└` deeper — and a
  # row that owns a subtree trades its free cell (or its `└`, from the second
  # level down) for the caret. A root with no subtree: blank.
  case "$depth" in
    0) treed=${carg:+$carg }; treed=${treed:-'  '} ;;
    1) treed="└${carg:- }" ;;
    2) treed=" ${carg:-└}" ;;
    *) treed="┊${carg:-└}" ;;
  esac
  if [ "$SIDEBAR" = 1 ]; then
    # The view lays the row out to its own width (issue #1328), so the producer
    # hands it the PIECES, never a pre-joined label: the name, the tree prefix,
    # the subtree badge, the nesting depth, and the needs detail. The view
    # right-aligns the badge and clips the NAME (with `…`) — a narrow pane gives
    # up name, never the count. Stable window IDs survive renumbering between
    # draw/click.
    #   tree   = 2 cells of indent per level past the first, then `└`, then the
    #            caret when the row owns a subtree (`└▾`); a root: its caret or blank
    #   detail = what kind of `!` this is (ask / perm / blocked / restore /
    #            failed) — the view shows it under the list for the selected row
    if [ "$depth" -gt 0 ]; then
      _d=$depth; [ "$_d" -gt "$DEPTH_MAX" ] && _d=$DEPTH_MAX
      printf -v treed '%*s└%s' $(( (_d - 1) * 2 )) '' "$carg"
    else treed=$carg; fi
    label="$dname"
    [ -n "$repod" ] && label="$label $repod"       # cross-repo child (#1031)
    [ -n "$zwait" ] && label="$label · ${zwait#z · }"
    [ -n "$degd" ] && label="$label $degd"           # #1557: output degenerated, Esc sent
    [ "$depth" -gt "$DEPTH_MAX" ] && depth=$DEPTH_MAX
    # WHY a ↻ row is idle-but-unfinished (issue #1370): the needs field carries
    # @claude_wait on a `looping` window (WFMT), and the selected-row line says it —
    # `等子任务 k/N` with this row's own subtree badge. Sidebar only: the hub's act
    # cell is the red `!` column, and a ↻ is not one.
    if [ -z "$ndet" ] && [ "$state" = looping ]; then
      case ",$nsub," in
        *,children,*) [ -n "${WD_children-}" ] || WD_children=$(fleet_ui_t wait_children)
                      ndet="$WD_children${kidd:+ $kidd}" ;;
        *,bg,*)       [ -n "${WD_bg-}" ] || WD_bg=$(fleet_ui_t wait_bg); ndet=$WD_bg ;;
        *,tool,*)     [ -n "${WD_tool-}" ] || WD_tool=$(fleet_ui_t wait_tool); ndet=$WD_tool ;;   # #1880
      esac
    fi
    # field 9 (issue #1475): the machine of a row on another machine — `m4`,
    # `m4!` when lost, `m5~` when heard over the shell's own connection (#1488)
    # — empty for a local row. The view ends the row in it as `@m4` (`@本机` for
    # the client's own computer, issue #1780); `!` dims the row too.
    # fields 10-12 (issue #1532): the hub's issue · PR · ctx% cells, bare text
    # (`#1532` · `#1552✓` · `45%`; `—` / `·` when there is none). The view draws
    # them only while its info column is open (⌃i), right-aligned.
    # field 13 (issue #1783): `stale` / `renew` / `ok` / `broken` — whether the
    # session's configuration is the one it would get now; the view draws a yellow
    # 配置旧 left of the @ mark on a stale one, 待换新 on a renew one (issue #1895),
    # a red 会坏·需重开 on a broken one (issue #2076). Absent when unknown, so a login with no expected file
    # (or a session from before #1782) emits its rows byte for byte as before.
    buf+="$rgrp	$pinned	$gpath	$wid$US$state$US$gl$US$label$US${treed:- }$US$kidd$US$depth$US$ndet$US${rnode:+$hnd}$US$issd$US$ptxt$US$pct$cfgf"$'\n'
    continue
  fi
  # full row: glyph1·issue5·tree2·window26·⟨flex: tags, badge⟩·act8·PR7·ctx4
  # the tree cell carries the hierarchy, so the window column holds the NAME and
  # nothing else and every name starts at the same column. act/PR/ctx right-align
  # to the edge, the flex gap between them absorbing the width so the metadata
  # block stays pinned right. The flex span used to carry the LLM one-liner
  # (summary column, retired in issue #535); the agent/repo/mem tags and the
  # #624 subtree-progress badge live there now.
  fld 5  "$issd"; f_iss=$fld_out
  # window column (issue #534): pad/clip by DISPLAY width, not code points. A CJK
  # name is the everyday case now that the prompt line NAMES a scratch, and a CJK
  # glyph is 2 cols — fld()'s ${#} pad gave `修复仪表盘` (10 cols) 17 spaces and
  # shoved the right-pinned act/PR/ctx block over. ASCII stays on fld()'s
  # fork-free path; only a non-ASCII name pays the one perl/wcwidth fork.
  case "$dname" in
    *[![:ascii:]]*) fleet_clip_display 26 "$dname"
                    printf -v f_name '%s%*s' "${clip_out:-}" $(( 26 - ${clip_w:-0} )) '' ;;
    *)              fld 26 "$dname"; f_name=$fld_out ;;
  esac
  # the act cell of a `!` row names WHICH `!` it is (issue #1328: the five needs
  # glyphs are one now). Its text is CJK in zh — padded by display width, which
  # for these all-wide-or-all-ASCII words is ${#} plus one per non-ASCII char.
  if [ -n "$ndet" ]; then
    _a=${ndet//[![:ascii:]]/}; _w=$(( ${#ndet} * 2 - ${#_a} ))
    [ "$_w" -le "$ACTW" ] && { printf -v f_act '%s%*s' "$ndet" $(( ACTW - _w )) ''; acol=$RD; } \
      || { fld "$ACTW" "$act"; f_act=$fld_out; }
  else fld "$ACTW" "$act"; f_act=$fld_out; fi
  fld 7  "$ptxt"; f_pr=$fld_out
  fld 4  "$pct";  f_pct=$fld_out
  # the flex span draws the tags (#547/#1031/#1292), then the #624 progress
  # badge; the tags are ASCII and the badge digits, so ${#} is the display width
  # of both and the pad keeps act/PR/ctx pinned right.
  # (fld() shares the same ${#}=chars assumption; its remaining inputs — issue/PR/
  #  ctx — are ASCII. The window column, where CJK names are ordinary since #534,
  #  takes the width-aware path above.)
  tagpfx=''; dwidth=0
  [ -n "$tagd" ] && { tagpfx="${IN}${tagd}${R}"; dwidth=${#tagd}; }
  [ -n "$kidd" ] && { [ -n "$tagpfx" ] && { tagpfx+=' '; dwidth=$((dwidth+1)); }
                      tagpfx+="${GY}${kidd}${R}"; dwidth=$(( dwidth + ${#kidd} )); }
  # An automatic wake held at the session limit (issue #1058) says so here.
  [ -n "$zwait" ] && { [ -n "$tagpfx" ] && { tagpfx+=' '; dwidth=$((dwidth+1)); }
                       tagpfx+="${AM}${zwait}${R}"; dwidth=$(( dwidth + ${#zwait} )); }
  # 配置旧 (issue #1783), amber, just before the @ mark: the session runs an older
  # configuration than a fresh one would get (fleet_cfg_state above).
  # 待换新 (issue #1895) the same way: same configuration, older fleet version.
  # 会坏·需重开 (issue #2076) in RED: its start names something the install no
  # longer has — it will fail, not merely lack a feature.
  if [ "$cfgst" = stale ] || [ "$cfgst" = renew ] || [ "$cfgst" = broken ]; then
    _cc=$AM
    if [ "$cfgst" = stale ]; then
      [ -n "$CFG_STALE_T" ] || CFG_STALE_T=$(fleet_ui_t sidebar_cfg_stale)
      _ct=$CFG_STALE_T
    elif [ "$cfgst" = broken ]; then
      [ -n "$CFG_BROKEN_T" ] || CFG_BROKEN_T=$(fleet_ui_t sidebar_cfg_broken)
      _ct=$CFG_BROKEN_T; _cc=$RD
    else
      [ -n "$CFG_RENEW_T" ] || CFG_RENEW_T=$(fleet_ui_t sidebar_cfg_renew)
      _ct=$CFG_RENEW_T
    fi
    _a=${_ct//[![:ascii:]]/}
    [ -n "$tagpfx" ] && { tagpfx+=' '; dwidth=$((dwidth+1)); }
    tagpfx+="${_cc}${_ct}${R}"; dwidth=$(( dwidth + ${#_ct} * 2 - ${#_a} ))
  fi
  # A row on another machine ends its tags in that machine's `@m4` (issue #1780,
  # the sidebar's mark): `@m4!` once it is lost (the row dims too), `@m5~` heard
  # over the shell's own connection. This machine's own rows carry none.
  if [ -n "$rnode" ]; then
    [ -n "$tagpfx" ] && { tagpfx+=' '; dwidth=$((dwidth+1)); }
    tagpfx+="${GY}@${hnd}${R}"; dwidth=$(( dwidth + 1 + ${#hnd} ))
  fi
  pad=$(( USABLE - LEFTW - dwidth - RIGHTW )); [ "$pad" -lt 1 ] && pad=1
  printf -v gap '%*s' "$pad" ''
  # tree cell: exactly two cells of source text. Like the old caret it is a
  # CONSTANT width, not a ${#} count: `└`/`▸`/`▾`/`┊` are East-Asian AMBIGUOUS,
  # so a CJK-wide terminal may draw them 2 cells; folding the cell into the fixed
  # LEFTW keeps the right-pinned act/PR/ctx block put whatever the terminal measures.
  disp="${gc}${gl}${R} ${icol}${f_iss}${R} ${GY}${treed}${R} ${nmcol}${f_name}${R} ${tagpfx}${gap}${acol}${f_act}${R} ${pcol}${f_pr}${R} ${pcolr}${f_pct}${R}"

  buf+="$rgrp	$pinned	$gpath	$sess:$idx$US$wid$US$disp"$'\n'
done <<< "$WLIST"

# column header — pinned at top of the list by fzf --header-lines=1. Same
# right-aligned layout as the rows: leading "  " fills the glyph(1)+space slot, the
# blank tree cell (#836) adds two more spaces after the issue column, the flex span
# is blank, act/PR/ctx pinned right. Underlined muted-grey to read as a rule.
if [ "$SIDEBAR" = 0 ]; then
fld 5  "issue";  h_i=$fld_out
fld 26 "window"; h_n=$fld_out
fld "$ACTW" "act"; h_a=$fld_out
fld 7  "PR";     h_p=$fld_out
fld 4  "ctx";    h_c=$fld_out
h_pad=$(( USABLE - LEFTW - RIGHTW )); [ "$h_pad" -lt 1 ] && h_pad=1
printf -v h_gap '%*s' "$h_pad" ''
printf '%s\n' "hdr${US}hdr${US}${GYU}  ${h_i}    ${h_n} ${h_gap}${h_a} ${h_p} ${h_c}${R}"
fi

# The batches nobody drives (issue #1916, ESTALE above): this machine's when its
# EPIC's title is in the open-issue haystack (= still open), then each other
# machine's off the hub cache (`<ref> US <machine> US <online|lost> US <age> US
# <title> US <local>`; local rows are the marks read above). One per EPIC.
if [ "$SIDEBAR" = 1 ]; then
  _eseen=' '; _erows=''
  while IFS=$US read -r _ref _ _eage _es _en; do
    [ -n "$_ref" ] || continue
    _k="$_es"$'\t#'"$_en"
    case "$ITTL" in *$'\n'"$_k"$'\t'*) _et=${ITTL#*$'\n'"$_k"$'\t'}; _et=${_et%%$'\n'*} ;; *) continue ;; esac
    _eseen+="$_ref "
    _erows+="$_ref$US$US$_eage$US$_et"$'\n'
  done <<< "$ESTALE"
  if [ -n "${FLEET_SESSION:-}" ] && [ -s "$G/epicstale_$FLEET_SESSION" ] && fleet_hub_on "$FLEET_SESSION"; then
    while IFS=$US read -r _ref _enode _eav _eage _et _eloc; do
      case "$_ref" in */*'#'[1-9]*) ;; *) continue ;; esac
      [ "$_eloc" = 1 ] && continue
      case "$_eseen$DRIVEN" in *" $_ref "*) continue ;; esac
      case "$_eage" in ''|*[!0-9]*) _eage=0 ;; esac
      [ "$_eav" = lost ] || { [ "${_rstale:-0}" = 1 ] && _eav=lost; }
      [ "$_eav" = lost ] && _enode="$_enode!"
      _eseen+="$_ref "
      _erows+="$_ref$US$_enode$US$_eage$US$_et"$'\n'
    done < "$G/epicstale_$FLEET_SESSION"
  fi
  if [ -n "$_erows" ]; then
    [ -n "${ES_BADGE-}" ] || ES_BADGE=$(fleet_ui_t sidebar_epic_stale)
    while IFS=$US read -r _ref _enode _eage _et; do
      [ -n "$_ref" ] || continue
      _er=${_ref%#*}; _en=${_ref##*#}
      rgrp_v "$_er" ''
      _ed=$(fleet_ui_t sidebar_epic_stale_detail_fmt "$(( _eage / 60 ))")
      buf+="$rgrp	1	0	epicstale:$_ref${_enode:+@${_enode%!}}${US}epicstale${US}○${US}#$_en${_et:+ $_et}${US} ${US}$ES_BADGE${US}0${US}$_ed${US}$_enode${US}#$_en"$'\n'
    done <<< "$_erows"
  fi
  unset _eseen _erows _ref _enode _eav _eage _et _eloc _er _en _es _k _ed
fi

# the 置顶 group's frame (issue #1170): a `置顶 (n)` heading above the pinned rows
# and ONE thin rule below them, the pin tier's only mark — no row carries one.
# Both exist only while a row is pinned, so a fleet with no pin renders byte for
# byte as before; a one-repo fleet gets them too (it has no other heading). The
# heading is drawn the way a repo heading is (the sidebar's dim bold hdr row,
# the hub's IN purple) and its fold target is `pin` — the sidebar's `hdr:pin`
# key, the hub's 4th field — so ←/→ fold it like one (#1037); `pin` names no
# repo, so a new session started from it keeps the fleet's default. The rule is
# an inert hdr row with BOTH key fields `hdr` (the sidebar's state field empty):
# no count, no cursor stop, no fold, no bind. It is #998's one deliberate
# exception — headings still draw no `──` of their own; this line closes the
# pinned block, where the tier would otherwise run straight into the list. The
# sidebar's rule is longer than any pane and the view clips it to its width;
# the hub's is the list's own width, in the column header's grey.
if [ "$PINCNT" -gt 0 ]; then
  t=$(fleet_ui_t pin_heading_fmt "$PINCNT"); [ "$PINFOLD" = 1 ] && t="▸ $t"
  printf -v rule '%*s' $(( USABLE > 200 ? USABLE : 200 )) ''; rule=${rule// /─}
  if [ "$SIDEBAR" = 1 ]; then
    buf+="$PGRP	-1	0	hdr${US}pin$US$US$t$US "$'\n'
    buf+="$PGRP	2	0	hdr$US$US$US$rule$US "$'\n'
  else
    buf+="$PGRP	-1	0	hdr${US}hdr${US}${IN}${t}${R}${US}pin"$'\n'
    buf+="$PGRP	2	0	hdr${US}hdr${US}${GY}${rule:0:USABLE}${R}"$'\n'
  fi
fi

# group headings (issue #974): under `all` in a 2+ repo fleet, one INERT row opens
# each repo group — `tokenledger (1)`: the repo's bare name
# (owner/name only for two hosted repos sharing one, fleet_repo_name; issue
# #995 — the sidebar is 30 columns and the old `to · owner/name` never fit). Every
# HOSTED repo gets its heading even with nothing running — `tokenledger (0)`
# (issue #998), so an idle repo still has a place to start work in; the `?` and
# `no repo` groups exist only while a window is in them, so theirs hide at 0. Its
# sort key is (group, -1): above every row of its group whatever their pin tier.
# Both of its key fields read `hdr`, the marker every dash bind target (enter, ⌃x,
# ⌃p, ⌃o, fold, pin, rename, answer, migrate) and the sidebar already treat as
# not-a-row, so no key acts on it. Both surfaces draw it bare, no `── ` rule
# (issue #998, operator call: the purple / dim-bold paint already sets it apart).
# Each heading carries its spawn target — owner/name, `none` for `no repo`, ''
# for `?` — the one thing the new-session path may read (EPIC #994, issue #997):
# the sidebar in its otherwise-unused state field, the hub in a 4th field fzf
# never shows (--with-nth=3) and only its ⌃s/⌃n/Enter binds pass on, as
# `{2}:{4}` — field 2 is a session row's window id (`@12`) and a heading's `hdr`;
# field 1 is the `sess:idx` jump target, which the resolver does not read (#1010).
# Both key fields stay `hdr`, so every other bind still ignores it — except ←/→
# (issue #1037): dash-fold-toggle.sh reads that same 4th field (the sidebar its
# `hdr:<target>` key) and folds the group, and a FOLDED heading wears the
# parent rows' `▸` — `▸ tokenledger (2)`, its count still the rows it hides. An
# open one is drawn exactly as before. One pass over the repos —
# the per-window cost is the RGCNT increment above, and #662's per-frame bound
# holds.
if [ "$RGRP" = 1 ]; then
  hd_v() { local n=${RGCNT[$1]:-0} t tg=${4-$3}
    [ "$n" -gt 0 ] || [ -n "$3" ] || return 0
    t="$2 ($n)"
    [ "${RGFOLD[$1]:-0}" = 1 ] && t="▸ $t"
    if [ "$SIDEBAR" = 1 ]; then
      buf+="$1	-1	0	hdr$US$tg$US$US$t$US "$'\n'
    else
      buf+="$1	-1	0	hdr${US}hdr${US}${IN}${t}${R}${tg:+$US$tg}"$'\n'
    fi
  }
  while IFS=$'\t' read -r g nm rp; do
    [ -n "$g" ] && hd_v "$g" "$nm" "$rp"
  done <<< "$RHEADS"
  hd_v "$RNREPO" "$(fleet_ui_t unknown_repo_heading)" ''
  hd_v "$((RNREPO + 1))" "$(fleet_ui_t no_repo)" '' none
fi

# --- the other machines (issues #1475, #1882) -------------------------------
# No heading of their own: a lost machine's rows stay in their own groups,
# dimmed (above) — a `─ m4 失联 ─` group at the foot made the whole list move
# when a network dropped (issue #1882). Which machine is lost, or that the hub
# is unreachable, is the bar's machine cell and each row's `@m4!` mark.

# 要你处理 (issue #1750): in the born order a `needs` / `failed` row no longer
# rises to the top — it stays where it was born, red — so ONE summary line above
# everything (the 置顶 group included) says how many there are, `! 2 个在问你 ·
# 点这里跳过去 ⌃K`; a tap on it, the sidebar's ⌃k (on an empty input line) and
# prefix k (issue #1771) walk onto them in list order, and the view follows. No
# such row, no line: it never takes a row of its own for nothing. A `hdr` row,
# never a cursor stop; the sidebar paints it red off its glyph field `!` and
# knows it by that (is_attn_summary). The `status`
# order has no line — the rows themselves still rise — so it stays byte for byte.
if [ "$ORDER" = born ] && [ "$ATTN" -gt 0 ]; then
  if [ "$SIDEBAR" = 1 ]; then
    t=$(fleet_ui_t attn_summary_fmt "$ATTN")
    buf+="-3	-1	0	hdr$US$US!$US$t$US "$'\n'
  else
    t=$(fleet_ui_t attn_summary_dash_fmt "$ATTN")
    buf+="-3	-1	0	hdr${US}hdr${US}${RD}${t}${R}"$'\n'
  fi
fi

# the empty state (issue #998): a frame with no session row says so, and how to
# start one, in ONE inert `hdr` row at the top — never a blank list under the
# column header. The hub list spells out both ways in (the query line, the
# new-task key off dash-keymap.sh); the 30-column sidebar keeps it short, its
# input line sits right below. Only an empty frame pays the keymap fork.
if [ "$NSESS" = 0 ]; then
  if [ "$SIDEBAR" = 1 ]; then
    t=$(fleet_ui_t empty_sidebar)
    buf+="-1	-1	0	hdr$US$US$US$t$US "$'\n'
  else
    DASH_GLYPH_NEW='⌃n'; eval "$(bash "$BIN/dash-keymap.sh" env 2>/dev/null)"
    t=$(fleet_ui_t empty_dash_fmt "$DASH_GLYPH_NEW")
    buf+="-1	-1	0	hdr${US}hdr${US}${GY}  ${t}${R}"$'\n'
  fi
fi

# emit by repo group first (issues #793/#974: each hosted repo's rows in their own
# group under `all`, no-repo sessions at the foot; everything else is group 0, so
# a one-repo fleet sorts exactly as before; the 置顶 group, PGRP, heads them all —
# issue #1170), then pinned-first (issue #623), then grouped by spawn provenance (issue #503):
# pinned windows (and the subtrees that float with them) take the whole top of the
# list whatever their status; below them, roots (hub/autofill/bridge spawns) keep
# the status-rank order they always had; each root's children sort directly below
# it, each child's own children directly below IT (the path key, issue #1328 —
# a byte sort, hence LC_ALL=C); orphans — children whose parent window closed —
# sink below every live group. Pins sort AMONG themselves by the same path, so
# the pinned block is the ordinary list in miniature.
printf '%s' "$buf" | LC_ALL=C sort -t'	' -k1,1n -k2,2n -k3,3 \
| while IFS='	' read -r _ _ _ line; do
  [ -z "$line" ] && continue
  printf '%s\n' "$line"
done
if [ "$TIMEIT" = 1 ] && [ -n "${T0:-}" ]; then
  printf '#took %d\n' "$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null) - T0 ))"
fi
