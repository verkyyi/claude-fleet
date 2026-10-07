# cred-proxy — research prototype (issue #1872)

> **The installed proxy is [`bin/fleet-cred-proxy.py`](../../bin/fleet-cred-proxy.py)**
> (issue #1970, EPIC #1967 C3): a per-login daemon (`com.claude-fleet.cred-proxy`)
> with a control socket and route selection (direct / relay / central). This
> prototype stays for the research audits below (`--audit`, `--sinkhole`, `sim/`).

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
  token from `~/.config/claude-fleet/accounts/<acct>.hub/.credentials.json` (Codex:
  `~/.codex/auth.json` for `default`, else `~/.codex-accounts/<acct>/auth.json` —
  where the node agent leases them) **in memory, per request**, drops `x-api-key`,
  sets `Authorization: Bearer <real>` (Codex: and ALWAYS the bound account's
  `chatgpt-account-id`) and streams the response back untouched.
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
| `serve … --codex-upstream URL --codex-homes DIR` | where `/codex/*` goes (loopback `http://` allowed — the simulator) and where Codex accounts live |
| `serve … --max-seconds N` | exit on its own after N s, so a forgotten one cannot linger |
| `serve … --audit --sinkhole --mitm-cert C --mitm-key K` | the OFFLINE audit (issue #1912): answer every CONNECT locally, log method/path + which kind of credential it carried, never connect out |
| `serve … --audit [--mitm-cert C --mitm-key K]` | also act as `HTTPS_PROXY`: log every CONNECT; with a throwaway CA the client trusts (`NODE_EXTRA_CA_CERTS`), log the method/path/status of traffic that BYPASSES the base URL. Research only. |

## Codex, with no ChatGPT login: `sim/`

[`sim/`](sim/) is a fake ChatGPT backend + a one-command harness that runs a real
`codex` CLI through this proxy and checks everything the proxy is responsible for
(issue #1912): `python3 -I extras/cred-proxy/sim/simtest.py --codex <codex>`.
`sim/real-check.sh` is the same against the real backend, for a machine that has
a valid login.
