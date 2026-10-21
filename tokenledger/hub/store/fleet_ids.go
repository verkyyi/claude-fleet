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
// The short code (EPIC T497 C11: the leading characters of the ID's display code —
// uppercase Crockford base32, the first always a letter, 4 by default) is unique
// within an owner: on registration the hub lengthens the LATER ID's code until
// no other ID of that owner shares it (bin/fleet_id.py short_for, the node's
// guess) and answers the node, which moves @task_short. Codes only ever grow.
// `code` / `short` hold today's form (bare, no `T-`); a row an older hub wrote
// (lowercase, the ID's plain base32) is recomputed once at start
// (backfillFleetIDCodes). The old `T-…` code still resolves for one version
// (FleetIDLegacyCode, computed — never stored; compat-1v: 下一批删).
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
const IDShortMin = 4

// IDPushMax bounds the events of one push.
const IDPushMax = 200

// ErrIDDuplicate: the full ID is already another node's (or another owner's).
var ErrIDDuplicate = errors.New("this ID is already registered by another machine")

var (
	idUUIDRE  = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	idIssueRE = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}#[1-9][0-9]{0,9}$`)
	idKeyRE   = regexp.MustCompile(`^(?:[A-Za-z0-9_.-]{1,100}:)?issue-([1-9][0-9]{0,9})$`)
)

const (
	idAlphabet = "0123456789abcdefghjkmnpqrstvwxyz" // the OLD code: Crockford base32, lowercase (compat-1v)
	idDigits   = "0123456789ABCDEFGHJKMNPQRSTVWXYZ" // the display code: Crockford base32, uppercase
	idLetters  = "ABCDEFGHJKMNPQRSTVWXYZ"           // its first character: a letter, never a digit
)

// idCodeSpan is 22 × 32^25: the display code's 26 places (one letter, 25 base32),
// more than 2^128, so no two IDs share a full code.
var idCodeSpan = new(big.Int).Mul(big.NewInt(22), new(big.Int).Exp(big.NewInt(32), big.NewInt(25), nil))

// IsFleetID reports whether s is an ID (a lowercase UUID, as fleet_fid_mint writes).
func IsFleetID(s string) bool { return idUUIDRE.MatchString(s) }

func idBits(id string) *big.Int {
	b, err := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	if err != nil || len(b) != 16 {
		return nil
	}
	return new(big.Int).SetBytes(b)
}

// FleetIDCode is the ID's full display code (EPIC T497 C11): the 128 bits scaled
// onto one letter place (22) and 25 base32 places, most significant first — so the
// first character is always a letter and a prefix is the ID's own (bin/fleet_id.py
// encode, byte for byte).
func FleetIDCode(id string) string {
	n := idBits(id)
	if n == nil {
		return ""
	}
	v := new(big.Int).Rsh(n.Mul(n, idCodeSpan), 128)
	out := make([]byte, 26)
	d := new(big.Int)
	for i := 25; i > 0; i-- {
		v.DivMod(v, big.NewInt(32), d)
		out[i] = idDigits[d.Int64()]
	}
	out[0] = idLetters[v.Int64()]
	return string(out)
}

// FleetIDLegacyCode is the OLD full code — 128 bits → 26 lowercase base32, most
// significant first (bin/fleet_id.py legacy_encode): what a `T-…` address names
// for one version (compat-1v: 下一批删).
func FleetIDLegacyCode(id string) string {
	n := idBits(id)
	if n == nil {
		return ""
	}
	n.Lsh(n, 2) // 130 bits = 26 × 5
	out := make([]byte, 26)
	m := big.NewInt(31)
	for i := 0; i < 26; i++ {
		d := new(big.Int).Rsh(n, uint(5*(25-i)))
		out[i] = idAlphabet[d.And(d, m).Int64()]
	}
	return string(out)
}

// NormIDCode is a typed code (`K3F9`, `#k3f9`, any case; I/L read 1, O read 0; the
// first character a letter) in its canonical uppercase form, or "" — an old `T-…`
// code is "" here (LegacyIDCode). bin/fleet_id.py norm_code.
func NormIDCode(s string) string {
	s = strings.TrimPrefix(strings.TrimSpace(s), "#")
	if strings.HasPrefix(s, "T-") || strings.HasPrefix(s, "t-") {
		return ""
	}
	s = strings.NewReplacer("I", "1", "L", "1", "O", "0").Replace(strings.ToUpper(s))
	if len(s) < 4 || len(s) > 26 || !strings.ContainsRune(idLetters, rune(s[0])) {
		return ""
	}
	for _, c := range s {
		if !strings.ContainsRune(idDigits, c) {
			return ""
		}
	}
	return s
}

