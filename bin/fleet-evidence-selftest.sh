#!/bin/bash
# fleet-evidence-selftest.sh — hermetic tests for bin/fleet-evidence.sh, the
# worker-captured before/after evidence store the EPIC report collects from
# (issue #810).
#
# No network, no tmux server, no real repo: `gh`, `tmux` and fleet-comment.sh are
# faked, FLEET_CONF_DIR is a sandbox, and the script runs from a temp bin/ beside
# a copy of the real fleet-lib.sh (no ../fleet.conf). What is pinned:
#   A. WHERE it lands — epic/<E>/evidence/<M> when GitHub names a parent, the
#      non-EPIC evidence/<M> when it 404s; a populated dir wins WITHOUT a gh call
#   B. the file naming (`<stage>-<UTC>-<name>`), the manifest row, --mv vs copy,
#      stdin (`-`) + --name, --pane, a note flattened to one line
#   C. `post` = ONE record-only comment through fleet-comment.sh (--note), listing
#      every row + the machine marker; nothing captured → refuses (exit 2)
#   D. `list --epic E` = every GitHub sub-issue ∪ every dir on disk; a member with
#      nothing reads `none` (the #7579 acceptance: no crash, no invention), and a
#      member captured before its parent link existed is still found
#   E. `export` copies beside a report page and prints RELATIVE paths
#   F. `line` extracts the 上线证据 line — the labelled form, and the `## 上线证据`
#      heading with the line under it (#841); neither → exit 1, silent. Plus one
#      END-TO-END round trip of /fleet-epic-plan's own template through the reader
#   G. issue resolution: --issue › @issue › issue-<N> worktree in cwd; usage codes
#   H. a 2+ repo fleet: the EPIC's repo, by-repo/<slug>/ stores, ask under `all`
# The whole file re-runs itself once under /bin/bash when that is a 3.x bash (the
# operator's macOS), because #703's class of bug is only observable there.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-evidence.sh"; LIB="$BIN/fleet-lib.sh"
[ -f "$SRC" ] || { echo "selftest: $SRC missing" >&2; exit 2; }
[ -f "$LIB" ] || { echo "selftest: $LIB missing" >&2; exit 2; }
SH="${FEV_BASH:-bash}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fev-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0
ok()   { pass=$((pass+1)); }
fail() { printf 'FAIL [%s] %s\n' "$SH" "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n--- stderr ---\n%s\n' "$2" "${3:-}" >&2; exit 1; }
eq()   { [ "$2" = "$3" ] && ok || fail "$1 — expected [$2], got [$3]" "${OUT:-}" "${ERR:-}"; }
has()  { case "$2" in *"$3"*) ok ;; *) fail "$1 — missing [$3]" "$2" "${ERR:-}" ;; esac; }
hasnt(){ case "$2" in *"$3"*) fail "$1 — unexpected [$3]" "$2" "${ERR:-}" ;; *) ok ;; esac; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf/fleets/fevsess" "$WORK/src"
cp "$SRC" "$WORK/bin/fleet-evidence.sh"; cp "$LIB" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-evidence.sh"
printf 'FLEET_REPO=o/r\n' > "$WORK/conf/fleets/fevsess/conf"
CONF="$WORK/conf/fleets/fevsess"

# --- fake gh: parent link (GH_PARENT, else 404) · sub-issues (GH_SUBS) · body (GH_BODY)
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"/parent"*)     [ -n "${GH_PARENT:-}" ] && { printf '%s\n' "$GH_PARENT"; exit 0; }
                   echo 'gh: No parent issue found (HTTP 404)' >&2; exit 1 ;;
  *"/sub_issues"*) printf '%b' "${GH_SUBS:-}"; exit 0 ;;
  "issue view"*)   printf '%b' "${GH_BODY:-}"; exit 0 ;;
esac
exit 0
GHFAKE
# --- fake tmux: session name, @issue (TMUX_AT_ISSUE), a two-line pane
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
case "$*" in
  *session_name*) echo fevsess ;;
  *'@issue'*)     printf '%s\n' "${TMUX_AT_ISSUE:-}" ;;
  capture-pane*)  printf 'PANE LINE 1\nPANE LINE 2\n' ;;
esac
exit 0
TMUXFAKE
# --- fake fleet-comment.sh: record argv + the stdin body, print a URL
cat > "$WORK/bin/fleet-comment.sh" <<'CMTFAKE'
#!/bin/bash
printf '%s\n' "$*" > "$CMT_ARGS"
cat > "$CMT_BODY"
echo 'https://github.com/o/r/issues/42#issuecomment-1'
CMTFAKE
chmod +x "$WORK/fakebin/gh" "$WORK/fakebin/tmux" "$WORK/bin/fleet-comment.sh"

