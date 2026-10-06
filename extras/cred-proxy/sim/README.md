# cred-proxy/sim — Codex through the proxy, with no real ChatGPT credential

**Research only (issue #1912). Not part of the install**; nothing in `bin/`,
`conf/` or any launch path references it. Findings:
[`docs/RESEARCH-CRED-PROXY.md`](../../../docs/RESEARCH-CRED-PROXY.md) §10.

```
codex ──(Bearer fcp1.<session cred>)──▶ cred_proxy.py /codex ──(Bearer <access token> + chatgpt-account-id)──▶ fake_chatgpt.py
 fresh CODEX_HOME, no auth.json          127.0.0.1                                                              127.0.0.1
```

## One command

```sh
npm install --prefix /tmp/cx @openai/codex          # any codex CLI; no login needed
python3 -I extras/cred-proxy/sim/simtest.py --codex /tmp/cx/node_modules/.bin/codex
```

It starts the fake backend and the proxy on free loopback ports, runs 16 checks,
prints `PASS`/`FAIL` with the evidence under each, and stops everything (both
servers also carry their own `--max-seconds` deadline). `--only pong,tools`
runs a subset; `--keep DIR` keeps the logs; `--runs N` sets the latency sample.

| check | what it proves |
|---|---|
| `pong` | `codex exec 'Reply with exactly: PONG'` → `PONG`; which headers the proxy changed (only `Authorization` + `chatgpt-account-id`); the body shape Codex sends |
| `tools` | a shell call + an `apply_patch` call + a final answer, then `exec resume --last` (multi-turn) |
| `ratelimit` | `x-codex-primary-*` headers land in the rollout's `token_count.rate_limits` (what `tokenledger/internal/scan/codex_telemetry.go` reads); `rebind` moves the same session to another account, no restart |
| `refresh` | the "vault" refreshes the token and rewrites `auth.json`; the running session's next request uses the new token, the old one is `token_revoked` |
| `concurrency` | three sessions at once on two accounts, no bleed |
| `spoof` | a session that sends its own `chatgpt-account-id` still gets its bound account |
| `badcreds` | expired / forged / revoked / no account / not a session credential → what Codex shows, how often it retries |
| `stream` | 5000 deltas arrive intact |
| `latency` | direct vs through the proxy, `codex exec` wall time and HTTP first byte |
| `noleak` | `ps -E` of every session process + every file in `CODEX_HOME`: the session credential, never an access token |
| `bypass` | an **offline** audit: `HTTPS_PROXY` = the proxy in `--sinkhole` mode with a throwaway CA (`CODEX_CA_CERTIFICATE`); every CONNECT is answered locally (503), nothing leaves the machine; once with the default config, once with the switches that keep Codex on `base_url` |

## The pieces

- **`fake_chatgpt.py`** — `serve` answers `POST /backend-api/codex/responses`
  as SSE and `POST /oauth/token` (refresh grant, Codex's public client id); every
  other path is logged with the credential it carried and answered `200 {}`.
  Tokens are per account; a refresh rotates both and makes the old access token
  answer `401 token_revoked`, like the real backend. Each account reports its own
  `x-codex-primary-used-percent` (11 / 77) so a rebind is visible. Replies are
  scripted off the last user message (`Reply with exactly: PONG`, `DO-TOOLS`,
  `STREAM <n>`, `SLOW <ms>`, else an echo naming the account). `seed` plays the
  hub's lease (writes `<homes>/<label>/auth.json` in the node agent's shape,
  refresh token = `hub-managed`); `refresh` plays the hub vault. Requests are
  logged to `<state>/requests.log` with header names and `<redacted:len>` values.
- **`simtest.py`** — the harness above.
- **`real-check.sh [ACCOUNT] [CODEX]`** — the same two turns against the REAL
  backend, on a machine with a valid ChatGPT login: reads `~/.codex/auth.json`
  (or `~/.codex-accounts/<ACCOUNT>/auth.json`) in the proxy's memory, never logs
  in or refreshes, prints the redacted proxy log + the rollout's rate limits.
  `CRED_PROXY_CODEX_UPSTREAM` / `_AUTH` / `_HOMES` point it at the fake instead
  (how it was tested).

## Proxy flags added for this

`--codex-upstream URL` (default `https://chatgpt.com/backend-api/codex`; plain
`http://` only to loopback), `--codex-homes DIR` (account `L` → `DIR/L/auth.json`,
`default` → `--codex-auth`, the node agent's own mapping), `--max-seconds N`, and
`--sinkhole` for the offline audit.
