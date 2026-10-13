# Admin handbook

This handbook is for two kinds of admin:

- **Admins of a self-hosting team**: the hub and the machines are your own; accounts, subscriptions and machines are all yours to manage.
- **Admins of a hosted customer**: we run the hub and the machines; you manage people, subscriptions and quota, and we look after the machines.

Every page is written in two columns, "self-hosted" and "hosted"; a step that applies to only one says so.

| Page | What it covers |
|---|---|
| [Creating and removing accounts](accounts.md) | Inviting a person, creating their account on a machine, what removing an account leaves behind |
| [Subscriptions and quota](quota.md) | Using the subscription we provide or connecting your own; per-person limits; seeing who used how much |
| [Machines](machines.md) | Adding a machine; what happens in maintenance, when one is taken offline or is lost |
| [Who can see what](access.md) | What admins and members each see; what an admin can and cannot do |

## What you do yourself, and what you ask us for

| Task | Self-hosted | Hosted |
|---|---|---|
| Invite members, remove accounts | You | You |
| Add, pause, remove subscriptions | You | You (we add the ones we provide) |
| Per-person quota | You | You |
| See usage, read the audit | You | You |
| Add machines, maintenance, taking one offline | You | Us |
| Who is an admin | You, in the hub's deployment configuration | Us, written into the deployment configuration from the list you gave when the hub was opened |
| Hub upgrades and backups | You | Us |

No step in the hosted column needs root or signing in to a machine; the few things that do are in the "Us" column.

## Where an admin works from

**The web console**: open `https://hub.example.com/app` in a browser and sign in as an admin. The sidebar has an extra **Admin** group: All sessions · Usage by person · Subscription pool · Service nodes & clients · Users · Settings · Audit. A member who opens these pages sees only "page not found" (404), exactly as for an address that does not exist.

**The command line**: `fleet hub …` and `fleet users …`, there once the client is installed (`curl -fsSL https://hub.example.com/install | sh`). They need an admin credential, read only from the environment and never written to a file:

- Self-hosted: the hub's operator token, `export CCQUOTA_VIEWER_TOKEN=…` (the one generated when you deployed the hub).
- Hosted: your session cookie after signing in to the hub in a browser. In the browser's developer tools → Application → Cookies → `ccq_sess`, copy its value, then `export FLEET_HUB_SESSION=<value>`. It stops working when you sign out.

> Coming: hosted admins will use their `fleet login` identity on the command line too, with no cookie to copy by hand.

## Who is an admin

There are only two roles: **admin** and **user** (member). Admins cannot be added or removed on the web; they are written only in the hub's deployment configuration:

- `CCQUOTA_GITHUB_ADMINS`: admins' GitHub usernames, separated by commas.
- `CCQUOTA_ADMINS`: admins who sign in with email or WeChat (an email address or an identity id).

A change takes effect once the hub is redeployed. On the **Users** page an admin's row is read-only and cannot be removed from the web.

## Before the first hosted customer

There are seven security gates before going public (the release signing key, root on the machines, credential lifetimes and so on). **Until all seven are green we open no hosted customer**; promoting it publicly needs at least gate 1 green.

- Self-hosted: run `fleet doctor` on any machine and read the `gate` rows: PASS / FAIL for each gate, with one line of reason.
- Hosted: ask us to show you the same reading before your hub is opened; you can also sign in and open `https://hub.example.com/v1/fleet/gate` in a browser to read it yourself.

What each of the seven is and why: [Security and isolation](../security.md).
