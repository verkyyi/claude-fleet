package model

import (
	"fmt"
	"regexp"
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

	// VerifyHealth is the shipper's own reading of how trustworthy this
	// repository's post-release verification is. Nil means the shipper does
	// not measure it — NOT that it is healthy.
	VerifyHealth *RepoVerifyHealth `json:"verify_health,omitempty"`

	// HumanSteps and HumanDays carry the OTHER half of progress: the work
	// that is waiting on a person rather than on a machine.
	//
	// They ride the same snapshot, under the same repo key and the same
	// enrollment credential, because they answer a question the flow cards
	// above cannot: a backlog can be moving fast and still be blocked, if
	// what it is blocked on is somebody doing something by hand. Splitting
	// them into a second endpoint would have bought a second contract, a
	// second token and a second way for the two halves to disagree about
	// which repository they describe.
	//
	// A shipper may send either list alone: the collector that holds issue
	// flow and the collector that can parse a repo's release fragments are
	// not necessarily the same program (in the fleet that motivated this,
	// they are not — one runs in-cluster with a GitHub token, the other runs
	// where the repository is checked out, because the parse rules live in
	// the repo and must never be copied).
	HumanSteps []RepoHumanStep `json:"human_steps,omitempty"`
	HumanDays  []RepoHumanDay  `json:"human_days,omitempty"`
}

// RepoVerifyHealth carries readings the hub stores and shows but never
// computes, re-derives, or second-guesses.
//
// That split is the whole point. These readings are honest only because of
// rules that live in the producer: a percentile is withheld below a sample
// floor, a ratio is withheld below a denominator floor, an unfinished
// observation is reported as a lower bound with a leading marker, and a
// reading that could not be taken says WHY instead of degrading to zero.
// Re-deriving any of that here would put those rules in two places, and two
// copies of a judgement drift without either side reporting a problem — which
// is the exact failure these readings exist to measure.
//
// So the hub holds pre-formatted strings, the way it already holds issue
// titles: data produced elsewhere, rendered verbatim. The page supplies only
// the framing (a translated label per known key, the observation time, and
// whether that time is stale).
type RepoVerifyHealth struct {
	// Source names the producer, so a reader who distrusts a figure knows
	// what to go read. Free text; it is shown, never parsed.
	Source string `json:"source,omitempty"`

	// StaleAfterSeconds is how long these readings stay current, according to
	// the shipper that takes them — a daily shipper says one thing, a weekly
	// one another.
	//
	// It is shipped rather than assumed because a surface that invents its own
	// staleness threshold is inventing a scale nobody measured, and because a
	// silently stale card and a healthy one look identical. Nil means the
	// shipper did not say; the page must then decline to judge freshness
	// rather than pick a number.
	StaleAfterSeconds *float64 `json:"stale_after_seconds,omitempty"`

	Readings []RepoReading `json:"readings"`
}

// RepoReading is one figure, already worded by the producer.
type RepoReading struct {
	// Key identifies the reading across snapshots so the page can attach a
	// translated label and keep row order stable. Lowercase, stable, and the
	// producer's to choose.
	Key string `json:"key"`

	// Label is the producer's own wording, used when the page has no
	// translation for Key. A reading the page has never heard of must still
	// render — a new figure that appears as a blank row is worse than an
	// untranslated one.
	Label string `json:"label,omitempty"`

	// Value is the figure as the producer chose to word it, INCLUDING any
	// honesty markers it carries (a bound marker on an unfinished
	// observation, "N cards" where a ratio was withheld, and so on).
	//
	// Required even when OK is false: a reading that could not be taken must
	// say why. "Not measured" and "measured, nothing wrong" are opposite
	// answers, and an empty cell reads as the second one.
	Value string `json:"value"`

	// Note is the caption a reader needs to not misread Value — the window it
	// covers, the denominator, the floor that withheld a figure.
	Note string `json:"note,omitempty"`

	// OK is false when the reading could not be taken. It defaults to false on
	// purpose: a producer that forgets to set it gets the fail-closed reading,
	// not a silent claim of health.
	OK bool `json:"ok"`
}

