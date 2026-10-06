# cred-proxy — research prototype (issue #1872)

**Not part of the install.** Nothing in `bin/`, `conf/` or any launch path
references it. It exists to answer whether a session can run on a subscription
without the subscription credential ever entering the session.
Findings: [`docs/RESEARCH-CRED-PROXY.md`](../../docs/RESEARCH-CRED-PROXY.md).

## What it does

```
claude ──(Bearer fcp1.<session cred>)──▶ 127.0.0.1:PORT ──(Bearer <real token>)──▶ api.anthropic.com
codex  ──(Bearer fcp1.<session cred>)──▶ 127.0.0.1:PORT/codex ──(Bearer + chatgpt-account-id)──▶ chatgpt.com/backend-api/codex
```

- A session credential is `fcp1.<claims>.<HMAC>` — claims `sid`, `acct`, `exp` —
  signed with the proxy's own key (`<state>/key`, 0600).
- On each request the proxy verifies it, picks the account (`<state>/bind.json`
  overrides the minted one — that is the no-restart account switch), reads the real
  token from `~/.config/claude-fleet/accounts/<acct>.hub/.credentials.json` (or
  `~/.codex/auth.json`) **in memory, per request**, drops `x-api-key`, sets
  `Authorization: Bearer <real>` and streams the response back untouched.
- Every credential-shaped header is logged as `<redacted:len>`.
- Binds `127.0.0.1` only. Stop it when you are done (Ctrl-C).

## One command

```sh
S=$(mktemp -d); P=extras/cred-proxy/cred_proxy.py
python3 -I $P serve --port 18787 --state $S/state --log $S/proxy.log &   # stop with: kill %1
TOK=$(python3 -I $P mint --state $S/state --account icloud --sid demo --ttl 3600)
mkdir $S/cfg && env -i HOME=$HOME PATH=$PATH CLAUDE_CONFIG_DIR=$S/cfg CLAUDE_SECURESTORAGE_CONFIG_DIR=$S/cfg \
  ANTHROPIC_BASE_URL=http://127.0.0.1:18787 CLAUDE_CODE_OAUTH_TOKEN="$TOK" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude -p 'Reply: PONG' </dev/null
```

`CLAUDE_CODE_OAUTH_TOKEN=<session cred>` (mode B) keeps Claude Code in
subscription mode — `rate_limits` in the statusLine JSON, so the fleet's `@rl*`
works. `ANTHROPIC_AUTH_TOKEN=<session cred>` (mode A) also works for inference
but Claude Code then runs in API-key mode (no `rate_limits`, "API Usage Billing").

Other subcommands:

| command | what |
|---|---|
| `rebind --state S --sid X --account L` | move session X to account L — its next request uses L, no restart |
| `echo X >> S/revoked` | revoke session X (next request → 401 `session credential revoked`) |
| `serve … --no-beta` | don't add `anthropic-beta: oauth-2025-04-20` (not needed, see doc §2) |
| `serve … --audit [--mitm-cert C --mitm-key K]` | also act as `HTTPS_PROXY`: log every CONNECT; with a throwaway CA the client trusts (`NODE_EXTRA_CA_CERTS`), log the method/path/status of traffic that BYPASSES the base URL. Research only. |
