package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A worker's evidence and history, handed to the hub by the machine that
// reaped it (claude-fleet#1609, EPIC #1645 C9).

func workerRecordsDo(t *testing.T, h *harness, tok, method, query string, body any) (int, []store.FleetWorkerRecord, string) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, h.http.URL+"/v1/node/worker-records"+query, rd)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out struct {
		Records []store.FleetWorkerRecord `json:"records"`
	}
	if method == http.MethodGet && res.StatusCode == http.StatusOK {
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatalf("answer does not parse: %v %s", err, raw)
		}
	}
	return res.StatusCode, out.Records, string(raw)
}

const (
	wrFleetM4 = "11111111-1111-4111-8111-111111111111"
	wrFleetM5 = "22222222-2222-4222-8222-222222222222"
	wrFid     = "33333333-3333-4333-8333-333333333333"
)

func wrUpload(note string) map[string]any {
	return map[string]any{
		"worker_id": wrFleetM4 + "/" + wrFid, "origin_wid": wrFleetM5 + "/issue-1645",
		"repo": "verkyyi/claude-fleet", "issue": 1609, "key": "issue-1609", "epic": 1645,
		"records": []map[string]any{
			{"kind": "evidence", "name": "after-20261005T010203Z-shot.png", "stage": "after",
				"ts": "20261005T010203Z", "note": note, "content": []byte("\x89PNG fake")},
			{"kind": "history", "name": "landed", "stage": "landed",
				"content": []byte("2026-10-05T01:00:00Z\t1609\ttitle\t1700\tabc\t-\t-\t-\t-\tlanded\tissue-1645\n")},
		},
	}
}

// The completion criterion, hub side: a node uploads what its worker left,
// keyed by worker_id; another node of the SAME owner reads it back by repo +
// EPIC / issue (bytes and all); a node of another owner sees nothing; a node
// cannot speak for a fleet it does not report; a second upload replaces.
func TestWorkerRecordsUploadReadOwnerOnly(t *testing.T) {
	h, _, n := peerHarness(t)
	h.srv.FleetAdmins = []string{"verk"}
	now := time.Now()
	if _, err := h.srv.Store.RecordFleetSnapshot(n["alice4"].id, "macmini-m4", "alice", "mach-alice4",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "verkyyi/claude-fleet", Checkout: "/c"}}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.RecordFleetSnapshot(n["alice5"].id, "macmini", "alice", "mach-alice5",
		[]store.FleetReport{{FleetID: wrFleetM5, Name: "fleet", Repo: "verkyyi/claude-fleet", Checkout: "/c"}}, now); err != nil {
		t.Fatal(err)
	}

	if st, _, raw := workerRecordsDo(t, h, n["alice4"].token, http.MethodPost, "", wrUpload("v1")); st != 200 {
		t.Fatalf("alice@m4 upload: HTTP %d %s", st, raw)
	}
	// Idempotent: the ship report, then the reap — the same names replace.
	if st, _, raw := workerRecordsDo(t, h, n["alice4"].token, http.MethodPost, "", wrUpload("v2")); st != 200 {
		t.Fatalf("alice@m4 re-upload: HTTP %d %s", st, raw)
	}

	st, recs, raw := workerRecordsDo(t, h, n["alice5"].token, http.MethodGet, "?repo=verkyyi/claude-fleet&epic=1645", nil)
	if st != 200 || len(recs) != 2 {
		t.Fatalf("alice@m5 read by epic: HTTP %d, %d records %s", st, len(recs), raw)
	}
	var ev *store.FleetWorkerRecord
	for i := range recs {
		if recs[i].Kind == "evidence" {
			ev = &recs[i]
		}
	}
	if ev == nil || string(ev.Content) != "\x89PNG fake" || ev.Note != "v2" || ev.Node != "macmini-m4" ||
		ev.Issue != 1609 || ev.Stage != "after" || ev.WorkerID != wrFleetM4+"/"+wrFid {
		t.Fatalf("evidence record %+v", ev)
	}
	// By issue + kind, listing only (no bytes).
	st, recs, _ = workerRecordsDo(t, h, n["alice5"].token, http.MethodGet, "?repo=verkyyi/claude-fleet&issue=1609&kind=history&content=0", nil)
	if st != 200 || len(recs) != 1 || recs[0].Name != "landed" || len(recs[0].Content) != 0 || recs[0].Size == 0 {
		t.Fatalf("history listing: HTTP %d %+v", st, recs)
	}

	// Another owner sees nothing — not even that it exists.
	if st, recs, _ := workerRecordsDo(t, h, n["bob4"].token, http.MethodGet, "?repo=verkyyi/claude-fleet&epic=1645", nil); st != 200 || len(recs) != 0 {
		t.Fatalf("bob read alice's records: HTTP %d, %d", st, len(recs))
	}
	if st, recs, _ := workerRecordsDo(t, h, n["verk5"].token, http.MethodGet, "?repo=verkyyi/claude-fleet&epic=1645", nil); st != 200 || len(recs) != 0 {
		t.Fatalf("the operator's login read alice's records: HTTP %d, %d", st, len(recs))
	}
	// A node speaks only for its own fleets.
	if st, _, raw := workerRecordsDo(t, h, n["alice5"].token, http.MethodPost, "", wrUpload("forged")); st != http.StatusForbidden {
		t.Fatalf("alice@m5 uploading for m4's fleet: HTTP %d %s; want 403", st, raw)
	}
	// No token, no answer.
	if st, _, _ := workerRecordsDo(t, h, "", http.MethodGet, "?repo=verkyyi/claude-fleet", nil); st != http.StatusUnauthorized {
		t.Fatalf("no token: HTTP %d; want 401", st)
	}
	// Bad shapes are refused.
	bad := wrUpload("x")
	bad["records"] = []map[string]any{{"kind": "evidence", "name": "../escape", "content": []byte("x")}}
	if st, _, _ := workerRecordsDo(t, h, n["alice4"].token, http.MethodPost, "", bad); st != http.StatusBadRequest {
		t.Fatalf("a path in a record name: HTTP %d; want 400", st)
	}
	big := wrUpload("x")
	big["records"] = []map[string]any{{"kind": "evidence", "name": "big.png", "content": make([]byte, workerRecordMaxFile+1)}}
	if st, _, _ := workerRecordsDo(t, h, n["alice4"].token, http.MethodPost, "", big); st != http.StatusRequestEntityTooLarge {
		t.Fatalf("an oversized file: HTTP %d; want 413", st)
	}

	// Kept 30 days, then gone.
	if gone, err := h.srv.Store.ExpireWorkerRecords(store.WorkerRecordTTL, now.Add(store.WorkerRecordTTL-time.Hour)); err != nil || gone != 0 {
		t.Fatalf("expired early: %d %v", gone, err)
	}
	if gone, err := h.srv.Store.ExpireWorkerRecords(store.WorkerRecordTTL, now.Add(store.WorkerRecordTTL+time.Hour)); err != nil || gone != 2 {
		t.Fatalf("after 30 days: %d expired, %v; want 2", gone, err)
	}
}
