package api

import (
	"bytes"
	"context"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// One signature is logged once a window, and the next line after it says how
// many it stood for.
func TestLogQuietOncePerWindow(t *testing.T) {
	var q logQuiet
	t0 := time.Now()
	if ok, n := q.allow("a", t0); !ok || n != 0 {
		t.Fatalf("first: %v %d", ok, n)
	}
	for i := 1; i <= 5; i++ {
		if ok, _ := q.allow("a", t0.Add(time.Duration(i)*time.Minute)); ok {
			t.Fatalf("repeat %d logged inside the window", i)
		}
	}
	if ok, _ := q.allow("b", t0); !ok {
		t.Fatal("another signature was held back")
	}
	if ok, n := q.allow("a", t0.Add(logQuietWindow)); !ok || n != 5 {
		t.Fatalf("after the window: %v %d, want true 5", ok, n)
	}
	if heldBack(5) == "" || heldBack(0) != "" {
		t.Fatal("heldBack")
	}
}

func quietCaptureLog(t *testing.T) (*bytes.Buffer, *sync.Mutex) {
	t.Helper()
	var buf bytes.Buffer
	var mu sync.Mutex
	log.SetOutput(writerFunc(func(p []byte) (int, error) { mu.Lock(); defer mu.Unlock(); return buf.Write(p) }))
	t.Cleanup(func() { log.SetOutput(io.Discard) })
	return &buf, &mu
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

// A fleet that does not derive from its machine is logged once and raises
// fleet_underived — once, however many beats repeat it — and the first beat
// that no longer shows it clears the alert.
func TestFleetUnderivedOnceAndAlert(t *testing.T) {
	h := newFleetHarness(t)
	buf, mu := quietCaptureLog(t)
	ep := store.Endpoint{ID: "ep_mac", Hostname: "mac-x.local", OSUser: "frank"}
	good := fakeFleet(t, machineA, "fleet", "", "")
	bad := good
	bad.FleetID = fakeFleet(t, machineB, "fleet", "", "").FleetID
	t0 := time.Now()
	for i := 0; i < 20; i++ {
		h.srv.recordFleets(ep, control.Heartbeat{MachineID: machineA, Fleets: []control.Fleet{bad}}, true, i == 0, t0.Add(time.Duration(i)*5*time.Second))
	}
	mu.Lock()
	out := buf.String()
	mu.Unlock()
	if n := strings.Count(out, "does not derive"); n != 1 {
		t.Fatalf("logged %d times, want 1:\n%s", n, out)
	}
	if !strings.Contains(out, "frank@mac-x") {
		t.Fatalf("the line does not name the machine: %s", out)
	}
	subject := ep.ID + "/" + bad.FleetID
	detail, _, ok, err := h.srv.Store.OpenFleetAlert(store.AlertFleetUnderived, subject)
	if err != nil || !ok {
		t.Fatalf("no open fleet_underived %s: %v", subject, err)
	}
	msg := alertMessage(store.FleetAlert{Kind: store.AlertFleetUnderived, Subject: subject, Detail: detail})
	if !strings.Contains(msg, "fleets/fleet/identity") || !strings.Contains(msg, "不在 hub 名单") || !strings.Contains(msg, "off the hub's list") {
		t.Fatalf("message does not say who fixes what: %s", msg)
	}
	// Fixed: the beat shows a fleet that derives.
	h.srv.recordFleets(ep, control.Heartbeat{MachineID: machineA, Fleets: []control.Fleet{good}}, true, false, t0.Add(2*time.Minute))
	if _, _, ok, _ := h.srv.Store.OpenFleetAlert(store.AlertFleetUnderived, subject); ok {
		t.Fatal("fleet_underived not cleared once the fleet derives")
	}
}

// A refused request names where it came from — address, token hash prefix,
// and the endpoint that once held the token — once a window per source.
func TestRejectedRequestNamesSourceOnce(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "oldmac")
	if _, err := h.srv.Store.RetireEndpoint("ep_oldmac"); err != nil {
		t.Fatal(err)
	}
	var lines []string
	var mu sync.Mutex
	h.srv.LogWriter = func(l string) { mu.Lock(); lines = append(lines, l); mu.Unlock() }
	for i := 0; i < 12; i++ {
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/live/report", strings.NewReader("{}"))
		req.Header.Set("Authorization", "Bearer "+tok)
		req.Header.Set("User-Agent", "ccquota-agent/test")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("status %d, want 401", resp.StatusCode)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	var got []string
	for _, l := range lines {
		if strings.Contains(l, "/v1/live/report 401") {
			got = append(got, l)
		}
	}
	if len(got) != 1 {
		t.Fatalf("logged %d lines, want 1: %q", len(got), got)
	}
	l := got[0]
	for _, want := range []string{"from=", "tok=" + HashToken(tok)[:8], "ep=ep_oldmac(", "retired", `ua="ccquota-agent/test"`} {
		if !strings.Contains(l, want) {
			t.Fatalf("line %q lacks %q", l, want)
		}
	}
	if strings.Contains(l, tok) {
		t.Fatalf("the token reached the log: %q", l)
	}
}

// A pool credential refused poolReloginAfter reads in a row raises
// pool_relogin, logs its failure once, and a good read clears it.
func TestPoolReloginAlert(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	var mu sync.Mutex
	refuse := true
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		no := refuse
		mu.Unlock()
		if no {
			http.Error(w, `{"error":"invalid"}`, http.StatusUnauthorized)
			return
		}
		w.Header().Set("anthropic-ratelimit-unified-5h-utilization", "0.1")
		w.Header().Set("anthropic-ratelimit-unified-7d-utilization", "0.1")
		w.Write([]byte(`{}`))
	}))
	t.Cleanup(up.Close)
	h.srv.HubQuota = &HubQuota{RelayURL: up.URL}
	buf, lmu := quietCaptureLog(t)
	exp := time.Now().Add(300 * 24 * time.Hour)
	putPool(t, h, credvault.Claude, "Charlie_20X", credvault.Secret{SetupToken: "sk-ant-oat01-CHARLIESECRET", ExpiresAt: &exp, AccountUUID: icloudUUID})
	subject := "claude/Charlie_20X"
	for i := 1; i <= poolReloginAfter; i++ {
		h.srv.ReadHubQuota(context.Background())
		_, _, ok, _ := h.srv.Store.OpenFleetAlert(store.AlertPoolRelogin, subject)
		if ok != (i == poolReloginAfter) {
			t.Fatalf("after %d refused reads: open=%v", i, ok)
		}
	}
	detail, _, _, _ := h.srv.Store.OpenFleetAlert(store.AlertPoolRelogin, subject)
	msg := alertMessage(store.FleetAlert{Kind: store.AlertPoolRelogin, Subject: subject, Detail: detail})
	if !strings.Contains(msg, "重新登录") || !strings.Contains(msg, "re-logs it in on the pool page") {
		t.Fatalf("message: %s", msg)
	}
	lmu.Lock()
	out := buf.String()
	lmu.Unlock()
	if n := strings.Count(out, "hub quota: claude/Charlie_20X"); n != 1 {
		t.Fatalf("failure logged %d times, want 1:\n%s", n, out)
	}
	if strings.Contains(out, "CHARLIESECRET") {
		t.Fatal("a secret reached the log")
	}
	mu.Lock()
	refuse = false
	mu.Unlock()
	h.srv.ReadHubQuota(context.Background())
	if _, _, ok, _ := h.srv.Store.OpenFleetAlert(store.AlertPoolRelogin, subject); ok {
		t.Fatal("pool_relogin not cleared by a good read")
	}
}
