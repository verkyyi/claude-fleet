package api

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"path"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Open it on the device in your hands (claude-fleet#1717, EPIC #1710 C7).
//
// A session anywhere asks to show the person a page, a file or a note; the
// hub hands it to the client that person is using right now — the primary of
// their leases (C5, #1715; several since #1932: the one typed into last) — or,
// a notify with all, to every client they hold,
// and that client does it on its own device: `open` / `xdg-open`, a page on
// the session's machine forwarded over the client's ssh master first, iTerm2's
// escapes where the terminal is iTerm2, a link to tap where the device cannot
// open anything (a phone ssh'd into a machine running the client).
//
//	POST /v1/node/client/actions   a node, with its own token, sends one action
//	                               to its OWNER's current client (the C6 rule):
//	                               {kind open_url|show_file|notify, url | rport
//	                               path scheme, file name size inline, title
//	                               body, links {tailnet, hub}, wait}
//	POST /v1/fleet/client/actions  the client, with its connection certificate:
//	                               {action poll, lease, wait} drains what waits
//	                               for its lease; {action done, lease, id,
//	                               result} answers one
//
// Anti-forgery (open.secret's rule, carried onto this road): every action is
// signed — HMAC-SHA256 under the lease's action key, which only the lease's
// own client is told (ClientLeaseResponse.ActionKey, on acquire and renewal) —
// and carries the lease id it was sent to. A client runs an action only when
// the signature checks under its key and the lease is its own, so nothing the
// network or another client injects is ever executed: a send reaches the
// primary at that moment, and a lease that is asked to leave or disconnected
// loses its queue and its key.
//
// The machine an action came from is the hub's word (the sending node's
// roster name), never the body's: the client forwards a loopback page or
// fetches a file from exactly that machine.

const (
	clientActionKeep   = 2 * time.Minute // an undelivered action is dropped after this
	clientActionMax    = 16              // waiting per lease; the oldest goes first
	clientActionWait   = 15 * time.Second
	clientPollWait     = 25 * time.Second
	clientActionResult = 5 * time.Minute // how long a result is kept for its sender
)

// ClientActionLinks are the addresses a device that cannot open a page itself
// is given to tap, best first by its route: Tailnet for a device on the
// tailnet, Hub for one that is not.
type ClientActionLinks struct {
	Tailnet string `json:"tailnet,omitempty"`
	Hub     string `json:"hub,omitempty"`
}

// ClientAction is one action as its client receives it (the signed payload).
type ClientAction struct {
	ID      string            `json:"id"`
	Lease   string            `json:"lease"`
	Kind    string            `json:"kind"`
	URL     string            `json:"url,omitempty"`
	RPort   int               `json:"rport,omitempty"`
	Path    string            `json:"path,omitempty"`
	Scheme  string            `json:"scheme,omitempty"`
	File    string            `json:"file,omitempty"`
	Name    string            `json:"name,omitempty"`
	Size    int64             `json:"size,omitempty"`
	Inline  bool              `json:"inline,omitempty"`
	Title   string            `json:"title,omitempty"`
	Body    string            `json:"body,omitempty"`
	Links   ClientActionLinks `json:"links,omitempty"`
	Machine string            `json:"machine"`
	Host    string            `json:"host"`
	TS      int64             `json:"ts"`
}

// SignedClientAction is what a poll returns: the payload as signed, and its
// signature (hex HMAC-SHA256 of the payload bytes under the action key).
type SignedClientAction struct {
	Payload string `json:"payload"`
	Sig     string `json:"sig"`
}

// ClientActionSend is the body of a node's POST /v1/node/client/actions.
type ClientActionSend struct {
	Kind   string            `json:"kind"`
	URL    string            `json:"url,omitempty"`
	RPort  int               `json:"rport,omitempty"`
	Path   string            `json:"path,omitempty"`
	Scheme string            `json:"scheme,omitempty"`
	File   string            `json:"file,omitempty"`
	Name   string            `json:"name,omitempty"`
	Size   int64             `json:"size,omitempty"`
	Inline bool              `json:"inline,omitempty"`
	Title  string            `json:"title,omitempty"`
	Body   string            `json:"body,omitempty"`
	Links  ClientActionLinks `json:"links,omitempty"`
	// All sends a notify to every client the person holds, not only the
	// primary (#1932); the answer is the primary's.
	All bool `json:"all,omitempty"`
	// Wait is how many seconds the sender waits for the client's answer
	// (at most clientActionWait); 0 = queued is the answer.
	Wait int `json:"wait,omitempty"`
}

// ClientActionSendResponse answers a send: state none (nobody is connected —
// the sender opens it its own way), queued (no answer within Wait), done or
// failed (the client's answer, Result its one line). Client is where it went.
type ClientActionSendResponse struct {
	State  string       `json:"state"`
	ID     string       `json:"id,omitempty"`
	Result string       `json:"result,omitempty"`
	Client *ClientLease `json:"client,omitempty"`
}

// ClientActionPoll is the body of a client's POST /v1/fleet/client/actions.
type ClientActionPoll struct {
	Cert   string `json:"cert,omitempty"`
	Sig    string `json:"sig,omitempty"`
	TS     int64  `json:"ts,omitempty"`
	Action string `json:"action"` // poll | done
	Lease  string `json:"lease"`
	Wait   int    `json:"wait,omitempty"`
	ID     string `json:"id,omitempty"`
	OK     bool   `json:"ok,omitempty"`
	Result string `json:"result,omitempty"`
}

// ClientActionPollResponse: state active (Actions, possibly none), or
// taken_over / none — the lease is not the current one, nothing will come.
type ClientActionPollResponse struct {
	State   string               `json:"state"`
	Actions []SignedClientAction `json:"actions"`
}

type clientActionResultRec struct {
	lease, result string
	ok            bool
	at            time.Time
	done          chan struct{}
}

// clientActionQueue is guarded by the lease table's mutex.
type clientActionQueue struct {
	wait    map[string][]SignedClientAction // lease → waiting
	at      map[string][]time.Time          // lease → when each was queued
	results map[string]*clientActionResultRec
	wake    chan struct{} // closed (and replaced) on every enqueue
}

func (q *clientActionQueue) init() {
	if q.wait == nil {
		q.wait = map[string][]SignedClientAction{}
		q.at = map[string][]time.Time{}
		q.results = map[string]*clientActionResultRec{}
		q.wake = make(chan struct{})
	}
}

func (q *clientActionQueue) drop(lease string) {
	delete(q.wait, lease)
	delete(q.at, lease)
}

func (q *clientActionQueue) prune(now time.Time) {
	for l, ats := range q.at {
		i := 0
		for i < len(ats) && now.Sub(ats[i]) > clientActionKeep {
			i++
		}
		if i == len(ats) {
			q.drop(l)
		} else if i > 0 {
			q.wait[l], q.at[l] = q.wait[l][i:], ats[i:]
		}
	}
	for id, r := range q.results {
		if now.Sub(r.at) > clientActionResult {
			delete(q.results, id)
		}
	}
}

// actionKey is the lease's action key, minted on first ask.
func (t *clientLeaseTable) actionKey(lease string) string {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	return t.actionKeyLocked(lease)
}

func (t *clientLeaseTable) actionKeyLocked(lease string) string {
	if k := t.keys[lease]; k != "" {
		return k
	}
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	k := hex.EncodeToString(b)
	t.keys[lease] = k
	return k
}

// forgetLeaseLocked drops what belonged to a lease that is no longer current.
func (t *clientLeaseTable) forgetLeaseLocked(lease string) {
	delete(t.keys, lease)
	t.acts.init()
	t.acts.drop(lease)
}

func signClientAction(key string, payload []byte) string {
	m := hmac.New(sha256.New, []byte(key))
	m.Write(payload)
	return hex.EncodeToString(m.Sum(nil))
}

// send queues a for key's primary lease — and, all, for every other live one
// too, each signed under its own key; nil lease = nobody is connected. The
// record waited on is the primary's.
func (t *clientLeaseTable) send(key string, a ClientAction, all bool, now time.Time) (*ClientLease, string, *clientActionResultRec) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	t.acts.init()
	t.acts.prune(now)
	p := t.primaryLocked(key, now)
	if p == nil {
		return nil, "", nil
	}
	to := []*ClientLease{p}
	if all {
		for _, l := range t.liveLocked(key, now) {
			if l.ID != p.ID {
				to = append(to, l)
			}
		}
	}
	var id string
	var rec *clientActionResultRec
	q := &t.acts
	for i, c := range to {
		b := a
		b.ID, b.Lease, b.TS = newClientLeaseID(), c.ID, now.Unix()
		payload, _ := json.Marshal(b)
		sa := SignedClientAction{Payload: string(payload), Sig: signClientAction(t.actionKeyLocked(c.ID), payload)}
		if len(q.wait[c.ID]) >= clientActionMax {
			q.wait[c.ID], q.at[c.ID] = q.wait[c.ID][1:], q.at[c.ID][1:]
		}
		q.wait[c.ID] = append(q.wait[c.ID], sa)
		q.at[c.ID] = append(q.at[c.ID], now)
		r := &clientActionResultRec{lease: c.ID, at: now, done: make(chan struct{})}
		q.results[b.ID] = r
		if i == 0 {
			id, rec = b.ID, r
		}
	}
	close(q.wake)
	q.wake = make(chan struct{})
	return leaseCopy(p), id, rec
}

