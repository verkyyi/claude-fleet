#!/bin/bash
# fleet-handoff-file.sh — where a FILE handoff is written, and which one an
# argument-free pickup resumes (issue #992). The comment-mode handoff (an
# issue-bound worker) and an explicit `pickup <path>` never come here.
#
#   fleet-handoff-file.sh path [--slug S] [opts]   # the file C2 case 3 writes
#   fleet-handoff-file.sh repo [opts]              # the doc's `Repo:` line value
#   fleet-handoff-file.sh find [opts]              # the file §P step 3 resumes
#   fleet-handoff-file.sh check <doc|-> [--issue N] [--issue-body F] [--repo R]
#                                                  # is the doc short enough to hand on?
#
#   opts: --session S   the fleet (default: this pane's)
#         --repo R      the pane's repo (default: fleet_window_repo of $TMUX_PANE)
#         --norepo      the pane deliberately has none (the hub of a 2+ repo fleet)
#   FLEET_HANDOFF_DIR   the store (default ~/.claude/handoff)
#
# WHY. A fleet hosts several repos now (#788), and folds retire whole fleets into
# another (#796). A handoff named only `<session>-<date>.md` and found as "the
# newest `<session>-*.md`" resumes ANOTHER repo's task in a scratch of this one,
# and never finds a handoff written under a folded fleet's old name.
#
# NAMING. A one-repo fleet keeps `<session>-<YYYY-MM-DD>[-<slug>].md` byte for
# byte. A 2+ repo fleet, for a pane whose repo is known, puts the repo's slug in:
# `<session>-<owner-name>-<YYYY-MM-DD>[-<slug>].md`. Every doc also carries a
# `Repo: <owner/name|none>` line (skills/handoff/SKILL.md).
#
# FIND. Candidates are `<session>-*.md` plus `<from>-*.md` for every fleet folded
# into this one — the fold archives `$FLEET_CONF_DIR/archive/<from>-folded-into-
# <session without fleet->-<YYYYMMDD>[-HHMMSS]`, whose conf says which repo(s)
# <from> hosted. A one-repo fleet takes the newest of them all (today's rule).
# A 2+ repo fleet attributes each file to a repo, first hit wins:
#   1. a hosted repo's slug right after the fleet prefix (the new name);
#   2. the doc's `Repo:` line;
#   3. a folded fleet that hosted exactly one repo → that repo;
#   4. exactly one hosted repo's owner/name named in the doc;
#   5. else unknown.
# and walks newest-first: another repo's file is skipped, the pane's is taken —
# unless an UNKNOWN one is newer, which might be the pane's own later work. That
# case, and "nothing of mine, only others'/unknowns", never guesses: exit 4 with
# the candidates listed, for the skill to ASK.
#
# CHECK (issue #1322). Every line of a handoff is context the pickup session
# spends before doing anything, so a doc that keeps growing — or that pastes the
# issue body the pickup can read for itself — hands on a smaller window. `check`
# reads the composed doc (a file, or `-` = stdin for a comment-mode doc) BEFORE it
# is stored and prints one `HANDOFF-CHECK:` line per finding:
#   - more than FLEET_HANDOFF_MAX_LINES lines (default 200; 0 = no line cap);
#   - FLEET_HANDOFF_COPY_LINES (default 5; 0 = off) or more substantive lines
#     copied from the bound issue's body (--issue N, else this pane's @issue; read
#     through fleet-gh.sh — or --issue-body F, a file holding the body).
#     Lines are compared after stripping list/quote/heading markers and spacing;
#     short lines (< 16 bytes), fences and table rules never count.
# It is advice, never a gate: the caller trims and rewrites, then stores either way.
#
# EXIT: 0 path printed / check clean · 1 no handoff file at all · 2 usage / no
#       fleet · 3 check found something (lines printed) ·
#       4 AMBIGUOUS — stdout is `<path>\t<repo|?>\t<mtime>` per candidate.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-handoff-file: %s\n' "$1" >&2; exit "${2:-2}"; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
SESS='' REPO='' REPO_SET=0 SLUG='' ISSUE='' ISSUE_BODY='' DOCARG=''
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)      ISSUE=$(printf '%s' "${2:-}" | tr -dc 0-9); shift 2 ;;
    --issue-body) ISSUE_BODY="${2:-}"; shift 2 ;;
    --session) SESS="${2:-}"; shift 2 ;;
    --repo)    REPO=$(fleet_norm_repo "${2:-}"); REPO_SET=1; shift 2 ;;
    --norepo)  REPO=''; REPO_SET=1; shift ;;
    --slug)    SLUG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    -) [ "$cmd" = check ] && [ -z "$DOCARG" ] || die "unexpected argument: -"; DOCARG=-; shift ;;
    -*) die "unknown argument: $1" ;;
    *) [ "$cmd" = check ] && [ -z "$DOCARG" ] || die "unknown argument: $1"; DOCARG=$1; shift ;;
  esac
