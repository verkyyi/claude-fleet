# Who can see what

## Two roles

| | Member (user) | Admin |
|---|---|---|
| Their own sessions, tasks, usage, clients | Sees and manages | Sees and manages |
| Other people's sessions | Cannot see | Sees the list ("All sessions"), not the content |
| Subscription pool, subscription access | Cannot see; sees only their own personal limit | Adds, pauses, removes, grants |
| Per-person quota | Sees only their own | Sees everyone's and sets it |
| Users list, invites | — | Adds, removes, sends invites |
| Machines, join codes, maintenance | Sees only the ones they have an account on | All |
| Settings, audit | — | All |

A member who opens an admin page (including any address under `/admin` and old bookmarks) sees exactly what an address that does not exist shows — "page not found" (404) — and the attempt is recorded in the audit. On the everyday pages (Overview, Sessions, My usage) an admin, like a member, sees only their own; everyone's is in the **Admin** group.

## What an admin can and cannot see

**Can see** (All sessions, Usage by person): whose each session is, which machine it is on, which subscription it uses, its state, how many tokens it used, and which task it is doing.

**Cannot see**: what was said in a session or what code it changed. No page and no endpoint on the hub can read a session's content; session transcripts exist only in the member's own account on the machine, and the accounts on a machine cannot read one another.

**One thing to be clear about**: a machine's root (its system administrator) can technically read any account's files on that machine. When self-hosted, that is your own machine administrator; when hosted, it is us. The home directory archived when an account is removed is also on the machine ([Creating and removing accounts](accounts.md)).

## What an admin can and cannot do

Can:

- invite people, remove people, take back their account on a machine
- add subscriptions, decide who may use which subscription, set each person's limit
- see everyone's usage and session list, read the audit
- self-hosted: add machines, put one in maintenance, remove machines, change the hub's settings

Cannot:

- read anyone else's session content from the hub
- get a subscription's long-lived credential: once stored in the hub, neither the web nor the command line shows it to anyone again
- add or remove admins on the web: admins are written only in the hub's deployment configuration ([Admin handbook](index.md))
- hosted: sign in to the machines or change them (we do that)

## Audit

The console's **Admin → Audit**: who did what and when over the last 60 days — adding and removing people, sending invites, creating and removing accounts, adding subscriptions, changing access and quota, maintenance, changing settings, refused attempts to reach what one may not. Filter by subscription · service node · client · user · settings · session, or **Export CSV**.

## Members' clients

Each of a person's computers and phones is a "client". On the **Service nodes & clients** page, the "Clients" tab lists everyone's clients, and an admin can revoke any one of them (say a member lost their phone). A revoked client cannot connect from that moment; the member signs in again on it. Removing a user revokes all their clients at once.

How credentials are kept and how long they last: [Security and isolation](../security.md).
