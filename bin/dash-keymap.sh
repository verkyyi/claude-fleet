#!/bin/bash
# dash-keymap.sh — the resolver for fleet panels' fzf keys (#556/#558).
#
# Every ⌃-chord the dash binds is a key the TERMINAL has to deliver to fzf, and
# there is exactly one ctrl chord tmux never delivers to a pane as a plain key:
# its prefix (`prefix`, plus `prefix2` when set). #554 bound the agent flip to
# ctrl-a — free in fzf's bind table, but the operator's ~/.tmux.conf carries
# `set -g prefix C-a`, so tmux ate the keypress and "ctrl-a did nothing"; only
# the send-prefix double-tap reached fzf, which no `?` sheet advertised. Two
# rails, both here:
#   1. the DEFAULT keys are unbound in fzf (`man fzf` KEY BINDINGS: ctrl-g/c/q
#      abort; ctrl-a/e/b/f/k/u/w/y/j/n/p/h/d/l edit or navigate) AND not a
#      prefix anyone sets in practice — the flip moved to ctrl-v, the terminal's
#      literal-next chord, which nobody makes a tmux prefix;
#   2. at every dash launch the table below is checked against the LIVE
#      prefix/prefix2, and a colliding key is remapped to its ⌥ fallback
#      (alt-<same letter>; none of those letters is an fzf default either). The
#      dash binds, the `?` sheet (fleet-keys.sh), the ⌃v toast
#      (dash-agent-toggle.sh) and fleet-doctor.sh all read THIS resolution, so
#      the help never names a key the terminal cannot deliver.
#
# Usage:
#   dash-keymap.sh --panel dash|backlog|config|sidebar <command>  # default panel: dash
#                                   # env names stay DASH_KEY_* within each panel
#   dash-keymap.sh env              # shell assignments, one fork for the table —
#                                   #   DASH_KEY_<ACTION>=<fzf key>  DASH_GLYPH_<ACTION>=⌃x|⌥x
#                                   #   DASH_REMAP_<ACTION>=<prefix dodged, or empty>
#                                   #   DASH_KEYSTATE_<ACTION>=ok|remapped|unreachable
#                                   #   DASH_KEYMAP_PREFIX=C-a  DASH_KEYMAP_PREFIX2=  (tmux names)
#   dash-keymap.sh key <action>     # the effective fzf key name (ctrl-v / alt-v)
#   dash-keymap.sh glyph <action>   # the effective glyph for help + toasts (⌃v / ⌥v)
#   dash-keymap.sh list             # action key glyph default remap state — one row each
#   dash-keymap.sh collisions       # one row per default that IS a prefix:
#                                   #   action default-glyph prefix fallback-glyph|UNREACHABLE
#   dash-keymap.sh prefixes         # `<prefix> <prefix2>` as tmux names, `-` for none
#   dash-keymap.sh actions          # the action names, one per line
#
# Prefix source, first hit wins: FLEET_TMUX_PREFIX / FLEET_TMUX_PREFIX2 in the env
# (a test seam, and a pin — set either and BOTH come from the env, an unset second
# meaning none); the live server (`tmux show -gv prefix` — inside a fleet pane
# $TMUX points at THIS fleet's socket); else the tmux conf file parsed for
# `set -g prefix …` (fleet-doctor runs outside any server, and every fleet server
# reads that file at start, so it is what the servers will have); else tmux's
# own default, C-b.
#
# The table: action, default key, fallback key. A new dash bind goes HERE, then
# `--bind "$DASH_KEY_<ACTION>:…"` in tmux-dashboard.sh and a `$(dg <action>)` row
# in fleet-keys.sh — bin/fleet-keys-selftest.sh holds the three in lockstep.
#
# PICKING a default (issue #623): the ideal is a ⌃<letter> that is BOTH free in
# fzf's own bind table AND nobody's tmux prefix — but the table has grown past the
# point where such a letter exists (fzf claims a/b/d/e/f/h/j/k/l/n/p/u/w/y for the
# input line plus c/g/q to abort, and the ten rows above hold the rest). So the
# rule degrades in a fixed order: never a common prefix (⌃a ⌃b ⌃s ⌃g ⌃t ⌃x — the
# whole point of #556), then take the fzf default whose loss costs the dash least.
# `pin` took ctrl-y on that basis: fzf's ⌃y is `yank` (paste the clipboard into
# the query), and the dash's query line is a short scratch NAME — the cheapest of
# the remaining bindings to spend, and the mnemonic survives (yank the row up).
# ⌃u / ⌃w (clear line / delete word) were deliberately left alone: those two are
# what an operator uses to fix a mistyped name.
# `migrate` (issue #873) took ctrl-l on the same basis: fzf's ⌃l is
# `clear-screen`, a repaint the dash's 1Hz reload already does every second.
# (Mnemonic: Leave this account's wall.)
# `pick` (issue #793) is ctrl-z: every other ⌃<letter> is now an fzf edit key,
# a common prefix or already a row — ⌃f was the mnemonic, but its ⌥ twin alt-f is
# fzf's forward-word. fzf binds nothing to ⌃z (it reads the byte in raw mode, so
# the terminal never suspends it), and nobody makes it a tmux prefix. It opens
# the fleet/repo picker — the same one the footer's fleet name opens.
set -uo pipefail

