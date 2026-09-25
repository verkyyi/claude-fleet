# Shared machine: one OS login per person

A runbook for putting several people on one always-on machine (a Mac mini in
a closet, a build box) so that each person gets **their own fleet** and **their
own quota record**. Issue #609; the reasoning is
[OSS-PACKAGING-PLAN.md, chapter 10](OSS-PACKAGING-PLAN.md#十共享-mini-的正确形态).

**The rule: N people = N OS logins.** Never N people behind one login.

| What you get from a separate login | Why it matters |
|---|---|
| Its own `~/.claude` — credentials, transcripts, settings | Usage is attributed to the person who spent it. Behind a shared login, ccquota sees one person, and per-person budgets or breakers have nothing to act on. |
| Its own `/tmp/tmux-<uid>/` (mode `0700`) | Each person's fleet server sits on a socket the others can't list or attach to. A stray `kill-server`, an OOM or a runaway takes down one person's fleet, not everyone's. |
| Its own Keychain, LaunchAgents and `~/.claude/fleet` | One fleet per login (EPIC #977). Every repo a person works on lives in that one fleet. Nobody switches fleets. |
| Its own ccquota agent | ccquota needs one agent per login. It reads that login's transcripts and credentials, which on most systems it couldn't read for another user anyway. |

Everything below uses placeholder names. Replace them:

| Placeholder | Meaning |
|---|---|
| `alice` | the new person's short login name |
| `mini` | a short name for this machine |
| `hub.example.com` | your ccquota (TokenLedger) hub |

Repeat steps 1–5 for each person. Step 6 checks the whole machine.

---

## 1. Create the OS login (admin, on the machine)

One command does the admin half of steps 1 and 2b (issue #1164). Run it as your
own admin login — **not** under `sudo`; it sudo's each step itself — from any
directory: a relative `--pubkey` is resolved where you typed it, and the steps
run from `/`, so the new login (which cannot see into your `0700` home) never
inherits your cwd (issue #1216):

```sh
~/.claude/fleet/bin/fleet-login-new.sh alice --full-name "Alice Example" \
  --pubkey alice.pub --share-pool          # a dry run: prints every command, runs none
~/.claude/fleet/bin/fleet-login-new.sh alice --full-name "Alice Example" \
  --pubkey alice.pub --share-pool --apply  # the same plan, executed — no prompt, works over ssh
~/.claude/fleet/bin/fleet-login-new.sh alice --full-name "Alice Example" \
  --share-pool --apply                     # no key from alice yet: a temporary pair, carried by her welcome letter
```

In order, it runs `sysadminctl -addUser` (no `-admin`: a fleet doesn't need it)
with a **random password it writes to `~/alice-onboard/password.txt`** in your
own home (mode 600, printed as a path, never as text — alice signs in with her
key; `--password-file <f>` uses f's first line instead, issue #1192),
`createhomedir`, adds the login to `com.apple.access_ssh` (only when that group
exists — without it Remote Login admits every user), installs `--pubkey` as
`~alice/.ssh/authorized_keys` (`.ssh` 700, key 600, owned by alice), and with
`--share-pool` copies the Claude pool as step 2b below describes. Then it
**clones claude-fleet at `stable` into `~alice/.claude/fleet` as alice** and
**installs her 14 background services as system LaunchDaemons** —
`/Library/LaunchDaemons/com.claude-fleet.alice.<unit>.plist`, `UserName alice`,
rendered from that clone by `fleet-install-apply.sh --render-system` and
`launchctl bootstrap system`'d — the shape every guest login on a shared mini
runs. Her home is 700, so the templates are read out of the clone **as alice**
(`sudo -u alice -H cat`, issue #1213) and rendered in the admin's temp dir; the
step ends `installed 14/14`, and a clone with no templates fails the run (exit
1) instead of installing nothing. It stops at the first failed step, refuses (exit 3) when the login or
`/Users/alice` already exists, never overwrites, and writes nothing in alice's
home outside `.ssh/`, `.config/claude-fleet/accounts/`, `.zshrc` and
`.claude/fleet/`. That `.zshrc` is the `~/.local/bin` PATH line (where Claude
Code installs, issue #1191) followed by the claude-fleet block (issue #1165):
alice's first terminal login installs Claude Code and finishes the claude-fleet
install by itself — step 5 below. It ends by printing the steps left for a
human — the ones below that it can't do.

**It also writes alice's welcome letter** (issue #1195):
`~/alice-onboard/welcome.txt` in your own home, mode 600 — how to connect
(`ssh -p <port> alice@<host>`), an ssh-config snippet, how to swap in her own
key, what the guide and `cf` do, and what is still hers (the Codex device code,
`gh auth login`); never the password. Leave `--pubkey` out and it generates a
**temporary** ed25519 pair into the same dir, installs the public half and puts
the private half in the letter, so alice can connect before she ever sent you a
key and swaps it for her own on first login (the letter says how). The host and
port are `FLEET_SSH_PUBLIC_HOST` / `FLEET_SSH_PUBLIC_PORT`, machine-wide
(`prefix+c` → 身份/identity, or two lines in
`~/.config/claude-fleet/fleet.settings`) — unset, the letter carries a visible
`<HOST>` placeholder and the run warns. `--lang en` for an English letter
(default Chinese); `--no-welcome` skips it (then `--pubkey` is required). You
send the letter; the script mails nothing and never prints the key.

**No GUI sign-in is needed** (issue #1192): the daemons are system
LaunchDaemons, so alice's first `ssh alice@mini` lands in a working fleet. The
one exception is `--no-daemons`, for someone who will use the console: their
first graphical login creates the `gui/<uid>` launchd domain, and the bootstrap
installs gui LaunchAgents into it the historic way. A GUI sign-in is also what
creates alice's login Keychain — only needed if she brings her own subscription
in step 2 (a `--share-pool` login reads token files, not the Keychain) or runs
the per-user ccquota agent of step 4.

## 2. First Claude Code login, as that person

In a shell running as `alice` (their own GUI Terminal, or `ssh alice@mini`):

```sh
claude          # complete the /login flow (their own subscription, or a pool account — see 2b)
```

This writes `~alice/.claude/` and stores the OAuth credential in **alice's**
Keychain. Don't copy another login's `~/.claude` directory over: it carries that
login's transcripts, settings and hook state, which is the shared-identity
problem this runbook exists to fix. If the person also uses Codex, run
`codex login` here too.

## 2b. (Optional) Join the machine's shared account pool

A login can bring its own subscription (step 2), or draw from the same
subscription pool the operator's login uses. Both are supported; which
subscriptions a machine's logins share is the operator's decision, and the
tooling neither requires nor refuses either setup. Sharing the pool still keeps
one login per person, so usage stays attributed per login on the hub.

**Claude pool** — the tokens are plain `claude setup-token` files, so copy them.
`fleet-login-new.sh --share-pool` (step 1) does exactly this: every `<label>`
token and its `<label>.conf` (`CCQUOTA_ACCOUNT`) from your accounts dir
(`--pool-src` to pick another), dir 700 / files 600, owned by the new login. For
an existing login, by hand (admin, since the source files are `600` in the
operator's home):

```sh
src=/Users/operator/.config/claude-fleet/accounts
dst=/Users/alice/.config/claude-fleet/accounts
sudo mkdir -p "$dst"
sudo cp "$src"/* "$dst"/                 # each <label> token + its <label>.conf (CCQUOTA_ACCOUNT)
sudo chown -R alice:staff /Users/alice/.config/claude-fleet
sudo chmod 700 "$dst"; sudo chmod 600 "$dst"/*
```

Then, as `alice`, `~/.claude/fleet/bin/fleet-account.sh list` shows the pool.
Each login keeps its own copy, so a token added to or revoked from the pool
later has to be copied to every sharing login again. Rotation state
(`account.limited`) is per login: a limit one login hits is learned by the
others from their own banners or from the ccquota hub.

**Codex** — do **not** copy `~/.codex/auth.json`. Codex rotates its refresh
token on use, so two homes holding one copy race each other and one gets logged
out. Give the login its own session on the same account instead, as `alice`:

```sh
ccquota codex login personal --device-auth   # approve the device code while signed in to the shared ChatGPT account
ccquota codex list                            # LOGIN valid
```

## 3. Enroll the login with the hub (admin, on the hub)

One enrollment per login. Name it `<machine>-<login>` so the hub's endpoint
list reads as "who, on which box":

```sh
ccquota enroll --name mini-alice        # prints a one-time enrollment token
```

Give the token to `alice` over a private channel. It is a credential.

## 4. Run the ccquota agent as that person (LaunchAgent)

`ccquota` isn't a brew formula. See [INSTALL.md step 6](INSTALL.md#install-steps)
for `go install github.com/verkyyi/ccquota/cmd/ccquota@latest`. As `alice`:

```sh
mkdir -p ~/.ccquota/agent
ccquota agent --install --hub https://hub.example.com --state ~/.ccquota/agent \
  > ~/Library/LaunchAgents/com.ccquota.agent.plist
# edit the plist: replace REPLACE_WITH_TOKEN (CCQUOTA_TOKEN) with the token from step 3
chmod 600 ~/Library/LaunchAgents/com.ccquota.agent.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ccquota.agent.plist
```

It **must be a per-user LaunchAgent**, not a root LaunchDaemon, and not a
single agent passed several `--home` values. The agent needs to run as
`alice` to open alice's Keychain, where Claude Code keeps that credential. A
root daemon or someone else's agent can count tokens, but it can't read
account limits. `--home` defaults to the user running the agent, so a
per-user agent needs no `--home` flag. The equivalent explicit form is
`ccquota agent --home /Users/alice --state /Users/alice/.ccquota/agent`.

> **Symptom to know:** if the hub shows this endpoint with
> `limits_unavailable`, the agent is running but can't read a Claude OAuth
> credential. Check that step 2 ran as *this* login and that the agent
> runs in this login's `gui/<uid>` domain (the Keychain belongs to it).
> Usage attribution still works in this state. Only the live limit readings
> are missing.

## 5. Install claude-fleet for that person

**A login opened with `fleet-login-new.sh` (step 1) needs nothing here** (issue
#1165). Its `~/.zshrc` carries a one-time block: on alice's first interactive
login (`ssh alice@mini` is enough — no GUI sign-in, issue #1192)
`bin/fleet-login-bootstrap.sh` finds the clone step 1 made in `~/.claude/fleet`
(and makes one at `refs/tags/stable` if it is missing), installs Claude Code
when she has none (`~/.local/bin/claude`, the official native installer, run as
her — issue #1191), runs
`fleet-install-apply.sh` from an empty tree (every hook, command and skill;
the system LaunchDaemons step 1 installed come out "already current", so
nothing there needs root), hooks up tmux, and brings her fleet up on the
starter repo — `fleet-up.sh verkyyi/claude-fleet --seed`, which only looks
(override with `FLEET_SEED_REPO`) — then prints `fleet-doctor.sh`. A step that
fails (offline; or, for a `--no-daemons` login, no GUI session yet) is retried
on her next login, alone; once all pass it writes
`~/.config/claude-fleet/global/bootstrapped` and never runs again.
It leaves a login that already has a fleet untouched. She adds her own repos with
`fleet-up.sh owner/repo`, and once one is in, takes the starter out with
`fleet-repo.sh remove verkyyi/claude-fleet` (issue #1172 — the wizard offers it
right after the add). Still hers to do: `gh auth login` and the Codex device
code (step 2b); still the hub admin's: `ccquota enroll` (step 3).

For a login made by hand, as `alice`, follow [INSTALL.md](INSTALL.md) from the top. Nothing in it is
per-machine: the live install (`~/.claude/fleet`), the conf dir, the hooks in
`~/.claude/settings.json`, and the LaunchAgents (step 6 of INSTALL) all live
in that home directory. Set `CCQUOTA_HUB_URL=https://hub.example.com` in that
fleet conf so quota rotation reads that login's own record. Then create the login's **one**
fleet. `fleet-up.sh` refuses to create a second fleet on a login
(issue #979). A second fleet needs a second login.

```sh
~/.claude/fleet/bin/fleet-up.sh owner/first-repo    # brings up this login's fleet
~/.claude/fleet/bin/fleet-up.sh owner/second-repo   # adds the repo to that same fleet
```

Each login's live install updates on its own schedule. After a
`git pull` + `/fleet-sync-install` on one login, the others are still behind.
`fleet-doctor.sh`'s `install` line shows this per login (see
INSTALL.md step 1).

---

## 6. Verify the machine

Run these once all logins are set up. Each check matches one acceptance item
of #609.

For a login with `~/.config/claude-fleet/global/bootstrapped`, run
`~/.claude/fleet/bin/fleet-doctor.sh | grep onboard` as that login. The single
`onboard` row names any missing Claude CLI, private nonempty pool tokens,
GitHub login, valid Codex login, SSH key, loaded fleet services, or live/completed
guide. A key whose comment contains `temporary` or `临时` gets a reminder to
replace it. Missing steps are WARNs and do not change the doctor's FAIL exit code.

**Each login has its own `~/.claude`.** As each user:

```sh
ls -ld ~/.claude && id -un        # owned by that user; no shared path, no symlink into another home
```

**Each login has one enrollment and one agent.** On the machine (admin):

```sh
ps -axo user=,command= | grep '[c]cquota agent'   # exactly one line per login, each under its own user
```

On the hub, every login appears as its own endpoint with `os_user` set:

```sh
curl -s -H "Authorization: Bearer $CCQUOTA_VIEWER_TOKEN" \
  https://hub.example.com/v1/endpoints | python3 -m json.tool | grep -E '"(name|os_user)"'
```

**Usage splits by person:**

```sh
curl -s -H "Authorization: Bearer $CCQUOTA_VIEWER_TOKEN" \
  'https://hub.example.com/v1/usage?group=user' | python3 -m json.tool
```

Expect one bucket per login. A single bucket covering several people means
someone is still sharing a login.

**Each fleet server is on its own socket and the others can't see it.** As
`alice`:

```sh
ls -ld /tmp/tmux-$(id -u)                       # drwx------ alice
ls /tmp/tmux-$(id -u bob) 2>&1               # Permission denied — bob's sockets are invisible
bash -c '. ~/.claude/fleet/bin/fleet-lib.sh; fleet_sockets' | wc -l   # 1 — one fleet for this login
```

On macOS, `/tmp` resolves to `/private/tmp`. tmux may use `$TMUX_TMPDIR` if a
login sets it. The rule is the same either way: the directory is per-uid and
`0700`.

---

## Offboarding a person

As the admin login, preview and then offboard the person:

```sh
~/.claude/fleet/bin/fleet-login-remove.sh alice
~/.claude/fleet/bin/fleet-login-remove.sh alice --apply
```

The command stops alice's fleet under her login, boots out and removes her
system LaunchDaemons and GUI LaunchAgents (including ccquota), removes the
copied Claude account pool, stops remaining processes, archives her home,
deletes her OS account, and takes her name out of every `com.apple.access_*`
service group. It refuses the current login and admin group members, and it
never passes `sysadminctl -keepHome` — on this macOS that option answers
`'-keepHome' options is not available on this system`, which is how the
default offboarding used to die (#1210 ⑤).

- **`--keep-home` (default):** her home is packed first as a `600` tar.gz owned
  by you under `/Users/Shared/offboarded/` (`--archive-dir <dir>`, or
  `FLEET_OFFBOARD_ARCHIVE_DIR`), and the login is then deleted home and all.
  The archive path is the last line of the output. The account pool is removed
  before the archive is taken, so the shared tokens are never inside it. A
  failed archive stops the run before the login is touched.
- **`--delete-home`:** no archive; the login and its home go outright.

After the account is gone, `dseditgroup -d` can no longer remove alice from
`com.apple.access_ssh` (`Record was not found`), so her name would stay in the
Remote Login allow-list forever; the command removes her name and GUID from
every `com.apple.access_*` group with `dscl . -delete` instead. Check with:

```sh
dscl . -read /Groups/com.apple.access_ssh GroupMembership
```
The hub has no endpoint deletion command: once the ccquota agent stops,
`mini-alice` goes stale and stops reporting. Past usage stays under its
`os_user`.
