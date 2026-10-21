# Subscriptions and quota

Claude OAuth subscriptions do not require an account UUID. The hub periodically reads the five-hour and seven-day windows for each credential. Importing the same token twice counts once; replacing a token under the same name waits for a new reading. Account association is optional, and imports never borrow the importing machine's login identity. A failed read shows its reason and the observation time of that credential's last reading; an unread credential shows no quota.

Sessions use a Claude or ChatGPT (Codex) subscription. A subscription's sign-in credential exists only in the hub; a machine is lent a short-lived copy, renewed as it runs out, and members can never read the long-lived credential.

## Where subscriptions come from: either works

| | Use the subscription we provide | Connect your own subscription |
|---|---|---|
| Suits | Not wanting to buy and manage subscriptions | Already having Claude Pro / Max, ChatGPT Plus / Pro |
| Who adds it to the subscription pool | Us | You |
| Self-hosted | — (self-hosting has only your own subscriptions) | You |
| Hosted | Say how many when the hub is opened, and we add them | You add them yourself, see below |

They can be mixed: one subscription pool can hold both ours and your own. Every subscription is shown on the **Subscription pool** page, with the name of whoever it belongs to.

## The subscription pool

The console's **Admin → Subscription pool**. One row per subscription: how much is left in each of its two quota windows (5 hours and 7 days), when they reset, who is using it, how many sessions, its state.

- A new session opens on the subscription with the most headroom; a subscription with either window at 85% is skipped until it resets. Change the percentage in **Subscription pool → Global settings → Skip a subscription at**.
- When a subscription is full the pool moves on by itself: a session's next request lands on another subscription. There is no switch for it.
- Members cannot see the subscription pool; they see only their own personal limit (below).

### Adding a subscription

An admin selects **Add subscription**, chooses Claude Code or Codex and gives it a name (letters, digits, dots, hyphens and underscores). Both connection methods stay in the browser:

- **Browser authorization (default)**: open the provider's sign-in page and paste its authorization code back here. For Codex, paste the complete localhost redirect URL; it is normal for that page not to load. Authorization expires after ten minutes. Start again after cancelling.
- **Existing OAuth token**: submit a Claude OAuth token or Codex OAuth refresh token in the hidden input. It clears on submit or close. The server validates it before encrypted storage. No SSH, operator token or account UUID is needed.

The page returns the result directly and reads the initial quota. Retry network failures; a valid credential whose quota cannot yet be read shows **Quota pending**. **Refresh quota** in its details reads the backend again. Duplicate tokens return the existing subscription. To replace a credential under the same name, explicitly select **Update credential** in its details; replacement follows validation. An unconfirmed expiry is shown as **Unknown**.

Only vault credentials appear in the pool. Historical usage remains in usage reports. Personal subscriptions retain their owner and do not count toward shared capacity. **Service** and **Plan** are separate columns: Max shows 5× or 20× only with a known tier. Unknown plans show **Unrecognized**; details retain the raw value, source and known observation time. A name containing 20X is not evidence of a plan.

### Members connect their own

Every member can connect **their own** Claude Pro / Max or ChatGPT Plus / Pro: Usage → "My own subscriptions" → **Connect my own subscription** → pick Claude or ChatGPT and name it → open the official sign-in page in **their own browser**, sign in and approve → paste back the code the page shows (Claude), or the whole address of the page it lands on that won't load (ChatGPT). The account's password is typed only on the provider's page; it never passes through the hub.

- A connected subscription is **for them alone**: the credential is stored under them and no one else's session can get it; their sessions use it first and the pool once it is full. In strict mode the hub adds it to their own allowlist and their own machines', and touches no one else's.
- In the same card they see its two windows (5 hours / week), pause / resume it, and disconnect it (typing its name); when its sign-in expires, one button signs in again. Every action is audited.
- Admins see these on the Subscription pool page, marked "<name>'s own"; they cannot pause one for its owner, and can revoke it if they must.

### Who may use which subscription

An added subscription **is not given to everyone automatically**. New users and new machines may use no subscription at all by default; grant them explicitly:

