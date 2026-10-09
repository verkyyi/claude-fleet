package api

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The client leases (claude-fleet#1715, EPIC #1710 C5; several at once since
// claude-fleet#1932, EPIC #1906 C13): one person, a few connected `fleet`
// clients — a MacBook, an iPhone, an iPad — none of which pushes another off.
//
// A client takes a lease of its own when it opens (action "acquire") and
// renews it every ClientLeaseRenew; ClientLeaseTTL without a renewal and it
// lapses. Each lease has its own action key. A person holds at most
// clientLeaseMax (4, FLEET_CLIENT_MAX) at once: an acquire past that asks the
// one used least recently to leave (a lapsed one first) — it reads taken_over
// with reason evicted on its next renewal, and its screen says why. That is
// the only way an acquire costs another client anything. Any of the person's
// clients may also disconnect another (action revoke, the sidebar's 我的客户端):
// that lease and its key are dropped at once, so an action signed with it is
// refused, and its client reads taken_over with reason revoked.
//
// Which one is "where the person is" (ClientLeaseOf — C6, #1716) is the
// PRIMARY: the client typed into or tapped most recently (last_input — a
// client reports it after an input, at most once per 5 s: action input, or a
// renewal carrying last_input). A client without input for clientLeaseIdle
// (10 min, FLEET_CLIENT_IDLE) is not primary while another is not idle; when
// every one is idle, the latest input still wins. Opening a client counts as
// input. Actions go to the primary (a notify may go to every client, all), and
// a get / GET /v1/node/client answers the primary as the lease — so a client
// or a node that knows only one lease reads exactly what it always has — with
// the whole list beside it (clients, primary). Besides the device and terminal
// a client says the device's system (OS), how it reached the machine its client
// runs on (Via: local, tailnet, lan or public), that machine (Host), what it
// can do for a session (Caps: open_url, show_file, notify, link, iterm2) and
// which session it is looking at (Viewing, a worker id — the top line's
// 「也在 iPhone 上打开」).
//
// A lease that lapsed (a MacBook asleep) is kept: its renewal on waking simply
// carries on, unless it was asked to leave meanwhile. The table lives in the
// hub's memory: a restart forgets every lease, and the next renewal of each
// live client re-adopts its own id while there is room, so a deploy costs
// nobody a standby screen. With two hub replicas the table is the state
// holder's alone; the other proxies every lease route to it
// (replica_state.go, claude-fleet#2190).
//
// A test identity (claude-fleet#1931, EPIC #1906 C12): a session's drill or
// test that runs a real client is never the person. It asks with `identity:
// test` (or at ClientTestPath, which a hub without test identities answers
// 404 — so a client never takes the person's lease from an older hub by
// mistake) and gets its own lease, in its own slot beside the person's: it
// counts toward nothing of the person's, it is never ClientLeaseOf (where the
// person is), it is handed no action and cannot place a session — it can only
// look. A request that says it comes from a session (the X-Fleet-Worker
// header: its worker assertion, or any word) may only be the test identity:
// asking for the person's lease is refused 403, with the reason.

const (
	// ClientLeaseRenew is how often a client renews.
	ClientLeaseRenew = 15 * time.Second
	// ClientLeaseTTL is how long a lease lives without a renewal.
	ClientLeaseTTL = 45 * time.Second
	// clientGoneKeep is how long a replaced lease is remembered, so a client
	// that slept through being asked to leave still reads it on waking; a
	// lapsed lease nobody renewed is dropped after as long.
	clientGoneKeep = 24 * time.Hour
	// clientLeaseMaxDefault is how many clients one person holds at once.
	clientLeaseMaxDefault = 4
	// clientLeaseIdleDefault: no input for this long and a client is not the
	// primary while another is in use.
	clientLeaseIdleDefault = 10 * time.Minute
	// ClientTestPath is the test identity's door: the lease at ClientPath, as
	// identity test.
	ClientTestPath = control.ClientPath + "/test"
	// clientTestSlot marks the test identity's slot in the lease table.
	clientTestSlot = "#test"
)

// ClientLease is one of a person's connected clients.
type ClientLease struct {
	ID       string   `json:"id"`
	Device   string   `json:"device"`
	Terminal string   `json:"terminal,omitempty"`
	OS       string   `json:"os,omitempty"`
	Via      string   `json:"via,omitempty"`
	Host     string   `json:"host,omitempty"`
	Caps     []string `json:"caps,omitempty"`
	Version  string   `json:"version,omitempty"`
	// Viewing is the session the client is looking at (a worker id), "" none.
	Viewing   string    `json:"viewing,omitempty"`
	Since     time.Time `json:"since"`
	Renewed   time.Time `json:"renewed"`
	Expires   time.Time `json:"expires"`
	LastInput time.Time `json:"last_input"`
	// Primary marks the primary in a list (set on the copies handed out).
	Primary bool `json:"primary,omitempty"`
}

// clientGone is a lease that is no longer held.
type clientGone struct {
	key string
	by  ClientLease // the lease that replaced it (evicted), or the primary then
	at  time.Time
	// reason: evicted (a client past the limit asked it to leave) or revoked
	// (the person disconnected it)
	reason string
}

// clientLeaseTable holds every person's leases, keyed by clientLeaseKey, then
// by lease id.
type clientLeaseTable struct {
	mu   sync.Mutex
	cur  map[string]map[string]*ClientLease
	gone map[string]clientGone
	// keys: each lease's action key (C7, #1717); acts: the actions waiting
	// for, or answered by, a lease's client — fleet_client_actions.go
	keys map[string]string
	acts clientActionQueue
	// max / idle: 0 = the default (or FLEET_CLIENT_MAX / FLEET_CLIENT_IDLE)
	max  int
	idle time.Duration
}

// ClientLeaseRequest is the body of a POST to control.ClientPath. Cert, Sig
// and TS prove a connection certificate (ssh-keygen -Y sign -n
// fleet-client@claude-fleet over control.ClientSigMessage(TS)); a viewer door
// leaves them out.
type ClientLeaseRequest struct {
	Cert string `json:"cert,omitempty"`
	Sig  string `json:"sig,omitempty"`
	TS   int64  `json:"ts,omitempty"`
	// Action is acquire, renew, input, release, list, revoke or get (the
	// default).
	Action string `json:"action"`
	// Lease is the client's own lease id: required to renew, input or
	// release; on an acquire, the id the client held before (its server's),
	// so the same client opening again keeps its lease.
	Lease    string   `json:"lease,omitempty"`
	Device   string   `json:"device,omitempty"`
	Terminal string   `json:"terminal,omitempty"`
	OS       string   `json:"os,omitempty"`
	Via      string   `json:"via,omitempty"`
	Host     string   `json:"host,omitempty"`
	Caps     []string `json:"caps,omitempty"`
	Version  string   `json:"version,omitempty"`
	// Viewing is the session the client looks at now (renew / input).
	Viewing string `json:"viewing,omitempty"`
	// LastInput is when the client was last typed into or tapped (unix
	// seconds; renew). An input action without it means now.
	LastInput int64 `json:"last_input,omitempty"`
	// Target is the lease a revoke disconnects.
	Target string `json:"target,omitempty"`
	// Identity is "" / person (the person themself) or test (#1931).
	Identity string `json:"identity,omitempty"`
}

// ClientLeaseResponse is the answer.
type ClientLeaseResponse struct {
	// State is active (the lease is yours — on a get: someone is connected),
	// taken_over (yours is no longer held: Reason says why, By who is primary
	// now), released, revoked (a revoke went through), or none.
	State string `json:"state"`
	// Lease is yours when active; the primary on a get.
	Lease *ClientLease `json:"lease,omitempty"`
	// By is the client that asked yours to leave, or the primary (taken_over).
	By *ClientLease `json:"by,omitempty"`
	// Reason is why a lease is no longer held: evicted or revoked.
	Reason string `json:"reason,omitempty"`
	// Evicted is the client an acquire past the limit asked to leave.
	Evicted *ClientLease `json:"evicted,omitempty"`
	// TookOver is kept for older readers; a hub with several clients never
	// takes one over.
	TookOver *ClientLease `json:"took_over,omitempty"`
	// Clients is every live client of the person, the primary marked; Primary
	// its id.
	Clients []ClientLease `json:"clients,omitempty"`
	Primary string        `json:"primary,omitempty"`
	// ActionKey signs every action sent to this lease (C7, #1717): handed
	// to the lease's own client on acquire / renew, never on a read.
	ActionKey string `json:"action_key,omitempty"`
	RenewSecs int    `json:"renew_secs"`
	TTLSecs   int    `json:"ttl_secs"`
	// Identity echoes a test identity's lease ("test"); absent for the person.
	Identity string `json:"identity,omitempty"`
}

func newClientLeaseID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// cleanClientField keeps a client's self-reported word short and printable:
// it is shown on another client's screen.
func cleanClientField(s string, max int) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(s) {
		if r < 0x20 || r == 0x7f {
			continue
		}
		b.WriteRune(r)
		if b.Len() >= max {
			break
		}
	}
	return b.String()
}

