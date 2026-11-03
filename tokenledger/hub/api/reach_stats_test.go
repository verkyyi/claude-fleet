package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/sshca"
)

// Reachability from the views (task FQAR).

func reachCall(t *testing.T, h *harness, method string, auth func(http.Header), body any) (int, string) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(method, h.http.URL+ReachStatsPath, bytes.NewReader(b))
	if auth != nil {
		auth(req.Header)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var raw bytes.Buffer
	raw.ReadFrom(resp.Body)
	return resp.StatusCode, raw.String()
}

func reachHist13(at int, n int64) []int64 {
	h := make([]int64, store.ReachBuckets)
	h[at] = n
	return h
}

// A certificate sends hourly rows: the good ones are kept under a hash of the
// caller (never its name), each refused row goes alone, a resend REPLACES its
// row (idempotent), a proof made for another door or none at all is 401.
func TestReachStatsIngest(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	enablePeople(t, h, pAlice)
	h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", now)
	good := k.cert(t, "person:"+pAlice, []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	hour := now.Unix() / 3600
	link := "0123456789abcdef"
	rows := []ReachRowWire{
		{Hour: hour, Route: "local", Attempts: 30, OK: 29, Enter: reachHist13(0, 29)},
		{Hour: hour - 1, Link: link, Route: "relay", Attempts: 5, OK: 4, Enter: reachHist13(3, 4), WantMS: 3600000, UpMS: 3000000, Recover: reachHist13(6, 2)},
		{Hour: hour - 1, Link: link, Route: "direct", WantMS: 600000, UpMS: 600000},
		// refused, one by one
		{Hour: hour, Link: "mac-c/kim", Route: "direct", Attempts: 1, OK: 1},         // a name, not a hash
		{Hour: hour, Link: link, Route: "local", Attempts: 1, OK: 1},                 // local with a link
		{Hour: hour, Route: "tailnet", Attempts: 1, OK: 1},                           // not a class
		{Hour: hour, Route: "local", Attempts: 1, OK: 2},                             // ok > attempts
		{Hour: hour, Link: link, Route: "relay", WantMS: 1000, UpMS: 2000},           // up > want
		{Hour: hour, Link: link, Route: "relay", WantMS: 2 * 3600000},                // more than an hour
		{Hour: hour + 2, Route: "local", Attempts: 1, OK: 1},                         // the future
		{Hour: hour - 24*91, Route: "local", Attempts: 1, OK: 1},                     // past the keep
		{Hour: hour, Route: "unknown", Attempts: 3, OK: 3, Enter: []int64{1, 2}},     // short histogram
		{Hour: hour, Route: "unknown", Attempts: 3, OK: 1, Enter: reachHist13(0, 3)}, // more enters than ok
		{Hour: hour, Route: "local", Attempts: 9, OK: 9},                             // the same key twice
	}
	sign := func(ns string, ts int64) ReachStatsRequest {
		return ReachStatsRequest{Cert: string(ssh.MarshalAuthorizedKey(good)), TS: ts,
			Sig: sshsig(t, k.user, ns, []byte(reachSigMessage(ts))), Rows: rows}
	}
	code, raw := reachCall(t, h, http.MethodPost, nil, sign(reachSigNamespace, now.Unix()))
	var ans ReachStatsAnswer
	_ = json.Unmarshal([]byte(raw), &ans)
	if code != 200 || ans.Accepted != 3 || ans.Refused != 11 {
		t.Fatalf("first batch: HTTP %d %s, want 3 accepted 11 refused", code, raw)
	}
	got, err := h.srv.Store.ReachRows(now.Add(-48 * time.Hour))
	must(t, err)
	if len(got) != 3 {
		t.Fatalf("rows = %+v", got)
	}
	for _, r := range got {
		if len(r.Src) != 16 || strings.Contains(r.Src, "alice") || strings.Contains(r.Src, pAlice) {
			t.Fatalf("src is not a hash: %q", r.Src)
		}
	}
	// The same hour resent with new totals replaces the row, never adds to it.
	rows = []ReachRowWire{{Hour: hour, Route: "local", Attempts: 40, OK: 38, Enter: reachHist13(1, 38)}}
	if code, raw := reachCall(t, h, http.MethodPost, nil, sign(reachSigNamespace, now.Unix())); code != 200 {
		t.Fatalf("resend: %d %s", code, raw)
	}
	got, _ = h.srv.Store.ReachRows(now.Add(-48 * time.Hour))
	var local []store.ReachRow
	for _, r := range got {
		if r.Route == "local" {
			local = append(local, r)
		}
	}
	if len(got) != 3 || len(local) != 1 || local[0].Attempts != 40 || local[0].OK != 38 || local[0].Enter[1] != 38 || local[0].Enter[0] != 0 {
		t.Fatalf("resend did not replace: %+v", got)
	}
	for name, req := range map[string]ReachStatsRequest{
		"another door's signature": sign(reachSigNamespace+"x", now.Unix()),
		"stale timestamp":          sign(reachSigNamespace, now.Add(-time.Hour).Unix()),
		"no credential":            {Rows: rows},
	} {
		if code, raw := reachCall(t, h, http.MethodPost, nil, req); code != http.StatusUnauthorized {
			t.Errorf("%s: HTTP %d %s, want 401", name, code, raw)
		}
	}
	// A bearer the doors accept needs no signature; GET is not a read here.
	if code, raw := reachCall(t, h, http.MethodPost, asOperator, ReachStatsRequest{Rows: rows}); code != 200 {
		t.Fatalf("operator bearer: %d %s", code, raw)
	}
	if code, _ := reachCall(t, h, http.MethodGet, asOperator, nil); code != http.StatusMethodNotAllowed {
		t.Fatalf("GET: %d, want 405", code)
	}
	// 90 days on, a row goes.
	must(t, h.srv.Store.PruneReachStats(now.Add(time.Hour)))
	if got, _ := h.srv.Store.ReachRows(now.Add(-48 * time.Hour)); len(got) != 0 {
		t.Fatalf("prune kept %+v", got)
	}
}

// The fold: each figure needs reachMinN samples behind it (else nil, "—"),
// the classes stay apart, availability is up ÷ wanted over link hours,
// percentiles are the histogram's bounds, and the 24-hour window leaves
// older hours out.
func TestReachPublicFoldAndSuppression(t *testing.T) {
	now := time.Date(2026, 11, 2, 12, 30, 0, 0, time.UTC)
	cur := now.Unix() / 3600
	var rows []store.ReachRow
	// relay: 25 link hours, each wanted the whole hour and up 54 minutes; 25
	// enters (24 ok, 20 of them under 500 ms, 4 under 2 s); 25 recoveries.
	for i := int64(0); i < 25; i++ {
		r := store.ReachRow{Hour: cur - i, Src: "s", Link: "aaaaaaaaaaaaaaaa", Route: reachRouteRelay, WantMS: 3600000, UpMS: 3240000, Attempts: 1, OK: 1}
		if i < 20 {
			r.Enter[3] = 1
		} else if i < 24 {
			r.Enter[5] = 1
		} else {
			r.OK = 0
		}
		r.Recover[6] = 1 // under 5 s
		rows = append(rows, r)
	}
	// direct: only 5 link hours and 5 enters — every figure suppressed.
	for i := int64(0); i < 5; i++ {
		r := store.ReachRow{Hour: cur - i, Src: "s", Link: "bbbbbbbbbbbbbbbb", Route: reachRouteDirect, WantMS: 3600000, UpMS: 3600000, Attempts: 1, OK: 1}
		r.Enter[0] = 1
		rows = append(rows, r)
	}
	// local: 30 enters a week ago — in the 30-day window only.
	old := store.ReachRow{Hour: cur - 24*7, Src: "s", Route: reachRouteLocal, Attempts: 30, OK: 30}
	old.Enter[0] = 30
	rows = append(rows, old)

	day := publicReachOf(rows, now.Add(-24*time.Hour))
	if day.Relay.SessionReach == nil || *day.Relay.SessionReach < 0.94 || *day.Relay.SessionReach > 0.97 {
		t.Fatalf("relay reach = %v", day.Relay.SessionReach)
	}
	// 24 hours of the window: cur-0..cur-23 → 24 relay link hours; ≥ 20 shown.
	if day.Relay.LinkAvailability == nil || *day.Relay.LinkAvailability != 0.9 {
		t.Fatalf("relay availability = %v", day.Relay.LinkAvailability)
	}
	if day.Relay.EnterP50MS == nil || *day.Relay.EnterP50MS != 500 || *day.Relay.EnterP95MS != 2000 {
		t.Fatalf("relay enter p50/p95 = %v/%v", day.Relay.EnterP50MS, day.Relay.EnterP95MS)
	}
	if day.Relay.RecoverP50MS == nil || *day.Relay.RecoverP50MS != 5000 {
		t.Fatalf("relay recovery = %v", day.Relay.RecoverP50MS)
	}
	d := day.Direct
	if d.SessionReach != nil || d.LinkAvailability != nil || d.EnterP50MS != nil || d.RecoverP50MS != nil {
		t.Fatalf("direct below %d samples published: %+v", reachMinN, d)
	}
	if day.Local.SessionReach != nil {
		t.Fatalf("a week-old row reached the 24-hour window: %+v", day.Local)
	}
	// all = relay + direct: 29 link hours, 29 attempts.
	if day.All.LinkAvailability == nil || day.All.SessionReach == nil {
		t.Fatalf("all = %+v", day.All)
	}
	month := publicReachOf(rows, now.Add(-30*24*time.Hour))
	if month.Local.SessionReach == nil || *month.Local.SessionReach != 1 || *month.Local.EnterP95MS != 150 {
		t.Fatalf("30-day local = %+v", month.Local)
	}
	if month.At != cur*3600*1000 {
		t.Fatalf("at = %d", month.At)
	}
	// No rows at all: every figure null.
	empty := publicReachOf(nil, now.Add(-24*time.Hour))
	if b, _ := json.Marshal(empty); strings.Count(string(b), "null") != 24 {
		t.Fatalf("empty = %s", b)
	}
}

// /v1/status carries reach_24h / reach_30d in the explicit public shape:
// figures and nulls only — no source, no link hash, no counts.
func TestPublicHealthReachShape(t *testing.T) {
	h, _, _ := rolesHarness(t)
	now := time.Now()
	cur := now.Unix() / 3600
	var rows []store.ReachRow
	for i := int64(0); i < 22; i++ {
		r := store.ReachRow{Hour: cur - i, Src: "feedfacefeedface", Link: "cafecafecafecafe", Route: reachRouteRelay, WantMS: 3600000, UpMS: 3600000, Attempts: 2, OK: 2, At: now}
		r.Enter[2] = 2
		rows = append(rows, r)
	}
	must(t, h.srv.Store.PutReachRows(rows))
	code, body := rolesGet(t, h, nil, PublicHealthPath)
	if code != 200 {
		t.Fatalf("%d %s", code, body)
	}
	var data struct {
		Reach24 map[string]any `json:"reach_24h"`
		Reach30 struct {
			Relay  map[string]any `json:"relay"`
			Direct map[string]any `json:"direct"`
		} `json:"reach_30d"`
	}
	must(t, json.Unmarshal(body, &data))
	relay := data.Reach30.Relay
	if relay["session_reach"] != float64(1) || relay["link_availability"] != float64(1) || relay["enter_p50_ms"] != float64(300) || relay["recover_p50_ms"] != nil {
		t.Fatalf("relay = %v", relay)
	}
	if data.Reach30.Direct["session_reach"] != nil {
		t.Fatalf("direct = %v", data.Reach30.Direct)
	}
	for _, k := range []string{"all", "local", "direct", "relay", "at"} {
		if _, ok := data.Reach24[k]; !ok {
			t.Fatalf("reach_24h lacks %s: %s", k, body)
		}
	}
	for _, forbidden := range []string{"feedface", "cafecafe", `"src"`, `"link"`, `"attempts"`, `"want_ms"`, `"n"`} {
		if strings.Contains(string(body), forbidden) {
			t.Fatalf("public field %s: %s", forbidden, body)
		}
	}
}

// The relay canary: the probe opens it through a real HTTP server and gets
// the hello and its frame back; a front door answering 426 (the 2026-11-02
// shape) fails the probe; the gate bounds what an anonymous caller can open;
// and the `relay` component goes green, then opens an incident after three
// failed minutes, like any other component.
func TestReachCanaryProbeAndRelayComponent(t *testing.T) {
	h := newFleetHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	target := reachCanaryTarget(h.http.URL)
	if !strings.HasPrefix(target, "ws://") || !strings.HasSuffix(target, ReachCanaryPath) {
		t.Fatalf("target = %q", target)
	}
	if err := probeReachCanary(ctx, target); err != nil {
		t.Fatalf("probe through the hub: %v", err)
	}
	if reachCanaryTarget("https://hub.example.com/x") != "wss://hub.example.com"+ReachCanaryPath || reachCanaryTarget("") != "" {
		t.Fatal("wss target")
	}
	upgradeRequired := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUpgradeRequired)
	}))
	defer upgradeRequired.Close()
	if err := probeReachCanary(ctx, "ws"+strings.TrimPrefix(upgradeRequired.URL, "http")+ReachCanaryPath); err == nil || err.Error() != "status" {
		t.Fatalf("426 front door: %v, want status", err)
	}
	// A plain GET (no upgrade) is not an echo; POST is 405.
	if resp, err := http.Post(h.http.URL+ReachCanaryPath, "text/plain", nil); err != nil || resp.StatusCode != 405 {
		t.Fatalf("POST: %v %v", resp, err)
	}
	var g reachCanaryGate
	n := time.Now()
	for i := 0; i < reachCanaryOpenMax; i++ {
		if !g.admit(n) {
			t.Fatal("gate too small")
		}
	}
	if g.admit(n) {
		t.Fatal("more than reachCanaryOpenMax open at once")
	}
	for i := 0; i < reachCanaryOpenMax; i++ {
		g.release()
	}
	for g.admit(n) {
		g.release()
	}
	if g.tokens >= 1 {
		t.Fatal("the bucket never empties")
	}

	// The component: FleetPublicURL is the hub itself → ok.
	h.srv.FleetPublicURL = h.http.URL
	t0 := time.Now().Truncate(time.Minute)
	h.srv.probeHealth(ctx, t0)
	relayState := func() string {
		ps, err := h.srv.Store.HealthProbes(t0.Add(-time.Hour))
		must(t, err)
		_, latest := healthOverview(ps, time.Now())
		return latest["relay"].State
	}
	if s := relayState(); s != "ok" {
		t.Fatalf("relay = %s, want ok", s)
	}
	// The same component behind a front door that refuses the upgrade.
	t.Setenv("CCQUOTA_HEALTH_TARGETS", `{"relay":"ws`+strings.TrimPrefix(upgradeRequired.URL, "http")+`/v1/node/peer-relay-canary"}`)
	for i := 1; i <= 3; i++ {
		h.srv.probeHealth(ctx, t0.Add(time.Duration(i)*time.Minute))
	}
	evs, err := h.srv.Store.HealthEvents(t0.Add(-time.Hour))
	must(t, err)
	opened := false
	for _, e := range evs {
		if e.Component == "relay" && e.Ended == 0 {
			opened = true
		}
	}
	if !opened {
		t.Fatalf("three failed relay probes opened no incident: %+v", evs)
	}
}
