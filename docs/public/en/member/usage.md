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
⚡ Write a sentence, ↵ to hand it to a new session
Waiting on you 1
  ● Login page redesign   mac-a    asking: keep the old redirect?
Working 2
  ● Fix export timeout    mac-a    #128
  ● Weekly report data    linux-a
Just landed 1
  ✓ Upgrade dependencies  mac-a    PR #131 merged
▸ Ended (4)
↵ go  Tab act  ↑↓ pick  type to filter  ? legend  esc close  ↑ to ⚡
```

### Open a session

- **Hand over a new task**: open the panel, write a sentence on the ⚡ line at the top (for example "add a header row to the CSV export"), and press ↵. fleet records the task and opens a new session to do it; your sentence is the first thing the session receives. Press Tab first to pick which repository it works in, and whether Claude or Codex does it.
- **Open a blank session**: pick the "⚡ New session (blank)" row and press ↵. It is tied to no repository — good for asking questions, looking things up, or talking a request through first.
- **Switch to another session**: just type a few letters (name, machine and state are all searchable) and press ↵. ↵ without typing goes back to the session you looked at last.

### Session states

The panel groups sessions by what you should do:

| Group | Meaning | What you do |
|---|---|---|
| **Pinned** | Ones you pinned yourself | — |
| **Waiting on you** | The session stopped to ask you something, or is waiting for you to allow an action — or asked on its ticket and nobody has answered yet, even if it has stopped since; its words are on the next line | Switch to it and answer, or press Tab on its row → "Answer…" |
| **Working** | Doing it now | Nothing |
| **Waiting to merge / ship** | Done, its pull request not merged yet, or merged but not live; the row ends with the step: checks running · checks red · ready to merge · waiting for the release train · deploying | Usually nothing; when the checks are red, take a look |
| **Just landed** | The change has been merged into the repository | Take a look at the result |
| **Other** | Idle, or no state to read | — |
| **Ended** | Finished sessions: ones bound to no ticket, or whose ticket is closed and pull request merged more than a day ago; the ones still open first, the reaped ones under them, folded at the bottom | Still open: ↵ on the last row reaps them all; to carry on: pick it, ↵ "Restore" |

Each row ends with the machine it is on (`mac-a`) and its ticket number (`#128`) or PR. When a machine cannot be reached, a red bar appears across the top of the panel and its rows say "lost N min"; wait for it to come back — the sessions are not lost.

### What you can do with a session

Pick a row and press **Tab** for its menu: Enter · Shell in its directory · Open PR · Answer… · Send a message… · Rename… · Pin · Reap policy… · Stop (resumable) · Resume · Wake · Switch account… · Switch to Claude / Codex · Reap…. "Shell in its directory" opens on the machine the session runs on.

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

For a task in a repository, the session changes **its own copy of the code** and touches nobody else's; when it is done it opens a pull request, merges it itself once the checks pass, and then tells you the result. You see it under "Just landed" and read what changed on the PR.

You do not have to watch it. To stop it or change direction, switch to it and say so; when it is stuck it shows up under "Waiting on you".

## Closing the computer, changing computers, watching on a phone

Sessions run on fleet's machines: close the terminal, shut the laptop, switch to another computer or open it on a phone — it is the same set of sessions. How to connect, and how to come back after closing: [Connecting from a computer or phone](connect.md).

## Task records: T numbers

Everything you hand over on the ⚡ line is first written down by fleet, numbered with a **T** (for example `T42`): your own words, which machine and which session it went to, and where it stands now.

- A task in a repository also gets a ticket (a number like `#128`), and the panel shows the ticket number; one tied to no repository shows its T number.
- The hub's **Tasks** page lists all your task records; a record stays after its session ends.
- Tell a colleague "the T42 thing" and they can find it on the Tasks page.

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
| `new` | new session: a no-repo session on your home machine, the cursor in its input; with FLEET_COMPOSE=1 the writing area on the right | `⌘N` | `⌃] c` |
| `dispatch` | dispatch: a title + a repo (the last one used) + optionally Codex, ↵ files it and starts its worker; from any window, no model on the way | `⌘T` | `⌃] t` |
| `quit` | quit fleet: every process of the client on this computer goes (the list, the hub loop, the connections); the sessions keep running on their machines; fleet comes back | `⌘Q` | `⌃] q` |
<!-- /docs-gen:keys-extra -->

Without iTerm2 (for example Ghostty, or the system's own Terminal) ⌘ keys never reach fleet; open the panel with `⌃] p` or `⌃Space`.

## Saying something is wrong

- **Tell the maintainers in one sentence**: in any session type `/fleet-feedback` followed by what you want to say, for example `/fleet-feedback the panel opens slowly on my phone`. It first shows you what would be sent (what is public, what was masked), then asks whether to attach recent logs and the screen, and sends only once you confirm. You get a feedback number (starting with `F`), and the reply comes back into your session when it has been handled.
- **Cannot connect, will not open**: first see [Troubleshooting](../troubleshooting.md). When you need someone to look, type `fleet debug report` in the terminal: it hands a diagnostic bundle (keys removed) to the hub and gives you a short link — send the link to your admin.
- **Common questions**: [FAQ](../faq.md).

A managed conversation without a repository can also switch to Codex from the list menu. Finish its current turn first. For native scheduled tasks, the panel asks the source to verify its current tasks and prepare handoff notes before switching. The source keeps running during preparation; missing sign-in, folder trust or task details are explained. Session-only patrols and one-shot reminders keep their own timing and expiry, and deleted tasks stay deleted. A durable Claude reminder in the project moves too: the source deletes it with its own scheduler only after Fleet has saved an inactive copy, and the copy goes live once the source has exited — so the reminder arrives once, on time, in the switched conversation. If the source cannot do that itself (for example it is out of quota), the switch takes the reminder only while no other Claude could be rewriting that project's task list; otherwise it explains which process is in the way and the original conversation and reminders keep running. You do not need to find or export JSON. A trusted node fills a missing HOME trust entry while respecting explicit distrust and pre-trust opt-out. Unsent input remains a draft.
