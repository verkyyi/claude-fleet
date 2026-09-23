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
# The KEY LIST, per-key help, AND per-key attributes are all PARSED from
# fleet.conf.example (the single source of truth — never a hardcoded divergent
# copy). Each key carries a declarative tag line (issue #89):
#   # @label=… @group=… @tier=… @scope=… @edit=… @unit=…
# which drives the modal's friendly label, section grouping, visibility tier,
# allowed write scope, and editor/validation type. Validation is a small policy
# on top of @edit so a bad value can't be written that would break `source`-ing
# the conf. A key newly added to the example shows up automatically — nothing to
# keep in sync here.
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
# The machine-wide layer. Since issue #979 a login keeps ONE settings file,
# $FLEET_CONF_DIR/fleet.settings: once it exists, global writes land there and it
# wins over the install's fleet.conf, which stays a read-only fallback (dual-read).
fcfg_install_conf() { printf '%s' "${FCFG_GLOBAL_CONF:-$FCFG_DIR/../fleet.conf}"; }
fcfg_settings_conf() { printf '%s' "${FCFG_SETTINGS_CONF:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.settings}"; }
fcfg_global_conf() {
  local s; s=$(fcfg_settings_conf)
  if [ -f "$s" ]; then printf '%s' "$s"; else fcfg_install_conf; fi
}
# The per-fleet overlay for a session. FCFG_FLEET_CONF overrides (tests); else the
# per-fleet layout fleets/<session>/conf (issue #181), falling back to a legacy
# flat <session>.conf when only that exists (edit it in place until migrated). A
# not-yet-created overlay resolves to the NEW path. Empty when there is no session.
fcfg_fleet_conf() {
  if [ -n "${FCFG_FLEET_CONF:-}" ]; then printf '%s' "$FCFG_FLEET_CONF"; return; fi
  local sess="${1:-}" root new old
  [ -n "$sess" ] || return 0
  # Reuse fleet-lib's fleet_conf_file when it's in scope (the config modal sources
  # fleet-lib via tmux-config.sh) so the dual-layout ladder has ONE definition; fall
  # back to an inline copy for the standalone-sourced case (the selftest).
  if declare -F fleet_conf_file >/dev/null 2>&1; then fleet_conf_file "$sess"; return; fi
  root="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
  new="$root/fleets/$sess/conf"; old="$root/$sess.conf"
  if   [ -f "$new" ]; then printf '%s' "$new"
  elif [ -f "$old" ]; then printf '%s' "$old"
  else                     printf '%s' "$new"; fi
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
        if (line ~ /^[[:space:]]*#[[:space:]]*FLEET_[A-Z0-9_]+=/) break # a prior key default line
        if (line ~ /@label=/) continue                         # tag line — not help
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

# --- declarative tags (issue #89) -------------------------------------------
# Each key carries a single "# @label=… @group=… @tier=… @scope=… @edit=… @unit=…"
# comment line directly above its assignment (see fleet.conf.example). That line
# is the source of truth for the modal's friendly label, grouping, visibility
# tier, allowed write scope, and editor/validation type. We parse it here so the
# scripts never hardcode a divergent copy.

# The tag line for KEY: the comment line in KEY's block that carries @label=.
_fcfg_tagline() {
  awk -v key="$1" '
    { L[NR]=$0 }
    $0 ~ ("^#?[[:space:]]*" key "=") { target=NR }
    END {
      if (!target) exit
      for (i=target-1; i>=1; i--) {
        line=L[i]
        if (line ~ /^[[:space:]]*$/) exit          # blank — out of the block
        if (line !~ /^[[:space:]]*#/) exit         # non-comment — out of the block
        if (line ~ /@label=/) { print line; exit }
      }
    }
  ' "$(fcfg_example)"
}

# fcfg_tag KEY NAME → the value of @NAME on KEY's tag line, or empty. A value
# runs from after "@NAME=" until the next " @word=" token (so @label may contain
# spaces, em-dashes, etc.), with trailing whitespace trimmed.
fcfg_tag() {
  local line; line=$(_fcfg_tagline "$1")
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" | TAG="$2" awk '
    BEGIN { key = "@" ENVIRON["TAG"] "=" }
    {
      p = index($0, key)
      if (p == 0) exit
      rest = substr($0, p + length(key))
      if (match(rest, /[[:space:]]+@[a-zA-Z_]+=/)) rest = substr(rest, 1, RSTART-1)
      sub(/[[:space:]]+$/, "", rest)
      print rest
    }
  '
}

# Friendly label for KEY (@label), falling back to the raw key name.
fcfg_label() { local v; v=$(fcfg_tag "$1" label); [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$1"; }
# Section bucket (@group), default "other".
fcfg_group() { local v; v=$(fcfg_tag "$1" group); [ -n "$v" ] && printf '%s' "$v" || printf 'other'; }
# Visibility tier (@tier): common | advanced. Default common.
fcfg_tier()  { local v; v=$(fcfg_tag "$1" tier);  [ -n "$v" ] && printf '%s' "$v" || printf 'common'; }
# Allowed write scope (@scope): identity | global | fleet. Default fleet.
fcfg_scope() { local v; v=$(fcfg_tag "$1" scope); [ -n "$v" ] && printf '%s' "$v" || printf 'fleet'; }
# Optional display unit (@unit), e.g. sec / GB / tokens. Empty if none.
fcfg_unit()  { fcfg_tag "$1" unit; }

# Editor/validation kind (@edit): no | bool | int | enum | path | str | regex.
# Falls back to a best-effort inference for a key that has no tag line yet.
fcfg_edit() {
  local v; v=$(fcfg_tag "$1" edit)
  if [ -n "$v" ]; then printf '%s' "$v"; return; fi
  case "$1" in
    FLEET_SPAWN_FOCUS)  printf bool; return ;;
    FLEET_MODEL|FLEET_SUBAGENT_MODEL)  printf enum; return ;;
  esac
  local d; d=$(fcfg_default "$1")
  case "$d" in
    ''|*[!0-9]*) printf str ;;
    *)           printf int ;;
  esac
}

# Validation CLASS for KEY: bool | enum | num | str — the coarse family the
# validator + writer key off (int→num; path/regex/str/no→str). Derived from the
# richer @edit type so the two never drift.
fcfg_type() {
  case "$(fcfg_edit "$1")" in
    bool)           printf bool ;;
    enum)           printf enum ;;
    int)            printf num ;;
    *)              printf str ;;
  esac
}

