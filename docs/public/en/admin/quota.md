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

- The node-local proxy’s skip threshold is set in **Subscription pool → Global settings → Skip a subscription at**. The central Codex gateway checks the 5-hour and 7-day windows separately. When both have reliable room, it favors an allowance nearing reset. Without trustworthy absolute capacity, remaining percentages cannot establish which subscription has more usable capacity.
- Automatic central Codex bindings stay for at least 10 minutes. They are reconsidered before a demonstrably self-contained request only for a clear improvement in window reserves or reset opportunity. Existing streams finish normally; the Agent is not restarted. Missing or expired readings never imply a full allowance. A quota 429 is returned unchanged: that request is not replayed on another account, and the updated binding applies to the next independent request. Credentials refreshed after an authentication 401 are also used only by the next independent request. Continuations carrying response IDs, encrypted history, or turn-state stay with their source subscription. Unknown, expired, or unavailable sources are refused. History created before source tracking may also be refused; deployment acceptance must assess existing-session compatibility separately.
- When a subscription is full the pool moves on by itself: a session's next request lands on another subscription. There is no switch for it.
- Members cannot see the subscription pool; they see only their own personal limit (below).

### Adding a subscription

An admin selects **Add subscription**, chooses Claude Code or Codex and gives it a name (letters, digits, dots, hyphens and underscores). Everything stays in the browser:

- **Claude: a setup token only**: on a computer signed in to that Claude account run `claude setup-token`, confirm in the browser, and paste the whole `sk-ant-oat01-…` it prints. The hub tests it once against the provider's messages endpoint and does not save a token that is refused. Claude no longer offers browser authorization — that road yields a short-lived rotating token, not the long-lived kind the rest of the pool uses.
- **Codex: browser authorization (default) or an existing refresh token**: after signing in, paste the complete localhost redirect URL (it is normal for that page not to load; authorization expires after ten minutes), or submit an OAuth refresh token.

The input is hidden and clears on submit or close. The server validates it before encrypted storage. No SSH, operator token or account UUID is needed.

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

A person let in through an approved request starts with trial limits: **7 days**, **3M tokens** of the shared pool (counted like a person's limit: input + cache write + output, a cache read not counted), and **1 session at a time**. Past the end or the tokens, their next request is refused and their session says which ("试用期已于 … 结束" / "试用额度已用完"); a start past the session count is refused with the reason.

They see it themselves at the top of the console and the chat — "Trial · 6 days left · 120k / 3M tokens · 1 session at a time" — coloured within a day of the end or at 80% used; ended or used up, it says why and offers "Ask to become a member" — while the trial runs normally, the Usage page carries a quiet one under the limit card too. Asking marks their row in the admin's People list and tells every admin once (WeChat if they follow the service account, else mail), tapping through to that person in People, where one button makes them a member. Admins see each person's trial limits and usage in People, and change them or make the person a member from the row.

- The default: `fleet hub set fleet.apply.trial "days=7,tokens=3000000,sessions=1"` (`3M` and `3000k` work too); `off` approves a full member with no limits.
- Per approval: the approve request's body carries `{"limits": "days=14,tokens=3M,sessions=2"}`, or `"off"`.
- Afterwards: `fleet hub set fleet.member_limits.<principal> "until=2026-11-01T00:00:00Z,tokens=3M,sessions=2"` (or edit it in People); `fleet hub unset fleet.member_limits.<principal>` makes them a full member.
- A `usd=` written before is turned into tokens by database migration 6 (150,000 per dollar).
- Approving again never resets limits already written.
- When a trial ends (`until` passed, not made a member): the sessions on their login stop at once; 23 and 27 days after the end they are told on the service account (else by mail) when their data goes; on day 30 their login's home is deleted (the login washed, checked clean and back in the spare pool), with the hub's copy of their conversation and their uploads — only a `trial.purge` audit row without content stays. `fleet hub set fleet.trial.retain_days 30` sets how long (30 by default, 0 = at once and no notice; the notices are always 7 and 3 days before). Making them a member (`unset` the key above) deletes nothing.

## Trial QR codes: scan, follow, try

**Trial QR codes**, under People in the admin console: make a code — a channel name (only admins see it), the trial plan (`fleet.apply.trial` above by default, changeable), how many people it gives a trial at most (200 by default, 0 = no cap), until when, and whether it needs approval (no by default). Two kinds: **permanent** (the default; never expires, stopped from here — the service account holds 100,000 in all, shared with the company's other products) and **temporary** (at most 30 days, then void). Download the picture as soon as it is made, for a poster, a slide or a group chat. To send it to a friend as it is, **Make a poster** beside the code (or Poster in its row): one 1080×1440 picture with the code, the product in a line, the trial it gives and three steps to start, in 中文 or English; on a phone long-press it to save or forward, on a computer Download PNG.

The website's scan card takes its code from here too: make one with the channel `site` and no approval, and the front page shows it (its scans land in that code's funnel); with none, the front page draws its own as before.

Someone scans it with WeChat and follows the service account (one already following just scans), and the account answers at once with a "Your trial is on" card; tapping it opens the chat inside WeChat — no sign-in, no request. They are on the list like a person approved from "Ask to use", with this code's trial limits and subscriptions; the request record says this code approved it.

- **One trial per WeChat, ever**: the same WeChat scanning another code is told "your trial is running" or "you have tried" (tap to ask to become a member); a member is told to tap and go on.
- **Each code has a cap**; once given out it answers "every trial is given". A stopped or expired code says so and points at "Ask to use".
- **A day's cap across every code**: `fleet hub set fleet.qr.daily 100` (100 by default, Beijing days); past it, "scan again tomorrow".
- **Machines or the pool busy: a line**. The scanner gets "In line · n ahead of you" first, and a "Your turn" message when it is.
- **Farming alarm**: a code that starts more than `fleet.qr.burst` (30 by default) trials in 10 minutes pauses itself and every admin is told; resume or stop it from the console once you have looked.
- **A stuck trial reaches you**: someone in line over 10 minutes (`queue_long`), 3 or more session starts failing within 15 minutes (`start_failed`, whoever asked), a machine lost (`node_lost`) — these and every other Tokenman alert are pushed to the admins' WeChat (the hub's `FLEET_NOTIFY_KF_*`); one kind at most once in `fleet.alert.quiet_mins` (30 by default), and the ones not pushed are still in `GET /v1/fleet/fleet_alerts`.
- **A code that needs approval** only files a waiting request in Requests; approving it uses that code's trial plan.

