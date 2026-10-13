# Security and isolation

This page answers the two questions asked first when evaluating fleet — **can a session read the subscription credentials**, and **can anyone else get into my workspace** — and where the credentials are, how long each lives, and whom a compromise of each part affects.

Every statement carries a status: **live** is in today's stable; **planned** is decided and under way. One marked "gate N" is row N of the [seven security gates that must be met before going public](https://github.com/verkyyi/claude-fleet/blob/master/conf/public-gate.tsv); on a machine connected to a hub, `fleet doctor`'s `gate` rows read out PASS / FAIL for each. Until all seven are green we do not promote it publicly and take on no hosted customer.

## The short answers to the two questions

**Can a session read the subscription credentials? No.** (live · gate 7)
On a managed machine, the Claude Code and Codex subscription credentials sit under a dedicated role account (in a directory only it can read); the personal account a session runs in gets "Permission denied" if it tries. All a session holds is a **session pass**: with it, the machine's credential proxy speaks for it; it lives at most 4 hours and cannot get the subscription credential itself. Every managed login is separated this way.

**Can anyone else get into my workspace? The other members on the same machine cannot.** (live)
Each person is their own system account on the machine, with a home directory of mode `700`; sessions run in that account, so one person's sessions cannot read another's files, keys or sessions. The certificate that connects into your account is signed by the hub for your sign-in only; the entry port accepts only the keys the hub registered for you.
The exception, said plainly: **the machine's administrator (anyone with root or sudo) can see everything on that machine** — as on any shared server. So personal accounts on managed machines never have administrator rights, and every hosted customer has a hub of its own, shared with no one else.

## Three principles

1. **A personal account is only personal.** A personal account runs only its own person's sessions — never fleet's machine-wide or admin services.
2. **A service account does one thing.** What takes the hub's instructions, what holds the subscription credentials and what holds root are three different accounts; compromising any one gets only its one job.
3. **Root is only a very small core.** It is not on the network and takes no instruction from outside; it listens only to the machine's own node daemon, and accepts only a fixed table of actions; anything off the table is refused and logged.

## On a managed machine, who runs what

