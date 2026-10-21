package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/sshca"
)

// A client's connection events (claude-fleet T689).

func clientEventsCall(t *testing.T, h *harness, method, query string, auth func(http.Header), body any) (int, string) {
	t.Helper()
	var rd *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, h.http.URL+control.ClientEventsPath+query, rd)
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

// A certificate sends its events under the device name the hub registered
// for its key; a batch sent twice is written once; an event carrying text
// (a reason that is not a code) is refused alone; a proof made for another
// door is refused; the person reads their own statistics, the operator all.
func TestFleetClientEventsByCertificate(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	enablePeople(t, h, pAlice, pBob)
	h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", now)
	h.srv.Store.AdoptPrincipal(pBob, "bob", "Bob", now)
	good := k.cert(t, "person:"+pAlice, []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	if _, err := h.srv.Store.RegisterDevice(store.FleetDevice{Fingerprint: ssh.FingerprintSHA256(k.user.PublicKey()),
		PrincipalID: pAlice, PublicKey: "k", Name: "alice-mbp"}, now); err != nil {
		t.Fatal(err)
	}
	at := func(ago time.Duration) string { return now.Add(-ago).UTC().Format(time.RFC3339) }
	evs := []ClientEventWire{
		{ID: "0000000a", At: at(50 * time.Minute), Event: "start", Start: "5a5a5a5a"},
		{ID: "0000000b", At: at(49 * time.Minute), Event: "fail", Start: "5a5a5a5a", Phase: "start", Home: "mac-d", Reason: "home:no_machine_online"},
		{ID: "0000000c", At: at(48 * time.Minute), Event: "up", Start: "5a5a5a5a", Phase: "start", Home: "mac-d", Route: "lan", MS: 900},
		{ID: "0000000d", At: at(40 * time.Minute), Event: "drop", Start: "5a5a5a5a", Home: "mac-d", Route: "lan", RC: 255, Reason: "timeout"},
		{ID: "0000000e", At: at(40 * time.Minute), Event: "up", Start: "5a5a5a5a", Phase: "reconnect", Home: "mac-d", Route: "relay", MS: 4000},
		{ID: "00000015", At: at(35 * time.Minute), Event: "fail", Start: "5a5a5a5a", Phase: "reconnect", Home: "mac-d", RC: 255, Reason: "timeout"},
		{ID: "0000000f", At: at(30 * time.Minute), Event: "drop", Start: "5a5a5a5a", Home: "mac-d", Route: "relay", RC: 255, Reason: "reset"},
		{ID: "00000010", At: at(29 * time.Minute), Event: "rehome", Start: "5a5a5a5a", Home: "mac-d", To: "m3"},
		{ID: "00000011", At: at(29 * time.Minute), Event: "up", Start: "5a5a5a5a", Phase: "reconnect", Home: "m3", Route: "direct", MS: 12000},
		// refused: free text in the reason, a home that is not a name, a kind
		{ID: "00000012", At: at(time.Minute), Event: "fail", Reason: "Permission denied (publickey) for alice"},
		{ID: "00000013", At: at(time.Minute), Event: "fail", Home: "mac d; rm -rf"},
		{ID: "00000014", At: at(time.Minute), Event: "keystroke"},
	}
	body := func(ns string, msg func(int64) string, ts int64) ClientEventsRequest {
		return ClientEventsRequest{Cert: string(ssh.MarshalAuthorizedKey(good)), TS: ts,
			Sig: sshsig(t, k.user, ns, []byte(msg(ts))), Device: "whatever-it-says", Events: evs}
	}
	code, raw := clientEventsCall(t, h, http.MethodPost, "", nil, body(control.ClientEventsSigNamespace, control.ClientEventsSigMessage, now.Unix()))
	var ans ClientEventsAnswer
	_ = json.Unmarshal([]byte(raw), &ans)
	if code != 200 || ans.Accepted != 9 || ans.Refused != 3 || ans.Duplicate != 0 {
		t.Fatalf("first batch: HTTP %d %s, want 9 accepted 3 refused", code, raw)
	}
	code, raw = clientEventsCall(t, h, http.MethodPost, "", nil, body(control.ClientEventsSigNamespace, control.ClientEventsSigMessage, now.Unix()))
	_ = json.Unmarshal([]byte(raw), &ans)
	if code != 200 || ans.Accepted != 0 || ans.Duplicate != 9 {
		t.Fatalf("the same batch again: HTTP %d %s, want 9 duplicates", code, raw)
	}
	for name, req := range map[string]ClientEventsRequest{
		"summary signature": body(control.SummarySigNamespace, control.SummarySigMessage, now.Unix()),
		"stale timestamp":   body(control.ClientEventsSigNamespace, control.ClientEventsSigMessage, now.Add(-time.Hour).Unix()),
	} {
		if code, raw := clientEventsCall(t, h, http.MethodPost, "", nil, req); code != http.StatusUnauthorized {
			t.Errorf("%s: HTTP %d %s, want 401", name, code, raw)
		}
	}
	if code, _ := clientEventsCall(t, h, http.MethodGet, "", nil, nil); code != http.StatusUnauthorized {
		t.Errorf("GET with no credential: HTTP %d, want 401", code)
	}

	read := func(auth func(http.Header), q string) ClientEventsReport {
		t.Helper()
		code, raw := clientEventsCall(t, h, http.MethodGet, q, auth, nil)
		if code != 200 {
			t.Fatalf("GET %s: HTTP %d %s", q, code, raw)
		}
		var out ClientEventsReport
		if err := json.Unmarshal([]byte(raw), &out); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(raw, "Permission denied") {
			t.Fatalf("a refused event's text reached the table: %s", raw)
		}
		return out
	}
	out := read(asSession(pAlice), "?hours=24&events=1")
	tot := out.Total
	if tot.Starts != 1 || tot.Ups != 3 || tot.Drops != 2 || tot.Reconnects != 2 || tot.Fails != 1 ||
		tot.StartsFailed != 1 || tot.ReconnectFails != 1 || tot.ReconnectFailReasons["timeout"] != 1 || tot.Rehomes != 1 || tot.ReconnectP50MS != 4000 || tot.ReconnectP90MS != 12000 {
		t.Fatalf("totals = %+v", tot)
	}
	if tot.DropReasons["timeout"] != 1 || tot.DropReasons["reset"] != 1 || tot.FailReasons["home:no_machine_online"] != 1 {
		t.Fatalf("reasons = %v / %v", tot.DropReasons, tot.FailReasons)
	}
	if len(out.Devices) != 1 || out.Devices[0].Device != "alice-mbp" {
		t.Fatalf("devices = %+v, want the hub's name alice-mbp", out.Devices)
	}
	if got := fmt.Sprintln(len(out.By), out.By[0].Home, out.By[1].Home); got != "2 m3 mac-d\n" {
		t.Fatalf("by device × home = %s", got)
	}
	if len(out.Events) != 9 {
		t.Fatalf("events = %d, want 9", len(out.Events))
	}
	if out := read(asSession(pAlice), "?hours=1&device=nobody"); out.Total.Ups != 0 {
		t.Fatalf("another device's filter read %+v", out.Total)
	}
	// Someone else reads nothing of Alice's; the operator reads it all.
	if out := read(asSession(pBob), ""); out.Total.Ups != 0 {
		t.Fatalf("bob read alice's events: %+v", out.Total)
	}
	if out := read(asOperator, ""); out.Total.Ups != 3 {
		t.Fatalf("operator: %+v", out.Total)
	}
	if code, _ := clientEventsCall(t, h, http.MethodGet, "?hours=0", asOperator, nil); code != http.StatusBadRequest {
		t.Errorf("hours=0: HTTP %d, want 400", code)
	}
}

func TestNearestRank(t *testing.T) {
	xs := []int64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
	if nearestRank(xs, 50) != 5 || nearestRank(xs, 90) != 9 || nearestRank(nil, 50) != 0 || nearestRank([]int64{7}, 90) != 7 {
		t.Fatal("nearest rank")
	}
}

// D4NW: a network change, the view back after it (an up with reason net) and a
// drop the person ended by hand are counted apart.
func TestClientLineStatsNet(t *testing.T) {
	at := time.Now()
	ev := func(kind, start, phase, reason string, ms int64) store.FleetClientEvent {
		at = at.Add(time.Second)
		return store.FleetClientEvent{Device: "mbp", Start: start, Event: kind, Phase: phase, Reason: reason, MS: ms, At: at}
	}
	st := clientLineStats([]store.FleetClientEvent{
		ev("start", "a", "", "", 0), ev("up", "a", "start", "", 900),
		ev("net", "a", "", "hotspot", 0), ev("drop", "a", "", "netchange", 0), ev("up", "a", "reconnect", "net", 3000),
		ev("net", "a", "", "lan", 0), ev("drop", "a", "", "netchange", 0), ev("up", "a", "reconnect", "net", 7000),
		ev("drop", "a", "", "timeout", 0), ev("up", "a", "reconnect", "", 20000),
		ev("start", "b", "", "", 0), ev("up", "b", "start", "", 900), ev("drop", "b", "", "timeout", 0),
		ev("quit", "b", "", "interrupt", 0),
		ev("start", "c", "", "", 0), ev("up", "c", "start", "", 900), ev("quit", "c", "", "quit", 0),
	})
	if st.NetChanges != 2 || st.NetReconnects != 2 || st.NetP50MS != 3000 || st.NetP95MS != 7000 ||
		st.ManualAfterDrop != 1 || st.Reconnects != 3 || st.ReconnectP95MS != 20000 {
		t.Fatalf("stats = %+v", st)
	}
}
