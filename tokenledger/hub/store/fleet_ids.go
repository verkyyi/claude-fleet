package store

import (
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// The hub's mirror of every window's ID (EPIC T497 C2; design page §3.3–§3.5,
// §7). A window's ID is its @fleet_id (a UUIDv4); the node keeps its ledger
// ($FLEET_CONF_DIR/ids/<ID>.ndjson, bin/fleet_id.py: opened · native · result ·
// closed, each with its (ID, seq)) and pushes it here in order. These three
// tables are only that ledger folded: ApplyFleetIDEvents applies event seq+1,
// skips what it already has and stops at a gap, so a push resent after an
// outage is a no-op for what landed and the record can always be rebuilt by
// replaying the nodes' ledgers.
//
// The short code (`T-` + the ID's leading lowercase Crockford base32) is unique
// within an owner: on registration the hub lengthens the LATER ID's code until
// no other ID of that owner shares it (bin/fleet_id.py short_for, the node's
// guess) and answers the node, which moves @task_short. Codes only ever grow.
// A full ID already registered by another node of any owner is refused
// (ErrIDDuplicate: a cloned machine) unless the push starts with `moved` — a
// fleet-move carrying the ledger to a new machine.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table;
// the old fleet_tasks is not touched.
//
// A `progress` event (EPIC T497 C12) is the window's latest progress word — an
// EPIC driver's tick, which used to be the task record's `progress`: only the
// newest is kept (progress · progress_state · progress_at · progress_seq), never a
// result, so it changes no status.
const fleetIDsSchema = `
CREATE TABLE IF NOT EXISTS fleet_ids (
  id           TEXT PRIMARY KEY,
  owner        TEXT NOT NULL,
  code         TEXT NOT NULL,
  short        TEXT NOT NULL,
  endpoint_id  TEXT NOT NULL,
  machine      TEXT NOT NULL DEFAULT '',
  login        TEXT NOT NULL DEFAULT '',
  win          TEXT NOT NULL DEFAULT '',
  title        TEXT NOT NULL DEFAULT '',
  agent        TEXT NOT NULL DEFAULT '',
  repo         TEXT NOT NULL DEFAULT '',
  issues       TEXT NOT NULL DEFAULT '[]',
  body         TEXT NOT NULL DEFAULT '',
  key          TEXT NOT NULL DEFAULT '',
  task         TEXT NOT NULL DEFAULT '',
  parent       TEXT NOT NULL DEFAULT '',
  prev         TEXT NOT NULL DEFAULT '',
  aliases      TEXT NOT NULL DEFAULT '[]',
  asked        TEXT NOT NULL DEFAULT '',
  parked       TEXT NOT NULL DEFAULT '',
  opened_at    INTEGER NOT NULL DEFAULT 0,
  closed_at    INTEGER NOT NULL DEFAULT 0,
  close_reason TEXT NOT NULL DEFAULT '',
  seq          INTEGER NOT NULL DEFAULT 0,
  natives      INTEGER NOT NULL DEFAULT 0,
  updated_at   TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS fleet_ids_owner_short ON fleet_ids(owner, short);
CREATE INDEX IF NOT EXISTS fleet_ids_owner_code ON fleet_ids(owner, code);
CREATE TABLE IF NOT EXISTS fleet_id_natives (
  id          TEXT NOT NULL,
  n           INTEGER NOT NULL,
  seq         INTEGER NOT NULL,
  agent       TEXT NOT NULL DEFAULT '',
  native      TEXT NOT NULL DEFAULT '',
  trig        TEXT NOT NULL DEFAULT '',
  source      TEXT NOT NULL DEFAULT '',
  from_ref    TEXT NOT NULL DEFAULT '',
  conflict    TEXT NOT NULL DEFAULT '',
  compactions INTEGER NOT NULL DEFAULT 0,
  start_at    INTEGER NOT NULL DEFAULT 0,
  end_at      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id, n)
);
CREATE INDEX IF NOT EXISTS fleet_id_natives_native ON fleet_id_natives(native);
CREATE TABLE IF NOT EXISTS fleet_id_results (
  id      TEXT NOT NULL,
  seq     INTEGER NOT NULL,
  state   TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  pr      TEXT NOT NULL DEFAULT '',
  agent   TEXT NOT NULL DEFAULT '',
  at      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id, seq)
);`

// IDShortMin is a short code's least length (bin/fleet_id.py SHORT_MIN).
const IDShortMin = 5

// IDPushMax bounds the events of one push.
const IDPushMax = 200

// ErrIDDuplicate: the full ID is already another node's (or another owner's).
var ErrIDDuplicate = errors.New("this ID is already registered by another machine")

var (
	idUUIDRE  = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	idIssueRE = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}#[1-9][0-9]{0,9}$`)
	idKeyRE   = regexp.MustCompile(`^(?:[A-Za-z0-9_.-]{1,100}:)?issue-([1-9][0-9]{0,9})$`)
)