// envClientMax / envClientIdle read FLEET_CLIENT_MAX (a count) and
// FLEET_CLIENT_IDLE (seconds, or a Go duration).
func envClientMax() int {
	if n, err := strconv.Atoi(strings.TrimSpace(os.Getenv("FLEET_CLIENT_MAX"))); err == nil && n > 0 {
		return n
	}
	return clientLeaseMaxDefault
}

func envClientIdle() time.Duration {
	v := strings.TrimSpace(os.Getenv("FLEET_CLIENT_IDLE"))
	if n, err := strconv.Atoi(v); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	if d, err := time.ParseDuration(v); err == nil && d > 0 {
		return d
	}
	return clientLeaseIdleDefault
}

func (t *clientLeaseTable) init() {
	if t.cur == nil {
		t.cur = map[string]map[string]*ClientLease{}
		t.gone = map[string]clientGone{}
		t.keys = map[string]string{}
	}
	if t.max <= 0 {
		t.max = envClientMax()
	}
	if t.idle <= 0 {
		t.idle = envClientIdle()
	}
}

func (t *clientLeaseTable) prune(now time.Time) {
	for id, g := range t.gone {
		if now.Sub(g.at) > clientGoneKeep {
			delete(t.gone, id)
			t.forgetLeaseLocked(id)
		}
	}
	for key, set := range t.cur {
		for id, l := range set {
			if now.Sub(l.Expires) > clientGoneKeep {
				delete(set, id)
				t.forgetLeaseLocked(id)
			}
		}
		if len(set) == 0 {
			delete(t.cur, key)
		}
	}
}