Each code is a row: given / cap, the funnel scan › follow › start › first line › member, its state; on top, the last 7 days' totals and the median time from scan to first line. Open a code to see who it reached; stop one person in People as usual.

## Seeing who used how much

- **Usage by person** (admins): each person's usage today and over 7 days, their personal limit, what they mostly work on, how many sessions; open a row to see which subscriptions and machines they used.
- **My usage** (every member, for themselves): their own usage and limit.
- **Subscription pool**: each subscription's two windows.
- **Audit**: every addition, pause and removal of a subscription and every change of access or quota is recorded ([Who can see what](access.md)).

## Claude capacity routing

**Subscription pool → Capacity → Claude** has its own Off, Shadow and Active modes. The catalog’s original top-level mode and profiles continue to belong to Codex. Saving with an older client preserves omitted Claude settings; every update still requires the current catalog revision. Configure Claude by reading and retaining the current Codex catalog, never by restoring an earlier whole catalog.

Claude estimates use confirmed provider identities and explicitly registered plan/tier evidence, including source and observation time. Labels and prices do not establish capacity. [Anthropic’s Max plan documentation](https://support.claude.com/en/articles/11049741-what-is-the-max-plan) establishes **five-hour, per-session** relative allowances of Pro 1, Max5 5 and Max20 20. It does not establish weekly multipliers. A weekly baseline needs its own evidence source. Without one, diagnostics say **five-hour-only estimate; weekly capacity unknown**. Weekly remaining percentages are separate eligibility guards and tie-breakers, never five-hour work units.

Active mode checks the observed five-hour, weekly and applicable model windows **before** comparing plan estimates. A fresh full weekly window blocks an account even if its plan evidence is stale or missing. Reset time passing does not prove refill. Missing, contradictory, future or expired readings cannot establish eligibility. An inference-header reading proves only the exact model requested; it does not establish the absence of another model’s weekly cap. Unknown window/model schemas remain explicit in preview. See also [Claude Code’s shared plan limits](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan).

Both the unified gateway and the local direct proxy keep eligible automatic bindings for at least ten minutes, then require a greater-than-25% comparable improvement to move at an independent request boundary. Explicit bindings are honored when eligible. Recorded tool IDs and signed thinking stay with the original credential; unknown, mixed or expired continuation sources are refused. Active mode can refuse history created before source tracking. Responses are never replayed on another subscription after sending. Full or unproven subscription capacity returns a capacity refusal; there is no paid API or extra-usage fallback.

Preview uses the saved catalog, a live worker’s permissions and an explicit request model. It performs no inference, credential refresh or binding writes. Local proxies fetch metadata in the background with a maximum 30-second cache and verify it against the credential actually leased. An expired cache after Active has been observed refuses routing. Rollout requires independent native first-turn, actual tool-result and resume acceptance on both proxy paths. Offline fixtures prove routing and protocol behavior only: if every live account is weekly-full, successful live inference remains unverified until a fresh eligible reading and a real canary succeed. Keep Claude in Shadow until then.
