package store

import (
	"fmt"
	"strings"
	"time"
)

// FindingMute is one silenced finding: the operator saying "I know about this,
// stop ranking it at me until then".
//
// FindingID is internal/findings' stable id (see that package's identity.go).
// This table stores no finding — only the judgement about one — so a mute for
// a finding that has stopped firing simply never matches anything, and expires
// on its own.
type FindingMute struct {
	FindingID string    `json:"finding_id"`
	Kind      string    `json:"kind,omitempty"`
	Note      string    `json:"note,omitempty"`
	By        string    `json:"by,omitempty"`
	MutedAt   time.Time `json:"muted_at"`
	ExpiresAt time.Time `json:"expires_at"`
}

const (
	// DefaultMuteFor is how long a silence lasts when the caller names no
	// duration. One working day: long enough to get through the thing that
	// caused it, short enough that a forgotten mute cannot hide a condition
	// for a week.
	DefaultMuteFor = 24 * time.Hour

	// MaxMuteFor is the ceiling, and the reason there is no "forever". A mute
	// is a decision made with today's information; a month is already well
	// past the point where the operator remembers making it, and anything
	// longer is a deletion wearing a different word. A caller asking for more
	// gets this, clamped rather than refused — the intent ("a long time") is
	// clear and honouring it partially is more useful than an error.
	MaxMuteFor = 30 * 24 * time.Hour

	// maxMuteNote bounds the free-text note. It is an operator's sentence,
	// not a document, and it comes in over HTTP.
	maxMuteNote = 500
)

// MuteFinding silences one finding until `now.Add(d)`, replacing any existing
// silence for the same id — re-muting is how an operator extends one, and
// making that an upsert avoids a "already muted" error that would have exactly
// one sensible response anyway.
//
// d is clamped into (0, MaxMuteFor]: zero or negative means the caller named no
// duration and gets DefaultMuteFor, and anything past the ceiling gets the
// ceiling (see MaxMuteFor). The clamped mute is returned so the caller can tell
// the operator what they actually got rather than what they asked for.
func (s *Store) MuteFinding(m FindingMute, d time.Duration, now time.Time) (FindingMute, error) {
	m.FindingID = strings.TrimSpace(m.FindingID)
	if m.FindingID == "" {
		return FindingMute{}, fmt.Errorf("finding id is required")
	}
	if d <= 0 {
		d = DefaultMuteFor
	}
	if d > MaxMuteFor {
		d = MaxMuteFor
	}
	m.Note = truncate(strings.TrimSpace(m.Note), maxMuteNote)
	m.Kind = strings.TrimSpace(m.Kind)
	m.By = strings.TrimSpace(m.By)
	m.MutedAt = now.UTC()
	m.ExpiresAt = now.Add(d).UTC()

	if _, err := s.write.Exec(
		`INSERT INTO finding_mutes(finding_id,kind,note,muted_by,muted_at,expires_at)
		 VALUES(?,?,?,?,?,?)
		 ON CONFLICT(finding_id) DO UPDATE SET
		   kind=excluded.kind, note=excluded.note, muted_by=excluded.muted_by,
		   muted_at=excluded.muted_at, expires_at=excluded.expires_at`,
		m.FindingID, m.Kind, m.Note, m.By, fmtTime(m.MutedAt), fmtTime(m.ExpiresAt)); err != nil {
		return FindingMute{}, fmt.Errorf("mute finding: %w", err)
	}
	s.pruneFindingMutes(now)
	return m, nil
}

// UnmuteFinding lifts a silence early and reports whether there was one to
// lift. A miss is not an error: "make this finding speak again" is satisfied
// either way, and the common way to hit it is two tabs open on the same card.
func (s *Store) UnmuteFinding(id string, now time.Time) (bool, error) {
	res, err := s.write.Exec(`DELETE FROM finding_mutes WHERE finding_id=?`, strings.TrimSpace(id))
	if err != nil {
		return false, fmt.Errorf("unmute finding: %w", err)
	}
	n, _ := res.RowsAffected()
	s.pruneFindingMutes(now)
	return n > 0, nil
}

// ActiveFindingMutes returns the silences in force at `now`, newest expiry
// first.
//
// The expiry is applied HERE, in the query, not by the pruner: a hub that has
// taken no writes for a week must still stop honouring a mute the moment it
// runs out, and a read path that trusted the table to be clean would keep an
// alert quiet for as long as nobody happened to mute anything else.
func (s *Store) ActiveFindingMutes(now time.Time) ([]FindingMute, error) {
	return s.findingMutes(`WHERE expires_at > ?`, fmtTime(now.UTC()))
}

// AllFindingMutes returns every row, expired ones included. For the roster
// view: "what did we silence, and what has already come back" is one question,
// and answering it needs the rows the read path deliberately ignores.
func (s *Store) AllFindingMutes() ([]FindingMute, error) { return s.findingMutes(``) }

func (s *Store) findingMutes(where string, args ...any) ([]FindingMute, error) {
	rows, err := s.read.Query(
		`SELECT finding_id,kind,note,muted_by,muted_at,expires_at FROM finding_mutes `+
			where+` ORDER BY expires_at DESC`, args...)
	if err != nil {
		return nil, fmt.Errorf("list finding mutes: %w", err)
	}
	defer rows.Close()
	out := []FindingMute{}
	for rows.Next() {
		var m FindingMute
		var mutedAt, expiresAt string
		if err := rows.Scan(&m.FindingID, &m.Kind, &m.Note, &m.By, &mutedAt, &expiresAt); err != nil {
			return nil, err
		}
		m.MutedAt, _ = time.Parse(rfc, mutedAt)
		m.ExpiresAt, _ = time.Parse(rfc, expiresAt)
		out = append(out, m)
	}
	return out, rows.Err()
}

// pruneFindingMutes drops rows that expired a while ago. It rides on the write
// path because that is the only moment this table is touched at all, and it is
// a cleanup rather than a correctness step — reads already filter on the clock.
//
// The grace period is why it is not `expires_at <= now`: an operator looking at
// the roster right after a mute lapsed should see that it lapsed, rather than
// find the row gone and wonder whether they imagined muting it.
func (s *Store) pruneFindingMutes(now time.Time) {
	_, _ = s.write.Exec(`DELETE FROM finding_mutes WHERE expires_at < ?`,
		fmtTime(now.Add(-mutePruneGrace).UTC()))
}

// mutePruneGrace is how long an expired mute stays visible on the roster
// before it is swept.
const mutePruneGrace = 7 * 24 * time.Hour

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
