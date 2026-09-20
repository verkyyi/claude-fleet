// web/dist/lib/i18n/en.js — the English dictionary, and the fallback for every
// other locale.
//
// This file is the SOURCE text, not a translation of one: every string here is
// the exact copy the page shipped before it had a second language, so an
// English viewer sees byte-identical wording to what they saw yesterday.
//
// Keys are namespaced by the card or module that prints them. Variables are
// named (`{n}`, `{source}`), never positional — a translator moves them, and
// Chinese routinely puts a count on the other side of its noun.
//
// Adding a key here without adding it to zh-CN.js is a red test
// (web/test/i18n.test.mjs), not a silent English leak.
export const en = {
  /* ------------------------------------------------------------ shell */
  'app.theme': 'Toggle light / dark',
  'app.language': 'Language',
  'app.unreachable': 'Cannot reach the hub: {error}',
  'nav.sections': 'Sections',
  // The bar's first entry: the whole page, every band, which is the default
  // view and the way back from any single one (#98). Not a band, so it has no
  // `band.` key and index.html has no label printing it.
  'nav.all': 'All',
  'band.quota': 'Quota',
  'band.quota.note': 'how much runway is left',
  'band.ledger': 'Ledger',
  'band.ledger.note': 'what was paid, and to whom',
  'band.usage': 'Usage',
  'band.usage.note': 'what drove the figures above',
  'band.progress': 'Progress',
  'band.progress.note': 'what the spend bought',
  'ops.title': 'Operations',
  'ops.note': 'machines · collection health · sessions',
  'ops.access': 'Ways in — every door, its credential, and what is turned on here',

  /* ----------------------------------------------------------- common */
  'common.queryFailed': 'Query failed: {error}',
  'common.noUsagePeriod': 'No usage in this period.',
  'common.loading': 'loading…',
  'common.showAll': 'show all {n}',
  'common.loadMore': 'load more',
  'common.unknown': '(unknown)',
  'common.unknownTime': 'unknown',

  /* ------------------------------------------------------ scope controls */
  'scope.subscription': 'Subscription',
  'scope.source': 'Usage source',
  'scope.span': 'Timeline span',
  'scope.allAccounts': 'All {n} accounts / usage pools',
  'scope.allQuotaAccounts': 'All {n} accounts',
  'scope.allSources': 'All sources',
  'scope.removeChip': 'remove {dim}',
  'scope.clearAll': 'Clear all',

  /* ------------------------------------------------------ dimension names */
  'dim.project': 'Project',
  'dim.login': 'Login',
  'dim.machine': 'Machine',
  'dim.model': 'Model',
  'dim.branch': 'Branch',
  'dim.team': 'Team',
  'dim.source': 'Source',
  'dim.session': 'Session',

  /* --------------------------------------------------------- source names */
  // Must stay in step with lib/providers.js's SOURCE_LABEL, which web's
  // embed_test.go anchors on; web/test/i18n.test.mjs asserts they agree.
  'source.claude': 'Claude Code',
  'source.codex': 'Codex',
  'source.gateway': 'AI gateway',
  'source.vendor_bill': 'Vendor invoice',
  'source.voice': 'Voice, app-reported',
  'accounts.subscriptions': 'Subscriptions',
  'accounts.apps': 'Calling applications',

  /* ------------------------------------------------------------ cost kinds */
  'kind.notional': 'notional',
  'kind.billed': 'billed',
  'kind.unknown': 'unclassified',
  'cost.noCost': 'no cost',
  'cost.subscription': 'subscription',
  'cost.sourceSubscription': '{source} — subscription',

  /* --------------------------------------------------------- spend (money) */
  'spend.title': 'What this actually cost',
  'spend.incomplete': 'Incomplete — {missing}',
  'spend.unpriced': '{n} request(s) have no price data, so every figure here is a lower bound.',
  // The one door into the folded explanation. It names what is behind it, so
  // opening it is a decision rather than a guess — "Details" would not be.
  'spend.working': 'How this number is worked out',
  'spendTerm.subscription': 'subscriptions',
  'spendTerm.gateway': 'metered · via the gateway',
  'spendTerm.vendor_bill': 'metered · billed by the vendor directly',
  'spendTerm.voice': 'metered · reported by the calling application',

  /* -------------------------------------------------------- consumption */
  'consumption.title': 'Consumption',
  'consumption.hint': 'Every model that ran, by the upstream that served it — who served the call, which is not '
    + 'the source the usage band groups by (that is which tool reported it). One call has both. '
    + 'Subscription rows show no amount: '
    + 'a plan bills monthly, not per request, so its cost belongs to the plan rather than to any '
    + 'row here. Their usage is the token count.',
  'consumption.empty': 'No usage in this selection.',
  'consumption.couldNotLoad': 'Could not load: {error}',
  'consumption.noModels': 'no models in this period',
  'consumption.modelsFailed': 'could not load models: {error}',
  'consumption.sortBy': 'by {what}',
  'consumption.costKindTip': 'cost kind: {kind}',
  'consumption.col.provider': 'Provider',
  'consumption.col.billing': 'Billing',
  'consumption.col.requests': 'Requests',
  'consumption.col.tokens': 'Tokens',
  'consumption.col.cost': 'Cost',
  'sort.cost': 'cost',
  'sort.tokens': 'tokens',
  'sort.events': 'requests',
  'billing.billed': 'metered',
  'billing.notional': 'subscription',
  'billing.unknown': 'unclassified',
  'rows.notDeclared': 'not declared',
  // Only when every figure in the row came from claude: then "blank" has one
  // possible cause, and the row can name it.
  'rows.notDeclaredClaude': 'Claude (declares no upstream)',
  'rows.foldedTail': 'other {n} providers · ≤{max} requests, no charge',

  /* ------------------------------------------------------- time formatting */
  'ago.seconds': '{n}s ago',
  'ago.minutes': '{n}m ago',
  'ago.hours': '{n}h ago',
  // How long a window IS, not how long ago something was. See windowOf in
  // lib/format.js for why a threshold cannot borrow the `ago.*` phrasing.
  'dur.seconds.one': '{n} second',
  'dur.seconds.other': '{n} seconds',
  'dur.minutes.one': '{n} minute',
  'dur.minutes.other': '{n} minutes',
  'dur.hours.one': '{n} hour',
  'dur.hours.other': '{n} hours',
  'reset.unknown': 'reset time unknown',
  'reset.now': 'resetting now',
  'reset.minutes': 'resets in {m}m',
  'reset.hours': 'resets in {h}h {m}m',
  'reset.days': 'resets in {d}d {h}h',
  'day.0': 'Sun',
  'day.1': 'Mon',
  'day.2': 'Tue',
  'day.3': 'Wed',
  'day.4': 'Thu',
  'day.5': 'Fri',
  'day.6': 'Sat',
  'fold.sentence': 'busiest hour: {day} {hour} local. Quietest 4-hour window: {from}–{to}.',

  /* ------------------------------------------------ currency conversion */
  'fx.billedTip': 'Billed {amount} · converted at {rate} {base}/{target} (rate as of {asOf})',
  'fx.rateLine': 'Amounts marked ≈ are converted for display at {rate} {base}/{target}, rate as of {asOf}.',
  'fx.fallbackLine': 'The live rate could not be read, so this uses one pinned in the build ({source}).',
  'fx.staleLine': 'This rate has not moved since {asOf}.',
  'fx.billedIn': 'The ledger keeps every figure in the currency it was billed in.',

  /* ------------------------------------------------------- gauges + tips */
  'gauge.critical': 'critical',
  'gauge.high': 'high',
  'gauge.moderate': 'moderate',
  'gauge.healthy': 'healthy',
  'chart.tip.tokens': '{tokens} tokens',
  'chart.tip.tokensTurns': '{tokens} tokens · {turns} turns',
  'chart.tip.turnsCost': '{turns} turns · {cost}',
  'chart.tip.tokensPct': '{tokens} tokens · {pct}',
  'chart.tip.heatCell': '{day} {hour} — {tokens} tokens, {turns} turns',
  'chart.tip.barTitle': '{key}: {tokens} tokens',
  'chart.tip.mixRow': '{name} · {tokens} · {pct}',
  'chart.subagent': 'subagent',
  'chart.ariaTokensPer': 'Tokens per {granularity}, peak {peak}',
  'chart.ariaModelMix': 'Model mix over time, {from} to {to}, peak {peak} tokens per bucket',
  // Issue #56: one aria-label per chart. Each names the picture, the span it
  // covers and its scale — the three things a reader who cannot see it needs
  // before deciding whether to open the table the ⊞ toggle swaps in.
  'chart.ariaTimeline': 'Tokens over time, {from} to {to}, peak {peak} tokens per bucket',
  'chart.ariaTimelineStacked': 'Tokens over time, stacked by model, {from} to {to}, peak {peak} tokens per bucket',
  'chart.ariaBrush': 'Time range selector. Arrow keys move the selection, Shift with arrow keys moves its right edge; the selected range is written below the chart.',
  'chart.ariaTurnBars': 'Tokens per turn, {turns} turns, peak {peak} tokens, coloured by model',
  'chart.ariaComposition': 'Token composition by type, largest part {name} at {pct}; every share is listed below the bar',
  'chart.ariaHeatmap': 'Tokens by weekday and hour, busiest {day} {hour} at {tokens} tokens',
  'chart.ariaHeatmapEmpty': 'Tokens by weekday and hour — no usage in this period',

  /* ------------------------------------------------------------- charts */
  'chart.turns': 'Turns',
  'chart.tokens': 'Tokens',
  'chart.unpriced': 'Unpriced',
  'chart.other': 'Other',
  'chart.toggleTable': 'Toggle table view',
  'chart.sourceCostTip': "{source}: {kind} cost — never added to another source's",

  /* --------------------------------------------------------- token badge */
  /* The title carries the whole definition of the figure -- what is counted,
     over which scope, over what span, and that it is projected between
     measurements. It stays long on purpose: it is the only place that says
     what this number means, and #96 shortened the caption, not this. */
  'hero.title': 'tokens consumed · selected account and source · all time · projected between measurements',
  /* One word, because the badge now lives in the top bar and every character
     of it competes with the section nav (#96). "· all time" moved into the
     title above rather than being dropped -- the scope qualifier is part of
     the definition, and the definition was already there. */
  'hero.caption': 'tokens',

  /* ---------------------------------------------------------------- live */
  'live.title': 'Right now',
  'live.tile.sessions': 'active / recent sessions',
  'live.tile.tpm': 'tokens / min',
  'live.tile.inflight': 'tokens in flight',
  'live.reporting.one': '{n} endpoint reporting · updates as sessions work',
  'live.reporting.other': '{n} endpoints reporting · updates as sessions work',
  'live.noActivity': 'No recent activity. Codex uses log observations; Claude uses statusLine heartbeats.',
  'live.window': 'Active means a heartbeat within the last {window}. Nothing here is stored — the hub knows only what the agents have just said.',
  'live.cold': 'Hub restarted {ago}; no agent has reported yet. This is not zero, it is not yet known.',
  'live.coldNoTime': 'No agent has reported to this hub yet. This is not zero, it is not yet known.',
  'live.coldRows': 'Nothing to show until the first agent reports in.',
  'live.noMatch': 'No live sessions match the current chips.',
  'live.noSessions': 'no sessions reporting',
  'live.row.filterTip': 'click to filter by this session',
  'live.row.codexPrefix': 'Codex · recent activity · ',
  'live.row.claudePrefix': 'Claude · ',
  'live.row.noNewTokens': 'no new tokens',
  'live.row.idle': 'idle',
  'live.row.contextUnknown': 'context unknown',
  'live.row.contextTip': 'context {pct}%',

  /* ---------------------------------------------------------------- wall */
  // #124 turned the title from a question into a noun: the card still needs an
  // h2 (every card in this build has one, and the band label above it is a pair
  // of spans that no heading outline sees), but a question plus three sentences
  // of explanation said what the numbers under them already say.
  'wall.title': 'Subscription quota',
  'wall.noReading': 'No reading available.',
  'wall.meteredOnly': 'Every account in view is billed per call — there is no quota window to be near. Their spend is on the usage cards below.',
  'wall.noReadingSeeNotice': 'No reading available — see the notice above.',
  'wall.closest': 'Closest to its limit: {label} ({source}) at {pct}%.',
  'quota.group.count.one': '{n} subscription',
  'quota.group.count.other': '{n} subscriptions',
  'quota.group.claude.note': 'a fixed five-hour and seven-day pair',
  'quota.group.codex.note': 'the windows the provider reports, plus a credit balance',
  'wall.whose': 'Whose 5-hour window is it',
  'wall.share.ofWindow': "{pct}% of this window's spend",
  'wall.share.tokens': '{tokens} tokens · {events} turns',
  'wall.share.estimate': '≈ {pct}% of the limit (estimate)',

  /* -------------------------------------------------------------- quota */
  'quota.fiveHour': '5-hour window',
  'quota.sevenDay': '7-day window',
  'quota.window': 'window',
  'quota.windowDays': '{n}-day window',
  'quota.windowHours': '{n}-hour window',
  'quota.windowMinutes': '{n}-minute window',
  'quota.scopedWeekly': '{name} · weekly',
  'quota.credits': '{id} credits: {value}',
  'quota.credits.unlimited': 'unlimited',
  'quota.credits.available': 'available',
  'quota.credits.none': 'none',
  'quota.blocked': 'Limit reached: {reason}',
  'quota.blocked.reported': 'reported by service',
  'quota.codexNote': '{plan} · observed {when} · projections are estimates',
  'quota.codexAccount': 'Codex account',

  /* -------------------------------------------------------------- alerts */
  'alerts.title': 'Alerts',
  /* The bar bell's accessible name and title (#123). All that fits on screen
     is the count and the severity word; this says what is being counted. */
  'alerts.bell.label': 'Alerts: {n} {severity}',
  'alerts.bell.allMuted': 'Alerts: {n}, all muted',
  /* The three severities, as words. Colour never carries the meaning on its
     own (styles.css:256) — the bell's colour is reinforced by one of these. */
  'alerts.sev.critical': 'critical',
  'alerts.sev.warning': 'warning',
  'alerts.sev.info': 'info',

  /* --------------------------------------------------------------- fleet */
  'endpoints.title': 'Endpoints',
  'endpoints.hint': 'Every machine reporting in, which subscription it is on, and what it could not '
    + 'attribute. An agent that stops reporting is the usual reason a total looks too low.',
  'endpoints.staleHint': 'A "last seen" older than {window} is greyed out, and is the same threshold '
    + 'that raises the stale-agent alert above. It is a different question from the live card\'s: '
    + 'that one asks whether a SESSION is running right now.',
  'endpoints.empty': 'No endpoints enrolled yet.',
  'endpoints.col.name': 'Name',
  'endpoints.col.subscription': 'Subscription',
  'endpoints.col.platform': 'Platform',
  'endpoints.col.cc': 'Claude Code',
  'endpoints.col.agent': 'Agent',
  'endpoints.col.lastSeen': 'Last seen',
  'endpoints.col.excluded': 'Excluded',
  'endpoints.neverReported': 'never reported',
  'endpoints.droppedTurns': '{n} turns',
  'endpoints.showRetired': 'Show retired endpoints',
  'endpoints.retiredOn': 'retired {date}',
  'endpoints.showAccounts': 'Show every subscription each machine runs',
  'endpoints.ownLogin': 'its own login',
  'endpoints.seenInSession': 'seen in a session',
  'endpoints.col.lastSwitch': 'Last switch',
  'endpoints.switchHint': 'A machine logged OUT of one subscription and INTO another. Turns recorded '
    + 'before a switch keep their old attribution and cannot be corrected — that is the '
    + 'seam where this machine’s historical figures stop being reliable. Running several '
    + 'subscriptions side by side is not a switch: the subscription column lists those.',
  'endpoints.switchUnavailable': 'The switch record could not be read, so this table cannot say '
    + 'whether any machine changed subscription. Treat the figures as unverified rather than clean.',

  /* ------------------------------------------------------------- banners */
  'banner.excludesHistory': '{name} excludes history.',
  'banner.droppedPreAccount': '{n} turn(s) older than this subscription{range} — they cannot belong to it, so they are excluded',
  'banner.backTo': ' (back to {date})',
  'banner.droppedBeyondBackfill': '{n} turn(s) beyond the {window} backfill window',
  'banner.limitsUnavailable.title': 'Account-wide limits unavailable.',
  'banner.limitsUnavailable.body': '{reason} The usage totals below are still accurate; only the quota gauges are missing.',
  'banner.limitsStale.title': 'Limits reading is stale.',
  'banner.limitsStale.body': 'Last read {ago}. An agent may have stopped polling.',

  /* ---------------------------------------------------------- collectors */
  'collectors.title': 'Collection by source',
  'collectors.unavailable': 'Collector status unavailable.',
  'collectors.empty': 'No collector observations for this selection.',
  'collectors.unlinked': 'Unlinked account',
  'collectors.profile': 'profile {name}',
  'collectors.defaultProfile': ' · default for new ccquota launches',
  'collectors.autoRenewOn': ' · automatic renewal on',
  'collectors.autoRenewOff': ' · automatic renewal off',
  'collectors.accessExpires': 'Access expires {when}',
  'collectors.credsRefreshed': ' · credentials refreshed {when}',
  'collectors.lastRenewalAttempt': 'Last renewal attempt {when}',
  'collectors.retryAfter': ' · retry after {when}',
  'collectors.manage': 'Manage this account',
  'collectors.manageHint': 'Run on this machine as the same OS user. Switching selects the account for new ccquota launches; existing sessions keep their login.',
  'collectors.stale': 'stale',
  'collectors.state': '{state} · {files} indexed transcripts',
  'collectors.cliVersion': ' · CLI v{version}',
  'collectors.logVersion': ' · last log v{version}',
  'collectors.lastScan': 'Last scan {when}',
  'collectors.lastUsage': ' · last usage {when}',
  'collectors.queue': ' · agent queue {bytes} bytes',
  'collectors.quota': 'Quota: {reason}',
  'collectors.addCodex': 'Add another Codex account',
  'collectors.addCodexHint': 'Create a separate login directory on the machine where you use Codex. The agent discovers it automatically; each account keeps its own quota.',
  'login.valid': 'Signed in',
  'login.refresh_due': 'Renewal due',
  'login.access_expired': 'Access expired · renewal pending',
  'login.refreshing': 'Renewing login',
  'login.retry_pending': 'Renewal retry scheduled',
  'login.reauth_required': 'Sign-in required',
  'login.no_credentials': 'No file login',
  'login.unsupported': 'Login mode unsupported',
  'login.unavailable': 'Login status unavailable',
  'accountUsage.title': 'Service account activity',
  'accountUsage.notProvided': 'not provided',
  'accountUsage.lifetime': '{total} lifetime tokens reported by the service',
  'accountUsage.local': '{tokens} tokens in local details attributed to this account · {requests} requests',
  'accountUsage.observed': 'Observed {when} · {n} daily buckets available',
  'accountUsage.recentDaily': 'Recent daily service totals',
  'accountUsage.col.date': 'Service date',
  'accountUsage.col.tokens': 'Tokens',

  /* ------------------------------------------------------------ timeline */
  'timeline.title': 'Timeline',
  'timeline.hint': 'Tokens per bucket across the current span — when work ran, not what ran it. Drag the '
    + 'body to move the selection every other card reports on, an edge to resize it, or '
    + 'double-click to reset to the whole span.',
  'timeline.caption': 'selected {from} → {to} ({len}) · compared with the {len} before',
  'timeline.bucket': 'Bucket',

  /* ---------------------------------------------------------------- kpis */
  'kpis.title': 'KPIs',
  'kpis.hint': 'Selection totals, each compared with the equal-length period right before it.',
  'kpis.spendTile': '{source} spend ({kind})',
  'kpis.ratesAsOf': 'Rates as of {date}. {note}',
  'kpis.ratesUnstated': 'unstated',
  'kpis.unpricedTip': '{n} {source} event(s) in this period have no price data — this figure is a lower bound.',
  'kpis.provenance': 'Where each cost figure comes from',
  'kpis.col.source': 'Source',
  'kpis.col.kind': 'Kind',
  'kpis.col.ratesAsOf': 'Rates as of',
  'kpis.col.basis': 'Basis',
  'kpis.subSpend': 'Subscription spend over this period',
  'kpis.col.sourcePlan': 'Source / plan',
  'kpis.col.seats': 'Seats',
  'kpis.col.months': 'Months',
  'kpis.col.amount': 'Amount',
  'kpis.noRecordedPrice': 'no recorded price',
  'kpis.unclassified': 'Cost from a source this build has no rate basis for, in no total: {list}',
  'kpis.coverage': 'Request pricing coverage: {pct}',
  'kpis.coverageHint': '{priced} priced / {total} collected model requests. {unpriced} unpriced requests still count toward token totals. This measures pricing coverage by request count, not collection completeness or remaining quota. API-equivalent cost is not your subscription bill.',
  'kpis.whyUnpriced': 'Why {n} requests have no price',
  'kpis.col.sourceModel': 'Source / model',
  'kpis.col.reason': 'Reason',
  'kpis.col.requests': 'Requests',
  'kpis.noSpend': 'No usage in this selection, so there is no spend to attribute to a source.',
  'kpis.cacheWrites': 'Codex cache writes: {tokens} tokens · breakdown available for {n} requests. Included in input totals.',
  'kpis.tile.tokens': 'tokens',
  'kpis.tile.requests': 'model requests',
  'kpis.tile.sessions': 'sessions',
  'kpis.tile.cacheHit': 'cache hit',
  'kpis.tile.subagent': 'subagent share',
  'kpis.tile.duration': 'duration',
  'kpis.tile.turns': 'turns',

  /* ------------------------------------------------------------ findings */
  'findings.title': 'Findings',
  'findings.empty': 'Nothing unusual in this period.',
  'findings.apply': 'apply →',
  // A finding's attribution. Only printed when the hub actually knows it —
  // absent is the normal case for a finding about a model or a whole period,
  // and these lines never appear rather than saying "unknown". {user} is an OS
  // login and {team} the operator's own allocation; neither is translated.
  'findings.owner.both': 'who to ask: {user} · team {team}',
  'findings.owner.user': 'who to ask: {user}',
  'findings.owner.team': 'who to ask: team {team}',

  // Muting: "I know about this, be quiet until then". Every one of these
  // states WHEN the silence ends, because a mute with no visible expiry is
  // indistinguishable from a deleted alert -- and the whole reason mutes
  // expire is so nobody has to wonder which they are looking at.
  'findings.mute': 'mute {hours}h',
  'findings.unmute': 'unmute now',
  'findings.mutedCount': 'muted ({n})',
  'findings.muted.plain': 'muted',
  'findings.muted.for': 'muted · {left} left',
  'findings.muted.by': 'muted by {by}',
  'findings.muted.byFor': 'muted by {by} · {left} left',
  'findings.muted.days': '{n}d',
  'findings.muted.hours': '{n}h',
  'findings.muted.minutes': '{n}m',
  'findings.muted.failed': "couldn't change that: {error}",

  /* ---------------------------------------------------------- breakdowns */
  'breakdown.title': 'By {dim}',
  'breakdown.hint': 'Top 50 rows, compared with the period before. Shares follow the current selection.',
  'breakdown.groupBy': 'group by (breakdown {n})',
  'breakdown.openUser': "Open {user}'s own page",
  'breakdown.subscriptionNote': 'Everything on this card ran on a subscription ({sources}) — the same sentence on every row, so it is said once here. Billed money still prints per row.',
  'breakdown.sourceNote': 'Source is which tool reported the call, and so which kind of money its cost is: a subscription estimate (claude, codex) or a real per-call charge (gateway). It is not the consumption table’s upstream, which is who actually served the call. One call has both, and the two are never added.',
  'breakdown.scaleNote': 'Both breakdown cards share one scale: a full bar is {max} tokens. The thin rule marks the previous period.',
  'breakdown.prevTokens': 'Prev tokens',
  'breakdown.prevSource': 'Prev {source} $',
  'breakdown.prevMark': 'Previous period: {prev} tokens',
  'breakdown.share': 'Share',
  'breakdown.shareTip': 'Share of the {n} rows on this card ({total} tokens in the current selection). Tokens only — the three kinds of money on this page are never added.',
  'breakdown.tip.cur': 'This period: {tokens} tokens · {share} of this card',
  'breakdown.tip.prev': 'Previous period: {prev} tokens ({abs}, {pct})',
  'breakdown.tip.noPrev': 'No previous-period data for this row.',
  'breakdown.tip.exact': 'exact change: {pct}',

  /* ---------------------------------------------------------- efficiency */
  'efficiency.title': 'Efficiency',
  'efficiency.hint': 'Token composition, how work was invoked, and cost per million output tokens by model — '
    + 'each rate within one source, labelled with the kind of money it is.',
  'part.cacheRead': 'cache read',
  'part.cacheCreate': 'cache create',
  'part.output': 'output (non-thinking)',
  'part.input': 'input',
  'part.thinking': 'thinking',
  'efficiency.col.part': 'Part',
  'efficiency.col.tokens': 'Tokens',
  'efficiency.col.share': 'Share',
  'efficiency.perMTitle': '$ per 1M output tokens, by model',
  'efficiency.perMFailed': 'Query failed: model breakdown unavailable.',
  'efficiency.perMEmpty': 'No priced model with output tokens in this period.',
  'efficiency.perMNeedsModel': 'This list reads breakdown card #2. Set that card’s group-by to “Model” to see it.',

  /* ----------------------------------------------------------- model mix */

  /* ---------------------------------------------------------------- when */
  'when.title': 'When',
  'when.hint': 'Hour × weekday, in your local time zone, folded from the selected window.',
  'when.hour': 'Hour',
  'when.tooShort': 'Under 48 hours there is not enough of each weekday-hour to fold. The timeline above already shows this window hour by hour.',

  /* -------------------------------------------------------- wall history */
  'wallHistory.title': 'Wall history',
  'wallHistory.hint': 'How often each subscription sat ON its limit, and for how long. A critical episode is an unbroken stretch at ≥ 90% of the 5-hour window; each Codex window is counted separately.',
  'wallHistory.empty': 'No limit snapshots in this period.',
  'wallHistory.col.subscription': 'Subscription',
  'wallHistory.col.episodes': 'Critical episodes',
  'wallHistory.col.time': 'Critical time',
  'wallHistory.col.prev': 'Prev critical time',

  /* ------------------------------------------------------------ sessions */
  'sessions.title': 'Sessions',
  'sessions.hint': 'Sorted by {sort}, 50 at a time. Click a row to open its detail; click the project or login to filter instead.',
  'sessions.empty': 'No sessions in this period.',
  'sessions.col.started': 'Started',
  'sessions.col.project': 'Project',
  'sessions.col.who': 'Login@machine',
  'sessions.col.model': 'Model',
  'sessions.col.duration': 'Duration',
  'sessions.col.turns': 'Turns',
  'sessions.col.tokens': 'Tokens',
  'sessions.col.cost': '$',
  'sessions.col.cacheHit': 'Cache hit',
  'sessions.col.subagent': 'Subagent %',
  'sessions.subTip': "{source}: billed by the month, not per session — the plan's cost is in real spend",
  'sessions.costTip': '{source}: {kind} cost',
  'sessions.mobile.tokens': '{tokens} tokens · {cost} · {turns} turns',
  'sessions.mobile.cache': 'cache hit {hit} · subagent {sub}',

  /* ----------------------------------------------------- session detail */
  'session.close': 'Close',
  'session.detail': 'Session detail',
  'session.loading': 'Loading…',
  'session.spendTile': 'spend ({kind})',
  'session.billedNote': 'Billed per call: this figure is an actual charge, not an API-equivalent estimate.',
  'session.notionalNote': 'Notional: what these tokens would have cost at API rates. The subscription is what is actually billed.',
  'session.unpricedNote': '{n} event(s) in this session have no price data — spend is a lower bound.',
  'session.started': ' · started {when}',
  'session.turnsTitle': 'Model requests ({n})',
  'session.col.time': 'Time',
  'session.col.model': 'Model',
  'session.col.effort': 'Effort',
  'session.col.input': 'Input',
  'session.col.output': 'Output',
  'session.col.cacheRead': 'Cache read',
  'session.col.cacheCreate': 'Cache create',
  'session.col.thinking': 'Thinking',
  'session.col.cost': '$',
  'session.col.sub': 'Sub',
  'session.loadMoreLeft': 'load more ({n} left)',
  'session.retentionPruned': 'Turns older than the retention window are gone.',
  'session.noTurns': 'No turns recorded.',
  'session.provenance': 'Request provenance and cache writes',
  'session.providerLine': '{provider} · client {client} · {billing} · account: {basis}',
  'session.providerUnknown': 'provider unknown',
  'session.billingUnknown': 'billing unknown',
  'session.unassigned': 'unassigned',
  'session.turnLine': '{request} · turn {turn} · root {root} · cache writes {writes} · tier {tier}',
  'session.legacyRequest': 'legacy request',
  'session.notRecorded': 'not recorded',
  /* --- repo progress: what the spend bought --------------------------- */
  /* Every threshold here comes from the repository's OWN close-time
     distribution. There is deliberately no string anywhere in this block that
     names a fixed number of days. */
  'repo.pick': 'Repository',
  'repo.flow.title': 'Issue flow',
  'repo.flow.hint': 'opened against closed, by week — the line is how many stayed open',
  'repo.flow.empty': 'No daily history has been shipped for this repository yet.',
  'repo.flow.aria': 'Issues opened and closed over {weeks} weeks; peak open count {open}.',
  'repo.flow.growing': 'The backlog grew by {n} over the last {weeks} weeks.',
  'repo.flow.shrinking': 'The backlog shrank by {n} over the last {weeks} weeks.',
  'repo.flow.level': 'The backlog held level over the last {weeks} weeks.',
  'repo.flow.openNow': '{n} open at the last report.',
  'repo.tip.opened': 'opened {n}',
  'repo.tip.closed': 'closed {n}',
  'repo.tip.open': 'open at end {n}',
  'repo.age.title': 'How old the open work is',
  'repo.age.hint': 'bands cut from this repository\u2019s own close times, not from a fixed number of days',
  'repo.age.noScale': 'No close-time percentiles have been shipped for this repository, so an age cannot be judged. A fixed threshold would say more about whoever picked it than about this repo.',
  'repo.age.upTo': 'up to {age} ({edge})',
  'repo.age.over': 'past {edge}',
  'repo.age.tip': '{n} open',
  'repo.age.scale': 'Scale: {parts}, measured {day}.',
  'repo.age.sample': 'Over {n} closes.',
  'repo.health.title': 'Can these checks be trusted',
  'repo.health.hint': 'Measured and worded by the shipper that watches this repository. This page shows them; it computes none of them.',
  'repo.health.none': 'No shipper measures this. "Nobody looked" and "nothing is wrong" are different answers, and an empty card supports only the first.',
  'repo.health.empty': 'A shipper sent this block with no readings in it. Read that as not measured, not as healthy.',
  'repo.health.k.touch': 'How long a red check waits for a human',
  'repo.health.k.rot': 'How much of the red is the check rotting, not the code',
  'repo.health.k.inflow': 'New cards with no machine-checkable exit',
  'repo.health.unread': 'not measured',
  'repo.health.observed': 'Read {when} ({age} ago).',
  'repo.health.source': 'From {source}.',
  'repo.health.stale': 'These figures are {age} old, past the {after} the shipper itself calls current. Read them as stale, not as good news.',
  'repo.health.noCadence': 'The shipper did not say how long these stay current, so this page does not judge their freshness. A threshold picked here would describe whoever picked it, not this repository.',
  'repo.backlog.title': 'Backlog',
  'repo.stalled.title': 'Open past p95',
  'repo.stalled.hint': 'older than 95% of everything this repository has ever closed',
  'repo.stalled.noScale': 'Without close-time percentiles there is no scale to call anything stalled against.',
  'repo.stalled.none': 'Nothing open is past this repository\u2019s p95.',
  'repo.stalled.shipped': 'already shipped',
  'repo.stalled.byLabel': 'Label',
  'repo.stalled.allLabels': 'All ({n})',
  'repo.stalled.onlyShipped': 'Already shipped ({n})',
  'repo.stalled.noMatch': 'Nothing stalled matches this filter. The backlog below it is unchanged \u2014 this is the filter, not the repository.',
  'repo.stalled.count': 'Showing {shown} of {total}.',
  'repo.stalled.sortedBy': 'Sorted by {what}, largest first.',
  'repo.sort.age': 'time open',
  'repo.sort.comments': 'comment count',
  'repo.col.issue': 'Issue',
  'repo.col.age': 'Open for',
  'repo.col.comments': 'Comments',
  'repo.col.shipped': 'Shipped?',
  'repo.col.burned': 'Burned',
  'repo.stalled.noCost': 'No money column: the issue numbers on the spend side cannot be bound to this repository.',

  // The issue axis (#58): money and progress read on one axis, with the part
  // nobody could attribute given a place on the chart rather than a footnote.
  'repo.cost.title': 'Where this window\u2019s money landed',
  'repo.cost.hint': 'bars are tokens \u2014 the three kinds of money are never added, so cost is per source, in the hover',
  'repo.cost.empty': 'No spend in this window.',
  'repo.cost.unattributed': 'Unattributed',
  'repo.cost.noBranch': '(no branch recorded)',
  'repo.cost.unknownIssue': '#{n} (not in this backlog)',
  'repo.cost.tokens': '{n} tokens',
  'repo.cost.tipWindow': 'This window: {tokens} tokens \u00b7 {cost}',
  'repo.cost.tipLifetime': 'All time: {cost}',
  'repo.cost.tipStale': 'Open {age}, past this repo\u2019s p95 of {after}',
  'repo.cost.tipBranches': 'Branches: {branches}',
  'repo.cost.concentration': 'The top {n} of {of} issues carry {share} of the attributed tokens.',
  'repo.cost.hidden': '{n} more issues are not shown.',
  'repo.cost.unattributedShare': '{share} of this window was never attributed to an issue.',
  'repo.cost.unattributedWhy': 'Mostly {branch} \u2014 work whose branch never said what it was for.',
  'repo.cost.noScale': 'No close-time percentiles have been shipped, so nothing here is called stalled.',
  'repo.cost.unbound': 'Spend rows carry an issue number and no repository, so this hub cannot say which repository these numbers belong to.',
  'repo.cost.undeclared': '{share} of this window ({tokens} tokens) named no repository and is not counted here.',
  'repo.cost.soleRepo': 'No endpoint has declared which repository it runs in yet, so this is the whole hub\u2019s spend \u2014 readable as this repository\u2019s only because the hub holds no other.',

  // The other half of progress (#89/PR #35): the pre-release steps a release
  // batch is waiting on a person for. Grouped by owner, never by viewer --
  // see repo.human.everyone for why this hub cannot tell two colleagues apart.
  'repo.human.title': 'Waiting on a person',
  'repo.human.hint': 'pre-release steps a release batch is blocked on — no check can turn these green',
  'repo.human.everyone': 'Everyone’s, not just yours: this hub’s sign-in cannot tell two colleagues apart, so it does not pretend to know which rows are yours.',
  'repo.human.none': 'Nothing is waiting on anybody.',
  'repo.human.untold': '{n} of these have not been sent to anybody yet — that delay is the system’s, not the owner’s.',
  'repo.human.group': '{n} open · longest {age}',
  'repo.human.kind.notAPerson': 'not a person',
  'repo.human.kind.unresolved': 'owner unresolved',
  'repo.human.col.step': 'Step',
  'repo.human.col.waiting': 'Waiting',
  'repo.human.col.told': 'Told',
  'repo.human.notTold': 'nobody told',
  'repo.human.noHow': 'The author wrote no "how to do it".',
  'repo.human.ratio.title': 'How much of it needs a hand',
  'repo.human.ratio.hint': 'share of release fragments carrying at least one manual step, by week',
  'repo.human.ratio.none': 'No daily fragment counts have been shipped for this repository yet.',
  'repo.human.ratio.window': '{pct} across the last {weeks} weeks.',
  'repo.human.ratio.down': 'Week of {week}: {pct}, down from {before}.',
  'repo.human.ratio.up': 'Week of {week}: {pct}, up from {before}.',
  'repo.human.ratio.level': 'Week of {week}: {pct}, level with {before}.',
  'repo.human.ratio.unknown': 'Not enough weeks yet to say which way it is going.',
  'repo.human.ratio.aria': 'Share of release fragments needing a manual step over {weeks} weeks; {pct} across the window.',
  'repo.human.tip': '{pct} — {n} of {total} fragments',
  'repo.unit.m': '{n}m',
  'repo.unit.h': '{n}h',
  'repo.unit.d': '{n}d',
  'repo.unit.mo': '{n}mo',
};
