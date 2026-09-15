package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// Account is a subscription tracked by this hub.
type Account struct {
	Source           string     `json:"source"`
	AccountUUID      string     `json:"account_uuid"`
	Email            string     `json:"email"`
	OrgUUID          string     `json:"org_uuid"`
	OrgName          string     `json:"org_name"`
	SubscriptionType string     `json:"subscription_type"`
	RateLimitTier    string     `json:"rate_limit_tier"`
	DisplayName      string     `json:"display_name"`
	AccountCreatedAt *time.Time `json:"account_created_at,omitempty"`
	LabelLocked      bool       `json:"label_locked"`
	FirstSeen        time.Time  `json:"first_seen"`
	LastSeen         time.Time  `json:"last_seen"`
	EndpointCount    int        `json:"endpoint_count"`
}

// Label is THE display name for a subscription, everywhere.
//
// Every surface must resolve it the same way or the same account appears under
// two names on one page. Preference order: a name set by hand, then whatever
// the login reported, then the identifier itself — never blank, because a blank
// row is unclickable and unreadable.
func (a Account) Label() string {
	switch {
	case a.Email != "":
		return a.Email
	case a.DisplayName != "":
		return a.DisplayName
	default:
		return a.AccountUUID
	}
}

// Inferred reports whether this subscription was identified by its rate-limit
// schedule rather than by a login. The UI says so rather than presenting a
// heuristic as a fact.
func (a Account) Inferred() bool { return strings.HasPrefix(a.AccountUUID, "win_") }

// ListAccounts returns every subscription on this hub.
func (s *Store) ListAccounts() ([]Account, error) {
	rows, err := s.read.Query(`
		SELECT a.account_uuid, a.email, a.org_uuid, a.org_name,
		       a.subscription_type, a.rate_limit_tier, a.display_name,
		       a.account_created_at, a.label_locked, a.first_seen, a.last_seen,
		       (SELECT COUNT(*) FROM endpoints e WHERE e.account_uuid = a.account_uuid
		        OR EXISTS (SELECT 1 FROM endpoint_accounts ea WHERE ea.endpoint_id = e.endpoint_id AND ea.account_uuid = a.account_uuid)),
		       a.source
		FROM accounts a
		ORDER BY a.last_seen DESC`)
	if err != nil {
		return nil, fmt.Errorf("list accounts: %w", err)
	}
	defer rows.Close()

	var out []Account
	for rows.Next() {
		var a Account
		var first, last string
		var created sql.NullString
		if err := rows.Scan(&a.AccountUUID, &a.Email, &a.OrgUUID, &a.OrgName,
			&a.SubscriptionType, &a.RateLimitTier, &a.DisplayName,
			&created, &a.LabelLocked, &first, &last, &a.EndpointCount, &a.Source); err != nil {
			return nil, err
		}
		a.AccountCreatedAt = parseNullTime(created)
		a.FirstSeen, _ = time.Parse(rfc, first)
		a.LastSeen, _ = time.Parse(rfc, last)
		out = append(out, a)
	}
	return out, rows.Err()
}

// ListEndpoints returns the endpoints for one account, or all when account is
// empty.
func (s *Store) ListEndpoints(account string, sources ...string) ([]Endpoint, error) {
	// Repo shippers are enrolled endpoints but they are not part of the fleet:
	// they never collect usage, so every surface fed from here -- the roster,
	// the stale-agent finding -- would report one as a machine that stopped
	// reporting. Their health is visible where it means something, on the
	// repositories list's observed_at.
	q := endpointColumns + ` FROM endpoints WHERE kind = 'agent'`
	var args []any
	if account != "" && account != AllAccounts {
		q += ` AND (account_uuid = ? OR endpoint_id IN (SELECT endpoint_id FROM endpoint_accounts WHERE account_uuid = ?))`
		args = append(args, account, account)
	}
	if len(sources) > 0 && sources[0] != "" {
		q += ` AND endpoint_id IN (SELECT ea.endpoint_id FROM endpoint_accounts ea JOIN accounts a ON a.account_uuid=ea.account_uuid WHERE a.source=?)`
		args = append(args, sources[0])
	}
	q += ` ORDER BY last_seen DESC NULLS LAST, label`

	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("list endpoints: %w", err)
	}
	defer rows.Close()

	var out []Endpoint
	for rows.Next() {
		e, err := scanEndpoint(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *e)
	}
	return out, rows.Err()
}

