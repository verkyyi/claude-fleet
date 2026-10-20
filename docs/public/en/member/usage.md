# Everyday use

This page is about every day: one key opens the panel, where you open sessions, see how they are doing and answer their questions; and how to say when something is wrong. Connecting from a computer or phone has its own page: [Connecting from a computer or phone](connect.md). Using it for the first time, follow [Member · Quickstart](quickstart.md) to your first session.

Remember one sentence: **sessions run on fleet's machines, not on your computer.** Close the terminal, shut the laptop, go offline — sessions keep working; come back, type `fleet`, and everything is as you left it.

## One key: the panel

Everything starts from one key. The tables below are generated from fleet's key configuration, so when a default key changes, this page follows:

<!-- docs-gen:keys -->
| Where | Press |
|---|---|
| iTerm2 on a Mac | `⌘P` |
| A phone (Termius) or another terminal | `⌃Space` or `F12` or `⌃] p` |

| Key | What it does |
|---|---|
| `↵` | go |
| `Tab` | act |
| `↑↓` | pick |
| — | type to filter |
| `?` | legend |
| `esc` | close |
| `↑` | to ⚡ |
<!-- /docs-gen:keys -->

The panel looks roughly like this (sample data):

```text
› Search sessions                 Sessions 8
─ Waiting on you 1
  ! T128     Claude  Login page redesign         web-app
                     keep the old redirect?
─ Working 2
  ↻ T131     Codex   Fix export timeout          web-app
  ↻          Claude  Weekly report data
─ Done, to collect 1
  ✓ T127     Claude  Upgrade dependencies        web-app
▸ Ended · still open (4)
  ⚡ New session
↵ go  Tab act  ↑↓ pick  type to filter  ? legend  esc close  ↑ to ⚡
```

### Open a session

- **Open a new session**: pick “⚡ New session” and press Enter (↑ from the top of the list gets there) to open the “New session” box: three items only — “Repo ‹›”, “Agent ‹›” and “Open ↵” — already chosen, with the cursor on “Open”, so another Enter opens it. To change one: ↑↓ or Tab moves between items, ←→ changes the repository or agent (“No repo” when you need none), and Enter on a value goes back to “Open”. The defaults: the repository of the session you are looking at (when it has none, the one you chose last time — “No repo” counts), and the agent that repository last opened with; `⌘N` opens this box directly, Enter then opens the session, Escape closes it. There is nothing to write — say what to do inside the session once it opens; after your first message, its row in the list (and its task record) is renamed to that message's first line.
- **Switch sessions**: type part of a title or ticket number, select a session with ↑↓, and press Enter.

The actions page, a question such as a rename, and the new-session box are whole pages: the list area is replaced, the top line names what it is about (the session, or “⚡ New session”), and below it one item a line — ↑↓ to pick, ↵ to run; there is no floating box. Escape goes back a level (from a rename to the actions page, then to the list), the list keeping its selection; another Escape closes the panel. Click to select a row, double-click to enter a session or open the new-session box; items on a page are clickable (click a repository or agent again for the next one, click “Open” to open).

The repository and agent chosen in the box are stored privately on this machine for this view, and come back the next time it opens. Resize keeps the selection, clamping scroll ranges only where necessary. At least 48 columns is recommended; narrower terminals show a notice and keep Tab and Escape working. Long content scrolls inside the page.


### Session states

The title counts open sessions and shows matched/total while searching. Folding and pinning do not change the total. Finished windows still open count; reaped records do not. `+?` marks an unconfirmed remote count. Selection changes the background while status glyphs and name columns stay fixed. Ctrl+T still pins or unpins. The footer contains shortcuts, the optional legend and brief feedback.

The panel groups sessions by what you should do:

| Group | Meaning | What you do |
|---|---|---|
| **Pinned** | Ones you pinned yourself | — |
| **Waiting on you** | The session stopped to ask you something, or is waiting for you to allow an action — or asked on its ticket and nobody has answered yet, even if it has stopped since; its words are on the next line | Switch to it and answer, or press Tab on its row → "Answer…" |
| **Working** | Doing it now | Nothing |
| **Done, to collect** | It handed in its result and its window is still open: the pull request checking, waiting to merge or ship, or merged | Look at the result; reap it when you are done |
| **Other** | Idle, or no state to read | — |
| **Ended** | Finished sessions: ones bound to no ticket, or whose ticket is closed and pull request merged more than a day ago; the ones still open first, the reaped ones under them, folded at the bottom | Still open: ↵ on the last row reaps them all; to carry on: pick it, ↵ "Restore" |

