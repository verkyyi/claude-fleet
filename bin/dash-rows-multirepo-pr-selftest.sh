#!/bin/bash
# dash-rows-multirepo-pr-selftest.sh — right PR status on every session (issue #792).
#
# Identity is (repo, branch), never the branch alone: two repos a fleet hosts can
# each have an `issue-3`, and one per-fleet prmap painted repo A's green check on
# repo B's unfinished work. Pinned here, for BOTH writers of a PR cell:
#   A. dash rows (tmux-dashboard-rows.sh) — two issue-3 windows in different repos
#      each show their OWN PR; deploy_<sha> is read from the window repo's dir;
#      `@norepo 1` and an unstamped window in a 2-repo fleet show no PR (never a
#      guess); an unstamped window in a fleet whose only repo has an overlay falls
#      back to that repo.
#   B. DEGENERATE — no repos/ overlay: @repo is ignored and every row reads the
#      fleet's one prmap, exactly as before.
#   C. SCALE — #662's bound holds in multi-repo mode: a 2000-line prmap in each repo
#      costs about what a 1-line one does.
#   D. pr-refresh (tmux-pr-refresh.sh) — @prci per window from its own repo's prmap,
#      an unstamped window gets @repo derived from @worktree + stamped; degenerate
#      fleet unchanged. Real tmux on a PRIVATE socket (PATH shim), gh shimmed to fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
REFRESH="$BIN/tmux-pr-refresh.sh"

CHECKS=0 FAILS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; FAILS=$((FAILS+1)); }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/multirepo-pr-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
SOCK="$WORK/tmux.sock"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export TMPDIR="$WORK/tmp" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf"
unset FLEET_REPO FLEET_MAIN TMUX TMUX_PANE 2>/dev/null || true
SESS=s1
C="$TMPDIR/.claude-dash"
FA="$C/fleets/acme-alpha" FB="$C/fleets/acme-beta"
mkdir -p "$C/global" "$FA" "$FB" "$FLEET_CONF_DIR/fleets/$SESS" "$WORK/bin" "$WORK/rbin"
printf 'FLEET_REPO=acme/alpha\n' > "$FLEET_CONF_DIR/fleets/$SESS/conf"
printf '%s\tacme-alpha\tacme/alpha\n' "$SESS" > "$C/global/sessmap"
OVL="$FLEET_CONF_DIR/fleets/$SESS/repos"
overlay_on()  { mkdir -p "$OVL"; printf 'FLEET_REPO=acme/beta\n' > "$OVL/acme-beta.conf"; }
overlay_off() { rm -rf "$OVL"; }

# same PR name, different PR, different state — plus a MERGED issue-7 in each repo
# whose deploy verdicts disagree, so the deploy dir is pinned too.
{ printf 'issue-3\t#11\tOPEN\t✓\tready\t\n'; printf 'issue-7\t#17\tMERGED\t✓\t\tshaA\n'; } > "$FA/prmap"
{ printf 'issue-3\t#22\tOPEN\t✗\tready\t\n'; printf 'issue-7\t#27\tMERGED\t✓\t\tshaB\n'; } > "$FB/prmap"
: > "$FA/prmap.ts"; : > "$FB/prmap.ts"
printf 'failed\t0\n' > "$FA/deploy_shaB"      # a WRONG-repo verdict: must never be read
printf 'live\t0\n'   > "$FB/deploy_shaB"

gk() { local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"; }
gitc() { printf '%s\tclean\n' "$2" > "$C/global/git_$(gk "$1")"; }

# ============================================================================
# A–C: the dash rows producer, fed by a list-windows STUB
# ============================================================================
US=$(printf '\037')
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037'); lw=0; fmt=0
for a in "$@"; do
  [ "$a" = list-windows ] && lw=1
  case "$a" in *"$US"*) fmt=1 ;; esac
