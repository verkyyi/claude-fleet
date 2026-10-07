package api

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The hub's in-memory state with two replicas (claude-fleet#2190, EPIC #2119).
//
// Three things live in one process's memory on purpose, and none of them is a
// node link that C5 (node_route.go) could forward by endpoint:
//
//   - a `fleet login` in progress (deviceLogins): start, the QR page's
//     confirmation and the poll are three requests that may land on either
//     replica, and the certificate — with a node pass on a `fleet node join`
//     scan — must be handed out exactly once;
//   - the client leases and the actions queued for them (clientLeaseTable):
//     eviction, the primary and an action's long-poll are one state machine;
//   - the live sessions (Live): a report from one endpoint, read by every
//     dashboard and by /mcp.
//
// The first two stay exactly the code they were, in ONE replica: the STATE
// HOLDER, the replica up the longest (fleet_replicas, oldest start first). A
// request for one of their routes that lands on another replica is reverse-
// proxied to the holder whole — headers, cookies, body, a long-poll — and the
// holder serves it as its own (stateRoute). A read from inside the hub
// (ClientLeaseOf, for placement) asks the holder over StateLeasePath. Nothing
// holding a credential is ever written to the database: a pending login's
// certificate and node pass stay in the holder's memory, as they always did.
// When the holder goes (it stops beating for replicaUpFor) the other replica
// becomes the holder with an empty table — what a hub restart always cost: a
// login in progress is scanned again, and every live client's next renewal
// re-adopts its own lease.
//
// The live sessions are different: every replica has readers of its own
// (/mcp, the counter's live rate), so a report is applied where it lands AND
// handed to every other replica up (LiveFanoutPath) — each one holds the whole
// picture, and an SSE stream on either shows every session.
//
// The hero counter's cache (counter.go) stays per replica: both read the same
// store, an ingest invalidates only its own replica's cache, and the other one
// recomputes within counterTTL (30 s) — display only.
//
// Off — Server.Replica nil, the single hub — nothing here runs: no table, no
// route, no lookup, every handler is called directly (TestReplicaStateSingleHub).

const (
	// LiveFanoutPath is the in-cluster route a live report is handed on.
	LiveFanoutPath = "/internal/v1/live-report"
	// StateLeasePath is the in-cluster read of the holder's client leases.
	StateLeasePath = "/internal/v1/client-lease"

	// replicaBeatEvery is how often a replica writes its fleet_replicas row.
	replicaBeatEvery = 5 * time.Second
	// replicaUpFor is how long a row counts as up without a new beat: the
	// longest a dead holder keeps the state's requests failing.
	replicaUpFor = 15 * time.Second
	// stateRetryAfter is the Retry-After of a request whose holder could not
	// be reached.
	stateRetryAfter = 5
)

// replicaLife is this replica's own row: when it started.
type replicaLife struct {
	once    sync.Once
	started time.Time
}

func (s *Server) replicaStarted() time.Time {
	s.replicaLife.once.Do(func() { s.replicaLife.started = time.Now().UTC() })
	return s.replicaLife.started
}

// beatReplica writes this replica's row.
func (s *Server) beatReplica(now time.Time) error {
	return s.Store.BeatReplica(store.ReplicaRow{Name: s.Replica.Name, URL: s.Replica.URL,
		StartedAt: s.replicaStarted(), SeenAt: now})
}

// RunReplica keeps this replica's fleet_replicas row fresh until ctx ends. A
// single hub returns at once.
func (s *Server) RunReplica(ctx context.Context) {
	if s.Replica == nil {
		return
	}
	t := time.NewTicker(replicaBeatEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			if err := s.beatReplica(now); err != nil {
				log.Printf("fleet: replica %s: beat: %v", s.Replica.Name, err)
			}
		}
	}
}

// replicasUp is every replica up right now, this one included even when its
// own beat failed, oldest start first.
func (s *Server) replicasUp(now time.Time) []store.ReplicaRow {
	self := store.ReplicaRow{Name: s.Replica.Name, URL: s.Replica.URL, StartedAt: s.replicaStarted(), SeenAt: now}
	rows, err := s.Store.Replicas(now.Add(-replicaUpFor))
	if err != nil {
		log.Printf("fleet: read fleet_replicas: %v", err)
		return []store.ReplicaRow{self}
	}
	out := make([]store.ReplicaRow, 0, len(rows)+1)
	placed := false
	for _, r := range rows {
		if r.Name == self.Name {
			continue
		}
		if !placed && (self.StartedAt.Before(r.StartedAt) || (self.StartedAt.Equal(r.StartedAt) && self.Name < r.Name)) {
			out, placed = append(out, self), true
		}
		out = append(out, r)
	}
	if !placed {
		out = append(out, self)
	}
	return out
}

// stateHolder is the OTHER replica holding the in-memory state; ok is false on
// a single hub and when this replica is the holder.
func (s *Server) stateHolder(now time.Time) (store.ReplicaRow, bool) {
	if s.Replica == nil {
		return store.ReplicaRow{}, false
	}
	up := s.replicasUp(now)
	if up[0].Name == s.Replica.Name {
		return store.ReplicaRow{}, false
	}
	return up[0], true
}

