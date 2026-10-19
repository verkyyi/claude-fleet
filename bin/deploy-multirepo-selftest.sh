#!/bin/bash
# deploy-multirepo-selftest.sh — each repo keeps its OWN "is it live" signal
# (issue #805). One fleet hosts two repos (issue #788): the conf's own repo deploys
# by FLEET_DEPLOY_REF (a checkout that IS the deployment — claude-fleet's live
# install), the overlay repo by FLEET_DEPLOY_CHECK=actions (the monorepo's post-merge
# workflow runs). The knobs are repo-scoped (_FLEET_REPO_SCOPED), so:
#
#   • PRODUCER  bin/tmux-pr-refresh.sh resolves the knobs per repo through
#               fleet_load_repo_conf: the ref repo is probed by git (no gh api),
#               the actions repo by gh — and a sha that would be `live` under the
#               OTHER repo's mode is not, in either direction.
#   • NO LEAK   an overlay with no deploy keys writes nothing: the conf repo's
#               FLEET_DEPLOY_REF must not reach it.
#   • DEGENERATE no repos/ overlay → the conf repo's ref mode, exactly as before.
#   (The DASH leg went with the rows' PR cell, issue #4902.)
#
# Hermetic: gh/tmux are PATH shims, git runs on a throwaway repo, every cache lands
# under TMPDIR=$WORK. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-repo-fixture.sh"
REFRESH="$BIN/tmux-pr-refresh.sh"
command -v git >/dev/null 2>&1 || { printf 'deploy-multirepo-selftest: git absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-multirepo-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf"
unset FLEET_DEPLOY_REF FLEET_DEPLOY_CHECK FLEET_REPO FLEET_MAIN FLEET_SESSION TMUX TMUX_PANE 2>/dev/null || true

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }

SESS=s1
C="$WORK/.claude-dash"
FT="$C/fleets/acme-tool" FA="$C/fleets/acme-app"
OVL="$FLEET_CONF_DIR/fleets/$SESS/repos"
mkdir -p "$C/global" "$FT" "$FA" "$FLEET_CONF_DIR/fleets/$SESS" "$WORK/bin" "$WORK/api"

# --- the deployment checkout (ref mode) ------------------------------------------
REF="$WORK/deploy-ref"
git init -q "$REF" && git -C "$REF" -c user.name=t -c user.email=t@t commit -q --allow-empty -m A \
  && SHA_T=$(git -C "$REF" rev-parse HEAD) || fail "could not build the temp git repo"
SHA_APP=0123456789abcdef0123456789abcdef01234567    # never in $REF

# --- shims ------------------------------------------------------------------------
# gh: `pr list --repo <r>` → $WORK/prmap.<slug>.tsv; `api …head_sha=<sha>` → $WORK/api/<sha>
# (missing ⇒ exit 1, the transient-failure shape — the producer then writes nothing).
cat > "$WORK/bin/gh" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/gh.log"
case "\${1:-} \${2:-}" in
  "api "*) q="\$2"; sha="\${q##*head_sha=}"; sha="\${sha%%&*}"
           [ -f "$WORK/api/\$sha" ] || exit 1
           cat "$WORK/api/\$sha"; exit 0 ;;
  "pr list") r=''; prev=''
             for a in "\$@"; do [ "\$prev" = --repo ] && r="\$a"; prev="\$a"; done
             f="$WORK/prmap.\${r//\//-}.tsv"; [ -f "\$f" ] && cat "\$f"; exit 0 ;;
esac
exit 0
SHIM
# tmux: no live fleet server; the rows producer's list-windows (0x1f -F) replays WLIST_FILE.
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037'); lw=0; fmt=0
for a in "$@"; do
  [ "$a" = has-session ] && exit 1
  [ "$a" = list-windows ] && lw=1
  case "$a" in *"$US"*) fmt=1 ;; esac
done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "${WLIST_FILE:-/dev/null}"
exit 0
SHIM
chmod +x "$WORK/bin/gh" "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH

