package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// RMVE: the numbers the browser terminal is judged by, read off its rows.
func TestTermHealthNumbers(t *testing.T) {
	t0 := time.Date(2026, 10, 21, 9, 0, 0, 0, time.UTC)
	at := func(s int) time.Time { return t0.Add(time.Duration(s) * time.Second) }
	rows := []store.FleetTermSession{
		// opened, got a path in 2 s, dropped by a hub restart at 60 s
		{ID: "a", Cause: "first", OpenedAt: at(0), SelectedAt: at(2), ClosedAt: at(60), Outcome: "relay hub; hub_restart"},
		// the page came back by itself: one failed try, then a path 4 s after the drop
		{ID: "b", Cause: "auto", Previous: "a", OpenedAt: at(60), ClosedAt: at(61), Outcome: "closed; node_closed"},
		{ID: "c", Cause: "auto", Previous: "b", OpenedAt: at(62), SelectedAt: at(64), ClosedAt: at(200), Outcome: "door us; browser_closed"},
		// opened, never got a path (counts against opening)
		{ID: "d", Cause: "first", OpenedAt: at(300), ClosedAt: at(301), Outcome: "closed; node_closed"},
		// a button was pressed; the drop after it never came back
		{ID: "e", Cause: "manual", OpenedAt: at(400), SelectedAt: at(401), ClosedAt: at(500), Outcome: "direct host/host; ended"},
		// an old row: a path, no close
		{ID: "f", OpenedAt: at(0), SelectedAt: at(1)},
	}
	h := termHealth(rows, t0, t0.Add(48*time.Hour))
	if h.Opens != 3 || h.OpensOK != 2 {
		t.Fatalf("opens %d ok %d, want 3 / 2", h.Opens, h.OpensOK)
	}
	if h.Drops != 2 || h.Recovered != 1 || h.DropReasons["hub_restart"] != 1 || h.DropReasons["ended"] != 1 {
		t.Fatalf("drops %d recovered %d reasons %v", h.Drops, h.Recovered, h.DropReasons)
	}
	if h.RecoverP95 != 4 {
		t.Fatalf("recover p95 %v, want 4 s", h.RecoverP95)
	}
	if h.Manual != 1 || h.Unrecorded != 1 {
		t.Fatalf("manual %d unrecorded %d", h.Manual, h.Unrecorded)
	}
}

func TestTermWords(t *testing.T) {
	if termCause("auto") != "auto" || termCause("x; drop table") != "" {
		t.Fatal("termCause accepts only its words")
	}
	if termReason("ended") != "ended" || termReason("anything else") != "node_error" {
		t.Fatal("termReason")
	}
	if termEndReason("relay hub; hub_restart") != "hub_restart" || termEndReason("closed") != "" {
		t.Fatal("termEndReason")
	}
}

// RMVE: a replica going away says so at once — its row goes, and the open
// terminals' attachments see the drain.
func TestDrainForgetsReplica(t *testing.T) {
	single, _ := certHarness(t)
	a, b := asReplicas(t, single)
	if h, ok := b.srv.stateHolder(time.Now()); !ok || h.Name != "hub-a" {
		t.Fatalf("holder %+v %v", h, ok)
	}
	a.srv.Drain()
	a.srv.Drain() // twice is once
	a.srv.finishDrain()
	if err := a.srv.beatReplica(time.Now()); err != nil {
		t.Fatal(err)
	}
	select {
	case <-a.srv.drainCh():
	default:
		t.Fatal("drain channel still open")
	}

	if h, ok := b.srv.stateHolder(time.Now()); ok {
		t.Fatalf("hub-b still hands the state to %s after it drained", h.Name)
	}
}

// RMVE: a holder that refuses the connection (its pod is gone, its row not
// yet aged out) is passed over — a GET is served here, never 503 for 15 s.
func TestStateHolderUnreachablePassedOver(t *testing.T) {
	single, _ := certHarness(t)
	a, b := asReplicas(t, single)
	a.http.Close() // hub-a's process went; its row is still fresh
	served := 0
	route := b.srv.stateRoute(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { served++; w.Write([]byte("here")) }))
	rec := httptest.NewRecorder()
	route.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/term/client", nil))
	if rec.Code != 200 || served != 1 {
		t.Fatalf("GET with the holder gone: %d %q served=%d", rec.Code, rec.Body.String(), served)
	}
	if !b.srv.replicaUnreachable("hub-a", time.Now()) {
		t.Fatal("hub-a not marked unreachable")
	}
	// the next one goes straight here, nothing forwarded
	before := b.srv.stateForwarded.Load()
	route.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/v1/term/client", nil))
	if served != 2 || b.srv.stateForwarded.Load() != before {
		t.Fatalf("served=%d forwarded %d", served, b.srv.stateForwarded.Load()-before)
	}
	// a body that may have been read is never sent twice: still 503
	b.srv.replicaDown.Delete("hub-a")
	rec = httptest.NewRecorder()
	route.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/term/client", strings.NewReader(`{"x":1}`)))
	if rec.Code != http.StatusServiceUnavailable || served != 2 {
		t.Fatalf("POST with the holder gone: %d served=%d", rec.Code, served)
	}
}
