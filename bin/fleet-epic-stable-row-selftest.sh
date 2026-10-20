#!/bin/bash
# fleet-epic-stable-row-selftest.sh — bin/fleet-epic-stable-row.sh, the
# 列车结果 line /fleet-epic-report writes (issue #4917; #1124's 「挪稳定版」 row
# before it). Fully hermetic: a local BARE repo stands in for github, a clone
# of it is `--main`, `gh` is a PATH shim answering from fixture files. Nothing
# touches the real `stable` tag or the network.
#
# What it pins (the report says the train's result and NEVER asks a person to
# move stable — issue #4917):
#   A. gate      a --main without bin/fleet-stable.sh → `skip`, no row (a team
#                repo's own `stable` tag is not ours to talk about)
#   B. none      no tag yet → a row that says so; the tag is NOT created
#   C. behind    tag on an older commit: target = the NEWEST merge whatever order
#                --merged came in, count right; the last release-train run says
#                running / red (卡在红车 <run>, a kind=human mark) / waiting /
#                unreadable — never a move command, never 挪稳定版
#   D. current   tag AT the last merge, or AHEAD of it → 已随列车上线, exit 1, no row
#   E. --epic    members from `sub_issues` (this repo's only, #1942), each merge from `pr list --head
#                issue-<M>`; an unfinished member is ignored; none merged →
#                `nomerge`, no row
#   F. unknown   the remote cannot be read → says so (NOT 0), still exit 0
#   G. offtrunk  stable off master → `offtrunk`, no move command promised
#   H. unknown sha  a --merged the remote does not have is skipped, not fatal
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROW="$BIN/fleet-epic-stable-row.sh"
[ -f "$ROW" ] || { printf 'selftest: %s not found\n' "$ROW" >&2; exit 2; }
[ -f "$BIN/fleet-stable.sh" ] || { printf 'selftest: fleet-stable.sh not found\n' >&2; exit 2; }
st_need git

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-epic-stable-row-selftest.XXXXXX")" || exit 2
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

st_tally count
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) st_fail "$1 — output does not contain [$3]:
$2";; esac; }
lacks() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) st_fail "$1 — output should not contain [$3]:
$2";; esac; }

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"

# gh shim: `gh api …/sub_issues` → $WORK/subs; `gh api …/release-train.yml/runs` →
# $WORK/train (status TAB conclusion TAB head sha TAB url rows; absent = unreadable);
# `gh pr list … --head X …` → $WORK/prs/X (one sha, the merge commit) or nothing
# when the member has no merged PR.
mkdir -p "$WORK/shim" "$WORK/prs"
cat > "$WORK/shim/gh" <<SH
#!/bin/sh
case "\$1" in
  api) case "\$2" in
         *release-train*) [ -f "$WORK/train" ] && cat "$WORK/train" || exit 1 ;;
         *) cat "$WORK/subs" ;;
       esac ;;
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
st_eq "A: no bin/fleet-stable.sh in --main → exit 1" 1 "$RC"
st_eq "A: kind skip" skip "$(kind)"
lacks "A: no row" "$OUT" "row:"
mkdir -p "$CO/bin" && cp "$BIN/fleet-stable.sh" "$CO/bin/fleet-stable.sh"

# --- B. none ---------------------------------------------------------------------
deltag
run --merged "$C2" --merged "$C3"
st_eq "B: no tag → a row is due (exit 0)" 0 "$RC"
st_eq "B: kind none" none "$(kind)"
contains "B: row says there is no stable mark" "$OUT" "还没有稳定版标记"
lacks "B: no move command" "$OUT" "fleet-stable.sh move"
st_eq "B: the tag was NOT created" none "$(tag)"

# --- C. behind: the train's result ----------------------------------------------
settag "$C1"
rm -f "$WORK/train"
run --merged "$C3" --merged "$C2"          # reverse order on purpose
st_eq "C: train unreadable → exit 0" 0 "$RC"
st_eq "C: kind trainunknown" trainunknown "$(kind)"
contains "C: target is the newest merge (C3), not the last argument" "$OUT" "target:  $(sh3 "$C3")"
contains "C: count is stable..target" "$OUT" "behind:  2"
printf 'in_progress\t-\t%s\thttps://x/run/9\ncompleted\tfailure\t%s\thttps://x/run/8\n' "$C3" "$C3" > "$WORK/train"
run --merged "$C3"
st_eq "C: a train in progress → kind running" running "$(kind)"
contains "C: line 列车在跑" "$OUT" "line:    列车在跑（https://x/run/9）"
lacks "C: running → no mark" "$OUT" "mark:"
printf 'completed\tfailure\t%s\thttps://x/run/8\n' "$C4" > "$WORK/train"
run --merged "$C3"
st_eq "C: last train red, it boarded the batch → kind red" red "$(kind)"
contains "C: line 卡在红车 <run>" "$OUT" "line:    卡在红车 https://x/run/8"
contains "C: tr" "$OUT" "<tr><td>本批最后一次合并"
contains "C: red → a human mark naming the run" "$OUT" "mark:    <!-- fleet:followup kind=human what=列车红在 https://x/run/8"
printf 'completed\tfailure\t%s\thttps://x/run/7\n' "$C1" > "$WORK/train"
run --merged "$C3"
st_eq "C: red train that never boarded the batch → waiting" waiting "$(kind)"
printf 'completed\tsuccess\t%s\thttps://x/run/6\n' "$C1" > "$WORK/train"
run --merged "$C3"
st_eq "C: green train before the batch → waiting" waiting "$(kind)"
contains "C: waiting names the next train" "$OUT" "等下一趟"
contains "C: tr renders the command as <code>" "$OUT" "<code>gh workflow run release-train.yml</code>"
lacks "C: never a move command" "$OUT" "fleet-stable.sh move"
lacks "C: never 挪稳定版" "$OUT" "挪稳定版"
lacks "C: never a kind=stable followup" "$OUT" "kind=stable"
st_eq "C: the tag did not move" "$C1" "$(tag)"

