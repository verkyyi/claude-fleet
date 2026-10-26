# Service health

## Open the health page

Open [/status](/status) on your site: no sign-in is needed. The website footer and avatar menu’s **Service health** links also open it. The page refreshes every minute; shared caching may delay data by up to about a minute. ClaudeFleet uses Chinese; tokenman.io uses English.

## Read the status

**Operational** means every recent probe succeeded. **Degraded** means at least one check failed, is not configured, or has not been updated for three minutes. **Outage** means all three user entry points failed. Missing data never counts as operational.

The page checks entry points, WeChat sign-in, the WeChat service connection, operations notifications and releases. These are server-side checks, so your network experience may differ. The page itself may be unavailable during a hub outage. A refresh failure warns that displayed data may be stale.

## First replies and your home

First reply measures the time from pressing Start to the first assistant text displayed, including opening the session and its page. p50 is the time that half the samples meet; p90 is the time that nine out of ten meet. The public page shows percentiles for the last 24 hours and seven days without sample counts. No samples means a dash, not zero seconds.

Only web sessions that receive and report a reply within ten minutes are counted. Empty sessions, pages closed before a reply, timeouts and reports blocked by the browser are excluded. This is not a success rate for all session starts. Small samples should not be treated as stable performance estimates.

The public page shows overall mean and maximum round-trip latency and the failure rate over the last 24 hours. It does not list individual machines, machine counts, people counts or identifying information. Old sample hours are marked stale.

Choose **Show signed-in details** to additionally see **Your home**. If signed out, a sign-in link appears. Members only see their own connection. Administrators can also see anonymous machine aggregates and operations details. These details are never shared in public caches; the existing signed-in `/app/health` page remains available.

## Incidents and explanations

Three consecutive failed minute checks open an incident. Further failures do not create duplicates. The first successful check resolves it. The page includes incidents opened or resolved in the last seven days and any ongoing incidents. Administrators can add public explanations in Chinese and English. Anyone can read them: describe service impact and progress only, without machine names, login names, internal addresses, IPs, tokens or user identities.

Operations alerts use the existing notification channel and ops inbox; no new enterprise WeChat push is added. Administrators also see daily first-reply percentiles by agent, recent probes and releases, and request and database pool metrics for the serving replica. RDS CPU and quota are not connected yet.
