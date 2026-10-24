# Dev server previews: copy-and-run examples

`fleet preview dev` (or the `preview` tool's `action: dev` from a Task session) runs a
dev server and gives it a private preview link with hot reload. The preview forwards
only to a port the command's own processes listen on. These folders are the smallest
apps that show it working. Each runs from a Task session's pane, or from an Agent
through `mcp__fleet__preview`.

| Folder | Run | Shows |
|---|---|---|
| [`vite/`](vite/) | `npm install`, then `fleet preview dev -- npm run dev` | zero-config Vite: the port is found, the host check passes, edit `src/message.js` and the page updates in place |
| [`fastapi/`](fastapi/) | `pip install 'uvicorn[standard]'`, then `fleet preview dev --unix -- uvicorn app:app --reload --uds '{socket}'` | a server on its own Unix socket (`--unix`): no TCP port at all |

The same through the tool, as an Agent calls it:

```
mcp__fleet__preview  action: dev  cwd: <this folder>  command: "npm run dev"
mcp__fleet__preview  action: dev  name: api  unix: true  command: "uvicorn app:app --reload --uds {socket}"
mcp__fleet__preview  action: stop  name: api
```

Other frameworks (Next.js, Express, Flask, Django, Rails, webpack) are one line each in
the `fleet-preview` skill's recipe table. `../private-preview/` is the hub's relay test
fixture (a Node / Express / Vite / Uvicorn server that opens its own socket), not a template.