- **Users** page → choose a person → subscription access: pick "All subscriptions" (including ones added later), or tick a few.
- **Service nodes & clients** page → choose a machine → the same access, covering everyone on that machine (for a hosted customer we set it).

What a person can finally use = the subscription pool ∩ what that machine is granted ∩ what that person is granted. A change takes effect within 30 seconds. **Check a user’s access on a service node** shows directly which subscriptions someone can use on a given machine.

### A subscription needs a new login, pausing, removing

- **Needs a new login**: the subscription's card says so. Select **Update credential** in its details, then authorize again or submit a token. The new credential replaces the old one after validation.
- **Pause**: new sessions no longer open on it; running ones carry on to the end. **Resume** to undo.
- **Remove**: the credential is deleted from the hub; sessions using it move to another subscription when their short-lived credential runs out.

## Per-person quota

Give a person two limits, for 5 hours and for 7 days (in tokens; write `200k`, `2M`). What counts is input + cache writes + output; cache reads do not count. Past the limit, their next request is refused and the session shows:

> 已达个人额度：近 5 小时已用 X / 上限 Y token，约 N 后恢复（额度由管理员设置）
> (personal limit reached: X of Y tokens used in the last 5 hours, back in about N; the limit is set by an admin)

Only that person is affected; everyone else carries on. As the window rolls on it lifts by itself — nothing for you to do.

Limits are set on the command line (today the web can show them but not set them):

```sh
fleet hub accounts                                          # find their identity id, like gh:1234567
fleet hub set fleet.person_budget.gh:1234567 "5h=200k,week=2M"
fleet hub set fleet.person_budget.gh:1234567 "week=2M"      # 7 days only
fleet hub unset fleet.person_budget.gh:1234567              # no limit
```

Self-hosted, with the operator token, `fleet config budget` works too: with no argument it lists each person's usage and limit; `fleet config budget gh:1234567 5h=200k week=2M` sets one, `… off` removes it.

**Quota is counted only when a session goes through the credential proxy.** On hosted machines it is on for every account by default; on a self-hosted machine an admin runs `fleet cred-proxy enable --machine` once — every account becomes a tenant of the machine's one proxy. An account not on it is neither counted nor stopped.

## A new member's trial limits

A person let in through an approved request starts with trial limits: **7 days**, **1.5M tokens** of the shared pool (counted like a person's limit: input + cache write + output, a cache read not counted), and **1 session at a time**. Past the end or the tokens, their next request is refused and their session says which ("试用期已于 … 结束" / "试用额度已用完"); a start past the session count is refused with the reason.

They see it themselves at the top of the console and the chat — "Trial · 6 days left · 120k / 1.5M tokens · 1 session at a time" — coloured within a day of the end or at 80% used; ended or used up, it says why and offers "Ask to become a member", which marks their row in the admin's People list. Admins see each person's trial limits and usage in People, and change them or make the person a member from the row.

- The default: `fleet hub set fleet.apply.trial "days=7,tokens=1500000,sessions=1"` (`1.5M` and `1500k` work too); `off` approves a full member with no limits.
- Per approval: the approve request's body carries `{"limits": "days=14,tokens=3M,sessions=2"}`, or `"off"`.
- Afterwards: `fleet hub set fleet.member_limits.<principal> "until=2026-11-01T00:00:00Z,tokens=3M,sessions=2"` (or edit it in People); `fleet hub unset fleet.member_limits.<principal>` makes them a full member.
- A `usd=` written before is turned into tokens by database migration 6 (75,000 per dollar).
- Approving again never resets limits already written.

## Seeing who used how much

- **Usage by person** (admins): each person's usage today and over 7 days, their personal limit, what they mostly work on, how many sessions; open a row to see which subscriptions and machines they used.
- **My usage** (every member, for themselves): their own usage and limit.
- **Subscription pool**: each subscription's two windows.
- **Audit**: every addition, pause and removal of a subscription and every change of access or quota is recorded ([Who can see what](access.md)).