GH_LOG="$WORK/gh.log"; CMT_ARGS="$WORK/cmt.args"; CMT_BODY="$WORK/cmt.body"
# run [env…] -- args…  (env knobs as VAR=val before --)
run() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  ( cd "$WORK" && env PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/conf" TMUX_PANE=%9 \
      GH_LOG="$GH_LOG" CMT_ARGS="$CMT_ARGS" CMT_BODY="$CMT_BODY" TMUX_AT_ISSUE='' GH_PARENT='' GH_SUBS='' GH_BODY='' \
      ${envs[@]+"${envs[@]}"} "$SH" "$WORK/bin/fleet-evidence.sh" "$@" >"$WORK/out" 2>"$WORK/err" )
  RC=$?; OUT=$(cat "$WORK/out"); ERR=$(cat "$WORK/err")
}

# ---------- A. where it lands -------------------------------------------------
: > "$GH_LOG"
run GH_PARENT=7 -- dir --session fevsess --issue 42
eq "A1 dir: parent 7 → epic path" 0 "$RC"
eq "A1 dir path" "$CONF/epic/7/evidence/42" "$OUT"
has "A1 gh asked for the parent" "$(cat "$GH_LOG")" "issues/42/parent"
run -- dir --session fevsess --issue 43
eq "A2 dir: 404 → non-EPIC path" "$CONF/evidence/43" "$OUT"
run -- dir --session fevsess --issue 43 --epic none
eq "A3 --epic none forces the non-EPIC path" "$CONF/evidence/43" "$OUT"
[ ! -e "$CONF/epic" ] && [ ! -e "$CONF/evidence" ] && ok || fail "A4 `dir` must not create directories"

# ---------- B. capture: naming, manifest, copy/mv, stdin, pane, note ----------
printf 'PNGDATA' > "$WORK/src/shot.png"
run GH_PARENT=7 -- before --session fevsess --issue 42 --note 'homepage before' "$WORK/src/shot.png"
eq "B1 before exits 0" 0 "$RC"
f1="${OUT##*/}"
case "$f1" in before-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-shot.png) ok ;; *) fail "B1 name shape: $f1" ;; esac
[ -f "$CONF/epic/7/evidence/42/$f1" ] && ok || fail "B1 file stored"
[ -f "$WORK/src/shot.png" ] && ok || fail "B1 default is COPY — source must survive"
row=$(cat "$CONF/epic/7/evidence/42/manifest.tsv")
ts1="${f1#before-}"; ts1="${ts1%-shot.png}"
eq "B1 manifest row" "$(printf 'before\t%s\t%s\thomepage before' "$ts1" "$f1")" "$row"

# a populated dir answers `dir` (and a second capture) with NO gh round-trip
: > "$GH_LOG"
run -- dir --session fevsess --issue 42
eq "A5 populated dir wins, offline" "$CONF/epic/7/evidence/42" "$OUT"
eq "A5 no gh call" "" "$(cat "$GH_LOG")"

printf 'PNG2' > "$WORK/src/shot.png"
run -- after --session fevsess --issue 42 --mv --note 'homepage after' "$WORK/src/shot.png"
eq "B2 after --mv exits 0" 0 "$RC"
[ ! -e "$WORK/src/shot.png" ] && ok || fail "B2 --mv removes the source"
f2="${OUT##*/}"; case "$f2" in after-*-shot.png) ok ;; *) fail "B2 name: $f2" ;; esac

run -- after --session fevsess --issue 42 --name curl-health.txt --note "$(printf 'tab\tin\nnote')" - <<<'{"ok":true}'
eq "B3 stdin capture exits 0" 0 "$RC"
f3="${OUT##*/}"; case "$f3" in after-*-curl-health.txt) ok ;; *) fail "B3 stdin name: $f3" ;; esac
eq "B3 stdin content" '{"ok":true}' "$(cat "$CONF/epic/7/evidence/42/$f3")"
has "B3 note flattened to one line" "$(tail -1 "$CONF/epic/7/evidence/42/manifest.tsv")" "$(printf '%s\ttab in note' "$f3")"

run -- after --session fevsess --issue 42 --pane '%3' --note 'dash after'
eq "B4 --pane exits 0" 0 "$RC"
f4="${OUT##*/}"; case "$f4" in after-*-pane-_3.txt) ok ;; *) fail "B4 pane name: $f4" ;; esac
eq "B4 pane content" "$(printf 'PANE LINE 1\nPANE LINE 2')" "$(cat "$CONF/epic/7/evidence/42/$f4")"

