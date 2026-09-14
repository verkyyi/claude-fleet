package model

import (
	"fmt"
	"strings"
	"time"
)

// Repo progress: what the tokens BOUGHT, carried under the same key as what
// they cost.
//
// The rest of this package describes spend — how much a subscription used,
// on which machine, in which session. None of it can answer "this week's
// tokens, what actually landed?", because the other half of that question is
// repo history and it lives in GitHub. The issue number is the axis that joins
// them: a fleet-style orchestrator binds a session to an issue, a commit
// convention binds a commit to an issue, and the hub already keys spend by
// session. Storing repo facts under that key — rather than in a second
// dashboard beside it — is the whole point.
//
// The COLLECTOR is deliberately not in this repo. Which repositories, which
// credentials, how often and behind which firewall is a per-team concern, and
// binding hub releases to collection logic would make both worse. The hub is a
// sink: a shipper POSTs snapshots, the way endpoint agents already do.

// RepoSnapshot is one shipper's observation of a repository at a point in time.
//
// It is a SNAPSHOT, not a stream: GitHub's API exposes each issue's current
// state and nothing else, so a shipper can only ever say "here is how it looks
// now". That is exactly why the day rows below matter — they are the only
// record of how the backlog looked last Tuesday, a question GitHub itself
// cannot answer retroactively.
//
// Both lists are optional and may arrive in separate POSTs: a shipper that
// pages a large backlog sends several snapshots with the same ObservedAt, and
// each one upserts. Nothing here is additive, so a replayed snapshot is a
// no-op rather than a double count.
type RepoSnapshot struct {
	// Repo is "owner/name", the same spelling GitHub uses. It is the tenant
	// key for every row below.
	Repo string `json:"repo"`

	// ObservedAt is when the shipper read GitHub, not when the hub received
	// it. A snapshot that arrives late is still a fact about the moment it
	// was taken.
	ObservedAt time.Time `json:"observed_at"`

	Issues []RepoIssue `json:"issues,omitempty"`
	Days   []RepoDay   `json:"days,omitempty"`
}

