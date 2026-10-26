# Hosted admin · Quickstart

Goal: with the hub we opened for you, connect a subscription, create an account for your first colleague, and have them open their first session. You only need a computer and a browser — no server of your own.

Below, replace `https://hub.example.com` with your hub's address (the one sent to you when it was opened).

## 1. Sign in to the hub

1. Open `https://hub.example.com/signin` in a browser.
2. Sign in the way you registered when the hub was opened: scan with WeChat, email, or GitHub.
3. After signing in you are in the console. The **Admin** group in the sidebar (Subscription pool, Service nodes & clients, Users…) is visible to admins only.

On the tokenman.io public portal, the homepage follows your browser language. The language link in the footer remembers your choice.

Sign in offers WeChat QR, email and GitHub; the homepage also offers access requests and a trial when available. Old portal bookmarks forward to the same page, while WeChat keeps its existing entry.

## 2. Install the client

Creating accounts and sending invites uses the `fleet` command. In a terminal on your own computer:

```sh
curl -fsSL https://hub.example.com/install | sh
```

When it is installed it opens `fleet` and asks you to sign in once (in a browser or by scanning with your phone, then choose **Confirm**).

## 3. Connect a subscription

Sessions use an AI subscription (Claude or ChatGPT): ours, or your own. The hub keeps the credentials for you and shares the quota out per person.

1. Open the **Subscription pool** page in the console. When you use the subscription we provide, it is already there from the day the hub was opened; to connect your own, add it as in [Subscriptions and quota](../admin/quota.md).
2. When you see the subscription and its 5-hour / 7-day quota, it is connected.
3. **Grant access**: a new user may use no subscription at all by default. After creating a colleague's account, open the **Users** page, choose them → subscription access, and pick "All subscriptions".

Add as many subscriptions as you have; when one is nearly out of quota, the hub moves on to the next.

## 4. Create an account for a colleague

The console's **Users** page → **Invite command**, or in a terminal:

```sh
fleet hub invite <their GitHub username>                  # make an invite
```

`fleet hub` needs your admin credential: after signing in to the hub in a browser, `export FLEET_HUB_SESSION=<value>` with the value of the `ccq_sess` cookie (details in the [Admin handbook](../admin/index.md)).

- An invite is valid for 7 days and can be used once; when it names a GitHub username, only that person can use it.
- When they sign in with the invite, the hub creates their account on a machine by itself — you do not create it separately.
- `fleet hub invite --list` shows every invite's state; `--revoke <id>` cancels one that has not been used.

Send them the install line it printed, which looks like:

```sh
curl -fsSL https://hub.example.com/i/<invite-code> | sh
```

From there they follow [Member · Quickstart](../member/quickstart.md).

## 5. Check that they got through

- They appear on the console's **Users** page, with subscription access granted.
- Their first session shows up in the console's session list.

## Next

- Removing accounts, changing quota, seeing who used how much: [Admin handbook](../admin/index.md)
- Common questions: [FAQ](../faq.md)
