#!/bin/bash
# tmux-dashboard-rows.sh — emit rows for the interactive dash (fzf), GROUPED by
# status with aligned (display-width-correct) columns.
# Line format:  <sess:idx>US<window-id>US<colored display>
#   field1 = jump target · field2 = stable summary key (window-id) · field3 = display
# Data: @claude_state (no LLM), everything slow from collector caches.
# (DASH_COMPACT mode retired with the 2026-07 fork-free rewrite.)
#
# HOT PATH (2026-07-07): this runs on every dash repaint (4×/s) — the loop is
# exec-fork-free (bash builtins only: read/expansion instead of cat/cut/sed/awk).
# Execs per render: tmux + sort + perl(sub-second clock) + one fleet_cache slug
# lookup ≈ 4. ~30ms total. (The #566 @wid backfill adds a handful of forks for a
# window that carries no handle yet — once in that window's life, not per tick.)
set -uo pipefail
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"   # ${#s} must count chars, not bytes
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"   # fleet_cache: route prmap through THIS fleet's slug'd cache
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
G="$C/global"                       # machine-wide caches (git_/ctx_) — issue #181

# live⇄landed view toggle (dash ⌃t writes $C/dash_view_<session>, per-fleet). In
# LANDED mode this producer hands off to the history ledger's row emitter, so
# finished (merged + cleaned-up) sessions are one keystroke away with the same row
# ergonomics (#130). Keyed by FLEET_SESSION so one fleet's toggle can't flip
# another's dash (they share $C); FLEET_SESSION is exported by tmux-dashboard.sh.
if [ "$(cat "$G/dash_view_${FLEET_SESSION:-default}" 2>/dev/null)" = landed ]; then
  exec bash "$BIN/fleet-history.sh" rows
fi

E=$'\033['
CY="${E}38;2;125;207;255m"; RD="${E}38;2;247;118;142m"; GN="${E}38;2;158;206;106m"
IN="${E}38;2;187;154;247m"; GY="${E}38;2;86;95;137m";  TX="${E}38;2;169;177;214m"
AM="${E}38;2;224;175;104m"   # amber — green PR that isn't land-ready (behind/blocked)
R="${E}0m"; US=$'\x1f'
# @pin (issue #623) is LAST on purpose: both passes below read it with `read`'s
# last-name-takes-the-rest rule, so a field appended AFTER it would arrive glued to
# the pin value. A new field goes BEFORE @pin, or pin_v's strict `1` test silently
# reads every pinned window as unpinned. @claude_needs (#640) and @expand (the
# fold bit) are the two newest such fields and sit exactly there, ahead of @pin,
# for that reason.
# Keep the column count stable. Codex's agent cell carries an exact cache suffix;
# the display loop separates it before drawing the ordinary `codex` tag.
WFMT="#{session_name}${US}#{window_index}${US}#{window_name}${US}#{pane_current_path}${US}#{@claude_state}${US}#{@claude_state_ts}${US}#{window_id}${US}#{@issue}${US}#{@origin}${US}#{@worktree}${US}#{?#{==:#{@cc_agent},codex},codex:#{@cc_launcher_pid}_#{@codex_session_id},#{@cc_agent}}${US}#{@wid}${US}#{@claude_needs}${US}#{@expand}${US}#{@pin}"

