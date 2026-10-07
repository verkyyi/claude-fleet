#!/bin/bash
# fleet-handoff-file-selftest.sh — bin/fleet-handoff-file.sh names and finds FILE
# handoffs by repo in a multi-repo fleet, and by fleet alone in a one-repo fleet
# (issue #992). Hermetic: a sandbox FLEET_CONF_DIR + handoff dir, no tmux, no gh.
#   ONE-REPO-NAME     a one-repo fleet's path carries its repo like any other
#                     (`<sess>-<owner-name>-<date>[-slug].md`, issue #1938); its old
#                     slug-less docs are still found (the fleet hosts one repo).
#   ONE-REPO-FIND     it resumes the newest `<sess>-*.md`, attribution never consulted.
#   MULTI-NAME        a 2-repo fleet puts the pane repo's slug in; a no-repo pane doesn't.
#   MULTI-INTERLEAVED newest files interleave A's and B's → each pane gets its own.
#   REPO-LINE         an old-style name is attributed by the doc's `Repo:` line.
#   FOLDED-LEGACY     a file under a folded fleet's old name is found by that repo's pane.
#   AMBIGUOUS-NEWER   an unattributable file newer than the pane's → exit 4, lists both.
#   AMBIGUOUS-NONE    only another repo's files → exit 4, never picks one.
#   CHECK-*           `check` (issue #1322): 201 lines → hint, exit 3; a doc that
#                     copies the issue body → hint; a normal doc → silent, exit 0.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-handoff-file.sh"
[ -x "$SRC" ] || { echo "selftest: $SRC not executable" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fhf-selftest.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
export FLEET_CONF_DIR="$WORK/conf" FLEET_HANDOFF_DIR="$WORK/handoff"
unset TMUX TMUX_PANE
mkdir -p "$FLEET_HANDOFF_DIR"

fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1" >&2; fails=$((fails+1)); }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1: want [$3] got [$2]"; }
# doc <name> <YYYYmmddHHMM> [body] — a handoff file with a fixed mtime.
doc()  { printf '# Handoff\n%s\n' "${3:-}" > "$FLEET_HANDOFF_DIR/$1"; touch -t "$2" "$FLEET_HANDOFF_DIR/$1"; }
run()  { "$SRC" "$@" 2>/dev/null; }
TODAY=$(date +%Y-%m-%d)

# ---- one-repo fleet ---------------------------------------------------------
mkdir -p "$FLEET_CONF_DIR/fleets/fleet-one"
echo 'FLEET_REPO=o/one' > "$FLEET_CONF_DIR/fleets/fleet-one/conf"
eq ONE-REPO-NAME "$(run path --session fleet-one --repo o/one)" "$FLEET_HANDOFF_DIR/fleet-one-o-one-$TODAY.md"
eq ONE-REPO-NAME-slug "$(run path --session fleet-one --repo o/one --slug x)" "$FLEET_HANDOFF_DIR/fleet-one-o-one-$TODAY-x.md"
doc fleet-one-2026-09-01.md 202609010000
doc fleet-one-2026-09-02-b.md 202609020000 'Repo: o/elsewhere'
# The same attribution as a 2-repo fleet: the newer doc says another repo, so the
# slug-less older one (this fleet's only repo) is the pane's.
eq ONE-REPO-FIND "$(run find --session fleet-one --repo o/one)" "$FLEET_HANDOFF_DIR/fleet-one-2026-09-01.md"

# ---- two-repo fleet (with one folded fleet) ---------------------------------
S=fleet-multi
mkdir -p "$FLEET_CONF_DIR/fleets/$S/repos"
echo 'FLEET_REPO=o/a' > "$FLEET_CONF_DIR/fleets/$S/conf"
echo 'FLEET_REPO=o/b' > "$FLEET_CONF_DIR/fleets/$S/repos/o-b.conf"
eq MULTI-NAME "$(run path --session $S --repo o/b)" "$FLEET_HANDOFF_DIR/$S-o-b-$TODAY.md"
eq MULTI-NAME-norepo "$(run path --session $S --norepo)" "$FLEET_HANDOFF_DIR/$S-$TODAY.md"
eq MULTI-REPO-LINE "$(run repo --session $S --norepo)" none

doc "$S-o-a-2026-09-10.md" 202609100000
doc "$S-o-b-2026-09-11.md" 202609110000
doc "$S-o-a-2026-09-12-x.md" 202609120000
doc "$S-o-b-2026-09-13.md" 202609130000
eq MULTI-INTERLEAVED-a "$(run find --session $S --repo o/a)" "$FLEET_HANDOFF_DIR/$S-o-a-2026-09-12-x.md"
eq MULTI-INTERLEAVED-b "$(run find --session $S --repo o/b)" "$FLEET_HANDOFF_DIR/$S-o-b-2026-09-13.md"

doc "$S-2026-09-14.md" 202609140000 'Repo: `o/a`'
eq REPO-LINE "$(run find --session $S --repo o/a)" "$FLEET_HANDOFF_DIR/$S-2026-09-14.md"
eq REPO-LINE-other "$(run find --session $S --repo o/b)" "$FLEET_HANDOFF_DIR/$S-o-b-2026-09-13.md"

# A fleet that hosted o/c, folded into this one; a lookalike `-multi-x` archive is not ours.
mkdir -p "$FLEET_CONF_DIR/archive/fleet-old-folded-into-multi-20260922" \
         "$FLEET_CONF_DIR/archive/fleet-alien-folded-into-multi-x-20260922"