done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
WLIST_FILE="$WORK/wlist"; export WLIST_FILE
# Field order MUST match WFMT in tmux-dashboard-rows.sh: 1 session · 2 idx · 3 name ·
# 4 path · 5 state · 6 state_ts · 7 window_id · 8 @issue · 9 @origin · 10 @worktree ·
# 11–19 agent…reap_stamp (empty here) · 20 @repo · 21 @norepo
w() {   # idx name path @issue @repo @norepo
  printf '%s\n' "$SESS$US$1$US$2$US$3${US}idle$US$US@$1$US$4$US$US$3$US$US$US$US$US$US$US$US$US$US$5$US$6" >> "$WLIST_FILE"
}
rows() { PATH="$WORK/bin:$PATH" FLEET_SESSION="$SESS" FZF_COLUMNS=140 bash "$ROWS" 2>&1; }
row_of() { printf '%s\n' "$1" | grep -F "$SESS:$2$US"; }
ms() { python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || printf '0'; }

gitc /w/alpha-issue-3 issue-3
gitc /w/beta-issue-3  issue-3
gitc /w/beta-issue-7  issue-7
gitc /w/free-issue-3  issue-3
gitc /w/unk-issue-3   issue-3

fixture() {   # $1 = 1 to stamp @repo/@norepo, 0 to leave them empty
  : > "$WLIST_FILE"
  if [ "$1" = 1 ]; then
    w 1 alpha3 /w/alpha-issue-3 3 acme/alpha ''
    w 2 beta3  /w/beta-issue-3  3 acme/beta  ''
    w 3 beta7  /w/beta-issue-7  7 acme/beta  ''
    w 4 free3  /w/free-issue-3  '' ''        1
  else
    w 1 alpha3 /w/alpha-issue-3 3 '' ''
    w 2 beta3  /w/beta-issue-3  3 '' ''
    w 3 beta7  /w/beta-issue-7  7 '' ''
    w 4 free3  /w/free-issue-3  '' '' ''
  fi
}

# --- A. two-repo fleet ---
overlay_on; fixture 1
w 5 unk3 /w/unk-issue-3 '' '' ''        # no @repo, no @norepo, 2 repos → unknown
out=$(rows) || fail "rows producer exited non-zero (multi)" "$out"
has   "A: repo A's issue-3 shows A's PR"                    "$(row_of "$out" 1)" "#11✓"
has   "A: repo B's issue-3 shows B's PR"                    "$(row_of "$out" 2)" "#22✗"
hasnt "A: … and NOT repo A's green check"                   "$(row_of "$out" 2)" "#11"
has   "A: deploy_<sha> read from the window repo's own dir" "$(row_of "$out" 3)" "live"
hasnt "A: … never the other repo's verdict"                 "$(row_of "$out" 3)" "deploy✗"
hasnt "A: @norepo window shows no PR"                       "$(row_of "$out" 4)" "#"
hasnt "A: unstamped window in a 2-repo fleet is not guessed" "$(row_of "$out" 5)" "#"
has   "A: … it shows the em-dash"                           "$(row_of "$out" 5)" "—"
multi_out=$out

# overlay only for the conf's own repo: still ONE hosted repo → unstamped falls back
rm -f "$OVL/acme-beta.conf"; printf 'FLEET_MODEL=x\n' > "$OVL/acme-alpha.conf"
out=$(rows)
has   "A: one-repo fleet with an own-repo overlay: unstamped window → its only repo" "$(row_of "$out" 5)" "#11✓"
rm -f "$OVL/acme-alpha.conf"

# --- B. degenerate: no repos/ overlay ---
overlay_off; fixture 1
out_st=$(rows)
has   "B: degenerate — repo A's row as before"     "$(row_of "$out_st" 1)" "#11✓"
has   "B: degenerate — @repo is ignored (one prmap per fleet, as before)" "$(row_of "$out_st" 2)" "#11✓"
fixture 0
out_un=$(rows)
CHECKS=$((CHECKS+1))
[ "$out_st" = "$out_un" ] || fail "B: degenerate output depends on @repo/@norepo" \
  "$(printf 'STAMPED:\n%s\n\nUNSTAMPED:\n%s\n' "$out_st" "$out_un")"

# --- C. scale (#662's bench, in multi-repo mode) ---
overlay_on; fixture 1
small=$(rows)
t0=$(ms); for i in 1 2 3; do rows >/dev/null 2>&1; done; t1=$(ms)
small_ms=$(( (t1 - t0) / 3 ))
for f in "$FA/prmap" "$FB/prmap"; do
  { cat "$f"; i=0
    while [ "$i" -lt 2000 ]; do printf 'noise-%s\t#%s\tMERGED\t✓\t\tsha%s\n' "$i" "$i" "$i"; i=$((i+1)); done
  } > "$f.big"; cp "$f" "$f.orig"; mv "$f.big" "$f"
