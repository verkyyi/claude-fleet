// internal/store/repo.go
package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// Repo returns a repository the hub holds progress for.
type Repo struct {
	Repo string `json:"repo"`
	// Open is the open-issue count from the per-issue rows, which are bounded:
	// it is what the hub can still see, not an all-time figure.
	Open       int       `json:"open"`
	Issues     int       `json:"issues"`
	Days       int       `json:"days"`
	FirstDay   string    `json:"first_day,omitempty"`
	LastDay    string    `json:"last_day,omitempty"`
	ObservedAt time.Time `json:"observed_at"`
}

// RepoIssueRow is one issue as stored, plus the derivations a reader needs and
// cannot compute without the repo's own distribution.
type RepoIssueRow struct {
	model.RepoIssue
	Repo string `json:"repo"`
	// AgeSeconds is time open: to now while open, to closed_at once closed.
	// Derived on read rather than stored, because for an open issue it changes
	// every second and a stored copy would be wrong by the time it is read.
	AgeSeconds float64 `json:"age_seconds"`
	// ObservedAt is when a shipper last saw this row.
	ObservedAt time.Time `json:"observed_at"`
}

// RepoScale is a repository's own close-time distribution — the only scale an
// age means anything against.
//
// Every field is a pointer for the same reason: absent is not zero. A hub that
// substituted a default here would print a confident "stale" badge computed
// from a number nobody measured.
type RepoScale struct {
	Day          string   `json:"day"`
	P50Seconds   *float64 `json:"p50_seconds,omitempty"`
	P90Seconds   *float64 `json:"p90_seconds,omitempty"`
	P95Seconds   *float64 `json:"p95_seconds,omitempty"`
	ClosedSample *int     `json:"closed_sample,omitempty"`
}

// RepoIssueFilter scopes a backlog query. The zero value is invalid: Repo is
// required, because a stalled list blended across repositories would be scaled
// by one repo's percentiles and read as if it applied to all of them.
type RepoIssueFilter struct {
	Repo  string
	State string // "" = both
	// MinAgeSeconds keeps only issues at least this old. The caller passes the
	// repo's own p95, never a constant.
	MinAgeSeconds float64
	// ShippedOnly keeps only issues whose work already landed.
	ShippedOnly bool
	Limit       int
	// Now is the clock age is measured against. Tests set it; callers pass
	// time.Now().
	Now time.Time
}