// LegacyIDCode is an old `T-…` address in its canonical lowercase form, or ""
// (compat-1v: 下一批删).
func LegacyIDCode(s string) string {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, "T-") && !strings.HasPrefix(s, "t-") {
		return ""
	}
	s = strings.NewReplacer("i", "1", "l", "1", "o", "0").Replace(strings.ToLower(s[2:]))
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
		{"progress_seq", "INTEGER NOT NULL DEFAULT 0"},
		// EPIC T644 C1: the task this ID belongs to, by the task's own ID
		// (fleet_tasks.fid) — `task` keeps the T<n> for one version (compat-1v: 下一批删).
		{"task_id", "TEXT NOT NULL DEFAULT ''"}} {
		if err := s.addColumn("fleet_ids", c.col, c.spec); err != nil {
			return err
		}
	}
	return s.backfillFleetIDCodes()
}

// backfillFleetIDCodes moves every row an older hub wrote (its `code` the ID's
// lowercase base32 — the first character not an uppercase letter) onto today's
// display code (EPIC T497 C11): code recomputed from the ID, short the shortest
// prefix no already-moved ID of that owner shares, oldest first. Idempotent: a
// moved row is never read again. The ID itself is never touched.
func (s *Store) backfillFleetIDCodes() error {
	rows, err := s.write.Query(`SELECT id, owner FROM fleet_ids WHERE substr(code, 1, 1) NOT IN ('` + strings.Join(strings.Split(idLetters, ""), "','") + `')
		ORDER BY owner, opened_at, id`)
	if err != nil {
		return err
	}
	type pend struct{ id, owner string }
	var todo []pend
	for rows.Next() {
		var p pend
		if err := rows.Scan(&p.id, &p.owner); err != nil {
			rows.Close()
			return err
		}
		todo = append(todo, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, p := range todo {
		code := FleetIDCode(p.id)
		if code == "" {
			continue // not an ID (a hand-written row): nothing to compute, left as it is
		}
		tx, err := s.write.Begin()
		if err != nil {
			return err
		}
		short, err := shortFor(tx, p.owner, p.id, code, IDShortMin)
		if err == nil {
			_, err = tx.Exec(`UPDATE fleet_ids SET code = ?, short = ? WHERE id = ?`, code, short, p.id)
		}
		if err != nil {
			tx.Rollback()
			return fmt.Errorf("fleet_ids code backfill %s: %w", p.id, err)
		}
		if err := tx.Commit(); err != nil {
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
	taskID                         string
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
		body, key, task, parent, prev, aliases, asked, parked, opened_at, closed_at, close_reason, seq, natives, task_id
		FROM fleet_ids WHERE id = ?`+s.d.forUpdate(), p.ID).Scan(&r.Owner, &r.code, &r.Short, &r.EndpointID,
		&r.Machine, &r.Login, &r.Window, &r.Title, &r.Agent, &r.Repo, &r.issues, &r.Body, &r.Key, &r.Task,
		&r.Parent, &r.Prev, &r.aliases, &r.Asked, &r.Parked, &r.OpenedAt, &r.ClosedAt, &r.CloseReason, &r.Seq, &r.natives, &r.taskID)
	exists := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return FleetIDPushed{}, err
	}
	if exists {
		if r.Owner != p.Owner {
			return FleetIDPushed{}, ErrIDDuplicate
		}
		if r.EndpointID == "" && r.Seq == 0 {
			// A task's ID the hub minted with its record (EPIC T644 C1): no
			// machine holds it yet, so the owner's first machine to push it
			// takes it — the window opened for the task.
			r.EndpointID, r.Machine, r.Login = p.EndpointID, p.Machine, p.Login
			if strings.HasPrefix(r.CloseReason, IDHubClose) {
				r.ClosedAt, r.CloseReason = 0, "" // a reconcile closed it unclaimed (BCYB): taken after all
			}
		} else if r.EndpointID != p.EndpointID {
			moved := false
			for _, ev := range evs {
				if int(evInt(ev, "seq")) == r.Seq+1 {
					moved = evStr(ev, "ev", 20) == "moved"
					break
				}
			}
			if !moved {
				return FleetIDPushed{Seq: r.Seq, Short: r.Short, Machine: r.Machine}, ErrIDDuplicate
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
		if r.taskID == "" && r.Task != "" {
			// the T<n> it carries, read as that task's ID (C1); none ⇒ left empty
			if n := ParseTaskRef(r.Task); n > 0 {
				_ = tx.QueryRow(`SELECT fid FROM fleet_tasks WHERE id = ? AND owner = ?`, n, r.Owner).Scan(&r.taskID)
			}
		}
		iss, _ := json.Marshal(nonNil(r.Issues))
		als, _ := json.Marshal(nonNil(r.Aliases))
		if _, err := tx.Exec(`UPDATE fleet_ids SET short = ?, endpoint_id = ?, machine = ?, login = ?, win = ?,
			title = ?, agent = ?, repo = ?, issues = ?, body = ?, key = ?, task = ?, parent = ?, prev = ?, aliases = ?,
			opened_at = ?, closed_at = ?, close_reason = ?, seq = ?, natives = ?, task_id = ?, updated_at = ? WHERE id = ?`,
			r.Short, r.EndpointID, r.Machine, r.Login, r.Window, r.Title, r.Agent, r.Repo, string(iss), r.Body,
			r.Key, r.Task, r.Parent, r.Prev, string(als), r.OpenedAt, r.ClosedAt, r.CloseReason, r.Seq, r.natives,
			r.taskID, time.Now().UTC().Format(rfc), r.ID); err != nil {
			return FleetIDPushed{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return FleetIDPushed{}, err
	}
	return FleetIDPushed{Seq: r.Seq, Short: r.Short, Machine: r.Machine}, nil
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
		st, pr := evStr(ev, "state", 20), evStr(ev, "pr", 210)
		if _, err := tx.Exec(`INSERT INTO fleet_id_results (id, seq, state, summary, pr, agent, at) VALUES (?,?,?,?,?,?,?)`,
			r.ID, seq, st, evStr(ev, "summary", 2000), pr, evStr(ev, "agent", 20), ts); err != nil {
			return err
		}
		// EPIC T644 C6: the record it carries ends in the same transaction.
		_, err := writeTaskResult(tx, r.Owner, r.ID, r.taskID, taskRefsOf(r.Task, r.Aliases), st, pr, seq, time.Now())
		return err
	case "closed":
		// the node's own word wins over a reconcile's (BCYB: hub:gone …)
		if r.ClosedAt == 0 || strings.HasPrefix(r.CloseReason, IDHubClose) {
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
	rec.Short = r.Short
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
// whose code starts with it — the resolver's candidates. An old `T-…` prefix
// (LegacyIDCode) is matched against each ID's old code, computed (compat-1v).
func (s *Store) FleetIDsOf(owner, prefix string) ([]FleetIDShort, error) {
	if lp := LegacyIDCode(prefix); lp != "" {
		all, err := s.FleetIDsOf(owner, "")
		if err != nil {
			return nil, err
		}
		out := []FleetIDShort{}
		for _, x := range all {
			if strings.HasPrefix(FleetIDLegacyCode(x.ID), lp) {
				out = append(out, x)
			}
		}
		return out, nil
	}
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

// IDSyncMax caps one page of a node's cache sync (FleetIDsSince).
const IDSyncMax = 500

// FleetIDsSince is one page of an owner's IDs changed after `since` (an
// updated_at the previous page answered; "" = from the start), oldest change
// first, at most limit — the node's ID cache (EPIC T644 C7: every machine's
// panel reads the same records, whichever machine is its home). The cursor is
// the last record's updated_at; more says another page follows.
func (s *Store) FleetIDsSince(owner, since string, limit int) (recs []FleetIDRecord, cursor string, more bool, err error) {
	if limit <= 0 || limit > IDSyncMax {
		limit = IDSyncMax
	}
	rows, err := s.read.Query(`SELECT id, updated_at FROM fleet_ids WHERE owner = ? AND updated_at > ?
		ORDER BY updated_at, id LIMIT ?`, owner, since, limit+1)
	if err != nil {
		return nil, "", false, err
	}
	type idAt struct{ id, at string }
	var got []idAt
	for rows.Next() {
		var x idAt
		if err := rows.Scan(&x.id, &x.at); err != nil {
			rows.Close()
			return nil, "", false, err
		}
		got = append(got, x)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, "", false, err
	}
	if len(got) > limit {
		// never cut a page between two records of one instant: the next page
		// starts strictly after the cursor
		more = true
		next := got[limit].at
		got = got[:limit]
		for len(got) > 1 && got[len(got)-1].at == next {
			got = got[:len(got)-1]
		}
	}
	recs = make([]FleetIDRecord, 0, len(got))
	for _, x := range got {
		rec, err := s.FleetIDOf(owner, x.id)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, "", false, err
		}
		recs = append(recs, rec)
		cursor = x.at
	}
	if cursor == "" {
		cursor = since
	}
	return recs, cursor, more, nil
}