done
case "$cmd" in path|repo|find|check) ;; *) die "usage: fleet-handoff-file.sh path|repo|find|check [opts]" ;; esac

# ---- check ------------------------------------------------------------------
# Needs no fleet: it judges a doc, and the issue body comes from a flag or the pane.
if [ "$cmd" = check ]; then
  [ -n "$DOCARG" ] || die "usage: fleet-handoff-file.sh check <doc|-> [--issue N] [--issue-body F]"
  T=$(mktemp -d "${TMPDIR:-/tmp}/fhf-check.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$T"' EXIT
  if [ "$DOCARG" = - ]; then
    cat > "$T/doc"; doc="$T/doc"; label='the handoff'
  else
    [ -r "$DOCARG" ] || die "cannot read $DOCARG"
    doc="$DOCARG"; label="$DOCARG"
  fi
  max="${FLEET_HANDOFF_MAX_LINES:-200}"; case "$max" in ''|*[!0-9]*) max=200 ;; esac
  cmax="${FLEET_HANDOFF_COPY_LINES:-5}"; case "$cmax" in ''|*[!0-9]*) cmax=5 ;; esac
  found=0
  n=$(awk 'END { print NR }' "$doc")
  if [ "$max" -gt 0 ] && [ "$n" -gt "$max" ]; then
    printf 'HANDOFF-CHECK: %s is %s lines (> FLEET_HANDOFF_MAX_LINES=%s) — the pickup session reads every line before it works; trim to the NEXT ACTION, live state and dead-ends, then rewrite it\n' "$label" "$n" "$max"
    found=1
  fi
  # The issue body to compare against: a file, else the issue (flag, then @issue).
  body=''
  if [ "$cmax" -gt 0 ]; then
    if [ -n "$ISSUE_BODY" ]; then
      [ -r "$ISSUE_BODY" ] && body=$ISSUE_BODY
    else
      [ -z "$ISSUE" ] && [ -n "${TMUX_PANE:-}" ] \
        && ISSUE=$(tmux display-message -p -t "$TMUX_PANE" '#{@issue}' 2>/dev/null | tr -dc 0-9)
      if [ -n "$ISSUE" ]; then
        set -- issue view "$ISSUE" --json body
        [ -n "$REPO" ] && set -- "$@" --repo "$REPO"
        if "$BIN/fleet-gh.sh" "$@" 2>/dev/null \
             | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("body") or "")' > "$T/body" 2>/dev/null; then
          body="$T/body"
        else
          echo "fleet-handoff-file: could not read issue #$ISSUE's body — copy check skipped" >&2
        fi
      fi
    fi
  fi
  if [ -n "$body" ]; then
    copied=$(awk -v MIN=16 '
      function norm(s) {
        gsub(/\r/, "", s); sub(/^[ \t]+/, "", s)
        while (s ~ /^([-*+>#]+|[0-9]+[.)]|\[[ xX]\])[ \t]+/) sub(/^([-*+>#]+|[0-9]+[.)]|\[[ xX]\])[ \t]+/, "", s)
        gsub(/[ \t]+/, " ", s); sub(/ $/, "", s)
        if (s ~ /^(```|~~~|<!--)/ || s ~ /^\|? *:?-+:? *(\||$)/ || length(s) < MIN) return ""
        return s
      }
      NR == FNR { k = norm($0); if (k != "") seen[k] = 1; next }
      { k = norm($0); if (k != "" && (k in seen)) { c++; if (c <= 3) at = at (at == "" ? "" : ",") FNR } }
      END { if (c) print c, at }' "$body" "$doc")
    c=${copied%% *}
    if [ -n "$copied" ] && [ "$c" -ge "$cmax" ]; then
      src='the issue'; [ -n "$ISSUE" ] && src="issue #$ISSUE"
      printf 'HANDOFF-CHECK: %s copies %s lines of %s'"'"'s body (at lines %s…) — the pickup session can read the issue itself; replace the copy with a pointer to it\n' \
        "$label" "$c" "$src" "${copied#* }"
      found=1
    fi
  fi
  [ "$found" = 0 ] && exit 0
  exit 3
fi

[ -n "$SESS" ] || SESS=$(fleet_current_session)
[ -n "$SESS" ] || die "not inside a fleet (pass --session)"
[ "$REPO_SET" = 1 ] || REPO=$(fleet_window_repo "$SESS" "${TMUX_PANE:-}")
DIR="${FLEET_HANDOFF_DIR:-$HOME/.claude/handoff}"

MULTI=0; fleet_multirepo "$SESS" && MULTI=1

if [ "$cmd" = repo ]; then
  printf '%s\n' "${REPO:-none}"; exit 0
fi

if [ "$cmd" = path ]; then
  name="$SESS"
  [ "$MULTI" = 1 ] && [ -n "$REPO" ] && name="$name-$(fleet_slug "$REPO")"
  name="$name-$(date +%Y-%m-%d)"
  [ -n "$SLUG" ] && name="$name-$(fleet_slug "$SLUG")"
  printf '%s/%s.md\n' "$DIR" "$name"; exit 0
fi

# ---- find -------------------------------------------------------------------
[ -n "${ZSH_VERSION:-}" ] && setopt null_glob
# The prefixes to search: this fleet, then each fleet folded into it, with the
# repo(s) each hosted — `<prefix>\t<repo> <repo>…`.
prefixes="$SESS	$(fleet_repos "$SESS" | tr '\n' ' ')"
into="${SESS#fleet-}"
for d in "$FLEET_CONF_DIR/archive/"*-folded-into-"$into"-*; do
  [ -d "$d" ] || continue
  b=${d##*/}; from=${b%%-folded-into-*}; tail=${b#"$from-folded-into-$into-"}
  printf '%s' "$tail" | grep -Eq '^[0-9]{8}(-[0-9]{6})?$' || continue
  repos=''
  for f in "$d/conf" "$d/repos/"*.conf; do
    [ -f "$f" ] || continue
    r=$( unset FLEET_REPO; . "$f" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    r=$(fleet_norm_repo "$r")
    case "$r" in ?*/?*) case " $repos " in *" $r "*) ;; *) repos="$repos$r " ;; esac ;; esac
  done
  prefixes="$prefixes
$from	$repos"
done

# Every repo a name or a doc can be attributed to: this fleet's and the folded ones'.
known=$(printf '%s\n' "$prefixes" | cut -f2 | tr ' ' '\n' | grep . | sort -u)

cands=()
while IFS='	' read -r p _; do
  [ -n "$p" ] || continue
  for f in "$DIR/$p-"*.md; do [ -f "$f" ] && cands+=("$f"); done
done <<EOF
$prefixes
EOF
[ "${#cands[@]}" -gt 0 ] || exit 1

newest=$(ls -1t -- ${cands[@]+"${cands[@]}"} 2>/dev/null)

if [ "$MULTI" = 0 ]; then
  printf '%s\n' "$newest" | head -n1; exit 0
fi

# attr <file> → the repo it belongs to, `none`, or `?`.
attr() {
  local f="$1" b rest p repos r best='' hits='' n=0 line
  b=${f##*/}; b=${b%.md}
  # The longest fleet prefix it carries (a folded `fleet-a` must not eat `fleet-a-b`).
  p=''; repos=''
  while IFS='	' read -r pp rr; do
    [ -n "$pp" ] || continue
    case "$b" in "$pp-"*) [ "${#pp}" -gt "${#p}" ] && { p=$pp; repos=$rr; } ;; esac
  done <<EOF
$prefixes
EOF
  rest=${b#"$p-"}
  # 1. the new name: a known repo's slug right after the prefix (longest wins).
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$rest" in "$(fleet_slug "$r")-"*) [ "${#r}" -gt "${#best}" ] && best=$r ;; esac
  done <<EOF
$known
EOF
  [ -n "$best" ] && { printf '%s' "$best"; return; }
  # 2. the doc's own `Repo:` line (skeleton field; tolerate **bold** / `code`).
  line=$(head -n 20 "$f" 2>/dev/null | grep -m1 -E '^[*_]*Repo[*_]*:' | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[`*]//g' -e 's/[[:space:]].*$//')
  case "$line" in
    none|-|—|'') ;;
    *) r=$(fleet_norm_repo "$line"); case "$r" in ?*/?*) printf '%s' "$r"; return ;; esac ;;
  esac
  case "$line" in none|-|—) printf 'none'; return ;; esac
  # 3. a folded fleet that hosted one repo: its files are that repo's.
  if [ "$p" != "$SESS" ]; then
    set -- $repos
    [ $# = 1 ] && { printf '%s' "$1"; return; }
  fi
  # 4. content: exactly one known repo named in the doc.
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    grep -qF -- "$r" "$f" 2>/dev/null && { hits=$r; n=$((n+1)); }
  done <<EOF
$known
EOF
  [ "$n" = 1 ] && { printf '%s' "$hits"; return; }
  printf '?'
}

want="${REPO:-none}"
row() { printf '%s\t%s\t%s\n' "$1" "$2" "$(date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null)"; }
unknown=''
while IFS= read -r f; do
  [ -n "$f" ] || continue
  a=$(attr "$f")
  if [ "$a" = "$want" ]; then
    if [ -z "$unknown" ]; then printf '%s\n' "$f"; exit 0; fi
    printf '%s' "$unknown"; row "$f" "$a"
    echo "AMBIGUOUS: the newest handoff for $want is older than one whose repo is unknown — ask which to resume" >&2
    exit 4
  fi
  [ "$a" = '?' ] && unknown="$unknown$(row "$f" "$a")
"
done <<EOF
$newest
EOF

# Nothing is this pane's: list the newest few, never pick one.
printf '%s\n' "$newest" | head -n 10 | while IFS= read -r f; do [ -n "$f" ] && row "$f" "$(attr "$f")"; done
echo "AMBIGUOUS: no handoff file is attributed to $want — only other repos' or unknown ones; ask which to resume" >&2
exit 4
