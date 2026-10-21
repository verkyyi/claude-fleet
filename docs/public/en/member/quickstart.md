# Member · Quickstart

Goal: from the invite your admin sent to your own first session, in about 5 minutes. You need a Mac or Linux computer and its terminal (on a Mac, iTerm2 is recommended).

## 1. Install

Paste the line your admin sent you into the terminal and press Enter. It looks like:

```sh
curl -fsSL https://hub.example.com/i/<invite-code> | sh
```

It asks no questions, and opens the fleet client when it is done.

## 2. Sign in

The first time it opens, it asks you to sign in:

1. A link or a QR code appears in the terminal. Open it in a browser, or scan it with your phone.
2. On the page, sign in with WeChat, email or GitHub, and choose **Confirm**.
3. Back in the terminal, `✓ 证书 · ✓ 已登记到入口` (certificate · registered with the hub) means you are in.

A sign-in lasts 12 hours, after which this computer renews it by itself; when it cannot, the client asks you to scan again.

## 3. Open your first session

1. The first time, the list is empty and says `No sessions — type a name` at the bottom.
2. Type a name, for example `hello`, and press Enter.
3. A new session opens on the right, with Claude Code in it. Tell it something; when it replies, everything works.

## 4. Remember one key

**⌘P** (iTerm2; in other terminals and on a phone **F12** or **⌃] p**) opens the panel:

- every session is here — pick a row to switch to it;
- select “⚡ New session” and press Enter to open its box: the repository and agent are already chosen, so Enter again opens it; then say what to do in the session;
- when a session stops to ask you something, its row is marked; switch to it and answer.

Closing the terminal window does not stop your sessions; type `fleet` in a terminal next time and everything is where you left it.

## Open a terminal in a desktop browser

Sign in to the portal, open Sessions, and choose **Terminal** on a running session
to open that session directly. **My Terminal** in the sidebar and Sessions header
opens your personal terminal. Ended sessions keep their **Resume** action.
The page is `/app/terminal`; old `/term?worker=…` links redirect here and keep the target.

A dropped connection (network, a hub update, your machine restarting, a phone in the background) is never given up on: the last screen stays, input pauses, and the page tries again at once when it is back in front or the network returns — always reconnecting to the same terminal. Uncertain input is never resent.
**Open shell** selects your persistent personal shell. Exiting a nested shell with `exit` or EOF returns to its parent. If the session you last viewed has ended, you land back in your personal terminal with a note; if the personal shell itself exited (or your machine's tmux went), the page opens a new personal terminal by itself — exited commands and workers are not restarted.
A session's terminal whose session ended takes you to your personal terminal; a session that restarted is connected as it is now. If your machine is offline or under maintenance, the page says so and connects as soon as it is back — no refresh needed.
The page you just opened or clicked back into uses the terminal; another page shows "open in another tab" — click it to bring it back. Only an expired login needs you to sign in again.
Closing the page preserves the running shell and session.

On nodes supporting browser terminals, **Fleet menu** or **Ctrl+] then p** opens
the native panel. **Open shell** switches to the shell; click again to return.
**Cmd/Ctrl+P** still prints, and **Cmd/Ctrl+W** still closes the browser tab.
The connection shows **Direct** or **Via hub**. Input is never replayed after a
disconnect; inspect an interrupted paste before typing it again.
Pages sent by a session appear as clickable links. Port forwarding, file transfer
and local sign-in callbacks require a local terminal.

## Next

- Everyday use and checking your own quota: [Everyday use](usage.md)
- It will not open or connect: [Troubleshooting](../troubleshooting.md)