// RepoIssue is one issue as the shipper last saw it.
//
// These rows are BOUNDED on purpose (see store.PruneRepoIssues): open issues
// stay, closed ones age out once the day rows have absorbed them. The hub is
// one Go binary and one SQLite file on a single replica, and a reporting
// feature must not turn storage into an operational problem for what was
// previously just a token ledger.
type RepoIssue struct {
	Number    int        `json:"number"`
	Title     string     `json:"title,omitempty"`
	State     string     `json:"state"` // RepoStateOpen | RepoStateClosed
	CreatedAt time.Time  `json:"created_at"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
	ClosedAt  *time.Time `json:"closed_at,omitempty"`
	Labels    []string   `json:"labels,omitempty"`
	Comments  int        `json:"comments,omitempty"`
	URL       string     `json:"url,omitempty"`

	// ShippedAt and ShippedRef record that the work already landed while the
	// issue is still open — a merged commit whose subject references this
	// number, say. It is the difference between a stalled list and an
	// actionable one: "open, older than p95, and already shipped in <ref>"
	// is a close, not an investigation.
	//
	// Nil means nobody looked, NOT that nothing shipped. A shipper that does
	// no commit cross-referencing simply omits it.
	ShippedAt  *time.Time `json:"shipped_at,omitempty"`
	ShippedRef string     `json:"shipped_ref,omitempty"`
}

// RepoDay is one UTC day of repository flow, pre-aggregated by the shipper.
//
// The shipper computes these because it is the only party that holds the full
// history; the hub keeps them forever because they are small — one row per
// repo per day — and because they are what survives when the per-issue rows
// are compacted away.
type RepoDay struct {
	Day       string `json:"day"` // YYYY-MM-DD, UTC
	Opened    int    `json:"opened"`
	Closed    int    `json:"closed"`
	OpenAtEnd int    `json:"open_at_end"`

	// MergedPRs is nil when the shipper does not track pull requests. Zero is
	// a claim that none merged; nil is an admission that nobody counted.
	MergedPRs *int `json:"merged_prs,omitempty"`

	// Close-time percentiles of the issues closed up to this day, in seconds.
	//
	// These are the scale EVERY age judgement is made against, and they are
	// stored rather than hardcoded for one reason: in a repo whose median
	// issue closes in three hours, "stale after 30 days" carries no
	// information. Measured on one real repo — 2,688 issues in 82 days —
	// median 0.13d, p90 4.6d, p95 10.9d. A constant that fits that repo fits
	// no other.
	//
	// nil means the shipper did not compute them. Surfaces must then say the
	// scale is unknown rather than substitute one; a fabricated threshold is
	// worse than an absent one because it still looks authoritative.
	CloseP50Seconds *float64 `json:"close_p50_seconds,omitempty"`
	CloseP90Seconds *float64 `json:"close_p90_seconds,omitempty"`
	CloseP95Seconds *float64 `json:"close_p95_seconds,omitempty"`

	// ClosedSample is how many closed issues the percentiles were computed
	// over, so a reader can tell a distribution from an anecdote.
	ClosedSample *int `json:"closed_sample,omitempty"`
}

// Issue states. GitHub has exactly two and the hub stores what it is told, so
// this is a closed set rather than free text — a third spelling would split
// every open-count in half without any surface reporting a problem.
const (
	RepoStateOpen   = "open"
	RepoStateClosed = "closed"
)

// RepoDayLayout is the day key format: UTC calendar days, sortable as strings.
const RepoDayLayout = "2006-01-02"

// Validate rejects a snapshot the hub cannot store honestly.
//
// It is strict on purpose. Every field here comes from outside the binary, and
// a repo name or day key that is merely *odd* becomes a second tenant or a
// second day that nothing ever reconciles — a silent split, not an error.
func (s RepoSnapshot) Validate(now time.Time) error {
	if err := ValidRepoName(s.Repo); err != nil {
		return err
	}
	if s.ObservedAt.IsZero() {
		return fmt.Errorf("repo %s: observed_at is required", s.Repo)
	}
	// Same tolerance the collector observations use: a little clock skew is
	// ordinary, a snapshot from next week is a broken shipper.
	if s.ObservedAt.After(now.Add(5 * time.Minute)) {
		return fmt.Errorf("repo %s: observed_at %s is in the future", s.Repo, s.ObservedAt.Format(time.RFC3339))
	}
	if len(s.Issues) == 0 && len(s.Days) == 0 {
		return fmt.Errorf("repo %s: snapshot carries neither issues nor days", s.Repo)
	}
	for _, i := range s.Issues {
		if err := i.validate(s.Repo); err != nil {
			return err
		}
	}
	for _, d := range s.Days {
		if err := d.validate(s.Repo); err != nil {
			return err
		}
	}
	return nil
}

func (i RepoIssue) validate(repo string) error {
	if i.Number <= 0 {
		return fmt.Errorf("repo %s: issue number must be positive, got %d", repo, i.Number)
	}
	if i.State != RepoStateOpen && i.State != RepoStateClosed {
		return fmt.Errorf("repo %s issue %d: state must be %q or %q, got %q",
			repo, i.Number, RepoStateOpen, RepoStateClosed, i.State)
	}
	if i.CreatedAt.IsZero() {
		return fmt.Errorf("repo %s issue %d: created_at is required", repo, i.Number)
	}
	// A closed issue with no closing time cannot enter the close-time
	// distribution, and an open issue with one is a contradiction. Both would
	// otherwise be stored and quietly skew every percentile derived from them.
	if i.State == RepoStateClosed && i.ClosedAt == nil {
		return fmt.Errorf("repo %s issue %d: closed issues need closed_at", repo, i.Number)
	}
	if i.State == RepoStateOpen && i.ClosedAt != nil {
		return fmt.Errorf("repo %s issue %d: open issue carries closed_at", repo, i.Number)
	}
	if i.ClosedAt != nil && i.ClosedAt.Before(i.CreatedAt) {
		return fmt.Errorf("repo %s issue %d: closed_at precedes created_at", repo, i.Number)
	}
	return nil
}

func (d RepoDay) validate(repo string) error {
	if _, err := time.Parse(RepoDayLayout, d.Day); err != nil {
		return fmt.Errorf("repo %s: day %q is not %s", repo, d.Day, RepoDayLayout)
	}
	if d.Opened < 0 || d.Closed < 0 || d.OpenAtEnd < 0 {
		return fmt.Errorf("repo %s day %s: counts cannot be negative", repo, d.Day)
	}
	for name, v := range map[string]*float64{
		"close_p50_seconds": d.CloseP50Seconds,
		"close_p90_seconds": d.CloseP90Seconds,
		"close_p95_seconds": d.CloseP95Seconds,
	} {
		if v != nil && *v < 0 {
			return fmt.Errorf("repo %s day %s: %s cannot be negative", repo, d.Day, name)
		}
	}
	return nil
}

// ValidRepoName accepts the "owner/name" spelling GitHub uses and nothing else.
//
// The repo string is a primary-key component, so "Owner/Name", "owner/name/"
// and "https://github.com/owner/name" must not be allowed to become three
// separate repositories that never reconcile. Rejecting is the only honest
// option: silently normalising would make a shipper's typo invisible, and the
// hub cannot know which spelling was intended.
func ValidRepoName(repo string) error {
	if repo == "" {
		return fmt.Errorf("repo is required")
	}
	owner, name, ok := strings.Cut(repo, "/")
	if !ok || owner == "" || name == "" || strings.Contains(name, "/") {
		return fmt.Errorf("repo %q is not owner/name", repo)
	}
	if strings.TrimSpace(repo) != repo {
		return fmt.Errorf("repo %q has surrounding whitespace", repo)
	}
	return nil
}
