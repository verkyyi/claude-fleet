# Creating and removing accounts

A person needs two things to use fleet: **to be able to sign in to the hub** (to be on the **Users** list), and **an account of their own on a machine** (their sessions run in it, and their files and other people's cannot see each other). Creating an account gives them both; removing it takes both back.

## Creating an account: send an invite

The usual road — one invite does both: they sign in to the hub with it, the hub adds them to the list and at once creates their account on a machine.

**Web**: the console's **Users** page → **Invite command**, and send them the line it prints.

**Command line**:

```sh
fleet hub invite alice          # only the GitHub user alice can use it; with no name, anyone holding it can use it once
fleet hub invite --list         # every invite and its state: unused · used · expired · revoked
fleet hub invite --revoke <id>  # revoke one that has not been used
```

- An invite is valid for 7 days and can be used once.
- What they receive is one install line, `curl -fsSL https://hub.example.com/i/<invite-code> | sh`; they follow [Member · Quickstart](../member/quickstart.md).
- Which machine it is created on: the setting "New users get a login on" (`fleet.auto_assign`) — `least-busy` lets the hub pick the least busy one, or name a machine.
- With "Spare logins on every service node" (`fleet.spares`) on, each machine keeps a few empty accounts ready, and a newcomer gets one at their first sign-in with no wait; with it off, they wait for the machine to create the account, usually a minute or two.

**Do not forget to grant subscriptions**: a new user may use no subscription at all by default. Once they have signed in: **Users** page → choose them → subscription access, and pick "All subscriptions" or tick a few ([Subscriptions and quota](quota.md)).

**Self-hosted**: all of the above; the machines also need room ([Machines](machines.md)).
**Hosted**: all of the above; we make sure the machines have room. Their row on the **Users** page shows the account's state; if it takes too long to be created, send us that row.

### Let them sign in, without an account

**Users** page → **Add user**, and fill in a GitHub username; or `fleet users add alice`. They can sign in to the hub and see the console, but the first time they open a session they see "ask the hub's admin to give you a machine" until you create their account.

### Create an account on a given machine for someone already registered (self-hosted)

```sh
fleet hub accounts                                   # each person's identity id (gh:<number>) and their accounts on each machine
fleet hub accounts assign gh:1234567 --host mac-a    # create one for them on mac-a
```

A person can have one account on each of several machines. A hosted customer who wants a second machine's account for someone asks us.

## Removing an account

Removing is also two steps: **stop them signing in**, and **take back their account on the machine**.

### 1. Stop them signing in

**Web**: **Users** page → choose them → **Remove user**.
**Command line**: `fleet users remove alice`.

It takes effect at once: their next request is refused, and every client of theirs (computers, phones) is revoked. But **sessions they are running carry on until they close** — to stop them now, do step 2. An admin written in the deployment configuration cannot be removed (take them out of the configuration and redeploy first).

### 2. Take back their account on the machine

```sh
fleet hub accounts remove gh:1234567 --host mac-a
```

Once per machine (`fleet hub accounts` shows which machines they have an account on).

> Today this step is command line only; **Remove user** on the web does not do it. Coming: taking it back straight from the **Users** page.

Taking it back, the machine first stops all their sessions and background services, then does one of two things:

- **Recycle** (the default with "Spare logins on every service node" on): the account is wiped into a fresh empty account that the next newcomer gets. It is handed out again only once checked clean and with its credentials separated; one that is not clean is marked broken and never given to anyone.
- **Delete** (with spare logins off, or with `--delete`): the system account on the machine is deleted.

**Hosted**: the same command, run by you; the machine-side work is done by our machines themselves — no need to ask us.

## What removing an account leaves behind

| What stays | Where | For how long |
|---|---|---|
| An archive of their home directory (code copies, session transcripts, history) | On that machine: `/Users/Shared/offboarded/` on a Mac, `/home/.attic/` on Linux | Deleted after 30 days on Linux; on a Mac it is not deleted automatically — an admin clears it by hand |
| Their identity record on the hub | The hub | Kept for good; invited back, they are the same person |
| The usage they ran up | The hub | Kept for good; it still counts in Usage by person |
| Audit records | The hub | The audit page shows the last 60 days |
| Branches and PRs already pushed to GitHub | GitHub | Not affected |

Both recycling and deleting take away the machine's copy of the shared subscription **before** archiving the home directory, so the archive holds no subscription credential. On the hub side, their connection tokens, the claims they held and unused join codes are revoked before the account is taken back.

**Self-hosted**: to destroy the archive for good, delete its file on that machine (needs root).
**Hosted**: the archive is on our machine; to have it destroyed early, tell us whose.

## Common cases

- **An invite went to the wrong person**: find it with `fleet hub invite --list`, then `--revoke <id>`. If it was already used, remove the account as above.
- **They changed GitHub accounts**: `fleet hub accounts rekey <old id> <new id>` hands the old identity's accounts over to the new one whole; nothing is reopened.
- **Creating the account got stuck, and the list has a row that never got created**: `fleet hub accounts forget gh:1234567` deletes that record (which never reached a machine); then invite them again.
- **The machine was gone before the removal reached it, and the row stays `remove_pending`**: first make sure the machine really is not coming back, then `fleet hub accounts forget gh:1234567 --host <machine> --machine-gone`. It marks the row `removed` and writes "home directory not archived on the source machine" into the record and the audit — their home directory on that machine was not archived; to keep it, look on the old disk. While the machine is still connected it is refused: then the removal lands by itself.
- **They left and came back**: send a new invite; the identity is the same, their usage history joins up, and the machine gives them a new account.