// UpsertRepoSnapshot stores one shipper observation and reports what it wrote.
//
// Everything here is an upsert keyed by (repo, number) or (repo, day), so a
// replayed snapshot is a no-op rather than a double count — which is what lets
// a shipper page a large backlog across several POSTs with one ObservedAt, and
// lets a flaky network retry without corrupting a single figure.
func (s *Store) UpsertRepoSnapshot(snap model.RepoSnapshot) (issues, days int, err error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback()

	observed := fmtTime(snap.ObservedAt)

	if len(snap.Issues) > 0 {
		// An older observation must never overwrite a newer one: snapshots can
		// arrive out of order after a shipper retries, and a stale row would
		// silently reopen a closed issue. The WHERE on the DO UPDATE is what
		// makes late arrivals harmless instead of destructive.
		stmt, err := tx.Prepare(`
			INSERT INTO repo_issues
			  (repo, number, title, state, created_at, updated_at, closed_at,
			   labels_json, comments, url, shipped_at, shipped_ref, observed_at)
			VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
			ON CONFLICT(repo, number) DO UPDATE SET
			  title = excluded.title, state = excluded.state,
			  created_at = excluded.created_at, updated_at = excluded.updated_at,
			  closed_at = excluded.closed_at, labels_json = excluded.labels_json,
			  comments = excluded.comments, url = excluded.url,
			  shipped_at = excluded.shipped_at, shipped_ref = excluded.shipped_ref,
			  observed_at = excluded.observed_at
			WHERE excluded.observed_at >= repo_issues.observed_at`)
		if err != nil {
			return 0, 0, fmt.Errorf("prepare repo issue: %w", err)
		}
		defer stmt.Close()
		for _, i := range snap.Issues {
			labels, _ := json.Marshal(nonNilLabels(i.Labels))
			if _, err := stmt.Exec(snap.Repo, i.Number, i.Title, i.State,
				fmtTime(i.CreatedAt), fmtTimePtr(i.UpdatedAt), fmtTimePtr(i.ClosedAt),
				string(labels), i.Comments, i.URL,
				fmtTimePtr(i.ShippedAt), i.ShippedRef, observed); err != nil {
				return 0, 0, fmt.Errorf("upsert repo issue %s#%d: %w", snap.Repo, i.Number, err)
			}
			issues++
		}
	}

	for _, d := range snap.Days {
		if _, err := tx.Exec(`
			INSERT INTO repo_days
			  (repo, day, opened, closed, open_at_end, merged_prs,
			   close_p50_seconds, close_p90_seconds, close_p95_seconds,
			   closed_sample, observed_at)
			VALUES (?,?,?,?,?,?,?,?,?,?,?)
			ON CONFLICT(repo, day) DO UPDATE SET
			  opened = excluded.opened, closed = excluded.closed,
			  open_at_end = excluded.open_at_end, merged_prs = excluded.merged_prs,
			  close_p50_seconds = excluded.close_p50_seconds,
			  close_p90_seconds = excluded.close_p90_seconds,
			  close_p95_seconds = excluded.close_p95_seconds,
			  closed_sample = excluded.closed_sample,
			  observed_at = excluded.observed_at
			WHERE excluded.observed_at >= repo_days.observed_at`,
			snap.Repo, d.Day, d.Opened, d.Closed, d.OpenAtEnd, nullInt(d.MergedPRs),
			nullFloat(d.CloseP50Seconds), nullFloat(d.CloseP90Seconds),
			nullFloat(d.CloseP95Seconds), nullInt(d.ClosedSample), observed); err != nil {
			return 0, 0, fmt.Errorf("upsert repo day %s/%s: %w", snap.Repo, d.Day, err)
		}
		days++
	}

	if err := tx.Commit(); err != nil {
		return 0, 0, fmt.Errorf("commit: %w", err)
	}
	return issues, days, nil
}

// Repos lists every repository the hub holds progress for, most recently
// observed first.
func (s *Store) Repos() ([]Repo, error) {
	// Each count comes from its own grouped subquery. Joining the two tables
	// directly would multiply issue rows by day rows, and a repo present in
	// only one of them would vanish entirely — which is the normal state of a
	// shipper that sends day rows but no per-issue detail.
	rows, err := s.read.Query(`
		SELECT r.repo,
		       COALESCE(i.open, 0), COALESCE(i.total, 0),
		       COALESCE(d.days, 0), COALESCE(d.first_day, ''), COALESCE(d.last_day, ''),
		       r.observed_at
		FROM (
		  SELECT repo, MAX(observed_at) AS observed_at FROM (
		    SELECT repo, observed_at FROM repo_issues
		    UNION ALL
		    SELECT repo, observed_at FROM repo_days
		  ) GROUP BY repo
		) AS r
		LEFT JOIN (
		  SELECT repo, SUM(state = 'open') AS open, COUNT(*) AS total
		  FROM repo_issues GROUP BY repo
		) AS i ON i.repo = r.repo
		LEFT JOIN (
		  SELECT repo, COUNT(*) AS days, MIN(day) AS first_day, MAX(day) AS last_day
		  FROM repo_days GROUP BY repo
		) AS d ON d.repo = r.repo
		ORDER BY r.observed_at DESC, r.repo`)
	if err != nil {
		return nil, fmt.Errorf("repos: %w", err)
	}
	defer rows.Close()
	var out []Repo
	for rows.Next() {
		var r Repo
		var at string
		if err := rows.Scan(&r.Repo, &r.Open, &r.Issues, &r.Days, &r.FirstDay, &r.LastDay, &at); err != nil {
			return nil, err
		}
		r.ObservedAt, _ = time.Parse(rfc, at)
		out = append(out, r)
	}
	return out, rows.Err()
}

