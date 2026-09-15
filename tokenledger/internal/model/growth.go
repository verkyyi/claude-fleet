package model

import (
	"fmt"
	"strings"
	"time"
)

// Growth facts: the business ledger that sits beside the token ledger.
//
// The rest of this package describes spend, and repo.go describes what the
// spend bought. This describes the third book: what the company actually earns
// while those two are running. Same hub, same SQLite file, same enrollment
// tokens — one internal ledger with three surfaces beats three dashboards
// nobody reconciles, and the issue number already joins the first two.
//
// The COLLECTOR is not in this repo, for the same reason the repo shipper is
// not: which production database, which credentials, how often and behind
// which firewall is a per-team concern. The hub is a sink.
//
// The half that matters most here is the half a machine CANNOT produce. The
// H5 subscription figures come off a production database every night; the AI
// deal figures are typed in by a person, and a person forgets. That asymmetry
// is why GrowthAI carries its own UpdatedAt and why AIStaleAfter exists: a
// dashboard printing last week's hand-filled number as though it were today's
// is worse than a dashboard printing nothing, because the reader cannot tell.

// GrowthDayLayout is the day key format: UTC calendar days, sortable as
// strings. Same shape as RepoDayLayout and deliberately its own name — the two
// ledgers key on the same kind of day and neither should have to read as the
// other to say so.
const GrowthDayLayout = RepoDayLayout

// AIStaleAfter is how long the hand-filled half may go without an update
// before a surface must stop printing its figures as current.
//
// Three days rather than a week: the AI deals are six conversations a person
// is personally carrying, and if nobody has touched them in three days the
// number on the board is not a fact about the business, it is a fact about who
// last opened the spreadsheet.
const AIStaleAfter = 3 * 24 * time.Hour

// GrowthSnapshot is one day of the business ledger as one shipper computed it.
//
// It is a whole-document snapshot keyed by (Source, Day), not a stream of
// deltas: everything here is a LEVEL — money on the books, accounts alive
// today — and levels do not add up. A replayed push overwrites the day rather
// than doubling it, which is what lets a shipper retry a flaky POST and what
// makes a missed night a gap rather than something to be back-filled. There is
// no watermark and nothing catches up; a day nobody shipped stays missing, and
// that is the honest record of a cron job that did not run.
type GrowthSnapshot struct {
	// Source names the shipper, and it is a tenant key: two shippers computing
	// the same day under two spellings would be two ledgers that never
	// reconcile.
	Source string `json:"source"`

	// Day is the UTC calendar day these figures describe — not when they were
	// pushed. A snapshot that arrives late is still a fact about its own day.
	Day string `json:"day"`

	H5  GrowthH5  `json:"h5"`
	AI  GrowthAI  `json:"ai"`
	OKR GrowthOKR `json:"okr"`
}

// GrowthH5 is the subscription business as a production database can see it.
//
// Money is whole CNY. The frozen shipper contract sends integers, and an
// integer is the right type for a figure that gets read aloud in a meeting:
// rounding a fraction into it silently would put a number on the board that
// matches no query anyone can re-run.
type GrowthH5 struct {
	// ARRCNY is annual recurring revenue on the books today.
	ARRCNY int64 `json:"arr_cny"`
	// ExpiringInWindowCNY and ExpiringAccounts are the same fact counted two
	// ways: how much renews in the window, and how many customers that is.
	ExpiringInWindowCNY int64 `json:"expiring_in_window_cny"`
	ExpiringAccounts    int   `json:"expiring_accounts"`
	ChurnedAccounts     int   `json:"churned_accounts"`
	ActiveAccounts      int   `json:"active_accounts"`
}

// GrowthAI is the new-business half, and it is typed in by hand.
//
// Six deals live in conversations, not in a system, so there is nothing to
// query. UpdatedAt is therefore not metadata — it is the field that decides
// whether the other three may be shown at all.
type GrowthAI struct {
	SignedDeals    int   `json:"signed_deals"`
	QualifiedLeads int   `json:"qualified_leads"`
	ARRCNY         int64 `json:"arr_cny"`

	// UpdatedAt is when a PERSON last confirmed these numbers, never when the
	// shipper ran. Required: a zero value would make the staleness rule below
	// unanswerable, and a surface that cannot tell fresh from stale has to
	// treat everything as fresh — which is the exact failure this field is
	// here to prevent.
	UpdatedAt time.Time `json:"updated_at"`
}

// GrowthOKR is the target the figures above are read against.
//
// It travels WITH the facts rather than being configured on the hub, for the
// same reason the repo ledger ships its own close-time percentiles: a target
// the hub invented is a number nobody agreed to, and a reader cannot tell one
// from the other once it is rendered.
type GrowthOKR struct {
	// Focus is single-valued on purpose. The quarter's whole discipline is
	// that there is exactly one direction; a list here would let a second one
	// grow quietly, which is precisely what the constraint exists to catch.
	Focus            string `json:"focus"`
	Quarter          string `json:"quarter"`
	TargetAnnualized int64  `json:"target_annualized"`

	// DaysToKillSwitch may be negative: the date passes whether or not anyone
	// re-decided, and a board that clamped it at zero would hide exactly the
	// week somebody needs to see.
	DaysToKillSwitch int `json:"days_to_kill_switch"`
}