PANEL=dash
if [ "${1:-}" = --panel ]; then
  PANEL="${2:-}"; shift; [ "$#" -gt 0 ] && shift
fi
case "$PANEL" in
dash) TABLE='agent ctrl-v alt-v
reload ctrl-r alt-r
new ctrl-n alt-n
scratch ctrl-s alt-s
view ctrl-t alt-t
restore ctrl-o alt-o
pr ctrl-p alt-p
reap ctrl-x alt-x
rename ctrl-e alt-e
answer ctrl-k alt-k
pin ctrl-y alt-y
migrate ctrl-l alt-l
pick ctrl-z alt-z' ;;
backlog) TABLE='new ctrl-n alt-n
close ctrl-x alt-x
priority ctrl-y alt-y
open ctrl-o alt-o
reload ctrl-r alt-r' ;;
config) TABLE='scope ctrl-s alt-s
reload ctrl-r alt-r
preview ctrl-p alt-p' ;;
# The worker task sidebar's navigation keys (issue #896). NOT fzf: a tmux key
# table (conf/tmux-attention.conf, fleet-sidebar) whose `Any` bind types every
# other key into the input line — so a letter can never be an action here, and
# an action is a ⌃-chord the view reads as a byte (⌃n = 0x0e). The prefix rule
# is the same: tmux honours its prefix in that table too, so a colliding key
# takes its ⌥ fallback, which the conf rewrites to the ⌃ byte (`bind -T
# fleet-sidebar M-n … send-keys C-n`). Later EPIC #894 members add rows here.
# `hide` is NOT a row: it left this table for prefix e (a global prefix bind),
# since `q` types now.
# `menu` (issue #898) is the one printable default: `.` opens the highlighted
# row's action menu ONLY while the input line is empty — inside a name it types
# a dot. One tap on an iPad keyboard, where a ⌃-chord is three. It arrives
# through the `Any` bind like any typed key (no conf bind), and no tmux prefix is
# a bare `.`, so it never remaps.
sidebar) TABLE='new ctrl-n alt-n
menu . .' ;;
*) echo "dash-keymap.sh: unknown panel '$PANEL' (dash|backlog|config|sidebar)" >&2; exit 2 ;;
esac

# tmux_to_fzf <tmux key name> → the fzf spelling, lowercase, modifiers ordered
# ctrl then alt: C-a → ctrl-a · M-a → alt-a · C-M-x / M-C-x → ctrl-alt-x ·
# C-Space → ctrl-space · ^A (legacy caret form) → ctrl-a · None / '' → ''.
tmux_to_fzf() {
  local k c="" a=""
  k=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$k" in ''|none) return 0 ;; '^'?) k="c-${k#^}" ;; esac
  while :; do
    case "$k" in
      c-?*) c=ctrl-; k="${k#c-}" ;;
      m-?*) a=alt-;  k="${k#m-}" ;;
      *)    break ;;
    esac
  done
  printf '%s%s%s\n' "$c" "$a" "$k"
}

# glyph_of <fzf key> → ⌃x / ⌥x / ⌃⌥x (the cheatsheet's spelling).
glyph_of() {
  local k="$1" g=""
  while :; do
    case "$k" in
      ctrl-?*) g="${g}⌃"; k="${k#ctrl-}" ;;
      alt-?*)  g="${g}⌥"; k="${k#alt-}" ;;
      *)       break ;;
    esac
  done
  printf '%s%s\n' "$g" "$k"
}

# conf_prefix <prefix|prefix2> → the LAST `set[-option] [-flags] <opt> <value>`
# in the tmux conf tmux would read (~/.tmux.conf, then the XDG paths), quotes
# stripped; nothing when no file sets it.
conf_prefix() {
  local f
  for f in "${TMUX_CONF:-$HOME/.tmux.conf}" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"; do
    [ -f "$f" ] || continue
    awk -v opt="$1" '
      $1=="set" || $1=="set-option" {
        i=2; while (i<=NF && $i ~ /^-/) i++
        if (i<NF && $i==opt) { v=$(i+1); gsub(/["'"'"']/, "", v); found=v }
      }
      END { if (found!="") print found }' "$f"
    return 0
  done
}