// take drains what waits for lease, if it is one of key's. state is
// active, or taken_over / none; wake is what to wait on when nothing waits.
func (t *clientLeaseTable) take(key, lease string, now time.Time) (string, []SignedClientAction, chan struct{}) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	t.acts.init()
	t.acts.prune(now)
	if t.holdsLocked(key, lease) == nil {
		if g, ok := t.gone[lease]; ok && g.key == key {
			return "taken_over", nil, nil
		}
		return "none", nil, nil
	}
	out := t.acts.wait[lease]
	t.acts.drop(lease)
	return "active", out, t.acts.wake
}

// answer records the client's result for one of its lease's actions.
func (t *clientLeaseTable) answer(key, lease, id string, ok bool, result string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.init()
	t.acts.init()
	r := t.acts.results[id]
	if r == nil || r.lease != lease {
		return false
	}
	select {
	case <-r.done:
		return true // answered already
	default:
	}
	r.ok, r.result = ok, cleanClientField(result, 200)
	close(r.done)
	return true
}

func cleanActionURL(u string) string {
	u = strings.TrimSpace(u)
	if len(u) > 4096 || strings.ContainsAny(u, " \t\r\n\x00") {
		return ""
	}
	if strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://") {
		return u
	}
	return ""
}

// nodeMachineLabel is the name a client knows the node's machine by: the
// route list's alias, else the roster hostname's first label.
func (s *Server) nodeMachineLabel(host string) string {
	for _, m := range s.fleetMachines() {
		if strings.EqualFold(m.Hostname, host) && m.Alias != "" {
			return m.Alias
		}
	}
	return firstLabel(host)
}

