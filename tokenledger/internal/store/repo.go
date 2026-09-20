// internal/store/repo.go
package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
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
	// Numbers keeps only these issue numbers. Empty means no constraint.
	//
	// It exists for the join back from the spend side, where the issue axis
	// hands over a set of numbers read off branch names and needs the rows
	// that go with them. A number with no row here is not an error: per-issue
	// rows are bounded by retention, so spend can outlive the issue it names,
	// and the caller has to be able to say so rather than drop the money.
	Numbers []int64
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

// RepoWritten counts what one snapshot wrote, per kind of row.
//
// A struct rather than a list of return values because the kinds are not
// fixed: this started as issues and days, and the manual-step rows arrived
// later. Each new kind would otherwise rewrite every call site, which is how
// "one more count" turns into a reason not to add one.
type RepoWritten struct {
	Issues     int `json:"issues"`
	Days       int `json:"days"`
	HumanSteps int `json:"human_steps"`
	HumanDays  int `json:"human_days"`
}

// UpsertRepoSnapshot stores one shipper observation and reports what it wrote.
//
// Everything here is an upsert keyed by (repo, number), (repo, day) or
// (repo, fragment, ord), so a replayed snapshot is a no-op rather than a
// double count — which is what lets a shipper page a large backlog across
// several POSTs with one ObservedAt, and lets a flaky network retry without
// corrupting a single figure.
func (s *Store) UpsertRepoSnapshot(snap model.RepoSnapshot) (w RepoWritten, err error) {
	tx, err := s.write.Begin()
	if err != nil {
		return w, fmt.Errorf("begin: %w", err)
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
			return w, fmt.Errorf("prepare repo issue: %w", err)
		}
		defer stmt.Close()
		for _, i := range snap.Issues {
			labels, _ := json.Marshal(nonNilLabels(i.Labels))
			if _, err := stmt.Exec(snap.Repo, i.Number, i.Title, i.State,
				fmtTime(i.CreatedAt), fmtTimePtr(i.UpdatedAt), fmtTimePtr(i.ClosedAt),
				string(labels), i.Comments, i.URL,
				fmtTimePtr(i.ShippedAt), i.ShippedRef, observed); err != nil {
				return w, fmt.Errorf("upsert repo issue %s#%d: %w", snap.Repo, i.Number, err)
			}
			w.Issues++
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
			return w, fmt.Errorf("upsert repo day %s/%s: %w", snap.Repo, d.Day, err)
		}
		w.Days++
	}

	// Manual steps. Same late-arrival guard as the rows above, and the same
	// reason: a shipper retry that lands out of order must not resurrect a
	// step somebody has since ticked off.
	for _, h := range snap.HumanSteps {
		if _, err := tx.Exec(`
			INSERT INTO repo_human_steps
			  (repo, fragment, ord, owner, owner_kind, owner_id, title, how, pass, exit,
			   fragment_title, fragment_url, fragment_at, todo_at, done, done_at, done_by, observed_at)
			VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
			ON CONFLICT(repo, fragment, ord) DO UPDATE SET
			  owner = excluded.owner, owner_kind = excluded.owner_kind,
			  owner_id = excluded.owner_id, title = excluded.title,
			  how = excluded.how, pass = excluded.pass, exit = excluded.exit,
			  fragment_title = excluded.fragment_title, fragment_url = excluded.fragment_url,
			  fragment_at = excluded.fragment_at, todo_at = excluded.todo_at,
			  done = excluded.done, done_at = excluded.done_at, done_by = excluded.done_by,
			  observed_at = excluded.observed_at
			WHERE excluded.observed_at >= repo_human_steps.observed_at`,
			snap.Repo, h.Fragment, h.Ord, h.Owner, h.OwnerKind, nullStr(h.OwnerID),
			h.Title, nullStr(h.How), nullStr(h.Pass), nullStr(h.Exit),
			h.FragmentTitle, h.FragmentURL, fmtTime(h.FragmentAt),
			fmtTimePtr(h.TodoAt), h.Done, fmtTimePtr(h.DoneAt), h.DoneBy, observed); err != nil {
			return w, fmt.Errorf("upsert human step %s#%d.%d: %w", snap.Repo, h.Fragment, h.Ord, err)
		}
		w.HumanSteps++
	}

	for _, d := range snap.HumanDays {
		if _, err := tx.Exec(`
			INSERT INTO repo_human_days
			  (repo, day, fragments, with_human, steps, steps_done, observed_at)
			VALUES (?,?,?,?,?,?,?)
			ON CONFLICT(repo, day) DO UPDATE SET
			  fragments = excluded.fragments, with_human = excluded.with_human,
			  steps = excluded.steps, steps_done = excluded.steps_done,
			  observed_at = excluded.observed_at
			WHERE excluded.observed_at >= repo_human_days.observed_at`,
			snap.Repo, d.Day, d.Fragments, d.WithHuman, d.Steps, d.StepsDone, observed); err != nil {
			return w, fmt.Errorf("upsert human day %s/%s: %w", snap.Repo, d.Day, err)
		}
		w.HumanDays++
	}

	// One row per repo, same late-arrival rule as everything above: a snapshot
	// that took the scenic route must never overwrite a fresher reading with
	// an older one. Here that matters more than elsewhere -- these figures are
	// the only thing on the page that says whether the verification behind
	// every OTHER figure still works, so a silent rewind would restore
	// confidence nobody measured.
	if h := snap.VerifyHealth; h != nil {
		readings, err := json.Marshal(h.Readings)
		if err != nil {
			return w, fmt.Errorf("encode verify_health for %s: %w", snap.Repo, err)
		}
		if _, err := tx.Exec(`
			INSERT INTO repo_health (repo, observed_at, source, stale_after_seconds, readings_json)
			VALUES (?,?,?,?,?)
			ON CONFLICT(repo) DO UPDATE SET
			  observed_at = excluded.observed_at, source = excluded.source,
			  stale_after_seconds = excluded.stale_after_seconds,
			  readings_json = excluded.readings_json
			WHERE excluded.observed_at >= repo_health.observed_at`,
			snap.Repo, observed, h.Source, nullFloat(h.StaleAfterSeconds), string(readings)); err != nil {
			return w, fmt.Errorf("upsert repo health %s: %w", snap.Repo, err)
		}
	}

	if err := tx.Commit(); err != nil {
		return w, fmt.Errorf("commit: %w", err)
	}
	return w, nil
}

