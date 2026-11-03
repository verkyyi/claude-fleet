# Service health

## Open the health page

Open [/status](/status) on your site: no sign-in is needed. The website footer and avatar menu’s **Service health** links also open it. The page refreshes every minute; shared caching may delay data by up to about a minute. ClaudeFleet uses Chinese; tokenman.io uses English.

## Read the status

**Operational** means every recent probe succeeded. **Degraded** means at least one check failed, is not configured, or has not been updated for three minutes. **Outage** means all three user entry points failed. Missing data never counts as operational.

The page checks entry points, WeChat sign-in, the WeChat service connection, operations notifications, releases and the session relay. These are server-side checks, so your network experience may differ. The page itself may be unavailable during a hub outage. A refresh failure warns that displayed data may be stale.

## First replies and your home

First reply measures the time from pressing Start to the first assistant text displayed, including opening the session and its page. p50 is the time that half the samples meet; p90 is the time that nine out of ten meet. The public page shows percentiles for the last 24 hours and seven days without sample counts. No samples means a dash, not zero seconds.

Only web sessions that receive and report a reply within ten minutes are counted. Empty sessions, pages closed before a reply, timeouts and reports blocked by the browser are excluded. This is not a success rate for all session starts. Small samples should not be treated as stable performance estimates.

The public page shows overall mean and maximum round-trip latency and the failure rate over the last 24 hours. It does not list individual machines, machine counts, people counts or identifying information. Old sample hours are marked stale.

Choose **Show signed-in details** to additionally see **Your home**. If signed out, a sign-in link appears. Members only see their own connection. Administrators can also see anonymous machine aggregates and operations details. These details are never shared in public caches; the existing signed-in `/app/health` page remains available.

## Session reachability

Views report hourly totals of how entering sessions and the standing links to your other machines went; the page shows them for the last 24 hours and 30 days, for all routes together and for direct (tailnet, LAN, entry), relay (through the service) and same-machine sessions.

- **Session reach**: enters whose session was there within 10 seconds, divided by attempts.
- **Link availability**: the time a wanted link to another machine was up, divided by the time it was wanted.
- **Enter p50 / p95** and **recovery p50 / p95** (a link down until it is up again) are bucket upper bounds.

Only totals are published: no machines, logins, people or counts. A view never sends machine or login names — a link is an unreadable hash. Any figure with fewer than 20 samples shows a dash.

The **Session relay** component is a server-side check: every minute the service opens a relay echo through its own public entry, the same WebSocket road views use to reach another machine. It does not reach anyone's machine.

## Incidents and explanations

Three consecutive failed minute checks open an incident. Further failures do not create duplicates. The first successful check resolves it. The page includes incidents opened or resolved in the last seven days and any ongoing incidents. Administrators can add public explanations in Chinese and English. Anyone can read them: describe service impact and progress only, without machine names, login names, internal addresses, IPs, tokens or user identities.

Operations alerts use the existing notification channel and ops inbox; no new enterprise WeChat push is added. Administrators also see daily first-reply percentiles by agent, recent probes and releases, and request and database pool metrics for the serving replica. RDS CPU and quota are not connected yet.