# fcfg_table → one US-delimited record per key, parsed in a SINGLE awk pass over
# the example (the fast path for the modal's row builder, which would otherwise
# re-parse the file ~7× per key). Fields, in order:
#   KEY  label  group  tier  scope  edit  unit  default
# Same rules as the per-key accessors above (label/group/tier/scope default to
# key/other/common/fleet; edit inferred when untagged; default unquoted) — the
# selftest cross-checks the two so they can never drift.
fcfg_table() {
  awk -v US="$FCFG_US" '
    function unq(rhs,   v) {
      v = rhs
      if (v ~ /^"/)  { sub(/^"/,  "", v); sub(/".*/,  "", v); return v }
      if (v ~ /^'\''/) { sub(/^'\''/, "", v); sub(/'\''.*/, "", v); return v }
      sub(/[[:space:]]+#.*$/, "", v); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      return v
    }
    function tagval(line, name,   k, p, rest) {
      k = "@" name "="; p = index(line, k)
      if (p == 0) return ""
      rest = substr(line, p + length(k))
      if (match(rest, /[[:space:]]+@[a-zA-Z_]+=/)) rest = substr(rest, 1, RSTART-1)
      sub(/[[:space:]]+$/, "", rest)
      return rest
    }
    { L[NR] = $0 }
    END {
      for (n = 1; n <= NR; n++) {
        if (L[n] !~ /^#?[[:space:]]*FLEET_[A-Z0-9_]+=/) continue
        key = L[n]; sub(/^#?[[:space:]]*/, "", key); sub(/=.*/, "", key)
        def = L[n]; sub(/^[^=]*=/, "", def); def = unq(def)
        tl = ""
        for (i = n-1; i >= 1; i--) {
          p = L[i]
          if (p ~ /^[[:space:]]*$/) break
          if (p !~ /^[[:space:]]*#/) break
          if (p ~ /@label=/) { tl = p; break }
        }
        label = tagval(tl, "label"); if (label == "") label = key
        group = tagval(tl, "group"); if (group == "") group = "other"
        tier  = tagval(tl, "tier");  if (tier  == "") tier  = "common"
        scope = tagval(tl, "scope"); if (scope == "") scope = "fleet"
        edit  = tagval(tl, "edit")
        unit  = tagval(tl, "unit")
        if (edit == "") {
          if (key == "FLEET_SPAWN_FOCUS") edit = "bool"
          else if (key == "FLEET_MODEL" || key == "FLEET_SUBAGENT_MODEL") edit = "enum"
          else if (def ~ /^[0-9]+$/) edit = "int"
          else edit = "str"
        }
        printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", \
          key, US, label, US, group, US, tier, US, scope, US, edit, US, unit, US, def
      }
    }
  ' "$(fcfg_example)"
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
  if v=$(fcfg_file_value "$(fcfg_settings_conf)"    "$key"); then printf '%s%sglobal' "$v" "$FCFG_US"; return; fi
  if v=$(fcfg_file_value "$(fcfg_install_conf)"     "$key"); then printf '%s%sglobal' "$v" "$FCFG_US"; return; fi
  printf '%s%sdefault' "$(fcfg_default "$key")" "$FCFG_US"
}

# The conf file a write targets for SESSION at SCOPE (global|fleet|repo:<slug>).
# A repo scope whose repo the fleet no longer hosts resolves to NOTHING, so the
# editor refuses instead of writing an overlay nobody reads.
fcfg_target_conf() {
  case "$2" in
    global) fcfg_global_conf ;;
    repo:*) fcfg_repo_conf "$1" "${2#repo:}" ;;
    *)      fcfg_fleet_conf "$1" ;;
  esac
}

# --- repo scope (issue #802) -------------------------------------------------
# A fleet hosting 2+ repos (issue #788) keeps each repo's own settings in
# fleets/<sess>/repos/<slug>.conf. The modal edits them through a third write
# scope, `repo:<slug>`, reached by the same ⌃s toggle. Only in a fleet that HAS
# a repos/ overlay: a one-repo fleet keeps the fleet⇄global toggle byte for byte.
# These helpers need fleet-lib (fleet_repos & co.) in scope — the modal and the
# editor source it; without it there are simply no repo scopes.
#
# The keys a repo overlay DOCUMENTEDLY carries (fleet.conf.example's "Per-repo
# settings" block): the deploy + launch knobs, then fleet-lib's
# _FLEET_REPO_OVERRIDABLE (read live, so the two cannot drift).
fcfg_repo_keys() {
  printf '%s\n' FLEET_MODEL FLEET_AGENT FLEET_MCP_CONFIG FLEET_DEPLOY_REF FLEET_DEPLOY_CHECK
  local k
  for k in ${_FLEET_REPO_OVERRIDABLE:-}; do printf '%s\n' "$k"; done
}
fcfg_is_repo_key() {
  case " $(fcfg_repo_keys | tr '\n' ' ') " in *" ${1:-_} "*) return 0 ;; esac
  return 1
}

# fcfg_repo_scopes SESS → "repo:<slug><US><owner/name>" per hosted repo, in
# fleet_repos order; nothing for a fleet without a repos/ overlay.
fcfg_repo_scopes() {
  local sess="${1:-}" r
  [ -n "$sess" ] || return 0
  declare -F fleet_has_repo_overlays >/dev/null 2>&1 || return 0
  fleet_has_repo_overlays "$sess" || return 0
  while IFS= read -r r; do
    [ -n "$r" ] && printf 'repo:%s%s%s\n' "$(fleet_slug "$r")" "$FCFG_US" "$r"
  done <<EOF
$(fleet_repos "$sess")
EOF
  return 0
}

# fcfg_scope_repo SESS SCOPE → owner/name for a hosted repo:<slug>; else nothing (rc 1).
fcfg_scope_repo() {
  local row
  case "${2:-}" in repo:?*) : ;; *) return 1 ;; esac
  while IFS= read -r row; do
    [ "${row%%"$FCFG_US"*}" = "$2" ] && { printf '%s' "${row#*"$FCFG_US"}"; return 0; }
  done <<EOF