eq "B5 four manifest rows" 4 "$(wc -l < "$CONF/epic/7/evidence/42/manifest.tsv" | tr -d ' ')"
run -- before --session fevsess --issue 42 "$WORK/src/does-not-exist.png"
eq "B6 a missing source → exit 1" 1 "$RC"
has "B6 says so" "$ERR" "not a file"

# ---------- C. post ------------------------------------------------------------
run -- post --session fevsess --issue 42
eq "C1 post exits 0" 0 "$RC"
eq "C1 fleet-comment argv: record-only, this issue, this repo" "42 --repo o/r --note --body-file -" "$(cat "$CMT_ARGS")"
body=$(cat "$CMT_BODY")
has "C1 header names issue + epic" "$body" "📎 上线证据 · #42 (EPIC #7)"
has "C1 dir line" "$body" "dir: \`$CONF/epic/7/evidence/42\`"
has "C1 before row" "$body" "- **before** · $ts1 · \`$f1\` — homepage before"
has "C1 after rows" "$body" "\`$f2\` — homepage after"
has "C1 pane row" "$body" "\`$f4\` — dash after"
has "C1 machine marker" "$body" "<!-- fleet:evidence issue=42 epic=7 dir=$CONF/epic/7/evidence/42 -->"
has "C1 prints the URL" "$OUT" "issuecomment-1"
run -- post --session fevsess --issue 43
eq "C2 nothing captured → refuse" 2 "$RC"
has "C2 reason" "$ERR" "nothing to post"
# --post on a capture posts in the same call
: > "$CMT_ARGS"
printf 'x' > "$WORK/src/x.png"
run GH_PARENT=7 -- after --session fevsess --issue 45 --post --note 'member 45' "$WORK/src/x.png"
eq "C3 --post exits 0" 0 "$RC"
eq "C3 --post reached fleet-comment" "45 --repo o/r --note --body-file -" "$(cat "$CMT_ARGS")"

# ---------- D. list --epic ------------------------------------------------------
# 44 captured with NO parent link (its worker ran before the link existed)
printf 'y' > "$WORK/src/y.txt"
run -- after --session fevsess --issue 44 --epic none --note 'linked later' "$WORK/src/y.txt"
eq "D0 44 in the non-EPIC dir" 0 "$RC"
f44="${OUT##*/}"
# GitHub says the epic has 42 43 44; 45 exists only on disk
run GH_SUBS='42\n43\n44\n' -- list --session fevsess --epic 7
eq "D1 list exits 0" 0 "$RC"
has "D1 header names the epic dir" "$OUT" "(epic 7 · $CONF/epic/7/evidence)"
has "D1 42 before row (absolute path)" "$OUT" "$(printf '42\tbefore\t%s\t%s\thomepage before' "$ts1" "$CONF/epic/7/evidence/42/$f1")"
has "D1 43 → none, not missing, not invented" "$OUT" "$(printf '43\tnone\t\t\t')"
has "D1 44 found in the non-EPIC dir" "$OUT" "$(printf '44\tafter\t')"
has "D1 44 path" "$OUT" "$CONF/evidence/44/$f44"
has "D1 45 on disk but not in GitHub's list still shows" "$OUT" "$(printf '45\tafter\t')"
eq "D1 members in numeric order" "42 43 44 45" "$(printf '%s\n' "$OUT" | grep -v '^#' | cut -f1 | uniq | tr '\n' ' ' | sed 's/ $//')"
# gh unavailable → disk-only list, still exit 0 (the report never needs gh to show what exists)
run -- list --session fevsess --epic 7 --repo ''
eq "D2 no repo → disk-only" 0 "$RC"
has "D2 42 still listed" "$OUT" "$(printf '42\tbefore\t')"
hasnt "D2 43 (GitHub-only) absent without gh" "$OUT" "$(printf '43\t')"
run GH_SUBS='' -- list --session fevsess --epic 99
eq "D3 an epic with nothing anywhere → exit 0" 0 "$RC"
has "D3 says so" "$OUT" "# epic 99: no members and no evidence on disk"
# per-member list
run -- list --session fevsess --issue 42
has "D4 --issue list header" "$OUT" "(issue 42 · epic 7)"
eq "D4 four rows" 4 "$(printf '%s\n' "$OUT" | grep -c "^42	")"

