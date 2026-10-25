# Member · Quickstart

Goal: from the invite your admin sent to your own first session, in about 5 minutes. You need a Mac or Linux computer and its terminal (on a Mac, iTerm2 is recommended).

## 1. Install

Paste the line your admin sent you into the terminal and press Enter. It looks like:

```sh
curl -fsSL https://hub.example.com/i/<invite-code> | sh
```

It asks no questions, and opens the tokenman client when it is done.

## 2. Sign in

The first time it opens, it asks you to sign in:

1. A link or a QR code appears in the terminal. Open it in a browser, or scan it with your phone.
2. On the page, sign in with WeChat, email or GitHub, and choose **Confirm**.
3. Back in the terminal, `✓ 证书 · ✓ 已登记到入口` (certificate · registered with the hub) means you are in.

A sign-in lasts 12 hours, after which this computer renews it by itself; when it cannot, the client asks you to scan again.

## 3. Open your first session

1. Open the ⌘P panel, select **+ New session**, and press Enter.
2. Check the repository and agent; choose **No repo** when none is needed. Press Enter again to open.
3. Tell the new session what to do. When it replies, you are ready.

## 4. Remember one key

**⌘P** (iTerm2; in other terminals and on a phone **F12** or **⌃] p**) opens the panel:

- PIN comes first, ordinary tasks follow without a heading, and older records are under Earlier conversations; search includes folded history;
- select “+ New session” and press Enter to open its box: the repository and agent are already chosen, so Enter again opens it; then say what to do in the session;
- one slot marks `!` needs your answer, `◷` pending start, `↻` running, or `⟳` Loop, in that priority order; quiet rows leave it empty;
- Tab → **Stop (resumable)** directly requests a stop for the current session, keeping files and history. Pending requests without a running session cannot yet be cancelled here.

Closing the terminal window does not stop your sessions; type `fleet` in a terminal next time and everything is where you left it.

## Open a terminal in a desktop browser

Sign in to the portal and open a row in **Sessions** to see its **web conversation**. The task page offers details, messaging, and Stop for the current running session. Old `/app/s/<session>?view=term` links open the same conversation and explain that native terminal interactions continue in iTerm2. There is no task browser-terminal backup mode.

The separate **personal Shell** remains available at `/app/s/shell?view=term`. It is a command-line entry point, not another task-list view. After a network interruption it keeps the last screen, pauses input and retries the connection; uncertain input is never resent. Closing the page does not stop a running Shell or task.

**Cmd/Ctrl+P** still prints and **Cmd/Ctrl+W** still closes the browser tab. Use iTerm2 or another local terminal for native agent terminal interactions, port forwarding, file transfer and local sign-in callbacks.

## Next

When a web Claude session exhausts its subscription quota, it automatically
continues in Codex at a safe handoff boundary, with a brief notice. Unsent messages
return to the composer. If handoff is unsafe, the record stays available with a
recovery notice. Network errors, sign-in failures and stopping a turn do not switch
agents. Trials can use Codex too; switching keeps the same budget and trial clock.

- Everyday use and checking your own quota: [Everyday use](usage.md)
- It will not open or connect: [Troubleshooting](../troubleshooting.md)