// RepoHealthRow is repo_health as it is read back, with the observation time
// the page needs to say how old these figures are.
type RepoHealthRow struct {
	Repo              string              `json:"repo"`
	ObservedAt        time.Time           `json:"observed_at"`
	Source            string              `json:"source,omitempty"`
	StaleAfterSeconds *float64            `json:"stale_after_seconds,omitempty"`
	Readings          []model.RepoReading `json:"readings"`
}

// RepoHealth returns the stored verification readings, or nil when no shipper
// has ever sent any.
//
// Nil means NOBODY MEASURED, and every caller has to render it that way. The
// tempting alternative -- an empty card, or no card at all -- reads as "there
// is nothing wrong", which is the one conclusion absent data cannot support.
func (s *Store) RepoHealth(repo string) (*RepoHealthRow, error) {
	if err := model.ValidRepoName(repo); err != nil {
		return nil, err
	}
	row := RepoHealthRow{Repo: repo}
	var at, readings string
	var stale sql.NullFloat64
	err := s.read.QueryRow(`
		SELECT observed_at, source, stale_after_seconds, readings_json
		FROM repo_health WHERE repo = ?`, repo).
		Scan(&at, &row.Source, &stale, &readings)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("repo health: %w", err)
	}
	row.ObservedAt, _ = time.Parse(rfc, at)
	row.StaleAfterSeconds = floatPtr(stale)
	// A row that will not decode is a bug in whatever wrote it, and reporting
	// it is the point: swallowing the error would hand the page an empty
	// reading list, which renders as the healthy-looking "no readings" state.
	if err := json.Unmarshal([]byte(readings), &row.Readings); err != nil {
		return nil, fmt.Errorf("repo health %s: stored readings will not decode: %w", repo, err)
	}
	return &row, nil
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
		    UNION ALL
		    SELECT repo, observed_at FROM repo_health
		    UNION ALL
		    -- The manual-step rows count too. They come from a DIFFERENT
		    -- shipper (the one that can parse release fragments, which needs
		    -- the repo checked out), so a hub can legitimately hold nothing
		    -- but these — and leaving them out made that hub answer "no
		    -- repositories" while holding a full list of what it owes.
		    SELECT repo, observed_at FROM repo_human_steps
		    UNION ALL
		    SELECT repo, observed_at FROM repo_human_days
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
	if len(f.Numbers) > 0 {
		q += ` AND number IN (` + strings.TrimSuffix(strings.Repeat("?,", len(f.Numbers)), ",") + `)`
		for _, n := range f.Numbers {
			args = append(args, n)
		}
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

// RepoHumanStepRow is one manual step as stored, plus the age a reader needs.
type RepoHumanStepRow struct {
	model.RepoHumanStep
	Repo string `json:"repo"`
	// WaitingSeconds is how long this step has been waiting on somebody: from
	// when they were told (todo_at) if they were, otherwise from when the
	// fragment was written. Derived on read, never stored — a stored age is
	// wrong by the time anyone looks at it.
	//
	// For a step that is done it measures what the wait WAS, which is what
	// makes "it took eleven days" answerable at all.
	WaitingSeconds float64 `json:"waiting_seconds"`
	// ToldSeconds is how long the step sat before anybody was told, or nil if
	// nobody has been. It is the half of the delay this hub's own side of the
	// system is responsible for, and it is invisible in the total.
	ToldSeconds *float64  `json:"told_seconds,omitempty"`
	ObservedAt  time.Time `json:"observed_at"`
}

// RepoHumanFilter scopes a manual-step query. Repo is required, for the same
// reason it is on the backlog: two repositories' release processes blended
// into one list read as one process that neither team runs.
type RepoHumanFilter struct {
	Repo string
	// OpenOnly keeps only steps nobody has finished.
	OpenOnly bool
	Limit    int
	// Now is the clock the wait is measured against. Tests set it.
	Now time.Time
}

// RepoHumanSteps returns manual steps, longest wait first.
//
// The ordering is the point of the list: whatever has been waiting longest is
// what the release is actually blocked on, and it is the row a reader should
// see without scrolling. Ties break on the fragment number so the order is
// stable between reads rather than whatever SQLite last happened to do.
func (s *Store) RepoHumanSteps(f RepoHumanFilter) ([]RepoHumanStepRow, error) {
	if err := model.ValidRepoName(f.Repo); err != nil {
		return nil, err
	}
	now := f.Now
	if now.IsZero() {
		now = time.Now()
	}
	q := `SELECT repo, fragment, ord, owner, owner_kind, owner_id, title, how, pass, exit,
	             fragment_title, fragment_url, fragment_at, todo_at, done, done_at, done_by, observed_at
	      FROM repo_human_steps WHERE repo = ?`
	args := []any{f.Repo}
	if f.OpenOnly {
		// On done, never on done_at: a step struck out by hand is finished and
		// carries no time, and filtering on the timestamp would leave it at
		// the top of somebody's list forever.
		q += ` AND done = 0`
	}
	q += ` ORDER BY COALESCE(todo_at, fragment_at) ASC, fragment ASC, ord ASC`
	if f.Limit > 0 {
		q += ` LIMIT ?`
		args = append(args, f.Limit)
	}
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("repo human steps: %w", err)
	}
	defer rows.Close()
	var out []RepoHumanStepRow
	for rows.Next() {
		var r RepoHumanStepRow
		var fragmentAt, observed string
		var ownerID, how, pass, exitLine, fragTitle, fragURL, doneBy sql.NullString
		var todoAt, doneAt sql.NullString
		if err := rows.Scan(&r.Repo, &r.Fragment, &r.Ord, &r.Owner, &r.OwnerKind, &ownerID,
			&r.Title, &how, &pass, &exitLine, &fragTitle, &fragURL, &fragmentAt,
			&todoAt, &r.Done, &doneAt, &doneBy, &observed); err != nil {
			return nil, err
		}
		r.OwnerID, r.How, r.Pass, r.Exit = ownerID.String, how.String, pass.String, exitLine.String
		r.FragmentTitle, r.FragmentURL, r.DoneBy = fragTitle.String, fragURL.String, doneBy.String
		r.FragmentAt, _ = time.Parse(rfc, fragmentAt)
		r.TodoAt = parseNullTime(todoAt)
		r.DoneAt = parseNullTime(doneAt)
		r.ObservedAt, _ = time.Parse(rfc, observed)

		// Waiting starts when the person was told; before that the system,
		// not the person, is the one holding it up.
		from := r.FragmentAt
		if r.TodoAt != nil {
			from = *r.TodoAt
			told := r.TodoAt.Sub(r.FragmentAt).Seconds()
			r.ToldSeconds = &told
		}
		end := now
		if r.DoneAt != nil {
			end = *r.DoneAt
		} else if r.Done {
			// Finished, and nobody recorded when. The last time a shipper saw
			// it is the tightest bound available — an over-estimate of the
			// wait, never an under-estimate, and stated here rather than
			// dressed up as a measurement.
			end = r.ObservedAt
		}
		r.WaitingSeconds = end.Sub(from).Seconds()
		out = append(out, r)
	}
	return out, rows.Err()
}

