# xssh — the door's copy of golang.org/x/crypto/ssh (A5SQ)

The cluster door terminates each person's SSH and hands the hub the signature
they made to log in; the hub signs the door's hop home only for that signature
(`docs/dev/DOOR-SIMPLIFY.md` §5 — the door holds no key into any home).
`golang.org/x/crypto/ssh` verifies the signature but never gives it to its
caller, so `agent/door` uses this copy of that one package with one patch:
`fleet.patch` adds `ServerConfig.SignedPublicKeyCallback`, called after the
signature verified, with it (the hunks are marked `xssh-patch`).

Everything else here is upstream byte for byte — the copy of the version
`tokenledger/agent/go.mod` requires, with two imports rewritten (x/crypto's
internal poly1305 → its public `golang.org/x/crypto/poly1305`, and the package's
own `internal/bcrypt_pbkdf`, copied beside it). `LICENSE` is upstream's (BSD).

## Keeping it in step (who · when · how)

- **When**: every time `golang.org/x/crypto` moves in `tokenledger/agent/go.mod` —
  above all for an upstream security fix (a Go vulnerability notice for
  `golang.org/x/crypto/ssh`, or a Dependabot bump).
- **Who**: whoever moves the version, in the same PR. `bin/xssh-sync-selftest.sh`
  is red until the copy is the required version's (CI selects it whenever
  go.mod, this directory or the script changes).
- **How**: bump the version, then `bin/xssh-sync.sh` (copies, rewrites, applies
  `fleet.patch`), `bin/xssh-sync.sh --check`, commit all three. If the patch no
  longer applies, redo the two hunks by hand on the new `server.go` and refresh
  `fleet.patch` (`diff -u` of upstream's `server.go` against the patched one).
- Never edit a file here by hand except `fleet.patch` and this README.
