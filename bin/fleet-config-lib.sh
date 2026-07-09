#!/bin/bash
# fleet-config-lib.sh — shared helpers for the prefix+c config modal (issue #83).
# Sourced by bin/tmux-config.sh, bin/dash-config-edit.sh and the selftest.
#
# The modal makes the fleet's TWO-LAYER config visible + editable:
#   per-fleet overlay ($FLEET_CONF_DIR/<session>.conf)  ▸ wins
#   global            (<install>/fleet.conf)            · inherited
#   code default      (documented in fleet.conf.example)  fallback
# — exactly the precedence fleet_load_conf applies at runtime.
#
# The KEY LIST + per-key help are PARSED from fleet.conf.example (the single
# source of truth — never a hardcoded divergent copy). Validation TYPE is a
# small policy layered on top (numeric caps/TTLs, on/off booleans, model enums,
# free strings) so a bad value can't be written that would break `source`-ing
# the conf. A key newly added to the example shows up automatically (with
# best-effort str validation) — nothing to keep in sync here.
#
# Shell-options policy (see CONTRIBUTING.md): this file is SOURCED, so it must
# NOT `set -u`/`set -o pipefail`. It is written to be safe under a `set -u`
# caller: every optional expansion is defaulted and every helper returns cleanly.

# Directory this lib lives in (used to locate the example + global conf).
FCFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# US (0x1f) field separator, matching the dashboard/backlog row producers.
FCFG_US="$(printf '\037')"

# --- file locations (all overridable for tests) -----------------------------
fcfg_example()     { printf '%s' "${FCFG_EXAMPLE:-$FCFG_DIR/../fleet.conf.example}"; }
fcfg_global_conf() { printf '%s' "${FCFG_GLOBAL_CONF:-$FCFG_DIR/../fleet.conf}"; }
# The per-fleet overlay for a session. FCFG_FLEET_CONF overrides (tests); else
# $FLEET_CONF_DIR/<session>.conf. Empty when there is no session (not in a fleet).
fcfg_fleet_conf() {
  if [ -n "${FCFG_FLEET_CONF:-}" ]; then printf '%s' "$FCFG_FLEET_CONF"; return; fi
  local sess="${1:-}"
  [ -n "$sess" ] || return 0
  printf '%s/%s.conf' "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}" "$sess"
}

# --- key list / defaults / help (parsed from the example) -------------------
# Every FLEET_* key in the example, in file order (commented-out optionals too).
fcfg_keys() {
  grep -oE '^#?[[:space:]]*FLEET_[A-Z0-9_]+=' "$(fcfg_example)" 2>/dev/null \
    | sed -E 's/^#?[[:space:]]*//; s/=$//'
}

# Strip a surrounding quote pair (or a trailing inline "# …" comment + edge
# whitespace on a bare value) from an assignment's RHS. One helper so the two
# call sites (default from the example, effective value from a conf) can never
# drift apart in how they unquote.
_fcfg_unquote() {
  local rhs="$1"
  case "$rhs" in
    \"*) rhs=${rhs#\"}; rhs=${rhs%%\"*} ;;                      # "…" → between quotes
    \'*) rhs=${rhs#\'}; rhs=${rhs%%\'*} ;;                      # '…' → between quotes
    *)   rhs=$(printf '%s' "$rhs" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//') ;;
  esac
  printf '%s' "$rhs"
}

# The documented default value for KEY (RHS of its example assignment, inline
# comment + surrounding quotes stripped). Empty if the key isn't in the example.
fcfg_default() {
  local line
  line=$(grep -E "^#?[[:space:]]*$1=" "$(fcfg_example)" 2>/dev/null | head -1)
  [ -n "$line" ] || return 0
  _fcfg_unquote "${line#*=}"
}