# sanitise a prefix name for the shell-assignment output (a prefix is a tmux key
# name — letters, digits, `-`, `^`, `+`, `_`, `~`; anything else is dropped).
clean() { printf '%s' "$1" | tr -cd 'A-Za-z0-9^+_~-'; }

# resolve_prefixes → PFX1 PFX2 (tmux names, '' for none) + F1 F2 (fzf names).
resolve_prefixes() {
  if [ -n "${FLEET_TMUX_PREFIX+x}" ] || [ -n "${FLEET_TMUX_PREFIX2+x}" ]; then
    PFX1="${FLEET_TMUX_PREFIX-}"; PFX2="${FLEET_TMUX_PREFIX2-}"
  else
    PFX1=$(tmux show -gv prefix 2>/dev/null) || PFX1=""
    if [ -n "$PFX1" ]; then
      PFX2=$(tmux show -gv prefix2 2>/dev/null) || PFX2=""
    else
      PFX1=$(conf_prefix prefix); PFX2=$(conf_prefix prefix2)
      [ -n "$PFX1" ] || PFX1="C-b"
    fi
  fi
  PFX1=$(clean "$PFX1"); PFX2=$(clean "$PFX2")
  case "$PFX2" in None|none) PFX2="" ;; esac
  F1=$(tmux_to_fzf "$PFX1"); F2=$(tmux_to_fzf "$PFX2")
}

# hit <fzf key> → prints the tmux name of the prefix it collides with, if any.
hit() {
  [ -n "$F1" ] && [ "$1" = "$F1" ] && { printf '%s\n' "$PFX1"; return 0; }
  [ -n "$F2" ] && [ "$1" = "$F2" ] && { printf '%s\n' "$PFX2"; return 0; }
  return 1
}

# resolve → rows: action key glyph default remap state
resolve() {
  local action def fb key remap state
  resolve_prefixes
  while read -r action def fb; do
    [ -n "$action" ] || continue
    key="$def"; remap="-"; state=ok
    if remap=$(hit "$def"); then
      if hit "$fb" >/dev/null; then key="$def"; state=unreachable
      else key="$fb"; state=remapped; fi
    else
      remap="-"
    fi
    printf '%s %s %s %s %s %s\n' "$action" "$key" "$(glyph_of "$key")" "$def" "$remap" "$state"
  done <<EOF
$TABLE
EOF
}

cmd="${1:-env}"; shift 2>/dev/null || true
case "$cmd" in
  env)
    resolve | while read -r action key glyph def remap state; do
      up=$(printf '%s' "$action" | tr '[:lower:]' '[:upper:]')
      [ "$remap" = "-" ] && remap=""
      printf "DASH_KEY_%s='%s'\nDASH_GLYPH_%s='%s'\nDASH_REMAP_%s='%s'\nDASH_KEYSTATE_%s='%s'\n" \
        "$up" "$key" "$up" "$glyph" "$up" "$remap" "$up" "$state"
    done
    resolve_prefixes
    printf "DASH_KEYMAP_PREFIX='%s'\nDASH_KEYMAP_PREFIX2='%s'\n" "$PFX1" "$PFX2"
    ;;
  key|glyph)
    want="${1:-}"; [ -n "$want" ] || { echo "dash-keymap.sh: $cmd needs an action" >&2; exit 2; }
    row=$(resolve | awk -v a="$want" '$1==a')
    [ -n "$row" ] || { echo "dash-keymap.sh: unknown action '$want'" >&2; exit 2; }
    if [ "$cmd" = key ]; then printf '%s\n' "$row" | awk '{print $2}'
    else printf '%s\n' "$row" | awk '{print $3}'; fi
    ;;
  list)      resolve ;;
  actions)   printf '%s\n' "$TABLE" | awk '{print $1}' ;;
  prefixes)  resolve_prefixes; printf '%s %s\n' "${PFX1:--}" "${PFX2:--}" ;;
  collisions)
    resolve | while read -r action key glyph def remap state; do
      case "$state" in
        remapped)    printf '%s %s %s %s\n' "$action" "$(glyph_of "$def")" "$remap" "$glyph" ;;
        unreachable) printf '%s %s %s UNREACHABLE\n' "$action" "$(glyph_of "$def")" "$remap" ;;
      esac
    done
    ;;
  *) echo "usage: dash-keymap.sh [--panel dash|backlog|config|sidebar] env|key <action>|glyph <action>|list|collisions|prefixes|actions" >&2; exit 2 ;;
esac
