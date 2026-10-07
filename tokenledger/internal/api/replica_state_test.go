package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The in-memory state with two hub replicas (claude-fleet#2190).

// asReplicas turns a single-hub harness into two replicas over its database:
// hub-a (h's own Server, remounted as a replica — it starts first, so it holds
// the state) and hub-b, a second process with the same configuration and a
// memory of its own.
func asReplicas(t *testing.T, h *harness) (a, b *harness) {
	t.Helper()
	if err := h.srv.Store.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	mk := func(srv *Server, name string) *harness {
		srv.Replica = &Replica{Name: name, Token: replicaTestToken}
		ts := httptest.NewUnstartedServer(srv.Handler())
		srv.Replica.URL = "http://" + ts.Listener.Addr().String()
		ts.Start()
		t.Cleanup(ts.Close)
		if err := srv.StartReplica(); err != nil {
			t.Fatal(err)
		}
		go srv.RunReplica(ctx)
		return &harness{srv: srv, http: ts, tokens: h.tokens}
	}
	a = mk(h.srv, "hub-a")
	time.Sleep(time.Millisecond) // a strictly older start: hub-a holds the state
	o := h.srv
	b = mk(&Server{Store: o.Store, Pricing: o.Pricing, ViewerToken: o.ViewerToken, LiveStore: NewLive(),
		Fleet: o.Fleet, SSHCA: o.SSHCA, GitHub: o.GitHub, FleetRoutes: o.FleetRoutes}, "hub-b")
	return a, b
}

// The issue's 完成判据: start, poll and the QR page's confirmation land on the
// two replicas in turn, 100 times, and every login is issued exactly once.
func TestFleetLoginTwoReplicas(t *testing.T) {
	single, _ := certHarness(t)
	a, b := asReplicas(t, single)
	hs := []*harness{a, b}

	const runs = 100
	ok := 0
	for i := 0; i < runs; i++ {
		x, y := hs[i%2], hs[(i+1)%2]
		code, body := postJSON(t, x, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)})
		if code != 200 {
			t.Fatalf("#%d start on %s: %d %s", i, x.srv.Replica.Name, code, body)
		}
		var st DeviceStart
		json.Unmarshal(body, &st)
		if !strings.HasPrefix(st.VerificationURI, x.http.URL+"/fleet/login?code=") {
			t.Fatalf("#%d verification uri %q names another host than the one asked (%s)", i, st.VerificationURI, x.http.URL)
		}
		if code, _ := postJSON(t, y, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code != http.StatusAccepted {
			t.Fatalf("#%d poll on %s before approval: %d, want 202", i, y.srv.Replica.Name, code)
		}
		if pc, raw := asPerson(t, y, http.MethodGet, "/fleet/login?code="+st.UserCode, pAlice, nil); pc != 200 || !strings.Contains(string(raw), ">Confirm</button>") {
			t.Fatalf("#%d confirm page on %s: %d\n%s", i, y.srv.Replica.Name, pc, raw)
		}
		if pc, done := personForm(t, y, pAlice, y.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}}); pc != 200 || !strings.Contains(done, "valid until") {
			t.Fatalf("#%d approve on %s: %d\n%s", i, y.srv.Replica.Name, pc, done)
		}
		code, body = postJSON(t, x, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode})
		if code != 200 {
			t.Fatalf("#%d poll on %s after approval: %d %s", i, x.srv.Replica.Name, code, body)
		}
		var cr CertResponse
		json.Unmarshal(body, &cr)
		if c := parseCert(t, cr.Certificate); strings.Join(c.ValidPrincipals, ",") != "alice" {
			t.Fatalf("#%d principals %v", i, c.ValidPrincipals)
		}
		if code, _ := postJSON(t, y, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code != http.StatusGone {
			t.Fatalf("#%d second poll on %s: %d, want 410 (handed out once)", i, y.srv.Replica.Name, code)
		}
		ok++
	}
	t.Logf("fleet login（start / poll / 确认交替落在两份）：%d/%d 成功；hub-b 转给持有份 %d 次，hub-a 转出 %d 次",
		ok, runs, b.srv.stateForwarded.Load(), a.srv.stateForwarded.Load())
	if a.srv.stateForwarded.Load() != 0 {
		t.Fatalf("the state holder forwarded %d requests", a.srv.stateForwarded.Load())
	}
	if b.srv.stateForwarded.Load() < runs*3 {
		t.Fatalf("hub-b forwarded %d requests; every one of its login requests should go to hub-a", b.srv.stateForwarded.Load())
	}
	if certs, err := a.srv.Store.FleetCerts(pAlice, 1000); err != nil || len(certs) != runs {
		t.Fatalf("audit rows = %d, %v; want %d", len(certs), err, runs)
	}
}