Every row has the same columns: state glyph · ID (the window's own short code `K3F9`, from the moment it opens until it closes) · Agent (Claude / Codex, its latest conversation's; a grey "unknown" when it cannot be read) · short name · repository (blank when it has none). The state comes from whether the window is up and the result it reported last: the newest of several wins, and a window closed without one is "exited". One conversation open in two windows makes both rows a red "waiting on you", the reason on the actions page. The glyphs: ↻ running · ! waiting on you · ✓ done · ✗ failed · ◌ exited (the agent quit, its window is still up — only under "Ended · still open") · ∙ idle · ? lost; only ! and ✗ are red. Press `?` for the legend.

Ticket numbers, pull requests and machines are no longer on the row: pick a row and the second line from the bottom says how long it has been lost, whether its configuration needs a reopen (in red), its sub-task progress and its pull request's step. A ticket number is not shown but is searched — type `4539` or `#4539` and the session linked to that ticket — or dispatched with `#4539` in its words — is found, the bottom line saying "matched: linked issue #4539". When a machine cannot be reached, a red bar appears across the top of the panel and its rows turn grey with a ?; wait for it to come back — the sessions are not lost.

### What you can do with a session

Pick a row and press **Tab** for its actions page: Enter · Open PR #n (only with a PR) · Rename… · Switch to Codex / Claude (while it runs; grey, unnumbered and saying why when this machine cannot run that agent) · Reap…. Under the items it lists the window's code, full ID, aliases (the old T number) and every conversation it went through (agent · start–end · how it began · compactions), and "not registered with the hub" while the hub has not got it yet. A digit runs an item; `[` `]` step to the previous / next session's page. A session waiting on you and one whose agent exited are both "Enter": switch to it and answer, or press ↵ on its recovery page. A shell in its directory is `⌃\`, pinning `⌃T` (or "Pin this session" at the foot of the list); a reap policy is changed by the session itself, or with the commands below.

You can do the same from the terminal with commands (`<session>` can be part of a name or a `#ticket`; when it is not clear which one you mean, it lists the candidates rather than guess):

```sh
fleet ls                       # my sessions: name · ticket · machine · left · state · PR · reap policy
fleet ls --all                 # ended ones too
fleet open login               # open the client and switch to this session
fleet answer login keep        # answer its question without going in
fleet close report             # close a session
fleet quit                     # quit fleet (see below)
```

## Pasting images and dropping files

In the desktop fleet terminal, drop files or press `Ctrl+V` to paste a clipboard image. Fleet uploads them and inserts their remote paths automatically, including multiple files. Ordinary text paste works as before.

Output and resizing continue while Fleet prepares and uploads attachments. The top bar shows Preparing → Uploading (received bytes and total progress) → Confirming → Uploaded. Input is paused: text, Enter and further drops are discarded, never saved for later. `Ctrl+C` cancels only the upload and restores input without interrupting remote work. Success inserts the confirmed remote paths once, without pressing Enter. Failure, switching sessions or disconnecting inserts nothing; type again after input resumes.

Each operation allows 16 files: 10 MiB per image, 100 MiB per other file, and 100 MiB total. It times out after 120 seconds. If Fleet cannot verify the current session, attachments fail visibly while ordinary text input remains available.

## Working in a code repository

For a task in a repository, the session changes **its own copy of the code** and touches nobody else's; when it is done it opens a pull request, merges it itself once the checks pass, and then tells you the result. You see it under "Done, to collect" and read what changed on the PR.

You do not have to watch it. To stop it or change direction, switch to it and say so; when it is stuck it shows up under "Waiting on you".

## Closing the computer, changing computers, watching on a phone

Sessions run on fleet's machines: close the terminal, shut the laptop, switch to another computer or open it on a phone — it is the same set of sessions. How to connect, and how to come back after closing: [Connecting from a computer or phone](connect.md).

## Task records: T numbers

Everything you hand over on the ⚡ line is first written down by fleet, numbered with a **T** (for example `T42`): your own words, which machine and which session it went to, and where it stands now.

- A task has this one number: it is yours, not a repository's. A task given a repository changes code and opens pull requests there — GitHub holds only the code and the pull requests, with no second ticket.
- The hub's **Tasks** page lists all your task records; a record stays after its session ends.
- **Completed** means the hub has a confirmed work result. A missing session never implies completion; old records without confirmed task status show **Unknown**. Open **Task details** to see the requested, resolved and verified agent separately from the session observation. A required PR still waiting for merge shows **Waiting for GitHub** beside the work result. If a refresh fails, the open page keeps its last confirmed view and read time, marked stale; **Retry read** only reads again and never starts work.
- Tell a colleague "the T42 thing" and they can find it on the Tasks page.

### A design page first, then the task