const idAlphabet = "0123456789abcdefghjkmnpqrstvwxyz" // Crockford base32, lowercase

// IsFleetID reports whether s is an ID (a lowercase UUID, as fleet_fid_mint writes).
func IsFleetID(s string) bool { return idUUIDRE.MatchString(s) }

// FleetIDCode is the ID's full code: 128 bits → 26 base32 characters, most
// significant first (bin/fleet_id.py encode, byte for byte).
func FleetIDCode(id string) string {
	b, err := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	if err != nil || len(b) != 16 {
		return ""
	}
	n := new(big.Int).Lsh(new(big.Int).SetBytes(b), 2) // 130 bits = 26 × 5
	out := make([]byte, 26)
	m := big.NewInt(31)
	for i := 0; i < 26; i++ {
		d := new(big.Int).Rsh(n, uint(5*(25-i)))
		out[i] = idAlphabet[d.And(d, m).Int64()]
	}
	return string(out)
}

// NormIDCode is a typed code (`T-…`, `t-…` or bare) in its canonical lowercase
// form, or "" (bin/fleet_id.py norm_code).
func NormIDCode(s string) string {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "T-") || strings.HasPrefix(s, "t-") {
		s = s[2:]
	}
	s = strings.NewReplacer("i", "1", "l", "1", "o", "0").Replace(strings.ToLower(s))
	if len(s) < 4 || len(s) > 26 {
		return ""
	}
	for _, c := range s {
		if !strings.ContainsRune(idAlphabet, c) {
			return ""
		}
	}
	return s
}

// FleetIDRecord is one ID as the hub mirrors it.
type FleetIDRecord struct {
	ID          string           `json:"id"`
	Short       string           `json:"short"`
	Owner       string           `json:"-"`
	EndpointID  string           `json:"-"`
	Machine     string           `json:"machine"`
	Login       string           `json:"login"`
	Window      string           `json:"window,omitempty"`
	Title       string           `json:"title,omitempty"`
	Agent       string           `json:"agent,omitempty"`
	Repo        string           `json:"repo,omitempty"`
	Issues      []string         `json:"issues"`
	Body        string           `json:"body,omitempty"`
	Key         string           `json:"key,omitempty"`
	Task        string           `json:"task,omitempty"`
	Parent      string           `json:"parent,omitempty"`
	Prev        string           `json:"prev,omitempty"`
	Aliases     []string         `json:"aliases"`
	Asked       string           `json:"asked,omitempty"`
	Parked      string           `json:"parked,omitempty"`
	OpenedAt    int64            `json:"opened_at"`
	ClosedAt    int64            `json:"closed_at,omitempty"`
	CloseReason string           `json:"close_reason,omitempty"`
	Seq         int              `json:"seq"`
	Natives     []FleetIDNative  `json:"natives"`
	Results     []FleetIDResult  `json:"results"`
	Progress    *FleetIDProgress `json:"progress,omitempty"`
}

// FleetIDProgress is an ID's newest progress word (a `progress` event).
type FleetIDProgress struct {
	Seq     int    `json:"seq"`
	State   string `json:"state,omitempty"`
	Summary string `json:"summary"`
	At      int64  `json:"at"`
}

// FleetIDNative is one native segment (a Claude session / Codex thread).
type FleetIDNative struct {
	N           int    `json:"n"`
	Seq         int    `json:"seq"`
	Agent       string `json:"agent"`
	Native      string `json:"native"`
	Trigger     string `json:"trigger"`
	Source      string `json:"source,omitempty"`
	From        string `json:"from,omitempty"`
	Conflict    string `json:"conflict,omitempty"`
	Compactions int    `json:"compactions"`
	Start       int64  `json:"start"`
	End         int64  `json:"end,omitempty"`
}