# pad/truncate a plaintext string to N DISPLAY chars (locale-aware ${#}) → $fld_out
fld() { local w="$1" s="$2" n=${#2}
  if [ "$n" -gt "$w" ]; then fld_out="${s:0:$w}"
  else printf -v fld_out "%s%*s" "$s" $((w-n)) ''; fi; }

# working glyph rotates: quarter-second frames from perl HiRes (macOS date has
# no %N and /bin/bash 3.2 no EPOCHREALTIME) — one frame per 4Hz repaint. The same
# tick doubles as the fork-free NOW (epoch seconds) for the activity column:
# perl's time()*4 ÷ 4 == floor(now), so no extra `date` fork on the hot path; the
# no-perl fallback reads whole seconds from `date` (one fork, as before).
SPINF='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
TICK=$(perl -MTime::HiRes=time -e 'printf "%d", time()*4' 2>/dev/null)
if [ -n "$TICK" ]; then NOW=$(( TICK / 4 )); else TICK=$(date +%s); NOW=$TICK; fi
FRAME=${SPINF:$(( TICK % 10 )):1}

# state → color/glyph/rank (set vars; no subshells)
# $2 is the `needs` SUBTYPE (@claude_needs, issue #640) and splits the red glyph
# into the two reflexes it really stands for — #605 shipped the answerer without
# this and the operator was left guessing which red row it applied to:
#
#   ?  an open AskUserQuestion  → ⌃k answers it from here, no attach
#   ⊘  an open permission prompt → only a human may approve one; ⌃k shows you WHAT
#                                  is blocked (bin/fleet-permission.sh) so you can
#                                  decide before walking over
#   !  undifferentiated (the classifier's verdict, an unrecognised Notification)
#   ⊠  the worker declared a blocker → read the issue and send a new prompt
#
# All four are ONE display cell, like every other state glyph: the row's leading
# "${gc}${gl}${R} " slot is a fixed width the right-pinned act/PR/ctx block is
# padded against, so a 2-cell emoji here (🔒) would shear every red row.
state_v() { case "$1" in
  needs)   gc=$RD; rk=0; case "${2:-}" in ask) gl='?';; perm) gl='⊘';; blocked) gl='⊠';; *) gl='!';; esac;;
  done)    gc=$GN; gl='✓';      rk=1;;
  working) gc=$CY; gl=$FRAME;   rk=2;;
  looping) gc=$IN; gl='↻';      rk=3;;
  *)       gc=$GY; gl='·';      rk=4;;
esac; }

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
  if [ -n "$1" ]; then okey="issue-$1"; return; fi
  local cand bn sn
  for cand in "$2" "$3"; do
    bn=${cand##*/}
    case "$bn" in
      scratch-*)   sn=${bn#scratch-} ;;
      *-scratch-*) sn=${bn##*-scratch-} ;;
      *)           continue ;;
    esac
    case "$sn" in ''|*[!0-9]*) continue;; *) okey="scratch-$sn"; return;; esac
  done
}

# model → context window (FLEET_CTX_WINDOW; haiku 200k). The model short name was
# dropped from the row in #36, so only cwin is computed now.
model_v() {
  case "$1" in *haiku*) cwin=200000;; *) cwin=${FLEET_CTX_WINDOW:-200000};; esac; }