// A client lease written through one replica is read through the other —
// over the route, and from inside the hub (ClientLeaseOf, for placement).
func TestClientLeaseTwoReplicas(t *testing.T) {
	single := newFleetHarness(t)
	k := newCertKit(t)
	single.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	single.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	alice := k.cert(t, "person:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	a, b := asReplicas(t, single)
	call := func(h *harness, r ClientLeaseRequest) ClientLeaseResponse {
		t.Helper()
		r.Cert, r.TS = string(ssh.MarshalAuthorizedKey(alice)), time.Now().Unix()
		r.Sig = sshsig(t, k.user, control.ClientSigNamespace, []byte(control.ClientSigMessage(r.TS)))
		code, out, raw := postClient(t, h, nil, r)
		if code != 200 {
			t.Fatalf("%s on %s: HTTP %d %s", r.Action, h.srv.Replica.Name, code, raw)
		}
		return out
	}

	mac := call(b, ClientLeaseRequest{Action: "acquire", Device: "MacBook", Host: "MacBook"})
	if mac.State != "active" || mac.Lease == nil || mac.ActionKey == "" {
		t.Fatalf("acquire on hub-b = %+v", mac)
	}
	for i := 0; i < 10; i++ {
		h := []*harness{a, b}[i%2]
		if r := call(h, ClientLeaseRequest{Action: "renew", Lease: mac.Lease.ID}); r.State != "active" {
			t.Fatalf("renew #%d on %s = %+v", i, h.srv.Replica.Name, r)
		}
	}
	phone := call(a, ClientLeaseRequest{Action: "acquire", Device: "iPhone", Host: "iPhone"})
	for _, h := range []*harness{a, b} {
		got := call(h, ClientLeaseRequest{Action: "list"})
		if len(got.Clients) != 2 {
			t.Fatalf("list on %s: %d clients %+v; want the MacBook and the iPhone", h.srv.Replica.Name, len(got.Clients), got.Clients)
		}
		if l, ok := h.srv.ClientLeaseOf("wx-alice", time.Now()); !ok || (l.ID != mac.Lease.ID && l.ID != phone.Lease.ID) {
			t.Fatalf("ClientLeaseOf on %s = %+v, %v", h.srv.Replica.Name, l, ok)
		}
		if l, _ := h.srv.ClientLeasesOf("wx-alice", time.Now()); len(l) != 2 {
			t.Fatalf("ClientLeasesOf on %s = %d leases", h.srv.Replica.Name, len(l))
		}
	}
	if r := call(b, ClientLeaseRequest{Action: "release", Lease: phone.Lease.ID}); r.State != "released" {
		t.Fatalf("release on hub-b = %+v", r)
	}
	if l, ok := a.srv.ClientLeaseOf("wx-alice", time.Now()); !ok || l.ID != mac.Lease.ID {
		t.Fatalf("after the release, hub-a's lease = %+v, %v; want the MacBook", l, ok)
	}
}

// A live report received by one replica shows on the other's /v1/live.
func TestLiveTwoReplicas(t *testing.T) {
	a, b := asReplicas(t, newFleetHarness(t))
	tokA, tokB := a.enroll(t, "m5"), a.enroll(t, "m4")
	report := func(h *harness, tok, sid string) {
		t.Helper()
		body, _ := json.Marshal(map[string]any{"sessions": []LiveSession{{SessionID: sid, Source: "claude", ObservedAt: time.Now()}}})
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/live/report", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Fatalf("report on %s: %d", h.srv.Replica.Name, resp.StatusCode)
		}
	}
	sessions := func(h *harness) map[string]bool {
		var snap Snapshot
		h.getJSON(t, "/v1/live", &snap)
		out := map[string]bool{}
		for _, s := range snap.Sessions {
			out[s.SessionID] = true
		}
		return out
	}
	report(a, tokA, "s-on-a")
	report(b, tokB, "s-on-b")
	for _, h := range []*harness{a, b} {
		h := h
		waitFor(t, 3*time.Second, h.srv.Replica.Name+" sees both sessions", func() bool {
			got := sessions(h)
			return got["s-on-a"] && got["s-on-b"]
		})
	}
	if a.srv.liveFanned.Load() != 1 || b.srv.liveFanned.Load() != 1 {
		t.Fatalf("reports handed on: hub-a %d, hub-b %d; want one each", a.srv.liveFanned.Load(), b.srv.liveFanned.Load())
	}
}