// RepoDays returns the flow rows for [start, end) by UTC day.
func (s *Store) RepoDays(repo string, start, end time.Time) ([]model.RepoDay, error) {
	if err := model.ValidRepoName(repo); err != nil {
		return nil, err
	}
	rows, err := s.read.Query(`
		SELECT day, opened, closed, open_at_end, merged_prs,
		       close_p50_seconds, close_p90_seconds, close_p95_seconds, closed_sample
		FROM repo_days
		WHERE repo = ? AND day >= ? AND day < ?
		ORDER BY day`,
		repo, start.UTC().Format(model.RepoDayLayout), end.UTC().Format(model.RepoDayLayout))
	if err != nil {
		return nil, fmt.Errorf("repo days: %w", err)
	}
	defer rows.Close()
	var out []model.RepoDay
	for rows.Next() {
		var d model.RepoDay
		var merged, sample sql.NullInt64
		var p50, p90, p95 sql.NullFloat64
		if err := rows.Scan(&d.Day, &d.Opened, &d.Closed, &d.OpenAtEnd, &merged,
			&p50, &p90, &p95, &sample); err != nil {
			return nil, err
		}
		d.MergedPRs = intPtr(merged)
		d.ClosedSample = intPtr(sample)
		d.CloseP50Seconds = floatPtr(p50)
		d.CloseP90Seconds = floatPtr(p90)
		d.CloseP95Seconds = floatPtr(p95)
		out = append(out, d)
	}
	return out, rows.Err()
}

// RepoCloseScale returns the most recent day row that actually carries
// percentiles, or nil when no shipper has ever computed them.
//
// Nil is a real answer and callers must render it as "unknown scale". The
// alternative — falling back to a constant — is the failure this whole feature
// exists to avoid: in a repo whose median issue closes in three hours, a
// thirty-day staleness threshold is not conservative, it is meaningless.
func (s *Store) RepoCloseScale(repo string) (*RepoScale, error) {
	if err := model.ValidRepoName(repo); err != nil {
		return nil, err
	}
	var sc RepoScale
	var p50, p90, p95 sql.NullFloat64
	var sample sql.NullInt64
	err := s.read.QueryRow(`
		SELECT day, close_p50_seconds, close_p90_seconds, close_p95_seconds, closed_sample
		FROM repo_days
		WHERE repo = ? AND (close_p50_seconds IS NOT NULL
		                    OR close_p90_seconds IS NOT NULL
		                    OR close_p95_seconds IS NOT NULL)
		ORDER BY day DESC LIMIT 1`, repo).
		Scan(&sc.Day, &p50, &p90, &p95, &sample)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("repo close scale: %w", err)
	}
	sc.P50Seconds, sc.P90Seconds, sc.P95Seconds = floatPtr(p50), floatPtr(p90), floatPtr(p95)
	sc.ClosedSample = intPtr(sample)
	return &sc, nil
}