# ---------- E. export -----------------------------------------------------------
run GH_SUBS='42\n43\n44\n' -- export --session fevsess --epic 7 "$WORK/report"
eq "E1 export exits 0" 0 "$RC"
[ -f "$WORK/report/evidence/42/$f1" ] && ok || fail "E1 42's before copied beside the page"
[ -f "$WORK/report/evidence/44/$f44" ] && ok || fail "E1 44 (non-EPIC dir) copied too"
eq "E1 copied bytes intact" 'PNGDATA' "$(cat "$WORK/report/evidence/42/$f1")"
has "E1 rows carry RELATIVE paths" "$OUT" "$(printf '42\tbefore\t%s\tevidence/42/%s\thomepage before' "$ts1" "$f1")"
has "E1 none rows kept" "$OUT" "$(printf '43\tnone')"
run -- export --session fevsess "$WORK/report"
eq "E2 export needs --epic" 2 "$RC"
run -- export --session fevsess --epic 7
eq "E3 export needs a dest" 2 "$RC"

# ---------- F. line -------------------------------------------------------------
run GH_BODY='## 要什么\n- **上线证据**：截图 https://x/y 首页，改动前后各一张\n- 完成判据: x\n' -- line --session fevsess --issue 42
eq "F1 line exits 0" 0 "$RC"
eq "F1 bold CJK label, full-width colon" "截图 https://x/y 首页，改动前后各一张" "$OUT"
run GH_BODY='Goal\n\nEvidence: curl -s https://api/health | jq .\n' -- line --session fevsess --issue 42
eq "F2 english label" "curl -s https://api/health | jq ." "$OUT"
run GH_BODY='3. 上线证据: capture-pane the dash\n' -- line --session fevsess --issue 42
eq "F3 numbered list" "capture-pane the dash" "$OUT"
run GH_BODY='## body\nno such line here\n' -- line --session fevsess --issue 42
eq "F4 absent → exit 1" 1 "$RC"
eq "F4 absent → silent" "" "$OUT"
# the HEADING form (issue #841): what /fleet-epic-plan wrote before #840 unified
# the write side — `## 上线证据` with the line under it, blank line and all
run GH_BODY='## 完成判据\nx\n\n## 上线证据\n\n把「现在」拨到 08:48Z 跑一次，贴出那条告警原文\n\n---\nPart of EPIC #7.\n' -- line --session fevsess --issue 42
eq "F5 heading form exits 0" 0 "$RC"
eq "F5 heading form: the line under it" "把「现在」拨到 08:48Z 跑一次，贴出那条告警原文" "$OUT"
run GH_BODY='## Evidence\n- curl -s https://api/health | jq .\n' -- line --session fevsess --issue 42
eq "F6 heading + bullet, no blank line" "curl -s https://api/health | jq ." "$OUT"
run GH_BODY='## 上线证据\n\n## 下一节\n这不是证据\n' -- line --session fevsess --issue 42
eq "F7 empty section → exit 1" 1 "$RC"
eq "F7 empty section → not the next section, not an empty string" "" "$OUT"
run GH_BODY='## 完成判据\nx\n\n## 上线证据\n\n\n' -- line --session fevsess --issue 42
eq "F8 heading at the end of the body → exit 1" 1 "$RC"
eq "F8 → silent" "" "$OUT"
# the labelled line still WINS, wherever it sits relative to a heading
run GH_BODY='## 上线证据\n标题下的那行\n\n**上线证据**：带冒号的那行\n' -- line --session fevsess --issue 42
eq "F9 labelled form wins even when a heading comes first" "带冒号的那行" "$OUT"
run GH_BODY='## 上线证据:\n标题带个空冒号\n' -- line --session fevsess --issue 42
eq "F10 a label with nothing after the colon falls through, never an empty line" "标题带个空冒号" "$OUT"

# END-TO-END: the shape /fleet-epic-plan WRITES must be a shape `line` READS.
# The two sides were fixed in separate passes (#840 write, #841 read) and the gap
# between them is exactly what filed 8 unreadable members on another fleet, so the
# assertion is one round trip through the command doc's own template, not two
# separate opinions about the format.
PLAN="$BIN/../commands/fleet-epic-plan.md"
if [ -f "$PLAN" ]; then
  # the template line in whatever shape it is written — plus the line under it, so
  # a heading-shaped template is round-tripped through the heading branch
  tmpl=$(awk '/^[[:space:]]*(#+[[:space:]]*)?[*_`]*(上线证据|[Ee]vidence)[*_`]*[[:space:]]*([:：]|$)/ { print; if ((getline nxt) > 0) print nxt; exit }' "$PLAN" \
           | sed 's/<[^>]*>/一句话证据/')
  [ -n "$tmpl" ] && ok || fail "F11 no 上线证据 template found in commands/fleet-epic-plan.md"
  run GH_BODY="$tmpl" -- line --session fevsess --issue 42
  eq "F11 the plan's own template round-trips through line" 0 "$RC"
  eq "F11 it yields the evidence line, not the label" "一句话证据" "$OUT"