# --- D. current ------------------------------------------------------------------
settag "$C3"
run --merged "$C2" --merged "$C3"
st_eq "D: stable AT the last merge → exit 1" 1 "$RC"
st_eq "D: kind current" current "$(kind)"
contains "D: 已随列车上线" "$OUT" "line:    已随列车上线（stable = $(sh3 "$C3")）"
lacks "D: no row" "$OUT" "row:"
settag "$C4"
run --merged "$C3"
st_eq "D: stable AHEAD of the batch → exit 1" 1 "$RC"
st_eq "D: kind current (ahead)" current "$(kind)"
lacks "D: no row (ahead)" "$OUT" "row:"

# --- E. --epic via gh ------------------------------------------------------------
settag "$C1"
printf '10\n11\n12\n' > "$WORK/subs"
printf '%s\n' "$C2" > "$WORK/prs/issue-10"
printf '%s\n' "$C3" > "$WORK/prs/issue-11"      # issue-12: no merged PR
run --epic 7
st_eq "E: --epic → exit 0" 0 "$RC"
st_eq "E: kind waiting" waiting "$(kind)"
contains "E: target = newest member merge" "$OUT" "target:  $(sh3 "$C3")"
contains "E: behind 2" "$OUT" "behind:  2"
printf '12\n' > "$WORK/subs"
run --epic 7
st_eq "E: no member merged → exit 1" 1 "$RC"
st_eq "E: kind nomerge" nomerge "$(kind)"
lacks "E: no row" "$OUT" "row:"
run --epic x
st_eq "E: --epic wants a number → exit 2" 2 "$RC"
# an EPIC spanning repos (issue #1942): another repo's member #12 is NOT this
# repo's issue-12 branch — only o/r's own members name a merge here
printf 'o/r\t10\no/b\t12\n' > "$WORK/subs"
printf '%s\n' "$C4" > "$WORK/prs/issue-12"
run --epic 7
st_eq "E: cross-repo EPIC → exit 0" 0 "$RC"
contains "E: target = this repo's member merge" "$OUT" "target:  $(sh3 "$C2")"
lacks "E: o/b#12 never read as o/r's issue-12" "$OUT" "$(sh3 "$C4")"
run --epic o/b#7                                  # the parent lives in o/b
st_eq "E: --epic owner/name#N (a parent in another repo) → exit 0" 0 "$RC"
contains "E: …still only this repo's members" "$OUT" "target:  $(sh3 "$C2")"
rm -f "$WORK/prs/issue-12"

# --- F. unknown ------------------------------------------------------------------
settag "$C1"
run --merged "$C3" --remote nowhere
st_eq "F: unreadable remote → still a row (exit 0)" 0 "$RC"
st_eq "F: kind unknown" unknown "$(kind)"
contains "F: says it could not read, not 0" "$OUT" "不是 0"
lacks "F: no move command" "$OUT" "fleet-stable.sh move"
contains "F: a human mark" "$OUT" "kind=human"

# --- G. offtrunk -----------------------------------------------------------------
settag "$S1"
run --merged "$C3"
st_eq "G: offtrunk → exit 0" 0 "$RC"
st_eq "G: kind offtrunk" offtrunk "$(kind)"
contains "G: row says stable is off trunk" "$OUT" "不在 origin/master 上"
lacks "G: no move promised in the next cell" "$OUT" "挪稳定版"
st_eq "G: the tag did not move" "$S1" "$(tag)"

# --- H. unknown sha --------------------------------------------------------------
settag "$C1"
run --merged 0000000000000000000000000000000000000000 --merged "$C2"
st_eq "H: an unknown sha is skipped, the rest still counts" 0 "$RC"
contains "H: skip note" "$OUT" "skipping 0000000"
contains "H: target = the known one" "$OUT" "target:  $(sh3 "$C2")"
run --merged 0000000000000000000000000000000000000000
st_eq "H: only unknown shas → nomerge" 1 "$RC"
st_eq "H: kind nomerge" nomerge "$(kind)"

echo "fleet-epic-stable-row-selftest OK ($CHECKS checks)"