$(fcfg_repo_scopes "${1:-}")
EOF
  return 1
}

# fcfg_repo_conf SESS SLUG → that repo's overlay path (may not exist yet — the
# first write creates it), or nothing when the fleet does not host it.
fcfg_repo_conf() {
  local r; r=$(fcfg_scope_repo "${1:-}" "repo:${2:-}") || return 0
  fleet_repo_conf_file "$1" "$r"
}

# fcfg_repo_effective KEY SESS REPO → "<value><US>repo|fleet|global|default": what
# REPO's windows read for KEY — the same ladder fleet_load_repo_conf applies, minus
# the sourcing (no fork per row). Its overlay wins; else the fleet conf, then the
# global layer, then the default — EXCEPT a repo-scoped identity/deploy key for a
# repo that is NOT the fleet conf's own, which fleet-lib unsets rather than inherit
# (_FLEET_REPO_SCOPED), so it falls straight to the default.
fcfg_repo_effective() {
  local key="$1" sess="${2:-}" repo="${3:-}" v fconf own
  if v=$(fcfg_file_value "$(fleet_repo_conf_file "$sess" "$repo")" "$key"); then
    printf '%s%srepo' "$v" "$FCFG_US"; return
  fi
  fconf=$(fcfg_fleet_conf "$sess")
  case " ${_FLEET_REPO_SCOPED:-} " in
    *" $key "*)
      own=$(fcfg_file_value "$fconf" FLEET_REPO); own=$(fleet_norm_repo "$own")
      if [ "$own" != "$(fleet_norm_repo "$repo")" ]; then
        printf '%s%sdefault' "$(fcfg_default "$key")" "$FCFG_US"; return
      fi ;;
  esac
  fcfg_effective "$key" "$sess"
}