# Both repos merged an issue-1 PR, and each also carries the OTHER mode's `live` sha:
# under a leaked knob that row would read live; under the right one it must not.
printf 'issue-1\t#1\tMERGED\t✓\t\t%s\nissue-2\t#2\tMERGED\t✓\t\t%s\n' "$SHA_T" "$SHA_APP" > "$WORK/prmap.acme-tool.tsv"
printf 'issue-1\t#5\tMERGED\t✓\t\t%s\nissue-2\t#6\tMERGED\t✓\t\t%s\n' "$SHA_APP" "$SHA_T" > "$WORK/prmap.acme-app.tsv"
printf 'live\n' > "$WORK/api/$SHA_APP"          # $SHA_T has no runs → gh fails for it

printf '%s\tacme-tool\tacme/tool\n' "$SESS" > "$C/global/sessmap"
: > "$FLEET_CONF_DIR/fleets/$SESS/conf"
fx_repo "$FLEET_CONF_DIR" "$SESS" acme/tool FLEET_DEPLOY_REF="$REF"
overlay() { mkdir -p "$OVL"; { printf 'FLEET_REPO="acme/app"\n'; printf '%s\n' "$@"; } > "$OVL/acme-app.conf"; }

dep() { [ -f "$1/deploy_$2" ] && cut -f1 < "$1/deploy_$2"; }
reset() { rm -f "$FT"/deploy_* "$FA"/deploy_*; : > "$WORK/gh.log"; }
refresh() { bash "$REFRESH" --repo "$1" >"$WORK/refresh.out" 2>&1 || fail "tmux-pr-refresh.sh --repo $1 exited non-zero" "$(cat "$WORK/refresh.out")"; }

# ============================================================ PRODUCER
overlay 'FLEET_DEPLOY_CHECK="actions"'
reset
refresh acme/tool
eq    "producer: ref repo — its merge sha is in the deployment → live" live    "$(dep "$FT" "$SHA_T")"
eq    "producer: ref repo — the actions repo's live sha is NOT live here" unknown "$(dep "$FT" "$SHA_APP")"
hasnt "producer: ref repo is probed by git, never gh api" "$(cat "$WORK/gh.log")" "actions/runs"
refresh acme/app
eq    "producer: actions repo — green post-merge runs → live" live "$(dep "$FA" "$SHA_APP")"
has   "producer: actions repo asks gh for ITS repo's runs" "$(cat "$WORK/gh.log")" "repos/acme/app/actions/runs?head_sha=$SHA_APP"
[ ! -f "$FA/deploy_$SHA_T" ] || fail "producer: the conf repo's FLEET_DEPLOY_REF leaked into the overlay repo" "$(cat "$FA/deploy_$SHA_T")"
CHECKS=$((CHECKS+1))

# ============================================================ NO LEAK
overlay 'FLEET_BASE_BRANCH="main"'
reset
refresh acme/app
[ -z "$(ls "$FA"/deploy_* 2>/dev/null)" ] || fail "no-leak: an overlay without deploy keys must write nothing" "$(ls "$FA")"
CHECKS=$((CHECKS+1))
hasnt "no-leak: … and make no gh api call" "$(cat "$WORK/gh.log")" "actions/runs"
# the first repo's overlay sets its own mode, like any other's
fx_repo "$FLEET_CONF_DIR" "$SESS" acme/tool FLEET_DEPLOY_REF="" FLEET_DEPLOY_CHECK=actions
reset
refresh acme/tool
has   "own-overlay: the first repo's overlay overrides its deploy mode" "$(cat "$WORK/gh.log")" "repos/acme/tool/actions/runs"
fx_repo "$FLEET_CONF_DIR" "$SESS" acme/tool FLEET_DEPLOY_REF="$REF"

# ============================================================ DEGENERATE
rm -f "$OVL/acme-app.conf"
reset
refresh acme/tool
eq    "degenerate: one repo → its ref mode, as before" live "$(dep "$FT" "$SHA_T")"
hasnt "degenerate: … still no gh api" "$(cat "$WORK/gh.log")" "actions/runs"
refresh acme/app
[ -z "$(ls "$FA"/deploy_* 2>/dev/null)" ] || fail "degenerate: a repo the fleet does not host gets no deploy state" "$(ls "$FA")"
CHECKS=$((CHECKS+1))

printf 'deploy-multirepo-selftest: OK (%d checks) — each repo keeps its own deploy signal in a shared fleet (issue #805)\n' "$CHECKS"