| Account | Runs | Rights | Status |
|---|---|---|---|
| Root core | Starts and stops a login's fleet processes as that login, ends runaway processes, memory protection, power settings, switches versions after re-checking the signature | Opens no port, reads nothing from the hub; accepts only the machine's node daemon and only the fixed action table | live · gate 2 |
| Node daemon | Health checks, disk patrol, reporting, connecting to the hub for session instructions, downloading and verifying new versions | No sudo; can only ask the root core for what is in its table | can be turned on per machine; planned until every machine has switched · gate 3 |
| Admin program | Account creation and removal sent by the hub | Runs only orders the hub signed, each usable once and expiring in ten minutes | "Only signed orders" is live; moving it into a dedicated admin account is planned · gate 4 |
| Credential proxy | Holds the subscription credentials and speaks for sessions | A separate role account, never merged with the account that takes outside instructions | live · gate 7 |
| Each person's account | Only that person's own sessions | No administrator rights, no sudo (`fleet doctor`'s `tenants` row turns red on any) | live |

In the cloud (the cluster the hub runs in) the same rules hold: each service its own service account with only the rights it needs, and no cluster token mounted in users' pods — **planned · gate 5**.

## Credentials: where they are, whether a session can read them, how long they live

A session runs the agent and also third-party code it pulls in (npm packages, MCP servers, scripts in a repository). Whatever a session can read can be carried off the machine. We cannot stop every such leak, but we can make whatever leaks expire soon, so the rule is: **anything a session can read is short-lived; only what it cannot read lives long.**

| Credential | Held by | Can a session read it? | Lifetime | How it is revoked | Status |
|---|---|---|---|---|---|
| Subscription credential | The credential proxy / the hub's credential store | No | Set upstream | The hub swaps the account; revoked upstream | live · gate 7 |
| Session pass | The session's environment | Yes | At most 4 hours, renewed only when less than 20% is left at use | Revocation list, effective at once | live · gate 7 |
| Relay pass | The login (under the role account in a separated login) | Not in a separated login | 4 hours (when the hub has a relay signing key configured; a hub without one issues the old non-expiring pass, and gate 7 reads red) | Revocation list, effective at once | live · gate 7 |
| Machine identity, a login's node token | The node daemon / the role account | No | Long-lived; presented as a signature with its own key, never a string that could be copied | The hub revokes the whole machine or that login | live |
| Connection certificate (for a person connecting in) | The person's own computer | Not by sessions on managed machines | 12 hours, renewed automatically; 5 minutes between machines | Revocation list | live; "renew only when less than 20% is left before connecting" is planned |
| Hub web sign-in | The person's browser | No | 7 days | The hub revokes all of a person's at once | live; shortening to 24 hours with a sliding renewal on use is planned |
| Release signing private key | In the hub today | No | Long-lived, rotated yearly | A revocation signed with the offline root key | moving it into the release pipeline and adding an offline root key is planned · gate 1 |

**Revocation takes effect at once, even with the hub away.** (live · gate 6) The hub pushes the revocation list to the relay and to every machine's entry port, which keep it locally and check only that local copy on every request; a revoked pass or certificate stops working at once even if it has not expired. If the hub goes down, the relay and the doors keep verifying against the list they hold, and short-lived credentials already issued keep working.

**Automatic updates accept only signatures.** (live) Every machine pulls only `stable` and verifies it with the public key it remembers; the final switch is re-checked by the root core itself — the signature and every file's digest.

## If one part is compromised, who is affected

| Compromised | Can get / can do | Cannot get / cannot do | Affects |
|---|---|---|---|
| A person's account or session | Their own home directory, keys, sessions; their own session pass (at most 4 hours) | Other people's home directories, subscription credentials, sudo, root | Only that person |
| The node daemon | See the whole machine's processes and disk; ask the root core to start or stop a login's processes per the table | Read anyone's home directory, get credentials, have root run anything off the table, install an unsigned version | The availability of everyone on that machine; no data touched |
| The admin program | Hold up or refuse account creation and removal on that machine | Create or remove any account without an order the hub signed | The people on that machine waiting for an account to be created or removed |
| The credential proxy | The few subscription accounts it holds | Anyone's home directory or keys, root | People using those subscriptions (their quota used by someone else); the hub swapping the accounts stops it |
| The root core | Everything on that machine | — | Everyone on that machine — which is why it is off the network, minimal, and accepts only a fixed table |
| The release signing private key | The equivalent of root on every machine | — | Everyone — which is why it is moving out of the hub and into the release pipeline only (gate 1, planned) |

## What the hub records, and who can see it

The hub records one line for every important action: who (a person, a machine or a session), when, what, and the result — creating and removing accounts, issuing and revoking credentials, machines joining and leaving, settings changes, sessions being dispatched. Only that hub's admins can see it, on the console's Audit page. Every hosted customer's hub is its own, and its records are never mixed with another's.

Each machine's entry port also records every entry: which login, from where, with which key.

## What the web chat tells the model about your browser

When you talk to your conversation at the site's `/chat`, the model is told what you are using right now: the kind of device (phone / tablet / computer), its system, the browser, the page language, how wide the screen is, your local time and time zone, and the rough city your IP address is in (the city only) — one line at the start of the conversation, and another only when the device, the city or the day changes. The full IP address, browser identifier and network type are given only when the model asks for them with its `browser_context` tool, and only within your own conversation.

The address and the city are what the hub saw, worked out from an offline database on the hub — no outside service is asked. None of it is written to a log; it stays in your own conversation's record.

## Reporting a security problem

Please do not open a public issue. Use only GitHub's private vulnerability reporting: the repository page → Security → [Report a vulnerability](https://github.com/verkyyi/claude-fleet/security/advisories/new); there is no email address. Response times and supported versions are in [SECURITY.md](https://github.com/verkyyi/claude-fleet/blob/master/SECURITY.md) at the repository root.
