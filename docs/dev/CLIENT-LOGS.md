# The client's own logs

> Issue #2896 (EPIC #2889 C7). A computer that runs the `fleet` client writes
> down, on its own disk, every connection it makes, every session it asks a
> machine to open, every renewal its keeper makes and every login — where it
> went, by which road, how long, who ended it and why. When a colleague is
> «stuck at 正在连接», the answer is read here instead of asking them to run it
> again with `-v` and send a screenshot.

This page is the contract. C1's bundle (retired with #4904) took its
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
the historical client cache) + `/logs`, created 0700; each file 0600.

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
| `pick` (route column `direct`) | a reconnect's remembered line had a better class of line beside it and that one answered — a same-network LAN line (#3074), or the tailnet under `FLEET_CONNECT_PREFER_TAILNET=1` (#2987) | `ok` | `<name> over remembered <name>` · `tailnet <name> over remembered <name>` |
| `ssh-start` | ssh is started | — | `<route name> <host>:<port> login=<login>` |
| `ssh-end` | ssh ended | `exit N` · `signal N` | `ssh ended normally` · `ssh: connection failed or was cut (255)` · `the remote command's exit` (+ `this side got signal N` when the client was signalled) |
| `relay-open` | a relay's handshake (ssh's ProxyCommand) | `ok` (ms = handshake) · `fail` | the hub URL · the refusal |
| `relay-end` | the relay's stream ended (ms = ready → the first end) | **who ended it**: `hub` · `client` · `net` | `ws close <code>: <reason>` (hub) · `ssh closed the stream (stdin EOF)` (client) · `the hub's socket closed with no close frame` (net) |

A slow switch reads off `switch` lines: one that is not `chan` / `select` names
why it was not. The ranking (`pick`, #3074, EPIC #3067 共同约定 8) takes the
routes that answered the most handshakes, then by class — `lan` (the machine's
own private addresses) < `entry` < `tailnet` < any other direct line < `relay` —
then by latency. A `lan` route is only measured when one of this computer's
interfaces is on its network (`skip 不在这台机器的局域网` otherwise), the tailnet
only when this computer has a Tailscale address (`skip 这台电脑没有 Tailscale`).
The remembered route is filed by network (default gateway + its network: the
`; net=<key>` at the end of a `pick` reason), so the line picked at home is not
the first one tried elsewhere. `FLEET_CONNECT_PREFER_TAILNET=0` ranks by latency
alone.

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
file the thin client writes; rotated and redacted as the others. Its own
eleven fields, only ever added at the end (a line with nothing in the last one
stops at ten):

    time  event  home  route  pick_ms  ssh_ms  first_ms  rc  reason  net  end

| event | when | fields |
|---|---|---|
| `connect` | each connection, when it ends | `pick_ms` = `fleet-connect.py --argv` (certificate · machine · route); `ssh_ms` = ssh spawned → the first byte back (handshake + the far end starting); `first_ms` = spawned → the home's first valid `cur` (the view drawn); `rc` = ssh's exit; reason `up` · `never up` · `quit`; `net` = `net=<default gateway>@<its network>` — the network this computer was on when the route was picked (#3074; empty under `FLEET_CONNECT_PREFER_TAILNET`); `end` = `end=<word>` on a connection whose ssh did not exit 0 — what ssh printed last (#4828): `timeout` (its keepalive gave up — `Timeout, server … not responding`) · `reset` · `broken-pipe` · `closed-remote` (the far end closed it) · `closed` · `unreachable` · `refused` · `connect-timeout` · `netchange` (the network changed under it, D4NW); empty when it said none of them |
| `drawn` | the moment a connection first draws the view (its first valid `cur`) — while it is up, where `connect` comes only at its end (#3155) | `home` · `route`; `ssh_ms`, `first_ms` as on `connect` |
| `rehome` | three connections in a row never came up — a new home asked for (`--avoid`), or the machine named changed; or the `--avoid` found no other machine and the loop went back to its home (#4829) | reason: from / other than which / `no other home: back to <home>` |
| `back` | (T690) between a drop and the next view, the line watch saw the line come back (no answer → an answer): the backoff, a pick or an ssh started on the dead network is cut short and the loop reconnects at once | reason: `the line came back: reconnecting now` · `cut short: asking again` (a pick) · `… cutting the ssh` · `a key on the page: …` · `the network changed: …` (D4NW); pick_ms / ssh_ms how long the cut one had run |
| `net` | (D4NW) the network changed (the address the default route leaves from), or a live view's line went with the old one and was ended | reason: `the network changed: <class> -> <class>` (lan · hotspot · other · none) · `the line went with the old network: ending it` |
| `shell` | (EPIC T651 C4, D4NW) the 看台 broke three times in a row: offered on the reconnect page; s opened the home's command line; it ended | reason: `offered: <why>` · `<why>` · `the shell ended: the 看台 again` |
| `first` | the home had no fleet session of yours (rc 3) or the hub is opening your first login — the first-session road (#3054): a start line, then rc 0 + the place line (opened there) or rc 1 + why it did not open | `home` (the machine it opened on, once placed); reason |
| `offline` | three connections failed and the hub did not answer either — this computer's own line is down, so no 换家: the home and the view are kept (#3007) | `home`; reason |
| `upload` | a drop or a ⌃V picture sent through the home | `ssh_ms` = the one-shot's time; reason `<name> → <path there>` |
| `show` | a file a session sent (OSC 7502 `show`, issue #3541): fetched over one ssh into `~/Downloads` | `rc` 0 saved · 1 not; reason = why not |
| `exec` | a new client version between two connections | reason `<old> → <new>` |
| `say` | a word for the person (a file not sent) — also an OSC 9 notification | the words |
| `quit` / `end` | ⌘Q or a detach / a signal | `rc` |
| `run` | `fleet-thin.py --run`: one command on the home over a one-shot ssh — `fleet ls / open / close / answer`, `fleet claude` with no client tmux (issue #3004) | `home` · `route`; reason = the command's first word |

### place.log — `bin/fleet-client-place.sh`

| event | `issue-N` · `scratch` · `home` · `new` · `restore:<key>` |
|---|---|
| machine | the machine that answered (`REMOTE`/`RESUME`/`HELD`/`DECLINED`/`UNKNOWN`/`LOCAL` name one), else the one asked for (`auto`) |
| route | `-` |
| ms | from the ask to the answer |
| result | the answer's first word and the exit: `REMOTE 0` · `REFUSED 4` · `DECLINED 5` · `error 1` · `NOHUB 1` … |
| reason | `repo=<repo>` · the answer after its tab (the hub's `No machine can take…` with each machine's reason, as it said it) · everything said on stderr (machines that declined, why this computer was not chosen) |

### login.log — `bin/fleet-login.py`

| event | when | result | reason |
|---|---|---|---|
| `scan` | `fleet login` (the browser / QR) | `ok` · `fail <exit>` | `valid_before …` or why it stopped · `tls: python <path> · CA 来源：…` |
| `renew` | every renewal by the device key (`fleet` or ssh use) | `ok` · `scan` (must scan again) · `fail` | the last two things it said · `tls: …` |

The `tls:` part is `fleet_tls.describe()` (#2878): which python, which CA
sources it verifies the hub with.

## Reading them — `bin/fleet-client-stats.py`

The ONE ruler for the client's three stability readings (issue #4824, EPIC
#4823 共同约定 7 — before, after and the batch report all read them this way):

    bin/fleet-client-stats.py [--json] [--days N] [--now ISO] <dir>…

Each `<dir>` is one computer: its cache (`~/.cache/claude-fleet`), a copied
set (`logs/thin.log` + `logs/*.log`) or a bare log dir; `.1` is read first.

| reading | from |
|---|---|
| drops / computer / day | `thin.log` `connect` with reason `up` whose next lifecycle line is not `quit` / `end`, over the UTC days that computer's thin client logged anything; broken down by route and by `end=` (`-` on a line written before #4828) |
| reconnect (median / p90) | a drop's line → the next `drawn`, whole seconds; also without the gaps that had an `offline` inside (this computer's own line down); a drop with no `drawn` before the client ended is `unrecovered` |
| open failures | per start (the first lifecycle line after `quit` / `end`, or a second `drawn` with no end to the first — a process that went silently): its first `connect` not up (pick rc 1, `never up` but rc 3 — the first-session road), or a `first` rc 1; beside it the starts that never drew, connect.log `home` failures by code, place.log asks and non-zero exits |

`bin/fleet-client-stats-selftest.sh` pins the three on synthetic logs.

## Sent to the hub — `bin/fleet_client_events.py` (T689)

thin.log stays on this computer; the part of it the hub and the doctor need
goes there as **connection events**, metadata only (稳定性①):

| event | when | fields beyond `id` · `at` · `start` · `ver` |
|---|---|---|
| `start` | a `fleet` start (its id rides every later event) | — |
| `up` | the view drawn | `phase` start (`ms` from the start) · reconnect (`ms` = drop → drawn: the reconnect time; after a network change `reason` net and `ms` from the change — D4NW) · `home` · `route` |
| `drop` | the line ended while up, not by the person | `home` · `route` · `rc` · `ms` (how long it was up) · `reason` = ssh's last word (`timeout` · `reset` · …) else `rc<N>` |
| `fail` | a connection that did not come up | `phase` start (起不来) · reconnect; `reason` = `home:<the hub's code>` (connect.log's `home` line) · `pick` · `opening` · `no_fleet` · `first_session` · `never_up` · ssh's word; `rc` |
| `rehome` | the home changed | `home` → `to`; `reason` `no_other` when the 换家 found no other and went back |
| `offline` | three tries failed and the hub did not answer either | `home` |
| `net` | (D4NW) this computer's network changed | `home` · `reason` lan · hotspot · other · none (never an address) |
| `quit` | the person (or a signal) ended it | `rc` · `reason` quit · detach · signal · interrupt · key (q on the reconnect page) |

Every field is a code (`[a-z0-9_.:-]`, ≤ 48), a machine name or a number — the
writer codes or drops anything else, and the hub (`POST /v1/fleet/client-events`,
`hub/api/fleet_client_events.go`) refuses an event that is not, one by one. No
credential, no person's words, no terminal byte has a field to travel in.

The spool is `${XDG_CACHE_HOME:-~/.cache}/claude-fleet/client-events.ndjson`
(0600, at most `FLEET_CLIENT_EVENTS_MAX` = 2000 — the oldest go). Each event is
appended and the spool is sent on a daemon thread (one sender: a flock; batches
of `FLEET_CLIENT_EVENTS_BATCH` = 200), signed with the connection certificate
(`fleet-client-events@claude-fleet` over `fleet-client-events <ts>`) or a
`FLEET_HUB_TOKEN`; an event leaves the spool only once the hub answered for it,
so a line that is down keeps them for the next event or the next start. The hub
keeps one row per id (a resend is a duplicate), 30 days, under the device name
it registered for the certificate's key. `FLEET_CLIENT_EVENTS=0` records and
sends nothing; `fleet_client_events.py status` / `flush` read and send by hand.

The read is the doctor's: `GET /v1/fleet/client-events?hours=24` (a session, a
viewer token, a login's node token — each person their own clients, the
operator everyone's; `&device=` · `&events=1` for the rows) answers drops and
their reasons, reconnect p50 / p90 (nearest rank), open failures (attempts, and
the starts that never came up) and their reasons, 换家, offline — per device ×
home, per device and in total. `fleet doctor`'s `clients` row is the one-line
summary (WARN on a start that never came up or a reconnect p90 past a minute);
`fleet doctor --clients [--hours N] [--device D] [--json]` (`bin/fleet-client-events.sh`)
is the table. `bin/fleet-client-events-selftest.sh` and `fleet-thin-selftest.sh` T
pin the client half, `TestFleetClientEventsByCertificate` the hub's.

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
