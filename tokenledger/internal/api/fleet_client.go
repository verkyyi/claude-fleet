package api

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The client lease (claude-fleet#1715, EPIC #1710 C5): one person, one
// connected `fleet` client at a time.
//
// A client takes the lease when it opens (action "acquire") and renews it every
// ClientLeaseRenew; ClientLeaseTTL without a renewal and it lapses. A second
// client of the same person — another device, or the same one again — takes it
// over: the new lease is the current one, and the old one is remembered as
// taken over, with the taker's device. The first client reads that on its next
// renewal (state taken_over, by = the taker) and goes to its standby screen; it
// stops renewing, and pressing Enter there is an acquire again. Taking over is
// the only conflict rule — nothing queues, nothing is refused.
//
// A lease that lapsed (a MacBook asleep) is not taken over: the next client
// simply gets a fresh one, and its answer carries no took_over. The sleeper's
// renewal on waking still reads taken_over — someone else holds the lease now
// — so two clients never both believe they are the one.
//
// The table lives in the hub's memory: a restart forgets every lease, and the
// next renewal of each live client re-adopts its own id (nothing else holds
// one), so a deploy costs nobody a standby screen. The current lease is also
// where the hub learns which device a person is using right now
// (ClientLeaseOf — C6, #1716).

const (
	// ClientLeaseRenew is how often a client renews.
	ClientLeaseRenew = 15 * time.Second
	// ClientLeaseTTL is how long a lease lives without a renewal.
	ClientLeaseTTL = 45 * time.Second
	// clientGoneKeep is how long a replaced lease is remembered, so a client
	// that slept through its replacement still reads taken_over on waking.
	clientGoneKeep = 24 * time.Hour
)

// ClientLease is one person's connected client.
type ClientLease struct {
	ID       string    `json:"id"`
	Device   string    `json:"device"`
	Terminal string    `json:"terminal,omitempty"`
	Version  string    `json:"version,omitempty"`
	Since    time.Time `json:"since"`
	Renewed  time.Time `json:"renewed"`
	Expires  time.Time `json:"expires"`
}

// clientGone is a lease that is no longer the current one.
type clientGone struct {
	key string
	by  ClientLease // the lease that replaced it
	at  time.Time
	// lapsed: it had already run out when it was replaced — not a takeover.
	lapsed bool
}

// clientLeaseTable holds every person's lease, keyed by clientLeaseKey.
type clientLeaseTable struct {
	mu   sync.Mutex
	cur  map[string]*ClientLease
	gone map[string]clientGone
}

// ClientLeaseRequest is the body of a POST to control.ClientPath. Cert, Sig
// and TS prove a connection certificate (ssh-keygen -Y sign -n
// fleet-client@claude-fleet over control.ClientSigMessage(TS)); a viewer door
// leaves them out.
type ClientLeaseRequest struct {
	Cert string `json:"cert,omitempty"`
	Sig  string `json:"sig,omitempty"`
	TS   int64  `json:"ts,omitempty"`
	// Action is acquire, renew, release or get (the default).
	Action string `json:"action"`
	// Lease is the client's own lease id: required to renew or release; on an
	// acquire, the id the client held before (its server's), so the same
	// client opening again keeps its lease instead of taking it from itself.
	Lease    string `json:"lease,omitempty"`
	Device   string `json:"device,omitempty"`
	Terminal string `json:"terminal,omitempty"`
	Version  string `json:"version,omitempty"`
}

// ClientLeaseResponse is the answer.
type ClientLeaseResponse struct {
	// State is active (the lease is yours), taken_over (another client holds
	// it — go to standby), released, or none (get: nobody holds one).
	State string `json:"state"`
	// Lease is yours when active; the current one on a get.
	Lease *ClientLease `json:"lease,omitempty"`
	// By is the client that holds it now (taken_over).
	By *ClientLease `json:"by,omitempty"`
	// TookOver is the live client an acquire displaced — absent when the old
	// lease had lapsed, which is not a takeover.
	TookOver  *ClientLease `json:"took_over,omitempty"`
	RenewSecs int          `json:"renew_secs"`
	TTLSecs   int          `json:"ttl_secs"`
}

func newClientLeaseID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// cleanClientField keeps a client's self-reported word short and printable:
// it is shown on another client's standby screen.
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

func (t *clientLeaseTable) init() {
	if t.cur == nil {
		t.cur = map[string]*ClientLease{}
		t.gone = map[string]clientGone{}
	}
}

func (t *clientLeaseTable) prune(now time.Time) {
	for id, g := range t.gone {
		if now.Sub(g.at) > clientGoneKeep {
			delete(t.gone, id)
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
	if v := cleanClientField(req.Version, 64); v != "" {
		l.Version = v
	}
}

func (t *clientLeaseTable) live(l *ClientLease, now time.Time) bool {
	return l != nil && now.Before(l.Expires)
}

func leaseCopy(l *ClientLease) *ClientLease {
	if l == nil {
		return nil
	}
	c := *l
	return &c
}

// acquire makes the caller's client the current one.
func (t *clientLeaseTable) acquire(key string, req ClientLeaseRequest, now time.Time) ClientLeaseResponse {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	t.prune(now)
	c := t.cur[key]
	if c != nil && req.Lease != "" && c.ID == req.Lease {
		// The same client opening again (another window on the same server):
		// its lease, refreshed — never a takeover of itself.
		t.fill(c, req)
		c.Renewed, c.Expires = now, now.Add(ClientLeaseTTL)
		return ClientLeaseResponse{State: "active", Lease: leaseCopy(c)}
	}
	n := &ClientLease{ID: newClientLeaseID(), Since: now, Renewed: now, Expires: now.Add(ClientLeaseTTL)}
	t.fill(n, req)
	out := ClientLeaseResponse{State: "active", Lease: n}
	if c != nil {
		lapsed := !t.live(c, now)
		t.gone[c.ID] = clientGone{key: key, by: *n, at: now, lapsed: lapsed}
		if !lapsed {
			out.TookOver = leaseCopy(c)
		}
	}
	if req.Lease != "" {
		delete(t.gone, req.Lease) // a standby client taking it back
	}
	t.cur[key] = n
	out.Lease = leaseCopy(n)
	return out
}

// renew extends the caller's lease, or says who took it.
func (t *clientLeaseTable) renew(key string, req ClientLeaseRequest, now time.Time) ClientLeaseResponse {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	t.prune(now)
	c := t.cur[key]
	if c != nil && c.ID == req.Lease {
		// Its own lease, even one that lapsed while nobody else came: a client
		// back from a short sleep simply carries on.
		t.fill(c, req)
		c.Renewed, c.Expires = now, now.Add(ClientLeaseTTL)
		return ClientLeaseResponse{State: "active", Lease: leaseCopy(c)}
	}
	if g, ok := t.gone[req.Lease]; ok && g.key == key {
		by := g.by
		if c != nil {
			by = *c // the one holding it NOW, should it have changed hands again
		}
		return ClientLeaseResponse{State: "taken_over", By: &by}
	}
	if t.live(c, now) {
		return ClientLeaseResponse{State: "taken_over", By: leaseCopy(c)}
	}
	// An id the hub does not know and nobody else holding one: the hub
	// restarted under a live client. It is the current one again, same id.
	n := &ClientLease{ID: req.Lease, Since: now, Renewed: now, Expires: now.Add(ClientLeaseTTL)}
	t.fill(n, req)
	if c != nil {
		t.gone[c.ID] = clientGone{key: key, by: *n, at: now, lapsed: true}
	}
	t.cur[key] = n
	return ClientLeaseResponse{State: "active", Lease: leaseCopy(n)}
}

// release gives the lease up (the client's server ended).
func (t *clientLeaseTable) release(key, lease string) ClientLeaseResponse {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	if c := t.cur[key]; c != nil && c.ID == lease {
		delete(t.cur, key)
	}
	delete(t.gone, lease)
	return ClientLeaseResponse{State: "released"}
}

// get is the current lease, if one is live.
func (t *clientLeaseTable) get(key string, now time.Time) ClientLeaseResponse {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	if c := t.cur[key]; t.live(c, now) {
		return ClientLeaseResponse{State: "active", Lease: leaseCopy(c)}
	}
	return ClientLeaseResponse{State: "none"}
}

// clientLeaseKey is whose lease it is: the principal, or the operator door.
func clientLeaseKey(id sshRelayIdentity) string {
	if id.Operator || id.Principal == "" {
		return "operator"
	}
	return "p:" + id.Principal
}

// ClientLeaseOf is the client a person is connected through right now, if any
// (principal "" = the operator).
func (s *Server) ClientLeaseOf(principal string, now time.Time) (ClientLease, bool) {
	key := clientLeaseKey(sshRelayIdentity{Operator: principal == "", Principal: principal})
	r := s.clientLeases.get(key, now)
	if r.Lease == nil {
		return ClientLease{}, false
	}
	return *r.Lease, true
}

// handleFleetClient serves control.ClientPath outside the viewer gate: a
// connection certificate proven by a signed timestamp (POST), or the
// operator's doors / a WeCom session (GET reads the current lease; POST acts).
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
	id, ok := s.sshRelayHTTPIdentity(r)
	if !ok {
		if req.Cert == "" || req.Sig == "" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
			httpError(w, http.StatusUnauthorized, "a session, a viewer token or a connection certificate is required")
			return
		}
		if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
			httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
			return
		}
		var err error
		if id, err = s.verifySSHRelayCert(req.Cert, req.Sig, control.ClientSigMessage(req.TS), control.ClientSigNamespace, now); err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				httpError(w, http.StatusUnauthorized, re.msg)
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	key := clientLeaseKey(id)
	var out ClientLeaseResponse
	switch req.Action {
	case "", "get":
		out = s.clientLeases.get(key, now)
	case "acquire":
		out = s.clientLeases.acquire(key, req, now)
		outcome := "OK"
		if out.TookOver != nil {
			outcome = "TAKEOVER"
		}
		if s.Store != nil {
			if err := s.Store.FleetAudit(id.Actor, "client_acquire", out.Lease.Device, outcome, out.Lease.ID, now); err != nil {
				log.Printf("fleet audit: %v", err)
			}
		}
	case "renew":
		if req.Lease == "" {
			httpError(w, http.StatusBadRequest, "renew needs the lease id")
			return
		}
		out = s.clientLeases.renew(key, req, now)
	case "release":
		if req.Lease == "" {
			httpError(w, http.StatusBadRequest, "release needs the lease id")
			return
		}
		out = s.clientLeases.release(key, req.Lease)
	default:
		httpError(w, http.StatusBadRequest, "action must be acquire, renew, release or get")
		return
	}
	out.RenewSecs, out.TTLSecs = int(ClientLeaseRenew/time.Second), int(ClientLeaseTTL/time.Second)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}
