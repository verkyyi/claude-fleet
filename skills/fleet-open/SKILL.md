---
name: fleet-open
description: Open a page, report, PR, local dev server or file on the OPERATOR's own computer (the iTerm2 they SSH in from) — never on this machine. Use whenever the operator should look at something in a browser — a doc-preview page, a GitHub PR or issue, a `localhost`/`127.0.0.1` dev server or preview running here, a report — or open a file. Never run `open <url>` / `open <file>` from a fleet session: it opens on the Mac mini's own screen, where nobody is sitting.
---

# fleet-open — show the operator a page on THEIR computer

<!-- fleet skill -->

**Wherever this session runs, it goes to the device the operator is using** (issue #1717):
`fleet-open` asks `fleet-client-where.sh`, and when their `fleet` client holds the hub's
lease the page goes to that client through the hub — a page on THIS machine's loopback is
forwarded over the client's own ssh first. The terminal road below is what it falls back to
when nobody is connected.

The operator reads this machine over SSH from iTerm2. `open <url>` here pops the page up on
the mini's own screen, which nobody is looking at. `fleet-open` sends it down the SSH
connection the operator already has, to their iTerm2, whose fleet script (issue #1380)
opens it in their browser. It is a call to the fleet's tool service (issue #1811) —
**`mcp__fleet__open`** (`target`) in Claude, the same `open` tool on a Codex session's
`fleet` server:

| `target` | what opens |
|---|---|
| `https://github.com/owner/repo/pull/12` | any URL |
| `:5173/` | a server HERE, by port |
| `http://localhost:3000/dashboard` | same thing |
| `report.pdf` | a file → their ~/Downloads |

A doc to host and open in one step: `~/.claude/skills/doc-preview/share.sh --open report.md`.

A page served on THIS machine (`:port`, `localhost`, `127.0.0.1`, or this machine's own
tailnet name) is opened through an SSH port forward the operator's side sets up — so a dev
server bound to `127.0.0.1` (as it must be, issue #1154) works without exposing anything,
and without a tailnet on their side. Everything else is opened as is.

## What it prints — relay it

One line in the tool's output — a RECEIPT, not a send (issue #3538): it waits a few
seconds (`FLEET_OPEN_ACK_WAIT`, 12) for the far side to say how it went.

| result | meaning | what to tell the operator |
|---|---|---|
| `opened` | the far side said it opened it: their client through the hub (#1717), their `fleet` thin client's loop (here, or through the home machine they watch this one from — 「经 mini2」), or this very screen | "opened on your <device>" (stderr names it) |
| `failed:<why>` (exit 4) | the far side said it could not (no browser, a port busy, the forward refused, no thin client on the home) | say why, and give them the link |
| `unconfirmed` | handed over, but no receipt within the wait — or a road that has none yet: the iTerm2 escape (#3540), a proxy window, open-url.sh's tunnel / clipboard; a phone's link on its bottom bar | "I sent it but cannot confirm it opened — the link is …" (stderr gives it) |
| `failed:…` (exit 2) | a file fleet-show could not send (`PATH …` line above it) | give them the path |

Which road it took and why is on stderr. A page on THIS machine never needs a tailnet on
their side: its loopback port is forwarded over their own ssh — through the home machine
too, whose link to this one carries it.

## Rules

- **Read where the operator is first** — `mcp__fleet__where` (issue #1716, the one reader): which device and terminal, and its `能：` — `打开网页`
  (the client runs on their computer), `给链接` only (a phone / iPad at the far end of an
  ssh: give them a link they can tap, tailnet address first), `iTerm2`. Never guess it.
- **Never `open`** a URL or file from a fleet session. Use `fleet-open`.
- **Docs to READ** (Markdown / HTML) still go through doc-preview — `share.sh --open <file>`
  hosts it and opens it in one step (add `--local` when there is no tailnet).
- **Images / PDFs to LOOK at** can also go through `mcp__fleet__show` (`inline: true` draws
  an image in the terminal); `open` with a file is the same download.
- **Never print or log the secret** (`~/.config/claude-fleet/open.secret`, 0600). It is what
  stops any other text printed to the operator's terminal from opening URLs on their machine.
- `fleet-doctor`'s `open` line shows whether the secret exists and the last result.

## 排障

The script behind the tool is `~/.claude/fleet/bin/fleet-open.sh <url | :port[/path] | file>`
(`fleet-client-where.sh`, `fleet-show.sh` beside it) — run it by hand only when the session
has no `fleet` tool, or with `--print` to see the payload JSON without sending anything.
