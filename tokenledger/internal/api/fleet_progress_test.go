package api

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// One progress stream per parent (claude-fleet#1648, EPIC #1645 C5).

type progressAnswer struct {
	Events []struct {
		Seq    int64           `json:"seq"`
		RID    string          `json:"rid"`
		Parent string          `json:"parent"`
		Kind   string          `json:"kind"`
		State  string          `json:"state"`
		Event  json.RawMessage `json:"event"`
	} `json:"events"`
	Seq int64 `json:"seq"`
}

func progressGet(t *testing.T, h *harness, tok, query string) (int, progressAnswer, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/node/progress"+query, nil)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out progressAnswer
	if res.StatusCode == http.StatusOK {
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatalf("answer does not parse: %v %s", err, raw)
		}
	}
	return res.StatusCode, out, string(raw)
}

// The completion criterion, hub side: a placement's every state and the
// child's reports land in ONE stream under the parent's worker_id, in order;
// the parent's machine reads it and the child's does not; the same event
// stored twice is one; a read from the last seq is empty.
func TestProgressStreamPerParent(t *testing.T) {
	h, _, n := peerHarness(t)
	now := time.Now()
	if _, err := h.srv.Store.RecordFleetSnapshot(n["alice4"].id, "macmini-m4", "alice", "mach-alice4",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "verkyyi/claude-fleet", Checkout: "/c"}}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.RecordFleetSnapshot(n["alice5"].id, "macmini", "alice", "mach-alice5",
		[]store.FleetReport{{FleetID: wrFleetM5, Name: "fleet", Repo: "verkyyi/claude-fleet", Checkout: "/c"}}, now); err != nil {
		t.Fatal(err)
	}
	parent := wrFleetM5 + "/" + wrFid

	// The degenerate case: nothing placed, nothing reported — an empty stream.
	if st, got, raw := progressGet(t, h, n["alice5"].token, "?since=0"); st != 200 || len(got.Events) != 0 || got.Seq != 0 {
		t.Fatalf("empty stream: HTTP %d %s", st, raw)
	}

	// A placement from the parent's fleet onto m4: accepted, then done.
	req, _ := json.Marshal(map[string]any{"action": "worker_start", "fleet_id": wrFleetM4, "node": "auto",
		"params": map[string]any{"issue": float64(1648), "repo": "verkyyi/claude-fleet", "origin_wid": parent}})
	op := store.FleetOperation{ID: "44444444-4444-4444-8444-444444444444", FleetID: wrFleetM4, Action: "worker_start",
		Request: string(req), Actor: "alice", Idem: "i1", Status: "accepted", Created: now, Updated: now}
	if err := h.srv.Store.InsertFleetOperation(op); err != nil {
		t.Fatal(err)
	}
	h.srv.progressOp(op)
	h.srv.progressOp(op) // the same state again: one event
	op.Status, op.Result, op.Updated = "succeeded", `{"window":"@42"}`, now.Add(time.Second)
	if err := h.srv.Store.UpdateFleetOperation(op.ID, op.Status, op.Result, op.Updated); err != nil {
		t.Fatal(err)
	}
	h.srv.progressOp(op)
	// A start with no parent adds nothing.
	bare := op
	bare.ID, bare.Request = "55555555-5555-4555-8555-555555555555", `{"action":"worker_start","params":{"issue":7}}`
	h.srv.progressOp(bare)

	// The child's report, as the relay the hub stored.
	payload, _ := json.Marshal(map[string]any{"child": "issue-1648", "state": "MERGED", "pr": "1700",
		"summary": "landed", "tier": "loud", "msg": "<the envelope>"})
	rel := store.FleetRelay{ID: wrFleetM4 + "/issue-1648#1.1", Kind: control.RelayChildReport,
		FromWID: wrFleetM4 + "/issue-1648", ToWID: parent, Payload: string(payload), Created: now.Add(2 * time.Second)}
	h.srv.progressReport(rel)
	h.srv.progressReport(rel) // a resend: one event
	msg := rel
	msg.ID, msg.Kind = rel.ID+"x", control.RelayMessage
	h.srv.progressReport(msg) // a message is not progress

	st, got, raw := progressGet(t, h, n["alice5"].token, "?since=0")
	if st != 200 || len(got.Events) != 3 {
		t.Fatalf("parent's machine: HTTP %d, want 3 events: %s", st, raw)
	}
	want := []struct{ kind, state, rid string }{
		{"dispatch", "accepted", "op:" + op.ID + ":accepted"},
		{"dispatch", "done", "op:" + op.ID + ":done"},
		{"report", "MERGED", rel.ID},
	}
	for i, w := range want {
		e := got.Events[i]
		if e.Kind != w.kind || e.State != w.state || e.RID != w.rid || e.Parent != parent {
			t.Fatalf("event %d = %+v, want %+v", i, e, w)
		}
	}
	var done, rep map[string]any
	_ = json.Unmarshal(got.Events[1].Event, &done)
	_ = json.Unmarshal(got.Events[2].Event, &rep)
	if done["window"] != "@42" || done["issue"] != "1648" || done["repo"] != "verkyyi/claude-fleet" || done["node"] != "macmini-m4" {
		t.Fatalf("dispatch event %v", done)
	}
	if rep["pr"] != "1700" || rep["node"] != "macmini-m4" || rep["msg"] != nil || rep["rid"] != rel.ID {
		t.Fatalf("report event %v", rep)
	}

	// The child's machine reads no one else's stream.
	if st, got, raw := progressGet(t, h, n["alice4"].token, "?since=0"); st != 200 || len(got.Events) != 0 {
		t.Fatalf("child's machine: HTTP %d %s", st, raw)
	}
	// From the last seq: nothing new.
	if st, again, raw := progressGet(t, h, n["alice5"].token, "?since="+itoa64(got.Seq)); st != 200 || len(again.Events) != 0 || again.Seq != got.Seq {
		t.Fatalf("since last: HTTP %d %s", st, raw)
	}
	// A final placement named in ops is appended as it stands (already
	// there: still three); an op of another fleet's parent is ignored.
	if st, again, raw := progressGet(t, h, n["alice5"].token, "?since=0&ops="+op.ID+",not-an-op"); st != 200 || len(again.Events) != 3 {
		t.Fatalf("ops: HTTP %d %s", st, raw)
	}
	if st, _, _ := progressGet(t, h, "", "?since=0"); st != http.StatusUnauthorized {
		t.Fatalf("no token: HTTP %d", st)
	}
}

func itoa64(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}
