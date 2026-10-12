# FAQ

Questions are written on this page only. The FAQ on the website's front page, the structured data for search engines and `llms.txt` are all generated from it; the questions marked for the site appear on the front page word for word.

## The basics

### How is it different from installing Claude Code myself?
<!-- faq: site -->
It is the same official Claude Code; fleet sets up the machine, the skills and publishing, gives each task its own session, and keeps it running when you close your laptop.

### Can I use it without coding?
<!-- faq: site -->
Yes. Say what you want in plain words; changing code and opening pull requests is optional, and chatting, pages and documents work too.

### Do I need my own Claude subscription?
<!-- faq: site -->
Bringing your own is optional: use the subscription we provide, or connect your own Claude or ChatGPT subscription; either way you sign in with the subscription and need no API key.

### What is the difference between hosted and self-hosted?
<!-- faq: site -->
Hosted means we run a hub just for your company and you only connect subscriptions and invite colleagues; self-hosted means you install the same open-source software on your own machines, so the hub, the machines and the data stay with you.

### Where do my code and files live? Are they safe?
<!-- faq: site -->
They live on the machine that runs your sessions, in your own OS account that nobody else can read; subscription keys are kept by the hub and never enter a session, and actions are logged.

### Does it work offline?
Sessions need to reach Claude's or ChatGPT's service to work; a self-hosted single computer needs no hub, and no GitHub either.

### Is this an Anthropic product?
<!-- faq: site -->
No. fleet is an independent open-source project (MIT) that runs the unmodified official Claude Code; Claude is a trademark of Anthropic.

## Using it

### How many sessions can one computer run?
There is no fixed limit by default: before a new session starts, fleet checks how much memory is left and how busy the machine is, and a session that does not fit waits; running sessions are never touched. For a hard limit, set `FLEET_GLOBAL_MAX_SESSIONS` in the configuration.

### If I close the terminal, do my sessions keep running?
Yes. Sessions run on the machine, not in your terminal; type `fleet` again and everything is where you left it. `fleet quit` closes only the client.

### Can I use it without GitHub?
Yes. Sessions that only chat or make pages and documents do not need GitHub; to let a session change code in a repository and open pull requests, install `gh` and run `gh auth login`.

### A session stopped on a question. What now?
It is most likely waiting for your answer (pick an option, approve an action). The ⌘P panel lists those sessions under "Waiting on you"; select one to see its question.

## Self-hosting

### What is the least I need to self-host?
One macOS or Linux computer, a Claude or ChatGPT subscription, and the `claude` or `codex` command line signed in once. One computer needs no hub; the [self-host quick start](self-host/quickstart.md) gets you to a first session in about ten minutes. <!-- docs-links-ok: docs-build.sh writes the en page while it is pending -->

### When do I need my own hub?
When you want to connect several machines, invite colleagues, or watch sessions from the web console or a phone. The hub is one program on one port that stores its data in SQLite or Postgres; see [Install and deploy](self-host/install.md). <!-- docs-links-ok: docs-build.sh writes the en page while it is pending -->

### Does a self-hosted hub show the website?
No. A self-hosted hub opens straight into the console; the website runs only on our own hub.

### How do I upgrade? Does it interrupt running sessions?
Machines and clients follow the stable release: `fleet update` catches up at once, and they catch up by themselves anyway. A switch replaces the programs and background services, never a running session.

### How do I find out what is broken?
Run `fleet doctor` first; what each line means and what to do when it is red is in [Troubleshooting](troubleshooting.md). To have someone else look, `fleet debug report` sends the diagnosis to the hub and gives you a short link. <!-- docs-links-ok: docs-build.sh writes the en page while it is pending -->
