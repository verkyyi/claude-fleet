#!/bin/bash
# fleet-epic-stable-row-selftest.sh — bin/fleet-epic-stable-row.sh, the
# 「挪稳定版」 row /fleet-epic-report adds to its 还差什么 table (issue #1124,
# EPIC #1117 R2). Fully hermetic: a local BARE repo stands in for github, a clone
# of it is `--main`, `gh` is a PATH shim answering from fixture files. Nothing
# touches the real `stable` tag or the network.
#
# What it pins (the issue's 完成判据: the row appears when stable trails the
# batch, and ONLY then):
#   A. gate      a --main without bin/fleet-stable.sh → `skip`, no row (a team
#                repo's own `stable` tag is not ours to talk about)
#   B. none      no tag yet → a row that says so, with the move command; the tag
#                is NOT created (the row proposes, never moves)
#   C. behind    tag on an older commit → `behind`, target = the NEWEST merge
#                whatever order --merged came in, count right, cmd names it
#   D. current   tag AT the last merge, or AHEAD of it → exit 1, no row
#   E. --epic    members from `sub_issues`, each merge from `pr list --head
#                issue-<M>`; an unfinished member is ignored; none merged →
#                `nomerge`, no row
#   F. unknown   the remote cannot be read → says so (NOT 0), still exit 0
#   G. offtrunk  stable off master → `offtrunk`, no move command promised
#   H. unknown sha  a --merged the remote does not have is skipped, not fatal
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROW="$BIN/fleet-epic-stable-row.sh"
[ -f "$ROW" ] || { printf 'selftest: %s not found\n' "$ROW" >&2; exit 2; }
[ -f "$BIN/fleet-stable.sh" ] || { printf 'selftest: fleet-stable.sh not found\n' >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "fleet-epic-stable-row-selftest SKIP (no git)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-epic-stable-row-selftest.XXXXXX")" || exit 2
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]:
$2";; esac; }
lacks() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output should not contain [$3]:
$2";; esac; }

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"

# gh shim: `gh api …/sub_issues` → $WORK/subs; `gh pr list … --head X …` → $WORK/prs/X
# (one sha, the merge commit) or nothing when the member has no merged PR.
mkdir -p "$WORK/shim" "$WORK/prs"
cat > "$WORK/shim/gh" <<SH
#!/bin/sh
case "\$1" in
  api) cat "$WORK/subs" ;;
  pr)  head=""; while [ "\$#" -gt 0 ]; do [ "\$1" = --head ] && { head="\$2"; break; }; shift; done
       [ -n "\$head" ] && [ -f "$WORK/prs/\$head" ] && cat "$WORK/prs/\$head" ;;
esac
exit 0
SH
chmod +x "$WORK/shim/gh"
export PATH="$WORK/shim:$PATH"

BARE="$WORK/origin.git" SEED="$WORK/seed" CO="$WORK/co"
git init -q --bare -b master "$BARE"
git clone -q "$BARE" "$SEED" 2>/dev/null
n=0
# distinct commit times, so "newest merge" is never a tie
commit() { n=$((n + 1)); echo "$1" >> "$SEED/f"; git -C "$SEED" add f
           GIT_COMMITTER_DATE="2026-01-01T00:0${n}:00Z" GIT_AUTHOR_DATE="2026-01-01T00:0${n}:00Z" git -C "$SEED" commit -qm "$1"
           git -C "$SEED" rev-parse HEAD; }
C1=$(commit one); C2=$(commit two); C3=$(commit three); C4=$(commit four)
git -C "$SEED" push -q origin HEAD:master
# a side branch off C1 that never reaches master (for G)
git -C "$SEED" checkout -q -b side "$C1"; S1=$(commit side-one); git -C "$SEED" push -q origin side; git -C "$SEED" checkout -q master
git clone -q "$BARE" "$CO" 2>/dev/null
sh3() { git -C "$CO" rev-parse --short "$1"; }

settag() { git --git-dir="$BARE" update-ref refs/tags/stable "$1"; }
deltag() { git --git-dir="$BARE" update-ref -d refs/tags/stable 2>/dev/null || :; }
tag() { git --git-dir="$BARE" rev-parse -q --verify refs/tags/stable 2>/dev/null || echo none; }
run() { OUT=$(sh "$ROW" --repo o/r --main "$CO" "$@" 2>&1); RC=$?; }
kind() { printf '%s\n' "$OUT" | sed -n 's/^kind:[[:space:]]*//p'; }

