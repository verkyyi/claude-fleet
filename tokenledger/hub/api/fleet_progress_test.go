package api

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
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

// Retired progress is historical data: reads never reconcile, append, or expire.
func TestProgressHistoryReadOnly(t *testing.T) {
	h, _, n := peerHarness(t)
	now := time.Now()
	_, err := h.srv.Store.RecordFleetSnapshot(n["alice5"].id, "mac-e", "alice", "mach-alice5", []store.FleetReport{{FleetID: wrFleetM5, Name: "fleet", Repo: "verkyyi/claude-fleet", Checkout: "/c"}}, now)
	if err != nil {
		t.Fatal(err)
	}
	parent := wrFleetM5 + "/" + wrFid
	old := store.FleetProgress{RID: "historical", Parent: parent, FleetID: wrFleetM5, Kind: store.ProgressReport, State: "MERGED", Body: `{"summary":"historical result"}`, Created: now.Add(-365 * 24 * time.Hour)}
	if _, err := h.srv.Store.AppendFleetProgress(old); err != nil {
		t.Fatal(err)
	}
	op := store.FleetOperation{ID: "44444444-4444-4444-8444-444444444444", FleetID: wrFleetM5, Action: "worker_start", Request: `{"params":{"origin_wid":"` + parent + `"}}`, Actor: "alice", Idem: "history", Status: "accepted", Created: now, Updated: now}
	if err := h.srv.Store.InsertFleetOperation(op); err != nil {
		t.Fatal(err)
	}
	h.srv.progressOp(op)
	h.srv.progressReport(store.FleetRelay{ID: "new-report", Kind: control.RelayChildReport, ToWID: parent, Payload: `{"state":"MERGED"}`, Created: now})
	st, got, raw := progressGet(t, h, n["alice5"].token, "?since=0&ops="+op.ID)
	if st != 200 || len(got.Events) != 1 || got.Events[0].RID != "historical" {
		t.Fatalf("history: %d %s", st, raw)
	}
	after, err := h.srv.Store.FleetOperation(op.ID)
	if err != nil || after.Status != op.Status || after.Result != op.Result {
		t.Fatalf("GET mutated operation: %+v %v", after, err)
	}
	if st, again, raw := progressGet(t, h, n["alice5"].token, "?since="+itoa64(got.Seq)); st != 200 || len(again.Events) != 0 || again.Seq != got.Seq {
		t.Fatalf("cursor: %d %s", st, raw)
	}
	if st, other, raw := progressGet(t, h, n["alice4"].token, "?since=0"); st != 200 || len(other.Events) != 0 {
		t.Fatalf("ownership: %d %s", st, raw)
	}
	if st, _, _ := progressGet(t, h, "", "?since=0"); st != http.StatusUnauthorized {
		t.Fatalf("unauthenticated: %d", st)
	}
}

func itoa64(n int64) string { b, _ := json.Marshal(n); return string(b) }