else
  printf 'fleet-evidence-selftest: F11 skipped — no commands/ beside %s\n' "$BIN"
fi

# ---------- G. issue resolution + usage codes ------------------------------------
run TMUX_AT_ISSUE=42 -- dir --session fevsess
eq "G1 @issue resolves the member" "$CONF/epic/7/evidence/42" "$OUT"
mkdir -p "$WORK/repo-issue-51"
( cd "$WORK/repo-issue-51" && env PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/conf" TMUX_AT_ISSUE='' GH_PARENT='' GH_LOG="$GH_LOG" \
    "$SH" "$WORK/bin/fleet-evidence.sh" dir --session fevsess >"$WORK/out" 2>"$WORK/err" ); RC=$?; OUT=$(cat "$WORK/out")
eq "G2 issue-<N> worktree in cwd is the fallback" "$CONF/evidence/51" "$OUT"
run -- dir --session fevsess
eq "G3 no issue anywhere → exit 4" 4 "$RC"
has "G3 says never guess" "$ERR" "no issue bound"
run -- frobnicate --session fevsess
eq "G4 unknown command → exit 2" 2 "$RC"
run -- before --session fevsess --issue 42
eq "G5 capture with nothing to store → exit 2" 2 "$RC"
run -- dir --session fevsess --issue 42 --bogus
eq "G6 unknown flag → exit 2" 2 "$RC"
run -- --help
eq "G7 --help exits 0" 0 "$RC"
has "G7 help text" "$OUT" "fleet-evidence.sh before|after|live"

# ---------- H. a fleet hosting 2+ repos (issue #803) ---------------------------
# The repo is the EPIC's — B's sub-issues, B's parent link — and B's store is its
# own (by-repo/<slug>/): issue numbers repeat across repos, so B's #42 must never
# answer A's lookup. The conf's own repo keeps the paths it always had.
mkdir -p "$WORK/conf/fleets/fevmulti/repos"
printf 'FLEET_REPO=o/r\n' > "$WORK/conf/fleets/fevmulti/conf"
MC="$WORK/conf/fleets/fevmulti"
bslug=$(FLEET_CONF_DIR="$WORK/conf"; . "$WORK/bin/fleet-lib.sh"; fleet_slug o/b)
printf 'FLEET_REPO=o/b\n' > "$MC/repos/$bslug.conf"
run TMUX= GH_PARENT=7 -- dir --session fevmulti --repo o/b --issue 42
eq "H1 repo B → its own by-repo store" "$MC/by-repo/$bslug/epic/7/evidence/42" "$OUT"
run TMUX= GH_PARENT=7 -- dir --session fevmulti --repo o/r --issue 42
eq "H2 the conf's own repo keeps its historic path" "$MC/epic/7/evidence/42" "$OUT"
run TMUX= -- dir --session fevmulti --issue 42
eq "H3 no --repo under \`all\` → exit 2" 2 "$RC"
has "H3 names the choices" "$ERR" "o/b"
run TMUX= -- dir --session fevmulti --repo o/zzz --issue 42
eq "H4 a repo the fleet does not host → exit 2" 2 "$RC"
printf 'o/b\n' > "$MC/current-repo"
: > "$GH_LOG"
run TMUX= GH_SUBS='42\n' -- list --session fevmulti --epic 7
eq "H5 list follows the current repo" 0 "$RC"
has "H5 sub-issues read from repo B" "$(cat "$GH_LOG")" "repos/o/b/issues/7/sub_issues"
printf 'BSHOT' > "$WORK/src/b.png"
run TMUX= GH_PARENT=7 -- before --session fevmulti --issue 42 --note 'b shot' "$WORK/src/b.png"
eq "H6 capture into B" 0 "$RC"
has "H6 stored under B's store" "$OUT" "$MC/by-repo/$bslug/epic/7/evidence/42/"
run TMUX= -- dir --session fevmulti --repo o/r --issue 42
eq "H6 A's #42 never picks up B's populated dir" "$MC/evidence/42" "$OUT"
rm -f "$MC/current-repo"

printf 'fleet-evidence-selftest OK (%d checks, %s)\n' "$pass" "$SH"

# ---- the bash 3.2 half (#703): re-run once under /bin/bash when it is a 3.x -----
if [ -z "${FEV_BASH:-}" ] && [ -x /bin/bash ]; then
  case "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" in
    3) FEV_BASH=/bin/bash exec /bin/bash "$0" ;;
  esac
fi
exit 0
