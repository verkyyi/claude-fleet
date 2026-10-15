# Codex authentication recovery

## Immediate repair (PR #4372)

Opening a terminal is not authentication acceptance. The terminal Fleet panel
must create a repository task and receive a real model response.

Two credential paths need independent coverage:

| Path | Rejection source | Recovery owner |
| --- | --- | --- |
| Personal POD, central proxy | Central HTTP response | Hub vault |
| Separated machine, direct/relay | Credential proxy's effective pooled auth home | Hub vault |

The central proxy reports a recognized access-token rejection through an
authenticated resolve request. The hub verifies the session binding, account,
and rejected access fingerprint before invalidating cached access. The proxy
retries the unchanged request once only after receiving different usable access.
Refresh-token refusals and relay authentication failures do not trigger this
access-token recovery.

Separated agents cannot inspect `~/.codex/auth.json`: their provider credentials
are deliberately absent there. The proxy's `upstream-rejections` control request
returns only the current tenant's hub-managed Codex rejection metadata. It reads
the same pool entry as the request path, matches the exact credential version,
and returns a SHA-256 access fingerprint, provider, account, and error code.
Neither access nor refresh tokens are returned. Existing peer-UID authorization
still applies. Personal logins, removed accounts, accepted verdicts, and stale
verdicts are excluded.

The node agent carries this report on its next credential lease; the existing
rejection poll wakes that lease early. This path renews access for subsequent
requests in an existing session, but does not transparently replay the first
failed request. A user may need to retry that turn. An older/unavailable proxy
produces a transition-only agent warning rather than an invented rejection.

This is an interim repair of Fleet's existing refresh system. It is not a
migration to Codex-managed authentication and does not guarantee an expired or
revoked refresh grant can recover without owner reauthentication.

## Native refresh owner design (not enabled by this PR)

Reference: [Maintain Codex account auth in CI/CD](https://learn.chatgpt.com/docs/auth/ci-cd-auth).
The guide applies to managed ChatGPT authentication on trusted private runners,
not external-token host integrations. It recommends Codex's built-in renewal,
durable refreshed auth state, and one machine or serialized stream per auth copy.
API keys remain its general automation recommendation. Do not copy its runner
workflow into every Fleet worker.

The proposed owner is one dedicated trusted credential service per enrolled
credential identity. It is not an ordinary worker login, a randomly selected
network relay, or each hub replica. Worker processes continue to receive only
short-lived access through their existing proxy boundary.

### Authority and lifecycle

1. Explicitly enroll an account into a dedicated persistent `CODEX_HOME` owned by
   the trusted service, inaccessible to workers. Bootstrap once with a supported
   Codex login. Never overwrite that home's refreshed state from an import seed.
2. Register a stable credential identity, pinned owner, and ownership generation
   in shared storage. Before activation, stop Fleet's custom OAuth refresh and
   any other refresh writer for that credential. Merely adding a second refresher
   would introduce rotation races rather than fix them.
3. Serialize owner work with a local profile lock and a cross-replica request
   coordinator. Run the official Codex client in that persistent home with
   file-backed managed ChatGPT authentication. Do not implement another OAuth
   endpoint call, forge `last_refresh`, or assume a scheduled run always rotates.
4. On rejection, submit the exact rejected access fingerprint to the owner. The
   owner first checks whether its durable state already contains a replacement.
   Otherwise, let the official client encounter and handle the authentication
   failure through its supported flow. Prove this behavior against the deployed
   Codex version before enabling it; a metadata-only account read is not evidence
   that inference authentication succeeded.
5. Validate account identity and usable access, retain Codex's updated auth state
   durably, then publish only access metadata/tokens to the encrypted hub cache.
   Never return the refresh token to workers or store it in logs, PRs, or artifacts.
6. If acknowledgement/cache publication fails after rotation, recover from the
   owner's updated file. Never restore the earlier refresh token or reseed from
   stale hub state. Retrying the same request must read durable state first.

### Failover and rollback

Hub failover can reconnect to the same owner without moving refresh authority.
Owner failover must fail closed until the old process/machine is fenced and its
latest persisted auth state is recovered. A database lease timeout alone cannot
fence an old process still calling the provider. Do not automatically bootstrap
a replacement owner from an old backup.

After activation, rollback must not re-enable the custom refresher against the
old vault secret. Pause refresh, fence the native owner, and recover current
state or explicitly reauthenticate. Account policy and subscription permissions
remain unchanged throughout migration.

### Acceptance gates

- Concurrent rejection reports through both hub replicas trigger one owner
  operation; stale fingerprints cannot invalidate replacement access.
- Rotation survives process restart, lost acknowledgement, and temporary hub
  unavailability without restoring a seed or reusing the old refresh token.
- Owner loss fails closed; a fenced transfer preserves identity and latest state.
- Direct, relay, and central routes recover on subsequent requests without
  recreating user workers; revoked refresh credentials report owner action.
- A terminal Fleet panel repository task starts and answers, then the same
  session answers after simulated access replacement. CLI fixtures are recorded
  separately from real panel acceptance.
- No live provider token is intentionally revoked for testing. Use fake-provider
  fixtures for destructive rotation/failure scenarios and a dedicated test
  credential for live acceptance before migrating any production account.

## Rollout of the interim repair

Run the proxy rejection fixtures, agent lease tests, vault two-replica tests,
central proxy recovery tests, and panel adapter regression before merging.
Deploy compatible hub/proxy code first, then the separated proxy and node agent.
Verify actual running versions, not only workflow success. Shared-proxy updates
can interrupt in-flight HTTP connections even though worker processes remain;
coordinate a quiet interval rather than promise a zero-impact restart.

For the affected separated machine, confirm a matching pooled rejection appears
in the hub audit, a new access fingerprint is installed, and a later request from
the existing session succeeds. For the affected personal POD, verify central
recovery and the terminal panel repository task separately. If terminal
automation is unavailable, mark real panel
acceptance pending operator evidence; do not substitute a CLI launch.