# fcfg_repo_write SESS SLUG KEY VALUE TYPE — fcfg_write into the repo's overlay.
# A brand-new overlay is seeded with its FLEET_REPO first, so fleet_repos still
# lists it (the conf repo's own overlay is created this way on its first edit).
fcfg_repo_write() {
  local r f; r=$(fcfg_scope_repo "${1:-}" "repo:${2:-}") || return 1
  f=$(fleet_repo_conf_file "$1" "$r")
  [ -f "$f" ] && { fcfg_write "$f" "$3" "$4" "$5"; return; }
  fcfg_write "$f" FLEET_REPO "$r" str >/dev/null || return 1
  fcfg_write "$f" "$3" "$4" "$5" >/dev/null || return 1
  printf 'created\n'
}

# --- write-scope state (which layer edits write to) -------------------------
# NOTE: distinct from a KEY's @scope attribute (fcfg_scope above). This is the
# modal's g/f WRITE-SCOPE toggle — which conf an edit lands in. Persisted
# per-session in the dash cache dir so it survives fzf reloads.
fcfg_wscope_file()   { printf '%s/global/config_scope_%s' "${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}" "${1:-_}"; }
# A stored repo:<slug> whose repo is no longer hosted (removed, or the overlay
# gone) reads back as fleet, so a stale scope can never route an edit nowhere.
fcfg_wscope() {
  local f s; f=$(fcfg_wscope_file "${1:-}")
  if [ -f "$f" ]; then s=$(cat "$f"); else s=fleet; fi
  case "$s" in repo:*) fcfg_scope_repo "${1:-}" "$s" >/dev/null || s=fleet ;; esac
  printf '%s' "$s"
}
fcfg_wscope_set()    { local f; f=$(fcfg_wscope_file "${1:-}"); mkdir -p "$(dirname "$f")" 2>/dev/null; printf '%s' "$2" > "$f"; }
# The ⌃s cycle: fleet → global → repo:<each hosted repo> → fleet. Without a repos/
# overlay there are no repo scopes, so it is the historic fleet⇄global flip.
fcfg_wscope_toggle() {
  local cur next='' prev='' s
  cur=$(fcfg_wscope "${1:-}")
  for s in fleet global $(fcfg_repo_scopes "${1:-}" | cut -d"$FCFG_US" -f1); do
    [ "$prev" = "$cur" ] && { next=$s; break; }
    prev=$s
  done
  fcfg_wscope_set "${1:-}" "${next:-fleet}"
}
# fcfg_wscope_label SESS → the scope as the modal names it: FLEET · GLOBAL · REPO owner/name.
fcfg_wscope_label() {
  local s r; s=$(fcfg_wscope "${1:-}")
  case "$s" in
    repo:*) r=$(fcfg_scope_repo "${1:-}" "$s"); printf 'REPO %s' "$r" ;;
    *)      printf '%s' "$s" | tr '[:lower:]' '[:upper:]' ;;
  esac
}