With the fleet-epic plugin installed, say `/fleet-task-plan <subject>` in a session (for example "batch reports never reach me"). It first writes the matter up as one design page: what happens, why (the evidence folded underneath), goal and scope, the changes, what could go wrong, what you need to decide, and the proof it shipped. The page is private and pushed to your WeChat. Say what to change and it edits the same page; nod and it opens one task from the page, stamps the task's number at the top, and the task's session works from it. For a batch of related work, `/fleet-epic-plan` writes the same kind of page.

## Reaping: when a session closes

A finished session is reaped automatically — no clean-up by hand. Before it goes its history is recorded and its copy of the code kept, and you can ↵ restore it any time from "Ended" in the panel. The default rules:

| Session | Closes by default |
|---|---|
| Repository task, PR merged | About 10 minutes after the merge |
| Repository task, done but no PR | After 2 hours idle |
| Blank session | After 15 minutes idle |

To change it: pick the row, Tab → "Reap policy…", and choose **closes after merge**, **closes when done** (optionally after a while), **closes when its loop stops**, **closes at a time**, or **never closed by itself**. A session that is working, or waiting for your answer, is never reaped.

## Quota and usage

The line at the top of the panel is only about the session you are looking at: how much context is left and which model it uses (for example `62% left · Opus 5.5 · high`). Grey means the reading is more than 5 minutes old.

When the context is nearly full, a repository task's session hands itself off to a new session that carries on; in a blank session you can just say "hand off".

## Optional: your own keys for common actions

By default there is one key — the one that opens the panel — and everything else is in the panel. If you are used to the old shortcuts, add them back in `~/.config/claude-fleet/fleet.conf` on your own computer:

```ini
[client]
FLEET_KEYS_EXTRA="next=cmd+down prev=cmd+up new=cmd+n"
[common]
FLEET_KEYS_PHONE_EXTRA="ctrl+]n=next ctrl+]b=prev"
```

The actions you can set (this table is generated too):

<!-- docs-gen:keys-extra -->
| Name | What it does | On a Mac (⌘) | On a phone (⌃] then) |
|---|---|---|---|
| `next` | the next session; the right pane follows at once | `⌘↓` | `⌃] n` |
| `prev` | the previous session | `⌘↑` | `⌃] b` |
| `back` | back through the sessions you were on (no task list: the machine before) | `⌘[` | `⌃] h` |
| `fwd` | forward again | `⌘]` | `⌃] l` |
| `new` | new session: straight to the “New session” box — the repo of the session you are looking at (else the last one used), the agent that repo last used; Enter opens | `⌘N` | `⌃] c` |
| `dispatch` | dispatch: a title + a repo (the last one used) + optionally Codex, ↵ files it and starts its worker; from any window, no model on the way | `⌘T` | `⌃] t` |
| `quit` | quit this client connection; sessions keep running on their machines; fleet opens it again | `⌘Q` | `⌃] q` |
<!-- /docs-gen:keys-extra -->

Without iTerm2 (for example Ghostty, or the system's own Terminal) ⌘ keys never reach fleet; open the panel with `⌃] p` or `⌃Space`.

## Saying something is wrong

- **Cannot connect, will not open**: first see [Troubleshooting](../troubleshooting.md). When you need someone to look, type `fleet doctor --json` in the terminal and send the output to your admin.
- **Common questions**: [FAQ](../faq.md).

A managed conversation without a repository can also switch to Codex from the list menu. Finish its current turn first. For native scheduled tasks, the panel asks the source to verify its current tasks and prepare handoff notes before switching. The source keeps running during preparation; missing sign-in, folder trust or task details are explained. Session-only patrols and one-shot reminders keep their own timing and expiry, and deleted tasks stay deleted. A durable Claude reminder in the project moves too: the source deletes it with its own scheduler only after Fleet has saved an inactive copy, and the copy goes live once the source has exited — so the reminder arrives once, on time, in the switched conversation. If the source cannot do that itself (for example it is out of quota), the switch takes the reminder only while no other Claude could be rewriting that project's task list; otherwise it explains which process is in the way and the original conversation and reminders keep running. You do not need to find or export JSON. A trusted node fills a missing HOME trust entry while respecting explicit distrust and pre-trust opt-out. Unsent input remains a draft.

For accepted remote tasks, Fleet verifies the selected agent before delivering the first input. If launch verification fails or the connection loses its receipt, Fleet keeps the task for recovery instead of choosing another agent or starting it again. A resume keeps the original conversation. An explicit agent switch starts a new attempt only after the source has stopped; an uncertain switch needs recovery before another attempt.

## Webchat connections

Webchat tries a direct connection to your home node first and uses the hub relay when the network prevents it. Older nodes and the local page continue to work, with the same conversation and quota rules.

If the connection drops after submission, the page reloads the conversation and says that the message may already have arrived. Review the recovered conversation before retrying. Messages, stop requests and answers are never sent again automatically.
