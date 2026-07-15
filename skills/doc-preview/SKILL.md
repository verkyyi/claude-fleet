---
name: doc-preview
description: Render a Markdown document to GitHub-styled HTML and host it on this machine's Tailscale tailnet URL so the user can read it in a browser before committing. Use after writing or substantially editing a Markdown doc the user may want to preview — a guide, README, design doc, runbook, report, or research writeup — especially when they ask to "preview", "share", "host", or "see" a doc. Multi-session safe: shares append to one fixed URL. Personal to this machine's tailnet (the host is derived from tailscale at runtime).
---

# doc-preview — host Markdown docs on a fixed tailnet URL

<!-- fleet skill -->

Use this whenever you have written or meaningfully edited a Markdown document and the user
would benefit from reading the rendered result (not raw `.md`) in a browser before commit.

## How it works

`share.sh` renders the given Markdown file(s) into GitHub-styled HTML (client-side `marked`
+ `github-markdown-css`, so **no npm install is needed**), serves them from one shared
directory via a loopback `server.py` (a `http.server` + a tiny control API), and fronts it
with `tailscale serve` (HTTPS on the tailnet). The viewing browser needs internet for the CDN libs.

**Multi-session safe — this is the key property.** Every share **appends** to one shared
collection behind a **single fixed URL**. A new share never removes other docs and never
changes the URL. The root page (`/`) lists everything currently shared, across all sessions
(each row shows the title, source path, session label, and time). So multiple concurrent
Claude sessions can each share docs and they all show up in one list.

## Usage

Add doc(s) to the shared list (paths relative to the repo or absolute):

```bash
~/.claude/skills/doc-preview/share.sh doc/开发与运维指南.md README.md
```

Output and what to relay:
- **Single doc shared** → prints `READY <direct doc URL>` + `INDEX <root list URL>`.
  **Relay the `READY` direct URL** (it opens the doc itself); mention the index only if useful.
- **Multiple docs shared** → prints `READY <root list URL>` + one `ADDED <direct URL>` per doc.
  **Relay the `READY` index URL** (it lists all of them).

In both cases the `READY` line is the primary URL to give the user.

Other commands:

```bash
~/.claude/skills/doc-preview/share.sh --list              # show what's currently shared
~/.claude/skills/doc-preview/share.sh --refresh           # re-render ALL shared docs in place
                                                          #  (same URLs; picks up source-file edits
                                                          #   and template changes — no new entries)
~/.claude/skills/doc-preview/share.sh --remove <substr>   # drop entries matching id/title/path
~/.claude/skills/doc-preview/share.sh --publish   <id>    # expose ONE doc on the public internet
~/.claude/skills/doc-preview/share.sh --unpublish <id>    # take that doc back off the public internet
~/.claude/skills/doc-preview/share.sh --pubstatus <id>    # is this doc public? print its URL
~/.claude/skills/doc-preview/share.sh --stop              # tear down EVERYTHING (all sessions)
```

## Public sharing (per-document, opt-in)

By default everything is **tailnet-only**. A single document can be exposed on the public
internet via a per-doc **Tailscale Funnel path mount** at `https://<host>:<funnelport>/p/<id>/`
(funnel port is 443/8443/10000 — here `:10000`, since nginx holds 443/8443).

**This is normally driven by an in-page toggle, not the CLI.** Each doc page rendered over the
tailnet shows a **"公开链接" switch** in its header. Flipping it on calls the loopback control
API (`/_ctl/publish`), which mounts just that one doc on Funnel and shows the public URL with a
copy button; flipping it off unmounts it. The switch is a thin wrapper over `share.sh --publish/
--unpublish`, so you can also drive it from the terminal.

Two properties make this safe to expose:
- **Only opted-in docs are public.** Funnel mounts individual `/p/<id>/` paths; every other
  doc and the collection index return 404 publicly. The tailnet URL still shows the full list.
- **The toggle is tailnet-only.** The control API (`/_ctl/*`) is never Funnel-mounted, so it is
  unreachable from the public internet (404). A public visitor can read the one doc — nothing else.
- **No internal metadata leaks.** The Funnel mount targets a `/_pub/<id>/` route that strips the
  page header server-side, so the public bytes contain only the document — no index link, no
  session/date, and no source file path (not even in view-source). The tailnet `/d/<id>/` view
  keeps the full header.

`--stop` turns off all public mounts too. Freshly published URLs take a few seconds to warm up
(Funnel provisions the route) — an immediate curl may return a connection error; retry.

Set `DOC_PREVIEW_SESSION=<label>` to tag your session in the list (default: hostname). When
you share on behalf of a distinct task/session, pass a short label so the user can tell rows apart.

## Notes for the agent

- Run `share.sh` via the Bash tool and surface the `READY` URL in your reply.
- **Prefer adding over resetting.** Just call `share.sh <files>` — it reuses the running
  server and existing tailnet route, so the URL stays fixed and other sessions' shares survive.
  Only use `--stop` when the user wants to tear down all sharing (it removes every session's docs).
- Re-sharing the same file adds a **new** entry (a fresh snapshot); it does not dedupe. If the
  user re-shares an updated doc and wants the old row gone, `--remove <substr>` the stale one.
  If the doc was edited in place and the user just wants the SAME URL updated, use `--refresh`.
- The doc page is reading/print-first by design: GitHub-styled, auto light/dark, print-friendly
  tables. The only interactive control is the header **"公开链接" public-link switch** (tailnet
  view only); don't add other UX chrome (filter/sort/theme toggles).
- On error, read the printed message (usually: tailscale logged out, HTTPS certs not enabled, or
  — for `--publish` — the Funnel node attribute not granted in the tailnet ACLs) and tell the fix.
- Override the static server's starting port with `DOC_PREVIEW_PORT=NNNN`.
- By default this serves over the **tailnet only** — only the user's tailnet devices can reach it.
  A doc goes public **only** when the user flips its "公开链接" switch (or you run `--publish` at
  their request); see "Public sharing" above. Don't publish a doc unless the user asks. The URL is
  a live preview (only while this machine is up and serve is active), not durable hosting.
- Note: port 443 (and 8443) on this machine's tailnet IP are held by a local nginx, so the
  skill auto-falls back to a free HTTPS port (e.g. `:8446`). That's expected.