// handleNodeClientActions serves POST /v1/node/client/actions: a node sends
// one action to its owner's current client.
func (s *Server) handleNodeClientActions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	var req ClientActionSend
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object")
		return
	}
	host, user := s.peerSelf(ep)
	a := ClientAction{Kind: req.Kind, Machine: s.nodeMachineLabel(host), Host: host,
		Links: ClientActionLinks{Tailnet: cleanActionURL(req.Links.Tailnet), Hub: cleanActionURL(req.Links.Hub)}}
	switch req.Kind {
	case "open_url":
		if req.RPort != 0 {
			if req.RPort < 1 || req.RPort > 65535 {
				httpError(w, http.StatusBadRequest, "rport must be a port")
				return
			}
			a.RPort, a.Scheme = req.RPort, "http"
			if req.Scheme == "https" {
				a.Scheme = "https"
			}
			a.Path = cleanClientField(req.Path, 2048)
			if !strings.HasPrefix(a.Path, "/") {
				a.Path = "/" + a.Path
			}
		} else if a.URL = cleanActionURL(req.URL); a.URL == "" {
			httpError(w, http.StatusBadRequest, "open_url needs an http(s) url or a loopback rport")
			return
		}
	case "show_file":
		f := cleanClientField(req.File, 1024)
		if !strings.HasPrefix(f, "/") || path.Clean(f) != f {
			httpError(w, http.StatusBadRequest, "show_file needs the file's absolute path")
			return
		}
		a.File, a.Name, a.Size, a.Inline = f, cleanClientField(req.Name, 255), req.Size, req.Inline
		if a.Name == "" {
			a.Name = path.Base(f)
		}
	case "notify":
		a.Title, a.Body = cleanClientField(req.Title, 120), cleanClientField(req.Body, 500)
		if a.Title == "" && a.Body == "" {
			httpError(w, http.StatusBadRequest, "notify needs a title or a body")
			return
		}
	default:
		httpError(w, http.StatusBadRequest, "kind must be open_url, show_file or notify")
		return
	}
	owner, err := s.Store.PrincipalForLogin(host, user)
	if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	key := clientLeaseKey(sshRelayIdentity{Operator: owner == "", Principal: owner})
	now := time.Now()
	w.Header().Set("Cache-Control", "no-store")
	c, id, rec := s.clientLeases.send(key, a, req.All && req.Kind == "notify", now)
	if c == nil {
		writeJSON(w, http.StatusOK, ClientActionSendResponse{State: "none"})
		return
	}
	if s.Store != nil {
		if err := s.Store.FleetAudit(host+"/"+user, "client_action", c.Device, req.Kind, id, now); err != nil {
			log.Printf("fleet audit: %v", err)
		}
	}
	out := ClientActionSendResponse{State: "queued", ID: id, Client: c}
	wait := time.Duration(req.Wait) * time.Second
	if wait > clientActionWait {
		wait = clientActionWait
	}
	if wait > 0 {
		select {
		case <-rec.done:
			s.clientLeases.mu.Lock()
			out.Result, out.State = rec.result, "failed"
			if rec.ok {
				out.State = "done"
			}
			s.clientLeases.mu.Unlock()
		case <-time.After(wait):
		case <-r.Context().Done():
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// handleFleetClientActions serves POST /v1/fleet/client/actions: a client
// polls for its lease's actions, or answers one.
func (s *Server) handleFleetClientActions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	var req ClientActionPoll
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object")
		return
	}
	now := time.Now()
	id, ok := s.clientIdentity(w, r, req.Cert, req.Sig, req.TS, now)
	if !ok {
		return
	}
	if req.Lease == "" {
		httpError(w, http.StatusBadRequest, "the lease id is required")
		return
	}
	// a test identity's lease polls in its own slot (#1931): no action is ever
	// queued there, so it waits and reads active, never taken_over
	key := s.clientLeases.slotOf(clientLeaseKey(id), req.Lease)
	w.Header().Set("Cache-Control", "no-store")
	switch req.Action {
	case "done":
		if !s.clientLeases.answer(key, req.Lease, req.ID, req.OK, req.Result) {
			httpError(w, http.StatusNotFound, "no such action for this lease")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"state": "recorded"})
	case "", "poll":
		wait := time.Duration(req.Wait) * time.Second
		if wait > clientPollWait {
			wait = clientPollWait
		}
		deadline := time.After(wait)
		for {
			st, acts, wake := s.clientLeases.take(key, req.Lease, time.Now())
			if st != "active" || len(acts) > 0 || wait <= 0 {
				if acts == nil {
					acts = []SignedClientAction{}
				}
				writeJSON(w, http.StatusOK, ClientActionPollResponse{State: st, Actions: acts})
				return
			}
			select {
			case <-wake:
			case <-deadline:
				wait = 0
			case <-r.Context().Done():
				return
			}
		}
	default:
		httpError(w, http.StatusBadRequest, "action must be poll or done")
	}
}
