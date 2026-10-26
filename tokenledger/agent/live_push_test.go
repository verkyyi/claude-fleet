package agent

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

type liveTestLink struct {
	nodeLink
	calls int
	fail  bool
}

func (l *liveTestLink) write(_ context.Context, m control.Message) error {
	if m.Type != control.TypeLiveReport {
		return errors.New("wrong message")
	}
	l.calls++
	if l.fail {
		return errors.New("disconnected")
	}
	return nil
}

func TestLivePushChangesHeartbeatAndFallback(t *testing.T) {
	var requests atomic.Int64
	var fail atomic.Bool
	h := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/live/report" {
			t.Errorf("path %s", r.URL.Path)
		}
		requests.Add(1)
		if fail.Load() {
			w.WriteHeader(503)
		}
	}))
	defer h.Close()
	p := &codexCollector{live: []liveSession{{Source: "codex", SessionID: "s", ObservedAt: time.Now(), InputTokens: 1}}}
	a := &Agent{cfg: Config{HubURL: h.URL}, http: h.Client(), codexProfiles: []*codexCollector{p}}
	push := func() {
		t.Helper()
		if err := a.pushLive(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	push() // An old hub/no welcome still accepts HTTP.
	p.live[0].ObservedAt = time.Now()
	push()
	if n := requests.Load(); n != 1 {
		t.Fatalf("unchanged sent %d", n)
	}
	p.live[0].InputTokens++
	push()
	if requests.Load() != 2 {
		t.Fatal("change not sent")
	}
	a.liveAt = time.Now().Add(-time.Minute)
	push()
	if requests.Load() != 3 {
		t.Fatal("heartbeat missing")
	}
	p.live = nil // Complete empty snapshot removes stopped sessions immediately.
	push()
	if requests.Load() != 4 {
		t.Fatal("removal missing")
	}
	fail.Store(true)
	a.liveAt = time.Time{}
	if a.pushLive(context.Background()) == nil {
		t.Fatal("failure hidden")
	}
	fail.Store(false)
	push()
	if requests.Load() != 6 {
		t.Fatal("failed report not retried")
	}
	link := &liveTestLink{}
	a.liveLink.Store(&liveTransport{conn: link})
	push() // Reconnect must repopulate a restarted hub even with no change.
	push()
	if link.calls != 1 || requests.Load() != 6 {
		t.Fatal("control push/dedup failed")
	}
	link.fail = true
	a.liveAt = time.Time{}
	push()
	if requests.Load() != 7 {
		t.Fatal("broken control link did not fall back")
	}
	a.liveLink.Store(nil)
	push()
	if requests.Load() != 8 {
		t.Fatal("lost lane did not resync via HTTP")
	}
}

func TestLivePushStableOrderAndExpiry(t *testing.T) {
	link := &liveTestLink{}
	p := &codexCollector{live: []liveSession{
		{Source: "codex", SessionID: "b", ObservedAt: time.Now()},
		{Source: "codex", SessionID: "a", ObservedAt: time.Now()},
	}}
	a := &Agent{codexProfiles: []*codexCollector{p}}
	a.liveLink.Store(&liveTransport{conn: link})
	for i := 0; i < 2; i++ {
		if err := a.pushLive(context.Background()); err != nil {
			t.Fatal(err)
		}
		p.live[0], p.live[1] = p.live[1], p.live[0]
	}
	if link.calls != 1 {
		t.Fatal("order manufactured a change")
	}
	p.live[0].ObservedAt = time.Now().Add(-3 * time.Minute)
	if err := a.pushLive(context.Background()); err != nil {
		t.Fatal(err)
	}
	if link.calls != 2 {
		t.Fatal("stale session was not removed")
	}
}