// RepoHumanStep is one step of release work that is waiting on a PERSON.
//
// # Why the hub stores these at all
//
// Everything else in this package is a fact about machines: tokens spent,
// issues opened, commits landed. This is the one fact about people, and it is
// here because it is the one that stalls a release: a batch with an unfinished
// manual step does not ship, however green every check is.
//
// # Done steps are still shipped
//
// Done false means "still owed". A step that has been done keeps arriving —
// with a time when anyone recorded one — until its fragment is archived. That is deliberate: if done
// meant "the shipper stops sending it", then a broken shipper and a productive
// afternoon would look identical here — and the second one is the one a reader
// would assume.
//
// # OwnerID is not an identity this hub can match a viewer against
//
// It is whatever the producing repo uses to address the person on its own
// notification channel (a WeCom open_userid, in the fleet this was built for).
// This hub's SSO ticket carries no per-person subject at all — one fixed
// subject per (app, tenant) — so a surface here MUST NOT filter rows by "the
// signed-in user". Group by owner and say so; claiming "these are yours" on a
// hub that cannot tell two colleagues apart is a lie with a login page in
// front of it.
type RepoHumanStep struct {
	// Fragment is the issue number of the release fragment this step lives
	// in, and Ord is the numbered step within it. Together with Repo they key
	// the row: a step is identified by WHERE IT IS WRITTEN, not by any id the
	// notification channel minted, because the same step keeps its place
	// across a card being deleted and rebuilt.
	Fragment int `json:"fragment"`
	Ord      int `json:"ord"`

	// Owner is the raw owner string as written in the fragment ("发起人",
	// "Verky Yi", "agent"). It is kept verbatim beside the resolution below
	// because a row whose owner could not be resolved must still be able to
	// say WHO IT NAMED — that string is the whole lead for fixing it.
	Owner string `json:"owner"`
	// OwnerKind is how the producing repo resolved that string. A closed set:
	// see the RepoOwner* constants. "unresolved" and "not-a-person" are shown,
	// never silently dropped — a step nobody can be reminded about is the most
	// stuck kind there is, and dropping it would make it the most invisible.
	OwnerKind string `json:"owner_kind"`
	OwnerID   string `json:"owner_id,omitempty"`

	// Title is the step itself. How/Pass/Exit are the three things the person
	// doing it needs: how to do it, what counts as done, and what to do if
	// they cannot. They are optional because the author may not have written
	// them — and when they did not, the surface says so rather than inventing
	// an acceptance criterion the reader has no second source to check.
	Title string `json:"title"`
	How   string `json:"how,omitempty"`
	Pass  string `json:"pass,omitempty"`
	Exit  string `json:"exit,omitempty"`

	FragmentTitle string    `json:"fragment_title,omitempty"`
	FragmentURL   string    `json:"fragment_url,omitempty"`
	FragmentAt    time.Time `json:"fragment_at"`

	// TodoAt is when the person was actually told (a card was created on the
	// notification channel). Nil means nobody has been told yet, which is a
	// different problem from "told and ignored" — and the two want different
	// fixes, so they must not render the same.
	TodoAt *time.Time `json:"todo_at,omitempty"`

	// Done and DoneAt are two different facts, and the second one is the
	// optional half.
	//
	// A step is marked done by striking it out in the fragment, and a person
	// can do that by hand in the editor — in which case it IS done and there
	// is no timestamp anywhere. Requiring a time would force the shipper to
	// choose between inventing one and reporting the step as still owed;
	// both are wrong, and the second one is the one that keeps a finished
	// step at the top of somebody's list forever.
	Done   bool       `json:"done,omitempty"`
	DoneAt *time.Time `json:"done_at,omitempty"`
	DoneBy string     `json:"done_by,omitempty"`
}

// Owner resolutions. Closed set for the same reason issue states are: a fourth
// spelling would quietly create a fourth bucket that no surface counts.
const (
	// RepoOwnerPerson: the producing repo resolved the owner to someone it can
	// address on its notification channel.
	RepoOwnerPerson = "person"
	// RepoOwnerNotAPerson: the step names something that is not a human at all
	// (an agent, a workflow). It still blocks the release; it just cannot be
	// solved by reminding anybody.
	RepoOwnerNotAPerson = "not-a-person"
	// RepoOwnerUnresolved: a name nobody could match. Loudest of the three,
	// because it is the one where the person is never going to hear about it.
	RepoOwnerUnresolved = "unresolved"
)