# This fleet's PR map — slug-resolved for THIS dash's own session (issue #180:
# all fleets equal, no privileged "primary" flat mirror). The row loop below
# strictly filters to FLEET_SESSION, so one slug'd cache is exactly this fleet's
# PR status and can never be another fleet's; fleet_cache's flat name is only a
# cold-start fallback before the slug'd .ts marker lands.
# Only the PATH is resolved here — the CONTENT is loaded after pass A, which is
# what collects the branches this frame actually needs (issue #662).
_pf=$(fleet_cache prmap "${FLEET_SESSION:-}")
# deploy_<sha> files (issue #541) live beside the prmap they were derived from.
PRDIR=${_pf%/*}

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
#   LEFTW  = glyph1+sp + id3+sp + issue5+sp + window22+sp = 35   (id = @wid, issue #566)
#   RIGHTW = act8+sp + PR7+sp + ctx4 = 21   (act = last-activity, issue #228)
# NB: LEFTW/ACTW/RIGHTW MUST stay in step with fleet-history.sh cmd_rows so the
# live list and the landed history list render the SAME aligned columns (#228).
COLS=${FZF_COLUMNS:-}
case "$COLS" in ''|*[!0-9]*) COLS=$( { tput cols </dev/tty; } 2>/dev/null );; esac
case "$COLS" in ''|*[!0-9]*) COLS=120;; esac
LEFTW=35; ACTW=8; RIGHTW=21; USABLE=$(( COLS - 4 ))
[ "$USABLE" -lt $(( LEFTW + RIGHTW + 1 )) ] && USABLE=$(( LEFTW + RIGHTW + 1 ))

# One tmux read, iterated twice (issue #503): pass A below builds the parent
# lookup table the grouping needs (a child can appear BEFORE its parent in window
# order); pass B renders. Herestring iteration, no extra forks.
WLIST=$(tmux list-windows -a -F "$WFMT")
# tmux 3.4 escapes a control separator as the literal four bytes `\037`;
# newer versions return the byte. Accept both at the serialization boundary.
WLIST=${WLIST//\\037/$US}

# pass A — KEYTAB: one `<key>\t<rk>\t<idx>\t<pin>\t<exp>\t<origin>` line per
# addressable window, the parent-resolution table for the spawn-provenance grouping
# (#503), the pin bit a child inherits from its parent (#623), the @expand fold bit
# its children are hidden by, and the subtree progress each parent row reports
# (#624). @origin stays LAST:
# pass B peels the row with `${x#*\t}`, so only the final field may contain no tab.
# The `_` placeholders after @worktree (@cc_agent since #547, @wid since #566)
# are load-bearing: `read` gives the LAST name all remaining fields, so without
# them $wt arrived as `<path><US><agent><US><handle>` and okey_v's strict
# `scratch-<digits>` test could never match a @worktree-stamped scratch — the
# #529 blind spot, reopened in pass A only (pass B reads every field by name).
# $pin (#623) is named for the same reason: this pass needs it, and it is last.
KEYTAB=''; PRWANT=''
while IFS=$US read -r sess idx name path state _ _ iss origin wt _ _ nsub exp pin; do
  [ -z "$name" ] && continue
  [ -n "${FLEET_SESSION:-}" ] && [ "$sess" != "$FLEET_SESSION" ] && continue
  case "$name" in dash|plan|backlog) continue;; esac
  # Collect the branch spellings this frame will look up in the prmap (issue
  # #662) — BEFORE the okey filter below, because a window with no addressable
  # key still RENDERS in pass B and still gets a PR cell. Its only cost is the
  # same one-line git_ cache read pass B already does.
  ckey_v "$path"
  prbr=''; [ -f "$G/git_$ckey" ] && { IFS=$'\t' read -r prbr _ < "$G/git_$ckey" || :; }
  case "$prbr" in ''|-) ;; *) prcands_v "$prbr"; PRWANT+="$b1"$'\n'"$b3"$'\n'"$b2"$'\n' ;; esac
  okey_v "$iss" "$wt" "$path"
  [ -z "$okey" ] && continue
  state_v "$state" "$nsub"; pin_v "$pin"; exp_v "$exp"
  KEYTAB+="$okey"$'\t'"$rk"$'\t'"$idx"$'\t'"$pin"$'\t'"$exp"$'\t'"$origin"$'\n'
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
PRMAPN=$'\n'
if [ -s "$_pf" ] && [ -n "$PRWANT" ]; then
  PRMAPN=$'\n'$(PRWANT="$PRWANT" awk -F'\t' '
    BEGIN { n = split(ENVIRON["PRWANT"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    ($1 in want)' "$_pf" 2>/dev/null)
fi

# chain walk (issues #503/#623/#624): resolve a parent KEY to the ultimate LIVE
# root — ≤4 hops, so a grandchild both GROUPS under and COUNTS toward the same row.
# Sets, all as globals (no subshells — this runs per row at 4Hz):
#   $croot    the root's key; EMPTY ⇒ orphan (the chain left this dash, or ran
#             past 4 hops), and then $crk/$cidx keep the 9/99999 sink sentinel
#   $crk/$cidx  that root's rank/idx — the group sort key
#   $chops    hops taken; 0 ⇒ the named parent itself was missing
#   $crootpin the root's @pin bit (#623), 0 when there is no live root
#   $crootexp the root's @expand fold bit, 0 when there is no live root
#   $cpnrk/$cpnidx  the NEAREST pinned ANCESTOR's rank/idx, empty if none. Self is
#             not considered here — the caller checks its own @pin first, so a
#             pinned row is always its own pin root (#623's rule, unchanged).
# Factored out of the render loop in #624 so the progress count and the grouping
# can never disagree about who a row belongs to: one walker, two readers.
chain_v() { croot=''; crk=9; cidx=99999; chops=0; crootpin=0; crootexp=0
  cpnrk=''; cpnidx=''
  local cur="$1" t m prow prest porig prk pidx ppin pexp
  t=$'\n'"$KEYTAB"
  while [ "$chops" -lt 4 ]; do
    m=${t#*$'\n'"$cur"$'\t'}
    [ "$m" = "$t" ] && return                               # parent not on this dash
    prow=${m%%$'\n'*}
    prk=${prow%%$'\t'*}; prest=${prow#*$'\t'}
    pidx=${prest%%$'\t'*}; prest=${prest#*$'\t'}
    ppin=${prest%%$'\t'*}; prest=${prest#*$'\t'}
    pexp=${prest%%$'\t'*}; porig=${prest#*$'\t'}
    [ "$ppin" = 1 ] && [ -z "$cpnrk" ] && { cpnrk=$prk; cpnidx=$pidx; }
    case "$porig" in
      issue-*|scratch-*) cur=$porig; chops=$((chops+1)) ;;  # a child too — keep climbing
      *) croot=$cur; crk=$prk; cidx=$pidx; crootpin=$ppin; crootexp=$pexp; return ;;   # hub/autofill/none
    esac
  done
}

# pass A2 — KIDTAB: one `\n<root-key>\t<rk>\n` record per window that resolves to
# a LIVE root, so a row that spawned work can report its subtree's progress
# (issue #624). Attribution is #503's grouping verbatim — a grandchild counts
# toward the ULTIMATE live root, which is the row it renders under, so the badge
# always describes exactly the indented block beneath it — and an orphan (parent
# window closed, or a chain past 4 hops) counts toward nobody. (The #623 pin tier
# only re-sorts that block; it never re-parents anyone, so the count is unaffected.)
# Each record carries its OWN leading AND trailing newline: the counting
# substitutions in pass B replace non-overlapping matches, so records sharing one
# separator newline would count `\nA\t1\n` twice in a row as ONE.
KIDTAB=''
while IFS=$'\t' read -r _ krk _ _ _ korig; do
  case "$korig" in issue-*|scratch-*) ;; *) continue ;; esac
  chain_v "$korig"
  [ -n "$croot" ] && KIDTAB+=$'\n'"$croot"$'\t'"$krk"$'\n'
done <<< "$KEYTAB"

buf=""
while IFS=$US read -r sess idx name path state state_ts wid iss origin wt agent hnd nsub exp pin; do
  [ -z "$name" ] && continue
  # strict per-fleet: only windows from the viewing dash's own tmux session.
  # FLEET_SESSION exported by tmux-dashboard.sh; unset ⇒ show all (single-fleet).
  [ -n "${FLEET_SESSION:-}" ] && [ "$sess" != "$FLEET_SESSION" ] && continue
  case "$name" in dash|plan|backlog) continue;; esac   # panels, not Claude sessions
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

  # PR cell: look up the branch in prmap. The cache branch may carry +ahead/-behind
  # decorations; try EXACT first (real branch names can end in -digits, e.g.
  # issue-231 — the old sed-strip wrongly ate that), then decoration-stripped.
  ptxt='—'; pcol=$GY
  if [ "$branch" != '-' ] && [ -n "$branch" ]; then
    prcands_v "$branch"
    for bare in "$b1" "$b3" "$b2"; do
      tail=${PRMAPN#*$'\n'"$bare"$'\t'}
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
                  [ -n "$msha" ] && [ -f "$PRDIR/deploy_$msha" ] && { read -r dst _ < "$PRDIR/deploy_$msha" || :; }
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

  # --- the `id` cell: this window's handle (issue #566) -----------------------
  # @wid is the fleet's own short, TYPEABLE name for a window (`a1`…`z9`) — the
  # thing the operator says when they mean "reap a1" / "migrate b3". Muted grey:
  # it is a handle, not status, and must not compete with the state glyph beside
  # it. Backfilled here (the render is the one place that sees every window on
  # every tick) for anything that has none — a window that predates #566, or a
  # spawn whose allocator failed open. fleet_wid_stamp is idempotent + lock-held,
  # so this costs its handful of forks ONCE per window's life, never per tick,
  # and can never hand the same handle to two windows.
  if [ -z "$hnd" ]; then hnd=$(fleet_wid_stamp "$wid" "${FLEET_SESSION:-}") || hnd=''; fi

  # --- the issue cell (issues #529/#566) --------------------------------------
  # ISSUE-ONLY since #566: `#<N>` in GREEN for an issue-bound worker, BLANK for a
  # scratch. The cell used to carry both meanings behind a sigil (`#5613` vs
  # `~76`), which is what #566 unpicked — a scratch's per-window identity is now
  # the `id` handle to its left, so the `~<N>` branch has nothing left to say
  # here. (#502's finding still holds and is still honoured in the LANDED view,
  # where a closed row has no live window and `~<N>` IS its only id — see
  # fleet-history.sh cmd_rows.) The scratch slot number stays findable: it names
  # the worktree dir and still renders in the `↳~76` provenance tag.
  okey_v "$iss" "$wt" "$path"
  issd=''; icol=$GN
  case "$okey" in issue-*) issd="#${okey#issue-}" ;; esac
  # --- spawn provenance (issue #503) -----------------------------------------
  # ↳ tag: rendered in the flex span for every non-hub origin (`↳#483` for a
  # worker parent, `↳~12` for a scratch one — key_label's grammar — the literal
  # word for autofill/bridge). └ indent: only when the parent is a WINDOW kind
  # (issue-*/scratch-*), i.e. the row is a child in the grouped list.
  # Built as TWO pieces and composed after the chain walk below, because whether the
  # provenance half survives depends on where the row ends up nesting — and the
  # agent half must survive either way.
  provd=''; dname=$name
  case "$origin" in
    '') : ;;
    issue-*)   provd="↳#${origin#issue-}";   dname="└ $name" ;;
    scratch-*) provd="↳~${origin#scratch-}"; dname="└ $name" ;;
    *)         provd="↳$origin" ;;
  esac
  # agent tag (issue #547): a window running a non-Claude agent (@cc_agent, stamped
  # by bin/fleet-codex.sh) shows its agent name in the same flex span, after the
  # provenance tag — a Claude window carries no @cc_agent and draws nothing. ASCII
  # only, so the ${#tagd} width math below stays exact.
  agentd=''
  case "$agent" in ''|claude) : ;; *) agentd="${agent//[^A-Za-z0-9_-]/}" ;; esac
  # group sort key: a root keeps its own (rank, idx); a child resolves its parent
  # CHAIN (≤4 hops, grandchildren group under the ultimate live root) and inherits
  # that root's (rank, idx) with depth=1 so it sorts right below it; a chain that
  # breaks (parent window closed) is an ORPHAN → the 9/99999 sentinel sinks the
  # row below every live group, sub-sorted by its own rank/idx.
  #
  # PIN (issue #623) is a tier ABOVE all of that: `pinned` (0 = pinned, 1 =
  # ordinary) is the FIRST sort key, so a pinned window outranks every unpinned one
  # whatever its status. The bit rides the SAME parent chain as (grk, gidx) — that
  # is the load-bearing part: pinning a parent has to take its children up with it,
  # or the pin strands them below and they read as orphans. Two rules make it exact:
  #   • the ultimate live ROOT is pinned → the whole group is pinned and keeps the
  #     grouping (and indentation) it already had — the everyday case;
  #   • the root is NOT pinned but this row, or a MIDDLE ancestor, is → that pinned
  #     node becomes the group's root for sorting, so a pinned child floats with its
  #     own descendants still nested under it. A row that is its own pin root sheds
  #     the └ indent, for the same reason an orphan does: its parent is no longer
  #     the line above, and indenting under an unrelated row is a lie. The ↳ tag
  #     stays either way, so the provenance is never lost.
  grk=$rk; gidx=$idx; depth=0; rootpin=0
  # nearest pinned ancestor-or-SELF, walking up — self first, so a pinned row is
  # always its own pin root and can never be re-parented above itself.
  pnrk=''; pnidx=''; pndepth=0
  [ "$pin" = 1 ] && { pnrk=$rk; pnidx=$idx; }
  case "$origin" in
    issue-*|scratch-*)
      depth=1
      chain_v "$origin"; grk=$crk; gidx=$cidx; rootpin=$crootpin
      [ -z "$pnrk" ] && [ -n "$cpnrk" ] && { pnrk=$cpnrk; pnidx=$cpnidx; pndepth=1; }
      # parent not on this dash at all (closed, or a key from ANOTHER fleet):
      # keep the ↳ tag but drop the └ indent — an orphan sinks below every live
      # group, and indenting it there reads as a child of an unrelated row.
      [ -z "$croot" ] && [ "$chops" -eq 0 ] && dname=$name ;;
  esac
  pinned=1
  if [ "$rootpin" = 1 ]; then
    pinned=0                            # whole group floats, exactly as it grouped
  elif [ -n "$pnrk" ]; then
    pinned=0; grk=$pnrk; gidx=$pnidx; depth=$pndepth
    [ "$pndepth" = 0 ] && dname=$name   # promoted to a group root → no └ indent
  fi
  # --- fold: a collapsed holder hides its subtree ------------------------------
  # Default-collapsed (the @expand polarity in exp_v): a row only survives here if
  # the row it renders UNDER is expanded. Three rails keep that from hiding
  # anything the operator needs:
  #   • only `depth>0` rows can hide — precisely the ones drawn with the `└` indent
  #     under the line above. A root, an ORPHAN (parent window closed) and a row
  #     promoted to its own pin root all carry depth 0 and are never touched, so
  #     nothing can disappear with no visible parent to expand it back from;
  #   • `rk != 0` — a child in `needs` (the red `!`) is EXEMPT and stays on the
  #     list whatever the fold says. The dash's whole job is surfacing the row
  #     that is waiting on you, and the fleet's rule is that the quiet layer folds
  #     while the loud one never does;
  #   • the governing bit is the ULTIMATE LIVE ROOT's ($crootexp) — the SAME
  #     attribution pass A2 counts by and the caret below is drawn from, so every
  #     fold that hides a row has a visible, caret-marked row to expand it back
  #     from. (A row with a broken chain has no live root at all — `$croot` empty,
  #     the 9/99999 orphan sentinel — and is never hidden: there would be nothing
  #     on the list to unfold it.) The #623 pin tier re-SORTS a subtree and never
  #     re-parents it, here exactly as in the count.
  # Hiding is a RENDER filter only: KIDTAB was counted in pass A2 over every window,
  # so a collapsed parent's `3/5 ✓ · 1!` badge still describes the whole subtree —
  # which is exactly what makes the fold safe to have on by default.
  if [ "$depth" -gt 0 ] && [ -n "$croot" ] && [ "$rk" != 0 ] && [ "$crootexp" != 1 ]; then
    continue
  fi
  # --- the ↳ tag, once the nesting is known ------------------------------------
  # DROP it where the `└` indent already says the same thing: the row is drawn
  # inside a block AND the session it came from is the very row that block hangs
  # off. That is the everyday case — a worker spawned by the parent right above it
  # — and there the tag was pure duplication.
  # It STAYS wherever the indent does NOT say it, which is every case the fold and
  # the two-level-flat grouping cannot express:
  #   • a GRANDCHILD — it is drawn at the same indent as a child, under the ultimate
  #     root, so `↳#<middle>` is the only thing naming its actual parent;
  #   • an ORPHAN (parent window closed) — it has no indent at all, and the tag is
  #     the only surviving trace of where it came from;
  #   • a row #623 promoted to its own pin root — it sheds the indent on purpose;
  #   • a non-window origin (`autofill`, `bridge`) — never indented, never nested.
  # The agent tag (#547) is unaffected: it describes the row, not its parentage.
  [ "$depth" -gt 0 ] && [ -n "$croot" ] && [ "$origin" = "$croot" ] && provd=''
  tagd="$provd"
  [ -n "$agentd" ] && tagd="${tagd:+$tagd }$agentd"

  # --- subtree progress (issue #624) ------------------------------------------
  # A row that SPAWNED work reports the state of the group rendered beneath it:
  # `3/5 ✓` = 3 of its 5 descendants done, and a LOUD `· 1!` when one of them is
  # asking for the operator. Before this the parent knew nothing: each child
  # pushed its own report on landing (#574) and no row held the total.
  # Counted off KIDTAB with the fork-free length-delta idiom (one substitution
  # per figure, no subshell) so the 4Hz hot path keeps its exec budget.
  # A row with no children draws NOTHING — the dash's quiet layer must not grow a
  # badge on every line.
  kidd=''; kidpfx=''; carg=''
  if [ -n "$okey" ]; then
    kn=$'\n'"$okey"$'\t'; kt=${KIDTAB//"$kn"/}
    ktot=$(( (${#KIDTAB} - ${#kt}) / ${#kn} ))
    if [ "$ktot" -gt 0 ]; then
      kn=$'\n'"$okey"$'\t1'$'\n'; kt=${KIDTAB//"$kn"/}    # rk 1 = done
      kdone=$(( (${#KIDTAB} - ${#kt}) / ${#kn} ))
      kn=$'\n'"$okey"$'\t0'$'\n'; kt=${KIDTAB//"$kn"/}    # rk 0 = needs
      kneed=$(( (${#KIDTAB} - ${#kt}) / ${#kn} ))
      # quiet by default — progress is not a call for attention. Only the needs
      # count is loud, the same hierarchy the state glyph already keeps.
      kidd="$kdone/$ktot ✓"; kidpfx="${GY}${kidd}${R}"
      [ "$kneed" -gt 0 ] && { kidd="$kidd · $kneed!"
                              kidpfx="${kidpfx}${GY} · ${R}${RD}${kneed}!${R}"; }
      # fold caret — ONLY on a row that has a subtree, so the quiet layer still
      # doesn't grow a mark on every line. It reads this row's OWN @expand,
      # because this row is the one ←/→ toggles. `ktot>0` already implies depth 0:
      # pass A2 attributes every descendant to its ULTIMATE root, and a root's
      # @origin is hub/autofill/none, so only a top-level row can carry a count —
      # which is why a caret is guaranteed present for every subtree the filter
      # above can hide.
      if [ "$exp" = 1 ]; then carg='▾'; else carg='▸'; fi
    fi
  fi
  # full row: glyph1·id3·issue5·window22·⟨flex: ↳tag or empty⟩·act8·PR7·ctx4
  # window sits right after the issue; act/PR/ctx right-align to the edge, the
  # flex gap between them absorbing the width so the metadata block stays pinned
  # right. The flex span used to carry the LLM one-liner (summary column, retired
  # in issue #535 — it was the dash's only token-spending column); the ↳
  # provenance tag, the #623 pin mark and the #624 subtree-progress badge live
  # there now.
  fld 3  "$hnd";  f_hnd=$fld_out
  fld 5  "$issd"; f_iss=$fld_out
  # window column (issue #534): pad/clip by DISPLAY width, not code points. A CJK
  # name is the everyday case now that the prompt line NAMES a scratch, and a CJK
  # glyph is 2 cols — fld()'s ${#} pad gave `修复仪表盘` (10 cols) 17 spaces and
  # shoved the right-pinned act/PR/ctx block over. ASCII stays on fld()'s
  # fork-free path; only a non-ASCII name pays the one perl/wcwidth fork.
  case "$dname" in
    *[![:ascii:]]*) fleet_clip_display 22 "$dname"
                    printf -v f_name '%s%*s' "${clip_out:-}" $(( 22 - ${clip_w:-0} )) '' ;;
    *)              fld 22 "$dname"; f_name=$fld_out ;;
  esac
  fld "$ACTW" "$act"; f_act=$fld_out
  fld 7  "$ptxt"; f_pr=$fld_out
  fld 4  "$pct";  f_pct=$fld_out
  # the flex span draws the ↳ tag (+ an agent tag, #547), then the #624 progress
  # badge; ↳/#/~/✓/· are single-cell and the agent name ASCII, so ${#} is the
  # display width of both and the pad keeps act/PR/ctx pinned right.
  # (fld() shares the same ${#}=chars assumption; its remaining inputs — issue/PR/
  #  ctx — are ASCII. The window column, where CJK names are ordinary since #534,
  #  takes the width-aware path above.)
  tagpfx=''; dwidth=0
  [ -n "$tagd" ] && { tagpfx="${IN}${tagd}${R}"; dwidth=${#tagd}; }
  # The caret rides the 📌 rule, not the ${#} one: its width is the CONSTANT 2
  # (glyph + space) below, never a character count — ▸/▾ are East-Asian AMBIGUOUS
  # width, so a CJK-wide terminal may draw them 2 cells and a ${#}=1 pad would
  # walk the right-pinned act/PR/ctx block off by a column on parent rows only.
  [ -n "$carg" ] && { [ -n "$tagpfx" ] && { tagpfx+=' '; dwidth=$((dwidth+1)); }
                      tagpfx+="${GY}${carg}${R} "; dwidth=$(( dwidth + 2 )); }
  [ -n "$kidd" ] && { tagpfx+="$kidpfx"; dwidth=$(( dwidth + ${#kidd} )); }
  # 📌 marks a pinned row (issue #623): without it the operator sees a row sitting
  # above a red `needs` one and has no idea why. It OPENS the flex span, ahead of
  # any ↳ tag, so every pin sits at the same column and the eye can scan for them.
  # This is the file's one deliberate 2-cell glyph, and it is safe here precisely
  # because the flex span is a COMPUTED pad, not an fld() cell: its width is the
  # constant 3 below (glyph 2 + space), never a ${#} count, so the right-pinned
  # act/PR/ctx block stays put whatever the terminal thinks the emoji measures.
  # The mark follows @pin, NOT the inherited `pinned` tier: it means "this window
  # carries the pin, ⌃y here takes it off". A child floated by its parent is
  # explained by the └ indent under the marked row above it, and marking those too
  # would make the top of the list a wall of pins with no way to see which one is
  # the real handle.
  pinpfx=''
  [ "$pin" = 1 ] && { pinpfx='📌 '; dwidth=$(( dwidth + 3 )); }
  pad=$(( USABLE - LEFTW - dwidth - RIGHTW )); [ "$pad" -lt 1 ] && pad=1
  printf -v gap '%*s' "$pad" ''
  disp="${gc}${gl}${R} ${GY}${f_hnd}${R} ${icol}${f_iss}${R} ${nmcol}${f_name}${R} ${pinpfx}${tagpfx}${gap}${acol}${f_act}${R} ${pcol}${f_pr}${R} ${pcolr}${f_pct}${R}"

  buf+="$pinned	$grk	$gidx	$depth	$rk	$idx	$sess:$idx$US$wid$US$disp"$'\n'
done <<< "$WLIST"

# column header — pinned at top of the list by fzf --header-lines=1. Same
# right-aligned layout as the rows: leading "  " fills the glyph(1)+space slot,
# the flex span is blank, act/PR/ctx pinned right. Underlined muted-grey to read as a rule.
fld 3  "id";     h_w=$fld_out
fld 5  "issue";  h_i=$fld_out
fld 22 "window"; h_n=$fld_out
fld "$ACTW" "act"; h_a=$fld_out
fld 7  "PR";     h_p=$fld_out
fld 4  "ctx";    h_c=$fld_out
h_pad=$(( USABLE - LEFTW - RIGHTW )); [ "$h_pad" -lt 1 ] && h_pad=1
printf -v h_gap '%*s' "$h_pad" ''
printf '%s\n' "hdr${US}hdr${US}${E}4;38;2;86;95;137m  ${h_w} ${h_i} ${h_n} ${h_gap}${h_a} ${h_p} ${h_c}${R}"

# emit pinned-first (issue #623), then grouped by spawn provenance (issue #503):
# pinned windows (and the subtrees that float with them) take the whole top of the
# list whatever their status; below them, roots (hub/autofill/bridge spawns) keep
# the status-rank order they always had; each root's children sort directly below
# it (depth breaks the tie, then the child's own rank/idx); orphans — children
# whose parent window closed — sink below every live group. Pins sort AMONG
# themselves by the same (grk, gidx) they always had, so the pinned block is the
# ordinary list in miniature.
printf '%s' "$buf" | sort -t'	' -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n -k6,6n \
| while IFS='	' read -r _ _ _ _ _ _ line; do
  [ -z "$line" ] && continue
  printf '%s\n' "$line"
done