// FleetIDResult is one reported result; the newest is the one that counts.
type FleetIDResult struct {
	Seq     int    `json:"seq"`
	State   string `json:"state"`
	Summary string `json:"summary,omitempty"`
	PR      string `json:"pr,omitempty"`
	Agent   string `json:"agent,omitempty"`
	At      int64  `json:"at"`
}

// FleetIDPush is one node's push of an ID's ledger events.
type FleetIDPush struct {
	Owner      string
	EndpointID string
	Machine    string
	Login      string
	ID         string
	Events     []map[string]any
}

// FleetIDPushed is what the hub answers: the last seq it holds (the node pushes
// from seq+1 next time) and the short code the ID goes by.
type FleetIDPushed struct {
	Seq     int    `json:"seq"`
	Short   string `json:"short"`
	Machine string `json:"machine,omitempty"`
}

func (s *Store) ensureFleetIDs() error {
	if _, err := s.write.Exec(s.d.ddl(fleetIDsSchema)); err != nil {
		return fmt.Errorf("create fleet_ids tables: %w", err)
	}
	for _, c := range []struct{ col, spec string }{{"progress", "TEXT NOT NULL DEFAULT ''"},
		{"progress_state", "TEXT NOT NULL DEFAULT ''"}, {"progress_at", "INTEGER NOT NULL DEFAULT 0"},
		{"progress_seq", "INTEGER NOT NULL DEFAULT 0"}} {
		if err := s.addColumn("fleet_ids", c.col, c.spec); err != nil {
			return err
		}
	}
	return nil
}

func evStr(ev map[string]any, k string, max int) string {
	var v string
	switch x := ev[k].(type) {
	case string:
		v = x
	case float64:
		v = fmt.Sprintf("%.0f", x)
	case json.Number:
		v = x.String()
	default:
		return ""
	}
	v = strings.TrimSpace(v)
	if utf8.RuneCountInString(v) > max {
		v = string([]rune(v)[:max])
	}
	return v
}

func evInt(ev map[string]any, k string) int64 {
	switch x := ev[k].(type) {
	case float64:
		return int64(x)
	case json.Number:
		n, _ := x.Int64()
		return n
	}
	return 0
}

func addIssue(list []string, v string) []string {
	if !idIssueRE.MatchString(v) {
		return list
	}
	for _, x := range list {
		if x == v {
			return list
		}
	}
	return append(list, v)
}

// shortFor is the shortest code (≥ min) of `code` no other ID of the owner
// shares a prefix of.
func shortFor(tx *sql.Tx, owner, id, code string, min int) (string, error) {
	if min < IDShortMin {
		min = IDShortMin
	}
	rows, err := tx.Query(`SELECT code FROM fleet_ids WHERE owner = ? AND id <> ? AND substr(code, 1, ?) = ?`,
		owner, id, IDShortMin, code[:IDShortMin])
	if err != nil {
		return "", err
	}
	defer rows.Close()
	n := min
	for rows.Next() {
		var o string
		if err := rows.Scan(&o); err != nil {
			return "", err
		}
		for n < 26 && strings.HasPrefix(o, code[:n]) {
			n++
		}
	}
	return code[:n], rows.Err()
}

type idRow struct {
	FleetIDRecord
	issues, aliases string
	natives         int
	code            string
	// the pushing node, for `moved`
	pushEP, pushMachine, pushLogin string
}

