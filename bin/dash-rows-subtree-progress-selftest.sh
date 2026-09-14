#!/bin/bash
# dash-rows-subtree-progress-selftest.sh — the parent row's subtree progress badge
# (issue #624).
#
# scratch-as-parent (one scratch that fans out N workers) had every primitive but
# the total: #503 resolves the @origin chain and indents the group, #574 has each
# child push its own outcome home — and nowhere did a row say "3 of my 5 are
# done". This pins the badge that closes that:
#
#   R  内容工厂方案            3/5 ✓ · 1!
#                             ╰──┬──╯ ╰┬╯
#                          quiet ┘     └ LOUD — a child is asking for the operator
#
# The rules under test:
#   * a row that spawned work shows `<done>/<total> ✓` over its whole subtree;
#   * `· <n>!` appears ONLY when a descendant is in `needs`, and only that half is
#     red — the dash's loud/quiet hierarchy (only needs is loud) must survive;
#   * attribution is #503's grouping VERBATIM: a grandchild counts toward the
#     ultimate live root, the row it actually renders under — so an intermediate
#     parent shows nothing and no window is counted twice;
#   * an ORPHAN (its @origin names a window that is gone) counts toward nobody;
#   * a row with NO children draws NOTHING — the badge must not become noise on
#     every line;
#   * and the badge must not break the right-pinned act/PR/ctx block, including
#     on a CJK-named parent, where the window cell goes through the #534 wcwidth
#     path and a code-point pad would already have shoved the row sideways. That
#     last one is checked the strict way: EVERY row is asserted to be exactly
#     `FZF_COLUMNS - 4` display columns wide, badge or no badge.
#
# Fully hermetic: `tmux` is PATH-shimmed to replay a fixture window list (never a
# live server, per the repo rail — and it keeps the test off the tmux version,
# since tmux ≤3.4 vis-escapes the 0x1f field separator the producer asks for). No
# gh, no git, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dashkids-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"                    # fleet_cache's $C lands in the sandbox
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"       # …and so does the #566 @wid allocation lock
mkdir -p "$WORK/.claude-dash/global" "$WORK/conf"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }

US=$'\x1f'
GY='38;2;86;95;137m'        # muted grey — the quiet half of the badge
RD='38;2;247;118;142m'      # red        — the loud half (a child needs the operator)
SESS=fleet-testrepo
COLS=140                    # ⇒ every row is exactly COLS-4 display columns

# --- tmux shim: replay a fixed window list, no-op everything else --------------
# Same shim as dash-rows-scratch-id-selftest.sh: only the producer's
# `list-windows -a -F <0x1f-separated fmt>` gets the fixture; #566's own
# `-F '#{@wid}'` handle scan must NOT (it would read as N taken handles).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037')
lw=0; fmt=0
for a in "$@"; do
  [ "$a" = list-windows ] && lw=1
  case "$a" in *"$US"*) fmt=1 ;; esac
done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH

# --- fixture windows ----------------------------------------------------------
# Field order MUST match WFMT in tmux-dashboard-rows.sh:
#   session idx name path state state_ts window_id @issue @origin @worktree
WLIST_FILE="$WORK/wlist"; export WLIST_FILE
w() { printf '%s\n' "$SESS$US$1$US$2$US$3$US$4$US$US$5$US$6$US$7$US$8" >> "$WLIST_FILE"; }
: > "$WLIST_FILE"
#   idx name      cwd                 state    wid @issue @origin   @worktree
# R = a hub-spawned root with a 5-window subtree: 3 done, 1 working, 1 needs.
w 1  R           /w/repo-issue-100    idle     @1  100 ''          /w/repo-issue-100
w 2  kid-done    /w/repo-issue-101    done     @2  101 issue-100   /w/repo-issue-101
w 3  kid-done2   /w/repo-issue-102    done     @3  102 issue-100   /w/repo-issue-102
w 4  kid-work    /w/repo-issue-103    working  @4  103 issue-100   /w/repo-issue-103
w 5  kid-needs   /w/repo-issue-104    needs    @5  104 issue-100   /w/repo-issue-104
# a GRANDCHILD (spawned by kid-done, not by R) — #503 groups it under R, so #624
# must COUNT it under R too, and kid-done itself must stay bare.
w 6  grandkid    /w/repo-issue-105    done     @6  105 issue-101   /w/repo-issue-105
# a root that never spawned anything → no badge at all.
w 7  lonely      /w/repo-issue-200    idle     @7  200 ''          /w/repo-issue-200
# an ORPHAN: @origin names a window that is not on this dash → counts for nobody.
w 8  orph        /w/repo-issue-300    done     @8  300 issue-999   /w/repo-issue-300
# a CJK-named SCRATCH parent with 2 children, neither in needs → `1/2 ✓`, no `!`.
w 9  修复仪表盘   /w/repo-scratch-7    idle     @9  ''  ''          /w/repo-scratch-7
w 10 s-kid-done  /w/repo-issue-401    done     @10 401 scratch-7   /w/repo-issue-401
w 11 s-kid-idle  /w/repo-issue-402    idle     @11 402 scratch-7   /w/repo-issue-402

