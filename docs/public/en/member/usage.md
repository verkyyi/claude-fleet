# Everyday use

This page is about every day: one key opens the panel, where you open sessions, see how they are doing and answer their questions; and how to say when something is wrong. Connecting from a computer or phone has its own page: [Connecting from a computer or phone](connect.md). Using it for the first time, follow [Member · Quickstart](quickstart.md) to your first session.

Remember one sentence: **sessions run on fleet's machines, not on your computer.** Close the terminal, shut the laptop, go offline — sessions keep working; come back, type `fleet`, and everything is as you left it.

## One key: the panel

Everything starts from one key. The tables below are generated from fleet's key configuration, so when a default key changes, this page follows:

<!-- docs-gen:keys -->
| Where | Press |
|---|---|
| iTerm2 on a Mac | `⌘P` |
| A phone (Termius) or another terminal | `F12` or `⌃] p` |

| Key | What it does |
|---|---|
| `↵` | go |
| `Tab` | act |
| `↑↓` | pick |
| — | type to filter |
| `?` | legend |
| `esc` | close |
| — | Rows of the panel (pick one, ↵ — or type its name): ⚡ New session · $ Shell (this machine's shell, in your home directory) · ⏻ Quit fleet (sessions keep running) |
<!-- /docs-gen:keys -->

**The top line is the session's; messages get a row of their own.** The 看台's top line says the session only: its state, title, change number and quota. Whatever fleet has to tell you — a session asking you, stuck or done, an alert, a result nobody took, a passing notice (e.g. 「暂停开新：内存紧张」) — goes on a row **under** it, there only while something is unseen: the newest on the left, 「✦ 3 · ⌘P」 on the right. An error (red ✖) and a result nobody took (yellow ✓) stay until you have seen them; a warning (yellow ▲) fades after 6 seconds, a note (grey ∙) after 3. Once you have seen everything the row folds away. Click the row, or open ⌘P's first row **✦ Messages** (or type 消息 / message in ⌘P), for all of them, grouped: ↵ reads one, g goes to its session, r marks it read, f hands a result nobody took to the orchestrator. Another home shows the same messages and count. `fleet notices` on your computer's command line prints them too.

The panel looks roughly like this (sample data). The order on screen, top to bottom, is the order ↑↓ walk; ↓ at the bottom goes round to the top, ↑ at the top to the bottom. The cursor stops on indented rows; a line starting with ─ is a group heading.

```text
› Search sessions                 Sessions 8
  ✦ Messages
 ⚡ New session
  $ Shell
─ Waiting on you 1
  ! T128     Claude  Login page redesign         web-app
                     keep the old redirect?
─ Working 2
  ↻ T131     Codex   Fix export timeout          web-app
  ↻          Claude  Weekly report data
─ Queued 1
  ✓ T127     Claude  Upgrade dependencies        web-app  waiting for the release train
  ▸ Folded away (4)
  ◐ Language / 语言
  ⏻ Quit fleet (sessions keep running)
↵ go  Tab act  ↑↓ pick  type to filter  ? legend  esc close
```

### Open a session

- **Open a new session**: pick “⚡ New session” and press Enter (at the top of the list, under Messages) to open the “New session” box: three items only — “Repo ‹›”, “Agent ‹›” and “Open ↵” — already chosen, with the cursor on “Open”, so another Enter opens it. To change one: ↑↓ or Tab moves between items, ←→ changes the repository or agent (“No repo” when you need none), and Enter on a value goes back to “Open”. The defaults: the repository of the session you are looking at (when it has none, the one you chose last time — “No repo” counts), and the agent that repository last opened with; `⌘N` opens this box directly, Enter then opens the session, Escape closes it. There is nothing to write — say what to do inside the session once it opens; after your first message, its row in the list (and its task record) is renamed to that message's first line.
- **Switch sessions**: type part of a title or ticket number, select a session with ↑↓, and press Enter.

The actions page, a question such as a rename, and the new-session box are whole pages: the list area is replaced, the top line names what it is about (the session, or “⚡ New session”), and below it one item a line — ↑↓ to pick, ↵ to run; there is no floating box. Escape goes back a level (from a rename to the actions page, then to the list), the list keeping its selection; another Escape closes the panel. Click to select a row, double-click to enter a session or open the new-session box; items on a page are clickable (click a repository or agent again for the next one, click “Open” to open).

The repository and agent chosen in the box are stored privately on this machine for this view, and come back the next time it opens. Resize keeps the selection, clamping scroll ranges only where necessary. At least 48 columns is recommended; narrower terminals show a notice and keep Tab and Escape working. Long content scrolls inside the page.


### Session states

The title counts open sessions and shows matched/total while searching. Folding and pinning do not change the total. Finished sessions whose window is still open count; folded-away ones do not. `+?` marks an unconfirmed remote count. Selection changes the background while status glyphs and name columns stay fixed. Ctrl+T still pins or unpins. The footer contains shortcuts, the optional legend and brief feedback.

The panel puts sessions in five groups, by whether they need you:

| Group | Meaning | What you do |
|---|---|---|
| **Pinned** | Ones you pinned yourself | — |
| **Waiting on you** | Only what waits on your hand: the session stopped to ask you something (a plan page waiting for your call included — it asks you properly, and its record keeps the "asked you" mark), is waiting for you to allow an action, or failed — or asked on its ticket and nobody has answered yet, even if it has stopped since; its words are on the next line. A session sitting idle with nothing asked is not here | Switch to it and answer, or press Tab on its row → "Answer…" |
| **Working** | Doing it now | Nothing |
| **Queued** | Waiting on something that is not you: it sits idle with no question open (marked "idle" at the row's end), it handed in its result and the pull request is checking, waiting to merge or ship, or it is done and about to be folded away (the row's end says which step) | Nothing; to fold the ended ones now, ↵ on the group's last row |
| **Folded away** | Sessions whose window is closed, their conversation and copy of the code kept (the last 7 days); a session whose agent exited while its window is still up is folded here at once too (marked "exited"). Folded at the bottom as a count | → to open it, pick one, ↵ "Restore" to carry on in the same conversation |

An EPIC batch's members hang under its driver's row, in whatever group the driver is in; the driver's row says done/total.

Every row has the same columns: state glyph · ID (the window's own short code `K3F9`, from the moment it opens until it closes) · Agent (Claude / Codex, its latest conversation's; a grey "unknown" when it cannot be read) · short name · repository (blank when it has none). The state comes from whether the window is up and the result it reported last: the newest of several wins, and a window closed without one is "exited". One conversation open in two windows makes both rows a red "waiting on you", the reason on the actions page. The glyphs: ↻ running · ! waiting on you · ✓ done · ✗ failed · ◌ exited (the agent quit, its window is still up — folded under "Folded away") · ∙ idle · ? lost; only ! and ✗ are red. Press `?` for the legend.

Ticket numbers, pull requests and machines are no longer on the row: pick a row and the second line from the bottom says how long it has been lost, whether its configuration needs a reopen (in red), its sub-task progress and its pull request's step. A ticket number is not shown but is searched — type `4539` or `#4539` and the session linked to that ticket — or dispatched with `#4539` in its words — is found, the bottom line saying "matched: linked issue #4539". When a machine cannot be reached, a red bar appears across the top of the panel and its rows turn grey with a ?; wait for it to come back — the sessions are not lost.

### What you can do with a session

Pick a row and press **Tab** for its actions page: Enter · Open PR #n (only with a PR) · Rename… · Switch to Codex / Claude (while it runs; grey, unnumbered and saying why when this machine cannot run that agent) · Reap…. Under the items it lists the window's code, full ID, aliases (the old T number) and every conversation it went through (agent · start–end · how it began · compactions), and "not registered with the hub" while the hub has not got it yet. A digit runs an item; `[` `]` step to the previous / next session's page. A session waiting on you and one whose agent exited (under "Folded away") are both "Enter": switch to it and answer, or press ↵ on its recovery page. A shell in its directory is `⌃\`, pinning `⌃T` (or "Pin this session" at the foot of the list); a reap policy is changed by the session itself, or with the commands below.

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

For a task in a repository, the session changes **its own copy of the code** and touches nobody else's; when it is done it opens a pull request, merges it itself once the checks pass, and then tells you the result. You see it under "Queued" and read what changed on the PR.

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

A finished session is reaped automatically — no clean-up by hand. Before it goes its history is recorded and its copy of the code kept, and you can ↵ restore it any time from "Folded away" in the panel. The default rules:

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

fleet uses one key, ⌘P (phone: `F12` or `⌃] p`); everything else is in the panel: New session, Shell and Quit fleet are rows of it — pick one and press ↵, or type a few letters ("shell", "quit") to land on it; quitting asks first. ⌘K (clear), ⌘T (new tab), ⌘N (new window) and ⌘Q (quit) are iTerm2's again. If you are used to the old shortcuts, add them back in `~/.config/claude-fleet/fleet.conf` on your own computer:

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
| `home` | From any screen: the home machine's command line ($HOME), no session or hub needed; again to come back | `⌘\` or `⌃\` | — |
<!-- /docs-gen:keys-extra -->

Without iTerm2 (for example Ghostty, or the system's own Terminal) ⌘ keys never reach fleet; open the panel with `F12` or `⌃] p` (⌃], then p). In iTerm2, F12 does not open the panel: it stays the session's.

## Saying something is wrong

- **Cannot connect, will not open**: first see [Troubleshooting](../troubleshooting.md). When you need someone to look, type `fleet doctor --json` in the terminal and send the output to your admin.
- **Common questions**: [FAQ](../faq.md).

A managed conversation without a repository can also switch to Codex from the list menu. Finish its current turn first. For native scheduled tasks, the panel asks the source to verify its current tasks and prepare handoff notes before switching. The source keeps running during preparation; missing sign-in, folder trust or task details are explained. Session-only patrols and one-shot reminders keep their own timing and expiry, and deleted tasks stay deleted. A durable Claude reminder in the project moves too: the source deletes it with its own scheduler only after Fleet has saved an inactive copy, and the copy goes live once the source has exited — so the reminder arrives once, on time, in the switched conversation. If the source cannot do that itself (for example it is out of quota), the switch takes the reminder only while no other Claude could be rewriting that project's task list; otherwise it explains which process is in the way and the original conversation and reminders keep running. You do not need to find or export JSON. A trusted node fills a missing HOME trust entry while respecting explicit distrust and pre-trust opt-out. Unsent input remains a draft.

For accepted remote tasks, Fleet verifies the selected agent before delivering the first input. If launch verification fails or the connection loses its receipt, Fleet keeps the task for recovery instead of choosing another agent or starting it again. A resume keeps the original conversation. An explicit agent switch starts a new attempt only after the source has stopped; an uncertain switch needs recovery before another attempt.

## Webchat connections

Webchat goes through the hub to your home node. The hub keeps one connection to your node open, so each request is a single round trip rather than a fresh connection. The conversation still runs only on your home node, with the same conversation and quota rules; the local page works as before.

If the connection drops after submission, the page reloads the conversation and says that the message may already have arrived. Review the recovered conversation before retrying. Messages, stop requests and answers are never sent again automatically.

The hub keeps a copy of your conversation in China (your words, the replies' text and one line per tool step; never a tool's output), encrypted and readable only by you. The chat shows this copy first, marked "Syncing", and replaces it with your home node's answer, marked "In sync"; while your node is out of reach you can still read the history ("Syncing · your machine is out of reach"). A copy not refreshed for 90 days is deleted; you can turn it off under Settings → Conversation history, which deletes it at once.
