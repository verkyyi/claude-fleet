#!/bin/bash
# helper-auth-selftest.sh — the screen-classifier helper must ride the account
# POOL, and a failed helper call must not be mistaken for an answer (issue #497).
#
# bin/classify-sessions.sh is the fleet's only direct `claude -p` call site (the
# dash summarizer that shared this wire retired in issue #535). Every WORKER runs
# on a pool token (bin/fleet-claude.sh exports CLAUDE_CODE_OAUTH_TOKEN before
# exec'ing claude); the helpers used to run on the machine's AMBIENT login instead
# — the one credential nothing else in the fleet depends on. On 2026-08-25 that
# login lapsed: all eleven workers kept going, and the looping-detector (and the
# then-summary column) went dark together.
#
# It presented as TOTAL rather than partial because of the second half. `claude`
# prints its auth failure on STDOUT, the helper took stdout line 1 with no status
# check, and the change-gate hash was stamped whether or not the call worked — so
# the error string became the answer, and stamping the hash retired that screen
# from every later producer.
#
# Asserted here:
#   • POOL-TOKEN   fleet_helper_claude_auth exports the ACTIVE account's token
#   • INHERIT-WINS an already-set CLAUDE_CODE_OAUTH_TOKEN is never overwritten (the
#                  hook path is a child of a worker's claude — re-resolving 'active'
#                  there could hand a hook the OTHER account mid-turn)
#   • POOL-OFF     no accounts configured ⇒ clean no-op (ambient login still correct)
#   • REACHES-CLI  the token is actually in the env of the `claude` the classifier runs
#   • CLASSIFY-NO-POISON  a FAILING helper call leaves the change-gate hash UNWRITTEN
#                  and @claude_state alone, however plausible its stdout looks; an
#                  rc=0-but-unparseable answer still stamps the hash
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
CLS="$BIN/classify-sessions.sh"
ACCT="$BIN/fleet-account.sh"
for f in "$LIB" "$CLS" "$ACCT"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/helper-auth-selftest.XXXXXX")" || exit 2

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# Isolate tmux onto a private socket via a PATH shim — the classifier calls bare
# `tmux` on its --window path, so this is what routes it here. Never the user's
# live server.
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"

# FAKE claude: records the OAuth token it was invoked WITH, then behaves as
# \$WORK/claude-rc + \$WORK/claude-out dictate. Printing to stdout AND exiting
# non-zero is the real failure shape we are guarding (that is how the auth error
# reached the dash in the first place). No network, no real credentials.
cat > "$WORK/bin/claude" <<EOF
#!/bin/sh
printf '%s' "\${CLAUDE_CODE_OAUTH_TOKEN:-}" > "$WORK/claude-token"
cat >/dev/null
cat "$WORK/claude-out" 2>/dev/null
exit "\$(cat "$WORK/claude-rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

export TMPDIR="$WORK"                       # FLEET_C → $WORK/.claude-dash
export FLEET_CONF_DIR="$WORK/conf"
export FLEET_ACCOUNTS_DIR="$WORK/accounts"  # fleet-account.sh reads this
export CLASSIFY_SETTLE=0
unset CLASSIFY_SOCK                         # force the bare-`tmux` (PATH shim) path
unset CLAUDE_CODE_OAUTH_TOKEN

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---------------------------------------------------------------- unit: the wire
# shellcheck source=/dev/null
. "$LIB"
command -v fleet_helper_claude_auth >/dev/null 2>&1 \
  || fail "fleet_helper_claude_auth not defined by fleet-lib.sh (issue #497)"
ok "fleet-lib.sh defines fleet_helper_claude_auth"

# POOL-OFF: no accounts dir at all ⇒ nothing exported, nothing broken.
( unset CLAUDE_CODE_OAUTH_TOKEN; fleet_helper_claude_auth
  [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] ) \
  || fail "with no accounts configured the helper still exported a token"
ok "no pool configured ⇒ clean no-op (the ambient login stays correct)"