// RepoIssues returns the per-issue rows matching f, oldest first.
//
// Oldest first is not a default, it is the point: this list exists to surface
// what has been open longest, and a reader who takes only the head of it must
// get the worst offenders rather than an arbitrary page.
func (s *Store) RepoIssues(f RepoIssueFilter) ([]RepoIssueRow, error) {
	if err := model.ValidRepoName(f.Repo); err != nil {
		return nil, err
	}
	if f.State != "" && f.State != model.RepoStateOpen && f.State != model.RepoStateClosed {
		return nil, fmt.Errorf("unknown issue state %q", f.State)
	}
	now := f.Now
	if now.IsZero() {
		now = time.Now()
	}

	q := `SELECT repo, number, title, state, created_at, updated_at, closed_at,
	             labels_json, comments, url, shipped_at, shipped_ref, observed_at
	      FROM repo_issues WHERE repo = ?`
	args := []any{f.Repo}
	if f.State != "" {
		q += ` AND state = ?`
		args = append(args, f.State)
	}
	if f.ShippedOnly {
		q += ` AND shipped_at IS NOT NULL`
	}
	if f.MinAgeSeconds > 0 {
		// Age is measured to closed_at once closed and to now while open, so
		// the cutoff has to be expressed against each row's own end. Doing it
		// in SQL keeps the LIMIT meaningful — filtering after the fact would
		// return a page of rows and then empty most of it.
		q += ` AND (julianday(COALESCE(closed_at, ?)) - julianday(created_at)) * 86400.0 >= ?`
		args = append(args, fmtTime(now), f.MinAgeSeconds)
	}
	q += ` ORDER BY created_at ASC, number ASC`
	if f.Limit > 0 {
		q += ` LIMIT ?`
		args = append(args, f.Limit)
	}

	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("repo issues: %w", err)
	}
	defer rows.Close()
	var out []RepoIssueRow
	for rows.Next() {
		var r RepoIssueRow
		var created, observed, labels string
		var updated, closed, shipped sql.NullString
		if err := rows.Scan(&r.Repo, &r.Number, &r.Title, &r.State, &created, &updated,
			&closed, &labels, &r.Comments, &r.URL, &shipped, &r.ShippedRef, &observed); err != nil {
			return nil, err
		}
		r.CreatedAt, _ = time.Parse(rfc, created)
		r.UpdatedAt = parseNullTime(updated)
		r.ClosedAt = parseNullTime(closed)
		r.ShippedAt = parseNullTime(shipped)
		r.ObservedAt, _ = time.Parse(rfc, observed)
		_ = json.Unmarshal([]byte(labels), &r.Labels)
		end := now
		if r.ClosedAt != nil {
			end = *r.ClosedAt
		}
		r.AgeSeconds = end.Sub(r.CreatedAt).Seconds()
		out = append(out, r)
	}
	return out, rows.Err()
}

// PruneRepoIssues bounds the per-issue table. Day rows are never touched.
//
// Two rules, both keyed off olderThan:
//
//   - a CLOSED issue whose closing is older than the window is deleted. Its
//     contribution already lives in repo_days, which is kept forever, so what
//     is lost is per-issue detail and never a count.
//   - an OPEN issue nobody has seen since the window is deleted too. It was
//     deleted, transferred or made private upstream; keeping it would leave a
//     permanent phantom at the top of the stalled list, which is the one place
//     a wrong row does the most damage.
//
// This is what keeps "one binary and one SQLite file" true as a repo's history
// grows without bound. Reporting must not turn storage into an operational
// problem for what was previously just a token ledger.
func (s *Store) PruneRepoIssues(olderThan time.Time) (int64, error) {
	cut := fmtTime(olderThan)
	res, err := s.write.Exec(`
		DELETE FROM repo_issues
		WHERE (state = 'closed' AND closed_at IS NOT NULL AND closed_at < ?)
		   OR (state = 'open' AND observed_at < ?)`, cut, cut)
	if err != nil {
		return 0, fmt.Errorf("prune repo issues: %w", err)
	}
	n, _ := res.RowsAffected()
	return n, nil
}

// nonNilLabels keeps an absent label list marshalling as [] rather than null,
// so every stored row has the same shape and readers never branch on it.
//
// Sorting a copy — not the caller's slice — makes the stored JSON identical
// for identical labels however GitHub happened to order them, so re-shipping
// an unchanged issue really is a no-op rather than a byte-level rewrite.
func nonNilLabels(l []string) []string {
	out := make([]string, len(l))
	copy(out, l)
	sort.Strings(out)
	return out
}

func nullInt(v *int) any {
	if v == nil {
		return nil
	}
	return *v
}

func nullFloat(v *float64) any {
	if v == nil {
		return nil
	}
	return *v
}

func intPtr(n sql.NullInt64) *int {
	if !n.Valid {
		return nil
	}
	v := int(n.Int64)
	return &v
}

func floatPtr(f sql.NullFloat64) *float64 {
	if !f.Valid {
		return nil
	}
	return &f.Float64
}
