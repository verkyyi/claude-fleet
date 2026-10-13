# Self-host · Quickstart

Goal: fleet installed on one computer of your own and your first session open, in about 10 minutes. This road needs no hub; when you later want to connect several machines or create accounts for colleagues, see [Install and deploy](install.md).

## What you need

- A macOS or Linux computer with internet access and a terminal (on a Mac, iTerm2 is recommended).
- A Claude subscription (Pro / Max / Team), or a ChatGPT subscription (for Codex). You sign in with the subscription; no API key is needed.
- The Claude Code command line `claude` (or the Codex command line `codex`) installed and signed in once with your subscription.
- For sessions that open pull requests themselves: `gh` installed and `gh auth login` run once. If you only chat and touch no code repository, you can skip it for now.

The install script brings its own tmux; there is nothing to install first.

## 1. Install

```sh
curl -fsSL https://raw.githubusercontent.com/verkyyi/claude-fleet/stable/bin/fleet-install.sh | sh -s -- --no-hub --host
```

- `--no-hub`: this computer only, connected to no hub (local mode).
- `--host`: this computer runs sessions itself (host). Without it you can turn it on later with `fleet host on`.

Once installed, the command is at `~/.local/bin/fleet`. If the terminal says it cannot find `fleet`, open a new terminal window and try again.

When it is done it opens the client right in this terminal. Where there is no terminal (a pipe, CI, a remote script) it says 「没有终端，跳过打开客户端」 (no terminal, the client is not opened) and exits 0 — type `fleet` in a terminal later to open it.

Every argument and the environment variables for automation (`FLEET_INSTALL_HOST=0|1` is `--host`, `FLEET_INSTALL_HUB=0` is `--no-hub`):

```sh
curl -fsSL https://raw.githubusercontent.com/verkyyi/claude-fleet/stable/bin/fleet-install.sh | sh -s -- --help
```

## 2. Open the client

Type `fleet` in the terminal and press Enter.

The first time, the list is empty and says `No sessions — type a name` at the bottom.

## 3. Open your first session

1. Type a name, for example `hello`, and press Enter.
2. A new session opens on the right, with Claude Code in it. Tell it something, for example "hi, what can you do?".
3. When it replies, everything works.

## 4. Remember one key

**⌘P** (iTerm2; in other terminals **⌃Space** or **F12**) opens the panel: every session is here — pick a row to switch to it; write a sentence on the top line and it becomes a new task for a new session.

Closing the terminal window does not stop your sessions; type `fleet` next time and everything is where you left it. To quit the client altogether, use `fleet quit` (the sessions keep running).

## 5. Let sessions work in a code repository (optional)

In ⌘P choose **Add a repo…** and fill in `<owner>/<repo>`. The repository goes to `~/projects/<repo>`; from then on, pick it when you start a session, and the session changes code and opens pull requests in its own copy, never touching your main checkout.

## Next

- Everyday use: [Everyday use](../member/usage.md)
- Connecting several machines, running your own hub, creating accounts for colleagues: [Install and deploy](install.md)
- Stuck: [Troubleshooting](../troubleshooting.md)
