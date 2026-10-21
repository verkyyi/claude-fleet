#!/bin/bash
# fleet-pool-run-selftest.sh — bin/fleet-pool-run.sh and shell/fleet-pool.zsh (task
# KEA0): `claude` / `codex` typed at a managed login's shell get a session
# credential from the login's proxy and run on it; it is revoked at the exit;
# ~/.fleet-pool-off, FLEET_SHELL_POOL=0, an already wired environment, a proxy
# that binds nothing (4) or fails pass straight to the plain program. A stand-in
# fleet-session-cred.sh (FLEET_POOL_SESSION_CRED) and stand-in agents on PATH.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_sandbox "${TMPDIR:-/tmp}/poolrun.XXXXXX"
st_tally
RUN="$BIN/fleet-pool-run.sh"
mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/sc.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$POOL_T/sc.calls"
case "$1" in
  mint) case "${POOL_MINT_RC:-0}" in 0) printf 'direct\t18923\tfcp1.SECRET\n' ;; *) exit "$POOL_MINT_RC" ;; esac ;;
  codex-home) mkdir -p "$POOL_T/ch"; echo "$POOL_T/ch" ;;
  revoke) : ;;
esac
SH
for t in claude codex; do
  cat > "$WORK/bin/$t" <<SH
#!/bin/bash
echo "$t argv=\$* base=\${ANTHROPIC_BASE_URL:-} tok=\${CLAUDE_CODE_OAUTH_TOKEN:-} cx=\${FLEET_CODEX_SESSION_CRED:-} home=\${CODEX_HOME:-}"
SH
done
chmod +x "$WORK/sc.sh" "$WORK/bin/claude" "$WORK/bin/codex"
run() { env -u ANTHROPIC_BASE_URL -u FLEET_CRED_SID -u CLAUDE_CODE_OAUTH_TOKEN HOME="$WORK/home" POOL_T="$WORK" \
          FLEET_POOL_SESSION_CRED="$WORK/sc.sh" PATH="$WORK/bin:/usr/bin:/bin" "$@" 2>"$WORK/err"; }

: > "$WORK/sc.calls"
out=$(run bash "$RUN" claude -p hi)
st_eq claude-wired "claude argv=-p hi base=http://127.0.0.1:18923 tok=fcp1.SECRET cx= home=" "$out"
st_has claude-said "$(cat "$WORK/err")" "共享订阅"
st_hasnt claude-no-secret-said "$(cat "$WORK/err")" "SECRET"
st_has claude-revoked "$(cat "$WORK/sc.calls")" "revoke --sid pool-"
st_has claude-mint "$(cat "$WORK/sc.calls")" "mint --provider claude --sid pool-"

out=$(run bash "$RUN" codex exec x)
st_has codex-provider "$out" 'model_provider="fleet"'
st_has codex-cred "$out" "cx=fcp1.SECRET home=$WORK/ch"
st_has codex-args "$out" "exec x"

touch "$WORK/home/.fleet-pool-off"
out=$(run bash "$RUN" claude -p hi); st_eq off-file "claude argv=-p hi base= tok= cx= home=" "$out"
rm -f "$WORK/home/.fleet-pool-off"
out=$(run env FLEET_SHELL_POOL=0 bash "$RUN" claude); st_eq off-env "claude argv= base= tok= cx= home=" "$out"
out=$(run env ANTHROPIC_BASE_URL=http://x bash "$RUN" claude); st_has wired-already "$out" "base=http://x tok="
out=$(run env POOL_MINT_RC=4 bash "$RUN" claude); st_eq nothing-bound "claude argv= base= tok= cx= home=" "$out"
out=$(run env POOL_MINT_RC=1 bash "$RUN" claude); st_eq mint-failed "claude argv= base= tok= cx= home=" "$out"
st_has mint-failed-said "$(cat "$WORK/err")" "没接上"

# the zsh snippet: two functions that route through the runner
if command -v zsh >/dev/null 2>&1; then
  mkdir -p "$WORK/fl/shell" "$WORK/fl/bin"
  cp "$BIN/../shell/fleet-pool.zsh" "$WORK/fl/shell/"; cp "$RUN" "$WORK/fl/bin/"
  got=$(zsh -fc "source '$WORK/fl/shell/fleet-pool.zsh'; whence -f claude codex" 2>&1)
  st_has zsh-claude "$got" "fleet-pool-run.sh claude"
  st_has zsh-codex "$got" "fleet-pool-run.sh codex"
fi
st_done