echo 'FLEET_REPO=o/c' > "$FLEET_CONF_DIR/archive/fleet-old-folded-into-multi-20260922/conf"
echo 'FLEET_REPO=o/c' > "$FLEET_CONF_DIR/archive/fleet-alien-folded-into-multi-x-20260922/conf"
echo 'FLEET_REPO=o/c' > "$FLEET_CONF_DIR/fleets/$S/repos/o-c.conf"
doc fleet-old-2026-09-05.md 202609050000
doc fleet-alien-2026-09-20.md 202609200000
eq FOLDED-LEGACY "$(run find --session $S --repo o/c)" "$FLEET_HANDOFF_DIR/fleet-old-2026-09-05.md"

# An old-style name with no Repo: line and no repo named in it: unknown.
doc "$S-2026-09-15.md" 202609150000 'nothing to go on'
out=$(run find --session $S --repo o/a); rc=$?
eq AMBIGUOUS-NEWER-rc "$rc" 4
eq AMBIGUOUS-NEWER-list "$(printf '%s\n' "$out" | cut -f1,2 | tr '\t\n' '| ')" \
  "$FLEET_HANDOFF_DIR/$S-2026-09-15.md|? $FLEET_HANDOFF_DIR/$S-2026-09-14.md|o/a "
# …but content naming exactly one repo attributes it.
doc "$S-2026-09-15.md" 202609150000 'worked in o/b today'
eq CONTENT "$(run find --session $S --repo o/b)" "$FLEET_HANDOFF_DIR/$S-2026-09-15.md"
eq CONTENT-other "$(run find --session $S --repo o/a)" "$FLEET_HANDOFF_DIR/$S-2026-09-14.md"

# The hub (no repo) has nothing of its own → lists, never picks.
out=$(run find --session $S --norepo); rc=$?
eq AMBIGUOUS-NONE-rc "$rc" 4
eq AMBIGUOUS-NONE-top "$(printf '%s\n' "$out" | head -n1 | cut -f1,2)" "$FLEET_HANDOFF_DIR/$S-2026-09-15.md	o/b"
doc "$S-2026-09-16.md" 202609160000 'Repo: none'
eq HUB-OWN "$(run find --session $S --norepo)" "$FLEET_HANDOFF_DIR/$S-2026-09-16.md"

# No file at all → 1.
S2=fleet-empty; mkdir -p "$FLEET_CONF_DIR/fleets/$S2"; echo 'FLEET_REPO=o/e' > "$FLEET_CONF_DIR/fleets/$S2/conf"
run find --session $S2 --repo o/e >/dev/null; eq NONE-rc "$?" 1

# ---- check (issue #1322) ----------------------------------------------------
C="$WORK/check"; mkdir -p "$C"
{ echo '# Handoff'; echo 'NEXT ACTION: run the selftest and push the branch.'; } > "$C/ok.md"
awk 'BEGIN { for (i = 1; i <= 201; i++) print "line " i }' > "$C/long.md"
awk 'BEGIN { for (i = 1; i <= 200; i++) print "line " i }' > "$C/edge.md"
cat > "$C/body.md" <<'BODY'
## 目标
交接文档超过 200 行，或大段照抄 issue 时，交接当场提醒精简。
## 解决什么
交接文档越写越长，新会话读它就要花掉一大块上下文，接力效果打折。
- `fleet-handoff-file.sh` 写入前检查行数与「与 issue 正文重复的段落」
- 新键 `FLEET_HANDOFF_MAX_LINES`（默认 200）。
- selftest：201 行文档 → 提示；照抄 issue 正文 → 提示；正常文档无提示。
BODY
{ echo '# Handoff'; echo 'Goal (pasted):'; sed 's/^/> /' "$C/body.md"; echo 'NEXT ACTION: push.'; } > "$C/copy.md"
# Two lines quoted from the issue is a pointer, not a copy.
{ echo '# Handoff'; sed -n '2p;4p' "$C/body.md"; echo 'NEXT ACTION: push.'; } > "$C/quote.md"
ck() { "$SRC" check "$@" 2>/dev/null; }
out=$(ck "$C/long.md" --issue-body "$C/body.md"); rc=$?
eq CHECK-LONG-rc "$rc" 3
case "$out" in *'HANDOFF-CHECK:'*'201 lines'*'FLEET_HANDOFF_MAX_LINES=200'*) ok CHECK-LONG-hint ;; *) bad "CHECK-LONG-hint: [$out]" ;; esac
eq CHECK-EDGE "$(ck "$C/edge.md"; echo "rc=$?")" "rc=0"
eq CHECK-KNOB "$(FLEET_HANDOFF_MAX_LINES=300 ck "$C/long.md"; echo "rc=$?")" "rc=0"
out=$(ck "$C/copy.md" --issue-body "$C/body.md" --issue 7); rc=$?
eq CHECK-COPY-rc "$rc" 3
case "$out" in *'HANDOFF-CHECK:'*'copies 5 lines of issue #7'*) ok CHECK-COPY-hint ;; *) bad "CHECK-COPY-hint: [$out]" ;; esac
eq CHECK-COPY-stdin "$(ck - --issue-body "$C/body.md" < "$C/copy.md" | cut -c1-34)" "HANDOFF-CHECK: the handoff copies "
eq CHECK-QUOTE "$(ck "$C/quote.md" --issue-body "$C/body.md"; echo "rc=$?")" "rc=0"
eq CHECK-OK "$(ck "$C/ok.md" --issue-body "$C/body.md"; echo "rc=$?")" "rc=0"
eq CHECK-NO-ISSUE "$(ck "$C/copy.md"; echo "rc=$?")" "rc=0"
eq CHECK-USAGE "$(ck; echo "rc=$?")" "rc=2"

[ "$fails" = 0 ] && { echo "fleet-handoff-file-selftest: PASS"; exit 0; }
echo "fleet-handoff-file-selftest: $fails failure(s)" >&2; exit 1