// RepoHumanDay is one UTC day of "how much of this repo's release work needed
// a human", pre-aggregated by the shipper.
//
// This is the ratio the whole feature is judged by, so it is stored as its two
// halves and never as the quotient: a stored percentage cannot be re-summed
// into a week, and a week is the grain a reader actually asks about.
//
// Fragments counts every release fragment created that day; WithHuman counts
// the subset carrying at least one manual step. Both are needed — "3 manual
// fragments" is a number that means nothing until you know whether the day had
// four fragments or four hundred.
type RepoHumanDay struct {
	Day       string `json:"day"` // YYYY-MM-DD, UTC
	Fragments int    `json:"fragments"`
	WithHuman int    `json:"with_human"`
	Steps     int    `json:"steps"`
	// StepsDone is how many of that day's steps have since been completed. It
	// is a property of the steps born that day, not of the day they were
	// finished — otherwise a burst of catching-up would read as a day that
	// created no manual work.
	StepsDone int `json:"steps_done"`
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
	if len(s.Issues) == 0 && len(s.Days) == 0 && s.VerifyHealth == nil &&
		len(s.HumanSteps) == 0 && len(s.HumanDays) == 0 {
		return fmt.Errorf("repo %s: snapshot carries no rows at all", s.Repo)
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
	if s.VerifyHealth != nil {
		if err := s.VerifyHealth.validate(s.Repo); err != nil {
			return err
		}
	}
	for _, h := range s.HumanSteps {
		if err := h.validate(s.Repo); err != nil {
			return err
		}
	}
	for _, d := range s.HumanDays {
		if err := d.validate(s.Repo); err != nil {
			return err
		}
	}
	return nil
}

// maxReadings caps one health block. The producer this was built for ships
// three; a shipper pushing dozens is looping, and a card nobody can read in
// one glance is the surface this feature exists to replace.
const maxReadings = 12

// maxReadingText caps each string. Long enough for a sentence of context,
// short enough that a runaway producer cannot turn a dashboard card into a
// log file.
const maxReadingText = 400

// repoReadingKey is the key charset: lowercase, stable, no spelling variants.
// `Touch` and `touch` arriving from two shipper versions would render as two
// rows saying the same thing, and nothing would report a problem.
var repoReadingKey = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,63}$`)

func (h RepoVerifyHealth) validate(repo string) error {
	if len(h.Readings) == 0 {
		return fmt.Errorf("repo %s: verify_health carries no readings", repo)
	}
	if len(h.Readings) > maxReadings {
		return fmt.Errorf("repo %s: verify_health carries %d readings, max %d",
			repo, len(h.Readings), maxReadings)
	}
	if h.StaleAfterSeconds != nil && *h.StaleAfterSeconds <= 0 {
		return fmt.Errorf("repo %s: verify_health stale_after_seconds must be positive, got %v",
			repo, *h.StaleAfterSeconds)
	}
	if len(h.Source) > maxReadingText {
		return fmt.Errorf("repo %s: verify_health source is longer than %d bytes", repo, maxReadingText)
	}
	seen := make(map[string]bool, len(h.Readings))
	for _, r := range h.Readings {
		if !repoReadingKey.MatchString(r.Key) {
			return fmt.Errorf("repo %s: verify_health key %q is not lowercase [a-z0-9_-]", repo, r.Key)
		}
		// Two rows under one key is not a duplicate row, it is one reading
		// overwriting the other depending on map order.
		if seen[r.Key] {
			return fmt.Errorf("repo %s: verify_health key %q appears twice", repo, r.Key)
		}
		seen[r.Key] = true
		// The fail-closed rule, enforced rather than documented: a reading
		// that could not be taken still has to say so in words.
		if strings.TrimSpace(r.Value) == "" {
			return fmt.Errorf("repo %s: verify_health %q has no value — say why it could not be read, never leave it blank", repo, r.Key)
		}
		for name, v := range map[string]string{"label": r.Label, "value": r.Value, "note": r.Note} {
			if len(v) > maxReadingText {
				return fmt.Errorf("repo %s: verify_health %q %s is longer than %d bytes",
					repo, r.Key, name, maxReadingText)
			}
		}
	}
	return nil
}

func (h RepoHumanStep) validate(repo string) error {
	if h.Fragment <= 0 {
		return fmt.Errorf("repo %s: human step fragment must be positive, got %d", repo, h.Fragment)
	}
	if h.Ord <= 0 {
		return fmt.Errorf("repo %s fragment %d: human step ord must be positive, got %d", repo, h.Fragment, h.Ord)
	}
	switch h.OwnerKind {
	case RepoOwnerPerson, RepoOwnerNotAPerson, RepoOwnerUnresolved:
	default:
		return fmt.Errorf("repo %s fragment %d step %d: owner_kind must be %q, %q or %q, got %q",
			repo, h.Fragment, h.Ord, RepoOwnerPerson, RepoOwnerNotAPerson, RepoOwnerUnresolved, h.OwnerKind)
	}
	// A resolved person with no id would render as somebody the channel can
	// reach while nothing can address them. The shipper knows which of the
	// three it is; making it say so here keeps that knowledge from being
	// re-derived (wrongly) on every surface.
	if h.OwnerKind == RepoOwnerPerson && h.OwnerID == "" {
		return fmt.Errorf("repo %s fragment %d step %d: owner_kind %q needs owner_id",
			repo, h.Fragment, h.Ord, RepoOwnerPerson)
	}
	if h.Title == "" {
		return fmt.Errorf("repo %s fragment %d step %d: title is required", repo, h.Fragment, h.Ord)
	}
	if h.FragmentAt.IsZero() {
		return fmt.Errorf("repo %s fragment %d step %d: fragment_at is required", repo, h.Fragment, h.Ord)
	}
	if h.DoneAt != nil && h.DoneAt.Before(h.FragmentAt) {
		return fmt.Errorf("repo %s fragment %d step %d: done_at precedes fragment_at", repo, h.Fragment, h.Ord)
	}
	// A time without the fact is a shipper that filled one field and forgot
	// the other. Storing it would put the row in the owed list with a
	// completion time printed beside it — a contradiction a reader would
	// resolve by distrusting the whole card.
	if h.DoneAt != nil && !h.Done {
		return fmt.Errorf("repo %s fragment %d step %d: done_at without done", repo, h.Fragment, h.Ord)
	}
	if h.DoneBy != "" && !h.Done {
		return fmt.Errorf("repo %s fragment %d step %d: done_by without done", repo, h.Fragment, h.Ord)
	}
	return nil
}

func (d RepoHumanDay) validate(repo string) error {
	if _, err := time.Parse(RepoDayLayout, d.Day); err != nil {
		return fmt.Errorf("repo %s: human day %q is not %s", repo, d.Day, RepoDayLayout)
	}
	if d.Fragments < 0 || d.WithHuman < 0 || d.Steps < 0 || d.StepsDone < 0 {
		return fmt.Errorf("repo %s human day %s: counts cannot be negative", repo, d.Day)
	}
	// The subset relations are the whole meaning of the row. A day claiming
	// more manual fragments than fragments, or more done steps than steps,
	// would render as a ratio above 100%% -- and a reader seeing that would
	// distrust the axis, not the shipper that produced it.
	if d.WithHuman > d.Fragments {
		return fmt.Errorf("repo %s human day %s: with_human %d exceeds fragments %d", repo, d.Day, d.WithHuman, d.Fragments)
	}
	if d.StepsDone > d.Steps {
		return fmt.Errorf("repo %s human day %s: steps_done %d exceeds steps %d", repo, d.Day, d.StepsDone, d.Steps)
	}
	if d.Steps > 0 && d.WithHuman == 0 {
		return fmt.Errorf("repo %s human day %s: %d steps but no fragment carrying them", repo, d.Day, d.Steps)
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