func (t *clientLeaseTable) fill(l *ClientLease, req ClientLeaseRequest) {
	if d := cleanClientField(req.Device, 64); d != "" {
		l.Device = d
	}
	if l.Device == "" {
		l.Device = "未知设备"
	}
	if v := cleanClientField(req.Terminal, 64); v != "" {
		l.Terminal = v
	}
	if v := cleanClientField(req.OS, 32); v != "" {
		l.OS = v
	}
	if v := cleanClientField(req.Via, 16); clientVias[v] {
		l.Via = v
	}
	if v := cleanClientField(req.Host, 64); v != "" {
		l.Host = v
	}
	if req.Caps != nil {
		var caps []string
		for _, c := range req.Caps {
			if c = cleanClientField(c, 16); clientCaps[c] && len(caps) < len(clientCaps) {
				caps = append(caps, c)
			}
		}
		l.Caps = caps
	}
	if v := cleanClientField(req.Version, 64); v != "" {
		l.Version = v
	}
}

// clientVias and clientCaps are the words a client may report (C6, #1716;
// node-hosted: the client on a managed machine, #2720).
var (
	clientVias = map[string]bool{"local": true, "tailnet": true, "lan": true, "public": true, "node-hosted": true}
	clientCaps = map[string]bool{"open_url": true, "show_file": true, "notify": true, "link": true, "iterm2": true}
)