// ApplyFleetIDEvents applies a node's events in seq order (see the file's head).
// A push for an ID another node holds is ErrIDDuplicate, nothing stored.
func (s *Store) ApplyFleetIDEvents(p FleetIDPush) (FleetIDPushed, error) {
	if !IsFleetID(p.ID) {
		return FleetIDPushed{}, fmt.Errorf("not an ID: %q", p.ID)
	}
	evs := append([]map[string]any(nil), p.Events...)
	sort.SliceStable(evs, func(i, j int) bool { return evInt(evs[i], "seq") < evInt(evs[j], "seq") })
	tx, err := s.write.Begin()
	if err != nil {
		return FleetIDPushed{}, err
	}
	defer tx.Rollback()
	if err := s.d.lockKey(tx, "fleet_ids", "fleet_ids:"+p.Owner); err != nil {
		return FleetIDPushed{}, err
	}
	r := idRow{}
	r.ID = p.ID
	err = tx.QueryRow(`SELECT owner, code, short, endpoint_id, machine, login, win, title, agent, repo, issues,
		body, key, task, parent, prev, aliases, asked, parked, opened_at, closed_at, close_reason, seq, natives
		FROM fleet_ids WHERE id = ?`+s.d.forUpdate(), p.ID).Scan(&r.Owner, &r.code, &r.Short, &r.EndpointID,
		&r.Machine, &r.Login, &r.Window, &r.Title, &r.Agent, &r.Repo, &r.issues, &r.Body, &r.Key, &r.Task,
		&r.Parent, &r.Prev, &r.aliases, &r.Asked, &r.Parked, &r.OpenedAt, &r.ClosedAt, &r.CloseReason, &r.Seq, &r.natives)
	exists := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return FleetIDPushed{}, err
	}
	if exists {
		if r.Owner != p.Owner {
			return FleetIDPushed{}, ErrIDDuplicate
		}
		if r.EndpointID != p.EndpointID {
			moved := false
			for _, ev := range evs {
				if int(evInt(ev, "seq")) == r.Seq+1 {
					moved = evStr(ev, "ev", 20) == "moved"
					break
				}
			}
			if !moved {
				return FleetIDPushed{Seq: r.Seq, Short: "T-" + r.Short, Machine: r.Machine}, ErrIDDuplicate
			}
		}
		_ = json.Unmarshal([]byte(r.issues), &r.Issues)
		_ = json.Unmarshal([]byte(r.aliases), &r.Aliases)
	} else {
		r.ID, r.Owner, r.code, r.EndpointID, r.Machine, r.Login = p.ID, p.Owner, FleetIDCode(p.ID), p.EndpointID, p.Machine, p.Login
	}
	r.pushEP, r.pushMachine, r.pushLogin = p.EndpointID, p.Machine, p.Login
	applied := 0
	for _, ev := range evs {
		seq := int(evInt(ev, "seq"))
		if seq <= r.Seq {
			continue // already here: a resend after an outage
		}
		if seq != r.Seq+1 {
			break // a gap: the node resends from r.Seq+1
		}
		if got := evStr(ev, "id", 64); got != "" && got != p.ID {
			return FleetIDPushed{}, fmt.Errorf("event %d names another ID", seq)
		}
		ts := evInt(ev, "ts")
		if !exists {
			min := IDShortMin
			if evStr(ev, "ev", 20) == "opened" {
				if c := NormIDCode(evStr(ev, "short", 32)); c != "" && strings.HasPrefix(r.code, c) {
					min = len(c)
				}
			}
			if r.Short, err = shortFor(tx, p.Owner, p.ID, r.code, min); err != nil {
				return FleetIDPushed{}, err
			}
			r.OpenedAt = ts
			if _, err := tx.Exec(`INSERT INTO fleet_ids (id, owner, code, short, endpoint_id, machine, login, opened_at, updated_at)
				VALUES (?,?,?,?,?,?,?,?,?)`, r.ID, r.Owner, r.code, r.Short, r.EndpointID, r.Machine, r.Login, ts,
				time.Now().UTC().Format(rfc)); err != nil {
				if isUniqueViolation(err) {
					return FleetIDPushed{}, ErrIDDuplicate
				}
				return FleetIDPushed{}, err
			}
			exists = true
		}
		if err := s.applyIDEvent(tx, &r, ev, seq, ts); err != nil {
			return FleetIDPushed{}, err
		}
		r.Seq = seq
		applied++
	}
	if applied > 0 {
		iss, _ := json.Marshal(nonNil(r.Issues))
		als, _ := json.Marshal(nonNil(r.Aliases))
		if _, err := tx.Exec(`UPDATE fleet_ids SET short = ?, endpoint_id = ?, machine = ?, login = ?, win = ?,
			title = ?, agent = ?, repo = ?, issues = ?, body = ?, key = ?, task = ?, parent = ?, prev = ?, aliases = ?,
			opened_at = ?, closed_at = ?, close_reason = ?, seq = ?, natives = ?, updated_at = ? WHERE id = ?`,
			r.Short, r.EndpointID, r.Machine, r.Login, r.Window, r.Title, r.Agent, r.Repo, string(iss), r.Body,
			r.Key, r.Task, r.Parent, r.Prev, string(als), r.OpenedAt, r.ClosedAt, r.CloseReason, r.Seq, r.natives,
			time.Now().UTC().Format(rfc), r.ID); err != nil {
			return FleetIDPushed{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return FleetIDPushed{}, err
	}
	out := FleetIDPushed{Seq: r.Seq, Machine: r.Machine}
	if r.Short != "" {
		out.Short = "T-" + r.Short
	}
	return out, nil
}

func nonNil(l []string) []string {
	if l == nil {
		return []string{}
	}
	return l
}

func fillStr(dst *string, v string) {
	if *dst == "" && v != "" {
		*dst = v
	}
}

// applyIDEvent folds one event into r (bin/fleet_id.py fold's rules: an
// `opened` field's first value wins; a native segment closes the one before).
func (s *Store) applyIDEvent(tx *sql.Tx, r *idRow, ev map[string]any, seq int, ts int64) error {
	switch evStr(ev, "ev", 20) {
	case "opened":
		fillStr(&r.Window, evStr(ev, "window", 32))
		fillStr(&r.Title, evStr(ev, "title", 200))
		fillStr(&r.Agent, evStr(ev, "agent", 20))
		fillStr(&r.Repo, evStr(ev, "repo", 201))
		fillStr(&r.Body, evStr(ev, "body", 4000))
		fillStr(&r.Key, evStr(ev, "key", 120))
		fillStr(&r.Task, evStr(ev, "task", 20))
		fillStr(&r.Parent, evStr(ev, "parent", 64))
		fillStr(&r.Prev, evStr(ev, "prev", 64))
		if r.OpenedAt == 0 {
			r.OpenedAt = ts
		}
		// §3.5: only the trusted sources — the dispatch's ticket / the old
		// record's issue (an issue-<N> key names one in its repo).
		r.Issues = addIssue(r.Issues, evStr(ev, "issue", 210))
		if _, ref, ok := strings.Cut(evStr(ev, "ticket_ref", 210), ":"); ok { // gh:<owner/name#N>
			r.Issues = addIssue(r.Issues, ref)
		}
		if m := idKeyRE.FindStringSubmatch(r.Key); m != nil && r.Repo != "" {
			r.Issues = addIssue(r.Issues, r.Repo+"#"+m[1])
		}
	case "native":
		if ev["compact"] == true {
			_, err := tx.Exec(`UPDATE fleet_id_natives SET compactions = compactions + 1 WHERE id = ? AND n = ?`, r.ID, r.natives)
			return err
		}
		if r.natives > 0 {
			if _, err := tx.Exec(`UPDATE fleet_id_natives SET end_at = ? WHERE id = ? AND n = ?`, ts, r.ID, r.natives); err != nil {
				return err
			}
		}
		r.natives++
		_, err := tx.Exec(`INSERT INTO fleet_id_natives (id, n, seq, agent, native, trig, source, from_ref, conflict, start_at)
			VALUES (?,?,?,?,?,?,?,?,?,?)`, r.ID, r.natives, seq, evStr(ev, "agent", 20), evStr(ev, "native", 128),
			evStr(ev, "trigger", 20), evStr(ev, "source", 20), evStr(ev, "from", 80), evStr(ev, "conflict", 64), ts)
		return err
	case "result":
		switch x := ev["issues"].(type) {
		case []any:
			for _, v := range x {
				if sv, ok := v.(string); ok {
					r.Issues = addIssue(r.Issues, sv)
				}
			}
		case string:
			for _, v := range strings.Split(x, ",") {
				r.Issues = addIssue(r.Issues, strings.TrimSpace(v))
			}
		}
		_, err := tx.Exec(`INSERT INTO fleet_id_results (id, seq, state, summary, pr, agent, at) VALUES (?,?,?,?,?,?,?)`,
			r.ID, seq, evStr(ev, "state", 20), evStr(ev, "summary", 2000), evStr(ev, "pr", 210), evStr(ev, "agent", 20), ts)
		return err
	case "closed":
		if r.ClosedAt == 0 {
			r.ClosedAt, r.CloseReason = ts, evStr(ev, "reason", 200)
			if r.natives > 0 {
				_, err := tx.Exec(`UPDATE fleet_id_natives SET end_at = ? WHERE id = ? AND n = ? AND end_at = 0`, ts, r.ID, r.natives)
				return err
			}
		}
	case "reopened":
		// 「恢复这个窗口」 (EPIC T497 C4): the same ID goes on in a new window.
		r.ClosedAt, r.CloseReason = 0, ""
		if w := evStr(ev, "window", 32); w != "" {
			r.Window = w
		}
	case "progress":
		// The newest progress word (C12): kept on the row, never a result.
		_, err := tx.Exec(`UPDATE fleet_ids SET progress = ?, progress_state = ?, progress_at = ?, progress_seq = ? WHERE id = ?`,
			evStr(ev, "summary", 2000), evStr(ev, "state", 20), ts, seq, r.ID)
		return err
	case "short":
		// The node writing down the code the hub gave it: only ever longer.
		if c := NormIDCode(evStr(ev, "short", 32)); len(c) > len(r.Short) && strings.HasPrefix(r.code, c) {
			r.Short = c
		}
	case "moved":
		r.EndpointID, r.Machine, r.Login = r.pushEP, r.pushMachine, r.pushLogin
	}
	return nil
}

// FleetIDOf reads one ID of an owner with its segments and results;
// sql.ErrNoRows when there is none.
func (s *Store) FleetIDOf(owner, id string) (FleetIDRecord, error) {
	var r idRow
	var pg FleetIDProgress
	err := s.read.QueryRow(`SELECT id, owner, code, short, endpoint_id, machine, login, win, title, agent, repo, issues,
		body, key, task, parent, prev, aliases, asked, parked, opened_at, closed_at, close_reason, seq,
		progress, progress_state, progress_at, progress_seq
		FROM fleet_ids WHERE id = ? AND owner = ?`, id, owner).Scan(&r.ID, &r.Owner, &r.code, &r.Short, &r.EndpointID,
		&r.Machine, &r.Login, &r.Window, &r.Title, &r.Agent, &r.Repo, &r.issues, &r.Body, &r.Key, &r.Task,
		&r.Parent, &r.Prev, &r.aliases, &r.Asked, &r.Parked, &r.OpenedAt, &r.ClosedAt, &r.CloseReason, &r.Seq,
		&pg.Summary, &pg.State, &pg.At, &pg.Seq)
	if err != nil {
		return FleetIDRecord{}, err
	}
	rec := r.FleetIDRecord
	if pg.Seq > 0 {
		rec.Progress = &pg
	}
	rec.Short = "T-" + r.Short
	_ = json.Unmarshal([]byte(r.issues), &rec.Issues)
	_ = json.Unmarshal([]byte(r.aliases), &rec.Aliases)
	rec.Issues, rec.Aliases = nonNil(rec.Issues), nonNil(rec.Aliases)
	rec.Natives, rec.Results = []FleetIDNative{}, []FleetIDResult{}
	rows, err := s.read.Query(`SELECT n, seq, agent, native, trig, source, from_ref, conflict, compactions, start_at, end_at
		FROM fleet_id_natives WHERE id = ? ORDER BY n`, id)
	if err != nil {
		return FleetIDRecord{}, err
	}
	for rows.Next() {
		var n FleetIDNative
		if err := rows.Scan(&n.N, &n.Seq, &n.Agent, &n.Native, &n.Trigger, &n.Source, &n.From, &n.Conflict,
			&n.Compactions, &n.Start, &n.End); err != nil {
			rows.Close()
			return FleetIDRecord{}, err
		}
		rec.Natives = append(rec.Natives, n)
	}
	rows.Close()
	rows, err = s.read.Query(`SELECT seq, state, summary, pr, agent, at FROM fleet_id_results WHERE id = ? ORDER BY seq`, id)
	if err != nil {
		return FleetIDRecord{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var x FleetIDResult
		if err := rows.Scan(&x.Seq, &x.State, &x.Summary, &x.PR, &x.Agent, &x.At); err != nil {
			return FleetIDRecord{}, err
		}
		rec.Results = append(rec.Results, x)
	}
	return rec, rows.Err()
}

// FleetIDShort is one owner's ID and its code, for a node's list of known IDs.
type FleetIDShort struct {
	ID    string `json:"id"`
	Short string `json:"short"`
}

// FleetIDsOf lists an owner's IDs; with prefix (a normalized code) only those
// whose code starts with it — the resolver's candidates.
func (s *Store) FleetIDsOf(owner, prefix string) ([]FleetIDShort, error) {
	q, args := `SELECT id, short FROM fleet_ids WHERE owner = ?`, []any{owner}
	if prefix != "" {
		q, args = q+` AND substr(code, 1, ?) = ?`, append(args, len(prefix), prefix)
	}
	rows, err := s.read.Query(q+` ORDER BY id`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetIDShort{}
	for rows.Next() {
		var x FleetIDShort
		if err := rows.Scan(&x.ID, &x.Short); err != nil {
			return nil, err
		}
		x.Short = "T-" + x.Short
		out = append(out, x)
	}
	return out, rows.Err()
}

// IDFamilyMax caps one family read: an EPIC batch's members and their redos.
const IDFamilyMax = 200

// FleetIDFamily reads the IDs an ID spawned (their `parent` is it), the seeds
// (IDs the caller knows are its members — a child task's worker), and every ID
// that continued one of them down the `prev` chain (a member's redo, a
// 「从这一段继续」 — EPIC T497 C5), oldest first, at most IDFamilyMax: an EPIC
// driver's whole batch in one read. Only the owner's IDs.
//
// The parent is its whole line (EPIC T497 C18): it and every ID that continued
// IT down `prev` (FleetIDLineage) — a driver's 「从这一段继续」 still owns what its
// predecessor spawned, and what the successor spawns is the same batch. The line
// itself is never in the answer.
func (s *Store) FleetIDFamily(owner, parent string, seeds []string) ([]FleetIDRecord, error) {
	line, err := s.FleetIDLineage(owner, parent)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for _, id := range line {
		seen[id] = true
	}
	var order []string
	var first []string
	for _, id := range seeds {
		if IsFleetID(id) && !seen[id] && len(order) < IDFamilyMax {
			var one int
			if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_ids WHERE owner = ? AND id = ?`, owner, id).Scan(&one); err != nil {
				return nil, err
			}
			if one > 0 {
				seen[id] = true
				order = append(order, id)
				first = append(first, id)
			}
		}
	}
	frontier, col := line, "parent"
	for len(frontier) > 0 && len(order) < IDFamilyMax {
		next := first
		first = nil
		for _, f := range frontier {
			rows, err := s.read.Query(`SELECT id FROM fleet_ids WHERE owner = ? AND `+col+` = ? ORDER BY opened_at, id`, owner, f)
			if err != nil {
				return nil, err
			}
			for rows.Next() {
				var id string
				if err := rows.Scan(&id); err != nil {
					rows.Close()
					return nil, err
				}
				if !seen[id] && len(order) < IDFamilyMax {
					seen[id] = true
					order = append(order, id)
					next = append(next, id)
				}
			}
			rows.Close()
		}
		frontier, col = next, "prev"
	}
	out := make([]FleetIDRecord, 0, len(order))
	for _, id := range order {
		rec, err := s.FleetIDOf(owner, id)
		if err != nil {
			return nil, err
		}
		out = append(out, rec)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].OpenedAt < out[j].OpenedAt })
	return out, nil
}

// FleetIDLineage is id and every ID of the owner's that continued it down `prev`,
// at any depth, oldest first (EPIC T497 C18) — at most IDFamilyMax.
func (s *Store) FleetIDLineage(owner, id string) ([]string, error) {
	line := []string{id}
	seen := map[string]bool{id: true}
	for i := 0; i < len(line) && len(line) < IDFamilyMax; i++ {
		rows, err := s.read.Query(`SELECT id FROM fleet_ids WHERE owner = ? AND prev = ? ORDER BY opened_at, id`, owner, line[i])
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var x string
			if err := rows.Scan(&x); err != nil {
				rows.Close()
				return nil, err
			}
			if !seen[x] && len(line) < IDFamilyMax {
				seen[x] = true
				line = append(line, x)
			}
		}
		rows.Close()
	}
	return line, nil
}