# The contiguous comment block immediately above KEY's assignment (leading "# "
# stripped), inline trailing comment first when present. Stops at a blank line,
# a bare "#" separator, a section divider (# --- …), or a non-comment line.
_fcfg_block() {
  awk -v key="$1" '
    { L[NR]=$0 }
    $0 ~ ("^#?[[:space:]]*" key "=") { target=NR }
    END {
      if (!target) exit
      inline=""
      if (match(L[target], /[[:space:]]#[[:space:]]*[^[:space:]]/)) {
        inline=substr(L[target], RSTART)
        sub(/^[[:space:]]*#[[:space:]]*/, "", inline)
      }
      n=0
      for (i=target-1; i>=1; i--) {
        line=L[i]
        if (line ~ /^[[:space:]]*$/) break                     # blank
        if (line !~ /^[[:space:]]*#/) break                    # non-comment
        if (line ~ /^[[:space:]]*#[[:space:]]*$/) break        # bare "#" separator
        if (line ~ /^[[:space:]]*#[[:space:]]*[-=]{2,}/) break # "# --- section ---"
        buf[++n]=line
      }
      if (inline != "") print inline
      for (i=n; i>=1; i--) { s=buf[i]; sub(/^[[:space:]]*#[[:space:]]?/, "", s); print s }
    }
  ' "$(fcfg_example)"
}

# One-line help for KEY (first sentence of its comment block).
fcfg_short() {
  local first
  first=$(_fcfg_block "$1" | sed '/^[[:space:]]*$/d' | head -1)
  first=$(printf '%s' "$first" | sed -E 's/\. .*/./')
  [ -n "$first" ] && printf '%s' "$first" || printf '(no description)'
}

# Full multi-line help for KEY (the preview pane).
fcfg_full() { _fcfg_block "$1"; }

# Validation type for KEY: bool | enum | num | str. Booleans/enums are an
# explicit policy; num vs str is inferred from whether the default is an integer.
fcfg_type() {
  case "$1" in
    FLEET_AUTOFILL|FLEET_SPAWN_FOCUS)  printf bool; return ;;
    FLEET_MODEL|FLEET_SUBAGENT_MODEL)  printf enum; return ;;
  esac
  local d; d=$(fcfg_default "$1")
  case "$d" in
    ''|*[!0-9]*) printf str ;;
    *)           printf num ;;
  esac
}

# --- per-file / effective value resolution ----------------------------------
# Value of an UNCOMMENTED KEY= assignment in FILE (quotes/inline-comment
# stripped). Prints the value and returns 0 if set; returns 1 if unset/absent.
fcfg_file_value() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 1
  line=$(grep -E "^[[:space:]]*$key=" "$file" 2>/dev/null | grep -vE '^[[:space:]]*#' | tail -1)
  [ -n "$line" ] || return 1
  _fcfg_unquote "${line#*=}"
  return 0
}

# Effective value + winning layer for KEY, as "<value><US>fleet|global|default".
fcfg_effective() {
  local key="$1" sess="${2:-}" v
  if v=$(fcfg_file_value "$(fcfg_fleet_conf "$sess")" "$key"); then printf '%s%sfleet'  "$v" "$FCFG_US"; return; fi
  if v=$(fcfg_file_value "$(fcfg_global_conf)"      "$key"); then printf '%s%sglobal' "$v" "$FCFG_US"; return; fi
  printf '%s%sdefault' "$(fcfg_default "$key")" "$FCFG_US"
}

# The conf file a write targets for SESSION at SCOPE (global|fleet).
fcfg_target_conf() {
  case "$2" in
    global) fcfg_global_conf ;;
    *)      fcfg_fleet_conf "$1" ;;
  esac
}

# --- scope state (which layer edits write to) -------------------------------
# Persisted per-session in the dash cache dir so it survives fzf reloads.
fcfg_scope_file()   { printf '%s/config_scope_%s' "${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}" "${1:-_}"; }
fcfg_scope()        { local f; f=$(fcfg_scope_file "${1:-}"); if [ -f "$f" ]; then cat "$f"; else printf 'fleet'; fi; }
fcfg_scope_set()    { local f; f=$(fcfg_scope_file "${1:-}"); mkdir -p "$(dirname "$f")" 2>/dev/null; printf '%s' "$2" > "$f"; }
fcfg_scope_toggle() { if [ "$(fcfg_scope "${1:-}")" = fleet ]; then fcfg_scope_set "${1:-}" global; else fcfg_scope_set "${1:-}" fleet; fi; }