out=$(FLEET_SESSION="$SESS" FZF_COLUMNS=$COLS bash "$ROWS" 2>&1) \
  || fail "rows producer exited non-zero" "$out"
row_of() { printf '%s\n' "$out" | grep -F "$SESS:$1$US"; }
rR=$(row_of 1); rKid=$(row_of 2); rLone=$(row_of 7); rOrph=$(row_of 8); rCJK=$(row_of 9)
for v in rR rKid rLone rOrph rCJK; do
  [ -n "${!v}" ] || fail "rows: fixture window for ${v#r} missing from output" "$out"
done
CHECKS=$((CHECKS+5))

# 1. the headline: 5 descendants (4 children + 1 grandchild), 3 of them done, and
#    a loud marker for the one asking for the operator.
has "parent row shows <done>/<total> over the WHOLE subtree" "$rR" "3/5 ✓"
has "parent row shows the needs marker"                      "$rR" "1!"
# …and it must be `5`, never `4` — the grandchild is part of the group under R.
hasnt "the grandchild must be counted (total is 5, not 4)"   "$rR" "/4 ✓"

# 2. loud/quiet: the count is muted grey, ONLY the needs marker is red. A future
#    change that paints the whole badge red (or the needs count grey) fails here —
#    the dash's one rule is that only `needs` is loud.
has "the done/total half is muted grey" "$rR" $'\033['"$GY"'3/5 ✓'
has "the needs half is RED"             "$rR" $'\033['"$RD"'1!'
hasnt "the done/total half must not be red" "$rR" $'\033['"$RD"'3/5'

# 3. attribution = #503's grouping, verbatim. kid-done spawned grandkid, but the
#    grandchild renders under R, so kid-done's own row must stay bare — otherwise
#    the same window is counted on two rows and the badges no longer describe the
#    indented block beneath them.
hasnt "an intermediate parent draws no badge of its own" "$rKid" "1/1 ✓"
hasnt "an intermediate parent draws no badge at all"     "$rKid" " ✓"

# 4. a childless row draws NOTHING — not `0/0`, not an empty `✓`. (A dash row has
#    no other `/` in it, so this also catches any stray badge.)
hasnt "a childless root draws no badge" "$rLone" "/"
hasnt "a childless root draws no lone ✓" "$rLone" "✓"

# 5. an orphan counts toward nobody and gets nothing itself.
hasnt "an orphan draws no badge" "$rOrph" "/"

# 6. the no-needs shape: `1/2 ✓` and no marker after it.
has   "a parent with no needs child shows a bare count" "$rCJK" "1/2 ✓"
hasnt "…and appends no needs marker"                    "$rCJK" "1/2 ✓ ·"
hasnt "…and paints nothing red"                         "$rCJK" $'\033['"$RD"

# 7. ALIGNMENT — the badge eats flex width, it must never push the right-pinned
#    act/PR/ctx block off the line. Every row (header included) is exactly
#    COLS-4 display columns, counting a CJK glyph as the 2 columns it occupies
#    (the #534 rule); ${#} would count it as 1 and pass a broken row.
dispw() { DISP="$1" perl -CO -MEncode -e '
  my $s = decode_utf8($ENV{DISP}); my $w = 0;
  for my $c (split //, $s) { my $o = ord $c;
    $w += ($o >= 0x1100 && ($o <= 0x115F ||
        ($o >= 0x2E80 && $o <= 0x303E) || ($o >= 0x3041 && $o <= 0x33FF) ||
        ($o >= 0x3400 && $o <= 0x4DBF) || ($o >= 0x4E00 && $o <= 0x9FFF) ||
        ($o >= 0xAC00 && $o <= 0xD7A3) || ($o >= 0xF900 && $o <= 0xFAFF) ||
        ($o >= 0xFF00 && $o <= 0xFF60) || ($o >= 0x1F000 && $o <= 0x1FAFF)))
      ? 2 : 1; }
  print $w;' 2>/dev/null; }
if perl -MEncode -e1 >/dev/null 2>&1; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    plain=${line#*$US}; plain=${plain#*$US}                    # drop key + window-id
    plain=$(printf '%s' "$plain" | perl -pe 's/\e\[[0-9;]*m//g')
    eq "every row is $((COLS-4)) display columns [${plain:0:24}…]" \
       "$((COLS-4))" "$(dispw "$plain")" "$plain"
  done <<< "$out"
else
  printf 'dash-rows-subtree-progress-selftest: no perl — skipping the width checks\n'
fi

printf 'dash-rows-subtree-progress-selftest: OK (%d checks)\n' "$CHECKS"
