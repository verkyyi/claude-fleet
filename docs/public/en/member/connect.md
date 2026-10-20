# Connecting from a computer or phone

Sessions run on fleet's devices, not on your computer or phone. Your computer and phone only open windows onto them: with the same account, whichever device you open it on, you see the same set of sessions. Every command you type in a terminal is on this page.

## On a computer (Mac or Linux)

**The first time**: paste the line your admin sent into the terminal and press Enter. An admin installing for themselves uses the hub's address followed by `/install`:

```sh
curl -fsSL https://hub.example.com/i/<invite-code> | sh     # member: the line in the invite
curl -fsSL https://hub.example.com/install | sh             # admin
```

When it is installed, fleet opens and asks you to sign in once: a link or a QR code appears in the terminal; open it in a browser or scan it with your phone, sign in with WeChat, email or GitHub, and choose **Confirm**. `✓ 证书 · ✓ 已登记到入口` (certificate · registered with the hub) means you are connected.

**Every day after that**: in the terminal, type

```sh
fleet          # open it, back to where you left off
fleet quit     # close only the window on this computer; sessions keep working
```

On a Mac, iTerm2 is recommended: ⌘P opens the panel; in other terminals use `⌃] p`. fleet takes that one key; everything else is in the panel.

## What happens when you close your computer

| What you did | Sessions | When you come back |
|---|---|---|
| Closed the terminal window, shut the laptop, went offline | Keep working | Type `fleet`, everything is where you left it |
| Chose "Quit fleet" in the panel, or typed `fleet quit` | Keep working (only the client on this computer quit) | Type `fleet` |
| Moved to another computer | Keep working | Install and sign in on the new computer (same account), type `fleet`: all your sessions are there |

One sign-in lasts 12 hours and this computer renews it by itself when it runs out; when it cannot, the client asks you to scan again.

## On a phone (iOS or Android)

On a phone, use **Termius** (on both iOS and Android) to connect to your own address; what you see is the same set of sessions as on your computer. It takes one setup, about 5 minutes:

1. Open the hub in a browser, sign in, and choose **Connect from a phone** in the navigation (the address is `https://<hub>/fleet/keys`, for example `https://hub.example.com/fleet/keys`).
2. Follow the page's six steps: install Termius → generate a key in Termius → paste the public key back on the page → add a host in Termius (address, port, username and key — each has a copy button on the page) → connect and trust the host key → once connected, press `⌃] p` to open the panel.
3. Your address looks like `<name>.<the hub's domain>` (for example `alice.fleet.example.com`) and is written on the page; use the port the page shows too.

After that, on the phone:

- Open the panel: `⌃] p` (Ctrl+], then p).
- On a narrow screen the panel fills the screen; tap a row to switch to it.
- New phone, or lost it: revoke that key on the hub's **My connection** page and it can no longer connect, at once.