# --- validation --------------------------------------------------------------
# fcfg_validate TYPE VALUE KEY → 0 (ok, no output) or 1 + a one-line reason.
# Guarantees the value can be written without breaking `source`-ing the conf.
fcfg_validate() {
  local type="$1" val="$2" key="${3:-value}"
  case "$type" in
    num)
      case "$val" in
        ''|*[!0-9]*) printf '%s must be a non-negative integer (got: %s)' "$key" "${val:-<empty>}"; return 1 ;;
      esac ;;
    bool)
      case "$val" in
        0|1) : ;;
        *)   printf '%s must be 0 or 1 (got: %s)' "$key" "${val:-<empty>}"; return 1 ;;
      esac ;;
    enum)
      case "$val" in
        ''|opus|sonnet|haiku|opusplan|default|claude-*) : ;;
        inherit)
          [ "$key" = FLEET_SUBAGENT_MODEL ] || { printf '%s: "inherit" is valid only for FLEET_SUBAGENT_MODEL' "$key"; return 1; } ;;
        *) printf '%s must be a model alias (opus|sonnet|haiku|opusplan|default), a claude-* id, or empty (got: %s)' "$key" "$val"; return 1 ;;
      esac ;;
    *)
      # free string: reject only what would make the double-quoted assignment
      # unsafe to `source`. $VAR / ${VAR} expansion is allowed (the example relies
      # on $HOME/$TMPDIR/$SHELL); command substitution — $(…) and backticks — is
      # rejected because it would EXECUTE when the conf is sourced.
      case "$val" in
        *\"*)    printf '%s: value may not contain a double-quote — edit the conf by hand for that' "$key"; return 1 ;;
        *\`*)    printf '%s: value may not contain a backtick (command substitution)' "$key"; return 1 ;;
        *'$('*)  printf '%s: value may not contain $(…) command substitution — edit the conf by hand for that' "$key"; return 1 ;;
        *\\)     printf '%s: value may not end in a backslash' "$key"; return 1 ;;
      esac ;;
  esac
  return 0
}

# --- write -------------------------------------------------------------------
# fcfg_write FILE KEY VALUE TYPE — back up FILE (if it exists) to FILE.bak, then
# upsert the assignment (replace an existing uncommented KEY= line in place, else
# append). Creates FILE (with a header) if absent. Prints "created" or "updated".
# num/bool write bare (KEY=5); enum/str write double-quoted (KEY="…"). VALUE is
# passed to awk via the environment so backslashes/metachars survive verbatim.
fcfg_write() {
  local file="$1" key="$2" val="$3" type="$4" line status
  case "$type" in
    num|bool) line="$key=$val" ;;
    *)        line="$key=\"$val\"" ;;
  esac
  if [ -f "$file" ]; then
    cp -p "$file" "$file.bak" 2>/dev/null || cp "$file" "$file.bak" || return 1
    status=updated
  else
    mkdir -p "$(dirname "$file")" 2>/dev/null
    {
      printf '# claude-fleet config — created by the prefix+c config modal.\n'
      printf '# Assignments only (this file is sourced). Per-fleet overlays the global fleet.conf.\n'
    } > "$file" || return 1
    status=created
  fi
  # Upsert to a temp then atomically rename. On ANY failure (full/read-only
  # volume — a first-class case in this repo) leave the original untouched and
  # return non-zero so the caller reports failure instead of a false success.
  if LINE="$line" awk -v key="$key" '
       $0 ~ /^[[:space:]]*#/                { print; next }
       $0 ~ ("^[[:space:]]*" key "=")       { print ENVIRON["LINE"]; repl=1; next }
                                            { print }
       END { if (!repl) print ENVIRON["LINE"] }
     ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"; then
    printf '%s' "$status"
    return 0
  fi
  rm -f "$file.tmp.$$" 2>/dev/null
  return 1
}
