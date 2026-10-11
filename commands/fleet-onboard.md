# /fleet-onboard — one key, one thing done, two or three minutes

<!-- fleet skill · owner: scratch -->

The first thing a new login sees (the pinned `guide` session). The person is
**not a developer** (issue #3332, EPIC #3178 C20): Claude Code is already set up
for them, and this walk only has to show them the one key and get one thing of
theirs done, right in front of them:

1. say hello in one line;
2. teach one key — ⌘P on a computer, ⌃Space on a phone;
3. they press it, write one thing on the panel's **⚡** row and press ↵ — the
   panel opens a new session whose first line is their own words (#3327, #3331),
   with no ticket filed (a hub task record, #3325) — and they watch it work and
   finish;
4. done — two or three minutes.

The old developer walk (pick a repo → a session that opens a PR → merged) stays,
**only when they ask for it** (step 5). Until then never say «仓库 / repo»,
«issue / 单», «PR», «GitHub», «worktree», «分支 / branch» — not once.

This window is an ordinary session: it never takes the orchestrator role, never
spawns a session, never files anything on the default walk, never edits a file.
Progress lives in `$FLEET_CONF_DIR/global/onboard.state` (`bin/fleet-onboard.sh`),
so calling the guide back picks up where it left off.

**Argument** (`$ARGUMENTS`): none — or `reset` to forget the saved progress and
start over (`~/.claude/fleet/bin/fleet-onboard.sh reset`, then step 0).

## How to talk (read this before saying anything)

- **Say the `say.<name>:` lines.** `brief` prints the walk's fixed lines in the
  person's language (`lang=`, from the fleet's one table — `fleet-ui-lang.sh`,
  which follows their own choice, then their device). Say each one as printed —
  you may join two, never pad them with fleet words. Everything else you say is
  in that same language; if they write in another one, switch and save it:
  `~/.claude/fleet/bin/fleet-onboard.sh set lang=<zh|en>`. Fleet automation that
  lands in this pane (a `[child-report]`, a resume nudge) is English — never a
  reason to switch.
- **Short.** One or two sentences a turn, then wait for them. No lists, no
  headings, no documents — they read nothing but what you say.
- **Save the step the moment it changes** (the `set` lines below), before saying
  the next thing — a closed laptop must not lose it.

## 0. Read where we are (run FIRST, every time)

```sh
~/.claude/fleet/bin/fleet-onboard.sh brief
```

Running it is also how the fleet learns the guide is really up (issue #1215):
the first `brief` leaves `$FLEET_CONF_DIR/global/guide.spoke`; until it exists
the guide counts as not yet spoken and the collector reopens it.

- **No fleet** (exit 3) → one line: *"not inside a fleet — open this from a fleet
  window."* Stop. A fleet with no repo at all is NOT that — it is exactly where a
  newcomer starts, and the default walk needs none.
- **Worker seat** (`seat=worker`) → one line: *"/fleet-onboard runs in its own
  window, not inside a session bound to one task."* Stop.
- `brief` prints `lang=`, the `say.*` lines, the saved progress, and
  `resume: <step>`. **Go to that step.** On a resume, open with one sentence of
  where you left off instead of starting over. `path=dev` means they chose the
  developer walk: `brief` then also prints the GitHub login and their repos.

## 1. `key` — hello, and the one key

Say `say.hello`, then `say.key`. Then remember which sessions exist right now,
so you can tell theirs apart in a minute:

```sh
~/.claude/fleet/bin/fleet-onboard.sh look --mark
~/.claude/fleet/bin/fleet-onboard.sh set step=try
```

## 2. `try` — they hand over one thing

Say `say.try`. If they ask what to write: anything they would ask a helpful
person at a computer — a letter, a summary of a web page, a plan for the
weekend, a question. Keep the example theirs; never steer them to code.

Wait for them to come back («好了 / done / sent»), or — if they type the wish
here instead — say it goes on the ⚡ row: ⌘P, write it, ↵. Then look once:

```sh
~/.claude/fleet/bin/fleet-onboard.sh look
```

- A `new` row → that is their session (its words are the last column). Save it
  and say `say.sent`:

  ```sh
  ~/.claude/fleet/bin/fleet-onboard.sh set task=<the task column, or its words> step=see
  ```

- `none` → it may still be opening, or it opened on another of their computers
  (the panel picks where it runs). Say: press ⌘P — their words are a row there; if
  they are, it is running (go on to step 3 all the same). If the ⚡ row showed a
  red line instead, read it to them in plain words and have them try once more.

## 3. `see` — it works, it finishes

They switch to it (⌘P, pick it, ↵) and watch; this window stays. When they come
back, look once (`fleet-onboard.sh look`) and read its state column in plain
words: `working` — still at it; `done` — finished; a `needs…` state — **it is
asking them something**: go to it (⌘P, its row, ↵) and answer in their own words.
Never poll in a loop; look when they come back or ask.

Finished (or they are happy with what they saw) → say `say.done`, then `say.more`,
then `say.dev` once, and:

```sh
~/.claude/fleet/bin/fleet-onboard.sh set step=done
```

That is the whole walk. If they want another, the same key does it — no need for
you.

## 4. `done` — they called the guide back

Offer, in one line, one more thing on ⌘P (back to step 2 — `look --mark`, then
`set step=try`) or the developer walk (`say.dev`). `reset` starts over.

## 5. The developer walk — only when they ask

They asked to change code / get a PR. Record it, then read the brief again —
with `path=dev` it shows the GitHub login and the repos this fleet hosts:

```sh
~/.claude/fleet/bin/fleet-onboard.sh set path=dev step=repo
~/.claude/fleet/bin/fleet-onboard.sh brief --dev
```

### 5.1 `repo` — which repo

- `gh=NOT-LOGGED-IN` → they log in first: have them type `! gh auth login` here
  and follow its prompts. Nothing below works without it.
- A `[seed]` repo is the tool this fleet runs on, not theirs: never offer it,
  don't bring it up; only if they ask to remove it, `fleet-repo.sh remove` it.
- List theirs and ask which one (they may name an org repo as `owner/name`):

  ```sh
  gh repo list --limit 30 --json nameWithOwner,description,pushedAt,isArchived --jq '.[] | select(.isArchived|not) | "\(.nameWithOwner)\t\(.pushedAt[:10])\t\(.description // "")"'
  ```

  None at all → offer to create one; show the command, run it only on yes:
  `gh repo create <name> --private --add-readme`.
- Unless `brief` already lists it, say what happens («我会把它克隆到这台电脑，
  加进 ⌘P 的仓库格子里，可以吗？») and on yes:

  ```sh
  ~/.claude/fleet/bin/fleet-repo.sh add <owner/name>
  ```

  stdout `added:<slug>` or `refused:hosted` → tell them in one line where it is:
  **「你的代码在 `~/projects/`」** (`~/projects/<name>` — every repo they add
  lands there), then go on (a `not trusted … pre-#563
  launcher` warning on stderr is not for them). Any other `refused:` / `failed:`
  → read its stderr to them in plain words and help fix it. Then:

  ```sh
  ~/.claude/fleet/bin/fleet-onboard.sh set repo=<owner/name> step=issue
  ```

### 5.2 `issue` — the same ⚡ row, with the repo

The same key as before. Mark first, then tell them: ⌘P, write the change they
want (one small, visible thing is the best first one), and before ↵ press **Tab**
on the ⚡ row — the 仓库 / Repo cell — and pick their repo with ←→; then ↵. The
panel files the issue on that repo and opens a session for it (its progress line
shows the number).

```sh
~/.claude/fleet/bin/fleet-onboard.sh look --mark
```

When they are back, `fleet-onboard.sh look`: a `new` row with an issue number is
it →

```sh
~/.claude/fleet/bin/fleet-onboard.sh set issue=<N> step=watch
```

### 5.3 `watch` — it works and opens a PR

The session works in its own copy of the repo, opens a PR when the change is
ready and lands it itself once the checks are green. Explain only what they can
see (`look`'s state column, the row's PR number). Look once when they come back:

```sh
gh pr list --repo <owner/name> --head issue-<N> --state all --json number,url,state,title
```

A PR → `fleet-onboard.sh set pr=<PR> step=merge`. A question from the session →
help them answer it on its row. Still working → say so.

### 5.4 `merge` — the result

Read the gate, never eyeball it:
`~/.claude/fleet/bin/fleet-pr-verdict.sh <PR> --repo <owner/name>`.
`MERGED` → show what changed in their words (`gh pr view <PR> --repo <owner/name>`,
the gist of `gh pr diff <PR> --repo <owner/name>`). `PENDING` / `FAILING` /
`CONFLICT` → the session is on it; say so. `BLOCKED` → their repo wants a review:
they press Merge on the PR's page themselves (give them its URL from the
PR list in 5.3). Then
`fleet-onboard.sh set step=done`, and say the next one is the same ⌘P, ⚡, Tab, ↵.

---

Rails: this fleet only. The default walk writes nothing but its own progress
file. The developer walk's writes are two, each shown and run only after a yes:
creating their GitHub repo (only when they have none) and adding a repo to this
fleet. Never take a role, never spawn, never file an issue yourself, never edit a
file; the session that does the work is the one the panel opened. No
`tmux send-keys` into another pane (hook-blocked). Never run `/fleet-sync-install`
or touch the live install.
