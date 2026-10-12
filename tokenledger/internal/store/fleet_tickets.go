package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// The ticket (claude-fleet#2677, EPIC #3570 C1): the whole of a ticket whose
// home is the hub — title · body · thread · state · labels · priority · who is
// on it · its parent (the batch it hangs on) — so a repo that is not on GitHub
// has somewhere to open one, and a private matter never goes into a public code
// repo. A ticket is (repo, number): `hub:<repo>#<N>`, numbered per repo by
// fleet_ticket_seq inside the transaction that writes it, so two openers never
// get one number. The body and the thread live here and nowhere else (EPIC
// #3570 共同约定 5).
//
// It grows out of the registry of #2676 (`fleet_ticket_index`, one row per
// GitHub ticket a node opened): those rows are copied in once as `gh` tickets
// — backend gh, the GitHub page as url, no body — and /register writes here
// for one version (# compat-1v: 下一批删 the index table and its road).
//
// A ticket is not a task record (fleet_tasks.go): T<n> is who asked for what;
// a ticket is what a repo has to do, and hangs on the record as its `issue`.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetTicketsSchema = `
CREATE TABLE IF NOT EXISTS fleet_tickets (
  repo         TEXT NOT NULL,
  num          INTEGER NOT NULL,
  owner        TEXT NOT NULL,
  backend      TEXT NOT NULL DEFAULT 'hub',
  url          TEXT NOT NULL DEFAULT '',
  title        TEXT NOT NULL,
  body         TEXT NOT NULL DEFAULT '',
  state        TEXT NOT NULL DEFAULT 'open',
  state_reason TEXT NOT NULL DEFAULT '',
  labels       TEXT NOT NULL DEFAULT '[]',
  priority     TEXT NOT NULL DEFAULT '',
  assignee     TEXT NOT NULL DEFAULT '',
  claimed_at   TEXT NOT NULL DEFAULT '',
  parent       TEXT NOT NULL DEFAULT '',
  origin       TEXT NOT NULL DEFAULT '',
  endpoint_id  TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  PRIMARY KEY (repo, num)
);
CREATE INDEX IF NOT EXISTS fleet_tickets_owner ON fleet_tickets(owner, updated_at);
CREATE INDEX IF NOT EXISTS fleet_tickets_parent ON fleet_tickets(parent);
CREATE TABLE IF NOT EXISTS fleet_ticket_comments (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  repo        TEXT NOT NULL,
  num         INTEGER NOT NULL,
  author      TEXT NOT NULL,
  body        TEXT NOT NULL,
  source      TEXT NOT NULL DEFAULT 'hub',
  marker      TEXT NOT NULL DEFAULT '',
  created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_ticket_comments_ticket ON fleet_ticket_comments(repo, num, id);
CREATE TABLE IF NOT EXISTS fleet_ticket_seq (
  repo    TEXT PRIMARY KEY,
  next_n  INTEGER NOT NULL
);`

// The registry of #2676, kept one version so its rows can be copied over.
// # compat-1v: 下一批删
const fleetTicketIndexSchema = `
CREATE TABLE IF NOT EXISTS fleet_ticket_index (
  id           TEXT PRIMARY KEY,
  owner        TEXT NOT NULL,
  title        TEXT NOT NULL,
  state        TEXT NOT NULL,
  backend      TEXT NOT NULL,
  url          TEXT NOT NULL,
  origin       TEXT NOT NULL,
  endpoint_id  TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);`

// Ticket backends: where the ticket's home is.
const (
	TicketHub    = "hub" // the hub holds all of it
	TicketGitHub = "gh"  // a GitHub issue registered here (#2676): no body, no thread
)

// FleetTicket is one ticket.
type FleetTicket struct {
	ID          string    `json:"id"` // hub:<repo>#<N> / gh:<repo>#<N>
	Repo        string    `json:"repo"`
	Number      int64     `json:"number"`
	Owner       string    `json:"owner"`
	Backend     string    `json:"backend"`
	URL         string    `json:"url,omitempty"`
	Title       string    `json:"title"`
	Body        string    `json:"body"`
	State       string    `json:"state"`
	StateReason string    `json:"state_reason,omitempty"`
	Labels      []string  `json:"labels"`
	Priority    string    `json:"priority,omitempty"`
	Assignee    string    `json:"assignee,omitempty"`
	ClaimedAt   string    `json:"claimed_at,omitempty"`
	Parent      string    `json:"parent,omitempty"` // <repo>#<N>
	Origin      string    `json:"origin,omitempty"`
	EndpointID  string    `json:"endpoint_id,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// TicketComment is one entry of a ticket's thread.
type TicketComment struct {
	ID        int64     `json:"id"`
	Repo      string    `json:"repo"`
	Number    int64     `json:"number"`
	Author    string    `json:"author"`
	Body      string    `json:"body"`
	Source    string    `json:"source"` // hub | github | fleet
	Marker    string    `json:"marker,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

var (
	// ErrTicketOwner: the ticket belongs to another person.
	ErrTicketOwner = errors.New("this ticket is registered to another person")
	// ErrTicketTaken: an imported number is already a ticket of that repo.
	ErrTicketTaken = errors.New("that number is already a ticket in this repo")
	// ErrTicketClaimed: someone else is on it; the error carries who.
	ErrTicketClaimed = errors.New("someone else has claimed this ticket")
)

// TicketRef is a ticket's id as the fleet writes it.
func TicketRef(backend, repo string, n int64) string {
	return backend + ":" + repo + "#" + strconv.FormatInt(n, 10)
}

func (s *Store) ensureFleetTickets() error {
	for _, q := range []string{fleetTicketIndexSchema, fleetTicketsSchema} {
		if _, err := s.write.Exec(s.d.ddl(q)); err != nil {
			return fmt.Errorf("create fleet_tickets tables: %w", err)
		}
	}
	// The registry's rows come over once, as gh tickets (a row already here —
	// copied before, or opened since — is left alone).
	rows, err := s.read.Query(`SELECT id, owner, title, state, url, origin, endpoint_id, created_at, updated_at
		FROM fleet_ticket_index`)
	if err != nil {
		return err
	}
	type idx struct{ id, owner, title, state, url, origin, ep, created, updated string }
	var old []idx
	for rows.Next() {
		var r idx
		if err := rows.Scan(&r.id, &r.owner, &r.title, &r.state, &r.url, &r.origin, &r.ep, &r.created, &r.updated); err != nil {
			rows.Close()
			return err
		}
		old = append(old, r)
	}
	rows.Close()
	for _, r := range old {
		repo, n, ok := splitGHID(r.id)
		if !ok {
			continue
		}
		if _, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_tickets (repo, num, owner, backend, url,
			title, state, origin, endpoint_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`),
			repo, n, r.owner, TicketGitHub, r.url, r.title, r.state, r.origin, r.ep, r.created, r.updated); err != nil {
			return err
		}
	}
	return nil
}

