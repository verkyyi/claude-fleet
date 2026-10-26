# Service health

## Open the health page

After signing in, choose **Service health** from your avatar menu, or open `/app/health` on your site. The page refreshes every minute. ClaudeFleet uses Chinese; tokenman.io uses English.

## Read the status

**Operational** means every recent probe succeeded. **Degraded** means at least one check failed, is not configured, or has not been updated for three minutes. **Outage** means all three user entry points failed. Missing data never counts as operational.

The page checks entry points, WeChat sign-in, the WeChat service connection, operations notifications and releases. These are server-side checks, so your network experience may differ. The page itself may be unavailable during a hub outage. A refresh failure warns that displayed data may be stale.

## First replies and your home

First reply measures the time from pressing Start to the first assistant text displayed, including opening the session and its page. p50 is the time that half the samples meet; p90 is the time that nine out of ten meet. Both the last 24 hours and seven days show sample counts. No samples means a dash, not zero seconds.

Only web sessions that receive and report a reply within ten minutes are counted. Empty sessions, pages closed before a reply, timeouts and reports blocked by the browser are excluded. This is not a success rate for all session starts. Small samples should not be treated as stable performance estimates.

**My home** shows the last 24 hours of round-trip latency from the service to your home, grouped by machine: mean, maximum and failed checks. Machine names, internal addresses and other people's homes are hidden. Old sample hours are marked stale. Administrators can see machine aggregates under anonymous labels.

## Incidents and explanations

Three consecutive failed minute checks open an incident. Further failures do not create duplicates. The first successful check resolves it. The page includes incidents opened or resolved in the last seven days and any ongoing incidents. Administrators can add public explanations in Chinese and English.

Operations alerts use the existing notification channel and ops inbox; no new enterprise WeChat push is added. Administrators also see daily first-reply percentiles by agent, recent probes and releases, and request and database pool metrics for the serving replica. RDS CPU and quota are not connected yet.