// RepoHumanDays returns the daily manual-work rows in [start, end].
//
// Empty is a real answer: a repo whose shipper does not parse release
// fragments has no rows here, and the surface must render that as "nobody
// measured" rather than as a flat zero line — a zero ratio and an absent one
// look identical on a chart and mean opposite things.
func (s *Store) RepoHumanDays(repo string, start, end time.Time) ([]model.RepoHumanDay, error) {
	if err := model.ValidRepoName(repo); err != nil {
		return nil, err
	}
	rows, err := s.read.Query(`
		SELECT day, fragments, with_human, steps, steps_done
		FROM repo_human_days
		WHERE repo = ? AND day >= ? AND day <= ?
		ORDER BY day ASC`,
		repo, start.UTC().Format(model.RepoDayLayout), end.UTC().Format(model.RepoDayLayout))
	if err != nil {
		return nil, fmt.Errorf("repo human days: %w", err)
	}
	defer rows.Close()
	var out []model.RepoHumanDay
	for rows.Next() {
		var d model.RepoHumanDay
		if err := rows.Scan(&d.Day, &d.Fragments, &d.WithHuman, &d.Steps, &d.StepsDone); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// PruneRepoHumanSteps bounds the step table the same way PruneRepoIssues bounds
// the backlog: by LAST SIGHTING, never by done-ness.
//
// A step stops being shipped when its fragment is archived, so ageing out by
// observed_at is what clears finished release batches. Deleting on done_at
// instead would erase a step the moment somebody ticked it — losing both the
// "how long did that take" answer and, worse, any trace that it was ever
// owed. The daily rows keep the counts either way.
func (s *Store) PruneRepoHumanSteps(olderThan time.Time) (int64, error) {
	res, err := s.write.Exec(`DELETE FROM repo_human_steps WHERE observed_at < ?`, fmtTime(olderThan))
	if err != nil {
		return 0, fmt.Errorf("prune repo human steps: %w", err)
	}
	n, _ := res.RowsAffected()
	return n, nil
}

// nullStr keeps "the author did not write one" distinct from "they wrote an
// empty one" in the column, so a surface can say which.
func nullStr(v string) any {
	if v == "" {
		return nil
	}
	return v
}