// LatestLimits returns the freshest snapshot for an account.
//
// A nil snapshot with a nil error means no endpoint has ever managed to read
// this account's limits. Callers must render that as "unavailable", never as
// zero utilization.
func (s *Store) LatestLimits(account string) (*model.LimitsSnapshot, error) {
	row := s.read.QueryRow(`
		SELECT account_uuid, endpoint_id, observed_at,
		       five_hour_pct, five_hour_resets_at,
		       seven_day_pct, seven_day_resets_at,
		       scoped_json, extra_usage_json, spend_json
		FROM limit_snapshots
		WHERE account_uuid = ?
		ORDER BY observed_at DESC LIMIT 1`, account)

	var snap model.LimitsSnapshot
	var observed string
	var fiveReset, sevenReset sql.NullString
	var scoped string
	err := row.Scan(&snap.AccountUUID, &snap.EndpointID, &observed,
		&snap.FiveHour.Utilization, &fiveReset,
		&snap.SevenDay.Utilization, &sevenReset,
		&scoped, &snap.ExtraUsageJSON, &snap.SpendJSON)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("latest limits: %w", err)
	}

	snap.ObservedAt, _ = time.Parse(rfc, observed)
	snap.FiveHour.ResetsAt = parseNullTime(fiveReset)
	snap.SevenDay.ResetsAt = parseNullTime(sevenReset)
	if scoped != "" {
		_ = json.Unmarshal([]byte(scoped), &snap.Scoped)
	}
	return &snap, nil
}

func parseNullTime(ns sql.NullString) *time.Time {
	if !ns.Valid || ns.String == "" {
		return nil
	}
	t, err := time.Parse(rfc, ns.String)
	if err != nil {
		return nil
	}
	return &t
}