// splitGHID reads gh:<owner>/<name>#<N>.
func splitGHID(id string) (string, int64, bool) {
	rest, ok := strings.CutPrefix(id, TicketGitHub+":")
	if !ok {
		return "", 0, false
	}
	repo, num, ok := strings.Cut(rest, "#")
	n, err := strconv.ParseInt(num, 10, 64)
	if !ok || err != nil || n <= 0 || repo == "" {
		return "", 0, false
	}
	return NormRepo(repo), n, true
}

const fleetTicketCols = `repo, num, owner, backend, url, title, body, state, state_reason, labels, priority,
	assignee, claimed_at, parent, origin, endpoint_id, created_at, updated_at`

func labelsJSON(l []string) string {
	if l == nil {
		l = []string{}
	}
	b, _ := json.Marshal(l)
	return string(b)
}

// CreateFleetTicket opens a hub ticket in t.Repo. number 0 takes the repo's
// next number; a number > 0 is an import (a mirror bringing its own numbers):
// refused with ErrTicketTaken when the repo already has it, and the repo's
// sequence moves past it, so the hub carries on from the highest number.
func (s *Store) CreateFleetTicket(t FleetTicket, number int64, now time.Time) (FleetTicket, error) {
	repo := NormRepo(t.Repo)
	if repo == "" || t.Owner == "" || t.Title == "" {
		return FleetTicket{}, errors.New("a ticket needs a repo, an owner and a title")
	}
	tx, err := s.write.Begin()
	if err != nil {
		return FleetTicket{}, err
	}
	defer tx.Rollback()
	// The repo's row is locked by the UPDATE, so a second opener waits here
	// and reads the number this one left.
	if _, err := tx.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_ticket_seq (repo, next_n) VALUES (?, 1)`), repo); err != nil {
		return FleetTicket{}, err
	}
	if _, err := tx.Exec(`UPDATE fleet_ticket_seq SET next_n = next_n WHERE repo = ?`, repo); err != nil {
		return FleetTicket{}, err
	}
	var next int64
	if err := tx.QueryRow(`SELECT next_n FROM fleet_ticket_seq WHERE repo = ?`, repo).Scan(&next); err != nil {
		return FleetTicket{}, err
	}
	n := number
	if n <= 0 {
		n = next
	}
	var taken int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM fleet_tickets WHERE repo = ? AND num = ?`, repo, n).Scan(&taken); err != nil {
		return FleetTicket{}, err
	}
	if taken > 0 {
		if number > 0 {
			return FleetTicket{}, ErrTicketTaken
		}
		// A number an import took ahead of the sequence: carry on past it.
		if err := tx.QueryRow(`SELECT MAX(num) FROM fleet_tickets WHERE repo = ?`, repo).Scan(&n); err != nil {
			return FleetTicket{}, err
		}
		n++
	}
	if n >= next {
		if _, err := tx.Exec(`UPDATE fleet_ticket_seq SET next_n = ? WHERE repo = ?`, n+1, repo); err != nil {
			return FleetTicket{}, err
		}
	}
	state := t.State
	if state == "" {
		state = "open"
	}
	ts := now.UTC().Format(rfc)
	if _, err := tx.Exec(`INSERT INTO fleet_tickets (`+fleetTicketCols+`)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		repo, n, t.Owner, TicketHub, "", t.Title, t.Body, state, t.StateReason, labelsJSON(t.Labels), t.Priority,
		"", "", t.Parent, t.Origin, t.EndpointID, ts, ts); err != nil {
		return FleetTicket{}, err
	}
	if err := tx.Commit(); err != nil {
		return FleetTicket{}, err
	}
	return s.FleetTicketAt(repo, n)
}

// RegisterTicket is #2676's registry road, now a gh ticket here: the row is
// written, or its title · state · url · origin refreshed when the same owner
// registers it again. Another owner's ticket is ErrTicketOwner; a number the
// repo already holds as a hub ticket is ErrTicketTaken. # compat-1v: 下一批删
func (s *Store) RegisterTicket(id string, t FleetTicket, now time.Time) (FleetTicket, error) {
	repo, n, ok := splitGHID(id)
	if !ok {
		return FleetTicket{}, fmt.Errorf("not a gh ticket id: %q", id)
	}
	old, err := s.FleetTicketAt(repo, n)
	switch {
	case errors.Is(err, sql.ErrNoRows):
	case err != nil:
		return FleetTicket{}, err
	case old.Backend != TicketGitHub:
		return FleetTicket{}, ErrTicketTaken
	case old.Owner != t.Owner:
		return FleetTicket{}, ErrTicketOwner
	}
	ts := now.UTC().Format(rfc)
	if _, err := s.write.Exec(`INSERT INTO fleet_tickets (repo, num, owner, backend, url, title, state, origin,
		endpoint_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(repo, num) DO UPDATE SET title = excluded.title, state = excluded.state,
		  url = excluded.url, origin = excluded.origin, endpoint_id = excluded.endpoint_id,
		  updated_at = excluded.updated_at`,
		repo, n, t.Owner, TicketGitHub, t.URL, t.Title, t.State, t.Origin, t.EndpointID, ts, ts); err != nil {
		return FleetTicket{}, err
	}
	return s.FleetTicketAt(repo, n)
}

// FleetTicketAt reads one ticket; sql.ErrNoRows when there is none.
func (s *Store) FleetTicketAt(repo string, n int64) (FleetTicket, error) {
	rows, err := s.read.Query(`SELECT `+fleetTicketCols+` FROM fleet_tickets WHERE repo = ? AND num = ?`, NormRepo(repo), n)
	if err != nil {
		return FleetTicket{}, err
	}
	out, err := scanFleetTickets(rows)
	if err != nil {
		return FleetTicket{}, err
	}
	if len(out) == 0 {
		return FleetTicket{}, sql.ErrNoRows
	}
	return out[0], nil
}

// TicketFilter narrows a list. Owner "" with All lists everyone's (the
// operator's door); Owner "" without All lists nothing.
type TicketFilter struct {
	Owner  string
	All    bool
	Repo   string
	State  string
	Label  string
	Parent string // <repo>#<N>: that ticket's children
	Since  time.Time
	Limit  int
}

// FleetTickets lists tickets, most recently touched first.
func (s *Store) FleetTickets(f TicketFilter) ([]FleetTicket, error) {
	if f.Limit <= 0 || f.Limit > 500 {
		f.Limit = 200
	}
	if !f.All && f.Owner == "" {
		return []FleetTicket{}, nil
	}
	where, args := []string{}, []any{}
	if !f.All || f.Owner != "" {
		where, args = append(where, "owner = ?"), append(args, f.Owner)
	}
	if f.Repo != "" {
		where, args = append(where, "repo = ?"), append(args, NormRepo(f.Repo))
	}
	if f.State != "" {
		where, args = append(where, "state = ?"), append(args, f.State)
	}
	if f.Label != "" {
		// labels is a JSON array of strings that hold no quote or backslash.
		where, args = append(where, "labels LIKE ?"), append(args, `%"`+f.Label+`"%`)
	}
	if f.Parent != "" {
		where, args = append(where, "parent = ?"), append(args, f.Parent)
	}
	if !f.Since.IsZero() {
		where, args = append(where, "updated_at >= ?"), append(args, f.Since.UTC().Format(rfc))
	}
	q := `SELECT ` + fleetTicketCols + ` FROM fleet_tickets`
	if len(where) > 0 {
		q += ` WHERE ` + strings.Join(where, " AND ")
	}
	rows, err := s.read.Query(q+` ORDER BY updated_at DESC, repo, num LIMIT `+strconv.Itoa(f.Limit), args...)
	if err != nil {
		return nil, err
	}
	return scanFleetTickets(rows)
}

// TicketEdit is a PATCH: a nil field is left as it is.
type TicketEdit struct {
	Title, Body, State, StateReason, Priority, Parent *string
	Labels                                            *[]string
}

// EditFleetTicket applies e and returns the ticket.
func (s *Store) EditFleetTicket(repo string, n int64, e TicketEdit, now time.Time) (FleetTicket, error) {
	sets, args := []string{}, []any{}
	for _, f := range []struct {
		col string
		v   *string
	}{{"title", e.Title}, {"body", e.Body}, {"state", e.State}, {"state_reason", e.StateReason},
		{"priority", e.Priority}, {"parent", e.Parent}} {
		if f.v != nil {
			sets, args = append(sets, f.col+" = ?"), append(args, *f.v)
		}
	}
	if e.Labels != nil {
		sets, args = append(sets, "labels = ?"), append(args, labelsJSON(*e.Labels))
	}
	if len(sets) > 0 {
		sets, args = append(sets, "updated_at = ?"), append(args, now.UTC().Format(rfc))
		res, err := s.write.Exec(`UPDATE fleet_tickets SET `+strings.Join(sets, ", ")+` WHERE repo = ? AND num = ?`,
			append(args, NormRepo(repo), n)...)
		if err != nil {
			return FleetTicket{}, err
		}
		if k, _ := res.RowsAffected(); k == 0 {
			return FleetTicket{}, sql.ErrNoRows
		}
	}
	return s.FleetTicketAt(repo, n)
}

// ClaimFleetTicket puts by on the ticket in one statement: it takes a ticket
// nobody is on (or by already is), and refuses with ErrTicketClaimed and the
// holder's name otherwise. release takes by off it again (a no-op when by is
// not the one on it).
func (s *Store) ClaimFleetTicket(repo string, n int64, by string, release bool, now time.Time) (FleetTicket, string, error) {
	repo = NormRepo(repo)
	ts := now.UTC().Format(rfc)
	var res sql.Result
	var err error
	if release {
		res, err = s.write.Exec(`UPDATE fleet_tickets SET assignee = '', claimed_at = '', updated_at = ?
			WHERE repo = ? AND num = ? AND assignee = ?`, ts, repo, n, by)
	} else {
		res, err = s.write.Exec(`UPDATE fleet_tickets SET assignee = ?, claimed_at = ?, updated_at = ?
			WHERE repo = ? AND num = ? AND (assignee = '' OR assignee = ?)`, by, ts, ts, repo, n, by)
	}
	if err != nil {
		return FleetTicket{}, "", err
	}
	k, _ := res.RowsAffected()
	t, err := s.FleetTicketAt(repo, n)
	if err != nil {
		return FleetTicket{}, "", err
	}
	if k == 0 && !release {
		return t, t.Assignee, ErrTicketClaimed
	}
	return t, t.Assignee, nil
}

// AddTicketComment appends c to its ticket's thread and touches the ticket.
func (s *Store) AddTicketComment(c TicketComment, now time.Time) (TicketComment, error) {
	repo := NormRepo(c.Repo)
	if c.Source == "" {
		c.Source = "hub"
	}
	ts := now.UTC().Format(rfc)
	tx, err := s.write.Begin()
	if err != nil {
		return TicketComment{}, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`UPDATE fleet_tickets SET updated_at = ? WHERE repo = ? AND num = ?`, ts, repo, c.Number)
	if err != nil {
		return TicketComment{}, err
	}
	if k, _ := res.RowsAffected(); k == 0 {
		return TicketComment{}, sql.ErrNoRows
	}
	if _, err := tx.Exec(`INSERT INTO fleet_ticket_comments (repo, num, author, body, source, marker, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, repo, c.Number, c.Author, c.Body, c.Source, c.Marker, ts); err != nil {
		return TicketComment{}, err
	}
	var id int64
	if err := tx.QueryRow(`SELECT MAX(id) FROM fleet_ticket_comments WHERE repo = ? AND num = ?`, repo, c.Number).Scan(&id); err != nil {
		return TicketComment{}, err
	}
	if err := tx.Commit(); err != nil {
		return TicketComment{}, err
	}
	c.ID, c.Repo, c.CreatedAt = id, repo, now.UTC().Truncate(time.Second)
	return c, nil
}

// TicketComments is a ticket's thread, oldest first.
func (s *Store) TicketComments(repo string, n int64) ([]TicketComment, error) {
	rows, err := s.read.Query(`SELECT id, repo, num, author, body, source, marker, created_at
		FROM fleet_ticket_comments WHERE repo = ? AND num = ? ORDER BY id`, NormRepo(repo), n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []TicketComment{}
	for rows.Next() {
		var c TicketComment
		var created string
		if err := rows.Scan(&c.ID, &c.Repo, &c.Number, &c.Author, &c.Body, &c.Source, &c.Marker, &created); err != nil {
			return nil, err
		}
		c.CreatedAt, _ = time.Parse(rfc, created)
		out = append(out, c)
	}
	return out, rows.Err()
}

func scanFleetTickets(rows *sql.Rows) ([]FleetTicket, error) {
	defer rows.Close()
	out := []FleetTicket{}
	for rows.Next() {
		var t FleetTicket
		var labels, created, updated string
		if err := rows.Scan(&t.Repo, &t.Number, &t.Owner, &t.Backend, &t.URL, &t.Title, &t.Body, &t.State,
			&t.StateReason, &labels, &t.Priority, &t.Assignee, &t.ClaimedAt, &t.Parent, &t.Origin, &t.EndpointID,
			&created, &updated); err != nil {
			return nil, err
		}
		_ = json.Unmarshal([]byte(labels), &t.Labels)
		if t.Labels == nil {
			t.Labels = []string{}
		}
		t.ID = TicketRef(t.Backend, t.Repo, t.Number)
		t.CreatedAt, _ = time.Parse(rfc, created)
		t.UpdatedAt, _ = time.Parse(rfc, updated)
		out = append(out, t)
	}
	return out, rows.Err()
}
