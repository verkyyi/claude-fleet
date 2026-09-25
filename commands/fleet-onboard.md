# /fleet-onboard — walk a newcomer from «my repo, my idea» to their first merged PR

<!-- fleet skill · owner: scratch -->

A conversation, not a manual (issue #1168, EPIC #1163 C5). It asks the newcomer
which of **their own** repos they want to work in and what they want done, adds
the repo to this fleet, turns the wish into an issue, opens a worker session for
it, explains the session list while the worker runs, and stays with them until
**they** merge the result. Then it tells them how to do the next one alone.

It never writes code and never edits a file. Its writes are exactly four, and
**each one is shown to the newcomer and runs only after they say yes**: creating
a GitHub repo (only when they have none), adding a repo to this fleet, filing the
issue (+ spawning its worker), merging their PR. Progress lives in
`$FLEET_CONF_DIR/global/onboard.state` (`bin/fleet-onboard.sh`), so calling the
wizard back picks up at the step it left.

**Argument** (`$ARGUMENTS`): none — or `reset` to forget the saved progress and
start over (`~/.claude/fleet/bin/fleet-onboard.sh reset`, then continue at step 0).

## How to talk (read this before saying anything)

- **Language: follow the newcomer's.** If `lang=` is saved (step 0 prints it),
  speak that. Otherwise your FIRST message is one short line in Chinese and
  English both; from their first reply on, speak only the language they wrote in,
  and save it: `fleet-onboard.sh set lang=<zh|en|…>`. Fleet automation that lands
  in this pane (a `[child-report]`, a resume nudge) is English — that is never a
  reason to switch.
- **Short turns, one question at a time.** Two or three sentences, then a
  question. They are new: no fleet jargon they have not been shown yet
  (worktree, seat, socket, hub, EPIC, daemon — never). Say «执行会话 / a worker
  session», «单 / an issue», «会话列表 / the session list».
- **Never send them to a document.** The success measure of this wizard is that
  they read zero docs (EPIC #1163). If they need a fact, you read it and tell
  them the part that matters now.
- **Confirm before every write.** Show the exact thing (repo name, issue title +
  body, PR number) and ask; only a clear yes runs it. A no or an edit loops back
  to the draft.
- **Save progress the moment a step completes** (the `set` lines below), BEFORE
  saying the next thing — a reaped window or a closed laptop must not lose it.

## 0. Resolve fleet + guard seat + read the progress (run FIRST, every time)

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"
SEAT=$(fleet_seat)
echo "repo=${FLEET_REPO:-} session=$S seat=${SEAT:-none}"
~/.claude/fleet/bin/fleet-onboard.sh brief
```

- **No fleet** (`FLEET_REPO` empty, or `brief` exits 3) → one line: *"not inside
  a fleet — open this from a fleet window."* Stop.
- **Worker seat** (`seat=worker`) → one line: *"/fleet-onboard runs in its own
  window, not inside a worker session."* Stop. (A worker is bound to one issue;
  the wizard files new ones.)
- `brief` prints this fleet's repos — `[seed]` is the **starter repo**
  (`FLEET_SEED=1`, claude-fleet itself: the tool, not theirs); `[mine]` is owned
  by the logged-in GitHub user — the `gh=` login (`NOT-LOGGED-IN` → help them run
  `gh auth login` first; nothing below works without it), and the saved progress
  ending in `resume: <step>`.
- **Go to the step `resume:` names.** A fresh start is `repo`. On a resume, open
  with one sentence of where you left off («上次我们开了 #12，正在做——看看进展？»)
  instead of starting over. `done` → offer step 5 again (it is what a newcomer
  calling the wizard back usually wants), or `reset` if they want a new walk.

## 1. `repo` — which repo, and put it in the fleet

1. Say hello, then ask what they want to work on. If `brief` showed a `[seed]`
   repo, say it plainly once: **it is the tool this fleet runs on, not their
   repo — the wizard never files work there.** Never offer it as a choice.
2. List their repos:

   ```sh
   gh repo list --limit 30 --json nameWithOwner,description,pushedAt,isArchived \
     --jq '.[] | select(.isArchived|not) | "\(.nameWithOwner)\t\(.pushedAt[:10])\t\(.description // "")"'
   ```

   Show the most recently pushed few (a repo `brief` already tagged `[mine]` is
   already in the fleet — say so). Ask which one to start with. They may name one
   not in the list (an org repo): take `owner/name` as given.
3. **No repo at all?** Offer to create one — name it with them, show the command,
   run it only on yes: `gh repo create <name> --private --add-readme`.
4. **Add it to the fleet** unless `brief` already listed it. Say what happens
   («我会把它克隆到 ~/projects/<name>，加进你的会话列表，可以吗？») and on yes:

   ```sh
   ~/.claude/fleet/bin/fleet-repo.sh add <owner/name>
   ```

   stdout is one token: `added:<slug>` (or `refused:hosted` — already there,
   fine) → go on (a `not trusted … pre-#563 launcher` WARNING on stderr is about
   old launchers — don't mention it). Any other `refused:` / `failed:` → read its stderr to them in
   plain words and help fix it (usually a typo, or no access). Then:

   ```sh
   ~/.claude/fleet/bin/fleet-onboard.sh set repo=<owner/name> step=issue
   ```

5. **The starter repo can go now** (issue #1172). If `brief` tagged a `[seed]`
   repo, say so once, right after the add: it was only there so the fleet worked
   before they had a repo of their own, and now it is dead weight in their session
   list — then offer, in one line, to take it out («起步仓库 claude-fleet 现在可以
   拿掉了，会话列表里就只剩你的仓库——要拿掉吗？»). On yes:

   ```sh
   ~/.claude/fleet/bin/fleet-repo.sh remove <seed owner/name>
   ```

   It promotes their repo into the fleet's own slot; this `guide` window keeps
   running (a scratch of the starter never blocks it). A `refused:` on stderr
   (an issue window still open on the starter) → leave it and go on — the same
   command works later from any window. On no → go on; nothing depends on it.

## 2. `issue` — turn the wish into an issue and open a session for it

1. Ask them to say, in their own words, the first thing they want changed — one
   small, visible thing is the best first issue; if the wish is big, help them
   pick a first slice. You may look at the repo to ground the draft (read-only:
   `gh repo view <repo>`, the checkout's `README` / tree) — never edit it.
2. Draft the issue in their language: a short title, and a body with **what**,
   **why**, and **how we'll know it's done**. Append this section verbatim (it is
   for the worker session, so it stays in English):

   ```markdown
   ---
   **For the worker:** this is the author's first fleet task. Open the PR and get
   the checks green, but **do not merge it** — the author merges their first PR
   themselves. When it is ready, report
   `fleet-report-parent.sh --state waiting --pr <PR> --summary 'ready for the author to merge'`,
   mark the window `set-claude-state.sh blocked`, and stop.
   ```

3. Show them the title + body (minus the worker note, which you mention in one
   line: «我还加了一句给执行会话的话：让它开好 PR 等你来合并»). Edit until they say
   yes. Then file it **and** open its session — one call:

   ```sh
   ~/.claude/fleet/bin/fleet-issue-file.sh --repo <owner/name> --title '<title>' --body '<body>' --spawn
   ```

   stdout is the issue URL; the trailing number is `N`. A spawn refusal on
   stderr (session cap, …) leaves the issue filed — tell them, and they can open
   it later from the session list. Save it before anything else:

   ```sh
   ~/.claude/fleet/bin/fleet-onboard.sh set issue=<N> step=watch
   ```

4. Tell them what just happened in two sentences: a new session is working on
   #N in its own copy of the repo; it will open a PR when it's done.

## 3. `watch` — read the session list while it works

Point at the session list (the task sidebar on the left) and explain **only the
states they can see right now** — look first:

```sh
tmux list-windows -F '#{window_name}|#{@issue}|#{@repo}|#{@claude_state}'
~/.claude/fleet/bin/fleet-keys.sh --context sidebar --plain
```

The row for #N is theirs. In plain words: a spinning row is **working**; green
✓ means it **finished a turn**; red means **it needs you** (a question, or — for
this issue — «PR 开好了，等你合并»); a PR number on the row means **a PR is open**.
Take every key you mention from the `fleet-keys.sh` output above, never from
memory — say only the two or three they need now (switching to a row with ↑↓,
getting back here). If a key isn't in that output, don't mention it.

Then let them go look — they can switch to the worker's row and watch it, and
come back here any time. **Do not poll in a loop.** The worker was spawned from
this window, so it reports back here by itself (`[child-report]`) when it opens
the PR, is blocked, or finishes; when they come back and ask, look once:

```sh
gh pr list --repo <owner/name> --head issue-<N> --state all --json number,url,state,title
```

- A PR exists → `fleet-onboard.sh set pr=<PR> step=merge` → step 4.
- The worker says it is blocked on a question → help them answer it (switch to
  its row; it is asking in plain language).
- Still working → say so, and that you'll be here.

## 4. `merge` — look at the PR together; they merge it

1. Show what changed, briefly: `gh pr view <PR> --repo <owner/name>` and the gist
   of `gh pr diff <PR> --repo <owner/name>` in their words — not the raw diff
   unless they ask.
2. Read the gate (never eyeball it):
   `~/.claude/fleet/bin/fleet-pr-verdict.sh <PR> --repo <owner/name>` —
   `READY` → go on; `PENDING` → checks still running, say so and wait for them to
   ask again; `FAILING` / `CONFLICT` → the worker fixes it (it usually already
   is) — tell them to reply on its row, or you can say it in its session:
   `~/.claude/fleet/bin/fleet-peer-send.sh issue:<N> '<what to fix>'`;
   `MERGED` → the worker merged it anyway: congratulate them, skip to 3.
3. Ask: **merge it?** They can press Merge on the PR's GitHub page themselves, or
   say yes and you run:

   ```sh
   gh pr merge <PR> --repo <owner/name> --squash --delete-branch
   ~/.claude/fleet/bin/fleet-pr-verdict.sh <PR> --repo <owner/name>   # → MERGED
   ```

   The confirming read, not `gh`'s exit code, says it landed. Then
   `fleet-onboard.sh set step=handoff`.
4. Tell them the worker's window **cleans itself up** a few minutes after the
   merge — the row disappears on its own; nothing to close.

## 5. `handoff` — how to do the next one alone

Three things, each with the key read live from
`~/.claude/fleet/bin/fleet-keys.sh --plain` (the full sheet — grep the lines you
need; skip any that are gone):

- **The next issue:** type what they want on the input line at the bottom of the
  session list and press ↵ for a quick session, or the «new task» key (⌃n in the
  sheet) to file an issue and open its session in one go — what you just did
  together, without you.
- **Another repo:** the row menu's «add a repo» letter (the sheet's `row menu`
  group), or ask the wizard again.
- **Calling the wizard back:** `/fleet-onboard` in any non-worker window — it
  remembers where they left off.

Then `fleet-onboard.sh set step=done` and say goodbye in one line.

---

Rails: this fleet only, and only repos the newcomer names — never the `[seed]`
starter repo (taking it OUT of the fleet, step 1.5, is the one thing you do to
it), never another fleet's. Read-only everywhere except the five
confirmed writes above; code is a worker's job, and the worker is a spawned
session (`fleet-issue-file.sh --spawn`), never a subagent. No `tmux send-keys`
into another pane (hook-blocked; `fleet-peer-send.sh issue:<N>` is the channel).
Never run `/fleet-sync-install` or touch the live install.