# --- enum option sets (issue #415) ------------------------------------------
# The values an @edit=enum key accepts, each with a short annotation, as one
# "<token><US><annotation>" row per line. This is the SINGLE source of truth for
# the enum sets: BOTH the dash-config-edit picker (what you can choose) AND the
# validator below (what it accepts) read from here, so the offered set and the
# accepted set can never drift — they did before, when a free-text hint and the
# validator each hardcoded their own model-alias list and both omitted `fable`.
#
# The three model keys are latest-of-tier CLI aliases (claude --help: "an alias
# for the latest model … 'fable', 'opus', or 'sonnet'"), so the list stays
# current per-tier with no API call. `fcfg_model_aliases` is key-aware: it offers
# `inherit` only for FLEET_SUBAGENT_MODEL, the one key that accepts it. The empty
# "defer to claude's own default" value, and (model keys only) any full claude-*
# id, are ALSO valid but are handled as shapes by the caller — not tier aliases,
# so not listed here.
fcfg_is_model_key() {
  case "$1" in FLEET_MODEL|FLEET_SUBAGENT_MODEL) return 0 ;; *) return 1 ;; esac
}

fcfg_model_aliases() {
  printf '%s%s%s\n' \
    opus     "$FCFG_US" 'latest Opus (largest)' \
    sonnet   "$FCFG_US" 'latest Sonnet (balanced)' \
    haiku    "$FCFG_US" 'latest Haiku (fastest / cheapest)' \
    fable    "$FCFG_US" 'latest Fable' \
    opusplan "$FCFG_US" 'Opus to plan, Sonnet to execute' \
    default  "$FCFG_US" "claude's own default alias"
  [ "${1:-}" = FLEET_SUBAGENT_MODEL ] && \
    printf '%s%s%s\n' inherit "$FCFG_US" 'let each subagent resolve its own model'
  return 0
}

# Every enum key's option set (model keys delegate to fcfg_model_aliases; the
# small own-set enums list their tokens inline). Drives the picker for ALL enum
# keys; the selftest cross-checks that every token it emits also validates.
fcfg_enum_options() {
  case "$1" in
    FLEET_SLEEP)
      printf '%s%s%s\n' \
        observe "$FCFG_US" 'report idle candidates without exiting agents (default)' \
        on      "$FCFG_US" 'hibernate idle workers and resume on entry' \
        off     "$FCFG_US" 'disable automatic sleep scans' ;;
    FLEET_HANDOFF_DEST)
      printf '%s%s%s\n' \
        comment "$FCFG_US" 'store the handoff as an issue comment (default)' \
        file    "$FCFG_US" 'store the handoff as a file' ;;
    FLEET_MERGE_METHOD)
      printf '%s%s%s\n' \
        squash "$FCFG_US" 'squash-merge (default)' \
        merge  "$FCFG_US" 'merge commit' \
        rebase "$FCFG_US" 'rebase-merge' ;;
    FLEET_AGENT)
      printf '%s%s%s\n' \
        claude "$FCFG_US" 'Claude Code (default)' \
        codex  "$FCFG_US" 'OpenAI Codex CLI (bin/fleet-codex.sh, issue #547)' ;;
    *) fcfg_model_aliases "$1" ;;
  esac
}

