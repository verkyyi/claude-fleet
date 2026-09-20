// internal/api/issue_cost.go
package api

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

// The issue axis, where money and progress are read side by side.
//
// #57 put an issue number on every spend row that could carry one. This is the
// read that #58 asked for: for one repository and one window, what the money
// landed on, what each issue has cost over its whole life, and -- always, never
// as an option -- how much of the window was never attributed to anything.
//
// Three rules from the issue, and each is enforced here rather than left to a
// renderer:
//
//   - The three kinds of money are never added. Every figure travels as a
//     store.CostBySource, which has no Total() to reach for.
//   - The unattributed bucket has a place on the chart. The response carries it
//     next to the attributed total and the grand total, so a reader can check
//     that the parts sum instead of trusting that they do.
//   - Thresholds come from the repository. `stale` is null, not false, when no
//     shipper has computed close-time percentiles -- the same refusal
//     /v1/repo/issues?stale=1 already makes.

// IssueCostRow is one issue with both its money and its progress.
type IssueCostRow struct {
	Number int64 `json:"number"`
	// Known is false when the hub holds no repo_issues row for this number.
	//
	// That is a normal state, not an error: per-issue rows are bounded by
	// retention while usage_hourly is kept forever, so spend outlives the
	// issue it names. The money still has to appear -- dropping it would break
	// the sum the whole response exists to let a reader check -- so the row
	// ships with its progress fields empty and this flag false.
	Known     bool       `json:"known"`
	Title     string     `json:"title,omitempty"`
	State     string     `json:"state,omitempty"`
	URL       string     `json:"url,omitempty"`
	CreatedAt *time.Time `json:"created_at,omitempty"`
	ClosedAt  *time.Time `json:"closed_at,omitempty"`
	// AgeSeconds is time open, to closed_at once closed. Null when the issue
	// is not known.
	AgeSeconds *float64 `json:"age_seconds,omitempty"`
	// Stale is null when this repo has shipped no percentiles. Null means "the
	// scale is unknown", which is a different statement from false, and the
	// page has to be able to tell them apart.
	Stale *bool `json:"stale"`
	// Window is the spend inside the requested range.
	Window store.SpendTotal `json:"window"`
	// Lifetime is every hour ever attributed to this issue, unbounded by the
	// window. This is the "from open to close, what did it cost" figure, and
	// it is deliberately not clipped to the issue's own dates -- see
	// store.IssueLifetimeSpend.
	Lifetime store.SpendTotal `json:"lifetime"`
}