// EventsInRange returns the raw events for an account within a period.
// Reconciliation needs the individual rows, not an aggregate.
func (s *Store) EventsInRange(account string, start, end time.Time) ([]model.UsageEvent, error) {
	q := fmt.Sprintf(`
		SELECT endpoint_id, session_id, message_uuid, ts, model,
		       input_tokens, output_tokens, cache_create_5m_tokens,
		       cache_create_1h_tokens, cache_read_tokens, thinking_tokens,
		       cost_usd, cwd, git_branch, is_sidechain, account_uuid, source
		FROM usage_events
		WHERE %s ts >= ? AND ts < ?`, accountClause(account))

	rows, err := s.read.Query(q, accountArgs(account, fmtTime(start), fmtTime(end))...)
	if err != nil {
		return nil, fmt.Errorf("events in range: %w", err)
	}
	defer rows.Close()

	var out []model.UsageEvent
	for rows.Next() {
		var e model.UsageEvent
		var ts string
		var cost sql.NullFloat64
		if err := rows.Scan(&e.EndpointID, &e.SessionID, &e.MessageUUID, &ts, &e.Model,
			&e.InputTokens, &e.OutputTokens, &e.CacheCreate5m, &e.CacheCreate1h,
			&e.CacheRead, &e.Thinking, &cost, &e.CWD, &e.GitBranch, &e.IsSidechain,
			&e.AccountUUID, &e.Source); err != nil {
			return nil, err
		}
		e.TS, _ = time.Parse(rfc, ts)
		if cost.Valid {
			c := cost.Float64
			e.CostUSD = &c
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// tokenColumnsExpr is THE column list behind "tokens" on this hub, unwrapped.
//
// A caller that needs the per-row expression rather than a SUM over it (a
// CASE branch gating on is_sidechain, or a rollup table whose rows are
// already per-hour sums and only needs summing again across hours) reuses
// this constant rather than retyping the column list — hourlyTokens
// (rollup_query.go) is built from exactly this, which is what keeps it from
// drifting out of sync with tokenSumExpr below.
const tokenColumnsExpr = `(input_tokens + output_tokens + cache_create_5m_tokens + cache_create_1h_tokens + cache_read_tokens)`

// tokenSumExpr is THE definition of "tokens" on this hub.
//
// It exists as one constant because two totals on one page that disagree by a
// cache-creation column would be worse than either -- LifetimeTotals already
// carries a comment saying so. Every query that sums tokens uses this.
const tokenSumExpr = `SUM` + tokenColumnsExpr

// Bucket is one row of a breakdown.
type Bucket struct {
	Key    string `json:"key"`
	Label  string `json:"label"`
	Events int64  `json:"events"`
	Tokens int64  `json:"tokens"`

	// Cost is kept split by source and has no blended member, because the
	// figures in it are not the same kind of money. There was a CostUSD
	// float64 here; it was removed rather than deprecated so that every
	// surface which used to print one number had to be revisited by the
	// compiler. See CostBySource.
	Cost CostBySource `json:"cost"`

	// Unpriced is the whole bucket's unpriced request COUNT, a count being
	// the one thing here that adds up across sources. The per-source share of
	// it is in Cost.
	Unpriced  int64 `json:"unpriced_events"`
	Sidechain int64 `json:"sidechain_tokens"`

	// Composition, filled by rollup-backed queries only.
	InputTokens       int64 `json:"input_tokens,omitempty"`
	OutputTokens      int64 `json:"output_tokens,omitempty"`
	CacheReadTokens   int64 `json:"cache_read_tokens,omitempty"`
	CacheCreateTokens int64 `json:"cache_create_tokens,omitempty"`
	ThinkingTokens    int64 `json:"thinking_tokens,omitempty"`

	// The same key in the previous period, when the caller asked to compare.
	PrevEvents   int64        `json:"prev_events,omitempty"`
	PrevUnpriced int64        `json:"prev_unpriced_events,omitempty"`
	PrevTokens   int64        `json:"prev_tokens,omitempty"`
	PrevCost     CostBySource `json:"prev_cost,omitempty"`
}

// Dimension names a breakdown axis.
type Dimension string

const (
	BySource   Dimension = "source"
	ByEndpoint Dimension = "endpoint"
	ByProject  Dimension = "project"
	BySession  Dimension = "session"
	ByModel    Dimension = "model"

	// ByProvider is the upstream that actually served the request.
	//
	// It is derivable from neither the model id nor the source: a gateway with
	// failover reaches one model id through several upstreams at several
	// contracted prices, and one source fronts all of them. This is the axis
	// that answers "which contract did this money go to". The empty bucket
	// means the reporting side declared none -- see ProviderNote.
	ByProvider Dimension = "provider"
	ByBranch   Dimension = "branch"

	// ByAccount makes the subscription an ordinary axis rather than a mode the
	// whole page is stuck in. "Which of my subscriptions is this spend on" is
	// the same shape of question as "which machine" or "which project".
	ByAccount Dimension = "account"

	// ByUser is the OS login the spend happened under. On a shared box that is
	// the axis an operator actually asks about ("who on the build server is
	// burning the quota"), and it is not derivable from any other column:
	// hostname is the machine, cwd is a project path, and one machine's users
	// cannot read each other's transcripts.
	ByUser Dimension = "user"

	// ByTeam allocates spend to an operator-assigned team.
	//
	// It is the one dimension not stored on the event row. Team is a property
	// of the endpoint, resolved by join at query time, so re-assigning a
	// machine moves its WHOLE history -- freezing a team at ingest would mean
	// a re-assignment silently changed nothing that had already happened.
	ByTeam Dimension = "team"

	// ByEffort is the reasoning effort the turn was run at.
	ByEffort Dimension = "effort"

	// ByEntrypoint is how the turn was invoked (cli, ide, ...).
	ByEntrypoint Dimension = "entrypoint"
)

// AllAccounts asks for every subscription at once.
//
// It is a distinct sentinel rather than the empty string on purpose: "" is
// what an uninitialised variable looks like, and answering that with a
// silently blended total across subscriptions is the failure this guard
// exists for. Spanning subscriptions has to be something the caller typed.
const AllAccounts = "*"

// column maps a dimension to its SQL expression. Whitelisting rather than
// interpolating the caller's string is what keeps this injection-proof.
func (d Dimension) column() (string, error) {
	switch d {
	case BySource:
		return "source", nil
	case ByAccount:
		return "account_uuid", nil
	case ByEndpoint:
		return "endpoint_id", nil
	case ByProject:
		return "cwd", nil
	case BySession:
		return "session_id", nil
	case ByModel:
		return "model", nil
	case ByProvider:
		return "provider", nil
	case ByBranch:
		return "git_branch", nil
	case ByUser:
		return "os_user", nil
	case ByTeam:
		return `COALESCE((SELECT e.team FROM endpoints e
		                  WHERE e.endpoint_id = usage_events.endpoint_id), '')`, nil
	case ByEffort:
		return "effort", nil
	case ByEntrypoint:
		return "entrypoint", nil
	default:
		return "", fmt.Errorf("unknown dimension %q", d)
	}
}

// UsageBy aggregates spend along one dimension.
//
// Pass a specific account uuid to scope to one subscription, or AllAccounts to
// span every one. The empty string is refused: see AllAccounts for why the
// distinction matters.
//
// Token figures are additive and may be summed across subscriptions.
// Rate-limit utilization is NOT — see LimitsAcross. Cost is additive across
// subscriptions but NOT across sources, which is why it comes back as a
// CostBySource rather than a number.
func (s *Store) UsageBy(account string, d Dimension, start, end time.Time, limit int) ([]Bucket, error) {
	if account == "" {
		return nil, fmt.Errorf("account is required: pass a uuid, or store.AllAccounts to span every subscription")
	}
	col, err := d.column()
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = 50
	}

	q := fmt.Sprintf(`
		SELECT %s AS k,
		       COUNT(*),
		       %s,
		       COALESCE(SUM(CASE WHEN is_sidechain = 1
		            THEN input_tokens + output_tokens + cache_create_5m_tokens
		                 + cache_create_1h_tokens + cache_read_tokens
		            ELSE 0 END), 0),
		       %s
		FROM usage_events
		WHERE %s ts >= ? AND ts < ?
		GROUP BY k
		ORDER BY 3 DESC
		LIMIT ?`, col, tokenSumExpr, eventCostSplit.sel, accountClause(account))

	rows, err := s.read.Query(q, accountArgs(account, fmtTime(start), fmtTime(end), limit)...)
	if err != nil {
		return nil, fmt.Errorf("usage by %s: %w", d, err)
	}
	defer rows.Close()

	var out []Bucket
	for rows.Next() {
		var b Bucket
		cs := eventCostSplit.scan()
		if err := rows.Scan(append([]any{&b.Key, &b.Events, &b.Tokens, &b.Sidechain}, cs.dest()...)...); err != nil {
			return nil, err
		}
		b.Cost = cs.costs()
		b.Unpriced = b.Cost.Unpriced()
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	switch d {
	case ByEndpoint:
		s.labelEndpoints(out)
	case ByAccount:
		s.labelAccounts(out)
	case ByTeam:
		labelTeams(out)
	}
	return out, nil
}

// labelTeams names the empty team.
//
// An unassigned endpoint keeps its bucket rather than being filtered out: a
// team breakdown whose rows do not add up to the fleet total is worse than one
// with an "unassigned" row in it.
func labelTeams(bs []Bucket) {
	for i := range bs {
		if bs[i].Key == "" {
			bs[i].Label = "unassigned"
			continue
		}
		bs[i].Label = bs[i].Key
	}
}

// accountClause returns the WHERE fragment that scopes to one subscription, or
// nothing at all for AllAccounts.
func accountClause(account string) string {
	if account == AllAccounts {
		return ""
	}
	return "account_uuid = ? AND"
}

// accountArgs prepends the account argument unless the query spans all of them.
func accountArgs(account string, rest ...any) []any {
	if account == AllAccounts {
		return rest
	}
	return append([]any{account}, rest...)
}

// labelAccounts replaces account uuids with the email they belong to.
func (s *Store) labelAccounts(bs []Bucket) {
	accts, err := s.ListAccounts()
	if err != nil {
		return
	}
	byID := make(map[string]string, len(accts))
	for _, a := range accts {
		byID[a.AccountUUID] = a.Label()
	}
	for i := range bs {
		if l := byID[bs[i].Key]; l != "" {
			bs[i].Label = l
		}
	}
}

// labelEndpoints replaces opaque endpoint ids with their human labels.
func (s *Store) labelEndpoints(bs []Bucket) {
	eps, err := s.ListEndpoints("")
	if err != nil {
		return
	}
	byID := make(map[string]string, len(eps))
	for _, e := range eps {
		label := e.Label
		if label == "" {
			label = e.Hostname
		}
		byID[e.ID] = label
	}
	for i := range bs {
		if l := byID[bs[i].Key]; l != "" {
			bs[i].Label = l
		}
	}
}

// Granularity buckets a time series.
type Granularity string

const (
	Hourly Granularity = "hour"
	Daily  Granularity = "day"
)

// format maps a granularity to a strftime pattern.
func (g Granularity) format() (string, error) {
	switch g {
	case Hourly:
		return "%Y-%m-%dT%H:00", nil
	case Daily:
		return "%Y-%m-%d", nil
	default:
		return "", fmt.Errorf("unknown granularity %q", g)
	}
}

// History returns a time series of spend, for one subscription or all of them.
func (s *Store) History(account string, g Granularity, start, end time.Time) ([]Bucket, error) {
	if account == "" {
		return nil, fmt.Errorf("account is required: pass a uuid, or store.AllAccounts to span every subscription")
	}
	f, err := g.format()
	if err != nil {
		return nil, err
	}

	q := fmt.Sprintf(`
		SELECT strftime(?, ts) AS k,
		       COUNT(*),
		       %s,
		       0,
		       %s
		FROM usage_events
		WHERE %s ts >= ? AND ts < ?
		GROUP BY k ORDER BY k`, tokenSumExpr, eventCostSplit.sel, accountClause(account))

	// The strftime pattern is the first placeholder, so it leads the argument
	// list ahead of the optional account scope.
	args := append([]any{f}, accountArgs(account, fmtTime(start), fmtTime(end))...)
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("history: %w", err)
	}
	defer rows.Close()

	var out []Bucket
	for rows.Next() {
		var b Bucket
		cs := eventCostSplit.scan()
		if err := rows.Scan(append([]any{&b.Key, &b.Events, &b.Tokens, &b.Sidechain}, cs.dest()...)...); err != nil {
			return nil, err
		}
		b.Cost = cs.costs()
		b.Unpriced = b.Cost.Unpriced()
		out = append(out, b)
	}
	return out, rows.Err()
}

// ModelSplit breaks an account's spend down by model over a period.
func (s *Store) ModelSplit(account string, start, end time.Time) ([]Bucket, error) {
	return s.UsageBy(account, ByModel, start, end, 50)
}

// AccountSwitch is a recorded change of subscription on one endpoint.
type AccountSwitch struct {
	Source      string    `json:"source,omitempty"`
	ProfileID   string    `json:"profile_id,omitempty"`
	EndpointID  string    `json:"endpoint_id"`
	FromAccount string    `json:"from_account"`
	ToAccount   string    `json:"to_account"`
	ObservedAt  time.Time `json:"observed_at"`
}

// AccountSwitches lists login changes, newest first. The UI shows these
// alongside historical data because rows ingested before a switch keep their
// old attribution and cannot be corrected.
//
// account == "" or AllAccounts lists every switch on the hub; a specific uuid
// scopes to switches touching that subscription on either side, since a
// switch AWAY from an account is exactly as relevant to it as a switch INTO
// it.
func (s *Store) AccountSwitches(account string, limit int) ([]AccountSwitch, error) {
	if limit <= 0 {
		limit = 50
	}
	q := `SELECT endpoint_id, from_account, to_account, observed_at FROM account_switches`
	args := []any{}
	if account != "" && account != AllAccounts {
		q += ` WHERE from_account = ? OR to_account = ?`
		args = append(args, account, account)
	}
	q += ` ORDER BY observed_at DESC LIMIT ?`
	args = append(args, limit)
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("account switches: %w", err)
	}
	defer rows.Close()

	var out []AccountSwitch
	for rows.Next() {
		var a AccountSwitch
		var at string
		if err := rows.Scan(&a.EndpointID, &a.FromAccount, &a.ToAccount, &at); err != nil {
			return nil, err
		}
		a.ObservedAt, _ = time.Parse(rfc, at)
		out = append(out, a)
	}
	return out, rows.Err()
}

// EndpointAccount is one subscription seen running on one endpoint.
//
// Concurrent, not sequential: a machine+user can appear here several times over
// overlapping windows because Claude Code takes its account from the process
// environment. Reading two rows as "it switched" is the mistake this type
// replaced.
type EndpointAccount struct {
	EndpointID   string `json:"endpoint_id"`
	EndpointName string `json:"endpoint_name"`
	OSUser       string `json:"os_user"`
	AccountUUID  string `json:"account_uuid"`
	AccountName  string `json:"account_name"`
	// Origin is "login" for the endpoint's own Claude Code login, "session"
	// for a subscription observed running in a session on it.
	Origin    string    `json:"origin"`
	FirstSeen time.Time `json:"first_seen"`
	LastSeen  time.Time `json:"last_seen"`
}

// EndpointAccounts lists which subscriptions each endpoint has been seen
// running, most recently active first.
//
// account == "" or AllAccounts lists every row on the hub; a specific uuid
// scopes to that subscription's own rows.
func (s *Store) EndpointAccounts(account string, limit int, sources ...string) ([]EndpointAccount, error) {
	if account == "all" {
		account = AllAccounts
	}
	if limit <= 0 {
		limit = 200
	}
	q := `
		SELECT ea.endpoint_id,
		       COALESCE(NULLIF(ep.label, ''), NULLIF(ep.hostname, ''), ea.endpoint_id),
		       COALESCE(ep.os_user, ''),
		       ea.account_uuid,
		       -- Email first, like every other account label on the page.
		       -- display_name is NOT unique: two of this hub's three
		       -- subscriptions are both called "Lee", so preferring it renders
		       -- two different plans under one name and the card silently
		       -- claims a machine runs the same subscription twice.
		       COALESCE(NULLIF(a.email, ''), NULLIF(a.display_name, ''), ea.account_uuid),
		       ea.origin, ea.first_seen, ea.last_seen
		FROM endpoint_accounts ea
		LEFT JOIN endpoints ep ON ep.endpoint_id = ea.endpoint_id
		LEFT JOIN accounts  a  ON a.account_uuid  = ea.account_uuid WHERE 1=1`
	args := []any{}
	if account != "" && account != AllAccounts {
		q += ` AND ea.account_uuid = ?`
		args = append(args, account)
	}
	if len(sources) > 0 && sources[0] != "" {
		q += ` AND a.source=?`
		args = append(args, sources[0])
	}
	q += ` ORDER BY ea.last_seen DESC LIMIT ?`
	args = append(args, limit)
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("endpoint accounts: %w", err)
	}
	defer rows.Close()

	var out []EndpointAccount
	for rows.Next() {
		var e EndpointAccount
		var first, last string
		if err := rows.Scan(&e.EndpointID, &e.EndpointName, &e.OSUser, &e.AccountUUID,
			&e.AccountName, &e.Origin, &first, &last); err != nil {
			return nil, err
		}
		e.FirstSeen, _ = time.Parse(rfc, first)
		e.LastSeen, _ = time.Parse(rfc, last)
		out = append(out, e)
	}
	return out, rows.Err()
}

