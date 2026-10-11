# The client's own logs

> Issue #2896 (EPIC #2889 C7). A computer that runs the `fleet` client writes
> down, on its own disk, every connection it makes, every session it asks a
> machine to open, every renewal its keeper makes and every login — where it
> went, by which road, how long, who ended it and why. When a colleague is
> «stuck at 正在连接», the answer is read here instead of asking them to run it
> again with `-v` and send a screenshot.

This page is the contract. C1's bundle (`fleet doctor --bundle`) takes its
whitelist from it; C3 and C4 read what C1 packs. **Fields are only ever added,
never changed or removed.**

## Where

```
~/.cache/claude-fleet/shell/logs/
  connect.log   (+ connect.log.1)
  place.log     (+ place.log.1)
  keeper.log    (+ keeper.log.1)
  login.log     (+ login.log.1)
  keeper.out    (+ keeper.out.1)   the keeper's raw stdout + stderr — not TSV
  ssh-v.log     (+ ssh-v.log.1)    only with FLEET_CONNECT_SSH_VERBOSE=1 — not TSV
```

The directory is `FLEET_CLIENT_LOG_DIR`, else the shell's cache
(`FLEET_SHELL_CACHE`, else `${XDG_CACHE_HOME:-~/.cache}/claude-fleet/shell`,
`bin/fleet-shell.sh`'s `CACHE`) + `/logs`, created 0700; each file 0600.

A file that has reached `FLEET_CLIENT_LOG_MAX` bytes (512 KiB) is renamed to
`<name>.1` before the next line — one old copy, the older one gone. So a log
never takes more than ~1 MiB with its `.1`. `keeper.out` is rotated before each
keeper start (the keeper holds it open), `ssh-v.log` before each ssh.

`FLEET_CLIENT_LOG=0` writes nothing — and `fleet connect` then `exec`s ssh
exactly as before.

## A line

One line per event, TSV, seven fields:

| # | field   | what |
|---|---------|------|
| 1 | time    | UTC, `2026-10-10T06:16:04Z` (seconds) — what the hub's records use |
| 2 | event   | per file, below |
| 3 | machine | the machine (alias) it was about; `-` when none; for `login.log` the hub URL |
| 4 | route   | `direct` · `relay` · `-` |
| 5 | ms      | how long, milliseconds; empty when it has no length |
| 6 | result  | per event, below |
| 7 | reason  | one line, in the words that were said — cut at 2000 bytes, then redacted |

Tabs and newlines inside a field become spaces. The reason is passed through
`conf/secret-shapes.list` (below) before it touches the disk.

## The events

### connect.log — `bin/fleet-connect.py`

| event | when | result | reason |
|---|---|---|---|
| `home` | the hub's machine pick (`fleet`) did not give one | the hub's code (`no_machine_online`, `opening`, `device_revoked`, …) or `unreachable` | the hub's words (+ the TLS hint, #2878) |
| `pick` | the routes were measured | `ok` · `fail` | every route: `<name> <answered>/<probes>` and its last error or skip |
| `pick` (route column `direct`) | a reconnect's remembered line was not the tailnet and the tailnet answered (#2987) | `ok` | `tailnet <name> over remembered <name>` |
| `switch` | `fleet-remote-view.sh open` — a click on a session row (#2987); ms = the whole `open` | `ok` | route column = how: `chan` (the serve channel, one round trip) · `select` (a one-shot over the window's master) · `readopt` (its control socket was gone; the warm master did it and the window took it) · `respawn` (a full reconnect — the reason says why: `down` · `chan no answer` · `ctl gone: <path>` · `select failed`) · `new` (a new proxy window) |
| `stray-end` | a proxy `run` loop that found its pane not its own ended (#2987) | `ok` | `pid N` |
| `ssh-start` | ssh is started | — | `<route name> <host>:<port> login=<login>` |
| `ssh-end` | ssh ended | `exit N` · `signal N` | `ssh ended normally` · `ssh: connection failed or was cut (255)` · `the remote command's exit` (+ `this side got signal N` when the client was signalled) |
| `relay-open` | a relay's handshake (ssh's ProxyCommand) | `ok` (ms = handshake) · `fail` | the hub URL · the refusal |
| `relay-end` | the relay's stream ended (ms = ready → the first end) | **who ended it**: `hub` · `client` · `net` | `ws close <code>: <reason>` (hub) · `ssh closed the stream (stdin EOF)` (client) · `the hub's socket closed with no close frame` (net) |

A slow switch reads off `switch` lines: one that is not `chan` / `select` names
why it was not. The ranking (`pick`) puts the tailnet first among routes that
answered every handshake — on one LAN the public gateway and the tailnet answer
within noise, and the one picked is kept for every reconnect;
`FLEET_CONNECT_PREFER_TAILNET=0` ranks by latency alone, as before.

`relay-end` is the line to put beside the hub's `/v1/fleet/ssh-relays` row for
the same minute: the hub records its own view of the same stream (direction,
length, `client closed: …`). The two should agree on the time (±1 s) and the
length.

For the end of ssh to be written, `fleet connect` runs ssh as a child and waits
(it used to `exec` it). It behaves as exec did: ^C / ^\ / ^Z reach ssh alone, a
SIGHUP / SIGTERM to `fleet connect` is passed on, a self-suspended ssh (`~^Z`)
stops `fleet connect` too, and ssh's exit is its exit.

`FLEET_CONNECT_SSH_VERBOSE=1` adds `ssh -v -E <logs>/ssh-v.log` (off by default:
it is long).

### thin.log — `bin/fleet-thin.py` (the thin client, #3003)

`${XDG_CACHE_HOME:-~/.cache}/claude-fleet/thin.log` (`FLEET_THIN_LOG`), the one
file the thin client writes; rotated and redacted as the others. Its own nine
fields, only ever added at the end:

    time  event  home  route  pick_ms  ssh_ms  first_ms  rc  reason

| event | when | fields |
|---|---|---|
| `connect` | each connection, when it ends | `pick_ms` = `fleet-connect.py --argv` (certificate · machine · route); `ssh_ms` = ssh spawned → the first byte back (handshake + the far end starting); `first_ms` = spawned → the home's first valid `cur` (the view drawn); `rc` = ssh's exit; reason `up` · `never up` · `quit` |
| `rehome` | three connections in a row never came up — a new home asked for (`--avoid`), or the machine named changed | reason: from / other than which |
| `first` | the home had no fleet session of yours (rc 3) or the hub is opening your first login — the first-session road (#3054): a start line, then rc 0 + the place line (opened there) or rc 1 + why it did not open | `home` (the machine it opened on, once placed); reason |
| `offline` | three connections failed and the hub did not answer either — this computer's own line is down, so no 换家: the home and the view are kept (#3007) | `home`; reason |
| `upload` | a drop or a ⌃V picture sent through the home | `ssh_ms` = the one-shot's time; reason `<name> → <path there>` |
| `exec` | a new client version between two connections | reason `<old> → <new>` |
| `say` | a word for the person (a file not sent) — also an OSC 9 notification | the words |
| `quit` / `end` | ⌘Q or a detach / a signal | `rc` |
| `run` | `fleet-thin.py --run`: one command on the home over a one-shot ssh — `fleet ls / open / close / answer`, `fleet claude` with no client tmux (issue #3004) | `home` · `route`; reason = the command's first word |

`connect.log` keeps the `home` / `pick` lines of each `--argv` run; the ssh
itself is the thin client's child, so it has no `ssh-start` / `ssh-end` there —
its end is the `connect` line here.

### place.log — `bin/fleet-client-place.sh`

| event | `issue-N` · `scratch` · `home` · `new` · `restore:<key>` |
|---|---|
| machine | the machine that answered (`REMOTE`/`RESUME`/`HELD`/`DECLINED`/`UNKNOWN`/`LOCAL` name one), else the one asked for (`auto`) |
| route | `-` |
| ms | from the ask to the answer |
| result | the answer's first word and the exit: `REMOTE 0` · `REFUSED 4` · `DECLINED 5` · `error 1` · `NOHUB 1` … |
| reason | `repo=<repo>` · the answer after its tab (the hub's `No machine can take…` with each machine's reason, as it said it) · everything said on stderr (machines that declined, why this computer was not chosen) |

### keeper.log — the keeper in `bin/fleet-shell.sh`

| event | result | reason |
|---|---|---|
| `start` | `pid N` | `session <name>` |
| `renew` · `input` | the hub's lease state (`active`, `taken_over`, …) · `fail` | `by <device>` + the hub's words · the lease command's last stderr line |
| `take` | `ok` · `fail` | the device |
| `stop` | `pid N` | `the client's tmux server is gone` |

A renewal is written only when its outcome differs from the last one written —
a steady lease every 15 s writes nothing. A keeper killed by a signal writes no
`stop`; the next `start` says it was replaced.

### login.log — `bin/fleet-login.py`

| event | when | result | reason |
|---|---|---|---|
| `scan` | `fleet login` (the browser / QR) | `ok` · `fail <exit>` | `valid_before …` or why it stopped · `tls: python <path> · CA 来源：…` |
| `renew` | every renewal by the device key (the keeper's, `fleet`'s) | `ok` · `scan` (must scan again) · `fail` | the last two things it said · `tls: …` |

The `tls:` part is `fleet_tls.describe()` (#2878): which python, which CA
sources it verifies the hub with.

## Redaction — `conf/secret-shapes.list`

The ONE table of what a credential looks like (EPIC #2889 共同约定 1): one
shape per line, `<name><TAB><POSIX ERE>`, applied top to bottom; a match becomes
`<redacted:<name>>`. Two writers read it, and are held to each other byte for
byte by `bin/client-log-selftest.sh`:

- `bin/fleet_clientlog.py` — Python (`fleet-connect.py`, `fleet-login.py`,
  `fleet-client-place.sh`'s hub half)
- `fleet_clientlog` in `bin/fleet-client-lib.sh` — POSIX sh + awk (the keeper,
  `fleet-client-place.sh`'s no-hub half)

So a shape must mean the same to Python's `re` and to BSD / GNU awk: no
backslash, no `{m,n}`, no `(?i)` (case goes in brackets), no lookaround or lazy
quantifier, no `[[:class:]]`, and an alternation only where one branch at most
can match at a spot. The selftest checks every line for these and carries a
sample per shape that must be redacted. Adding a shape = a line in the table +
a sample in the selftest; C1's bundle redactor reads the same table.

What is kept on purpose: host names, logins, ports, paths (diagnosis needs
them); a private key's path, never its content.
