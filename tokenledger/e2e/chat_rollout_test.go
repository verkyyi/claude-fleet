package e2e

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Real agent + two hub replicas: the browser keeps the last complete SSE
// cursor, misses output during rollout, then reads exactly that missing tail.
func TestChatViewResumesAcrossRollingDrain(t *testing.T) {
	a, b := newReplicaPair(t)
	for _, h := range []*harness{a, b} {
		enablePeople(t, h, pAlice)
	}
	a.Srv.LinkDrainSpread = 200 * time.Millisecond
	ua, _ := url.Parse(a.HTTP.URL)
	ub, _ := url.Parse(b.HTTP.URL)
	pa, pb := httputil.NewSingleHostReverseProxy(ua), httputil.NewSingleHostReverseProxy(ub)
	var switched atomic.Bool
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if switched.Load() {
			pb.ServeHTTP(w, r)
		} else {
			pa.ServeHTTP(w, r)
		}
	}))
	t.Cleanup(front.Close)
	conf := shortTemp(t)
	svc := serveFakeChat(t, conf)
	host, login := startSignedChatAgent(t, a, front.URL, "roll-chat", conf)
	setChatHome(t, a, pAlice, host, login)
	waitFor(t, 3*time.Second, "first heartbeat", func() bool { at, _, _ := a.Srv.Store.NodeLastBeat("ep_roll-chat"); return at != nil })
	t.Cleanup(func() {
		if t.Failed() {
			events, _ := b.Srv.Store.LinkEvents(time.Now().Add(-time.Minute))
			t.Logf("events: %+v", events)
		}
	})
	const fid = "77777777-7777-4777-8777-777777777777"
	const fleet = "66666666-6666-4666-8666-666666666666"
	worker := fleet + "/" + fid
	workers, _ := json.Marshal([]map[string]any{{"key": "scratch-1", "state": "working", "worker_id": worker, "identity": fid}})
	if _, err := a.Srv.Store.RecordFleetSnapshot("ep_roll-chat", host, login, "mach-"+host, []store.FleetReport{{FleetID: fleet, Name: "fleet", Repo: "o/r", Checkout: "/c", WorkerCount: 1, WorkersJSON: string(workers)}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	svc.mu.Lock()
	svc.view = func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		if r.URL.Query().Get("at") == "100" && r.URL.Query().Get("s") == "s1" {
			io.WriteString(w, `data: {"t":"items","session":"s1","at":200,"items":[{"t":"text","d":"during rollout"}]}`+"\n\n")
			return
		}
		io.WriteString(w, `data: {"t":"items","replace":true,"session":"s1","at":100,"items":[{"t":"text","d":"before rollout"}]}`+"\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}
	svc.mu.Unlock()
	alice := personCookie(pAlice, "alice")
	resp := chatDo(t, a, "GET", "/v1/chat/view?worker="+worker, alice, nil, "")
	rd := bufio.NewReader(resp.Body)
	line, err := rd.ReadString('\n')
	if err != nil || !strings.Contains(line, `"at":100`) {
		t.Fatalf("first frame: %s %v", line, err)
	}
	ended := make(chan struct{})
	go func() { io.Copy(io.Discard, rd); resp.Body.Close(); close(ended) }()
	switched.Store(true)
	a.Srv.Drain()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	a.Srv.DrainLinks(ctx)
	if ctx.Err() != nil {
		t.Fatal("drain exhausted grace")
	}
	select {
	case <-ended:
	case <-ctx.Done():
		t.Fatal("old browser stream never ended")
	}
	waitFor(t, 5*time.Second, "agent moved to survivor", func() bool { return holderOf(b, "ep_roll-chat") })
	waitFor(t, 3*time.Second, "handoff classified as hub restart", func() bool {
		events, err := b.Srv.Store.LinkEvents(time.Now().Add(-time.Minute))
		if err != nil {
			return false
		}
		for _, e := range events {
			if e.Replica == "hub-b" && e.Event == "up" && e.Cause == "hub_restart" {
				return true
			}
		}
		return false
	})
	resp = chatDo(t, b, "GET", "/v1/chat/view?worker="+worker+"&at=100&s=s1", alice, nil, "")
	defer resp.Body.Close()
	tail, err := io.ReadAll(resp.Body)
	if err != nil || resp.StatusCode != 200 || !strings.Contains(string(tail), "during rollout") || strings.Contains(string(tail), "before rollout") {
		t.Fatalf("resumed stream: %d %s %v", resp.StatusCode, tail, err)
	}
}
