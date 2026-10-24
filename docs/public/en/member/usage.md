# Everyday use

This page is about every day: one key opens the panel, where you open sessions, see how they are doing and answer their questions; and how to say when something is wrong. Connecting from a computer or phone has its own page: [Connecting from a computer or phone](connect.md). Using it for the first time, follow [Member · Quickstart](quickstart.md) to your first session.

Remember one sentence: **sessions run on Tokenman's machines, not on your computer.** Close the terminal, shut the laptop, go offline — sessions keep working; come back, type `fleet`, and everything is as you left it — you land on the session you looked at last; if it has closed, ⌘P's list opens with the cursor on your most recently active session (Enter goes back to it), and only when you have no session on any machine is a new one opened (setting `FLEET_VIEW_LAND`: `panel` default · `last` straight back to the most recent · `new` a new one every time).

## One key: the panel

Everything starts from one key. The tables below are generated from Tokenman's key configuration, so when a default key changes, this page follows:

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
| — | Rows of the panel (pick one, ↵ — or type its name): + New session · $ Shell (this machine's shell, in your home directory) · ⏏ Quit Tokenman (sessions keep running) |
<!-- /docs-gen:keys -->

**The top line is the session's; messages get a row of their own.** The 看台's top line says the session only: its state, title, change number and quota. Whatever Tokenman has to tell you — a session asking you, stuck or done, an alert, a result nobody took, a passing notice (e.g. 「暂停开新：内存紧张」) — goes on a row **under** it, there only while something is unseen: the newest on the left, 「✦ 3 · ⌘P」 on the right. An error (red ✖) and a result nobody took (yellow ✓) stay until you have seen them; a warning (yellow ▲) fades after 6 seconds, a note (grey ∙) after 3. Once you have seen everything the row folds away. Click the row, or open ⌘P's first row **✦ Messages** (or type 消息 / message in ⌘P), for all of them, grouped: ↵ reads one, g goes to its session, r marks it read, f hands a result nobody took to the orchestrator. Another home shows the same messages and count. `fleet notices` on your computer's command line prints them too.

The panel looks roughly like this (sample data). ↑↓ follows the visible order. Needs attention has its own entry; PIN keeps pinned sessions above ordinary tasks. Ordinary and earlier conversations each sort by their latest turn activity, newest first. A new reply moves an older conversation up within its section. PIN keeps its pinned order; status refreshes alone do not reorder rows.

```text
  › Search sessions
  ✦ Messages
  + New session
  $ Shell
─ PIN
  ↻ K3F9     Codex   Fix export timeout          web-app
  ⟳ A7P4     Claude  Check service availability  ops
  ! B8D2     Claude  Login page redesign         web-app
  ◷ C9W1     Codex   Add API tests               api
    D2R6     Claude  Upgrade dependencies        web-app
  ▸ More sessions
  ⇄ Language / 语言
  ⏏ Quit Tokenman (sessions keep running)
  ↵ go  Tab act  ↑↓ pick  ? legend  esc close
```

### Open a session

- **Open a new session**: pick “+ New session” and press Enter (at the top of the list, under Messages) to open the “New session” box: three items only — “Repo ‹›”, “Agent ‹›” and “Open ↵” — already chosen, with the cursor on “Open”, so another Enter opens it. To change one: ↑↓ or Tab moves between items, ←→ changes the repository or agent (“No repo” when you need none), and Enter on a value goes back to “Open”. The defaults: the repository of the session you are looking at (when it has none, the one you chose last time — “No repo” counts), and the agent that repository last opened with; `⌘N` opens this box directly, Enter then opens the session, Escape closes it. There is nothing to write — say what to do inside the session once it opens. On “Open” the new session's window is in front of you at once and takes typing straight away: while the session still starts behind it, what you type is kept — a line you press Enter on is queued and sent the moment the session is up, an unsent line goes into its input box; if it cannot start, the reason is written in that window (Escape twice closes it). After your first message, the top bar, list row and task record use that message's first line as the title (up to 30 characters). This also applies to tasks addressed by short code; later messages do not rename it again.
- **Switch sessions**: type part of a title or ticket number, select a session with ↑↓, and press Enter.

The actions page, a question such as a rename, and the new-session box are whole pages: the list area is replaced, the top line names what it is about (the session, or “+ New session”), and below it one item a line — ↑↓ to pick, ↵ to run; there is no floating box. Escape goes back a level (from a rename to the actions page, then to the list), the list keeping its selection; another Escape closes the panel. Click to select a row, double-click to enter a session or open the new-session box; items on a page are clickable (click a repository or agent again for the next one, click “Open” to open).

The repository and agent chosen in the box are stored privately on this machine for this view, and come back the next time it opens. Resize keeps the selection, clamping scroll ranges only where necessary. At least 48 columns is recommended; narrower terminals show a notice and keep Tab and Escape working. Long content scrolls inside the page.


### Session states

The title counts open sessions and shows matched/total while searching. Folding and pinning do not change the total. Finished sessions whose window is still open count; folded-away ones do not. `+?` marks an unconfirmed remote count. Selection changes the background while status glyphs and name columns stay fixed. Ctrl+T still pins or unpins. The footer contains shortcuts, the optional legend and brief feedback.

The list initially shows **10 sessions**, including the current session and PIN. Ordinary sessions fold after **24 hours without Turn activity while not executing**. Current and pinned sessions remain visible; explicit pins may exceed the limit. “Needs attention (N)” previews up to 3 sessions; expand it to see the rest. “More sessions (N)” includes the running count: → expands, ← collapses, and Enter toggles it. Search includes folded sessions. Folding only changes presentation: it never stops, parks or deletes a session; background resource policies operate independently.

In the web app, **Settings → Session list** offers 5 / 10 / 15 visible sessions and 12 hours / 24 hours / 3 days / Off. These preferences follow your account to web and terminal. You can also run `fleet config session-list 10 24`; the second number is hours, with `0` disabling age folding. New Turn activity competes for visible places again. Reordering pauses during interaction, and refreshing never closes an expanded More section.

Rows keep the same columns: status slot · short code such as `K3F9` · agent · title · repository. Narrow terminals hide the repository first, then the agent. **All status symbols share one fixed slot on the left**:

| Symbol | Meaning |
|---|---|
| `!` | Needs your answer or approval; open the session to respond |
| `◷` | A start request exists, with execution not yet confirmed |
| `↻` | Running |
| `⟳` | An observed recurring plan is active; a one-shot reminder is not a Loop |

When several apply, the first in this table wins; other facts remain in the selected row's details. Quiet rows leave the slot empty, without done, failed, idle or exited icons. Results and errors remain available in details. Press `?` for the legend. A reserved record without an accepted start request is not pending, and missing Loop observations from older nodes are not guessed from a state name.

Questions, native state, pull requests, machines and configuration notices appear in the footer or details. Search still finds linked ticket numbers such as `4539` or `#4539`. Lost rows are dimmed and described as unknown; an empty status slot does not prove execution stopped.

### What you can do with a session

Pick a row and press **Tab** for its actions page: Enter, Open PR when present, Rename, Switch agent, Open in web, and **Stop (resumable)**. Unavailable actions are hidden or explain why. A digit runs an action, `[` `]` change its target, and Escape returns to the same list selection. Older conversations keep their history and restore actions; an exited agent with a window still open uses Enter to reach its recovery page. Use `⌃T` or the footer action to pin a row.

Stop directly requests that the current session stop, without a reap confirmation or waiting for its PR to merge. The web task page's Stop and `fleet close` use the same stop entry point, preserving files and history. Failures are reported; acceptance does not prove the remote process has exited. For a task explicitly waiting to start that has never opened a session, choose Cancel start in the terminal action page or web page, or run `fleet close <task code>`. If a session has opened, refresh and stop that session. Cancellation does not require the target machine to be online; stopping does not yet cancel every future automatic wakeup.

After stopping is confirmed, choose Continue task and then the original agent, Claude or Codex. Use `fleet continue T123` in the CLI, or explicitly select `fleet continue T123 --agent codex`. Continuation keeps the same task and history. Retry an unconfirmed request with its original agent choice; it cannot be replaced by a different start. If user credentials are missing, the command provides the task’s web link. Opening history does not start a session.

You can do the same from the terminal with commands (`<session>` can be part of a name or a `#ticket`; when it is not clear which one you mean, it lists the candidates rather than guess):

```sh
fleet ls                       # my sessions: name · ticket · machine · left · state · PR · reap policy
fleet ls --all                 # ended ones too
fleet open login               # open the client and switch to this session
fleet answer login keep        # answer its question without going in
fleet close report             # request a stop; keep files and history
fleet continue T123 --agent codex  # explicitly continue the same task with Codex
fleet quit                     # quit fleet (see below)
```

## Pasting images and dropping files

In the desktop Tokenman terminal, drop files or press `Ctrl+V` to paste a clipboard image. Tokenman uploads them and inserts their remote paths automatically, including multiple files. Ordinary text paste works as before.

Output and resizing continue while Tokenman prepares and uploads attachments. The top bar shows Preparing → Uploading (received bytes and total progress) → Confirming → Uploaded. Input is paused: text, Enter and further drops are discarded, never saved for later. `Ctrl+C` cancels only the upload and restores input without interrupting remote work. Success inserts the confirmed remote paths once, without pressing Enter. Failure, switching sessions or disconnecting inserts nothing; type again after input resumes.

Each operation allows 16 files: 10 MiB per image, 100 MiB per other file, and 100 MiB total. It times out after 120 seconds. If Tokenman cannot verify the current session, attachments fail visibly while ordinary text input remains available.

## Working in a code repository

For a task in a repository, the session changes **its own copy of the code** and touches nobody else's; when it is done it opens a pull request, merges it itself once the checks pass, and then tells you the result. Its row stays in place; read what changed on the PR.

You do not have to watch it. To change direction, open it and say so; to stop execution, use Stop. A question needing your answer is marked with `!`.

## Closing the computer, changing computers, watching on a phone

Sessions run on Tokenman's machines: close the terminal, shut the laptop, switch to another computer or open it on a phone — it is the same set of sessions. How to connect, and how to come back after closing: [Connecting from a computer or phone](connect.md).

## Task records: T numbers

Everything you hand over on the + New session line is first written down by Tokenman, numbered with a **T** (for example `T42`): your own words, which machine and which session it went to, and where it stands now.

- A task has this one number: it is yours, not a repository's. A task given a repository changes code and opens pull requests there — GitHub holds only the code and the pull requests, with no second ticket.
- The hub's **Sessions** page uses the same PIN, ordinary tasks and More sessions layout. Opening a row opens its web conversation; details keep the task description, native observations, PR and history. Task pages no longer offer a browser-terminal switch.
- Historical results remain in details, without a completed icon in the list. A missing session is not proof of completion; unknown observations are not proof of stopping. Failed reads preserve existing content and explain the problem; retrying a read does not start work.
- For native terminal interactions, open the task in iTerm2. The separate personal browser Shell remains available. Old task links containing `?view=term` open the same task's web conversation.
- Tell a colleague "the T42 thing" and they can find it by its code on the Sessions page.

### A design page first, then the task

With the fleet-epic plugin installed, say `/fleet-task-plan <subject>` in a session (for example "batch reports never reach me"). It first writes the matter up as one design page: what happens, why (the evidence folded underneath), goal and scope, the changes, what could go wrong, what you need to decide, and the proof it shipped. The page is private and pushed to your WeChat. Say what to change and it edits the same page; nod and it opens one task from the page, stamps the task's number at the top, and the task's session works from it.

## Reaping: when a session closes

Parking releases an idle agent process while keeping its window, identity, conversation and worktree. Speaking resumes the same conversation. Reaping closes the window only after recording resumable history; the worktree stays.

Background resource policies are separate from your explicit Stop request. New tasks use the same ordinary idle/park default (`idle:2h`), regardless of creator, interface or agent. PIN only orders the list. A missing result no longer triggers reminders or automatic closure.

For Hub-controlled tasks, automatic cleanup only parks safely: the task binding, window, history and worktree remain, while an acknowledged park releases the native process and running capacity. Existing policies such as `keep` and `merged` are preserved without bulk migration. Keep prevents automatic archival, allows safe parking, and never prevents your Stop request. Legacy parked retention still requires resumable history before closing a window. Older wrappers that cannot park do not count as released capacity. Explicit test probes retain their dedicated policy; title words never make an ordinary task a probe.

Settings: `fleet.session.park_idle` **5m**, `park_idle_unattended` **5m** (the conservative cache-measurement fallback; **1m** is configurable), `park_presence` **15m**, and `fleet.session.reap_parked` **3d**. Memory pressure may park earlier. Watched windows, drafts, active turns, open choice dialogs and background work hold parking. `fleet doctor --park` lists each window's origin, park/reap rule, next UTC deadline and hold reason.

The window's explanation line says why parking is held: someone is looking, a draft is in the input box, background work is running, a choice dialog is open, or an older wrapper cannot park. Doctor carries the same reason instead of promising a parking time that a protection condition has blocked.

Ask the session to change its automatic reap policy; the simplified Tab page no longer lists Reap policy. An existing keep remains effective, including after a historical result.

## Quota and usage

The line at the top of the panel is only about the session you are looking at: how much context is left and which model it uses (for example `62% left · Opus 5.5 · high`). Grey means the reading is more than 5 minutes old.

When the context is nearly full, a repository task's session hands itself off to a new session that carries on; in a blank session you can just say "hand off".

## Optional: your own keys for common actions

Tokenman uses one key, ⌘P (phone: `F12` or `⌃] p`); everything else is in the panel: New session, Shell and Quit Tokenman are rows of it — pick one and press ↵, or type a few letters ("shell", "quit") to land on it; quitting asks first. ⌘K (clear), ⌘T (new tab), ⌘N (new window) and ⌘Q (quit) are iTerm2's again. If you are used to the old shortcuts, add them back in `~/.config/claude-fleet/fleet.conf` on your own computer:

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
| `quit` | quit this client connection; sessions keep running on their machines; type fleet to open it again | `⌘Q` | `⌃] q` |
| `home` | From any screen: the home machine's command line ($HOME), no session or hub needed; again to come back | `⌘\` or `⌃\` | — |
<!-- /docs-gen:keys-extra -->

Without iTerm2 (for example Ghostty, or the system's own Terminal) ⌘ keys never reach Tokenman; open the panel with `F12` or `⌃] p` (⌃], then p). In iTerm2, F12 does not open the panel: it stays the session's.

## Saying something is wrong

- **Cannot connect, will not open**: first see [Troubleshooting](../troubleshooting.md). When you need someone to look, type `fleet doctor --json` in the terminal and send the output to your admin.
- **Common questions**: [FAQ](../faq.md).

A managed conversation without a repository can also switch to Codex from the list menu. Finish its current turn first. For native scheduled tasks, the panel asks the source to verify its current tasks and prepare handoff notes before switching. The source keeps running during preparation; missing sign-in, folder trust or task details are explained. Session-only patrols and one-shot reminders keep their own timing and expiry, and deleted tasks stay deleted. A durable Claude reminder in the project moves too: the source deletes it with its own scheduler only after Tokenman has saved an inactive copy, and the copy goes live once the source has exited — so the reminder arrives once, on time, in the switched conversation. If the source cannot do that itself (for example it is out of quota), the switch takes the reminder only while no other Claude could be rewriting that project's task list; otherwise it explains which process is in the way and the original conversation and reminders keep running. You do not need to find or export JSON. A trusted node fills a missing HOME trust entry while respecting explicit distrust and pre-trust opt-out. Unsent input remains a draft.

For accepted remote tasks, Tokenman verifies the selected agent before delivering the first input. If launch verification fails or the connection loses its receipt, Tokenman keeps the task for recovery instead of choosing another agent or starting it again. A resume keeps the original conversation. An explicit agent switch starts a new attempt only after the source has stopped; an uncertain switch needs recovery before another attempt.

## Webchat connections

When you open a session, the page first checks whether sending is available. You can draft while it checks or reconnects, then send after it recovers; drafts are never sent automatically. A read-only sign-in or an older session without web continuation remains read-only, with an explanation on the page.

Webchat goes through the hub to your home node. The hub keeps one connection to your node open, so each request is a single round trip rather than a fresh connection. The conversation still runs only on your home node, with the same conversation and quota rules; the local page works as before.

If the connection drops after submission, the page reloads the conversation and says that the message may already have arrived. Review the recovered conversation before retrying. Messages, stop requests and answers are never sent again automatically.

The hub keeps a copy of your conversation in China (your words, the replies' text and one line per tool step; never a tool's output), encrypted and readable only by you. The chat shows this copy first, marked "Syncing", and replaces it with your home node's answer, marked "In sync"; while your node is out of reach you can still read the history ("Syncing · your machine is out of reach"). A copy not refreshed for 90 days is deleted; you can turn it off under Settings → Conversation history, which deletes it at once.

## Private live development previews

When enabled by the deployment, the Task details show your running HTTP/API/WebSocket
applications under Live previews, including SSE and hot reload (HMR).
Opening a preview requires sign-in and the Task owner's identity. Disconnected nodes
show Offline. The default lease is two hours; renew or close it in Task details.
Closing disconnects active streams without stopping the application.

The usual way is to ask the Agent in the Task: "start the dev server and give me a
preview link". It calls the `preview` tool with `action: dev` and your dev command
(`npm run dev`, `next dev`, `uvicorn …`). The command runs in the background, and the
Agent hands you the URL once the server answers. The lease renews while it runs, and
`action: stop` ends both the server and the preview. From your own shell on that
machine, the same thing is `fleet preview dev -- npm run dev`, stopped with Ctrl+C.

The dev server keeps its usual loopback port. The preview forwards to that port only
while one of the command's own processes listens on it; a port held by anything else on
the machine gets a "not listening yet" answer instead. Vite and Next.js work as they
are, hot reload included. Frameworks that check the Host header (Django, Rails,
webpack-dev-server) need the preview's host name allowed. It is in the
`FLEET_PREVIEW_HOST` environment variable, and the `fleet-preview` skill gives each
framework's one line.

A server that opens its own Unix socket instead can be registered directly:
`fleet preview register app.sock`, `list`, `renew <id>`, `close <id>`, with the socket
in your own `~/.fleet-preview/` (directory 0700, socket 0600).

Each account gets up to three previews and 32 concurrent requests, including
WebSockets, independently of Task concurrency. Without an explicit, separate preview
domain, the feature shows as disabled.

Live previews serve running applications. Saved HTML/Markdown remains accessible
through the existing Space / LivePage entry. Trial accounts need an active managed
login and their own Task; chat-only trials without Task identity cannot register.
