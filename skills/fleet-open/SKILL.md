---
name: fleet-open
description: Open a page, report, PR, local dev server or file on the OPERATOR's own computer (the iTerm2 they SSH in from) — never on this machine. Use whenever the operator should look at something in a browser — a doc-preview page, a GitHub PR or issue, a `localhost`/`127.0.0.1` dev server or preview running here, a report — or open a file. Never run `open <url>` / `open <file>` from a fleet session: it opens on the Mac mini's own screen, where nobody is sitting.
---

# fleet-open — show the operator a page on THEIR computer

<!-- fleet skill -->

The operator reads this machine over SSH from iTerm2. `open <url>` here pops the page up on
the mini's own screen, which nobody is looking at. `fleet-open` sends it down the SSH
connection the operator already has, to their iTerm2, whose fleet script (issue #1380)
opens it in their browser:

```bash
~/.claude/fleet/bin/fleet-open.sh https://github.com/owner/repo/pull/12   # any URL
~/.claude/fleet/bin/fleet-open.sh :5173/                                  # a server HERE, by port
~/.claude/fleet/bin/fleet-open.sh http://localhost:3000/dashboard         # same thing
~/.claude/fleet/bin/fleet-open.sh report.pdf                              # a file → their ~/Downloads
~/.claude/skills/doc-preview/share.sh --open report.md                    # host a doc + open it
```

A page served on THIS machine (`:port`, `localhost`, `127.0.0.1`, or this machine's own
tailnet name) is opened through an SSH port forward the operator's side sets up — so a dev
server bound to `127.0.0.1` (as it must be, issue #1154) works without exposing anything,
and without a tailnet on their side. Everything else is opened as is.

## What it prints — relay it

One line on stdout:

| result | meaning | what to tell the operator |
|---|---|---|
| `sent:iterm2` | written to the iTerm2 they are using | "opened in your browser" — if nothing opened, their side (#1380) is not installed; give them the URL |
| `sent:tunnel` | their reverse-tunnel opener (`open-url.sh`, port 2226) took it | "opened in your browser" |
| `fallback:popup` | no iTerm2 / tunnel: a popup with the URL, also copied to their clipboard | "the link is in a popup and on your clipboard" |
| `fallback:path` | a file fleet-show could not send (`PATH …` line above it) | give them the path |

Why it fell back is on stderr (e.g. the active client is not iTerm2). A loopback page that
falls back also names the `ssh -L <port>:127.0.0.1:<port>` the operator would need — the
popup URL `http://127.0.0.1:<port>/…` means nothing on their computer without it.

## Rules

- **Never `open`** a URL or file from a fleet session. Use `fleet-open`.
- **Docs to READ** (Markdown / HTML) still go through doc-preview — `share.sh --open <file>`
  hosts it and opens it in one step (add `--local` when there is no tailnet).
- **Images / PDFs to LOOK at** can also go through `fleet-show.sh` (`--inline` draws an image
  in the terminal); `fleet-open <file>` is the same download.
- **Never print or log the secret** (`~/.config/claude-fleet/open.secret`, 0600). It is what
  stops any other text printed to the operator's terminal from opening URLs on their machine.
- `--print` shows the payload JSON without sending anything — use it to check a rewrite.
- `fleet-doctor`'s `open` line shows whether the secret exists and the last result.