// LifetimeTotals is every turn and token this hub has ever stored, across every
// subscription.
//
// Deliberately unscoped: no account, no time range. It is the one number that
// only ever grows, which is what makes it worth putting at the top of a page —
// any windowed total falls as old turns age out of the window.
//
// The token expression matches UsageBy's exactly. Two "total tokens" on one
// page that disagree by a cache-creation column would be worse than either.
func (s *Store) LifetimeTotals() (turns, tokens int64, err error) {
	err = s.read.QueryRow(fmt.Sprintf(`
		SELECT COALESCE(SUM(events),0), COALESCE(%s, 0)
		FROM usage_hourly`, tokenSumExpr)).Scan(&turns, &tokens)
	if err != nil {
		return 0, 0, fmt.Errorf("lifetime totals: %w", err)
	}
	return turns, tokens, nil
}

// UserSummary is one OS login's spend across the whole hub.
//
// Scoped by os_user rather than by endpoint: the same person on two machines
// is one person, and that is the question /u/<login> answers.
type UserSummary struct {
	OSUser string `json:"os_user"`
	// Teams is a LIST because a login can work on machines allocated to
	// different teams. Collapsing it to one would attribute the rest of their
	// spend to a team that never received it.
	Teams  []string `json:"teams"`
	Turns  int64    `json:"turns"`
	Tokens int64    `json:"tokens"`

	// Cost is split by source for the same reason Bucket.Cost is: a person
	// who ran Claude and gateway work in the same week has two figures, and
	// one of them is a real invoice.
	Cost     CostBySource `json:"cost"`
	Projects int          `json:"projects"`
	Machines int          `json:"machines"`
}