// A holder that stops beating hands the state on: the other replica serves a
// login itself within replicaUpFor.
func TestReplicaStateHolderGoes(t *testing.T) {
	single, _ := certHarness(t)
	a, b := asReplicas(t, single)
	if h, ok := b.srv.stateHolder(time.Now()); !ok || h.Name != "hub-a" {
		t.Fatalf("hub-b's holder = %+v, %v; want hub-a", h, ok)
	}
	if _, ok := a.srv.stateHolder(time.Now()); ok {
		t.Fatal("hub-a, the oldest, does not think it holds the state")
	}
	// hub-a's last beat is now older than replicaUpFor.
	if err := a.srv.Store.BeatReplica(store.ReplicaRow{Name: "hub-a", URL: a.srv.Replica.URL,
		StartedAt: a.srv.replicaStarted(), SeenAt: time.Now().Add(-2 * replicaUpFor)}); err != nil {
		t.Fatal(err)
	}
	if h, ok := b.srv.stateHolder(time.Now()); ok {
		t.Fatalf("hub-b still hands the state to %s, gone for %v", h.Name, 2*replicaUpFor)
	}
	before := b.srv.stateForwarded.Load()
	code, body := postJSON(t, b, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)})
	if code != 200 {
		t.Fatalf("start on hub-b with hub-a gone: %d %s", code, body)
	}
	var st DeviceStart
	json.Unmarshal(body, &st)
	if code, _ := postJSON(t, b, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code != http.StatusAccepted {
		t.Fatalf("poll on hub-b: %d, want 202", code)
	}
	if n := b.srv.stateForwarded.Load() - before; n != 0 {
		t.Fatalf("hub-b forwarded %d requests to a holder that is gone", n)
	}
}

// EPIC #2119 共同约定 1: a single hub has no fleet_replicas table, no
// in-cluster route, and forwards nothing.
func TestReplicaStateSingleHub(t *testing.T) {
	h, _ := certHarness(t)
	code, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)})
	if code != 200 {
		t.Fatalf("start: %d %s", code, body)
	}
	var st DeviceStart
	json.Unmarshal(body, &st)
	if code, _ := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code != http.StatusAccepted {
		t.Fatalf("poll: %d", code)
	}
	tok := h.enroll(t, "m5")
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/live/report", strings.NewReader(`{"sessions":[]}`))
	req.Header.Set("Authorization", "Bearer "+tok)
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != 200 {
		t.Fatalf("live report: %v %v", resp, err)
	}
	if n := h.srv.stateForwarded.Load() + h.srv.liveFanned.Load(); n != 0 {
		t.Fatalf("a single hub handed %d requests on", n)
	}
	if _, err := h.srv.Store.Replicas(time.Now()); err == nil {
		t.Fatal("a single hub created fleet_replicas")
	}
	for _, p := range []string{LiveFanoutPath, StateLeasePath} {
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+p, strings.NewReader(`{}`))
		req.Header.Set(replicaTokenHeader, replicaTestToken)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusUnauthorized {
			t.Fatalf("a single hub answers %s with HTTP %d; the route must not exist", p, resp.StatusCode)
		}
	}
}