func (t *clientLeaseTable) live(l *ClientLease, now time.Time) bool {
	return l != nil && now.Before(l.Expires)
}

func leaseCopy(l *ClientLease) *ClientLease {
	if l == nil {
		return nil
	}
	c := *l
	c.Caps = append([]string(nil), l.Caps...)
	return &c
}

// lastUse is when a client was last used: its last input, else its opening.
func lastUse(l *ClientLease) time.Time {
	if l.LastInput.After(l.Since) {
		return l.LastInput
	}
	return l.Since
}

// liveLocked is key's live leases, the most recently used first.
func (t *clientLeaseTable) liveLocked(key string, now time.Time) []*ClientLease {
	var out []*ClientLease
	for _, l := range t.cur[key] {
		if t.live(l, now) {
			out = append(out, l)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := lastUse(out[i]), lastUse(out[j])
		if !a.Equal(b) {
			return a.After(b)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// primaryLocked is the client the person is using: the latest input among
// the ones not idle, else the latest input of all; nil when none is live.
func (t *clientLeaseTable) primaryLocked(key string, now time.Time) *ClientLease {
	ls := t.liveLocked(key, now)
	for _, l := range ls {
		if now.Sub(lastUse(l)) <= t.idle {
			return l
		}
	}
	if len(ls) > 0 {
		return ls[0]
	}
	return nil
}

// listLocked fills r's Clients and Primary.
func (t *clientLeaseTable) listLocked(key string, r *ClientLeaseResponse, now time.Time) {
	p := t.primaryLocked(key, now)
	r.Clients = nil
	for _, l := range t.liveLocked(key, now) {
		c := leaseCopy(l)
		c.Primary = p != nil && l.ID == p.ID
		r.Clients = append(r.Clients, *c)
	}
	r.Primary = ""
	if p != nil {
		r.Primary = p.ID
	}
}

// dropLocked takes a lease out of key's set, remembered as gone for reason.
func (t *clientLeaseTable) dropLocked(key string, l *ClientLease, by ClientLease, reason string, now time.Time) {
	delete(t.cur[key], l.ID)
	t.gone[l.ID] = clientGone{key: key, by: by, at: now, reason: reason}
	t.forgetLeaseLocked(l.ID)
}

// roomLocked makes room for one more of key's leases: a lapsed one goes
// first (quietly), then the one used least recently (asked to leave, for
// by). It answers the live client it asked to leave, if any.
func (t *clientLeaseTable) roomLocked(key string, by ClientLease, now time.Time) *ClientLease {
	set := t.cur[key]
	for len(set) >= t.max {
		var lapsed, lru *ClientLease
		for _, l := range set {
			if !t.live(l, now) {
				if lapsed == nil || l.Expires.Before(lapsed.Expires) {
					lapsed = l
				}
			} else if lru == nil || lastUse(l).Before(lastUse(lru)) {
				lru = l
			}
		}
		if lapsed != nil {
			t.dropLocked(key, lapsed, by, "evicted", now)
			continue
		}
		t.dropLocked(key, lru, by, "evicted", now)
		return leaseCopy(lru)
	}
	return nil
}

func (t *clientLeaseTable) setLocked(key string) map[string]*ClientLease {
	if t.cur[key] == nil {
		t.cur[key] = map[string]*ClientLease{}
	}
	return t.cur[key]
}

// acquire adds the caller's client to the person's set (or refreshes its own).
func (t *clientLeaseTable) acquire(key string, req ClientLeaseRequest, now time.Time) ClientLeaseResponse {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	t.prune(now)
	set := t.setLocked(key)
	if c := set[req.Lease]; c != nil && req.Lease != "" {
		// The same client opening again (another window on the same server):
		// its lease, refreshed — opening it is a use.
		t.fill(c, req)
		c.Renewed, c.Expires, c.LastInput = now, now.Add(ClientLeaseTTL), now
		out := ClientLeaseResponse{State: "active", Lease: leaseCopy(c)}
		t.listLocked(key, &out, now)
		return out
	}
	n := &ClientLease{ID: newClientLeaseID(), Since: now, Renewed: now, Expires: now.Add(ClientLeaseTTL), LastInput: now}
	t.fill(n, req)
	out := ClientLeaseResponse{State: "active"}
	out.Evicted = t.roomLocked(key, *n, now)
	if req.Lease != "" {
		delete(t.gone, req.Lease) // a client asked to leave, coming back
	}
	set[n.ID] = n
	out.Lease = leaseCopy(n)
	t.listLocked(key, &out, now)
	return out
}

// renew extends the caller's lease (input: and marks it used now), or says
// why it is no longer held.
func (t *clientLeaseTable) renew(key string, req ClientLeaseRequest, now time.Time, input bool) ClientLeaseResponse {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	t.prune(now)
	set := t.setLocked(key)
	c := set[req.Lease]
	if c == nil {
		if g, ok := t.gone[req.Lease]; ok && g.key == key {
			by := g.by
			if p := t.primaryLocked(key, now); p != nil && g.reason != "evicted" {
				by = *p
			}
			out := ClientLeaseResponse{State: "taken_over", By: &by, Reason: g.reason}
			return out
		}
		// An id the hub does not know: the hub restarted under a live client.
		// It is one of the person's again, same id — while there is room.
		if len(t.liveLocked(key, now)) >= t.max {
			var by ClientLease
			if p := t.primaryLocked(key, now); p != nil {
				by = *p
			}
			return ClientLeaseResponse{State: "taken_over", By: &by, Reason: "evicted"}
		}
		c = &ClientLease{ID: req.Lease, Since: now}
		t.roomLocked(key, *c, now) // only lapsed ones can go here
		set[c.ID] = c
	}
	// Its own lease, even one that lapsed: a client back from a short sleep
	// simply carries on.
	t.fill(c, req)
	c.Viewing = cleanClientField(req.Viewing, 128)
	c.Renewed, c.Expires = now, now.Add(ClientLeaseTTL)
	if req.LastInput > 0 {
		if at := time.Unix(req.LastInput, 0); at.After(c.LastInput) {
			if at.After(now) {
				at = now
			}
			c.LastInput = at
		}
	} else if input {
		c.LastInput = now
	}
	out := ClientLeaseResponse{State: "active", Lease: leaseCopy(c)}
	t.listLocked(key, &out, now)
	return out
}

// release gives the caller's lease up (the client's server ended).
func (t *clientLeaseTable) release(key, lease string) ClientLeaseResponse {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	delete(t.cur[key], lease)
	delete(t.gone, lease)
	t.forgetLeaseLocked(lease)
	return ClientLeaseResponse{State: "released"}
}

// revoke disconnects one of key's clients: its lease and action key dropped
// at once. false = no such client of this person.
func (t *clientLeaseTable) revoke(key, target string, now time.Time) (ClientLeaseResponse, *ClientLease, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	c := t.cur[key][target]
	if c == nil || target == "" {
		return ClientLeaseResponse{}, nil, false
	}
	gone := leaseCopy(c)
	var by ClientLease
	t.dropLocked(key, c, by, "revoked", now)
	out := ClientLeaseResponse{State: "revoked"}
	t.listLocked(key, &out, now)
	return out, gone, true
}

// get is the primary, if any client is live, with the whole list.
func (t *clientLeaseTable) get(key string, now time.Time) ClientLeaseResponse {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	out := ClientLeaseResponse{State: "none"}
	if p := t.primaryLocked(key, now); p != nil {
		out.State, out.Lease = "active", leaseCopy(p)
		out.Lease.Primary = true
		t.listLocked(key, &out, now)
	}
	return out
}

// holds says whether lease is one of key's current leases (live or not).
func (t *clientLeaseTable) holdsLocked(key, lease string) *ClientLease {
	if lease == "" {
		return nil
	}
	return t.cur[key][lease]
}

// clientLeaseKey is whose lease it is: the principal, or the operator door.
func clientLeaseKey(id sshRelayIdentity) string {
	if id.Operator || id.Principal == "" {
		return "operator"
	}
	return "p:" + id.Principal
}

// slotOf is the slot a lease id lives in: the test identity's when that slot
// holds (or held) it, else the person's key itself.
func (t *clientLeaseTable) slotOf(key, lease string) string {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	tk := key + clientTestSlot
	if t.holdsLocked(tk, lease) != nil {
		return tk
	}
	if g, ok := t.gone[lease]; ok && g.key == tk {
		return tk
	}
	return key
}

// ClientLeaseOf is the client a person is using right now — the primary — if
// any (principal "" = the operator).
func (s *Server) ClientLeaseOf(principal string, now time.Time) (ClientLease, bool) {
	key := clientLeaseKey(sshRelayIdentity{Operator: principal == "", Principal: principal})
	r := s.clientLeasesGet(key, now)
	if r.Lease == nil {
		return ClientLease{}, false
	}
	return *r.Lease, true
}

// ClientLeasesOf is every live client of a person (the primary marked) and
// the primary's id.
func (s *Server) ClientLeasesOf(principal string, now time.Time) ([]ClientLease, string) {
	key := clientLeaseKey(sshRelayIdentity{Operator: principal == "", Principal: principal})
	r := s.clientLeasesGet(key, now)
	return r.Clients, r.Primary
}

// handleFleetClient serves control.ClientPath outside the viewer gate: a
// connection certificate proven by a signed timestamp (POST), or the
// operator's doors / a GitHub session (GET reads the current lease; POST acts).
func (s *Server) handleFleetClient(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	var req ClientLeaseRequest
	if r.Method == http.MethodPost {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "the body must be one JSON object")
			return
		}
	}
	now := time.Now()
	id, ok := s.clientIdentity(w, r, req.Cert, req.Sig, req.TS, now)
	if !ok {
		return
	}
	key := clientLeaseKey(id)
	ident := strings.TrimSpace(req.Identity)
	if r.URL.Path == ClientTestPath {
		if ident != "" && ident != "test" {
			httpError(w, http.StatusBadRequest, "this door is the test identity's: identity must be test")
			return
		}
		ident = "test"
	}
	switch ident {
	case "", "person":
		if strings.TrimSpace(r.Header.Get(workerAssertHeader)) != "" {
			// A session's test or drill (#1931): never the person's lease.
			httpError(w, http.StatusForbidden, "a session may not take the person's client lease — "+
				"a session's test or drill runs as the test identity (fleet --test-identity / "+
				"FLEET_CLIENT_IDENTITY=test), which leaves the person's client and where untouched")
			return
		}
		ident = ""
	case "test":
		key += clientTestSlot
	default:
		httpError(w, http.StatusBadRequest, "identity must be person or test")
		return
	}
	if ident == "test" {
		req.Caps = []string{} // it only looks: nothing to ask of it
	}
	var out ClientLeaseResponse
	switch req.Action {
	case "", "get":
		out = s.clientLeases.get(key, now)
	case "list":
		out = s.clientLeases.get(key, now)
		out.Lease = nil
	case "acquire":
		out = s.clientLeases.acquire(key, req, now)
		outcome, what := "OK", "client_acquire"
		if out.Evicted != nil {
			// past the limit: the one used least recently was asked to leave
			outcome = "EVICT " + out.Evicted.Device
		}
		if ident == "test" {
			what = "client_acquire_test"
		}
		if s.Store != nil {
			if err := s.Store.FleetAudit(id.Actor, what, out.Lease.Device, outcome, out.Lease.ID, now); err != nil {
				log.Printf("fleet audit: %v", err)
			}
		}
	case "renew", "input":
		if req.Lease == "" {
			httpError(w, http.StatusBadRequest, req.Action+" needs the lease id")
			return
		}
		out = s.clientLeases.renew(key, req, now, req.Action == "input")
	case "release":
		if req.Lease == "" {
			httpError(w, http.StatusBadRequest, "release needs the lease id")
			return
		}
		out = s.clientLeases.release(key, req.Lease)
	case "revoke":
		// disconnect one of the person's clients (the sidebar's 我的客户端):
		// its lease and action key go at once
		var gone *ClientLease
		var ok bool
		if out, gone, ok = s.clientLeases.revoke(key, strings.TrimSpace(req.Target), now); !ok {
			httpError(w, http.StatusNotFound, "no such client of yours (it may have gone already)")
			return
		}
		if s.Store != nil {
			if err := s.Store.FleetAudit(id.Actor, "client_revoke", gone.Device, "OK", gone.ID, now); err != nil {
				log.Printf("fleet audit: %v", err)
			}
		}
	default:
		httpError(w, http.StatusBadRequest, "action must be acquire, renew, input, release, list, revoke or get")
		return
	}
	if out.State == "active" && out.Lease != nil && (req.Action == "acquire" || req.Action == "renew" || req.Action == "input") {
		// The key the lease's actions are signed with (C7, #1717): the
		// client that holds the lease, and only it, is told — on every
		// acquire and renewal, so a hub restart's fresh key reaches it.
		out.ActionKey = s.clientLeases.actionKey(out.Lease.ID)
	}
	out.RenewSecs, out.TTLSecs = int(ClientLeaseRenew/time.Second), int(ClientLeaseTTL/time.Second)
	out.Identity = ident
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// clientIdentity is who is asking at a client door: a session / viewer token,
// else a connection certificate proven by a signed timestamp. It answers the
// refusal itself.
func (s *Server) clientIdentity(w http.ResponseWriter, r *http.Request, cert, sig string, ts int64, now time.Time) (sshRelayIdentity, bool) {
	if id, ok := s.sshRelayHTTPIdentity(r); ok {
		return id, true
	}
	if cert == "" || sig == "" {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "a session, a viewer token or a connection certificate is required")
		return sshRelayIdentity{}, false
	}
	if d := now.Sub(time.Unix(ts, 0)); d > routesClockSkew || d < -routesClockSkew {
		httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
		return sshRelayIdentity{}, false
	}
	id, err := s.verifySSHRelayCert(cert, sig, control.ClientSigMessage(ts), control.ClientSigNamespace, now)
	if err != nil {
		var re *sshRelayError
		if errors.As(err, &re) {
			httpError(w, http.StatusUnauthorized, re.msg)
			return sshRelayIdentity{}, false
		}
		httpError(w, http.StatusInternalServerError, err.Error())
		return sshRelayIdentity{}, false
	}
	return id, true
}

// handleNodeClient serves GET /v1/node/client (C6, #1716): the client the
// node's OWNER is connected through right now — the person whose active fleet
// account is this node's login (PrincipalForLogin; an unowned login is the
// operator's) — so a session running on any machine can say which device and
// terminal that person is using. Authenticated by the node's enrollment token;
// state none when nobody holds a lease.
func (s *Server) handleNodeClient(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	host, user := s.peerSelf(ep)
	owner, err := s.Store.PrincipalForLogin(host, user)
	if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	now := time.Now()
	out := ClientLeaseResponse{State: "none"}
	if l, ok := s.ClientLeaseOf(owner, now); ok {
		// the primary as the lease (what a reader of one lease always read),
		// every client beside it (#1932)
		out = ClientLeaseResponse{State: "active", Lease: &l}
		out.Clients, out.Primary = s.ClientLeasesOf(owner, now)
	}
	out.RenewSecs, out.TTLSecs = int(ClientLeaseRenew/time.Second), int(ClientLeaseTTL/time.Second)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}