// UserSummary totals one OS login over a period.
//
// An unknown login returns a zeroed summary and no error: "this person has no
// usage in this range" is an ordinary answer, and a 500 would be a lie about
// what went wrong.
func (s *Store) UserSummary(osUser string, start, end time.Time) (*UserSummary, error) {
	if osUser == "" {
		return nil, fmt.Errorf("os user is required")
	}
	out := &UserSummary{OSUser: osUser}

	cs := eventCostSplit.scan()
	q := fmt.Sprintf(`
		SELECT COUNT(*), COALESCE(%s, 0),
		       COUNT(DISTINCT cwd), COUNT(DISTINCT endpoint_id),
		       %s
		FROM usage_events
		WHERE os_user = ? AND ts >= ? AND ts < ?`, tokenSumExpr, eventCostSplit.sel)
	dest := append([]any{&out.Turns, &out.Tokens, &out.Projects, &out.Machines}, cs.dest()...)
	if err := s.read.QueryRow(q, osUser, fmtTime(start), fmtTime(end)).Scan(dest...); err != nil {
		return nil, fmt.Errorf("user summary: %w", err)
	}
	out.Cost = cs.costs()

	rows, err := s.read.Query(`
		SELECT DISTINCT e.team
		FROM usage_events u
		JOIN endpoints e ON e.endpoint_id = u.endpoint_id
		WHERE u.os_user = ? AND u.ts >= ? AND u.ts < ? AND e.team <> ''
		ORDER BY e.team`, osUser, fmtTime(start), fmtTime(end))
	if err != nil {
		return nil, fmt.Errorf("user teams: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var team string
		if err := rows.Scan(&team); err != nil {
			return nil, err
		}
		out.Teams = append(out.Teams, team)
	}
	return out, rows.Err()
}

// UsageByUser aggregates one OS login's spend along a dimension.
//
// Spans every subscription on purpose: a person's own page is about them, not
// about which plan paid. Tokens are additive across subscriptions, so that
// total is legitimate -- unlike utilization, which is never summed, and unlike
// cost ACROSS SOURCES, which is why the cost here stays split.
func (s *Store) UsageByUser(osUser string, d Dimension, start, end time.Time, limit int) ([]Bucket, error) {
	if osUser == "" {
		return nil, fmt.Errorf("os user is required")
	}
	col, err := d.column()
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = 50
	}

	q := fmt.Sprintf(`
		SELECT %s AS k, COUNT(*), %s, 0, %s
		FROM usage_events
		WHERE os_user = ? AND ts >= ? AND ts < ?
		GROUP BY k ORDER BY 3 DESC LIMIT ?`, col, tokenSumExpr, eventCostSplit.sel)

	rows, err := s.read.Query(q, osUser, fmtTime(start), fmtTime(end), limit)
	if err != nil {
		return nil, fmt.Errorf("usage by user %s: %w", d, err)
	}
	defer rows.Close()

	var out []Bucket
	for rows.Next() {
		var b Bucket
		cs := eventCostSplit.scan()
		if err := rows.Scan(append([]any{&b.Key, &b.Events, &b.Tokens, &b.Sidechain}, cs.dest()...)...); err != nil {
			return nil, err
		}
		b.Cost = cs.costs()
		b.Unpriced = b.Cost.Unpriced()
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	switch d {
	case ByEndpoint:
		s.labelEndpoints(out)
	case ByAccount:
		s.labelAccounts(out)
	case ByTeam:
		labelTeams(out)
	}
	return out, nil
}
