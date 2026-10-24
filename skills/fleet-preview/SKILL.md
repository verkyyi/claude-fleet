---
name: fleet-preview
description: Give the person a private live link to a dev server running in this Task — the web app, API or docs site you are working on, with hot reload — that they can open on their phone, on the Task page, or from any browser after signing in. Use when they ask to see / try / preview / 预览 / 看一下 the app, "send me a link", "open it on my phone", or when a UI change is ready to look at. Covers Vite (React, Vue, Svelte), Next.js, Express / plain Node, FastAPI / uvicorn, Flask, Django and Rails. For a quick look on the computer they are at right now, the fleet-open skill is faster.
---

# fleet-preview — a private link to the dev server, hot reload included

<!-- fleet skill · owner: worker -->

The preview is a private HTTPS address on the hub, `https://<id>.<preview domain>`. Only
the Task's owner can open it, after signing in. It reaches the server running in this
session over the node's own connection. There's no port forward, tunnel or public port.
HTTP, SSE and WebSocket all pass through, so the framework's own hot reload works there
as it does on localhost. It is **one call**:

```
mcp__fleet__preview  action: dev  command: "npm run dev"
```

What happens, so you can explain it:

- The command runs in the background, in this session's directory (`cwd` to change it),
  with `PORT` and `HOST=127.0.0.1` set. Any `{port}` in it is replaced with the same port.
- The tool finds the port the command's **own processes** listen on, even if it ignored
  `PORT` (Vite's 5173), and forwards the preview to it. A port held by anything else on
  the machine is never forwarded to: the preview answers 503 instead.
- It registers the preview, renews the 2-hour lease while the command runs, and closes it
  when the command ends.
- It waits up to 30 s for the server and returns `url`, `ready`, `log` and the last
  `output`.

## Steps

1. **Pick the road.** Ask `mcp__fleet__where` where the person is. On a phone or iPad,
   or for a link they keep and open again later, use this preview. At their own
   computer with nothing else needed, `mcp__fleet__open` with `:port` is quicker (no
   sign-in, see the fleet-open skill); offer the preview when they want a link.
2. **Check the recipe below** for the framework. Most need nothing. A server with a host
   check needs one setting, read from `FLEET_PREVIEW_HOST`.
3. **Start it:** `mcp__fleet__preview` `action: dev`, `command: …` (`name: api` for a
   second server beside the first; one run per name).
4. **Read the answer.**
   - `ready: true`: give the person the `url`, and say it opens after they sign in as
     the Task's owner.
   - `running: false`: the command ended. Its `output` says why: fix it and run again.
   - `ready: false`, still running: it is still starting (a first `npm install`, a
     large build). Read `log` again shortly; the URL already answers 503 until it's up.
5. **Stop it** when the work is done or they're finished looking:
   `mcp__fleet__preview` `action: stop` (`name` if not `dev`). Closing the Task page's
   preview only drops the link; `stop` ends the server too.

`keep: true` leaves the preview registered when the command ends, so the next `dev` with
the same `name` gets **the same URL** back. Use it when restarting the server often
during a session.

## Recipes

Verified through this road: **Vite 8** and **Next.js 15**, hot reload included. The
others follow from each framework's own documented settings.

| Framework | `command` | Also needed |
|---|---|---|
| Vite / React / Vue / Svelte (`npm create vite`) | `npm run dev` | nothing: the host check is passed through `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS`, and HMR follows the page's own address |
| Next.js | `npx next dev -H 127.0.0.1` | nothing (it reads `PORT`; `-H` keeps it off the LAN) |
| Express / plain Node | `node server.js` | listen on `process.env.PORT`, host `127.0.0.1` |
| webpack-dev-server / Create React App | `npm start` | a host check: `allowedHosts: [process.env.FLEET_PREVIEW_HOST]` in the dev-server config; CRA: `DANGEROUSLY_DISABLE_HOST_CHECK=true npm start` |
| FastAPI / Starlette | `uvicorn app:app --reload --uds {socket}` + `unix: true` | nothing (the socket is made private for you); or `--host 127.0.0.1 --port {port}` without `unix` |
| Flask | `flask run --debug --host 127.0.0.1 --port {port}` | nothing |
| Django | `python manage.py runserver 127.0.0.1:{port}` | `ALLOWED_HOSTS.append(os.environ.get('FLEET_PREVIEW_HOST', ''))` and, for forms, `CSRF_TRUSTED_ORIGINS = ['https://' + os.environ['FLEET_PREVIEW_HOST']]` when it is set |
| Rails | `bin/rails server -b 127.0.0.1 -p {port}` | `config.hosts << ENV['FLEET_PREVIEW_HOST'] if ENV['FLEET_PREVIEW_HOST']` in `config/environments/development.rb` |
| A static folder | `python3 -m http.server --bind 127.0.0.1 {port}` | nothing (no reload: the person refreshes) |

A server that **pins its HMR to a fixed address** (Vite `server.hmr.clientPort` /
`host`, webpack `client.webSocketURL`) breaks reload through the preview: remove that
setting, or set the port to 443 and the host to `FLEET_PREVIEW_HOST`. A server-side
reload (`uvicorn --reload`, `flask --debug`) restarts the server only; the page reloads
when the person refreshes.

## What it says, and what to do

| Answer or symptom | Meaning | Do |
|---|---|---|
| `preview requires a verified worker credential and its current Hub Task` | this session is not a Task's session (or is too old to carry its credential) | use `mcp__fleet__open` `:port` instead; a Task session can preview |
| `already running` | a run with that name is up | `stop` it first, or another `name` |
| 403 / `Blocked request` / `Invalid Host header` / `DisallowedHost` in the page | the framework's host check | the recipe's setting, then `stop` + `dev` again |
| 503 `the dev server is not listening yet` | nothing of the command's listens (yet) | read `log`; a note there names the port it saw. A fixed port it ignores PORT for: `port: N` |
| `note: it listens on every interface` in `output` | the LAN can reach it too | bind it to 127.0.0.1 (the recipe's flag) |
| `port N is already held by another process` | `port` names a port something else holds | not yours: the preview refuses it; let the server take `PORT` instead |
| 429 / a limit | three previews per account | `mcp__fleet__preview` `action: list`, then `close` (or `stop`) the old ones |
| page loads, hot reload never connects | HMR pinned to localhost or a fixed port | the HMR note above the table |
| `managed login enrollment required` | this login is not bound for previews | the operator binds it (docs/dev/PRIVATE-PREVIEWS.md); meanwhile use `mcp__fleet__open` |

Service Workers are switched off in previews: a PWA's offline mode can't be tried this
way.

## 运营者：在自己的终端里

From a person's own shell on the machine, the same road is one command; it stays in
the foreground, prints the URL, and Ctrl+C stops the server and closes the preview:

```sh
fleet preview dev -- npm run dev
fleet preview dev --name api --keep --unix -- uvicorn app:app --reload --uds '{socket}'
~/.claude/fleet/bin/fleet-preview.py dev -- npx next dev -H 127.0.0.1   # where `fleet` is not on PATH
```

It still needs a Task session's credential (the environment of a Task's pane).
`fleet preview register|list|renew|close` remain for a server that opens its own socket
in `~/.fleet-preview/`.