mkdir -p "$FLEET_ACCOUNTS_DIR"
printf 'tok-alpha\n' > "$FLEET_ACCOUNTS_DIR/alpha@example.com"
printf 'tok-beta\n'  > "$FLEET_ACCOUNTS_DIR/beta@example.com"
chmod 600 "$FLEET_ACCOUNTS_DIR"/*
bash "$ACCT" use beta@example.com >/dev/null 2>&1 \
  || fail "could not pin the active pool account"

# POOL-TOKEN: the ACTIVE account's token, not just any account's.
got="$( unset CLAUDE_CODE_OAUTH_TOKEN; fleet_helper_claude_auth; printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" )"
[ "$got" = 'tok-beta' ] || fail "helper did not export the ACTIVE account's token — got [$got]"
ok "fleet_helper_claude_auth exports the active pool account's token"

# INHERIT-WINS: a token already in the env is the hook path's, and it must survive.
got="$( CLAUDE_CODE_OAUTH_TOKEN=tok-inherited; export CLAUDE_CODE_OAUTH_TOKEN
        fleet_helper_claude_auth; printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" )"
[ "$got" = 'tok-inherited' ] \
  || fail "an inherited CLAUDE_CODE_OAUTH_TOKEN was overwritten — got [$got]"
ok "an inherited token always wins (the Stop hook keeps its worker's account)"

# ------------------------------------------------- integration: a fleet-shaped pane
tmux -f /dev/null new-session -d -s fleet-t -x 140 -y 40 \
  || fail "could not start isolated tmux server"
ww="$(tmux display-message -p '#{window_id}')"
tmux rename-window -t "$ww" issue-497
tmux set-window-option -t "$ww" @issue 497
tmux set-window-option -t "$ww" @claude_state 'done'
tmux respawn-pane -k -t "$ww" "printf 'a stable screen to hash\n'; sleep 300" 2>/dev/null \
  || fail "could not seed the worker pane"
i=0
while [ "$i" -lt 40 ]; do
  [ -n "$(tmux capture-pane -p -t "$ww" 2>/dev/null | tr -d '[:space:]')" ] && break
  i=$((i+1)); sleep 0.1
done
[ -n "$(tmux capture-pane -p -t "$ww" 2>/dev/null | tr -d '[:space:]')" ] \
  || fail "isolated worker pane never rendered content"

wopt() { tmux show-options -w -t "$1" -v "$2" 2>/dev/null; }

# --- CLASSIFY-NO-POISON: the two rails on the state classifier -------------------
CCACHE="$BIN/../logs/.classify-cache"
ckey="$(printf '%s' "$ww" | tr '/:@' '___')"
rm -f "$CCACHE/$ckey.hash"
printf 'Failed to authenticate: OAuth session expired and could not be refreshed\n' > "$WORK/claude-out"
printf '1\n' > "$WORK/claude-rc"
tmux set-window-option -t "$ww" @claude_state 'done'
bash "$CLS" --window "$ww" || fail "classifier exited non-zero on a failed helper call"
[ "$(wopt "$ww" @claude_state)" = 'done' ] \
  || fail "a FAILED helper call moved @claude_state — got [$(wopt "$ww" @claude_state)]"
ok "classify: a failed helper call leaves @claude_state alone"
[ -f "$CCACHE/$ckey.hash" ] \
  && fail "classify stamped its change-gate hash despite the helper failing"
ok "classify: a failed helper call leaves the change-gate hash unwritten"
[ "$(cat "$WORK/claude-token" 2>/dev/null)" = 'tok-beta' ] \
  || fail "the classifier's claude ran WITHOUT the pool token — got [$(cat "$WORK/claude-token" 2>/dev/null)]"
ok "the pool token reaches the claude process the classifier runs"

# rc=0 with garbage is a DIFFERENT case: the model answered, we just could not use
# it, and re-asking the same screen would not help — that one still stamps the hash.
rm -f "$CCACHE/$ckey.hash"
printf 'purple monkey dishwasher\n' > "$WORK/claude-out"
printf '0\n' > "$WORK/claude-rc"
bash "$CLS" --window "$ww" || fail "classifier exited non-zero on an unparseable answer"
[ -f "$CCACHE/$ckey.hash" ] \
  || fail "an unparseable (but successful) answer no longer stamps the hash — that re-asks a screen the model already answered"
ok "classify: rc=0 but unparseable still stamps the hash (unchanged behaviour)"
rm -f "$CCACHE/$ckey.hash"

printf 'selftest OK: %s checks — helper claude -p rides the account pool, and a failed call is not an answer (issue #497)\n' "$pass"