// DaysSinceUpdate is whole days since a person last confirmed the AI half.
func (a GrowthAI) DaysSinceUpdate(now time.Time) int {
	d := now.Sub(a.UpdatedAt)
	if d < 0 {
		return 0
	}
	return int(d / (24 * time.Hour))
}

// Stale reports whether the hand-filled half is too old to be printed as
// current. A stale half is not an error and not an empty one: the figures are
// still the last thing a person said, they simply may not be shown as though
// they were said today.
func (a GrowthAI) Stale(now time.Time) bool {
	return now.Sub(a.UpdatedAt) > AIStaleAfter
}

// Validate rejects a snapshot the hub cannot store honestly.
//
// Strict, for the reason RepoSnapshot.Validate is strict and then one more:
// these are revenue figures that get read in a meeting. A source spelling or a
// day key that is merely odd becomes a second ledger nothing reconciles, and a
// negative or missing figure that is stored anyway becomes a sentence somebody
// says out loud.
func (s GrowthSnapshot) Validate(now time.Time) error {
	if err := ValidGrowthSource(s.Source); err != nil {
		return err
	}
	day, err := time.Parse(GrowthDayLayout, s.Day)
	if err != nil {
		return fmt.Errorf("growth %s: day %q is not %s", s.Source, s.Day, GrowthDayLayout)
	}
	// One day of slack, not five minutes: the shipper computes a CALENDAR day
	// and may well be running east of UTC, where the local date is already
	// tomorrow. Anything past that is a broken clock, and a snapshot filed
	// under a future day would sit at the top of the ledger for as long as it
	// took somebody to notice.
	if day.After(now.UTC().AddDate(0, 0, 1)) {
		return fmt.Errorf("growth %s: day %s is in the future", s.Source, s.Day)
	}
	if err := s.H5.validate(s.Source); err != nil {
		return err
	}
	if err := s.AI.validate(s.Source, now); err != nil {
		return err
	}
	return s.OKR.validate(s.Source)
}

func (h GrowthH5) validate(source string) error {
	for name, v := range map[string]int64{
		"h5.arr_cny":                h.ARRCNY,
		"h5.expiring_in_window_cny": h.ExpiringInWindowCNY,
		"h5.expiring_accounts":      int64(h.ExpiringAccounts),
		"h5.churned_accounts":       int64(h.ChurnedAccounts),
		"h5.active_accounts":        int64(h.ActiveAccounts),
	} {
		if v < 0 {
			return fmt.Errorf("growth %s: %s cannot be negative, got %d", source, name, v)
		}
	}
	return nil
}

func (a GrowthAI) validate(source string, now time.Time) error {
	if a.UpdatedAt.IsZero() {
		// The one field with no defensible default. Without it every surface
		// has to assume the figures are current, which is the failure the
		// field exists to prevent -- so the push is refused instead.
		return fmt.Errorf("growth %s: ai.updated_at is required "+
			"(it is what says whether the hand-filled figures may be shown as current)", source)
	}
	if a.UpdatedAt.After(now.Add(5 * time.Minute)) {
		return fmt.Errorf("growth %s: ai.updated_at %s is in the future",
			source, a.UpdatedAt.Format(time.RFC3339))
	}
	for name, v := range map[string]int64{
		"ai.signed_deals":    int64(a.SignedDeals),
		"ai.qualified_leads": int64(a.QualifiedLeads),
		"ai.arr_cny":         a.ARRCNY,
	} {
		if v < 0 {
			return fmt.Errorf("growth %s: %s cannot be negative, got %d", source, name, v)
		}
	}
	return nil
}

func (o GrowthOKR) validate(source string) error {
	// Both are printed on the board beside the money. An empty one renders as
	// a blank where the quarter's whole point belongs, and a blank reads as
	// "no target" rather than as "the shipper forgot a field".
	if strings.TrimSpace(o.Focus) == "" {
		return fmt.Errorf("growth %s: okr.focus is required", source)
	}
	if strings.TrimSpace(o.Quarter) == "" {
		return fmt.Errorf("growth %s: okr.quarter is required", source)
	}
	if o.TargetAnnualized < 0 {
		return fmt.Errorf("growth %s: okr.target_annualized cannot be negative, got %d",
			source, o.TargetAnnualized)
	}
	return nil
}

// maxGrowthSource bounds the tenant key. Long enough for any honest shipper
// name, short enough that a runaway field cannot become a primary key.
const maxGrowthSource = 64

// ValidGrowthSource accepts a lowercase slug and nothing else.
//
// Same reasoning as ValidRepoName: the source is half the primary key, so
// "growth-facts", "Growth-Facts" and " growth-facts" must not be allowed to
// become three ledgers. Rejecting is the only honest option — normalising
// silently would make a shipper's typo invisible to the one person who can fix
// it.
func ValidGrowthSource(source string) error {
	if source == "" {
		return fmt.Errorf("source is required")
	}
	if len(source) > maxGrowthSource {
		return fmt.Errorf("source %q is longer than %d bytes", source, maxGrowthSource)
	}
	for i, r := range source {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
		case (r == '-' || r == '_' || r == '.') && i > 0 && i < len(source)-1:
		default:
			return fmt.Errorf("source %q is not a lowercase slug "+
				"(a-z, 0-9, and - _ . between them)", source)
		}
	}
	return nil
}