# --- A. gate ---------------------------------------------------------------------
run --merged "$C3"
eq "A: no bin/fleet-stable.sh in --main → exit 1" 1 "$RC"
eq "A: kind skip" skip "$(kind)"
lacks "A: no row" "$OUT" "row:"
mkdir -p "$CO/bin" && cp "$BIN/fleet-stable.sh" "$CO/bin/fleet-stable.sh"

# --- B. none ---------------------------------------------------------------------
deltag
run --merged "$C2" --merged "$C3"
eq "B: no tag → a row is due (exit 0)" 0 "$RC"
eq "B: kind none" none "$(kind)"
contains "B: row says there is no stable mark" "$OUT" "还没有稳定版标记"
contains "B: cmd names the newest merge" "$OUT" "fleet-stable.sh move $(sh3 "$C3")"
eq "B: the tag was NOT created" none "$(tag)"

# --- C. behind -------------------------------------------------------------------
settag "$C1"
run --merged "$C3" --merged "$C2"          # reverse order on purpose
eq "C: behind → exit 0" 0 "$RC"
eq "C: kind behind" behind "$(kind)"
contains "C: target is the newest merge (C3), not the last argument" "$OUT" "target:  $(sh3 "$C3")"
contains "C: count is stable..target" "$OUT" "behind:  2"
contains "C: row names the stable sha" "$OUT" "稳定版还停在 $(sh3 "$C1")"
contains "C: cmd" "$OUT" "cmd:     "
contains "C: cmd is fleet-stable.sh move <target>" "$OUT" "fleet-stable.sh move $(sh3 "$C3")"
contains "C: tr renders the command as <code>" "$OUT" "<tr><td>稳定版还停在"
contains "C: tr has code" "$OUT" "<code>"
eq "C: the tag did not move" "$C1" "$(tag)"

# --- D. current ------------------------------------------------------------------
settag "$C3"
run --merged "$C2" --merged "$C3"
eq "D: stable AT the last merge → exit 1" 1 "$RC"
eq "D: kind current" current "$(kind)"
lacks "D: no row" "$OUT" "row:"
settag "$C4"
run --merged "$C3"
eq "D: stable AHEAD of the batch → exit 1" 1 "$RC"
eq "D: kind current (ahead)" current "$(kind)"
lacks "D: no row (ahead)" "$OUT" "row:"

# --- E. --epic via gh ------------------------------------------------------------
settag "$C1"
printf '10\n11\n12\n' > "$WORK/subs"
printf '%s\n' "$C2" > "$WORK/prs/issue-10"
printf '%s\n' "$C3" > "$WORK/prs/issue-11"      # issue-12: no merged PR
run --epic 7
eq "E: --epic → exit 0" 0 "$RC"
eq "E: kind behind" behind "$(kind)"
contains "E: target = newest member merge" "$OUT" "target:  $(sh3 "$C3")"
contains "E: behind 2" "$OUT" "behind:  2"
printf '12\n' > "$WORK/subs"
run --epic 7
eq "E: no member merged → exit 1" 1 "$RC"
eq "E: kind nomerge" nomerge "$(kind)"
lacks "E: no row" "$OUT" "row:"
run --epic x
eq "E: --epic wants a number → exit 2" 2 "$RC"

# --- F. unknown ------------------------------------------------------------------
settag "$C1"
run --merged "$C3" --remote nowhere
eq "F: unreadable remote → still a row (exit 0)" 0 "$RC"
eq "F: kind unknown" unknown "$(kind)"
contains "F: says it could not read, not 0" "$OUT" "不是 0"
contains "F: still hands over the move command" "$OUT" "fleet-stable.sh move $(sh3 "$C3")"

# --- G. offtrunk -----------------------------------------------------------------
settag "$S1"
run --merged "$C3"
eq "G: offtrunk → exit 0" 0 "$RC"
eq "G: kind offtrunk" offtrunk "$(kind)"
contains "G: row says stable is off trunk" "$OUT" "不在 origin/master 上"
lacks "G: no move promised in the next cell" "$OUT" "挪稳定版到"
eq "G: the tag did not move" "$S1" "$(tag)"

# --- H. unknown sha --------------------------------------------------------------
settag "$C1"
run --merged 0000000000000000000000000000000000000000 --merged "$C2"
eq "H: an unknown sha is skipped, the rest still counts" 0 "$RC"
contains "H: skip note" "$OUT" "skipping 0000000"
contains "H: target = the known one" "$OUT" "target:  $(sh3 "$C2")"
run --merged 0000000000000000000000000000000000000000
eq "H: only unknown shas → nomerge" 1 "$RC"
eq "H: kind nomerge" nomerge "$(kind)"

echo "fleet-epic-stable-row-selftest OK ($CHECKS checks)"