// handleRepoCost serves the issue axis for one repository.
func (s *Server) handleRepoCost(w http.ResponseWriter, r *http.Request) {
	repo, start, end, ok := repoScope(w, r)
	if !ok {
		return
	}
	limit := 0
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 || n > 1000 {
			httpError(w, http.StatusBadRequest, "limit: want 1..1000")
			return
		}
		limit = n
	}
	out, err := s.IssueCost(repo, start, end, limit)
	if err != nil {
		// The binding refusal is a 409, the same answer
		// /v1/repo/issues?stale=1 gives when no scale has been shipped: the
		// caller asked a well-formed question the hub cannot answer honestly
		// yet, which is neither its fault nor a server fault.
		var bind *issueBindingError
		if errors.As(err, &bind) {
			httpError(w, http.StatusConflict, err.Error())
			return
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// IssueCost is the issue axis for one repository, as both HTTP and MCP serve
// it.
//
// One body rather than two, because the two surfaces have drifted before: the
// README's own note about MCP advertising seven tools for an API that grouped
// by twelve is what #60 had to go and fix. A refusal, a null scale or a newly
// added field has to reach an agent and a browser on the same day.
func (s *Server) IssueCost(repo string, start, end time.Time, limit int) (map[string]any, error) {
	if err := s.issueBinding(repo); err != nil {
		return nil, err
	}

	// AllAccounts, and not a caller-chosen subscription. A repository is
	// worked by endpoints on several plans at once -- that is exactly why
	// repo_issues carries no account_uuid (schema.sql) -- so scoping this to
	// one subscription would report a fraction of an issue's cost as its cost.
	f := store.Filter{Account: store.AllAccounts, Start: start, End: end}.AlignHours()
	page, err := s.Store.SpendByIssue(f, limit)
	if err != nil {
		return nil, err
	}

	numbers := make([]int64, 0, len(page.Issues))
	for _, i := range page.Issues {
		numbers = append(numbers, i.Number)
	}

	now := time.Now()
	scale, err := s.Store.RepoCloseScale(repo)
	if err != nil {
		return nil, err
	}
	known, err := s.repoIssuesByNumber(repo, numbers, now)
	if err != nil {
		return nil, err
	}
	lifetime, err := s.Store.IssueLifetimeSpend(store.AllAccounts, numbers)
	if err != nil {
		return nil, err
	}

	rows := make([]IssueCostRow, 0, len(page.Issues))
	for _, spend := range page.Issues {
		row := IssueCostRow{
			Number:   spend.Number,
			Window:   spend.SpendTotal,
			Lifetime: lifetime[spend.Number],
			Stale:    staleAgainst(scale, nil),
		}
		if issue, ok := known[spend.Number]; ok {
			age := issue.AgeSeconds
			created := issue.CreatedAt
			row.Known = true
			row.Title, row.State, row.URL = issue.Title, issue.State, issue.URL
			row.CreatedAt, row.ClosedAt = &created, issue.ClosedAt
			row.AgeSeconds = &age
			row.Stale = staleAgainst(scale, &age)
		}
		rows = append(rows, row)
	}

	return map[string]any{
		"repo":   repo,
		"since":  start.UTC(),
		"until":  end.UTC(),
		"issues": rows,
		// The full count before truncation, so a top-N cannot be mistaken for
		// the whole distribution.
		"distinct_issues": page.Distinct,
		"attributed":      page.Attributed,
		"unattributed":    page.Unattributed,
		"total":           page.Total,
		// Null when nobody has computed percentiles. Readers must render that
		// as "scale unknown" and must not substitute one.
		"scale": scale,
	}, nil
}

// staleAgainst judges one age against the repo's own p95.
//
// Null on a missing scale and null on a missing age, both deliberately. The
// only alternative is to pick a threshold, and a confident "stale" badge
// computed from a number nobody measured is indistinguishable from a measured
// one once it is on the page.
func staleAgainst(scale *store.RepoScale, ageSeconds *float64) *bool {
	if scale == nil || scale.P95Seconds == nil || ageSeconds == nil {
		return nil
	}
	v := *ageSeconds >= *scale.P95Seconds
	return &v
}

// repoIssuesByNumber fetches the progress rows for a set of issue numbers.
func (s *Server) repoIssuesByNumber(repo string, numbers []int64, now time.Time) (map[int64]store.RepoIssueRow, error) {
	out := map[int64]store.RepoIssueRow{}
	if len(numbers) == 0 {
		return out, nil
	}
	rows, err := s.Store.RepoIssues(store.RepoIssueFilter{
		Repo: repo, Numbers: numbers, Limit: len(numbers), Now: now,
	})
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		out[int64(r.Number)] = r
	}
	return out, nil
}

// issueBinding is the §5 gate of the cost-per-issue design, and the only
// thing standing between this endpoint and a confidently wrong answer.
//
// A spend row names an issue NUMBER and no repository -- `owner/name` appears
// nowhere on the spend side, because the hub was never told which repository a
// cwd is. So a number can be bound to this repo's backlog only while the hub
// holds exactly one repository and it is this one. Every repository starts its
// issues at #1, so the day a second shipper enrolls, `#104` means two different
// pieces of work and nothing on the row can separate them.
//
// It refuses rather than hedging, with the same 409 /v1/repo/issues?stale=1
// gives for a missing scale, and for the same reason: a reader cannot tell a
// blended cost-per-issue from a measured one. The discomfort is the point --
// it is the pressure that gets the repository declared at the source.
func (s *Server) issueBinding(repo string) error {
	repos, err := s.Store.Repos()
	if err != nil {
		return err
	}
	if len(repos) == 1 && repos[0].Repo == repo {
		return nil
	}
	return &issueBindingError{msg: issueBindingRefusal(repo, repos)}
}

// issueBindingError is the §5 refusal, typed so a caller can tell it from a
// storage failure: one is answerable by declaring the repository at the
// source, the other is a bug.
type issueBindingError struct{ msg string }

func (e *issueBindingError) Error() string { return e.msg }

// issueBindingRefusal says which of the two ways the binding failed, because
// they need different fixes: a hub holding several repos needs the repository
// declared on the spend side, while a hub holding none (or another one) needs a
// shipper pointed at this repository.
func issueBindingRefusal(repo string, repos []store.Repo) string {
	held := make([]string, 0, len(repos))
	for _, r := range repos {
		held = append(held, r.Repo)
	}
	switch {
	case len(repos) == 0:
		return "no repository progress has been shipped: " +
			"spend rows carry an issue number and no repository, so there is nothing to bind " + repo + " to"
	case len(repos) == 1:
		return "the hub holds progress for " + held[0] + ", not " + repo +
			": spend rows carry an issue number and no repository, so the numbers cannot be bound to " + repo
	default:
		return fmt.Sprintf(
			"the hub holds %d repositories (%s) and spend rows carry an issue number without one: "+
				"cost per issue cannot be bound to %s until the repository is declared on the spend side",
			len(repos), strings.Join(held, ", "), repo)
	}
}

// attachIssueCost fills in each backlog row's lifetime spend.
//
// This is what puts the money beside a STALLED issue -- the question is "what
// has this one already burned", which is a lifetime figure and has nothing to
// do with whatever window the page is showing.
//
// Rows whose issue never appeared on a branch come back with a zero SpendTotal
// and zero events, and SourceCost.Events is what makes that legible: a cost of
// 0 with events > 0 is free or unpriced work, a cost of 0 with no events is an
// absence.
func (s *Server) attachIssueCost(rows []store.RepoIssueRow) ([]IssueWithCost, error) {
	numbers := make([]int64, 0, len(rows))
	for _, r := range rows {
		numbers = append(numbers, int64(r.Number))
	}
	spend, err := s.Store.IssueLifetimeSpend(store.AllAccounts, numbers)
	if err != nil {
		return nil, err
	}
	out := make([]IssueWithCost, 0, len(rows))
	for _, r := range rows {
		out = append(out, IssueWithCost{RepoIssueRow: r, Lifetime: spend[int64(r.Number)]})
	}
	return out, nil
}

// IssueWithCost is a backlog row with the money it has burned beside it.
//
// The embedding is what keeps this from becoming a second shape: every field
// /v1/repo/issues already serves stays exactly where it was, and `lifetime` is
// the only addition. Two renderers over the same rows, never two copies.
type IssueWithCost struct {
	store.RepoIssueRow
	Lifetime store.SpendTotal `json:"lifetime"`
}