done
t0=$(ms); big=$(rows); t1=$(ms); big_ms=$(( t1 - t0 ))
CHECKS=$((CHECKS+1))
[ "$big" = "$small" ] || fail "C: 2000-line prmaps changed the rendered rows" "$(printf 'SMALL:\n%s\n\nBIG:\n%s\n' "$small" "$big")"
if [ "$small_ms" -le 0 ] || [ "$small_ms" -gt 2000 ]; then
  printf 'dash-rows-multirepo-pr-selftest: timing unusable (small=%sms) — SCALE leg skipped\n' "$small_ms" >&2
else
  budget=$(( small_ms * 3 + 200 ))
  CHECKS=$((CHECKS+1))
  [ "$big_ms" -le "$budget" ] || fail "C: multi-repo PR lookup scales with prmap size — ${big_ms}ms vs ${small_ms}ms (budget ${budget}ms); build the (repo, branch) haystack ONCE per frame (#662)"
  printf 'dash-rows-multirepo-pr-selftest: multi-repo frame 1-line %sms · 2000-line %sms (budget %sms)\n' "$small_ms" "$big_ms" "$budget"
fi
for f in "$FA/prmap" "$FB/prmap"; do mv "$f.orig" "$f"; done

# ============================================================================
# D. pr-refresh — @prci per window, on a private tmux socket
# ============================================================================
if [ -z "$REAL_TMUX" ] || ! command -v git >/dev/null 2>&1; then
  printf 'dash-rows-multirepo-pr-selftest: tmux/git missing — pr-refresh leg SKIPPED\n' >&2
else
  cat > "$WORK/rbin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
  printf '#!/bin/sh\nexit 1\n' > "$WORK/rbin/gh"
  chmod +x "$WORK/rbin/tmux" "$WORK/rbin/gh"
  RT() { PATH="$WORK/rbin:$PATH" tmux "$@"; }
  mkdir -p "$WORK/wa" "$WORK/wb" "$WORK/wd"
  git init -q "$WORK/wd" && git -C "$WORK/wd" remote add origin https://github.com/acme/beta.git
  for d in wa wb wd; do gitc "$WORK/$d" issue-3; done
  RT -f /dev/null new-session -d -s "$SESS" -n plan -c "$WORK"
  RT new-window -d -t "$SESS:" -n alpha3 -c "$WORK/wa"
  RT new-window -d -t "$SESS:" -n beta3  -c "$WORK/wb"
  RT new-window -d -t "$SESS:" -n derive3 -c "$WORK/wd"
  RT set-option -w -t "$SESS:alpha3" @repo acme/alpha
  RT set-option -w -t "$SESS:beta3"  @repo acme/beta
  RT set-option -w -t "$SESS:derive3" @worktree "$WORK/wd"
  sleep 0.3   # let the panes' cwds settle
  refresh() { PATH="$WORK/rbin:$PATH" bash "$REFRESH" --repo acme/none >/dev/null 2>&1; }
  prci() { RT display-message -p -t "$SESS:$1" '#{@prci}'; }

  overlay_on; refresh
  eq "D: pr-refresh — repo A window gets A's CI"              "$(prci alpha3)"  "✓"
  eq "D: pr-refresh — repo B window gets B's CI, not A's"     "$(prci beta3)"   "✗"
  eq "D: pr-refresh — unstamped window: @repo derived from @worktree + stamped" \
     "$(RT display-message -p -t "$SESS:derive3" '#{@repo}')" "acme/beta"
  eq "D: … and it gets its derived repo's CI"                 "$(prci derive3)" "✗"

  overlay_off; RT set-option -w -t "$SESS:derive3" -u @repo; refresh
  eq "D: degenerate — every window reads the fleet's one prmap (as before)" "$(prci beta3)" "✓"
  eq "D: degenerate — no @repo derivation"  "$(RT display-message -p -t "$SESS:derive3" '#{@repo}')" ""
fi

[ "$FAILS" -eq 0 ] || { printf 'dash-rows-multirepo-pr-selftest: %s of %s checks FAILED\n' "$FAILS" "$CHECKS" >&2; exit 1; }
printf 'dash-rows-multirepo-pr-selftest: OK (%s checks)\n' "$CHECKS"
