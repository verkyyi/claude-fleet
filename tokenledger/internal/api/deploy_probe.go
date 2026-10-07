package api

// What a rolling release asks of a hub (claude-fleet#2125, EPIC #2119 C6).
//
//   GET  /readyz           200 only while the database answers and has run
//                          every migration this build knows — the pod's
//                          readinessProbe, so a new replica gets traffic only
//                          once it can serve it, and one whose database went
//                          away stops getting it (liveness stays /healthz: a
//                          database outage must not restart every pod).
//   POST /v1/deploy-probe  one real write (rollup_meta's deploy_probe row) —
//                          hub-deploy's availability probe calls it every
//                          second of a release, beside /healthz, and counts
//                          the seconds either is not 2xx (downtime_seconds).
//
// Both are public and say nothing: no database detail leaves the hub (the
// reason is logged here, once per change), and the probe's write is one row
// overwritten, coalesced to at most two writes a second however hard it is hit.

import (
	"context"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/leader"
)

// deployProbeEvery is the most often the probe writes; a call inside it
// answers 200 without writing again.
const deployProbeEvery = 500 * time.Millisecond

type deployProbe struct {
	mu        sync.Mutex
	lastWrite time.Time
	lastReady string // the last /readyz verdict logged ("" = ready)
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	err := s.Store.Ready(ctx)
	why := ""
	if err != nil {
		why = err.Error()
	}
	s.probe.mu.Lock()
	changed := why != s.probe.lastReady
	s.probe.lastReady = why
	s.probe.mu.Unlock()
	if changed {
		if why == "" {
			log.Printf("readyz: ready")
		} else {
			log.Printf("readyz: not ready: %s", why)
		}
	}
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "not ready"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) handleDeployProbe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	now := time.Now()
	s.probe.mu.Lock()
	recent := now.Sub(s.probe.lastWrite) < deployProbeEvery
	if !recent {
		s.probe.lastWrite = now
	}
	s.probe.mu.Unlock()
	if !recent {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := s.Store.TouchDeployProbe(ctx, now, leader.Replica()); err != nil {
			s.probe.mu.Lock()
			s.probe.lastWrite = time.Time{}
			s.probe.mu.Unlock()
			log.Printf("deploy-probe: write failed: %v", err)
			httpError(w, http.StatusServiceUnavailable, "write failed")
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "wrote": !recent})
}