// stateRoute serves h on the state holder: here when this replica is it (or
// is a single hub, or the request was already handed here), else the whole
// request is proxied to it.
func (s *Server) stateRoute(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.Replica == nil || s.relayHopped(r) {
			h.ServeHTTP(w, r)
			return
		}
		holder, ok := s.stateHolder(time.Now())
		if !ok {
			h.ServeHTTP(w, r)
			return
		}
		s.proxyState(w, r, holder)
	})
}

func (s *Server) stateRouteFunc(f http.HandlerFunc) http.Handler { return s.stateRoute(f) }

// proxyState hands r to holder. The holder sees the request the client sent:
// its Host (the verification URI, the same-origin check), its scheme, its
// cookies and body; a long-poll streams through.
func (s *Server) proxyState(w http.ResponseWriter, r *http.Request, holder store.ReplicaRow) {
	target, err := url.Parse(holder.URL)
	if err != nil {
		httpError(w, http.StatusBadGateway, "replica "+holder.Name+": bad address: "+err.Error())
		return
	}
	s.stateForwarded.Add(1)
	rp := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.Out.Host = pr.In.Host
			for _, k := range []string{"X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto"} {
				if v := pr.In.Header.Values(k); len(v) > 0 {
					pr.Out.Header[k] = v
				}
			}
			if pr.In.TLS != nil {
				pr.Out.Header.Set("X-Forwarded-Proto", "https")
			}
			pr.Out.Header.Set(replicaTokenHeader, s.Replica.Token)
		},
		FlushInterval: -1,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("fleet: hand %s to state holder %s: %v", r.URL.Path, holder.Name, err)
			w.Header().Set("Retry-After", strconv.Itoa(stateRetryAfter))
			httpError(w, http.StatusServiceUnavailable, "the hub replica holding this state could not be reached; retry shortly")
		},
	}
	if s.Replica.Client != nil && s.Replica.Client.Transport != nil {
		rp.Transport = s.Replica.Client.Transport
	}
	rp.ServeHTTP(w, r)
}

// replicaAuthed checks the replicas' shared token on an in-cluster route.
func (s *Server) replicaAuthed(w http.ResponseWriter, r *http.Request) bool {
	if !s.relayHopped(r) {
		httpError(w, http.StatusUnauthorized, "not a replica of this hub")
		return false
	}
	return true
}

// clientLeasesGet is clientLeases.get on the state holder.
func (s *Server) clientLeasesGet(key string, now time.Time) ClientLeaseResponse {
	holder, ok := s.stateHolder(now)
	if !ok {
		return s.clientLeases.get(key, now)
	}
	s.stateForwarded.Add(1)
	ctx, cancel := context.WithTimeout(context.Background(), nodeRouteMargin)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, holder.URL+StateLeasePath+"?key="+url.QueryEscape(key), nil)
	if err != nil {
		return ClientLeaseResponse{State: "none"}
	}
	req.Header.Set(replicaTokenHeader, s.Replica.Token)
	resp, err := s.Replica.client().Do(req)
	if err != nil {
		// Where the person is is unknown, which every caller already
		// handles as "no client".
		log.Printf("fleet: read client leases from state holder %s: %v", holder.Name, err)
		return ClientLeaseResponse{State: "none"}
	}
	defer resp.Body.Close()
	var out ClientLeaseResponse
	if resp.StatusCode != http.StatusOK || json.NewDecoder(resp.Body).Decode(&out) != nil {
		return ClientLeaseResponse{State: "none"}
	}
	return out
}

// handleStateLease answers another replica's read of a person's leases.
func (s *Server) handleStateLease(w http.ResponseWriter, r *http.Request) {
	if !s.replicaAuthed(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, s.clientLeases.get(r.URL.Query().Get("key"), time.Now()))
}

// liveFanout is one report handed to the other replicas.
type liveFanout struct {
	EndpointID string        `json:"endpoint_id"`
	Label      string        `json:"label"`
	Sessions   []LiveSession `json:"sessions"`
	Complete   bool          `json:"complete"`
}

// fanoutLive hands a report this replica just applied to every other replica
// up. In the background: an agent's report never waits on a peer.
func (s *Server) fanoutLive(f liveFanout) {
	if s.Replica == nil {
		return
	}
	body, err := json.Marshal(f)
	if err != nil {
		return
	}
	for _, peer := range s.replicasUp(time.Now()) {
		if peer.Name == s.Replica.Name {
			continue
		}
		peer := peer
		s.liveFanned.Add(1)
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), nodeRouteMargin)
			defer cancel()
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, peer.URL+LiveFanoutPath, bytes.NewReader(body))
			if err != nil {
				return
			}
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set(replicaTokenHeader, s.Replica.Token)
			resp, err := s.Replica.client().Do(req)
			if err != nil {
				// That replica's viewers miss this report; the endpoint's
				// next one (seconds away) carries the same sessions.
				log.Printf("live: hand %s's report to replica %s: %v", f.EndpointID, peer.Name, err)
				return
			}
			resp.Body.Close()
		}()
	}
}

// handleLiveFanout applies a report another replica received.
func (s *Server) handleLiveFanout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	if !s.replicaAuthed(w, r) {
		return
	}
	var f liveFanout
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&f); err != nil {
		httpError(w, http.StatusBadRequest, "malformed live report: "+err.Error())
		return
	}
	s.liveStore().report(f.EndpointID, f.Label, f.Sessions, f.Complete)
	writeJSON(w, http.StatusOK, map[string]any{"accepted": len(f.Sessions)})
}