# --- validation --------------------------------------------------------------
# fcfg_validate TYPE VALUE KEY → 0 (ok, no output) or 1 + a one-line reason.
# TYPE accepts either the coarse class (num|bool|enum|str) or an @edit type
# (int|path|regex map onto num/str). Guarantees the value can be written
# without breaking `source`-ing the conf.
fcfg_validate() {
  local type="$1" val="$2" key="${3:-value}"
  case "$type" in
    no)
      printf '%s is an identity key — set it in fleet.conf and re-provision' "$key"; return 1 ;;
    num|int)
      case "$val" in
        ''|*[!0-9]*) printf '%s must be a non-negative integer (got: %s)' "$key" "${val:-<empty>}"; return 1 ;;
      esac ;;
    regex)
      # must not break source-ing AND must be a valid ERE.
      case "$val" in
        *\"*)   printf '%s: value may not contain a double-quote — edit the conf by hand for that' "$key"; return 1 ;;
        *\`*)   printf '%s: value may not contain a backtick (command substitution)' "$key"; return 1 ;;
        *'$('*) printf '%s: value may not contain $(…) command substitution — edit the conf by hand for that' "$key"; return 1 ;;
        *\\)    printf '%s: value may not end in a backslash' "$key"; return 1 ;;
      esac
      # grep exits 1 on "no match" (valid pattern) but >=2 on a malformed one.
      printf '' | grep -E -- "$val" >/dev/null 2>&1
      [ "$?" -ge 2 ] && { printf '%s: not a valid extended regular expression (got: %s)' "$key" "$val"; return 1; }
      : ;;
    bool)
      case "$val" in
        0|1) : ;;
        *)   printf '%s must be 0 or 1 (got: %s)' "$key" "${val:-<empty>}"; return 1 ;;
      esac ;;
    enum)
      if [ "$key" = FLEET_SLEEP ]; then
        case "$val" in
          ''|off|observe|on) : ;;
          *) printf '%s must be off|observe|on or empty (got: %s)' "$key" "$val"; return 1 ;;
        esac
        return 0
      fi
      # FLEET_HANDOFF_DEST is an enum over its OWN small set (comment|file), not a
      # model alias — a per-key special-case shape like "inherit" for
      # FLEET_SUBAGENT_MODEL below.
      if [ "$key" = FLEET_HANDOFF_DEST ]; then
        case "$val" in
          ''|comment|file) : ;;
          *) printf '%s must be comment|file or empty (got: %s)' "$key" "$val"; return 1 ;;
        esac
        return 0
      fi
      # FLEET_MERGE_METHOD is an enum over the GitHub auto-merge strategies
      # (issue #283) — its own set, not a model alias. Empty defers to squash.
      if [ "$key" = FLEET_MERGE_METHOD ]; then
        case "$val" in
          ''|squash|merge|rebase) : ;;
          *) printf '%s must be squash|merge|rebase or empty (got: %s)' "$key" "$val"; return 1 ;;
        esac
        return 0
      fi
      # FLEET_AGENT is an enum over the agent CLIs the launcher can exec (issue
      # #547) — its own set, not a model alias. Empty defers to claude.
      if [ "$key" = FLEET_AGENT ]; then
        case "$val" in
          ''|claude|codex) : ;;
          *) printf '%s must be claude|codex or empty (got: %s)' "$key" "$val"; return 1 ;;
        esac
        return 0
      fi
      # Model-alias enum (FLEET_MODEL / FLEET_SUBAGENT_MODEL). Empty
      # (defer to claude's own default) and any full claude-* id are always fine;
      # the tier aliases come from the ONE source of truth (fcfg_model_aliases),
      # which is key-aware — it offers `inherit` only for FLEET_SUBAGENT_MODEL, so
      # this stays a single list (issue #415 also adds `fable`).
      case "$val" in ''|claude-*) return 0 ;; esac
      local _row _tok
      while IFS= read -r _row; do
        _tok=${_row%%"$FCFG_US"*}
        [ "$val" = "$_tok" ] && return 0
      done <<EOF
$(fcfg_model_aliases "$key")
EOF
      printf '%s must be a model alias (%s), a claude-* id, or empty (got: %s)' \
        "$key" "$(fcfg_model_aliases "$key" | cut -d"$FCFG_US" -f1 | paste -sd'|' -)" "$val"
      return 1 ;;
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
# passed as one argv entry so backslashes/metachars survive verbatim. The shared
# Python writer serializes dashboard and remote writes with a kernel-held lock.
fcfg_write() {
  # Use the same kernel-held lock as Fleet Hub's compare-and-set writer. A
  # dashboard edit and a remote edit must not overwrite each other's snapshot.
  python3 "$FCFG_DIR/fleet_config_write.py" "$1" "$2" "$3" "$4"
}
