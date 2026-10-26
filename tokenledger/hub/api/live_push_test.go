package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/nodesig"
)

// Count real row writes, on both CI database legs, rather than asserting a
// cache implementation. Ingest touches endpoints even for an empty batch.
func countEndpointWrites(t *testing.T, h *harness) func() int {
	t.Helper()
	statements := []string{`CREATE TABLE report_write_count (n INTEGER NOT NULL)`, `INSERT INTO report_write_count VALUES (0)`}
	if os.Getenv("CCQUOTA_DB_URL") != "" {
		statements = append(statements, `CREATE FUNCTION count_report_write() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN UPDATE report_write_count SET n=n+1; RETURN NEW; END $$`,
			`CREATE TRIGGER count_report_write AFTER UPDATE ON endpoints FOR EACH ROW EXECUTE FUNCTION count_report_write()`)
	} else {
		statements = append(statements, `CREATE TRIGGER count_report_write AFTER UPDATE ON endpoints BEGIN UPDATE report_write_count SET n=n+1; END`)
	}
	for _, q := range statements {
		if _, err := h.srv.Store.DB().Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	return func() int {
		t.Helper()
		var n int
		if err := h.srv.Store.DB().QueryRow(`SELECT n FROM report_write_count`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
}

func TestLegacyLiveReportsCoalesceWithoutWrites(t *testing.T) {
	a, b := asReplicas(t, newFleetHarness(t))
	tok := a.enroll(t, "live")
	count := countEndpointWrites(t, a)
	body := liveReport{Sessions: []LiveSession{{Source: "claude", SessionID: "s", ObservedAt: time.Now(), InputTokens: 1}}, Complete: true}
	send := func() {
		t.Helper()
		raw, _ := json.Marshal(body)
		req, _ := http.NewRequest("POST", a.http.URL+"/v1/live/report", bytes.NewReader(raw))
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Fatal(resp.Status)
		}
	}
	for i := 0; i < 12; i++ {
		send()
	}
	waitFor(t, 3*time.Second, "peer live snapshot", func() bool { return len(b.srv.LiveStore.Snapshot().Sessions) == 1 })
	if n := a.srv.liveFanned.Load(); n != 1 {
		t.Fatalf("unchanged fanout=%d", n)
	}
	if count() != 0 {
		t.Fatal("live report wrote database rows")
	}
	body.Sessions[0].InputTokens = 2
	send()
	if a.srv.liveFanned.Load() != 2 {
		t.Fatal("changed report not forwarded")
	}
	a.srv.LiveStore.mu.Lock()
	r := a.srv.LiveStore.receipts["ep_live"]
	r.at = time.Now().Add(-time.Minute)
	a.srv.LiveStore.receipts["ep_live"] = r
	a.srv.LiveStore.mu.Unlock()
	send()
	if a.srv.liveFanned.Load() != 3 {
		t.Fatal("heartbeat did not repair peers")
	}
	body.Sessions = nil
	send()
	waitFor(t, 3*time.Second, "peer removal", func() bool { return len(b.srv.LiveStore.Snapshot().Sessions) == 0 })
}

func TestControlLiveReportUsesAuthenticatedEndpoint(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "live")
	c := dialNode(t, h, tok)
	if !hello(t, c, control.Proto, 5000).LiveReport {
		t.Fatal("missing transport negotiation")
	}
	m, _ := control.New(control.TypeLiveReport, liveReport{Complete: true, Sessions: []LiveSession{{SessionID: "s", EndpointID: "forged", ObservedAt: time.Now(), Source: "claude"}}})
	if err := wsjson.Write(context.Background(), c, m); err != nil {
		t.Fatal(err)
	}
	waitFor(t, time.Second, "control live report", func() bool { return len(h.srv.LiveStore.Snapshot().Sessions) == 1 })
	if h.srv.LiveStore.Snapshot().Sessions[0].EndpointID != "ep_live" {
		t.Fatal("client chose endpoint")
	}
}

func TestIdleIngestCoalescesLegacyDatabaseWrites(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "idle")
	count := countEndpointWrites(t, h)
	b := batchFor("account", "host", nil, "")
	b.Collector = &model.CollectorStatus{Source: "claude", ProfileID: "default", State: "idle", ObservedAt: time.Now()}
	push := func() {
		t.Helper()
		r := h.push(t, tok, b)
		defer r.Body.Close()
		if r.StatusCode != 200 {
			t.Fatal(r.Status)
		}
	}
	push()
	initial := count()
	if initial == 0 {
		t.Fatal("first report not stored")
	}
	for i := 0; i < 12; i++ {
		b.Collector.ObservedAt = time.Now()
		push()
	}
	if n := count(); n != initial {
		t.Fatalf("unchanged writes=%d want %d", n, initial)
	}
	b.Collector.State = "degraded"
	push()
	if count() <= initial {
		t.Fatal("status change not stored")
	}
	prior := count()
	b = batchFor("account", "host", []string{"new-event"}, "")
	push()
	if count() <= prior {
		t.Fatal("usage batch not ingested")
	}
}

func TestLiveControlAvoidsPerReportNonceWrites(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "signed")
	signer, note := nodesig.Ensure(context.Background(), h.http.Client(), h.http.URL, tok, filepath.Join(t.TempDir(), "key"))
	if signer == nil {
		t.Fatal(note)
	}
	count := func() int {
		t.Helper()
		var n int
		if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_sig_nonces`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	before := count()
	for i := 0; i < 12; i++ {
		if code := signedDo(t, h, signer, tok, "POST", "/v1/live/report", `{"sessions":[],"complete":true}`); code != 200 {
			t.Fatal(code)
		}
	}
	if got := count() - before; got != 12 {
		t.Fatalf("legacy signed HTTP nonce writes=%d, want 12", got)
	}
	c := dialNode(t, h, tok)
	hello(t, c, control.Proto, 5000)
	before = count()
	for i := 0; i < 12; i++ {
		m, _ := control.New(control.TypeLiveReport, liveReport{Complete: true, Sessions: []LiveSession{{SessionID: fmt.Sprint(i), Source: "claude", ObservedAt: time.Now()}}})
		if err := wsjson.Write(context.Background(), c, m); err != nil {
			t.Fatal(err)
		}
	}
	waitFor(t, time.Second, "last control snapshot", func() bool { ss := h.srv.LiveStore.Snapshot().Sessions; return len(ss) == 1 && ss[0].SessionID == "11" })
	if got := count() - before; got != 0 {
		t.Fatalf("control snapshots wrote %d replay nonces", got)
	}
}

func TestLiveMachineLaneKeepsLoginIdentity(t *testing.T) {
	h := newFleetHarness(t)
	root := h.enroll(t, "machine")
	identify(t, h, "machine", "host", "root")
	user := h.enroll(t, "login")
	identify(t, h, "login", "host", "alice")
	n := dialMachine(t, h, root)
	reply := n.login("alice", user, false)
	var welcome control.Welcome
	if json.Unmarshal(reply.Payload, &welcome) != nil || !welcome.LiveReport {
		t.Fatal("login has no live capability")
	}
	m, _ := control.New(control.TypeLiveReport, liveReport{Complete: true, Sessions: []LiveSession{{SessionID: "tenant", Source: "claude", ObservedAt: time.Now()}}})
	n.send("alice", m)
	waitFor(t, time.Second, "tenant live snapshot", func() bool { return len(h.srv.LiveStore.Snapshot().Sessions) == 1 })
	if got := h.srv.LiveStore.Snapshot().Sessions[0].EndpointID; got != "ep_login" {
		t.Fatalf("snapshot assigned to %s", got)
	}
}
